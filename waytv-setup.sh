#!/usr/bin/env bash
# WayTV Waydroid kiosk for Debian 13 x86_64: boots straight into Waydroid
# fullscreen (cage, no desktop environment), tunes the OS for kiosk use,
# keeps Debian + Android updated, enables SSH, updates itself from GitHub, and
# shows update notifications inside Android. Settings menu on Ctrl+Alt+F2.
#
#   sudo ./waytv-setup.sh                    install; if already installed, add only what is new
#   sudo ./waytv-setup.sh --no-upgrade       same, but skip the Debian/Android upgrade
#   sudo ./waytv-setup.sh --force            redo every step, even ones already done
#   sudo ./waytv-setup.sh --aurora           install Aurora Store without asking
#   sudo ./waytv-setup.sh --no-aurora        do not install Aurora Store, do not ask
#   sudo ./waytv-setup.sh --uninstall        remove everything this script added
#   sudo ./waytv-setup.sh --uninstall --yes  same, without the confirmation prompt
#
# Tested on a CN60 mini PC (Intel Celeron 2955U, 4 GB RAM). Other x86_64 boxes: should work, untested.
# Self-contained: writes the settings menu and updater to /usr/local/bin.

set -euo pipefail

SCRIPT_VERSION=19              # bump when the script changes
STATE=/etc/waytv
MARK=$STATE/installed          # present once a full install finished
STEPS=$STATE/steps             # one file per one-time step, holding the step version
BACKUP=$STATE/backup           # originals of system files this script edits
PKGS_ADDED=$STATE/packages-added
GROUPS_ADDED=$STATE/groups-added
MASKED=$STATE/masked           # units this script masked
DISABLED=$STATE/disabled       # units this script disabled
ENABLED=$STATE/enabled         # units this script enabled (besides its own)
USER_FILE=$STATE/user
OPTIONS=$STATE/options         # answers to install questions (asked once)
export DEBIAN_FRONTEND=noninteractive
APT=(apt-get -y -o DPkg::Lock::Timeout=600
     -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
MODE=install
ASSUME_YES=0
FORCE=0
UPGRADE=1
AURORA_FLAG=""
for arg in "$@"; do
    case "$arg" in
        --uninstall)  MODE=uninstall ;;
        --yes)        ASSUME_YES=1 ;;
        --force)      FORCE=1 ;;
        --no-upgrade) UPGRADE=0 ;;
        --aurora)     AURORA_FLAG=yes ;;
        --no-aurora)  AURORA_FLAG=no ;;
        -h|--help)    awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
        *)            die "Unknown option: $arg" ;;
    esac
done

# Re-run as root, keeping the invoking user so Waydroid can run as them.
if [[ $EUID -ne 0 ]]; then
    command -v sudo >/dev/null || die "Run as root (sudo)."
    exec sudo -E bash "$0" "$@"
fi

# ---- Move an install made by the old CN60 script (cn60-waydroid-setup.sh) to WayTV.
# Same steps and records, new names: /etc/cn60 -> /etc/waytv, cn60-* -> waytv-*.
MIGRATED=""
migrate_from_cn60() {
    [[ $MODE == install && -d /etc/cn60 && ! -e $STATE ]] || return 0
    log "Moving the existing CN60 kiosk install to WayTV"
    local u old new
    for u in cn60-check.timer cn60-update.timer cn60-perf.service; do
        systemctl is-enabled -q "$u" 2>/dev/null && MIGRATED+=" ${u/cn60-/waytv-}"
    done
    systemctl disable --now cn60-check.timer cn60-update.timer cn60-perf.service 2>/dev/null || true
    mv /etc/cn60 "$STATE"
    # Self-update now follows the WayTV repo (the old one is kept as it is).
    [[ -f $STATE/update.conf ]] && sed -i \
        -e 's|^REPO=carongutermuth113/cn60-waydroid-kiosk$|REPO=carongutermuth113/waytv|' \
        -e 's/CN60/WayTV/g; s/cn60/waytv/g' "$STATE/update.conf"
    # Settings files keep their content, only the name changes; one-time steps need not rerun.
    for old in /etc/systemd/journald.conf.d/90-cn60.conf /etc/systemd/system.conf.d/90-cn60.conf \
               /etc/sysctl.d/90-cn60.conf /etc/ssh/sshd_config.d/90-cn60.conf \
               /etc/apt/apt.conf.d/52cn60-unattended \
               /etc/wireplumber/wireplumber.conf.d/80-cn60-bluetooth.conf \
               /etc/systemd/system/waydroid-container.service.d/90-cn60.conf \
               /var/log/cn60-crash-report.txt; do
        new=${old//cn60/waytv}
        [[ -e $old ]] && mv -f "$old" "$new" && sed -i 's/CN60/WayTV/g; s/cn60/waytv/g' "$new"
    done
    # Backup markers ("this file did not exist") must follow the renamed files for uninstall.
    if [[ -d $STATE/backup ]]; then
        while IFS= read -r old; do
            mkdir -p "$(dirname "${old//cn60/waytv}")"
            mv -f "$old" "${old//cn60/waytv}"
        done < <(find "$STATE/backup" -path '*cn60*' -type f)
    fi
    rm -f /usr/local/bin/cn60-* /etc/systemd/system/cn60-*.service /etc/systemd/system/cn60-*.timer \
          /etc/update-motd.d/90-cn60
    rm -rf /usr/local/lib/cn60 /var/lib/cn60
    rm -f /var/lib/systemd/timers/stamp-cn60-*.timer
    systemctl daemon-reload
    MIGRATED=${MIGRATED:- none}
}
migrate_from_cn60

KUSER="${SUDO_USER:-}"
if [[ -z "$KUSER" || "$KUSER" == root ]]; then
    [[ -r $USER_FILE ]] && KUSER="$(cat "$USER_FILE")"
fi
[[ -n "$KUSER" && "$KUSER" != root ]] || \
    die "Run with sudo from your normal user account, not from a root login."
id "$KUSER" >/dev/null 2>&1 || die "User '$KUSER' does not exist."

CHANGES=()                     # what this run added or changed, printed at the end

# ------------------------------------------------------------------ helpers
# record <file> <line>: append a line once (state lists used by uninstall).
record() {
    mkdir -p "$STATE"
    grep -qxF -- "$2" "$1" 2>/dev/null || echo "$2" >> "$1"
}

# backup_once <path>: keep the original of a system file before the first edit.
backup_once() {
    local b="$BACKUP$1"
    [[ -e $b || -e $b.absent ]] && return 0
    mkdir -p "$(dirname "$b")"
    if [[ -e $1 ]]; then cp -a "$1" "$b"; else touch "$b.absent"; fi
}

# put_file <path> <mode> [backup]: write stdin to path only if the content changed.
put_file() {
    local path=$1 mode=$2 tmp
    tmp="$(mktemp)"
    cat > "$tmp"
    if [[ -f $path ]] && cmp -s "$tmp" "$path"; then
        rm -f "$tmp"; chmod "$mode" "$path"; return 0
    fi
    [[ ${3:-} == backup ]] && backup_once "$path"
    # Write next to the target, then rename: scripts that are running keep reading the old copy.
    install -D -m "$mode" "$tmp" "$path.waytvnew"
    mv -f "$path.waytvnew" "$path"
    rm -f "$tmp"
    CHANGES+=("wrote $path")
}

# set_kv <file> <key> <value>: set KEY=value, uncommenting or appending as needed.
set_kv() {
    if grep -qE "^#?[[:space:]]*$2=" "$1"; then
        sed -i -E "s|^#?[[:space:]]*$2=.*|$2=$3|" "$1"
    else
        echo "$2=$3" >> "$1"
    fi
}

# Install questions: asked once, answer kept in /etc/waytv/options.
opt_get() { sed -n "s/^$1=//p" "$OPTIONS" 2>/dev/null | tail -n1; }
opt_set() {
    mkdir -p "$STATE"; touch "$OPTIONS"
    if grep -q "^$1=" "$OPTIONS"; then sed -i "s|^$1=.*|$1=$2|" "$OPTIONS"
    else echo "$1=$2" >> "$OPTIONS"; fi
}

ask_options() {
    [[ -n $AURORA_FLAG ]] && opt_set AURORA_STORE "$AURORA_FLAG"
    if [[ -z "$(opt_get AURORA_STORE)" ]]; then
        if [[ -t 0 && $ASSUME_YES -eq 0 ]]; then
            cat <<'EOM'

Aurora Store is an open-source app store that downloads apps from Google Play
without Google's own apps. You can sign in anonymously. Apps that need Google
Play Services (some games, banking, Google apps) may not work.
EOM
            local a
            read -rp "Install Aurora Store in Android? [Y/n] " a
            case "$a" in
                n|N|no|NO) opt_set AURORA_STORE no ;;
                *)         opt_set AURORA_STORE yes ;;
            esac
            CHANGES+=("Aurora Store: $(opt_get AURORA_STORE)")
        else
            echo "  Aurora Store: not asked (no keyboard on this run). Later: sudo waytv-apps aurora"
        fi
    fi
}

unit_state() { systemctl is-enabled "$1" 2>/dev/null || true; }
unit_exists() { [[ -n "$(systemctl list-unit-files "$1" --no-legend 2>/dev/null)" ]]; }

# run_step <name> <version> <function>: one-time steps; rerun only when the version changes.
run_step() {
    local name=$1 ver=$2 fn=$3
    if [[ $FORCE -eq 0 && -f $STEPS/$name && "$(cat "$STEPS/$name")" == "$ver" ]]; then
        echo "  $name: already done (v$ver)"
        return 0
    fi
    if "$fn"; then
        mkdir -p "$STEPS"; echo "$ver" > "$STEPS/$name"
        CHANGES+=("step $name v$ver")
    else
        warn "$name did not finish; it will be retried next run."
    fi
}

check_platform() {
    [[ "$(uname -m)" == x86_64 ]] || die "Needs x86_64; this machine is $(uname -m)."
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${ID:-}" == debian && "${VERSION_ID:-}" == 13 ]] || \
        warn "Expected Debian 13, found ${PRETTY_NAME:-unknown}. Continuing."
}

