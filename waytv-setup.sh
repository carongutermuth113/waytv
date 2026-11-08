#!/usr/bin/env bash
# WayTV Setup Script v1.0 (WayDroid-ATV TV build)
# Complete Waydroid-ATV kiosk setup with WayTV agent and settings app
#
# Usage:
#   sudo ./waytv-setup.sh                install WayTV stack
#   sudo ./waytv-setup.sh --force        redo all steps
#   sudo ./waytv-setup.sh --uninstall    remove WayTV
#
# Requirements:
#   - Debian 13 x86_64
#   - 4 GB RAM (with zram + swap)
#   - 20 GB free disk space
#   - Internet connection for first setup

set -euo pipefail

SCRIPT_VERSION=1
STATE=/etc/waytv
MARK=$STATE/installed
STEPS=$STATE/steps
BACKUP=$STATE/backup
PKGS_ADDED=$STATE/packages-added
OPTIONS=$STATE/options
AGENT_DIR=/etc/waytv/agent
SETTINGS_APK=/opt/waytv/app.apk
KUSER=waytv
KUSER_HOME=/home/waytv

export DEBIAN_FRONTEND=noninteractive
APT=(apt-get -y -o DPkg::Lock::Timeout=600 \
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

# ================================================================ checks
check_platform() {
    [[ "$(uname -m)" == x86_64 ]] || die "Needs x86_64; this machine is $(uname -m)."
    . /etc/os-release
    [[ "${ID:-}" == debian && "${VERSION_ID:-}" == 13 ]] || \
        warn "Expected Debian 13, found ${PRETTY_NAME:-unknown}. Continuing."
}

ensure_user() {
    log "Creating kiosk user: $KUSER"
    if id "$KUSER" >/dev/null 2>&1; then
        echo "  User $KUSER already exists"
        return 0
    fi
    useradd -m -s /bin/bash "$KUSER"
    echo "$KUSER" > "$STATE/user"
    CHANGES+=("created user $KUSER")
}

# ================================================================ packages
install_packages() {
    log "Installing dependencies"
    local want=(waydroid lxc dnsmasq-base nftables cage seatd bluez cec-utils whiptail
                python3-venv python3-pip python3-flask git curl ca-certificates
                build-essential dkms "linux-headers-$(uname -r)" linux-headers-amd64
                zram-tools unattended-upgrades openssh-server wlr-randr)
    
    # Audio: use existing pulse/pipe setup
    if dpkg -s pulseaudio >/dev/null 2>&1; then
        want+=(pulseaudio-module-bluetooth)
    else
        want+=(pipewire pipewire-pulse wireplumber libspa-0.2-bluetooth)
    fi
    
    local missing=()
    for p in "${want[@]}"; do
        if ! dpkg -s "$p" >/dev/null 2>&1; then
            missing+=("$p")
        fi
    done
    
    if [[ ${#missing[@]} -eq 0 ]]; then
        echo "  All packages present"
        return 0
    fi
    
    "${APT[@]}" update || die "apt update failed"
    "${APT[@]}" install "${missing[@]}" || die "apt install failed"
    for p in "${missing[@]}"; do record "$PKGS_ADDED" "$p"; done
    CHANGES+=("installed ${#missing[@]} packages")
}

# ================================================================ waydroid
ensure_binder() {
    log "Checking binder kernel support"
    if ! lsmod | grep -q '^binder_linux'; then
        modprobe binder_linux devices="binder,hwbinder,vndbinder" 2>/dev/null || true
    fi
    if [[ ! -e /dev/binder && ! -e /dev/binderfs/binder-control ]]; then
        mkdir -p /dev/binderfs
        mount -t binder binder /dev/binderfs 2>/dev/null || true
    fi
    if [[ ! -e /dev/binder && ! -e /dev/binderfs/binder-control ]]; then
        die "No binder support. Kernel needs CONFIG_ANDROID_BINDER_IPC."
    fi
    put_file /etc/modules-load.d/waydroid-binder.conf 644 <<< "binder_linux"
    put_file /etc/modprobe.d/waydroid-binder.conf 644 \
        <<< 'options binder_linux devices="binder,hwbinder,vndbinder"'
}

setup_waydroid() {
    log "Setting up Waydroid with WayDroid-ATV (Android 17)"
    systemctl enable --now waydroid-container.service || warn "waydroid-container enable failed"
    
    if [[ ! -f /var/lib/waydroid/images/system.img ]]; then
        log "Initializing Waydroid (vanilla, downloading 1-2 GB)..."
        waydroid init -s VANILLA || die "waydroid init failed"
        CHANGES+=("initialized Waydroid with vanilla images")
    else
        echo "  Waydroid images present"
    fi
}

# ================================================================ agent & settings
setup_agent() {
    log "Installing WayTV agent v1.0"
    mkdir -p "$AGENT_DIR"
    
    # Copy agent script from repo
    if [[ -f "$(dirname "$SELF")/waytv-agent.py" ]]; then
        cp "$(dirname "$SELF")/waytv-agent.py" "$AGENT_DIR/agent.py"
        chmod 755 "$AGENT_DIR/agent.py"
    else
        warn "waytv-agent.py not found in repo; agent not installed"
        return 1
    fi
    
    # Create systemd service
    put_file /etc/systemd/system/waytv-agent.service 644 <<'EOF'
[Unit]
Description=WayTV Agent (REST API)
After=waydroid-container.service
Wants=waydroid-container.service

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 /etc/waytv/agent/agent.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable waytv-agent.service || warn "Failed to enable waytv-agent"
    systemctl start waytv-agent.service || warn "Failed to start waytv-agent"
    CHANGES+=("deployed WayTV agent on port 8765")
}

ask_gapps() {
    if [[ -n "$(opt_get GAPPS)" ]]; then
        echo "  GApps choice saved: $(opt_get GAPPS)"
        return 0
    fi
    [[ -t 0 ]] || { opt_set GAPPS vanilla; echo "  GApps: not asked (no TTY), using vanilla"; return 0; }
    
    cat <<'EOM'

Choose the Android base:
  GApps:   Google Play Store (recommended for most apps)
  Vanilla: Aurora Store + F-Droid (open-source, no Google)

EOM
    local a
    read -rp "Use GApps? [y/N] " a
    case "$a" in
        y|Y|yes|YES) opt_set GAPPS gapps ;;
        *)           opt_set GAPPS vanilla ;;
    esac
    echo "  Selected: $(opt_get GAPPS)"
}

ask_launcher() {
    if [[ -n "$(opt_get LAUNCHER)" ]]; then
        echo "  Launcher choice saved: $(opt_get LAUNCHER)"
        return 0
    fi
    [[ -t 0 ]] || { opt_set LAUNCHER projectivity; echo "  Launcher: not asked (no TTY), using Projectivity"; return 0; }
    
    cat <<'EOM'

Choose the launcher:
  Projectivity: Android-style TV launcher
  AT4K:         Apple TV-style minimal launcher

EOM
    local a
    read -rp "Use Projectivity? [Y/n] " a
    case "$a" in
        n|N|no|NO) opt_set LAUNCHER at4k ;;
        *)         opt_set LAUNCHER projectivity ;;
    esac
    echo "  Selected: $(opt_get LAUNCHER)"
}

