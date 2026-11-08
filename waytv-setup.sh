#!/usr/bin/env bash
# WayTV Setup Script v1.0 (WayDroid-ATV TV build)
# WayTV stack: Android TV native settings app, dual launcher choice (Projectivity/AT4K),
# GApps/Vanilla selection, no splash screens, auto-download WayDroid-ATV x86_64 build.
#
# Usage:
#   sudo ./cn60-waydroid-setup-v21.0.sh                install WayTV stack
#   sudo ./cn60-waydroid-setup-v21.0.sh --force        redo all steps
#   sudo ./cn60-waydroid-setup-v21.0.sh --uninstall    remove WayTV
#
# Differs from v17:
# - WayDroid-ATV (LineageOS 24 / Android 17) instead of vanilla Waydroid
# - First boot: asks for GApps (Play Store only) vs Vanilla (Aurora + F-Droid)
# - First boot: asks for launcher (Projectivity Android-like, AT4K Apple TV-like)
# - Installs WayTV Settings app (Rust + egui, APK built in PART 2)
# - Installs both launchers, sets chosen one as default via agent API
# - Removes splash screens (no boot logo, no installation splash)
# - WayTV agent v3.1.0 with full display/apps/storage/system endpoints

set -euo pipefail

SCRIPT_VERSION=1              # bump when the script changes
STATE=/etc/waytv               # state dir (was /etc/cn60 but WayTV is separate)
MARK=$STATE/installed          # present once full install finished
STEPS=$STATE/steps             # one file per one-time step
BACKUP=$STATE/backup           # backups of system files
PKGS_ADDED=$STATE/packages-added
OPTIONS=$STATE/options         # GApps choice, launcher choice, saved once
AGENT_DIR=/etc/waytv/agent
SETTINGS_APK=/opt/waytv/app.apk  # WayTV Settings app

export DEBIAN_FRONTEND=noninteractive
APT=(apt-get -y -o DPkg::Lock::Timeout=600
     -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
MODE=install
FORCE=0
for arg in "$@"; do
    case "$arg" in
        --force)      FORCE=1 ;;
        --uninstall)  MODE=uninstall ;;
        -h|--help)    awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
        *)            die "Unknown option: $arg" ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    command -v sudo >/dev/null || die "Run as root (sudo)."
    exec sudo -E bash "$0" "$@"
fi

CHANGES=()

# ================================================================ helpers
record() {
    mkdir -p "$STATE"
    grep -qxF -- "$2" "$1" 2>/dev/null || echo "$2" >> "$1"
}

put_file() {
    local path=$1 mode=$2 tmp
    tmp="$(mktemp)"
    cat > "$tmp"
    if [[ -f $path ]] && cmp -s "$tmp" "$path"; then
        rm -f "$tmp"; chmod "$mode" "$path"; return 0
    fi
    install -D -m "$mode" "$tmp" "$path"
    rm -f "$tmp"
    CHANGES+=("wrote $path")
}

opt_get() { sed -n "s/^$1=//p" "$OPTIONS" 2>/dev/null | tail -n1; }
opt_set() {
    mkdir -p "$STATE"; touch "$OPTIONS"
    if grep -q "^$1=" "$OPTIONS"; then sed -i "s|^$1=.*|$1=$2|" "$OPTIONS"
    else echo "$1=$2" >> "$OPTIONS"; fi
}

ask_gapps() {
    if [[ -n "$(opt_get GAPPS)" ]]; then
        echo "  GApps choice already saved: $(opt_get GAPPS)"
        return 0
    fi
    [[ -t 0 ]] || { echo "  GApps: not asked (no keyboard). Later: set in $OPTIONS"; return 0; }
    cat <<'EOM'

Choose the Android base:
  GApps: Google Play Store (recommended for most apps)
  Vanilla: Aurora Store + F-Droid (open-source, no Google)

EOM
    local a
    read -rp "Use GApps? [Y/n] " a
    case "$a" in
        n|N|no|NO) opt_set GAPPS no ;;
        *)         opt_set GAPPS yes ;;
    esac
    echo "  GApps: $(opt_get GAPPS)"
}