# ---- Hardware check (always): compare with the minimum/recommended specs (README) and
# pick the tuning profile. LOW_RESOURCES=1 turns on the low-memory optimizations.
#   minimum:     2 CPU cores, 4 GB RAM, 16 GB free disk, Intel/AMD GPU with Mesa drivers
#   recommended: 4 CPU cores, 8 GB RAM, SSD with 32 GB free, Intel UHD 600+/AMD Vega or newer
LOW_RESOURCES=0
check_resources() {
    local ram_mb cores disk_gb cpu gpu drv below=() low=() line
    log "🔧 Checking the hardware"
    ram_mb=$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)
    cores=$(nproc)
    disk_gb=$(df --output=avail -BG / 2>/dev/null | tail -n1 | tr -dc 0-9)
    cpu=$(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo | head -n1)
    drv=$(basename "$(readlink -f /sys/class/drm/card0/device/driver 2>/dev/null)" 2>/dev/null)
    gpu=$(lspci 2>/dev/null | sed -n 's/^.*\(VGA compatible controller\|Display controller\|3D controller\): //p' | head -n1)

    # 4 GB boxes report about 3.7 GB, so the thresholds sit a little lower.
    (( ram_mb < 3400 )) && below+=("RAM: $((ram_mb / 1024)).$(( ram_mb % 1024 * 10 / 1024 )) GB (minimum 4 GB)")
    (( cores < 2 )) && below+=("CPU: $cores core (minimum 2)")
    [[ ! -e $MARK ]] && (( ${disk_gb:-0} < 16 )) && below+=("Disk: ${disk_gb:-?} GB free (minimum 16 GB)")
    case "$drv" in
        i915|xe|amdgpu|radeon|virtio-pci|virtio_gpu) ;;
        nvidia*) below+=("GPU: NVIDIA's driver ($drv) does not work with Waydroid; use an Intel or AMD GPU") ;;
        "") below+=("GPU: no graphics driver found (/dev/dri missing)") ;;
        *) warn "GPU driver '$drv' is untested with Waydroid; Android may not start." ;;
    esac
    (( ram_mb < 7000 )) && low+=("RAM under 8 GB")
    (( cores < 4 )) && low+=("fewer than 4 CPU cores")

    echo "  CPU:  ${cpu:-unknown} ($cores cores)"
    echo "  RAM:  $((ram_mb / 1024)).$(( ram_mb % 1024 * 10 / 1024 )) GB"
    echo "  GPU:  ${gpu:-unknown} (driver: ${drv:-none})"
    echo "  Disk: ${disk_gb:-?} GB free on /"
    if (( ${#below[@]} )); then
        echo
        echo "  !!! BELOW THE MINIMUM SPECS - Android may be very slow or not start:"
        for line in "${below[@]}"; do echo "  !!!   - $line"; done
        echo "  !!! Continuing anyway; see 'Requirements' in the README."
    fi
    if (( ${#below[@]} || ${#low[@]} )); then
        LOW_RESOURCES=1
        echo
        local why
        why=$(IFS=,; echo "${low[*]:-below minimum}"); why=${why//,/, }
        echo "  *** LOW RESOURCES DETECTED ($why): applying optimizations:"
        echo "  ***   - compressed RAM swap (zram) at 100% of RAM + a ${SWAP_GB} GB swap file on disk"
        echo "  ***   - memory settings that swap idle apps instead of closing them"
        echo "  ***   - Android and the kiosk protected from the out-of-memory killer"
        echo "  ***   - 1080p at 60 Hz by default (4K costs a lot of GPU and memory)"
    else
        echo "  Hardware meets the recommended specs: standard tuning (zram at 50%, no swap file)."
    fi
    mkdir -p "$STATE"
    printf 'RAM_MB=%s\nCORES=%s\nGPU_DRIVER=%s\nLOW_RESOURCES=%s\n' \
        "$ram_mb" "$cores" "${drv:-none}" "$LOW_RESOURCES" > "$STATE/hardware"
}

# ---------------------------------------------------------------- uninstall
do_uninstall() {
    if [[ $ASSUME_YES -eq 0 ]]; then
        [[ -t 0 ]] || die "Non-interactive uninstall needs --yes."
        echo "This removes the kiosk, Waydroid and its data (/var/lib/waydroid, ~$KUSER/.local/share/waydroid),"
        echo "the OS tweaks and auto-updates, the packages this script added, and group memberships it added."
        echo "If this script installed SSH it is removed too: run this from the box, not over SSH."
        read -rp "Type UNINSTALL to continue: " confirm
        [[ "$confirm" == UNINSTALL ]] || die "Cancelled."
    fi

    log "⏹️  Stopping the kiosk and returning to a normal boot"
    systemctl disable --now waydroid-kiosk.service waytv-update.timer waytv-check.timer waytv-perf.service waytv-agent.service 2>/dev/null || true
    systemctl set-default multi-user.target
    runuser -u "$KUSER" -- waydroid session stop >/dev/null 2>&1 || true
    systemctl disable --now waydroid-container.service 2>/dev/null || true

    log "Removing systemd units and helper scripts"
    rm -f /etc/systemd/system/waydroid-kiosk.service \
          /etc/systemd/system/waytv-fallback.service \
          /etc/systemd/system/graphical-kiosk.target \
          /etc/systemd/system/waytv-update.service \
          /etc/systemd/system/waytv-update.timer \
          /etc/systemd/system/waytv-check.service \
          /etc/systemd/system/waytv-check.timer \
          /etc/systemd/system/waytv-perf.service \
          /etc/systemd/system/waytv-agent.service
    rm -f /usr/local/bin/waytv-kiosk-start /usr/local/bin/waytv-kiosk-user \
          /usr/local/bin/waytv-settings /usr/local/bin/waytv-update \
          /usr/local/bin/waytv-check /usr/local/bin/waytv-remote /usr/local/bin/waytv-apps \
          /usr/local/bin/waytv-crashlog /usr/local/bin/waytv-tweaks /usr/local/bin/waytv-perf /usr/local/bin/waytv-agent /etc/update-motd.d/90-waytv
    rm -rf /usr/local/lib/waytv /var/lib/waytv /etc/systemd/system/waydroid-container.service.d/90-waytv.conf

    log "Reverting OS tweaks"
    if [[ -r $STATE/swapfile ]]; then
        local sf
        sf="$(cat "$STATE/swapfile")"
        if [[ -n $sf ]]; then
            swapoff "$sf" 2>/dev/null || warn "Could not turn off $sf (not enough free RAM?); it is removed after reboot."
            sed -i "\|^${sf}[[:space:]]|d" /etc/fstab
            rm -f "$sf"
        fi
    fi
    rm -f /etc/sysctl.d/90-waytv.conf \
          /etc/systemd/journald.conf.d/90-waytv.conf \
          /etc/systemd/system.conf.d/90-waytv.conf \
          /etc/apt/apt.conf.d/52waytv-unattended \
          /etc/ssh/sshd_config.d/90-waytv.conf \
          /etc/wireplumber/wireplumber.conf.d/80-waytv-bluetooth.conf
    [[ -r $MASKED ]]   && while read -r u; do [[ -n $u ]] && systemctl unmask "$u" 2>/dev/null || true; done < "$MASKED"
    [[ -r $DISABLED ]] && while read -r u; do [[ -n $u ]] && systemctl enable "$u" 2>/dev/null || true; done < "$DISABLED"
    [[ -r $ENABLED ]]  && while read -r u; do [[ -n $u ]] && systemctl disable "$u" 2>/dev/null || true; done < "$ENABLED"
    if [[ -d $BACKUP ]]; then
        while IFS= read -r b; do
            local target=${b#"$BACKUP"}
            if [[ $target == *.absent ]]; then rm -f "${target%.absent}"
            else cp -a "$b" "$target"; fi
        done < <(find "$BACKUP" -type f)
        [[ -e $BACKUP/etc/default/grub ]] && { update-grub || warn "update-grub failed."; }
    fi
    systemctl daemon-reload

    log "Removing Waydroid data, ARM translation and WayTV config"
    rm -rf /var/lib/waydroid "/home/$KUSER/.local/share/waydroid" \
           "/home/$KUSER/.share/waydroid" /opt/waydroid_script
    rm -f /etc/modules-load.d/waydroid-binder.conf /etc/modprobe.d/waydroid-binder.conf
    loginctl disable-linger "$KUSER" 2>/dev/null || true

    log "Removing group memberships this script added"
    if [[ -r $GROUPS_ADDED ]]; then
        while read -r user group; do
            [[ -n "${user:-}" ]] && gpasswd -d "$user" "$group" >/dev/null 2>&1 || true
        done < "$GROUPS_ADDED"
    fi

    log "Purging packages this script installed (packages that were already present are kept)"
    if [[ -r $PKGS_ADDED ]]; then
        # shellcheck disable=SC2046
        "${APT[@]}" purge $(cat "$PKGS_ADDED") || warn "Some packages failed to purge."
        "${APT[@]}" autoremove || true
    fi

    rm -rf "$STATE"
    echo
    echo "Uninstall complete. Reboot now: sudo reboot"
    exit 0
}

# ------------------------------------------------------------------ install
install_packages() {
    log "📦 Checking packages (installs only what is missing)"
    local want=(waydroid lxc dnsmasq-base nftables cage seatd bluez cec-utils whiptail
                python3-venv python3-pip git curl ca-certificates
                build-essential dkms "linux-headers-$(uname -r)" linux-headers-amd64
                zram-tools unattended-upgrades openssh-server wlr-randr)
    # Sound for Android (HDMI and Bluetooth headphones/speakers) goes through the host's audio server.
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

ensure_user_groups() {
    log "Checking $KUSER's device groups"
    local seat_group=seat
    getent group _seatd >/dev/null && seat_group=_seatd
    for g in video render input "$seat_group"; do
        getent group "$g" >/dev/null || continue
        if ! id -nG "$KUSER" | tr ' ' '\n' | grep -qx "$g"; then
            usermod -aG "$g" "$KUSER"
            record "$GROUPS_ADDED" "$KUSER $g"
            CHANGES+=("added $KUSER to $g")
        fi
    done
    # Keeps /run/user/<uid> alive so Waydroid's session bus exists at boot.
    loginctl enable-linger "$KUSER"
}

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
        die "No binder support in this kernel (CONFIG_ANDROID_BINDER_IPC missing). Waydroid cannot run on this box."
    fi
    put_file /etc/modules-load.d/waydroid-binder.conf 644 <<< "binder_linux"
    put_file /etc/modprobe.d/waydroid-binder.conf 644 \
        <<< 'options binder_linux devices="binder,hwbinder,vndbinder"'
}

write_config() {
    # display.conf is written only when missing, so re-running never overwrites a user's choice.
    mkdir -p "$STATE"
    echo "$KUSER" > "$USER_FILE"
    if [[ ! -f $STATE/display.conf ]]; then
        printf 'WIDTH=1920\nHEIGHT=1080\n' > "$STATE/display.conf"
        CHANGES+=("created $STATE/display.conf (1920x1080)")
    fi
    chmod 644 "$STATE/display.conf"
    # update.conf is also written only when missing (it may hold a GitHub token, so root-only).
    if [[ ! -f $STATE/update.conf ]]; then
        cat > "$STATE/update.conf" <<'EOF'
# WayTV self-update settings (read by waytv-check and waytv-update)
# GitHub repo and branch that hold waytv-setup.sh
REPO=carongutermuth113/waytv
BRANCH=main
# Read-only token, needed only while the repo is private (fine-grained, Contents: Read-only)
GITHUB_TOKEN=
# yes = the weekly update installs new script versions automatically; no = only notify
AUTO_APPLY_SCRIPT=yes
# yes = show update notifications inside Android
NOTIFY=yes
EOF
        CHANGES+=("created $STATE/update.conf")
    fi
    chmod 600 "$STATE/update.conf"
}

upgrade_debian() {
    log "Upgrading Debian packages"
    "${APT[@]}" full-upgrade || { warn "Debian upgrade failed; continuing."; return 0; }
    "${APT[@]}" autoremove --purge || true
    "${APT[@]}" autoclean || true
}

# ---- OS tuning (one-time step; bump its version in do_install when it changes)
tune_os() {
    log "Tuning the OS for kiosk use"
    # Memory (sysctl, zram, swap file) is handled by tune_memory, which runs every time.

    # Logs: cap the journal so the disk does not fill up over months.
    put_file /etc/systemd/journald.conf.d/90-waytv.conf 644 <<'EOF'
[Journal]
SystemMaxUse=200M
RuntimeMaxUse=50M
EOF
    systemctl restart systemd-journald || true

    # Faster shutdown/reboot when a service hangs.
    put_file /etc/systemd/system.conf.d/90-waytv.conf 644 <<'EOF'
[Manager]
DefaultTimeoutStopSec=15s
EOF

    # Never suspend or hibernate; don't wait for the network at boot.
    local u
    for u in sleep.target suspend.target hibernate.target hybrid-sleep.target \
             NetworkManager-wait-online.service systemd-networkd-wait-online.service; do
        unit_exists "$u" || continue
        [[ "$(unit_state "$u")" == masked ]] && continue
        systemctl mask "$u" >/dev/null 2>&1 && record "$MASKED" "$u"
    done

    # Services a TV box does not need.
    for u in ModemManager.service cups.service cups-browsed.service; do
        [[ "$(unit_state "$u")" == enabled ]] || continue
        systemctl disable --now "$u" >/dev/null 2>&1 && record "$DISABLED" "$u"
    done

    # Weekly SSD/eMMC TRIM.
    if unit_exists fstrim.timer && [[ "$(unit_state fstrim.timer)" != enabled ]]; then
        systemctl enable --now fstrim.timer >/dev/null 2>&1 && record "$ENABLED" fstrim.timer
    fi

    # Boot: 1 s GRUB menu, quiet boot, no console blanking.
    if [[ -f /etc/default/grub ]] && command -v update-grub >/dev/null; then
        backup_once /etc/default/grub
        local f=/etc/default/grub cur new p key
        set_kv "$f" GRUB_TIMEOUT 1
        cur="$(sed -n 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"$/\1/p' "$f" | tail -n1)"
        new="$cur"
        for p in quiet loglevel=3 consoleblank=0; do
            key=${p%%=*}
            if ! printf ' %s ' "$new" | grep -qE " $key(=| )"; then new="${new:+$new }$p"; fi
        done
        if [[ "$new" != "$cur" ]] || ! grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$f"; then
            new="$(printf '%s' "$new" | sed 's/[&|\\]/\\&/g')"
            if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$f"; then
                sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$new\"|" "$f"
            else
                echo "GRUB_CMDLINE_LINUX_DEFAULT=\"$new\"" >> "$f"
            fi
        fi
        update-grub || warn "update-grub failed; boot settings unchanged."
    else
        warn "GRUB not found; skipping boot tweaks."
    fi
    systemctl daemon-reload
    return 0
}

# ---- Network clash fix (one-time step)
# Waydroid runs its own bridge (waydroid0) with its own dnsmasq. The system-wide dnsmasq
# daemon and LXC's default bridge (lxc-net, lxcbr0) are not needed. They fight over
# port 53, so lxc-net fails at boot ("Failed to start lxc-net.service").
fix_network_clash() {
    log "Disabling dnsmasq.service and lxc-net.service (Waydroid does not use them)"
    local u
    for u in dnsmasq.service lxc-net.service; do
        unit_exists "$u" || continue
        case "$(unit_state "$u")" in
            enabled|enabled-runtime)
                systemctl disable --now "$u" >/dev/null 2>&1 && record "$DISABLED" "$u" ;;
            *)  systemctl stop "$u" >/dev/null 2>&1 || true ;;
        esac
        systemctl reset-failed "$u" >/dev/null 2>&1 || true
    done
    # Remove a leftover lxcbr0 bridge so it cannot hold the address range.
    ip link show lxcbr0 >/dev/null 2>&1 && ip link delete lxcbr0 2>/dev/null || true
    systemctl restart waydroid-container.service || warn "waydroid-container did not restart."
    return 0
}

# ---- Bluetooth audio fix (one-time step)
# WirePlumber only offers Bluetooth audio to a user that has an active logind seat session.
# The kiosk runs without one, so headphones/speakers fail with
# "br-connection-profile-unavailable". Turn seat monitoring off for Bluetooth.
fix_bt_audio() {
    log "Allowing Bluetooth audio without a desktop login (WirePlumber)"
    put_file /etc/wireplumber/wireplumber.conf.d/80-waytv-bluetooth.conf 644 <<'EOF'
# WayTV kiosk: Bluetooth audio without a logind seat session (removed on uninstall)
wireplumber.profiles = {
  main = {
    monitor.bluez.seat-monitoring = disabled
  }
}
EOF
    systemctl --user -M "$KUSER@" restart wireplumber.service pipewire-pulse.service >/dev/null 2>&1 \
        || echo "  WirePlumber restarts with the next kiosk restart or reboot."
    return 0
}

# ---- Self-update checks + Android notifications (one-time step)
setup_self_update() {
    log "Turning on daily update checks (new script version on GitHub, Debian updates)"
    systemctl daemon-reload
    systemctl enable --now waytv-check.timer || { warn "Could not enable waytv-check.timer."; return 1; }
}

# ---- SSH remote access (one-time step)
setup_ssh() {
    log "Setting up SSH remote access"
    put_file /etc/ssh/sshd_config.d/90-waytv.conf 644 <<'EOF'
# WayTV: SSH for normal users only (removed by waytv-setup.sh --uninstall)
PermitRootLogin no
MaxAuthTries 4
X11Forwarding no
EOF
    if ! sshd -t; then
        warn "SSH config test failed; removing the WayTV SSH settings."
        rm -f /etc/ssh/sshd_config.d/90-waytv.conf
        return 1
    fi
    if [[ "$(unit_state ssh.service)" != enabled ]]; then
        systemctl enable ssh.service >/dev/null 2>&1 && record "$ENABLED" ssh.service
    fi
    systemctl restart ssh.service || { warn "SSH did not start: journalctl -u ssh -b"; return 1; }
}

# ---- Automatic updates (one-time step)
setup_auto_updates() {
    log "Turning on automatic updates"
    # Daily: Debian security/stable updates through unattended-upgrades. Never auto-reboots.
    put_file /etc/apt/apt.conf.d/20auto-upgrades 644 backup <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
    put_file /etc/apt/apt.conf.d/52waytv-unattended 644 <<'EOF'
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF
    # Weekly: full upgrade + Android image via waytv-update (timer written in write_helpers).
    systemctl daemon-reload
    systemctl enable --now waytv-update.timer || { warn "Could not enable waytv-update.timer."; return 1; }
}

setup_waydroid() {
    log "🤖 Checking the Waydroid container"
    systemctl enable --now waydroid-container.service
    if [[ ! -f /var/lib/waydroid/images/system.img ]]; then
        log "Initialising Waydroid (vanilla, no GApps; downloads 1-2 GB)"
        waydroid init -s VANILLA || die "waydroid init failed; fix the error above and re-run."
        CHANGES+=("initialised Waydroid")
    else
        echo "  Waydroid images present"
    fi
}

# stop_android: stop the kiosk and the Android session before changing the Android image.
# do_install restarts the kiosk at the end if it was running when the script started.
stop_android() {
    systemctl stop waydroid-kiosk.service 2>/dev/null || true
    runuser -u "$KUSER" -- waydroid session stop >/dev/null 2>&1 || true
}

# ---- ARM translation (one-time step)
# Most Play Store apps ship ARM code only. Intel CPUs run it best with Intel's
# libhoudini; libndk (used up to script v10) suits AMD and makes many apps crash on Intel.
install_arm_translation() {
    local arm=libndk arm_old=libhoudini py=/opt/waydroid_script/venv/bin/python3
    if grep -q GenuineIntel /proc/cpuinfo; then arm=libhoudini; arm_old=libndk; fi
    log "💪 Installing ARM translation ($arm) for ARM-only apps (third-party project)"
    if [[ ! -d /opt/waydroid_script/venv ]]; then
        rm -rf /opt/waydroid_script
        git clone --depth 1 https://github.com/casualsnek/waydroid_script /opt/waydroid_script \
            || { warn "Could not clone waydroid_script; ARM apps unavailable."; return 1; }
        python3 -m venv /opt/waydroid_script/venv || return 1
    else
        git -C /opt/waydroid_script pull -q --ff-only || warn "Could not update waydroid_script; using the old copy."
    fi
    /opt/waydroid_script/venv/bin/pip install -q -r /opt/waydroid_script/requirements.txt \
        || { warn "pip install for waydroid_script failed; ARM apps unavailable."; return 1; }
    stop_android
    # Only one translator may be installed; remove the other one (harmless if it is absent).
    (cd /opt/waydroid_script && "$py" main.py uninstall "$arm_old") >/dev/null 2>&1 || true
    (cd /opt/waydroid_script && "$py" main.py install "$arm") \
        || { warn "ARM translation install failed; x86 apps still work."; return 1; }
}

# ---- Low-RAM tuning (always checked)
# Small boxes have about 4 GB of RAM. Debian + Android + one big app do not fit, so the kernel or
# Android's memory killer closes apps. Fix: compressed RAM swap (zram, about 3:1) used early,
# plus a swap file on disk as the last resort before anything is killed.
SWAP_GB=4
tune_memory() {
    # Existing installs keep the swap file they already have (older versions used /cn60.swap).
    local SWAPFILE
    SWAPFILE=$(cat "$STATE/swapfile" 2>/dev/null || true); SWAPFILE=${SWAPFILE:-/waytv.swap}
    if [[ $LOW_RESOURCES -eq 1 ]]; then
        log "Checking low-memory tuning (low resources detected)"
    else
        log "Checking memory tuning (standard)"
    fi
    put_file /etc/sysctl.d/90-waytv.conf 644 <<'EOF'
# WayTV kiosk memory tuning (removed by waytv-setup.sh --uninstall)
# zram swap is fast, so move idle memory there early instead of killing apps.
vm.swappiness=150
vm.page-cluster=0
vm.watermark_scale_factor=125
vm.watermark_boost_factor=0
vm.vfs_cache_pressure=100
EOF
    sysctl --system >/dev/null 2>&1 || warn "sysctl reload failed; applies after reboot."

    # zram: compressed swap in RAM, size = 100% of RAM (zstd), used before the disk.
    if [[ -f /etc/default/zramswap ]]; then
        backup_once /etc/default/zramswap
        local before
        before="$(cat /etc/default/zramswap)"
        set_kv /etc/default/zramswap ALGO zstd
        local zpct=50
        [[ $LOW_RESOURCES -eq 1 ]] && zpct=100
        set_kv /etc/default/zramswap PERCENT "$zpct"
        set_kv /etc/default/zramswap PRIORITY 100
        systemctl enable zramswap.service >/dev/null 2>&1 || true
        if ! swapon --show=NAME --noheadings | grep -q zram; then
            systemctl restart zramswap.service && CHANGES+=("zram swap on (${zpct}% of RAM, zstd)") \
                || warn "zram swap did not start; continuing."
        elif [[ "$before" != "$(cat /etc/default/zramswap)" ]]; then
            # Restarting zram now would pull everything swapped back into RAM at once.
            CHANGES+=("zram swap resized to ${zpct}% of RAM (applies after reboot)")
        fi
    else
        warn "zram-tools config missing; skipping zram swap."
    fi

    # Swap file on disk: used only when zram is full (lower priority).
    if swapon --show=NAME --noheadings | grep -qx "$SWAPFILE"; then
        :
    elif [[ $LOW_RESOURCES -eq 0 && ! -f $SWAPFILE ]]; then
        :   # enough RAM: no swap file needed
    elif [[ -f $SWAPFILE ]]; then
        swapon -p 10 "$SWAPFILE" 2>/dev/null || warn "Could not enable $SWAPFILE."
    else
        local fs avail
        fs="$(findmnt -no FSTYPE / 2>/dev/null || true)"
        avail="$(df --output=avail -BG / 2>/dev/null | tail -n1 | tr -dc 0-9)"
        if [[ $fs != ext4 && $fs != xfs ]]; then
            warn "Swap file skipped: the root filesystem is '${fs:-unknown}', not ext4/xfs."
        elif (( ${avail:-0} < SWAP_GB + 8 )); then
            warn "Swap file skipped: only ${avail:-0} GB free on / (need $((SWAP_GB + 8)) GB)."
        elif fallocate -l "${SWAP_GB}G" "$SWAPFILE" && chmod 600 "$SWAPFILE" \
             && mkswap -L waytvswap "$SWAPFILE" >/dev/null && swapon -p 10 "$SWAPFILE"; then
            echo "$SWAPFILE" > "$STATE/swapfile"
            CHANGES+=("added a ${SWAP_GB} GB swap file ($SWAPFILE)")
        else
            swapoff "$SWAPFILE" 2>/dev/null || true
            rm -f "$SWAPFILE"
            warn "Could not create the swap file; continuing with zram only."
        fi
    fi
    if [[ -f $SWAPFILE ]] && ! grep -q "^${SWAPFILE}[[:space:]]" /etc/fstab; then
        backup_once /etc/fstab
        echo "$SWAPFILE none swap sw,pri=10 0 0" >> /etc/fstab
        CHANGES+=("swap file enabled at boot (/etc/fstab)")
        systemctl daemon-reload
    fi

    # If Debian itself runs out of memory, its OOM killer must pick something other than
    # Android's container or the kiosk screen (that would close everything at once).
    put_file /etc/systemd/system/waydroid-container.service.d/90-waytv.conf 644 <<'EOF'
# WayTV: protect Android from the host OOM killer (removed by --uninstall)
[Service]
OOMScoreAdjust=-500
EOF
    systemctl daemon-reload
    return 0
}

# ---- Android memory settings (always checked)
# Bigger per-app Java heap: heavy apps (video, games) otherwise die with OutOfMemoryError.
# Written to the [properties] section of waydroid.cfg; Waydroid copies it into the
# Android image's properties on every `waydroid upgrade` (also --offline), so it survives updates.
ANDROID_PROPS=(dalvik.vm.heapgrowthlimit=256m dalvik.vm.heapsize=512m)
tune_android() {
    log "📱 Checking Android memory settings"
    local cfg=/var/lib/waydroid/waydroid.cfg out
    [[ -f $cfg ]] || { warn "$cfg missing; skipping Android memory settings."; return 0; }
    out="$(python3 - "$cfg" "${ANDROID_PROPS[@]}" <<'PY'
import configparser, sys
path, props = sys.argv[1], sys.argv[2:]
c = configparser.ConfigParser()
c.read(path)
if not c.has_section("properties"):
    c.add_section("properties")
changed = False
for kv in props:
    k, v = kv.split("=", 1)
    if c.get("properties", k, fallback=None) != v:
        c.set("properties", k, v)
        changed = True
if changed:
    with open(path + ".waytvnew", "w") as f:
        c.write(f)
    print("changed")
PY
)" || { warn "Could not edit $cfg."; rm -f "$cfg.waytvnew"; return 0; }
    if [[ $out == changed ]]; then
        backup_once "$cfg"
        mv -f "$cfg.waytvnew" "$cfg"
        stop_android
        if waydroid upgrade --offline >/dev/null 2>&1; then
            CHANGES+=("Android: larger app memory limit (${ANDROID_PROPS[*]})")
        else
            warn "waydroid upgrade --offline failed; the Android memory settings apply after the next 'sudo waytv-update'."
        fi
    else
        echo "  Android memory settings present"
    fi
    return 0
}

write_helpers() {
    log "Checking the kiosk helpers and systemd units (only changed files are rewritten)"

    # Settings menu (embedded, so this script is the only file you need).
    put_file /usr/local/bin/waytv-settings 755 <<'WAYTV_SETTINGS_EOF'
#!/usr/bin/env bash
# WayTV settings menu: resolution, TV tweaks, Bluetooth, TV power (HDMI-CEC), SSH info, updates.
# Written by waytv-setup.sh. Run with sudo from a console.
set -uo pipefail

CONF=/etc/waytv/display.conf
[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo waytv-settings"; exit 1; }
command -v whiptail >/dev/null || { echo "whiptail missing"; exit 1; }

apply_resolution() {
    local w="$1" h="$2"
    mkdir -p /etc/waytv
    touch "$CONF"
    # Keep the other settings in the file (OVERLAY=...); only replace the size.
    sed -i '/^WIDTH=/d; /^HEIGHT=/d; /^REFRESH=/d' "$CONF"
    printf 'WIDTH=%s\nHEIGHT=%s\n' "$w" "$h" >> "$CONF"
    [[ -x /usr/local/bin/waytv-tweaks ]] && /usr/local/bin/waytv-tweaks density-follow >/dev/null 2>&1
    waydroid prop set persist.waydroid.width "$w" || true
    waydroid prop set persist.waydroid.height "$h" || true
    systemctl restart waydroid-kiosk.service
    whiptail --msgbox "Resolution set to ${w}x${h}. Android restarts in about a minute." 8 60
}

menu_resolution() {
    local choice
    choice=$(whiptail --title "Resolution" --menu "The HDMI output switches to this size at the fastest refresh up to 60 Hz. This box can only send 4K at 30 Hz." 16 74 4 \
        1080p "1920x1080 at 60 Hz (default, smoothest)" \
        4k    "3840x2160 at 30 Hz (sharper, choppy)" \
        720p  "1280x720 at 60 Hz" \
        back  "Return" 3>&1 1>&2 2>&3) || return
    case "$choice" in
        4k)    apply_resolution 3840 2160 ;;
        1080p) apply_resolution 1920 1080 ;;
        720p)  apply_resolution 1280 720 ;;
        back)  ;;
    esac
}

# Bluetooth: devices pair with Debian. Keyboards, mice, gamepads and remotes then
# work in Android as normal input; headphones/speakers play Android's sound.
bt_pick() {   # bt_pick <filter: Paired|Connected|""> <title>; sets BT_MAC
    local items=() mac name
    while read -r _ mac name; do
        [[ $mac =~ ^([0-9A-F]{2}:){5}[0-9A-F]{2}$ ]] && items+=("$mac" "${name:-unknown}")
    done < <(bluetoothctl devices $1 2>/dev/null)
    if [[ ${#items[@]} -eq 0 ]]; then
        whiptail --msgbox "No devices found." 7 40; return 1
    fi
    BT_MAC=$(whiptail --title "$2" --menu "Choose a device" 20 70 10 "${items[@]}" 3>&1 1>&2 2>&3)
}

bt_run() {    # show the commands' output on screen (passkeys appear here)
    clear
    echo "$1"; echo
    shift
    local out
    for c in "$@"; do
        echo "\$ bluetoothctl $c"
        out=$(eval "bluetoothctl $c" 2>&1); echo "$out"; echo
        if [[ $out == *profile-unavailable* ]]; then
            echo "Hint: no Debian service can handle this device. Headphones/speakers need the"
            echo "audio server: run 'sudo waytv-update' (script v10+) and reboot. Phones and PCs"
            echo "cannot be connected this way at all."
            echo
        fi
    done
    read -rp "Press Enter to continue " _
}

bt_pair() {
    whiptail --msgbox "Put the device in pairing mode now (usually hold its pairing or power button until a light flashes), then press OK. Scanning takes 20 seconds." 10 64
    clear; echo "Scanning for 20 seconds..."
    bluetoothctl --timeout 20 scan on >/dev/null 2>&1
    bt_pick "" "Devices found" || return
    bt_run "Pairing $BT_MAC. If a code appears, type it on the keyboard and press Enter." \
        "pair $BT_MAC" "trust $BT_MAC" "connect $BT_MAC"
}

bt_status() {
    local paired connected
    paired=$(bluetoothctl devices Paired 2>/dev/null | cut -d' ' -f2-)
    connected=$(bluetoothctl devices Connected 2>/dev/null | cut -d' ' -f2-)
    whiptail --title "Bluetooth status" --msgbox \
        "Paired:\n${paired:-none}\n\nConnected now:\n${connected:-none}" 20 74
}

menu_bluetooth() {
    systemctl start bluetooth.service
    rfkill unblock bluetooth 2>/dev/null || true
    bluetoothctl power on >/dev/null 2>&1
    local choice
    while true; do
        choice=$(whiptail --title "Bluetooth" --menu "Keyboards, mice, gamepads, remotes, headphones, speakers" 16 70 6 \
            pair       "Scan and pair a new device" \
            status     "Show paired and connected devices" \
            connect    "Reconnect a paired device" \
            disconnect "Disconnect a device" \
            remove     "Forget a device" \
            back       "Return" 3>&1 1>&2 2>&3) || return
        case "$choice" in
            pair)       bt_pair ;;
            status)     bt_status ;;
            connect)    bt_pick Paired "Reconnect" && bt_run "Connecting $BT_MAC" "connect $BT_MAC" ;;
            disconnect) bt_pick Connected "Disconnect" && bt_run "Disconnecting $BT_MAC" "disconnect $BT_MAC" ;;
            remove)     bt_pick Paired "Forget" && bt_run "Removing $BT_MAC" "remove $BT_MAC" ;;
            back)       return ;;
        esac
    done
}