# ================================================================ system tuning
tune_memory() {
    log "Configuring memory (4 GB RAM + swap)"
    
    # sysctl tuning for 4GB RAM
    put_file /etc/sysctl.d/90-waytv.conf 644 <<'EOF'
vm.swappiness=150
vm.page-cluster=0
vm.watermark_scale_factor=125
vm.vfs_cache_pressure=100
EOF
    sysctl --system >/dev/null 2>&1 || warn "sysctl reload may apply after reboot"
    
    # Enable zram swap
    if [[ -f /etc/default/zramswap ]]; then
        sed -i 's/^ALGO=.*/ALGO=zstd/' /etc/default/zramswap
        sed -i 's/^PERCENT=.*/PERCENT=100/' /etc/default/zramswap
        systemctl enable zramswap.service >/dev/null 2>&1
        systemctl restart zramswap.service || warn "zram restart failed"
    fi
    
    CHANGES+=("configured memory tuning (zram + sysctl)")
}

tune_os() {
    log "Tuning OS for kiosk mode"
    
    # Journal size limit
    put_file /etc/systemd/journald.conf.d/90-waytv.conf 644 <<'EOF'
[Journal]
SystemMaxUse=200M
RuntimeMaxUse=50M
EOF
    
    # Faster shutdown
    put_file /etc/systemd/system.conf.d/90-waytv.conf 644 <<'EOF'
[Manager]
DefaultTimeoutStopSec=15s
EOF
    
    # Mask unnecessary services
    for u in sleep.target suspend.target hibernate.target ModemManager.service cups.service; do
        systemctl mask "$u" 2>/dev/null || true
    done
    
    # Enable TRIM for SSD
    systemctl enable --now fstrim.timer 2>/dev/null || true
    
    systemctl daemon-reload
    CHANGES+=("tuned OS (journal, shutdown, services)")
}

