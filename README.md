# WayTV

Turn any x86_64 box running **Debian 13** (built and tested on a CN60 mini PC) into an
Android TV-style appliance: it boots straight into Android full screen, with
no Linux desktop.

Everything comes from one script, `waytv-setup.sh`. Run it once to
install. Run it again later to add only what is new.

> **Status:** in daily use on a CN60 mini PC (Celeron 2955U, 4 GB RAM, Debian 13) with
> a 4K Vizio TV. A fresh install from zero on another box has not been tested yet:
> try it on a box you can reinstall, and open an issue with the output if something fails.
>
> **Coming from the old CN60 script** (`cn60-waydroid-kiosk`)? Run `waytv-setup.sh` once.
> It moves the install over by itself, see [Moving from the CN60 script](#moving-from-the-cn60-script).

---

## What it does

| Area | What you get |
|---|---|
| **Android** | [Waydroid](https://waydro.id) with the VANILLA image (no Google apps), shown full screen at boot |
| **Kiosk** | No desktop environment. `cage` (a single-app Wayland compositor) runs Android on tty1 |
| **ARM apps** | ARM translation (libhoudini on Intel, libndk on AMD) through [casualsnek/waydroid_script](https://github.com/casualsnek/waydroid_script), so ARM-only apps can run |
| **Display** | Resolution set from a config file: 1080p at 60 Hz (default), 4K or 720p. The HDMI output switches to match |
| **TV control** | Turns the TV on at boot and has on/standby buttons over HDMI-CEC |
| **Sound** | PipeWire (or PulseAudio, if already installed) for HDMI and Bluetooth audio |
| **Bluetooth** | Pair keyboards, mice, gamepads, remotes, headphones and speakers from a menu |
| **SSH** | OpenSSH server enabled. Root login over SSH is disabled |
| **Updates** | Daily security updates, plus a weekly full Debian + Android image upgrade |
| **Self-update** | Checks this GitHub repo daily and installs new script versions in the weekly update |
| **Aurora Store** | Optional (the installer asks): open-source Google Play client, from F-Droid |
| **Remote screen** | See and control Android from a PC with scrcpy, through an SSH tunnel |
| **Notifications** | Android notification when a new script version, Debian updates or a reboot is waiting |
| **Low resources** | Detects low-RAM/low-CPU boxes and says so; then: zram + swap file, bigger app memory limit, Android protected from the OOM killer, kiosk restarts by itself, `waytv-crashlog` explains crashes |
| **OS tuning** | zram swap, journal size cap, no suspend, quiet fast boot, unneeded services off |
| **Settings app** | **WayTV Settings**, an Android app made for a TV remote or game controller: resolution, scaling, bottom bar, overlay, time zone, updates, restart, reboot |
| **Settings menu** | `sudo waytv-settings`: text menu on Ctrl+Alt+F2 |
| **Safe re-runs** | Re-running applies only new or changed parts and keeps your settings |
| **Uninstall** | `--uninstall` reverts everything the script added or changed |

---

## Requirements

### Minimum and recommended specs

| | Minimum | Recommended |
|---|---|---|
| **CPU** | x86_64, 2 cores (e.g. Celeron 2955U) | 4 cores or more (e.g. Intel N100, Core i3 8th gen, Ryzen 3) |
| **RAM** | 4 GB | 8 GB or more |
| **Storage** | 16 GB free (Waydroid image is 1-2 GB, plus apps and a 4 GB swap file) | SSD with 32 GB free or more |
| **GPU** | Intel HD (Haswell, 4th gen) or AMD with Mesa drivers | Intel UHD 600 or newer, AMD Vega/RDNA |
| **Video out** | HDMI 1.4: 1080p at 60 Hz (4K only at 30 Hz) | HDMI 2.0: 4K at 60 Hz |
| **OS** | Debian 13 "trixie", minimal install | same |

- **NVIDIA GPUs are not supported**: Waydroid needs Mesa (Intel/AMD) drivers.
- Tested on a CN60 mini PC (Celeron 2955U, Haswell graphics, 4 GB RAM): 1080p at 60 Hz
  is smooth, 4K runs at 30 Hz with the GPU near its limit.

**Low-resource alert:** the setup script checks the hardware at every run. Below 8 GB of RAM
or with fewer than 4 cores it prints `LOW RESOURCES DETECTED` and applies the low-memory
optimizations (zram at 100% of RAM, a 4 GB swap file, memory settings that swap idle apps
instead of closing them, OOM protection for Android). Below the minimum it also prints
`BELOW THE MINIMUM SPECS` with the reason, and continues. Recommended hardware gets standard
tuning (zram at 50%, no swap file). The result is saved in `/etc/waytv/hardware`.

### Also needed

- A normal user account with `sudo`
- A kernel with **binder** support (`binder_linux` module or binderfs). Debian's stock kernel has it
- Internet access. The first Waydroid download is about 1-2 GB
- A TV or monitor over HDMI. CEC is optional

---

## Quick start

On the box, logged in as your normal user:

```bash
# get the script
wget https://raw.githubusercontent.com/carongutermuth113/waytv/main/waytv-setup.sh

chmod +x waytv-setup.sh
sudo ./waytv-setup.sh
sudo reboot
```

After the reboot the box goes straight into Android.

If you copied the file from Windows and get `$'\r': command not found`, fix
the line endings first:

```bash
sed -i 's/\r$//' waytv-setup.sh
```

---

## Script options

```text
sudo ./waytv-setup.sh                    install; if already installed, add only what is new
sudo ./waytv-setup.sh --no-upgrade       same, but skip the Debian/Android upgrade
sudo ./waytv-setup.sh --force            redo every step, even ones already done
sudo ./waytv-setup.sh --aurora           install Aurora Store without asking
sudo ./waytv-setup.sh --no-aurora        do not install Aurora Store, do not ask
sudo ./waytv-setup.sh --uninstall        remove everything this script added
sudo ./waytv-setup.sh --uninstall --yes  same, without the confirmation prompt
./waytv-setup.sh --help                  show usage
```

Run it with `sudo` from your **normal user**, not from a root login. Android
runs as that user. If you forget `sudo`, the script restarts itself with it.

---

## How it works

### Boot flow

```text
power on
  └─ GRUB (1 s, quiet boot)
      └─ systemd default target: graphical-kiosk.target
          ├─ multi-user.target        network, SSH, Bluetooth, user logins
          └─ waydroid-kiosk.service   on tty1
              └─ /usr/local/bin/waytv-kiosk-start      (root)
                  ├─ read /etc/waytv/display.conf → set Waydroid width/height
                  ├─ HDMI-CEC "power on" to the TV (best effort, 10 s max)
                  └─ cage (as your user)
                      └─ /usr/local/bin/waytv-kiosk-user
                          ├─ waydroid session start
                          └─ waydroid show-full-ui   ← Android full screen
```

- If the kiosk crashes, systemd restarts it (up to 3 times in 2 minutes).
- If it keeps failing, `waytv-fallback.service` brings back a text login on
  tty1 so the box is never dead.
- **Ctrl+Alt+F2** opens a text console at any time. **Ctrl+Alt+F1** goes back
  to Android.

### What the installer does, step by step

0. **Questions.** Asks once whether to install Aurora Store, and keeps the answer in `/etc/waytv/options`, so the rest runs unattended.
1. **Platform check.** Stops if the machine is not x86_64. Warns if it is not Debian 13.
2. **Packages.** Installs only the missing ones and records exactly which ones it added, so uninstall removes only those.
3. **Debian upgrade.** `apt full-upgrade`. Skip it with `--no-upgrade`.
4. **User groups.** Adds your user to `video`, `render`, `input` and `seat`/`_seatd`, and turns on *linger* so your user session exists at boot without a login.
5. **Binder.** Loads `binder_linux` or mounts binderfs, and sets it to load at boot. Stops with a clear error if the kernel has neither.
6. **Config.** Writes `/etc/waytv/user`, and `/etc/waytv/display.conf` (1920x1080) only if it does not exist yet.
7. **Waydroid.** Enables the container service and runs `waydroid init -s VANILLA` if no image exists yet.
8. **Helpers and units.** Writes the scripts in `/usr/local/bin` and the systemd units. A file is rewritten only when its content changed.
9. **One-time steps,** each tracked with a version number:
   - `arm-translation`: libhoudini (Intel) or libndk (AMD) through waydroid_script
   - `os-tuning`: see [OS tuning](#os-tuning)
   - `auto-updates`: unattended-upgrades plus the weekly timer
   - `ssh`: sshd hardening drop-in, service enabled
   - `self-update`: enables the daily `waytv-check.timer`
   - `network-clash`: disables `dnsmasq.service` and `lxc-net.service`, which Waydroid does not need
   - `bt-audio`: lets WirePlumber handle Bluetooth audio without a desktop login
10. **Android image upgrade.** `waydroid upgrade`.
10. **WayTV Settings app.** Installs the newest `app-v*` release from this repo, or queues it until Android runs.
10. **Aurora Store** (if you said yes). Installs it now if Android is running, otherwise queues it.
11. **Boot target.** Enables seatd, disables any desktop login manager, and sets `graphical-kiosk.target` as the default.
12. **Summary.** Prints what changed this run, the box's IP for SSH, and next steps.

### Re-running = updating

When `/etc/waytv/installed` exists, the script does not ask anything. It:

- installs only packages that are missing
- rewrites only helper files whose content changed
- skips one-time steps already done at the same version. Each step's version is stored in `/etc/waytv/steps/<name>`, and bumping the number in the script makes old installs run that step once more
- never overwrites your resolution in `display.conf`
- restarts the kiosk if it was running
- prints `Nothing new to add` when there is nothing to do

So to update a box, copy the newest script over the old one and run it again.

---

## WayTV Settings app

An Android app, written in **Rust**, for changing the box's settings from the couch, with a
TV remote or a game controller. It is installed by the setup script (`sudo waytv-apps waytv` installs or
updates it by hand) and shows up in the app drawer and in Android TV launchers.

| Section | What you can do |
|---|---|
| **Display** | Resolution and refresh rate (every mode the TV offers, e.g. 4K at 60 Hz or 1080p at 120 Hz where the hardware allows), scaling (DPI), performance overlay, HDR status |
| **Android** | Hide/show the bottom bar, time zone, restart Android |
| **Updates** | See what is waiting, check now, update everything (script, Debian, Android, the app) with a live log |
| **System** | IP address, SSH, uptime, live FPS/CPU/RAM/GPU, reboot the box |

**Changes are staged, then applied together:** picking a value marks it as pending
(`current → new`). **Apply** sends all pending changes at once and restarts Android at most
once; **Discard** drops them.

**Controller:** D-pad / left stick to move, **A** to select, **B** to go back,
**LB/RB** to switch sections, **Y** to refresh.

**HDR:** the app shows whether the TV supports HDR (read from its EDID) and why the box
cannot output it yet: Waydroid draws Android in SDR only, and Debian 13's screen library
(wlroots 0.18) has no HDR output. No HDR switch until both support it.

### How it talks to the box

```text
WayTV Settings (Android)  ── HTTP + token ──►  waytv-agent (Debian, root)
      192.168.240.112                           listens only on 192.168.240.1:8765
                                                (Waydroid's private bridge, not the LAN)
```

- `waytv-agent.service` accepts only a fixed list of actions (the ones above); it cannot
  run arbitrary commands. API: [docs/agent-api.md](docs/agent-api.md).
- It is not reachable from your network: it listens only on Waydroid's internal bridge.
- Requests need a random token from `/etc/waytv/agent.token` (root-only). After Android
  starts, the agent puts it in the app's private folder (`files/agent.json`), which other
  Android apps cannot read.
- If the app says *Not paired*, run `sudo waytv-agent pair` on the box.
- Long tasks (updates) run in their own systemd unit, so they finish even when Android
  restarts; the app shows the result when it comes back.

### Building the app

The source is in [`app/`](app): Rust, a NativeActivity app with no Java or Kotlin code. Pushing a tag `app-v<N>` builds a signed APK with GitHub
Actions and publishes it as a release; boxes pick it up with `sudo waytv-apps waytv` and the
weekly update.

---

## Moving from the CN60 script

WayTV is the renamed, more general version of `cn60-waydroid-kiosk`. The old repo stays
as it is. To move a box over, run the new script once:

```bash
wget https://raw.githubusercontent.com/carongutermuth113/waytv/main/waytv-setup.sh
chmod +x waytv-setup.sh
sudo ./waytv-setup.sh --no-upgrade
```

It keeps all your settings and the records uninstall needs:

- `/etc/cn60` becomes `/etc/waytv` (resolution, overlay, options, backups, step versions)
- `cn60-*` commands, timers and services become `waytv-*`, with the same on/off state
- config drop-ins are renamed (`90-cn60.conf` → `90-waytv.conf`); content is kept
- self-update now follows this repo (`REPO=` in `/etc/waytv/update.conf`; your token is kept)
- the swap file stays `/cn60.swap` (new installs use `/waytv.swap`)

---

## Settings menu

Press **Ctrl+Alt+F2**, log in, then run:

```bash
sudo waytv-settings
```

| Option | What it does |
|---|---|
| `resolution` | 1080p at 60 Hz (default, smoothest), 4K (3840x2160, 30 Hz on the CN60) or 720p. Switches the HDMI output and Android, then restarts Android |
| `perf` | Performance overlay: FPS, CPU, RAM and GPU in the top-right corner of the TV (see below) |
| `tweaks` | TV tweaks: hide phone apps, scaling (DPI), hide the bottom bar, Android time zone (see below) |
| `bluetooth` | Scan/pair, status, reconnect, disconnect, forget devices |
| `tv` | TV on / standby over HDMI-CEC |
| `info` | IP address and SSH status |
| `remote` | How to see this screen on a PC (scrcpy) |
| `apps` | Install Aurora Store |
| `crashes` | Crash report: why apps close (same as `sudo waytv-crashlog`) |
| `restart` | Restart Android |
| `check` | Check for a new script version and Debian updates |
| `update` | Update the script from GitHub, then Debian + Android |
| `reboot` | Reboot the box |

---

## Resolution and smoothness

`/etc/waytv/display.conf` holds `WIDTH`, `HEIGHT` and optionally `REFRESH` (set from the app).
Without `REFRESH` the fastest rate up to 60 Hz is used; with it, that exact rate (e.g. 120).

The kiosk switches the **HDMI output** to the resolution in `/etc/waytv/display.conf`, at the
fastest refresh rate the TV offers **up to 60 Hz** (`wlr-randr`). Before v17 only Android's size
changed and the TV stayed in its preferred mode, often 4K at 30 Hz.

- The CN60's Haswell graphics can only send **4K at 30 Hz** over HDMI, and drawing Android at 4K
  keeps the GPU at 100%. **1080p at 60 Hz** is twice as smooth and far lighter. Measured on a CN60:
  4K = 30 FPS max with the GPU maxed out; 1080p = 60 FPS while scrolling, GPU about 80%.
- If the TV doesn't offer the chosen size, its preferred mode is kept and Android is scaled.
- After changing the size, `sudo waytv-tweaks density auto` sets matching scaling (1080p → 240).

---

## Performance overlay

Shows **FPS, CPU, RAM and GPU** usage in the top-right corner of the TV. Off by default.

```bash
sudo waytv-perf overlay on    # show it on the TV (installs labwc + waybar the first time, restarts Android)
sudo waytv-perf overlay off   # hide it
sudo waytv-perf               # same numbers live in the terminal (Ctrl+C to stop)
```

Or `sudo waytv-settings` → **perf**.

- **FPS** = frames Android drew in the last second. It is **0 when nothing moves on screen**; that is normal.
- **CPU** = whole box, **RAM** = used / total, **GPU** = Intel render engine busy (`intel_gpu_top`).
- cage cannot draw on top of Android, so with the overlay on the kiosk runs
  [labwc](https://labwc.github.io/) instead (same wlroots base, no borders, Android full screen)
  and [waybar](https://github.com/Alexays/Waybar) draws the box. With it off, cage is used as before.
- The overlay and its stats service (`waytv-perf.service`) cost about 1-2% CPU.
- The text size follows the resolution (24 px at 1080p, 48 px at 4K).

---

## TV tweaks

Stock Waydroid is a phone image. `sudo waytv-settings` → **tweaks** (or `sudo waytv-tweaks`) makes it fit a TV:

| Command | What it does |
|---|---|
| `sudo waytv-tweaks all` | All of the below in one go |
| `sudo waytv-tweaks apps-remove` | Hides Clock, Contacts, Music, Recorder, Calculator, Calendar and Camera |
| `sudo waytv-tweaks apps-restore` | Brings them back |
| `sudo waytv-tweaks density auto` | Scaling that matches the resolution (4K → 480 dpi, 1080p → 240, 720p → 160). Also `density 360`, `density reset` |
| `sudo waytv-tweaks navbar off` | Hides the bottom bar (`qemu.hw.mainkeys=1` in `waydroid.cfg`). Use the remote's Back and Home keys. `navbar on` shows it again. Restarts Android |
| `sudo waytv-tweaks timezone` | Sets Android's clock to the box's time zone (or `timezone Europe/Madrid`) |
| `sudo waytv-tweaks status` | Shows the current state |

Apps are hidden with `pm uninstall --user 0`, so they stay in the Android image and can be restored at any time.
Changing the resolution in the menu keeps the layout size if you set a scaling before.

---

## Bluetooth

Bluetooth devices pair with **Debian**, not with Android. Waydroid cannot pass
Bluetooth through to Android apps. Once a device is connected to Debian:

- ✅ Keyboards, mice, gamepads and Bluetooth remotes work in Android as normal input
- ✅ Headphones and speakers play Android's sound
- ❌ Android apps that talk to Bluetooth gadgets directly (fitness bands, etc.) do not work

### Pairing from the menu

1. `sudo waytv-settings`, then **bluetooth**, then **pair**
2. Put the device in pairing mode (usually hold its pair/power button until a light flashes), then press OK
3. Wait for the 20-second scan and pick the device
4. The menu pairs, trusts and connects it. If a keyboard shows a code, type it on that keyboard and press Enter

Trusted devices reconnect by themselves after a reboot.

### Pairing by hand

```bash
sudo bluetoothctl
  power on
  scan on               # wait for your device's MAC address
  scan off
  pair AA:BB:CC:DD:EE:FF
  trust AA:BB:CC:DD:EE:FF
  connect AA:BB:CC:DD:EE:FF
  devices Connected
  exit
```

---

## SSH

SSH is enabled for normal users. Root login over SSH is turned off.

```bash
ssh <your-user>@<box-ip>
```

The installer prints the IP at the end, and the settings menu shows it under
`info`. Settings live in `/etc/ssh/sshd_config.d/90-waytv.conf`.

---

## Aurora Store (apps from Google Play)

The Android image is VANILLA (no Google apps), so there is no Play Store.
[Aurora Store](https://f-droid.org/packages/com.aurora.store/) is an
open-source Play Store client. It downloads the same apps from Google Play,
and you can sign in **anonymously**.

- The installer **asks once** (`Install Aurora Store in Android? [Y/n]`) and
  remembers the answer. Use `--aurora` / `--no-aurora` to answer up front.
  Runs with no keyboard (the weekly self-update) never ask. They print how to
  install it later.
- It comes from **F-Droid** (newest suggested build, over HTTPS).
- If Android is not running yet (fresh install, before the first reboot), the
  install is **queued** and done automatically by the update check 15 minutes
  after boot.
- Once installed, Aurora Store updates itself.

```bash
sudo waytv-apps aurora     # install now (or menu: apps)
sudo waytv-apps list       # installed Android apps
```

Limits: apps that need Google Play Services (many Google apps, some games,
banking, Netflix-style DRM apps) may refuse to run. ARM-only apps work through
the ARM translation, but not all of them.

---

### Apps Aurora calls "not supported"

Aurora uses Google Play's compatibility check. Waydroid reports itself as a
tablet, so apps made only for Android TV (they require `android.software.leanback`)
show as "not supported". This has nothing to do with ARM: ARM apps install
normally once libhoudini is active. Android itself does not enforce that check, so
install the APK directly:

```bash
sudo -S -p '' waytv-apps at4k                                  # AT4K Launcher, newest GitHub release (also updates it)
sudo -S -p '' waytv-apps install /home/tv/Downloads/app.apk    # any single .apk file
sudo -S -p '' waytv-apps install https://example.com/app.apk   # or a direct https link
```

Split bundles (.apks, .xapk, .apkm) are not supported. Take apps only from the
developer or another source you trust.

## Remote screen (see and control Android from a PC)

Use [scrcpy](https://github.com/Genymobile/scrcpy) to mirror the box's
Android screen to a PC window and control it with the PC's mouse and
keyboard. This is useful for troubleshooting, typing passwords, or installing
apps without walking to the TV.

It connects to Android's ADB through an **SSH tunnel**. ADB is never opened to
your network, because Waydroid's ADB has full control of Android. Anyone who
can log in over SSH can use it, nobody else.

```text
PC: scrcpy ─► adb 127.0.0.1:15555 ─► SSH tunnel ─► box ─► Android ADB (192.168.240.112:5555)
```

### Windows (easiest)

1. Install scrcpy once (PowerShell): `winget install --id Genymobile.scrcpy`
   (or unzip it from the [releases page](https://github.com/Genymobile/scrcpy/releases)
   and put the .bat file in that folder)
2. Download [`windows/waytv-screen.bat`](windows/waytv-screen.bat) and double-click it
3. Type `tv@192.168.1.158` (your box), then the box password when asked
4. The first time, the TV may ask **"Allow USB debugging?"**. Tick *Always allow* and press *Allow*

A window with the Android screen opens. Close the window and the tunnel window when done.

### By hand (Windows, Linux, macOS)

```bash
# on the box, check it is ready and get the exact commands:
sudo waytv-remote

# on the PC:
ssh -N -L 15555:192.168.240.112:5555 tv@192.168.1.158   # leave open
adb connect 127.0.0.1:15555                              # in a second terminal
scrcpy -s 127.0.0.1:15555 --no-audio
```

Install scrcpy with `sudo apt install scrcpy` (Linux) or `brew install scrcpy` (macOS).

Handy scrcpy options: `--max-size 1280` (smoother over Wi-Fi), `--turn-screen-off`
(PC only, TV goes dark), `--record file.mp4`. Drag an `.apk` onto the window to install it.

Tip: set up an SSH key (`ssh-keygen`, then `ssh-copy-id tv@192.168.1.158`, or
copy the key by hand on Windows) so you are not asked for the password twice.

---

## Updates

| What | When | How |
|---|---|---|
| Debian security / stable updates | Daily | `unattended-upgrades`. Never reboots by itself |
| Full Debian upgrade + Waydroid Android image | Sundays 04:30 | `waytv-update.timer` runs `waytv-update --auto` |
| Same, by hand | Any time | `sudo waytv-update`, or **update** in the settings menu |
| Same, from the installer | Each run | Skip with `--no-upgrade` |

The weekly update first installs a newer setup script from GitHub (see
[Self-update](#self-update-from-github)). Then it stops Android, upgrades
everything, and starts Android again. It reboots **only** if a new kernel was
installed.

```bash
systemctl list-timers waytv-update.timer          # next run
sudo systemctl disable --now waytv-update.timer   # turn weekly updates off
journalctl -u waytv-update -b                     # last update log
```

---

## Self-update from GitHub

The box keeps a copy of the script at `/usr/local/lib/waytv/waytv-setup.sh`
and checks this repo for a newer one.

```text
waytv-check.timer   (15 min after boot + daily)
  └─ waytv-check
      ├─ download waytv-setup.sh from GitHub (API), syntax-check it
      ├─ compare its SCRIPT_VERSION with /etc/waytv/version
      ├─ count pending Debian updates, check for a new kernel
      ├─ write /etc/waytv/status            (shown in the menu and at SSH login)
      └─ post an Android notification if anything is waiting

waytv-update  (weekly timer, menu "update", or sudo waytv-update)
  ├─ newer script found? → run it with --no-upgrade (adds only what is new)
  ├─ apt full-upgrade
  ├─ waydroid upgrade
  └─ waytv-check again (clears the status when everything is done)
```

Settings live in `/etc/waytv/update.conf` (root-only, created on first install,
never overwritten):

```bash
REPO=carongutermuth113/waytv
BRANCH=main
GITHUB_TOKEN=          # needed only while the repo is private
AUTO_APPLY_SCRIPT=yes  # no = weekly update only notifies, you install by hand
NOTIFY=yes             # no = no Android notifications
```

**Private repo:** the box needs a read-only token to download the script.
On GitHub: Settings → Developer settings → Fine-grained tokens → Generate:
*Only select repositories* → this repo, *Contents: Read-only*, nothing else.
Then on the box, enter it yourself:

```bash
sudo nano /etc/waytv/update.conf     # paste it after GITHUB_TOKEN=
sudo waytv-check                     # should say "Everything is up to date" or "v… is available"
```

If you make the repo public, leave `GITHUB_TOKEN` empty.

### Bypassing GitHub API rate limits

GitHub's API has rate limits: **60 requests/hour** without authentication, **5000 requests/hour** with a token.
If you have multiple boxes or frequent manual updates, add a Personal Access Token to avoid hitting the limit.

**Steps to add a token:**

1. Go to https://github.com/settings/tokens?type=beta
2. Click **Generate new token** → **Fine-grained personal access token**
3. Fill in:
   - Token name: `WayTV`
   - Repository access: **Only select repositories** → choose `carongutermuth113/waytv`
   - Permissions: **Repository permissions** → **Contents** → set to **Read-only**
   - Nothing else is needed
4. Click **Generate token**
5. Copy the token (starts with `ghp_`)
6. On the box, edit the config:
   ```bash
   sudo nano /etc/waytv/update.conf
   ```
   Paste the token after `GITHUB_TOKEN=` (e.g., `GITHUB_TOKEN=ghp_abcdefgh...`)
7. Save and exit, then test:
   ```bash
   sudo waytv-check
   ```

**Token permissions:**
- A fine-grained token with **Contents: Read-only** cannot modify anything
- It only reads the repo (fetching the setup script)
- Safe to store on the box, even in a root-owned config file

**Revoking the token:**
Go back to https://github.com/settings/tokens and delete the token if you no longer need it.

> **Releasing a new version:** bump `SCRIPT_VERSION=` near the top of the
> script in every commit you want boxes to pick up. Boxes only install a
> version **higher** than the one they have. They never downgrade.
>
> **Trust:** the box runs whatever script is on `main` as root. Anyone who can
> push to this repo can run code on your boxes. Protect the account with 2FA.

### Notifications in Android

`waytv-check` posts a notification through Android's own
`cmd notification post` (run with `waydroid shell`), for example:

> **WayTV updates available**
> WayTV script v6 is available (installed: v5). 12 Debian update(s) waiting.
> They install automatically on Sunday at 04:30, or open Settings > update on Ctrl+Alt+F2.

Each new notification replaces the previous one instead of stacking up. It
appears at most once a day (and 15 minutes after boot) while something is
waiting. The same message shows at the top of `waytv-settings` and when you log
in over SSH.

```bash
sudo waytv-check                         # check now, print, notify
systemctl list-timers waytv-check.timer  # next check
journalctl -u waytv-check -b             # check log
```

---

## OS tuning

All of these are undone by `--uninstall`.

| Tweak | Why |
|---|---|
| zram swap (zstd, 100% of RAM, priority 100) | Compressed RAM swap; idle memory takes about a third of the space |
| 4 GB swap file `/waytv.swap` (priority 10) | Last resort when zram is full, so apps are not killed. Only on ext4/xfs with 12 GB free |
| `vm.swappiness=150`, `page-cluster=0`, `watermark_scale_factor=125` | Use the fast zram swap early instead of running out of memory |
| `OOMScoreAdjust=-500` for `waydroid-container` and the kiosk | Debian's OOM killer picks something else before Android |
| Android `dalvik.vm.heapgrowthlimit=256m`, `heapsize=512m` (waydroid.cfg `[properties]`) | Heavy apps do not die with OutOfMemoryError |
| Journal capped at 200 MB | Disk never fills with logs |
| `DefaultTimeoutStopSec=15s` | Shutdown never hangs on a stuck service |
| Suspend / hibernate masked | A TV box should never go to sleep |
| `*-wait-online` masked | Boot does not wait for the network |
| ModemManager, CUPS disabled (if present) | Not needed on a TV box |
| `fstrim.timer` enabled | Weekly TRIM for SSD/eMMC |
| GRUB: 1 s timeout, `quiet loglevel=3 consoleblank=0` | Faster boot, screen never blanks |

Original files are backed up once under `/etc/waytv/backup/` before the first
edit. Units the script masks, disables or enables are recorded under
`/etc/waytv/` so uninstall reverses exactly those.

---

## Files on the box

| Path | Purpose |
|---|---|
| `/etc/waytv/display.conf` | Resolution (`WIDTH=`, `HEIGHT=`), performance overlay (`OVERLAY=1/0`) |
| `/etc/waytv/user` | Kiosk user |
| `/etc/waytv/version`, `installed`, `steps/` | Install state for safe re-runs |
| `/etc/waytv/packages-added`, `groups-added`, `masked`, `disabled`, `enabled`, `backup/` | What uninstall will revert |
| `/usr/local/bin/waytv-settings` | Settings menu |
| `/usr/local/bin/waytv-agent`, `/etc/systemd/system/waytv-agent.service` | Service the WayTV Settings app talks to |
| `/etc/waytv/agent.token` | The app's access token (root-only) |
| `/var/lib/waytv/jobs/` | Logs of tasks started from the app (last 20) |
| `/usr/local/bin/waytv-update` | Updater (script from GitHub, Debian, Android) |
| `/usr/local/bin/waytv-check` | Update checker + Android notification |
| `/usr/local/bin/waytv-remote` | Remote-screen status and PC commands |
| `/usr/local/bin/waytv-apps` | Android app installer (WayTV Settings, Aurora Store, AT4K, any .apk) |
| `/usr/local/bin/waytv-perf`, `/usr/local/lib/waytv/perf-collector.py`, `/etc/systemd/system/waytv-perf.service` | Performance overlay (labwc/waybar config in `/usr/local/lib/waytv/`) |
| `/usr/local/bin/waytv-tweaks` | TV tweaks (hide apps, scaling, bottom bar, time zone) |
| `/usr/local/bin/waytv-crashlog` | Crash report, saved to `/var/log/waytv-crash-report.txt` |
| `/waytv.swap`, `/etc/waytv/swapfile` | Swap file and its record for uninstall |
| `/etc/waytv/options` | Answers to install questions (`AURORA_STORE=yes/no`) |
| `/etc/waytv/pending-apps` | Apps waiting for Android to be running |
| `/usr/local/lib/waytv/waytv-setup.sh` | Installed copy of this script |
| `/etc/waytv/update.conf` | Self-update settings (repo, token, auto-apply, notify) |
| `/etc/waytv/status` | Current "updates waiting" message |
| `/var/lib/waytv/` | Downloaded newer script, last check result |
| `/etc/update-motd.d/90-waytv` | Shows the status at SSH/console login |
| `/usr/local/bin/waytv-kiosk-start`, `waytv-kiosk-user` | Kiosk launchers |
| `/etc/systemd/system/waydroid-kiosk.service` | The kiosk |
| `/etc/systemd/system/waytv-fallback.service` | Text login if the kiosk fails |
| `/etc/systemd/system/graphical-kiosk.target` | Default boot target |
| `/etc/systemd/system/waytv-update.{service,timer}` | Weekly update |
| `/etc/systemd/system/waytv-check.{service,timer}` | Daily update check |

---

## Useful commands

```bash
# kiosk
sudo systemctl start|stop|restart waydroid-kiosk
systemctl status waydroid-kiosk
journalctl -u waydroid-kiosk -b -f

# Waydroid
waydroid status
waydroid app list
waydroid app install /path/to/app.apk
waydroid prop get persist.waydroid.width
sudo waydroid shell
sudo waydroid log

# resolution without the menu
sudo nano /etc/waytv/display.conf && sudo systemctl restart waydroid-kiosk

# TV by hand
echo 'on 0'      | cec-client -s -d 1
echo 'standby 0' | cec-client -s -d 1

# boot mode
sudo systemctl set-default multi-user.target       # normal text boot
sudo systemctl set-default graphical-kiosk.target  # back to the kiosk
```

---

## Troubleshooting

**`Permission denied` / `sudo: ./waytv-setup.sh: command not found`**
The file lost its executable bit while being copied. Run `chmod +x waytv-setup.sh`, or start it with `sudo bash ./waytv-setup.sh`.

**`$'\r': command not found` or `bash\r: No such file or directory`**
The file has Windows line endings. Fix them with `sed -i 's/\r$//' waytv-setup.sh`.

**No Android notification**
Run `sudo waytv-check`. It says if GitHub could not be reached (private repo
without a token) or if posting to Android failed. Notifications need the
Waydroid container running. Older Waydroid images without
`cmd notification` cannot show them; the status still appears in the menu and
at SSH login.

**SSH: "System is booting up. Unprivileged users are not permitted to log in yet"**
Fixed in script version 4. Older versions booted without
`systemd-user-sessions`, which left `/run/nologin` in place. To recover:
- if you have a root password: on the box, Ctrl+Alt+F2, log in as root, run `systemctl start systemd-user-sessions`
- otherwise: reboot, tap **Esc** for the GRUB menu, press **e**, add
  `systemd.unit=multi-user.target` to the end of the `linux` line, and press **Ctrl+X**

Then run the latest script and reboot.

**"No binder support in this kernel"**
Your kernel lacks `CONFIG_ANDROID_BINDER_IPC`. Use Debian's stock kernel.

**No sound**
Check `systemctl --user -M <user>@ status pipewire-pulse`. For Bluetooth audio, check the device is connected (`bluetoothctl devices Connected`), then **restart** from the menu.

**"Failed to start lxc-net.service" at boot**
Fixed in script version 7. The system-wide `dnsmasq` daemon and LXC's
default bridge (`lxc-net`) are not used by Waydroid (it runs its own
`waydroid0` bridge) and fight over port 53. The script disables both. By hand:
`sudo systemctl disable --now dnsmasq lxc-net && sudo systemctl restart waydroid-container`.

**Bluetooth: `Failed to connect: org.bluez.Error.Failed br-connection-profile-unavailable`**
No Debian service accepted the device. For headphones/speakers this is because
WirePlumber only offers Bluetooth audio to a desktop login, and the kiosk has
none. Script v10 turns that off (`/etc/wireplumber/wireplumber.conf.d/80-waytv-bluetooth.conf`).
Update, reboot, then `connect` again. Phones and PCs cannot be "connected" to
the box this way at all.

**Remote screen: `adb connect` fails or scrcpy says "device unauthorized"**
Run `sudo waytv-remote` on the box. It turns on network ADB inside Android if
it is off. "Unauthorized" means the *Allow USB debugging?* prompt on the TV
has not been accepted yet. Check the TV screen.

**Apps crash or close (4 GB RAM)**
Script v11 adds more swap (zram + a swap file), a bigger app memory limit,
OOM protection for Android, Intel's libhoudini ARM translation instead of
libndk, and restarts the kiosk if Android's screen closes. If an app still
closes, run `sudo waytv-crashlog --clear`, open the app until it closes, then
`sudo waytv-crashlog`. The end of the report says the likely cause:
- *needs Google Play Services*: the VANILLA image has none. RAM does not help;
  it needs a GApps or microG image.
- *ARM translation*: re-run `sudo /usr/local/lib/waytv/waytv-setup.sh --force`.
- *RAM was full*: use 1080p instead of 4K and keep few apps open.
- *bug in the app itself* (a Java exception): not the box; update the app or report it.
  Example: Aurora Store 4.8.4 crashes on its home screen when the feed lists an app
  twice ([issue #1611](https://gitlab.com/AuroraOSS/AuroraStore/-/issues/1611)).
  Workaround: tap Search right after opening Aurora.

**Resolution setting had no effect at boot (v12 and older)**
`waydroid prop set` only works while Android runs, so the boot-time setting
failed. From v13 the kiosk sets it after Android starts and restarts Android once
when it changed.

**Black screen / kiosk keeps restarting**
Check `journalctl -u waydroid-kiosk -b` and `sudo waydroid log`. After 3
failures you get a text login on tty1 automatically.

---

## Uninstall

```bash
sudo ./waytv-setup.sh --uninstall
# or, from anywhere:
sudo /usr/local/lib/waytv/waytv-setup.sh --uninstall
sudo reboot
```

This removes the kiosk, Waydroid and **all Android data**, the ARM
translation, the helper scripts and units, the OS tweaks (original files are
restored), the auto-updates, the group memberships it added, and only the
packages it installed. If the script installed SSH, SSH is removed too, so
run the uninstall at the box, not over SSH.

---

## Credits

- [Waydroid](https://waydro.id)
- [cage](https://github.com/cage-kiosk/cage)
- [casualsnek/waydroid_script](https://github.com/casualsnek/waydroid_script) for the libhoudini/libndk ARM translation (third-party; check its license)

## License

MIT, see [LICENSE](LICENSE).