menu_info() {
    local ips ssh_state
    ips=$(hostname -I 2>/dev/null)
    ssh_state=$(systemctl is-active ssh.service 2>/dev/null)
    whiptail --title "Network / SSH" --msgbox \
        "IP address(es): ${ips:-none}\nSSH: ${ssh_state}\n\nFrom another computer:\n  ssh $(cat /etc/waytv/user 2>/dev/null)@<IP above>" 13 70
}

menu_tv_power() {
    local choice
    choice=$(whiptail --title "TV power (HDMI-CEC)" --menu "Control the TV" 12 60 3 \
        on   "Turn TV on" \
        off  "Put TV in standby" \
        back "Return" 3>&1 1>&2 2>&3) || return
    case "$choice" in
        on)  echo 'on 0'  | cec-client -s -d 1 >/dev/null 2>&1 && whiptail --msgbox "Sent power-on." 7 40 || whiptail --msgbox "CEC command failed. Check the HDMI cable and that CEC is enabled on the TV." 9 60 ;;
        off) echo 'standby 0' | cec-client -s -d 1 >/dev/null 2>&1 && whiptail --msgbox "Sent standby." 7 40 || whiptail --msgbox "CEC command failed." 7 40 ;;
        back) ;;
    esac
}

# TV tweaks (waytv-tweaks): hide phone apps, scaling, bottom bar, time zone.
tw_run() { clear; /usr/local/bin/waytv-tweaks "$@"; read -rp "Press Enter to continue " _; }

menu_tweaks() {
    local choice v
    while true; do
        choice=$(whiptail --title "TV tweaks" --menu "$(/usr/local/bin/waytv-tweaks status 2>&1 | head -n 4)" 21 74 8 \
            all      "Do all of the below (recommended for a TV)" \
            apps     "Hide phone apps (Clock, Contacts, Music, Camera...)" \
            restore  "Bring the hidden apps back" \
            scale    "Size of text and icons (scaling)" \
            navbar   "Hide or show the bottom bar" \
            timezone "Set Android's clock to this box's time zone" \
            back     "Return" 3>&1 1>&2 2>&3) || return
        case "$choice" in
            all)      tw_run all ;;
            apps)     tw_run apps-remove ;;
            restore)  tw_run apps-restore ;;
            scale)    v=$(whiptail --title "Scaling" --menu "Bigger number = bigger text and icons" 17 64 7 \
                          auto  "Match the resolution (recommended)" \
                          160   "720p normal" \
                          240   "1080p normal" \
                          360   "4K small" \
                          480   "4K normal" \
                          560   "4K large" \
                          reset "Android default" 3>&1 1>&2 2>&3) && tw_run density "$v" ;;
            navbar)   v=$(whiptail --title "Bottom bar" --menu "Without the bar, use the remote's Back and Home keys. Android restarts." 12 64 2 \
                          off "Hide the bottom bar" \
                          on  "Show the bottom bar" 3>&1 1>&2 2>&3) && tw_run navbar "$v" ;;
            timezone) tw_run timezone ;;
            back)     return ;;
        esac
    done
}

while true; do
    status_line=$(cat /etc/waytv/status 2>/dev/null)
    choice=$(whiptail --title "WayTV Settings (script v$(cat /etc/waytv/version 2>/dev/null))" \
        --menu "${status_line:-Everything is up to date.}" 25 70 14 \
        resolution "Change display resolution" \
        tweaks     "TV tweaks: hide apps, scaling, bottom bar, clock" \
        perf       "Performance overlay: FPS, CPU, RAM, GPU on screen" \
        bluetooth  "Bluetooth devices" \
        tv         "TV power on/off (CEC)" \
        info       "IP address and SSH" \
        remote     "See this screen on a PC (scrcpy)" \
        crashes    "Why do apps close? (crash report)" \
        apps       "Install Aurora Store (Google Play client)" \
        restart    "Restart the Android kiosk" \
        check      "Check for updates" \
        update     "Update script + Debian + Android now" \
        reboot     "Reboot the box" \
        exit       "Quit" 3>&1 1>&2 2>&3) || break
    case "$choice" in
        resolution) menu_resolution ;;
        tweaks)     menu_tweaks ;;
        perf)       v=$(whiptail --title "Performance overlay" --menu "Now: $(/usr/local/bin/waytv-perf status | head -n 1). Shows FPS, CPU, RAM and GPU top right. Android restarts." 12 70 3 \
                        on   "Show the numbers on the TV" \
                        off  "Hide them" \
                        live "Show them here instead (Ctrl+C to stop)" 3>&1 1>&2 2>&3) &&
                    case "$v" in
                        live) clear; /usr/local/bin/waytv-perf ;;
                        *)    clear; /usr/local/bin/waytv-perf overlay "$v"; read -rp "Press Enter to return to the menu " _ ;;
                    esac ;;
        bluetooth)  menu_bluetooth ;;
        tv)         menu_tv_power ;;
        info)       menu_info ;;
        remote)     clear; /usr/local/bin/waytv-remote; read -rp "Press Enter to return to the menu " _ ;;
        crashes)    clear; /usr/local/bin/waytv-crashlog | less -R; ;;
        apps)       if whiptail --yesno "Install Aurora Store?\n\nIt downloads apps from Google Play without Google's apps. Apps that need Google Play Services may not work." 11 64; then
                        clear; /usr/local/bin/waytv-apps aurora; read -rp "Press Enter to return to the menu " _
                    fi ;;
        restart)    systemctl restart waydroid-kiosk.service ;;
        check)      clear; /usr/local/bin/waytv-check --no-notify; read -rp "Press Enter to return to the menu " _ ;;
        update)     clear; /usr/local/bin/waytv-update; read -rp "Press Enter to return to the menu " _ ;;
        reboot)     whiptail --yesno "Reboot now?" 7 40 && systemctl reboot ;;
        exit)       break ;;
    esac
done
WAYTV_SETTINGS_EOF

    # TV tweaks: hide phone apps, UI scaling (DPI), bottom bar, Android time zone.
    put_file /usr/local/bin/waytv-tweaks 755 <<'WAYTV_TWEAKS_EOF'
#!/usr/bin/env bash
# WayTV TV tweaks for Android: hide stock phone apps, UI scaling (DPI), hide the bottom
# navigation bar, and set Android's time zone. Written by waytv-setup.sh.
# Usage: sudo waytv-tweaks status|all|apps-remove|apps-restore|density <dpi|auto|reset>
#                         |navbar <off|on>|timezone [Area/City]
set -uo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo waytv-tweaks $*"; exit 1; }

CFG=/var/lib/waydroid/waydroid.cfg
BACKUP=/etc/waytv/backup
KUSER="$(cat /etc/waytv/user 2>/dev/null || echo tv)"
# Stock apps that make little sense on a TV. "pm uninstall --user 0" hides them for the
# user only: they stay in the Android image and "waytv-tweaks apps-restore" brings them back.
APPS=(com.android.deskclock:Clock com.android.contacts:Contacts org.lineageos.eleven:Music
      org.lineageos.recorder:Recorder com.android.calculator2:Calculator
      org.lineageos.etar:Calendar org.lineageos.aperture:Camera)

ash() { waydroid shell -- "$@" 2>&1 | tr -d '\r'; }

need_android() {
    if [[ $(waydroid status 2>/dev/null) != *Session:*RUNNING* ]]; then
        echo "Android is not running. Start it with: sudo systemctl restart waydroid-kiosk"
        echo "then wait a minute and try again."
        exit 1
    fi
}

# Read the package list once into a variable: "ash ... | grep -q" would race with
# pipefail (grep exits early, the writer gets SIGPIPE, the test randomly fails).
PKGS=""
load_pkgs() { PKGS=$(ash /system/bin/pm list packages); }
installed() { [[ $'\n'"$PKGS"$'\n' == *$'\n'"package:$1"$'\n'* ]]; }