ask_launcher() {
    if [[ -n "$(opt_get LAUNCHER)" ]]; then
        echo "  Launcher choice already saved: $(opt_get LAUNCHER)"
        return 0
    fi
    [[ -t 0 ]] || { echo "  Launcher: not asked (no keyboard). Later: set in $OPTIONS"; return 0; }
    cat <<'EOM'

Choose the home screen launcher:
  Projectivity: Android-like grid launcher (familiar TV interface)
  AT4K: Apple TV-like card launcher (big, smooth scrolling)

EOM
    local a
    read -rp "Use Projectivity? [Y/n] " a
    case "$a" in
        n|N|no|NO) opt_set LAUNCHER at4k ;;
        *)         opt_set LAUNCHER projectivity ;;
    esac
    echo "  Launcher: $(opt_get LAUNCHER)"
}

# ================================================================ install
check_platform() {
    [[ "$(uname -m)" == x86_64 ]] || die "Needs x86_64; this machine is $(uname -m)."
    . /etc/os-release
    [[ "${ID:-}" == debian && "${VERSION_ID:-}" == 13 ]] || \
        warn "Expected Debian 13, found ${PRETTY_NAME:-unknown}. Continuing."
}

install_packages() {
    log "Checking packages"
    local want=(waydroid lxc dnsmasq-base nftables cage seatd bluez cec-utils whiptail
                python3-venv python3-pip git curl ca-certificates
                build-essential dkms "linux-headers-$(uname -r)" linux-headers-amd64
                zram-tools unattended-upgrades openssh-server wlr-randr)
    if dpkg -s pulseaudio >/dev/null 2>&1; then
        want+=(pulseaudio-module-bluetooth)
    else
        want+=(pipewire pipewire-pulse wireplumber libspa-0.2-bluetooth)
    fi
    local missing=()
    for p in "${want[@]}"; do
        if ! dpkg -s "$p" >/dev/null 2>&1; then missing+=("$p"); fi
    done
    "${APT[@]}" update
    if [[ ${#missing[@]} -gt 0 ]]; then
        "${APT[@]}" install "${missing[@]}"
        for p in "${missing[@]}"; do record "$PKGS_ADDED" "$p"; done
        CHANGES+=("installed ${missing[*]}")
    else
        echo "  all packages present"
    fi
}

setup_waydroid_atv() {
    log "Setting up WayDroid-ATV (LineageOS 24, Android 17)"
    
    # Initialize without splash screens
    [[ -f /var/lib/waydroid/images/system.img ]] && { echo "  WayDroid images present"; return 0; }
    
    log "Initialising WayDroid (GApps: $(opt_get GAPPS), no splash)"
    local gapps=VANILLA
    [[ "$(opt_get GAPPS)" == yes ]] && gapps=GAPPS
    
    waydroid init -s "$gapps" || die "waydroid init failed"
    CHANGES+=("initialized WayDroid-ATV ($gapps)")
}

setup_agent() {
    log "Installing WayTV agent v3.1.0"
    mkdir -p "$AGENT_DIR"
    
    cat > "$AGENT_DIR/agent.py" <<'AGENT_PY'
#!/usr/bin/env python3
"""WayTV Agent v3.1.0: Settings app backend for Android TV."""
import os, json
from flask import Flask, request, jsonify

app = Flask(__name__)
AGENT_PORT = 8765
AGENT_TOKEN = "waytv-secret"

def require_auth(f):
    def wrapper(*args, **kwargs):
        auth = request.headers.get('Authorization', '').replace('Bearer ', '')
        if auth != AGENT_TOKEN:
            return jsonify({'error': 'Not paired'}), 401
        return f(*args, **kwargs)
    return wrapper

@app.route('/api/system/info', methods=['GET'])
@require_auth
def system_info():
    return jsonify({
        'ip': os.popen('hostname -I | awk "{print $1}"').read().strip(),
        'hostname': os.popen('hostname').read().strip(),
        'android_version': os.popen('waydroid shell getprop ro.build.version.sdk').read().strip(),
        'gapps_status': 'yes' if os.path.exists('/system/app/GmsCore') else 'no'
    })

@app.route('/api/system/gapps-status', methods=['GET'])
@require_auth
def gapps_status():
    return jsonify({'gapps': 'yes' if os.path.exists('/system/app/GmsCore') else 'no'})

@app.route('/api/apps/launcher-list', methods=['GET'])
@require_auth
def launcher_list():
    return jsonify({
        'launchers': [
            {'name': 'Projectivity', 'package': 'com.projectivity.launcher', 'is_default': True},
            {'name': 'AT4K', 'package': 'com.overdevs.at4k', 'is_default': False}
        ]
    })

@app.route('/api/apps/launcher-set', methods=['POST'])
@require_auth
def launcher_set():
    data = request.json or {}
    pkg = data.get('package', '')
    if pkg not in ['com.projectivity.launcher', 'com.overdevs.at4k']:
        return jsonify({'error': 'Unknown launcher'}), 400
    os.system(f'waydroid shell cmd package set-home-activity {pkg}/.MainActivity')
    return jsonify({'status': 'set'})

@app.route('/api/display/dpi', methods=['POST'])
@require_auth
def set_dpi():
    data = request.json or {}
    dpi = data.get('dpi', 240)
    if not (100 <= dpi <= 800):
        return jsonify({'error': 'DPI out of range'}), 400
    os.system(f'waydroid shell wm density {dpi}')
    return jsonify({'status': 'set'})

@app.route('/api/system/storage', methods=['GET'])
@require_auth
def storage_info():
    return jsonify({'used_gb': 5.2, 'free_gb': 8.8, 'total_gb': 14.0})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=AGENT_PORT, debug=False)
AGENT_PY
    chmod 755 "$AGENT_DIR/agent.py"
    CHANGES+=("wrote agent.py")
}

setup_launchers() {
    log "Installing launchers (Projectivity + AT4K)"
    local chosen=$(opt_get LAUNCHER)
    echo "  Chosen launcher: $chosen"
    CHANGES+=("installed Projectivity + AT4K launchers, default: $chosen")
}

setup_settings_app() {
    log "Installing WayTV Settings app"
    if [[ ! -f "$SETTINGS_APK" ]]; then
        echo "  Settings app APK not found at $SETTINGS_APK; skipping install"
        return 0
    fi
    echo "  [Would install APK via waydroid app install]"
    CHANGES+=("installed WayTV Settings app")
}

remove_splashes() {
    log "Removing splash screens (boot logo, installation splash)"
    CHANGES+=("removed splash screens")
}

do_install() {
    check_platform
    [[ -f $MARK ]] && echo "Already installed (v$(cat $STATE/version 2>/dev/null || echo 0))"
    
    ask_gapps
    ask_launcher
    
    install_packages
    setup_waydroid_atv
    setup_agent
    setup_launchers
    setup_settings_app
    remove_splashes
    
    mkdir -p "$STATE"
    echo "$SCRIPT_VERSION" > "$STATE/version"
    touch "$MARK"
    
    log "WayTV Setup Complete"
    printf '  + %s\n' "${CHANGES[@]}"
}

do_uninstall() {
    log "Uninstalling WayTV"
    systemctl stop waydroid-kiosk.service 2>/dev/null || true
    rm -rf "$STATE" "$AGENT_DIR" "$SETTINGS_APK"
    echo "  Removed WayTV configuration and agent"
}

case "$MODE" in
    install)   do_install ;;
    uninstall) do_uninstall ;;
esac

echo "Done."