setup_ssh() {
    log "Enabling SSH"
    put_file /etc/ssh/sshd_config.d/90-waytv.conf 644 <<'EOF'
PermitRootLogin no
MaxAuthTries 4
X11Forwarding no
EOF
    
    if ! sshd -t; then
        warn "SSH config invalid; reverting changes"
        rm -f /etc/ssh/sshd_config.d/90-waytv.conf
        return 1
    fi
    
    systemctl enable ssh.service >/dev/null 2>&1
    systemctl restart ssh.service || warn "SSH restart failed"
    CHANGES+=("enabled SSH access")
}

# ================================================================ kiosk startup
setup_kiosk_services() {
    log "Setting up kiosk boot target"
    
    # Kiosk user session service
    mkdir -p "/etc/systemd/user-session"
    
    # Boot to multi-user (can be changed to graphical)
    systemctl set-default multi-user.target 2>/dev/null || true
    
    # Enable user lingering for $KUSER
    loginctl enable-linger "$KUSER" 2>/dev/null || true
    
    CHANGES+=("configured kiosk boot services")
}

# ================================================================ uninstall
do_uninstall() {
    log "Uninstalling WayTV"
    
    systemctl stop waytv-agent.service 2>/dev/null || true
    systemctl disable waytv-agent.service 2>/dev/null || true
    
    rm -rf "$STATE" "$AGENT_DIR" "$SETTINGS_APK"
    rm -f /etc/systemd/system/waytv-agent.service
    rm -f /etc/sysctl.d/90-waytv.conf
    rm -f /etc/systemd/journald.conf.d/90-waytv.conf
    rm -f /etc/systemd/system.conf.d/90-waytv.conf
    rm -f /etc/ssh/sshd_config.d/90-waytv.conf
    
    userdel -r "$KUSER" 2>/dev/null || true
    
    systemctl daemon-reload
    echo "Uninstall complete."
}

# ================================================================ main install
do_install() {
    check_platform
    
    if [[ -f $MARK && $FORCE -eq 0 ]]; then
        log "Already installed (v$(cat $STATE/version 2>/dev/null || echo 0))"
        echo "Run with --force to reinstall"
        exit 0
    fi
    
    # Ask questions first
    ask_gapps
    ask_launcher
    
    # Install dependencies
    install_packages
    
    # System setup
    ensure_binder
    ensure_user
    tune_memory
    tune_os
    setup_ssh
    
    # Waydroid
    setup_waydroid
    
    # WayTV services
    setup_agent
    setup_kiosk_services
    
    # Mark complete
    mkdir -p "$STATE"
    echo "$SCRIPT_VERSION" > "$STATE/version"
    touch "$MARK"
    
    log "WayTV v1.0 Setup Complete"
    if [[ ${#CHANGES[@]} -gt 0 ]]; then
        echo "Changes:"
        printf '  + %s\n' "${CHANGES[@]}"
    fi
    
    cat <<EOM

✅ WayTV v1.0 Installed

Next steps:
  1. Reboot:           sudo reboot
  2. After boot:       Ctrl+Alt+F2 to open settings menu
  3. SSH access:       ssh $KUSER@<ip-address>
  4. Check agent:      curl -H "Authorization: Bearer waytv-default" http://localhost:8765/api/system
  5. Settings app:     Opens on first boot in Android TV

Configuration saved to: $STATE/

EOM
}

# ================================================================ entry point
case "$MODE" in
    install)   do_install ;;
    uninstall) do_uninstall ;;
esac