apps_remove() {
    local e pkg name out
    load_pkgs
    for e in "${APPS[@]}"; do
        pkg=${e%%:*}; name=${e#*:}
        if installed "$pkg"; then
            out=$(ash /system/bin/pm uninstall --user 0 "$pkg")
            [[ $out == *Success* ]] && echo "  hidden: $name" || echo "  FAILED: $name ($out)"
        else
            echo "  already hidden: $name"
        fi
    done
}

apps_restore() {
    local e pkg name out
    load_pkgs
    for e in "${APPS[@]}"; do
        pkg=${e%%:*}; name=${e#*:}
        if installed "$pkg"; then echo "  already there: $name"; continue; fi
        out=$(ash /system/bin/pm install-existing --user 0 "$pkg")
        [[ $out == *installed* || $out == *Success* ]] && echo "  restored: $name" || echo "  FAILED: $name ($out)"
    done
}

# Density that gives a 1280x720-sized layout (about right from a sofa) at the configured
# resolution: 4K -> 480, 1080p -> 240, 720p -> 160.
auto_dpi() {
    local HEIGHT=1080
    # shellcheck disable=SC1091
    [[ -r /etc/waytv/display.conf ]] && . /etc/waytv/display.conf
    echo $(( ${HEIGHT:-1080} * 2 / 9 ))
}

density() {
    local v=${1:-auto}
    [[ $v == auto ]] && v=$(auto_dpi)
    if [[ $v == reset ]]; then
        ash /system/bin/wm density reset >/dev/null
        echo "  scaling: Android default"
    elif [[ $v =~ ^[0-9]+$ ]] && (( v >= 100 && v <= 800 )); then
        ash /system/bin/wm density "$v" >/dev/null
        echo "  scaling: $v dpi"
    else
        echo "Density must be a number from 100 to 800, 'auto' or 'reset'."; return 1
    fi
}

# After a resolution change: keep the layout size, but only if a density was chosen before.
density_follow() {
    [[ $(ash /system/bin/wm density) == *'Override density'* ]] && density auto
    return 0
}

# The bottom bar is hidden with the qemu.hw.mainkeys=1 property ("this device has hardware
# keys"). It lives in waydroid.cfg [properties], so it survives "waydroid upgrade".
navbar() {
    local want=$1 out
    [[ $want == off || $want == on ]] || { echo "Use: waytv-tweaks navbar off|on"; return 1; }
    [[ -f $CFG ]] || { echo "$CFG missing; is Waydroid installed?"; return 1; }
    out="$(python3 - "$CFG" "$want" <<'PY'
import configparser, sys
path, want = sys.argv[1], sys.argv[2]
c = configparser.ConfigParser()
c.read(path)
if not c.has_section("properties"):
    c.add_section("properties")
cur = c.get("properties", "qemu.hw.mainkeys", fallback=None)
if want == "off" and cur != "1":
    c.set("properties", "qemu.hw.mainkeys", "1")
elif want == "on" and cur is not None:
    c.remove_option("properties", "qemu.hw.mainkeys")
else:
    sys.exit(0)
with open(path + ".waytvnew", "w") as f:
    c.write(f)
print("changed")
PY
)" || { rm -f "$CFG.waytvnew"; echo "Could not edit $CFG."; return 1; }
    if [[ $out != changed ]]; then
        echo "  bottom bar: already $want"; return 0
    fi
    local b="$BACKUP$CFG"
    [[ -e $b ]] || { mkdir -p "$(dirname "$b")"; cp -a "$CFG" "$b"; }
    mv -f "$CFG.waytvnew" "$CFG"
    echo "  bottom bar: $want (restarting Android, about a minute)"
    # Android saves app changes (hidden apps) about 10 s after they are made; stopping it
    # sooner loses them. Give it time if it is running.
    [[ $(waydroid status 2>/dev/null) == *Session:*RUNNING* ]] && sleep 15
    systemctl stop waydroid-kiosk.service 2>/dev/null || true
    runuser -u "$KUSER" -- waydroid session stop >/dev/null 2>&1 || true
    waydroid upgrade --offline >/dev/null 2>&1 || echo "  WARNING: waydroid upgrade --offline failed"
    systemctl restart waydroid-container.service
    systemctl start waydroid-kiosk.service
}

timezone() {
    local tz=${1:-}
    [[ -n $tz ]] || tz=$(timedatectl show -p Timezone --value 2>/dev/null)
    [[ -n $tz ]] || tz=$(cat /etc/timezone 2>/dev/null)
    if [[ -z $tz || ! -f /usr/share/zoneinfo/$tz ]]; then
        echo "Unknown time zone '${tz}'. Example: waytv-tweaks timezone America/New_York"; return 1
    fi
    ash /system/bin/settings put global auto_time_zone 0 >/dev/null
    ash /system/bin/cmd alarm set-timezone "$tz" >/dev/null
    if [[ $(ash /system/bin/getprop persist.sys.timezone) == "$tz" ]]; then
        echo "  time zone: $tz (Android now shows $(ash /system/bin/date '+%H:%M'))"
    else
        echo "  FAILED to set the time zone to $tz"; return 1
    fi
}

status() {
    local e hidden=() d mk tz
    load_pkgs
    for e in "${APPS[@]}"; do installed "${e%%:*}" || hidden+=("${e#*:}"); done
    d=$(ash /system/bin/wm density | sed -n 's/Override density: //p')
    mk=$(ash /system/bin/getprop qemu.hw.mainkeys)
    tz=$(ash /system/bin/getprop persist.sys.timezone)
    echo "Hidden apps: ${hidden[*]:-none}"
    echo "Scaling:     ${d:-Android default} dpi (suggested $(auto_dpi))"
    echo "Bottom bar:  $([[ $mk == 1 ]] && echo hidden || echo shown)"
    echo "Time zone:   ${tz:-unset} (box: $(timedatectl show -p Timezone --value 2>/dev/null))"
}

cmd=${1:-help}; shift || true
case $cmd in
    status)        need_android; status ;;
    apps-remove)   need_android; apps_remove ;;
    apps-restore)  need_android; apps_restore ;;
    density)       need_android; density "${1:-auto}" ;;
    density-follow) need_android; density_follow ;;
    timezone)      need_android; timezone "${1:-}" ;;
    navbar)        navbar "${1:-}" ;;
    all)           need_android
                   apps_remove; density auto; timezone; navbar off ;;
    *) sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
WAYTV_TWEAKS_EOF

    # Performance overlay (optional, off by default): FPS, CPU, RAM, GPU on the TV.
    # cage cannot draw anything on top of Android, so with the overlay on the kiosk runs
    # labwc (same wlroots base) and waybar shows a small box in the top-right corner.
    put_file /usr/local/lib/waytv/perf-collector.py 755 <<'WAYTV_PERF_PY_EOF'
#!/usr/bin/env python3
"""WayTV performance numbers: FPS, CPU, RAM, GPU.

FPS = frames Android put on screen in the last second (SurfaceFlinger page flips).
It drops to 0 when nothing moves on screen; that is normal, not a hang.
GPU = Intel render engine busy % (intel_gpu_top); n/a on other GPUs.
  perf-collector.py           print one line per second (Ctrl+C to stop)
  perf-collector.py --daemon  write the line to /run/waytv/perf.txt for the overlay
"""
import json, os, re, subprocess, sys, threading, time

OUT = "/run/waytv/perf.txt"
LXC = ["lxc-attach", "-P", "/var/lib/waydroid/lxc", "-n", "waydroid", "--clear-env", "--"]
state = {"fps": None, "gpu": None}


def fps_thread():
    # One long-running shell inside Android asks SurfaceFlinger for its page-flip
    # counter every second (transaction 1013); the difference over time is the FPS.
    loop = "while :; do /system/bin/service call SurfaceFlinger 1013; sleep 1; done"
    while True:
        try:
            p = subprocess.Popen(LXC + ["/system/bin/sh", "-c", loop], text=True,
                                 stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            last = last_t = None
            for line in p.stdout:
                m = re.search(r"Parcel\(([0-9a-f]{8})", line)
                if not m:
                    continue
                n, t = int(m.group(1), 16), time.monotonic()
                if last is not None and t > last_t:
                    state["fps"] = round(((n - last) & 0xFFFFFFFF) / (t - last_t))
                last, last_t = n, t
            p.wait()
        except OSError:
            pass
        state["fps"] = None
        time.sleep(5)


def gpu_thread():
    # intel_gpu_top -J prints one JSON object per period; split on brace depth.
    while True:
        try:
            p = subprocess.Popen(["intel_gpu_top", "-J", "-s", "1000"], text=True,
                                 stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            depth, buf = 0, []
            while True:
                ch = p.stdout.read(1)
                if not ch:
                    break
                if ch == "{":
                    depth += 1
                if depth:
                    buf.append(ch)
                if ch == "}":
                    depth -= 1
                    if depth == 0:
                        try:
                            eng = json.loads("".join(buf)).get("engines", {})
                            busy = [v.get("busy", 0) for k, v in eng.items() if k.startswith("Render")]
                            state["gpu"] = round(busy[0]) if busy else None
                        except ValueError:
                            pass
                        buf = []
            p.wait()
        except OSError:
            pass
        state["gpu"] = None
        time.sleep(30)


def cpu_times():
    with open("/proc/stat") as f:
        v = [int(x) for x in f.readline().split()[1:]]
    idle = v[3] + (v[4] if len(v) > 4 else 0)
    return sum(v), idle


def ram():
    m = {}
    with open("/proc/meminfo") as f:
        for line in f:
            k, v = line.split(":", 1)
            m[k] = int(v.split()[0])
    total = m["MemTotal"] / 1048576
    return total - m.get("MemAvailable", m["MemFree"]) / 1048576, total


def fmt(v, unit=""):
    return "n/a" if v is None else f"{v}{unit}"


def main():
    daemon = "--daemon" in sys.argv
    for fn in (fps_thread, gpu_thread):
        threading.Thread(target=fn, daemon=True).start()
    if daemon:
        os.makedirs(os.path.dirname(OUT), exist_ok=True)
    t0, i0 = cpu_times()
    while True:
        time.sleep(1)
        t1, i1 = cpu_times()
        cpu = round(100 * (1 - (i1 - i0) / max(t1 - t0, 1)))
        t0, i0 = t1, i1
        used, total = ram()
        line = (f"FPS {fmt(state['fps'])}  CPU {cpu}%  "
                f"RAM {used:.1f}/{total:.1f} GB  GPU {fmt(state['gpu'], '%')}")
        if daemon:
            with open(OUT + ".new", "w") as f:
                f.write(line + "\n")
            os.replace(OUT + ".new", OUT)
        else:
            print(line, flush=True)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
WAYTV_PERF_PY_EOF

    put_file /usr/local/lib/waytv/perf-tail 755 <<'EOF'
#!/bin/sh
# Feeds waybar one line per second from the stats file written by waytv-perf.service.
while :; do
    cat /run/waytv/perf.txt 2>/dev/null || echo "Performance: starting..."
    sleep 1
done
EOF

    put_file /usr/local/lib/waytv/waybar/config 644 <<'EOF'
{
    "layer": "overlay",
    "position": "top",
    "exclusive": false,
    "passthrough": true,
    "modules-right": ["custom/perf"],
    "custom/perf": {
        "exec": "/usr/local/lib/waytv/perf-tail",
        "format": "{}",
        "tooltip": false
    }
}
EOF

    put_file /usr/local/lib/waytv/waybar/style.css 644 <<'EOF'
* { border: none; min-height: 0; }
window#waybar { background: transparent; }
#custom-perf {
    font-family: "DejaVu Sans Mono", monospace;
    font-size: 44px;
    font-weight: bold;
    color: #ffffff;
    background: rgba(0, 0, 0, 0.6);
    padding: 6px 16px;
    border-radius: 10px;
}
EOF

    put_file /usr/local/lib/waytv/labwc/rc.xml 644 <<'EOF'
<?xml version="1.0"?>
<!-- WayTV kiosk with performance overlay: Android full screen, no window borders. -->
<labwc_config>
  <core><gap>0</gap></core>
  <keyboard>
    <!-- Defining one binding turns off labwc's default shortcuts (Alt+F4 etc.). -->
    <keybind key="W-F12"><action name="Reconfigure"/></keybind>
  </keyboard>
  <windowRules>
    <windowRule identifier="*" serverDecoration="no">
      <action name="ToggleFullscreen"/>
    </windowRule>
  </windowRules>
</labwc_config>
EOF

    put_file /usr/local/lib/waytv/labwc/autostart 644 <<'EOF'
# Overlay text size follows the resolution: 1080p -> 24px, 4K -> 48px.
HEIGHT=1080
[ -r /etc/waytv/display.conf ] && . /etc/waytv/display.conf
CSS="${XDG_RUNTIME_DIR:-/tmp}/waytv-waybar.css"
sed "s/font-size: [0-9]*px/font-size: $(( ${HEIGHT:-1080} / 45 ))px/" /usr/local/lib/waytv/waybar/style.css > "$CSS"
waybar -c /usr/local/lib/waytv/waybar/config -s "$CSS" >/dev/null 2>&1 &
EOF

    put_file /etc/systemd/system/waytv-perf.service 644 <<'EOF'
[Unit]
Description=WayTV performance numbers for the on-screen overlay (sudo waytv-perf)
After=waydroid-container.service

[Service]
ExecStart=/usr/bin/python3 /usr/local/lib/waytv/perf-collector.py --daemon
Restart=always
RestartSec=5
Nice=10

[Install]
WantedBy=graphical-kiosk.target
EOF

    put_file /usr/local/bin/waytv-perf 755 <<'WAYTV_PERF_EOF'
#!/usr/bin/env bash
# WayTV performance overlay: FPS, CPU, RAM and GPU usage on the TV screen.
# Usage: sudo waytv-perf                  live numbers in this terminal (Ctrl+C to stop)
#        sudo waytv-perf overlay on|off   show/hide them on the TV (Android restarts)
#        sudo waytv-perf status
set -uo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo waytv-perf $*"; exit 1; }

CONF=/etc/waytv/display.conf
ADDED=/etc/waytv/packages-added
PKGS=(labwc waybar)
grep -q GenuineIntel /proc/cpuinfo && PKGS+=(intel-gpu-tools)

overlay_state() { grep -qs '^OVERLAY=1' "$CONF" && echo on || echo off; }
set_overlay() { touch "$CONF"; sed -i '/^OVERLAY=/d' "$CONF"; echo "OVERLAY=$1" >> "$CONF"; }

overlay_on() {
    local p missing=()
    for p in "${PKGS[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
    if (( ${#missing[@]} )); then
        echo "Installing ${missing[*]}..."
        if ! apt-get install -y --no-install-recommends -o DPkg::Lock::Timeout=600 "${missing[@]}"; then
            echo "Install failed (no network?). The overlay stays off."; return 1
        fi
        for p in "${missing[@]}"; do grep -qsxF "$p" "$ADDED" || echo "$p" >> "$ADDED"; done
    fi
    set_overlay 1
    systemctl enable --now waytv-perf.service
    [[ -n ${WAYTV_NO_RESTART:-} ]] && return 0     # the caller restarts Android once
    systemctl restart waydroid-kiosk.service
    echo "Overlay on. Android's screen comes back in about a minute with the numbers top right."
}

overlay_off() {
    set_overlay 0
    systemctl disable --now waytv-perf.service 2>/dev/null
    [[ -n ${WAYTV_NO_RESTART:-} ]] && return 0
    systemctl restart waydroid-kiosk.service
    echo "Overlay off. Android's screen comes back in about a minute."
}

case ${1:-show} in
    show)    echo "FPS = frames shown per second (0 when the screen is still). Ctrl+C to stop."
             exec /usr/bin/python3 /usr/local/lib/waytv/perf-collector.py ;;
    overlay) case ${2:-} in
                 on)  overlay_on ;;
                 off) overlay_off ;;
                 *)   echo "Use: waytv-perf overlay on|off"; exit 1 ;;
             esac ;;
    status)  echo "Overlay: $(overlay_state)"
             cat /run/waytv/perf.txt 2>/dev/null ;;
    *)       sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
WAYTV_PERF_EOF

    # Agent for the WayTV Settings app: a small root service reachable only from Android
    # (Waydroid's bridge), protected by a token it pushes into the app. API: docs/agent-api.md.
    put_file /usr/local/bin/waytv-agent 755 <<'WAYTV_AGENT_EOF'
#!/usr/bin/env python3
"""WayTV agent: lets the WayTV Settings app (inside Android) change box settings.

Listens only on the host side of Waydroid's bridge (waydroid0, usually 192.168.240.1),
so the LAN cannot reach it. Every request needs the token from /etc/waytv/agent.token,
which the agent pushes into the app by itself after Android starts.
API: docs/agent-api.md in the WayTV repo.

  waytv-agent serve    run the service (systemd: waytv-agent.service)
  waytv-agent pair     push the URL + token into the app now
  waytv-agent token    print the token (root only)
"""
import hmac
import ipaddress
import json
import os
import re
import secrets
import subprocess
import sys
import threading
import time
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

API = 2
PORT = 8765
STATE = "/etc/waytv"
TOKEN_FILE = f"{STATE}/agent.token"
DISPLAY_CONF = f"{STATE}/display.conf"
JOBS = "/var/lib/waytv/jobs"
LXC = ["lxc-attach", "-P", "/var/lib/waydroid/lxc", "-n", "waydroid", "--clear-env", "--"]
APP_PKG = "tv.waytv.settings"
BIN = "/usr/local/bin"
PRESETS = [("1080p", 1920, 1080), ("4k", 3840, 2160), ("720p", 1280, 720)]
ALLOWED_NET = ipaddress.ip_network("192.168.240.0/24")
lock = threading.Lock()


# ------------------------------------------------------------------ helpers
def run(cmd, timeout=30):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stdout or "").strip()
    except (OSError, subprocess.TimeoutExpired):
        return 1, ""


def android(*args, timeout=20):
    return run(LXC + list(args), timeout)[1].replace("\r", "")


def android_up():
    rc, out = run(["lxc-info", "-P", "/var/lib/waydroid/lxc", "-n", "waydroid", "-sH"], 10)
    return rc == 0 and out == "RUNNING" and android("/system/bin/getprop", "sys.boot_completed") == "1"


def container_pid():
    return run(["lxc-info", "-P", "/var/lib/waydroid/lxc", "-n", "waydroid", "-pH"], 10)[1]


def read_env(path):
    out = {}
    try:
        with open(path) as f:
            for line in f:
                if "=" in line and not line.lstrip().startswith("#"):
                    k, v = line.rstrip("\n").split("=", 1)
                    out[k.strip()] = v.strip().strip('"')
    except OSError:
        pass
    return out


def set_env_keys(path, values):
    """Replace only the given KEY=value lines; keep everything else in the file."""
    try:
        with open(path) as f:
            lines = [l for l in f.read().splitlines() if l.split("=", 1)[0] not in values]
    except OSError:
        lines = []
    lines += [f"{k}={v}" for k, v in values.items()]
    tmp = path + ".waytvnew"
    with open(tmp, "w") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(tmp, path)


def kiosk_user():
    try:
        with open(f"{STATE}/user") as f:
            return f.read().strip()
    except OSError:
        return ""


def wlr_modes():
    """[(w, h, refresh)] the TV offers and the current mode, via wlr-randr as the kiosk user."""
    user = kiosk_user()
    if not user:
        return [], None
    uid = run(["id", "-u", user])[1]
    rc, out = run(["runuser", "-u", user, "--", "env", f"XDG_RUNTIME_DIR=/run/user/{uid}",
                   "WAYLAND_DISPLAY=wayland-0", "wlr-randr"], 10)
    modes, current, seen_output = [], None, False
    for line in out.splitlines():
        if line and not line[0].isspace():
            if seen_output:
                break
            seen_output = True
            continue
        m = re.match(r"\s+(\d+)x(\d+) px, ([\d.]+) Hz(.*)", line)
        if m:
            mode = (int(m.group(1)), int(m.group(2)), float(m.group(3)))
            modes.append(mode)
            if "current" in m.group(4):
                current = mode
    return modes, current


def best_refresh(modes, w, h):
    rates = [r for (mw, mh, r) in modes if (mw, mh) == (w, h) and r <= 60.5]
    return max(rates) if rates else None


def mode_list(modes, current):
    """Every resolution/refresh the TV offers, biggest first, duplicates removed."""
    seen, out = set(), []
    for (w, h, r) in sorted(modes, key=lambda m: (-m[0] * m[1], -m[2])):
        key = (w, h, round(r, 2))
        if key in seen:
            continue
        seen.add(key)
        out.append({"width": w, "height": h, "refresh": round(r, 3),
                    "label": f"{w}x{h} at {r:.2f}".rstrip("0").rstrip(".") + " Hz",
                    "current": current is not None and (w, h) == current[:2] and abs(r - current[2]) < 0.01})
    return out


def tv_hdr_formats():
    """HDR formats the connected TV announces in its EDID (CTA-861 HDR static metadata)."""
    import glob
    for path in glob.glob("/sys/class/drm/card*-*/edid"):
        try:
            if read_file(os.path.dirname(path) + "/status") != "connected":
                continue
            with open(path, "rb") as f:
                d = f.read()
        except OSError:
            continue
        for b in range(1, len(d) // 128):
            blk = d[b * 128:(b + 1) * 128]
            if blk[0] != 0x02:
                continue
            i, end = 4, blk[2]
            while i < end and i < 127:
                tag, ln = blk[i] >> 5, blk[i] & 31
                if tag == 7 and ln >= 2 and blk[i + 1] == 6:
                    eotf = blk[i + 2]
                    return [n for bit, n in ((2, "HDR10"), (3, "HLG")) if eotf & (1 << bit)]
                i += ln + 1
        return []
    return []


def hdr_info():
    tv = tv_hdr_formats()
    reasons = ["Waydroid draws Android in SDR only: Android apps cannot send HDR video to the TV through it."]
    rc, out = run(["dpkg-query", "-W", "-f=${Package} ", "libwlroots-0.18", "libwlroots-0.19"], 10)
    if "libwlroots-0.19" not in out:
        reasons.append("The screen program (wlroots 0.18 in Debian 13) has no HDR output.")
    if not tv:
        reasons.insert(0, "The TV does not announce HDR support.")
    return {"tv": tv, "available": False, "reasons": reasons}


def delayed(seconds, cmd):
    def go():
        time.sleep(seconds)
        subprocess.run(cmd, capture_output=True)
    threading.Thread(target=go, daemon=True).start()


def restart_android_soon():
    delayed(2, ["systemctl", "restart", "waydroid-kiosk.service"])


# ------------------------------------------------------------------ jobs
# Jobs run in their own transient systemd unit, so they survive an agent restart
# (the update itself may rewrite and restart this agent).
def job_info(job_id):
    if not re.fullmatch(r"[0-9]+-[a-z-]+", job_id or ""):
        return None
    base = f"{JOBS}/{job_id}"
    meta = read_env(base + ".meta")
    if not meta:
        return None
    rc = None
    try:
        with open(base + ".rc") as f:
            rc = int(f.read().strip() or "1")
    except (OSError, ValueError):
        pass
    active = run(["systemctl", "is-active", f"waytv-job-{job_id}.service"], 10)[1] in ("active", "activating")
    if rc is None and not active:
        rc = 1                     # unit vanished without writing a result (killed, rebooted)
    state = "running" if rc is None else ("done" if rc == 0 else "failed")
    try:
        with open(base + ".log", errors="replace") as f:
            log = "".join(f.readlines()[-200:])
    except OSError:
        log = ""
    log = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", log).replace("\r", "\n")
    finished = None
    if rc is not None and os.path.exists(base + ".rc"):
        finished = datetime.fromtimestamp(os.path.getmtime(base + ".rc")).astimezone().isoformat(timespec="seconds")
    return {"id": job_id, "kind": meta.get("KIND"), "title": meta.get("TITLE"), "state": state,
            "exit_code": rc, "started": meta.get("STARTED"), "finished": finished, "log": log}


def last_job_id():
    try:
        with open(f"{JOBS}/last") as f:
            return f.read().strip()
    except OSError:
        return ""


def running_job():
    j = job_info(last_job_id())
    return j if j and j["state"] == "running" else None


def start_job(kind, title, shell_cmd):
    with lock:
        cur = running_job()
        if cur:
            raise ApiError(409, f"Another task is running: {cur['title']}")
        os.makedirs(JOBS, exist_ok=True)
        job_id = f"{int(time.time())}-{kind}"
        base = f"{JOBS}/{job_id}"
        started = datetime.now().astimezone().isoformat(timespec="seconds")
        with open(base + ".meta", "w") as f:
            f.write(f"KIND={kind}\nTITLE={title}\nSTARTED={started}\n")
        wrapper = f"{{ {shell_cmd} ; }} > {base}.log 2>&1; echo $? > {base}.rc"
        rc, out = run(["systemd-run", f"--unit=waytv-job-{job_id}", "--collect", "--quiet",
                       "-p", "Nice=5", "bash", "-c", wrapper], 30)
        if rc != 0:
            with open(base + ".rc", "w") as f:
                f.write("1\n")
            raise ApiError(500, "Could not start the task.")
        with open(f"{JOBS}/last", "w") as f:
            f.write(job_id + "\n")
        # keep the 20 newest jobs
        olds = sorted({n.split(".")[0] for n in os.listdir(JOBS) if n[0].isdigit()})[:-20]
        for o in olds:
            for ext in (".meta", ".log", ".rc"):
                try:
                    os.remove(f"{JOBS}/{o}{ext}")
                except OSError:
                    pass
    return job_info(job_id)


# ------------------------------------------------------------------ status
def status():
    conf = read_env(DISPLAY_CONF)
    w, h = int(conf.get("WIDTH", 1920)), int(conf.get("HEIGHT", 1080))
    modes, current = wlr_modes()
    presets = []
    for pid, pw, ph in PRESETS:
        r = best_refresh(modes, pw, ph)
        label = f"{pid.upper() if pid == '4k' else pid} ({pw}x{ph})" + (f" at {r:.0f} Hz" if r else "")
        presets.append({"id": pid, "width": pw, "height": ph, "label": label,
                        "available": (r is not None) or not modes})
    up = android_up()
    density = {"current": None, "suggested": h * 2 // 9, "default": None}
    navbar = timezone_android = None
    if up:
        wm = android("/system/bin/wm", "density")
        m = re.search(r"Physical density: (\d+)", wm)
        density["default"] = int(m.group(1)) if m else None
        m = re.search(r"Override density: (\d+)", wm)
        density["current"] = int(m.group(1)) if m else None
        navbar = "hidden" if android("/system/bin/getprop", "qemu.hw.mainkeys") == "1" else "shown"
        timezone_android = android("/system/bin/getprop", "persist.sys.timezone") or None
    if navbar is None:
        cfg = run(["grep", "-q", r"^qemu.hw.mainkeys *= *1", "/var/lib/waydroid/waydroid.cfg"])[0]
        navbar = "hidden" if cfg == 0 else "shown"
    chk = read_env("/var/lib/waytv/check.env")
    status_line = ""
    try:
        with open(f"{STATE}/status") as f:
            status_line = f.read().strip()
    except OSError:
        pass
    perf = None
    if run(["systemctl", "is-active", "waytv-perf.service"], 10)[1] == "active":
        try:
            with open("/run/waytv/perf.txt") as f:
                perf = f.read().strip() or None
        except OSError:
            pass

    def num(v):
        return int(v) if v and v.isdigit() else None
    checked = chk.get("CHECKED")
    try:
        checked = datetime.strptime(checked, "%Y-%m-%d %H:%M").astimezone().isoformat(timespec="seconds")
    except (TypeError, ValueError):
        pass
    with open("/proc/uptime") as f:
        uptime = int(float(f.read().split()[0]))
    ips = [ip for ip in run(["hostname", "-I"])[1].split()
           if not ip.startswith(("192.168.240.", "10.0.3.")) and ":" not in ip]
    return {
        "ok": True, "api": API, "name": "WayTV",
        "script_version": num(read_file(f"{STATE}/version")),
        "hostname": os.uname().nodename, "ips": ips,
        "ssh": run(["systemctl", "is-active", "ssh.service"], 10)[1] or "unknown",
        "user": kiosk_user(), "uptime_s": uptime, "android_running": up,
        "display": {"width": w, "height": h, "refresh": current[2] if current else None,
                    "refresh_setting": float(conf["REFRESH"]) if re.fullmatch(r"[\d.]+", conf.get("REFRESH", "")) else None,
                    "modes": mode_list(modes, current), "presets": presets},
        "hdr": hdr_info(),
        "density": density, "navbar": navbar,
        "overlay": "on" if conf.get("OVERLAY") == "1" else "off",
        "timezone": {"android": timezone_android,
                     "box": run(["timedatectl", "show", "-p", "Timezone", "--value"], 10)[1] or None},
        "updates": {"status_line": status_line or ("Everything is up to date." if chk else None),
                    "script_latest": num(chk.get("LATEST")),
                    "debian_pending": num(chk.get("DEBIAN_UPDATES")),
                    "reboot_needed": chk.get("REBOOT") == "1" if chk else None,
                    "checked_at": checked},
        "perf": perf, "job": running_job(),
    }


def read_file(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return ""


# ------------------------------------------------------------------ actions
class ApiError(Exception):
    def __init__(self, code, msg):
        super().__init__(msg)
        self.code, self.msg = code, msg


def need_android():
    if not android_up():
        raise ApiError(503, "Android is still starting. Try again in a minute.")


def check_display(body):
    """Validate {"width","height","refresh"?}; returns (w, h, refresh or None)."""
    try:
        w, h = int(body.get("width")), int(body.get("height"))
        r = body.get("refresh")
        r = None if r in (None, "", "auto") else float(r)
    except (TypeError, ValueError):
        raise ApiError(400, "width, height and refresh must be numbers.")
    modes, _ = wlr_modes()
    if modes:
        rates = [mr for (mw, mh, mr) in modes if (mw, mh) == (w, h)]
        if not rates:
            raise ApiError(400, f"The TV does not offer {w}x{h}.")
        if r is not None and not any(abs(mr - r) < 0.05 for mr in rates):
            raise ApiError(400, f"The TV does not offer {w}x{h} at {r:g} Hz.")
    elif (w, h) not in [(pw, ph) for _, pw, ph in PRESETS]:
        raise ApiError(400, "That resolution is not one of the choices.")
    return w, h, r


def write_display(w, h, r):
    set_env_keys(DISPLAY_CONF, {"WIDTH": w, "HEIGHT": h})
    if r is None:
        conf = read_env(DISPLAY_CONF)
        if "REFRESH" in conf:     # back to "fastest up to 60 Hz"
            lines = [l for l in read_file(DISPLAY_CONF).splitlines() if not l.startswith("REFRESH=")]
            with open(DISPLAY_CONF + ".waytvnew", "w") as f:
                f.write("\n".join(lines) + "\n")
            os.replace(DISPLAY_CONF + ".waytvnew", DISPLAY_CONF)
    else:
        set_env_keys(DISPLAY_CONF, {"REFRESH": f"{r:g}"})


def set_display(body):
    w, h, r = check_display(body)
    write_display(w, h, r)
    if android_up():
        run([f"{BIN}/waytv-tweaks", "density-follow"], 60)
    restart_android_soon()
    return {"ok": True, "restarting": True}


def check_density(v):
    if isinstance(v, str) and v in ("auto", "reset"):
        return v
    try:
        n = int(v)
    except (TypeError, ValueError):
        raise ApiError(400, "Scaling must be a number from 100 to 800, 'auto' or 'reset'.")
    if not 100 <= n <= 800:
        raise ApiError(400, "Scaling must be from 100 to 800.")
    return str(n)


def apply_density(arg):
    rc, out = run([f"{BIN}/waytv-tweaks", "density", arg], 60)
    if rc != 0:
        raise ApiError(500, out or "Could not change the scaling.")
    m = re.search(r"(\d+) dpi", out)
    return int(m.group(1)) if m else None


def set_density(body):
    arg = check_density(body.get("value"))
    need_android()
    return {"ok": True, "density": apply_density(arg)}


def set_navbar(body):
    want = body.get("state")
    if want not in ("on", "off"):
        raise ApiError(400, "state must be 'on' or 'off'.")
    cfg = read_file("/var/lib/waydroid/waydroid.cfg")
    hidden = re.search(r"^qemu\.hw\.mainkeys\s*=\s*1\s*$", cfg, re.M) is not None
    if (want == "off") == hidden:
        return {"ok": True, "restarting": False}
    start_job("navbar", "Bottom bar " + ("hidden" if want == "off" else "shown"),
              f"{BIN}/waytv-tweaks navbar {want}")
    return {"ok": True, "restarting": True}


def set_overlay(body):
    want = body.get("state")
    if want not in ("on", "off"):
        raise ApiError(400, "state must be 'on' or 'off'.")
    job = start_job("overlay", f"Performance overlay {want}", f"{BIN}/waytv-perf overlay {want}")
    return {"ok": True, "restarting": True, "job": job}


def timezones():
    rc, out = run(["timedatectl", "list-timezones"], 20)
    return sorted(z for z in out.splitlines() if "/" in z and not z.startswith("Etc/"))


def set_timezone(body):
    tz = body.get("tz") or ""
    if tz not in timezones():
        raise ApiError(400, f"Unknown time zone: {tz}")
    rc, out = run(["timedatectl", "set-timezone", tz], 20)
    if rc != 0:
        raise ApiError(500, "Could not set the box's time zone.")
    if android_up():
        run([f"{BIN}/waytv-tweaks", "timezone", tz], 60)
    return {"ok": True, "tz": tz}


def navbar_hidden():
    cfg = read_file("/var/lib/waydroid/waydroid.cfg")
    return re.search(r"^qemu\.hw\.mainkeys\s*=\s*1\s*$", cfg, re.M) is not None


def apply_all(body):
    """Apply several settings at once, with at most one Android restart.

    Body (every key optional): {"display": {"width","height","refresh"}, "density": n|"auto"|"reset",
    "navbar": "on"|"off", "overlay": "on"|"off", "timezone": "Area/City"}
    """
    # 1. Check everything before changing anything.
    disp = check_display(body["display"]) if body.get("display") else None
    dens = check_density(body["density"]) if body.get("density") is not None else None
    nav = body.get("navbar")
    if nav is not None and nav not in ("on", "off"):
        raise ApiError(400, "navbar must be 'on' or 'off'.")
    ov = body.get("overlay")
    if ov is not None and ov not in ("on", "off"):
        raise ApiError(400, "overlay must be 'on' or 'off'.")
    tz = body.get("timezone")
    if tz is not None and tz not in timezones():
        raise ApiError(400, f"Unknown time zone: {tz}")
    if dens is not None:
        need_android()
    if running_job():
        raise ApiError(409, f"Another task is running: {running_job()['title']}")

    conf = read_env(DISPLAY_CONF)
    applied, restart, cmds = [], False, []
    # 2. Changes that apply at once.
    if tz is not None:
        set_timezone({"tz": tz})
        applied.append("timezone")
    if disp is not None:
        w, h, r = disp
        cur_r = conf.get("REFRESH")
        if (str(w), str(h)) != (conf.get("WIDTH"), conf.get("HEIGHT")) or (r is None) != (cur_r is None) \
                or (r is not None and abs(r - float(cur_r)) > 0.01):
            write_display(w, h, r)
            applied.append("display")
            restart = True
    if dens is not None:
        apply_density(dens)
        applied.append("density")
    elif "display" in applied and android_up():
        run([f"{BIN}/waytv-tweaks", "density-follow"], 60)
    # 3. Changes that need Android to restart: one task, one restart.
    if ov is not None and ov != ("on" if conf.get("OVERLAY") == "1" else "off"):
        cmds.append(f"WAYTV_NO_RESTART=1 {BIN}/waytv-perf overlay {ov}")
        applied.append("overlay")
        restart = True
    if nav is not None and (nav == "off") != navbar_hidden():
        cmds.append(f"{BIN}/waytv-tweaks navbar {nav}")      # restarts Android itself
        applied.append("navbar")
        restart = True
    elif restart:
        cmds.append("systemctl restart waydroid-kiosk.service")
    job = None
    if cmds:
        job = start_job("apply", "Apply settings", "sleep 2; " + "; ".join(cmds))
    return {"ok": True, "applied": applied, "restarting": restart, "job": job}


# ------------------------------------------------------------------ pairing
def pair(force=False, state={"pid": None}):
    """Push URL + token into the app. Returns a short message."""
    if not android_up():
        return "Android is not running."
    if "package:" not in android("/system/bin/pm", "path", APP_PKG):
        return "The WayTV Settings app is not installed (sudo waytv-apps waytv)."
    pid = container_pid()
    have = android("/system/bin/sh", "-c", f"test -s /data/data/{APP_PKG}/files/agent.json && echo yes")
    if not force and state["pid"] == pid and have == "yes":
        return "Already paired."
    url = f"http://{bridge_ip() or '192.168.240.1'}:{PORT}"
    data = json.dumps({"url": url, "token": token()})
    folder = f"/data/data/{APP_PKG}/files"
    # Root inside Android: create the app's files folder, write the file, hand it to the app.
    script = (f'd={folder}; uid=$(stat -c %u /data/data/{APP_PKG}) || exit 1; '
              'mkdir -p "$d" && chown "$uid:$uid" "$d" && chmod 771 "$d" && '
              'cat > "$d/agent.json.new" && chown "$uid:$uid" "$d/agent.json.new" && '
              'chmod 600 "$d/agent.json.new" && mv -f "$d/agent.json.new" "$d/agent.json" && echo PAIRED')
    try:
        p = subprocess.run(LXC + ["/system/bin/sh", "-c", script], input=data, capture_output=True,
                           text=True, timeout=30)
        out = (p.stdout + p.stderr).strip()
    except (OSError, subprocess.TimeoutExpired):
        out = ""
    if "PAIRED" in out:
        state["pid"] = pid
        return "Paired: the app can now change settings."
    return "Pairing failed: " + (out or "no answer from Android")


def pair_loop():
    while True:
        try:
            pair()
        except Exception:     # never let the pairing thread die
            pass
        time.sleep(15)


def token():
    try:
        with open(TOKEN_FILE) as f:
            t = f.read().strip()
        if re.fullmatch(r"[0-9a-f]{64}", t):
            return t
    except OSError:
        pass
    os.makedirs(STATE, exist_ok=True)
    t = secrets.token_hex(32)
    fd = os.open(TOKEN_FILE + ".new", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(t + "\n")
    os.replace(TOKEN_FILE + ".new", TOKEN_FILE)
    return t


def bridge_ip():
    out = run(["ip", "-4", "-o", "addr", "show", "dev", "waydroid0"], 10)[1]
    m = re.search(r"inet (\d+\.\d+\.\d+\.\d+)/", out)
    return m.group(1) if m else None


# ------------------------------------------------------------------ HTTP
class Handler(BaseHTTPRequestHandler):
    server_version = "waytv-agent"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):      # journal: one short line per request
        sys.stderr.write("%s %s\n" % (self.command, self.path))

    def reply(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def guard(self):
        try:
            if ipaddress.ip_address(self.client_address[0]) not in ALLOWED_NET:
                self.reply(403, {"ok": False, "error": "Only Android on this box may connect."})
                return False
        except ValueError:
            self.reply(403, {"ok": False, "error": "Forbidden."})
            return False
        auth = self.headers.get("Authorization", "")
        if not hmac.compare_digest(auth.encode(), f"Bearer {token()}".encode()):
            self.reply(401, {"ok": False, "error": "Not paired. On the box run: sudo waytv-agent pair"})
            return False
        return True

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n > 65536:
            raise ApiError(413, "Request too large.")
        if n == 0:
            return {}
        try:
            data = json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            raise ApiError(400, "Body must be JSON.")
        if not isinstance(data, dict):
            raise ApiError(400, "Body must be a JSON object.")
        return data

    def handle_api(self, method):
        if not self.guard():
            return
        path = self.path.split("?", 1)[0].rstrip("/")
        try:
            if method == "GET":
                if path == "/api/status":
                    return self.reply(200, status())
                if path == "/api/timezones":
                    return self.reply(200, {"ok": True, "timezones": timezones()})
                if path == "/api/jobs/last":
                    return self.reply(200, {"ok": True, "job": job_info(last_job_id())})
                if path.startswith("/api/jobs/"):
                    job = job_info(path.rsplit("/", 1)[1])
                    if not job:
                        raise ApiError(404, "No such task.")
                    return self.reply(200, {"ok": True, "job": job})
            elif method == "POST":
                body = self.body()
                routes = {
                    "/api/apply": lambda: apply_all(body),
                    "/api/display": lambda: set_display(body),
                    "/api/density": lambda: set_density(body),
                    "/api/navbar": lambda: set_navbar(body),
                    "/api/overlay": lambda: set_overlay(body),
                    "/api/timezone": lambda: set_timezone(body),
                    "/api/update/check": lambda: {"ok": True, "job": start_job(
                        "check", "Check for updates", f"{BIN}/waytv-check --no-notify")},
                    "/api/update/run": lambda: {"ok": True, "job": start_job(
                        "update", "Update", f"{BIN}/waytv-update")},
                    "/api/restart-android": lambda: (restart_android_soon(), {"ok": True, "restarting": True})[1],
                    "/api/reboot": lambda: (delayed(3, ["systemctl", "reboot"]), {"ok": True, "rebooting": True})[1],
                }
                if path in routes:
                    return self.reply(200, routes[path]())
            raise ApiError(404, "Unknown request.")
        except ApiError as e:
            self.reply(e.code, {"ok": False, "error": e.msg})
        except Exception as e:  # report, don't crash the server
            self.reply(500, {"ok": False, "error": f"Internal error: {e.__class__.__name__}"})

    def do_GET(self):
        self.handle_api("GET")

    def do_POST(self):
        self.handle_api("POST")


def serve():
    token()
    threading.Thread(target=pair_loop, daemon=True).start()
    while True:                       # waydroid0 appears only once the container runs
        ip = bridge_ip()
        if ip:
            try:
                srv = ThreadingHTTPServer((ip, PORT), Handler)
                srv.daemon_threads = True
                print(f"waytv-agent listening on http://{ip}:{PORT}", flush=True)
                srv.serve_forever()
            except OSError as e:
                print(f"cannot listen on {ip}:{PORT}: {e}", flush=True)
        time.sleep(5)


def main():
    if os.geteuid() != 0:
        sys.exit("Run with sudo: sudo waytv-agent " + " ".join(sys.argv[1:]))
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "serve":
        serve()
    elif cmd == "pair":
        print(pair(force=True))
    elif cmd == "token":
        print(token())
    else:
        print(__doc__.split("\n\n", 2)[2] if __doc__ else "")
        sys.exit(1)


if __name__ == "__main__":
    main()
WAYTV_AGENT_EOF

    put_file /etc/systemd/system/waytv-agent.service 644 <<'EOF'
[Unit]
Description=WayTV agent: lets the WayTV Settings app change box settings
After=waydroid-container.service network.target

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/waytv-agent serve
Restart=always
RestartSec=5

[Install]
WantedBy=graphical-kiosk.target
EOF

    # Keep a copy of this script on the box, for self-update and uninstall from anywhere.
    put_file /usr/local/lib/waytv/waytv-setup.sh 755 < "$SELF"

    # Update checker: new script version on GitHub + pending Debian updates -> Android notification.
    put_file /usr/local/bin/waytv-check 755 <<'WAYTV_CHECK_EOF'
#!/usr/bin/env bash
# WayTV update check: new setup-script version on GitHub, pending Debian updates,
# pending reboot. Writes /etc/waytv/status and posts an Android notification.
#   sudo waytv-check               check, print the result, notify in Android
#   sudo waytv-check --quiet       no output (used by the daily timer)
#   sudo waytv-check --no-notify   do not post an Android notification
set -uo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo waytv-check"; exit 1; }
QUIET=0; WANT_NOTIFY=1
for a in "$@"; do
    case "$a" in --quiet) QUIET=1 ;; --no-notify) WANT_NOTIFY=0 ;; esac
done
say() { [[ $QUIET -eq 1 ]] || echo "$*"; }

REPO=carongutermuth113/waytv; BRANCH=main; GITHUB_TOKEN=""; NOTIFY=yes
# shellcheck disable=SC1091
[[ -r /etc/waytv/update.conf ]] && . /etc/waytv/update.conf
LIB=/var/lib/waytv
mkdir -p "$LIB"
installed="$(cat /etc/waytv/version 2>/dev/null || echo 0)"

# Apps queued while Android was not running (for example Aurora Store on a fresh install).
if [[ -s /etc/waytv/pending-apps && -x /usr/local/bin/waytv-apps ]]; then
    /usr/local/bin/waytv-apps pending >/dev/null 2>&1 || true
fi

# 1. Newest setup script on GitHub (API works for public repos, and private ones with a token).
latest=""
tmp="$(mktemp)"
hdr=(-H "Accept: application/vnd.github.raw")
[[ -n $GITHUB_TOKEN ]] && hdr+=(-H "Authorization: Bearer $GITHUB_TOKEN")
code="$(curl -sL --max-time 60 "${hdr[@]}" -o "$tmp" -w '%{http_code}' \
        "https://api.github.com/repos/$REPO/contents/waytv-setup.sh?ref=$BRANCH" || true)"
gh_problem=""
case "$code" in
    200) if bash -n "$tmp" 2>/dev/null; then
             latest="$(sed -n 's/^SCRIPT_VERSION=\([0-9][0-9]*\).*/\1/p' "$tmp" | head -n1)"
         else
             gh_problem="the downloaded script has syntax errors; not using it."
         fi ;;
    404) if [[ -z $GITHUB_TOKEN ]]; then
             gh_problem="the repo $REPO is private (or does not exist). Make it public, or put a read-only token after GITHUB_TOKEN= in /etc/waytv/update.conf."
         else
             gh_problem="$REPO or branch $BRANCH not found, or the token cannot read this repo (it needs Contents: Read-only on $REPO)."
         fi ;;
    401) gh_problem="the GITHUB_TOKEN in /etc/waytv/update.conf is wrong or expired. Make a new one." ;;
    403|429) gh_problem="GitHub refused or rate-limited the request; it will retry at the next check." ;;
    000|"") gh_problem="no connection to github.com (check the network/DNS)." ;;
    *)   gh_problem="GitHub answered HTTP $code." ;;
esac
script_new=0
if [[ $latest =~ ^[0-9]+$ && $installed =~ ^[0-9]+$ ]] && (( latest > installed )); then
    script_new=1
    install -m 700 "$tmp" "$LIB/latest-setup.sh"
fi
rm -f "$tmp"
[[ -n $latest ]] || say "Script update check skipped: ${gh_problem:-could not read the version.}"

# 2. Pending Debian updates.
apt-get -qq -o DPkg::Lock::Timeout=300 update >/dev/null 2>&1 || true
debs="$(apt list --upgradable 2>/dev/null | grep -c 'upgradable from' || true)"

# 3. New kernel waiting for a reboot.
newest="$(ls -1 /lib/modules | sort -V | tail -n1)"
reboot_needed=0
[[ -n $newest && $newest != "$(uname -r)" ]] && reboot_needed=1

msg=""
(( script_new )) && msg+="WayTV script v$latest is available (installed: v$installed). "
(( debs > 0 )) && msg+="$debs Debian update(s) waiting. "
(( reboot_needed )) && msg+="Reboot needed for the new kernel. "
printf 'LATEST=%s\nINSTALLED=%s\nDEBIAN_UPDATES=%s\nREBOOT=%s\nCHECKED=%s\n' \
    "${latest:-unknown}" "$installed" "$debs" "$reboot_needed" "$(date '+%F %R')" > "$LIB/check.env"

if [[ -z $msg ]]; then
    rm -f /etc/waytv/status
    if [[ -n $latest ]]; then say "Everything is up to date (script v$installed)."
    else say "No Debian updates waiting. (Script version not checked, see above.)"; fi
    exit 0
fi
echo "$msg" > /etc/waytv/status
say "$msg"
say "Install now: sudo waytv-update (or Settings > update). The weekly update runs Sundays at 04:30."

# 4. Android notification (best effort; needs the Waydroid container running).
android_notify() {
    local title=$1 text=$2
    waydroid status 2>/dev/null | grep -q 'Container:.*RUNNING' || return 1
    waydroid shell -- /system/bin/cmd notification post -S bigtext -t "$title" waytv-update "$text" \
        >/dev/null 2>&1 && return 0
    printf "cmd notification post -S bigtext -t '%s' waytv-update '%s'\nexit\n" "$title" "$text" \
        | waydroid shell >/dev/null 2>&1
}
if [[ $WANT_NOTIFY -eq 1 && $NOTIFY == yes ]]; then
    if android_notify "WayTV updates available" \
        "${msg}They install automatically on Sunday at 04:30, or open Settings > update on Ctrl+Alt+F2."; then
        say "Android notification sent."
    else
        say "Could not post the Android notification (is Android running?)."
    fi
fi
exit 0
WAYTV_CHECK_EOF

    # Remote screen: lets a PC see and control Android with scrcpy through an SSH tunnel.
    put_file /usr/local/bin/waytv-remote 755 <<'WAYTV_REMOTE_EOF'
#!/usr/bin/env bash
# WayTV remote screen helper: see and control Android from a PC with scrcpy over SSH.
# ADB is never opened to the network; the PC reaches it only through an SSH tunnel.
#   waytv-remote          show status and the commands to run on your PC
#   sudo waytv-remote     same, and turn on network ADB inside Android if it is off
#   waytv-remote --ip     print only Android's internal IP (used by the Windows helper)
set -uo pipefail
ip="$(waydroid status 2>/dev/null | sed -n 's/^IP address:[[:space:]]*//p' | head -n1)"
ip="${ip:-192.168.240.112}"
if [[ ${1:-} == --ip ]]; then echo "$ip"; exit 0; fi

port_open() { timeout 3 bash -c "exec 3<>/dev/tcp/$ip/5555" 2>/dev/null; }
if ! port_open && [[ $EUID -eq 0 ]]; then
    echo "Turning on network ADB inside Android..."
    waydroid shell -- /system/bin/setprop service.adb.tcp.port 5555 >/dev/null 2>&1
    waydroid shell -- /system/bin/stop adbd >/dev/null 2>&1
    waydroid shell -- /system/bin/start adbd >/dev/null 2>&1
    sleep 3
fi
if port_open; then
    state="ready"
else
    state="NOT reachable. Is Android running? Try: sudo waytv-remote"
fi
box_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
user="$(cat /etc/waytv/user 2>/dev/null || id -un)"
cat <<EOF
Android ADB ($ip:5555): $state

On your PC (Windows: double-click windows\waytv-screen.bat from the GitHub repo), or by hand:
  1. ssh -N -L 15555:$ip:5555 $user@${box_ip:-<box-ip>}     (leave it open)
  2. adb connect 127.0.0.1:15555
  3. scrcpy -s 127.0.0.1:15555 --no-audio

The first time, the TV may ask "Allow USB debugging?": tick "Always allow" and press Allow.
EOF
WAYTV_REMOTE_EOF

    # Android app installer (Aurora Store); queues installs while Android is not running.
    put_file /usr/local/bin/waytv-apps 755 <<'WAYTV_APPS_EOF'
#!/usr/bin/env bash
# WayTV Android app installer.
#   sudo waytv-apps waytv            install/update the WayTV Settings app (controller-friendly settings)
#   sudo waytv-apps aurora           install Aurora Store (Google Play client) from F-Droid
#   sudo waytv-apps at4k             install/update AT4K Launcher (Android TV launcher) from its GitHub releases
#   sudo waytv-apps install <apk>    install an .apk file or https:// link (apps Aurora calls "not supported")
#   sudo waytv-apps pending          install apps that were queued while Android was not running
#   sudo waytv-apps list             list installed Android apps
set -uo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo waytv-apps $*"; exit 1; }
PENDING=/etc/waytv/pending-apps
KUSER="$(cat /etc/waytv/user)"
UIDN="$(id -u "$KUSER")"
as_user() { runuser -u "$KUSER" -- env XDG_RUNTIME_DIR="/run/user/$UIDN" "$@"; }
android_up() { waydroid status 2>/dev/null | grep -q 'Session:.*RUNNING'; }
has_pkg() { as_user waydroid app list 2>/dev/null | grep -q "packageName: $1\$"; }
queue() {
    grep -qx "$1" "$PENDING" 2>/dev/null || echo "$1" >> "$PENDING"
    echo "Android is not running. $2 is queued and installs automatically once it is (15 min after boot, then daily)."
}
unqueue() {
    [[ -f $PENDING ]] || return 0
    sed -i "/^$1\$/d" "$PENDING"
    [[ -s $PENDING ]] || rm -f "$PENDING"
}

# install_fdroid <queue key> <display name> <package id>: newest suggested build from f-droid.org
install_fdroid() {
    local key=$1 name=$2 pkg=$3 code tmp
    if ! android_up; then queue "$key" "$name"; return 0; fi
    if has_pkg "$pkg"; then
        echo "$name is already installed (it updates itself)."
        unqueue "$key"; return 0
    fi
    code="$(curl -fsSL --max-time 30 "https://f-droid.org/api/v1/packages/$pkg" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["suggestedVersionCode"])' 2>/dev/null)"
    [[ $code =~ ^[0-9]+$ ]] || { echo "Could not get $name's version from F-Droid."; return 1; }
    tmp="$(mktemp --suffix=.apk)"
    echo "Downloading $name (F-Droid build $code)..."
    if ! curl -fL --max-time 600 -o "$tmp" "https://f-droid.org/repo/${pkg}_${code}.apk" \
       || [[ "$(head -c2 "$tmp")" != PK ]]; then
        rm -f "$tmp"; echo "Download of $name failed."; return 1
    fi
    local rc=0
    put_apk "$tmp" "$name" "$pkg" || rc=1
    rm -f "$tmp"
    [[ $rc -eq 0 ]] && unqueue "$key"
    return $rc
}

# put_apk <apk file> <display name> [package id]: install (or update) an APK in Android.
# Android does not check Play Store "compatibility" (TV-only, tablet-only), only the APK itself.
put_apk() {
    local apk=$1 name=$2 pkg=${3:-} tmp rc=0
    if [[ "$(head -c2 "$apk" 2>/dev/null)" != PK ]]; then
        echo "$apk is not an APK file."; return 1
    fi
    # Copy to a file the kiosk user can read; the original may sit in a private folder.
    tmp="$(mktemp --suffix=.apk)"
    cp "$apk" "$tmp" && chmod 644 "$tmp"
    echo "Installing $name in Android..."
    as_user waydroid app install "$tmp" || rc=1
    rm -f "$tmp"
    if [[ $rc -ne 0 ]]; then
        echo "Install of $name failed. Split APKs (.apks, .xapk, .apkm bundles) are not supported; use a single .apk."
        return 1
    fi
    sleep 3
    if [[ -z $pkg ]] || has_pkg "$pkg"; then
        echo "$name installed. Open it from the Android app drawer."
    else
        echo "$name was sent to Android but does not show up yet; check the TV screen."
    fi
}

# install_github <queue key> <display name> <package id> <owner/repo>: newest release .apk
install_github() {
    local key=$1 name=$2 pkg=$3 repo=$4 url tmp
    if ! android_up; then queue "$key" "$name"; return 0; fi
    url="$(curl -fsSL --max-time 30 "https://api.github.com/repos/$repo/releases/latest" \
        | python3 -c 'import json,sys; r=json.load(sys.stdin); print(next(a["browser_download_url"] for a in r["assets"] if a["name"].endswith(".apk")))' 2>/dev/null)"
    [[ $url == https://* ]] || { echo "Could not find $name's newest release on GitHub ($repo)."; return 1; }
    tmp="$(mktemp --suffix=.apk)"
    echo "Downloading $name from $url ..."
    if ! curl -fL --max-time 600 -o "$tmp" "$url"; then
        rm -f "$tmp"; echo "Download of $name failed."; return 1
    fi
    local rc=0
    put_apk "$tmp" "$name" "$pkg" || rc=1
    rm -f "$tmp"
    [[ $rc -eq 0 ]] && unqueue "$key"
    return $rc
}

# install_waytv: the WayTV Settings app, newest "app-v<N>" release of the WayTV repo.
# Installs only if missing or older, then pairs it with the agent on the box.
install_waytv() {
    local REPO=carongutermuth113/waytv GITHUB_TOKEN="" tag url code have tmp rc=0
    # shellcheck disable=SC1091
    [[ -r /etc/waytv/update.conf ]] && . /etc/waytv/update.conf
    if ! android_up; then queue waytv "WayTV Settings"; return 0; fi
    local hdr=()
    [[ -n $GITHUB_TOKEN ]] && hdr=(-H "Authorization: Bearer $GITHUB_TOKEN")
    read -r tag url < <(curl -fsSL --max-time 30 "${hdr[@]}" "https://api.github.com/repos/$REPO/releases?per_page=30" \
        | python3 -c '
import json, re, sys
best = None
for r in json.load(sys.stdin):
    m = re.fullmatch(r"app-v(\d+)", r.get("tag_name", ""))
    a = [x["browser_download_url"] for x in r.get("assets", []) if x["name"] == "waytv-settings.apk"]
    if m and a and not r.get("draft") and (best is None or int(m.group(1)) > best[0]):
        best = (int(m.group(1)), r["tag_name"], a[0])
print(best[1], best[2]) if best else None' 2>/dev/null)
    if [[ $url != https://* ]]; then
        echo "Could not find a WayTV Settings release on GitHub ($REPO)."; return 1
    fi
    code=${tag#app-v}
    have="$(timeout 30 waydroid shell -- dumpsys package tv.waytv.settings 2>/dev/null \
            | sed -n 's/.*versionCode=\([0-9]*\).*/\1/p' | head -n1)"
    if [[ $have =~ ^[0-9]+$ ]] && (( have >= code )); then
        echo "WayTV Settings is up to date (version $have)."
    else
        tmp="$(mktemp --suffix=.apk)"
        echo "Downloading WayTV Settings ($tag)..."
        if curl -fL --max-time 600 -o "$tmp" "$url"; then
            put_apk "$tmp" "WayTV Settings" tv.waytv.settings || rc=1
        else
            echo "Download of WayTV Settings failed."; rc=1
        fi
        rm -f "$tmp"
    fi
    if [[ $rc -eq 0 ]]; then
        unqueue waytv
        /usr/local/bin/waytv-agent pair 2>/dev/null || true
    fi
    return $rc
}

# install_any <file.apk | https://...>: sideload any single APK.
install_any() {
    local src=${1:-} tmp rc
    [[ -n $src ]] || { echo "Usage: sudo waytv-apps install <file.apk | https://link-to.apk>"; return 1; }
    android_up || { echo "Android is not running. Start it first (it runs on the TV screen), then try again."; return 1; }
    if [[ $src == https://* ]]; then
        tmp="$(mktemp --suffix=.apk)"
        echo "Downloading $src ..."
        curl -fL --max-time 600 -o "$tmp" "$src" || { rm -f "$tmp"; echo "Download failed."; return 1; }
        put_apk "$tmp" "$(basename "${src%%\?*}")"; rc=$?
        rm -f "$tmp"; return $rc
    fi
    [[ -f $src ]] || { echo "File not found: $src"; return 1; }
    put_apk "$src" "$(basename "$src")" || return 1
    /usr/local/bin/waytv-agent pair >/dev/null 2>&1 || true   # in case it was the WayTV Settings app
}

case "${1:-}" in
    aurora)  install_fdroid aurora "Aurora Store" com.aurora.store ;;
    waytv)   install_waytv ;;
    at4k)    install_github at4k "AT4K Launcher" com.overdevs.at4k avadhesh18/at4k ;;
    install) install_any "${2:-}" ;;
    pending)
        [[ -s $PENDING ]] || exit 0
        android_up || exit 0
        rc=0
        while read -r app; do
            case "$app" in
                aurora) install_fdroid aurora "Aurora Store" com.aurora.store || rc=1 ;;
                waytv)  install_waytv || rc=1 ;;
                at4k)   install_github at4k "AT4K Launcher" com.overdevs.at4k avadhesh18/at4k || rc=1 ;;
            esac
        done < <(cat "$PENDING")
        exit $rc ;;
    list)    as_user waydroid app list ;;
    *)       sed -n '2,8p' "$0"; exit 1 ;;
esac
WAYTV_APPS_EOF

    # Crash report: tells in plain words why Android apps close.
    put_file /usr/local/bin/waytv-crashlog 755 <<'WAYTV_CRASHLOG_EOF'
#!/usr/bin/env bash
# WayTV crash report: why do Android apps crash or close?
#   sudo waytv-crashlog          show the report and save it to /var/log/waytv-crash-report.txt
#   sudo waytv-crashlog --clear  empty Android's crash log; then open the app that crashes and
#                               run sudo waytv-crashlog again, so only that crash is shown
set -uo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo waytv-crashlog"; exit 1; }
OUT=/var/log/waytv-crash-report.txt
ash() { timeout 30 waydroid shell -- "$@" 2>/dev/null; }
android_up=0
waydroid status 2>/dev/null | grep -q 'Session:.*RUNNING' && android_up=1

if [[ ${1:-} == --clear ]]; then
    [[ $android_up -eq 1 ]] || { echo "Android is not running."; exit 1; }
    ash /system/bin/logcat -c -b all
    echo "Crash log cleared. Now open the app that crashes, then run: sudo waytv-crashlog"
    exit 0
fi

report="$(
    echo "WayTV crash report, $(date '+%F %T')"
    echo; echo "== Debian memory"
    free -h; swapon --show
    echo "memory pressure: $(head -n1 /proc/pressure/memory 2>/dev/null)"
    echo; echo "== Debian out-of-memory kills (this boot)"
    # Real kernel OOM kills only (Android's "libprocessgroup: Successfully killed" lines are normal app exits).
    ooms="$(journalctl -k -b --no-pager 2>/dev/null | grep -E 'Out of memory: Killed process|oom-kill:|invoked oom-killer' \
            | grep -v libprocessgroup | tail -n 15)"
    echo "${ooms:-none}"
    if [[ $android_up -eq 1 ]]; then
        echo; echo "== Android settings"
        for p in ro.product.cpu.abilist ro.dalvik.vm.native.bridge dalvik.vm.heapgrowthlimit \
                 dalvik.vm.heapsize persist.waydroid.width persist.waydroid.height; do
            echo "$p=$(ash /system/bin/getprop "$p" | tr -d '\r')"
        done
        echo; echo "== Android low-memory kills (last 20)"
        ash /system/bin/logcat -d -b main,system,events | tr -d '\r' \
            | grep -iE 'lowmemorykiller|lmkd.*kill|am_kill' | tail -n 20
        echo; echo "== App crashes (newest last)"
        ash /system/bin/logcat -d -b crash | tr -d '\r' | tail -n 150
    else
        echo; echo "Android is not running, so its crash log cannot be read."
    fi
)"

# Plain-language hints from the report (the settings section is left out of the matching).
src="$(sed '/^== Android settings/,/^== Android low-memory/d' <<< "$report")"
hints=()
if [[ $android_up -eq 1 ]] && grep -qE '^ro\.dalvik\.vm\.native\.bridge=(0)?$' <<< "$report"; then
    hints+=("ARM translation is not active, so ARM-only apps cannot start. Re-run: sudo /usr/local/lib/waytv/waytv-setup.sh --force")
fi
grep -qiE 'com\.google\.android\.gms|GooglePlayServices|play services' <<< "$src" && \
    hints+=("An app needs Google Play Services, which the VANILLA Android image does not have. Such apps (YouTube, Netflix, Google apps, many games) close right after opening. Fixing this needs a different Android image (GApps or microG).")
grep -qiE 'UnsatisfiedLinkError|couldn.t find "lib|dlopen failed|libhoudini|libndk' <<< "$src" && \
    hints+=("An app has ARM-only code that did not load: ARM translation is missing or failing. Re-run: sudo /usr/local/lib/waytv/waytv-setup.sh --force")
grep -qi 'OutOfMemoryError' <<< "$src" && \
    hints+=("An app ran out of its Java memory limit (OutOfMemoryError).")
grep -qiE 'lowmemorykiller|am_kill' <<< "$src" && \
    hints+=("Android closed apps because RAM was full. Use 1080p instead of 4K (Settings > resolution) and keep few apps open.")
grep -qE 'Out of memory: Killed process|oom-kill:' <<< "$src" && \
    hints+=("Debian ran out of memory and killed processes. Check that swap is on (the 'Debian memory' section above should list zram and /waytv.swap).")
grep -qiE 'libEGL|libGLES|gralloc|mesa|iris|i965|SIGSEGV' <<< "$src" && \
    hints+=("A native crash (possibly graphics/GPU). Send this report for a closer look.")

if grep -q 'was already used. If you are using LazyColumn' <<< "$src" && grep -q 'com.aurora.store' <<< "$src"; then
    hints+=("Aurora Store bug: its home feed lists the same app twice and it crashes (Aurora issue #1611, https://gitlab.com/AuroraOSS/AuroraStore/-/issues/1611). Not the box. Workaround: open Aurora and tap Search right away, before the home screen loads. A later Aurora version should fix it.")
fi
if [[ ${#hints[@]} -eq 0 ]] && grep -q 'FATAL EXCEPTION' <<< "$src"; then
    app="$(grep -m1 -o 'Process: [^,]*' <<< "$src" | cut -d' ' -f2)"
    exc="$(grep -A2 'FATAL EXCEPTION' <<< "$src" | grep -m1 -oE '[a-zA-Z0-9_.]+(Exception|Error)[^:]*(: .{0,120})?')"
    hints+=("${app:-An app} crashed because of a bug in the app itself (${exc:-Java exception}). Memory, ARM translation and Play Services are not the cause. Look for an app update or report it to the app's developer.")
fi

{
    echo "$report"
    echo; echo "== What this probably means"
    if [[ ${#hints[@]} -eq 0 ]]; then
        echo "- No known cause found. Run 'sudo waytv-crashlog --clear', open the app until it crashes, then run 'sudo waytv-crashlog' again."
    else
        printf -- '- %s\n' "${hints[@]}"
    fi
    echo; echo "Saved to $OUT"
} | tee "$OUT"
WAYTV_CRASHLOG_EOF

    # Shown when you log in over SSH or on a console.
    put_file /etc/update-motd.d/90-waytv 755 <<'EOF'
#!/bin/sh
[ -s /etc/waytv/status ] && printf '\nWayTV: %s\nRun: sudo waytv-update\n\n' "$(cat /etc/waytv/status)"
exit 0
EOF

    # Updater: used by the weekly timer, the settings menu, and this script.
    put_file /usr/local/bin/waytv-update 755 <<'WAYTV_UPDATE_EOF'
#!/usr/bin/env bash
# WayTV updater: upgrades Debian packages and the Waydroid Android image.
#   sudo waytv-update                   update the WayTV script from GitHub, upgrade Debian and
#                                      Android, restart the kiosk if it was running
#   sudo waytv-update --no-restart      leave the kiosk stopped (used by the setup script)
#   sudo waytv-update --no-self-update  skip the GitHub script update
#   sudo waytv-update --auto            weekly timer: follows AUTO_APPLY_SCRIPT and reboots
#                                      if a new kernel was installed
set -uo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo waytv-update"; exit 1; }
export DEBIAN_FRONTEND=noninteractive
APT=(apt-get -y -o DPkg::Lock::Timeout=600
     -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
RESTART=1; AUTO=0; SELF_UPDATE=1
for a in "$@"; do
    case "$a" in
        --no-restart) RESTART=0 ;; --auto) AUTO=1 ;; --no-self-update) SELF_UPDATE=0 ;;
    esac
done
AUTO_APPLY_SCRIPT=yes
# shellcheck disable=SC1091
[[ -r /etc/waytv/update.conf ]] && . /etc/waytv/update.conf
rc=0

if [[ $SELF_UPDATE -eq 1 ]]; then
    echo "==> Checking GitHub for a new WayTV setup script"
    /usr/local/bin/waytv-check --no-notify | grep -i 'script\|github' || true
    new="$(sed -n 's/^SCRIPT_VERSION=\([0-9][0-9]*\).*/\1/p' /var/lib/waytv/latest-setup.sh 2>/dev/null | head -n1)"
    cur="$(cat /etc/waytv/version 2>/dev/null || echo 0)"
    if [[ $new =~ ^[0-9]+$ && $cur =~ ^[0-9]+$ ]] && (( new > cur )); then
        if [[ $AUTO -eq 0 || $AUTO_APPLY_SCRIPT == yes ]]; then
            echo "==> Installing WayTV setup script v$new (was v$cur)"
            bash /var/lib/waytv/latest-setup.sh --no-upgrade || { echo "Script update failed."; rc=1; }
        else
            echo "Script v$new is available; AUTO_APPLY_SCRIPT=no, so it was not installed."
        fi
    fi
fi

echo "==> Upgrading Debian packages"
"${APT[@]}" update || rc=1
"${APT[@]}" full-upgrade || rc=1
"${APT[@]}" autoremove --purge || true
"${APT[@]}" autoclean || true

echo "==> Upgrading the Waydroid Android image"
was_active=0
if systemctl is-active --quiet waydroid-kiosk.service; then
    was_active=1
    systemctl stop waydroid-kiosk.service
fi
KUSER="$(cat /etc/waytv/user 2>/dev/null || true)"
[[ -n $KUSER ]] && runuser -u "$KUSER" -- waydroid session stop >/dev/null 2>&1 || true
waydroid upgrade || { echo "Waydroid upgrade failed; Android keeps its current image."; rc=1; }

newest="$(ls -1 /lib/modules | sort -V | tail -n1)"
if [[ -n $newest && $newest != "$(uname -r)" ]]; then
    echo "New kernel $newest installed. Reboot to use it: sudo reboot"
    if [[ $AUTO -eq 1 ]]; then systemctl reboot; exit $rc; fi
fi
if [[ $was_active -eq 1 && $RESTART -eq 1 ]]; then
    systemctl start waydroid-kiosk.service
    echo "==> Updating the WayTV Settings app (once Android is up)"
    for _ in $(seq 60); do
        waydroid status 2>/dev/null | grep -q 'Session:.*RUNNING' && break
        sleep 3
    done
    sleep 20
    /usr/local/bin/waytv-apps waytv || echo "App update skipped; it is retried at the next update."
fi
/usr/local/bin/waytv-check --quiet || true   # refresh status; notify if something is still pending
[[ $rc -eq 0 ]] && echo "Update finished." || echo "Update finished with errors (see above)."
exit $rc
WAYTV_UPDATE_EOF

    # Runs as root: sets resolution, powers on the TV, then hands off to the user.
    put_file /usr/local/bin/waytv-kiosk-start 755 <<'EOF'
#!/bin/sh
# Root part of the kiosk: wake the TV, start the user session.
KUSER="$(cat /etc/waytv/user)"
UID_NUM="$(id -u "$KUSER")"

# Resolution is applied by waytv-kiosk-user: waydroid prop set only works while Android runs.
echo 'on 0' | timeout 10 cec-client -s -d 1 >/dev/null 2>&1 || true   # best effort, never blocks boot

systemctl start "user@${UID_NUM}.service" || true

# Performance overlay on (sudo waytv-perf overlay on): labwc + waybar instead of cage.
OVERLAY=0
[ -r /etc/waytv/display.conf ] && . /etc/waytv/display.conf
if [ "$OVERLAY" = 1 ] && command -v labwc >/dev/null && command -v waybar >/dev/null; then
    set -- labwc -C /usr/local/lib/waytv/labwc -S /usr/local/bin/waytv-kiosk-user
else
    set -- cage -s -- /usr/local/bin/waytv-kiosk-user
fi
exec runuser -u "$KUSER" -- env XDG_RUNTIME_DIR="/run/user/$UID_NUM" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$UID_NUM/bus" "$@"
EOF

    # Runs as the normal user inside cage: start Waydroid and show it fullscreen.
    put_file /usr/local/bin/waytv-kiosk-user 755 <<'EOF'
#!/bin/sh
# Start Android, wait until it is really up (slow with 4 GB RAM), apply the resolution from
# /etc/waytv/display.conf, then show Android fullscreen.
CONF=/etc/waytv/display.conf
[ -r "$CONF" ] && . "$CONF"
WIDTH="${WIDTH:-1920}"; HEIGHT="${HEIGHT:-1080}"

# Switch the HDMI output to WIDTHxHEIGHT at the fastest refresh rate up to 60 Hz.
# Without this the compositor keeps the TV's preferred mode (often 4K at 30 Hz on this
# box) and only scales Android up, which is both blurry and choppy.
set_hdmi_mode() {
    command -v wlr-randr >/dev/null 2>&1 || return 0
    # REFRESH in display.conf (chosen in the WayTV Settings app) picks that exact rate;
    # without it the fastest rate up to 60 Hz is used.
    best=$(wlr-randr 2>/dev/null | awk -v want="${WIDTH}x${HEIGHT}" -v pick="${REFRESH:-0}" '
        /^[^ ]/ { if (out != "") exit; out = $1; next }
        $1 == want && $2 == "px," {
            r = $3 + 0
            if (pick > 0) {
                d = r - pick; if (d < 0) d = -d
                if (rate == 0 || d < bestd) { rate = r; bestd = d }
            } else if (r <= 60.5 && r > rate) rate = r
        }
        END { if (out != "" && rate > 0) printf "%s %s@%f\n", out, want, rate }')
    [ -n "$best" ] || return 0
    # shellcheck disable=SC2086
    set -- $best
    wlr-randr --output "$1" --mode "$2" >/dev/null 2>&1 || true
}
set_hdmi_mode

wait_up() {
    i=0
    while [ "$i" -lt 120 ]; do
        waydroid status 2>/dev/null | grep -q 'Session:.*RUNNING' && return 0
        sleep 1; i=$((i + 1))
    done
    return 1
}
start_android() {
    waydroid session stop >/dev/null 2>&1 || true
    waydroid session start >/dev/null 2>&1 &
    wait_up
}
start_android
# Resolution props can only be set while Android runs, and apply at its next start:
# if they differ, set them and restart Android once.
if [ "$(waydroid prop get persist.waydroid.width 2>/dev/null)" != "$WIDTH" ] ||
   [ "$(waydroid prop get persist.waydroid.height 2>/dev/null)" != "$HEIGHT" ]; then
    waydroid prop set persist.waydroid.width "$WIDTH" &&
        waydroid prop set persist.waydroid.height "$HEIGHT" && start_android
fi
waydroid show-full-ui
# show-full-ui returns as soon as Android's screen is up. cage keeps running after that,
# but labwc (performance overlay) quits when this script ends, so stay alive while
# Android runs. If Android stops, the kiosk exits and systemd restarts it.
while waydroid status 2>/dev/null | grep -q 'Session:.*RUNNING'; do sleep 5; done
EOF

    put_file /etc/systemd/system/waydroid-kiosk.service 644 <<'EOF'
[Unit]
Description=WayTV Waydroid fullscreen kiosk
After=waydroid-container.service seatd.service systemd-user-sessions.service network.target
Wants=waydroid-container.service seatd.service systemd-user-sessions.service
Conflicts=getty@tty1.service
OnFailure=waytv-fallback.service
StartLimitIntervalSec=120
StartLimitBurst=3

[Service]
TTYPath=/dev/tty1
StandardInput=tty
StandardOutput=journal
ExecStart=/usr/local/bin/waytv-kiosk-start
# If Android's screen closes for any reason, bring it straight back.
Restart=always
RestartSec=3
# Debian's OOM killer should pick something else before the kiosk screen.
OOMScoreAdjust=-500

[Install]
WantedBy=graphical-kiosk.target
EOF

    # If the kiosk gives up, bring back a text login on tty1 so the box is not dead.
    put_file /etc/systemd/system/waytv-fallback.service 644 <<'EOF'
[Unit]
Description=WayTV kiosk failed: restore text login on tty1

[Service]
Type=oneshot
ExecStart=/bin/systemctl start getty@tty1.service
EOF

    put_file /etc/systemd/system/graphical-kiosk.target 644 <<'EOF'
[Unit]
Description=Boot target for the WayTV Waydroid kiosk
# Pull in the normal system first (network, SSH, user logins), like graphical.target does.
# Without this, /run/nologin is never removed and only root can log in.
Requires=multi-user.target
Wants=waydroid-kiosk.service
After=multi-user.target waydroid-kiosk.service
AllowIsolate=yes
EOF

    put_file /etc/systemd/system/waytv-update.service 644 <<'EOF'
[Unit]
Description=WayTV weekly update (Debian + Waydroid image)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/waytv-update --auto
EOF

    put_file /etc/systemd/system/waytv-update.timer 644 <<'EOF'
[Unit]
Description=Run the WayTV update every Sunday at 04:30

[Timer]
OnCalendar=Sun *-*-* 04:30:00
RandomizedDelaySec=15min
Persistent=true

[Install]
WantedBy=timers.target
EOF

    put_file /etc/systemd/system/waytv-check.service 644 <<'EOF'
[Unit]
Description=WayTV update check (GitHub script version + Debian updates)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/waytv-check --quiet
EOF

    put_file /etc/systemd/system/waytv-check.timer 644 <<'EOF'
[Unit]
Description=Check for WayTV updates daily and 15 minutes after boot

[Timer]
OnBootSec=15min
OnCalendar=daily
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
}

do_install() {
    check_platform
    check_resources
    # Earlier versions booted without systemd-user-sessions, leaving /run/nologin behind.
    systemctl start systemd-user-sessions.service 2>/dev/null || true
    local kiosk_was_active=0 prev="none"
    systemctl is-active --quiet waydroid-kiosk.service 2>/dev/null && kiosk_was_active=1
    [[ -r $STATE/version ]] && prev="$(cat "$STATE/version")"
    if [[ -f $MARK ]]; then
        log "Already installed (version $prev). Script version $SCRIPT_VERSION: adding only what is new."
    fi

    # Questions first, so the rest can run unattended.
    ask_options

    # Always-checked steps: each one is idempotent and only changes what is missing.
    install_packages
    [[ $UPGRADE -eq 1 ]] && upgrade_debian
    ensure_user_groups
    ensure_binder
    write_config
    setup_waydroid
    write_helpers
    tune_memory
    if [[ -n $MIGRATED ]]; then
        CHANGES+=("moved the CN60 install to WayTV: /etc/cn60 -> /etc/waytv, cn60-* commands -> waytv-*")
        systemctl daemon-reload
        # shellcheck disable=SC2086
        [[ $MIGRATED != " none" ]] && { systemctl enable --now $MIGRATED || warn "Could not re-enable:$MIGRATED"; }
    fi

    # One-time steps: bump the number to make an existing install run the step again.
    log "Checking one-time steps"
    run_step arm-translation 2 install_arm_translation
    run_step os-tuning       1 tune_os
    run_step auto-updates    1 setup_auto_updates
    run_step ssh             1 setup_ssh
    run_step self-update     1 setup_self_update
    run_step network-clash   1 fix_network_clash
    run_step bt-audio        1 fix_bt_audio

    # After ARM translation: both edit waydroid.cfg [properties].
    tune_android

    if [[ $UPGRADE -eq 1 ]]; then
        log "Upgrading the Waydroid Android image"
        /usr/local/bin/waytv-update --no-restart --no-self-update >/dev/null 2>&1 \
            && echo "  done" || warn "Android image upgrade failed; run 'sudo waytv-update' to see why."
    fi

    log "⚙️  Checking the WayTV Settings app"
    /usr/local/bin/waytv-apps waytv || warn "WayTV Settings app install failed; retry with: sudo waytv-apps waytv"

    if [[ "$(opt_get AURORA_STORE)" == yes ]]; then
        log "Checking Aurora Store"
        /usr/local/bin/waytv-apps aurora || warn "Aurora Store install failed; retry with: sudo waytv-apps aurora"
    fi
    
    log "📥 Preparing optional apps for the app installer"
    mkdir -p /data/apps
    # SmartTube (YouTube client for Android TV)
    if [[ ! -f /data/apps/smarttube.apk ]]; then
        wget -q -O /data/apps/smarttube.apk.tmp https://github.com/yuliskov/SmartTubeNext/releases/download/latest/smarttube.apk 2>/dev/null \
            && mv /data/apps/smarttube.apk.tmp /data/apps/smarttube.apk \
            && echo "  Downloaded SmartTube" \
            || rm -f /data/apps/smarttube.apk.tmp
    fi
    # Aurora Store (Google Play client)
    if [[ ! -f /data/apps/aurorastore.apk ]]; then
        wget -q -O /data/apps/aurorastore.apk.tmp "https://gitlab.com/api/v4/projects/aurora%2Fstore/releases" 2>/dev/null \
            | grep -o 'https://[^"]*\.apk' | head -1 | xargs -I {} wget -q -O /data/apps/aurorastore.apk.tmp {} 2>/dev/null \
            && mv /data/apps/aurorastore.apk.tmp /data/apps/aurorastore.apk \
            && echo "  Downloaded Aurora Store" \
            || rm -f /data/apps/aurorastore.apk.tmp
    fi
    # Titanium Browser (web browser for Android TV)
    if [[ ! -f /data/apps/titanium-browser.apk ]]; then
        wget -q -O /data/apps/titanium-browser.apk.tmp https://github.com/jqssun/android-titanium-browser/releases/download/latest/app-release.apk 2>/dev/null \
            && mv /data/apps/titanium-browser.apk.tmp /data/apps/titanium-browser.apk \
            && echo "  Downloaded Titanium Browser" \
            || rm -f /data/apps/titanium-browser.apk.tmp
    fi

    log "🚀 Checking the boot target"
    systemctl enable --now seatd.service
    systemctl disable --now display-manager.service 2>/dev/null || true
    systemctl enable waydroid-kiosk.service
    systemctl set-default graphical-kiosk.target
    systemctl enable waytv-agent.service >/dev/null 2>&1 || warn "Could not enable waytv-agent.service."
    if printf '%s\n' "${CHANGES[@]}" | grep -q 'waytv-agent'; then
        systemctl restart waytv-agent.service || warn "waytv-agent did not start: journalctl -u waytv-agent"
    else
        systemctl start waytv-agent.service || true
    fi

    touch "$MARK"
    echo "$SCRIPT_VERSION" > "$STATE/version"
    /usr/local/bin/waytv-check --quiet --no-notify || true   # refresh the update status

    if [[ $kiosk_was_active -eq 1 ]]; then
        log "Restarting the kiosk to apply changes"
        systemctl restart waydroid-kiosk.service || warn "Kiosk restart failed: journalctl -u waydroid-kiosk -b"
    fi

    echo
    if [[ ${#CHANGES[@]} -eq 0 ]]; then
        echo "Nothing new to add. Everything is up to date."
    else
        echo "Changes this run:"
        printf '  - %s\n' "${CHANGES[@]}"
    fi
    newest="$(ls -1 /lib/modules | sort -V | tail -n1)"
    [[ -n $newest && $newest != "$(uname -r)" ]] && echo "A new kernel ($newest) is installed: reboot to use it."

    local ips
    ips="$(hostname -I 2>/dev/null | xargs || true)"
    cat <<EOM

SSH from another computer:  ssh $KUSER@${ips%% *}     (all addresses: ${ips:-unknown})

Next steps:
  - Test without rebooting:   sudo systemctl start waydroid-kiosk
  - Watch the logs:           journalctl -u waydroid-kiosk -b -f
  - Settings menu:            Ctrl+Alt+F2, log in, run: sudo waytv-settings
  - Update now:               sudo waytv-update
  - Check for updates:        sudo waytv-check
  - See the screen on a PC:   sudo waytv-remote
  - Why do apps close?        sudo waytv-crashlog
  - Install Aurora Store:     sudo waytv-apps aurora
  - Performance numbers:      sudo waytv-perf   (on the TV: sudo waytv-perf overlay on)
  - Self-update settings:     sudo nano /etc/waytv/update.conf
  - Weekly auto-update:       systemctl list-timers waytv-update.timer
  - Reboot to start the kiosk (and apply boot tweaks).
  - Revert to a normal boot:  sudo systemctl set-default multi-user.target
  - Uninstall everything:     sudo ./waytv-setup.sh --uninstall
EOM
}

# ------------------------------------------------------------ entry point
if [[ $MODE == uninstall ]]; then
    do_uninstall
else
    do_install
fi
