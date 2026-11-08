# WayTV v1.0 — Complete Device Testing & Deployment

## 📋 Prerequisites

- Device: 192.168.1.157 (CN60 box, Debian 13)
- SSH access as root
- Waydroid already installed
- Current WayTV agent running
- ~30 GB free disk space (for WayDroid-ATV download + temp)

---

## 🔴 PHASE 1: Backup Current State

### Step 1.1: SSH into device
```bash
ssh root@192.168.1.157
```

### Step 1.2: Backup /etc/waytv and /opt/waytv
```bash
sudo tar czf /root/waytv-backup-v17.tgz /etc/waytv /opt/waytv 2>/dev/null || true
ls -lah /root/waytv-backup-v17.tgz
```

**Expected output**: File size ~100–500 MB (depending on current installation)

### Step 1.3: Backup current setup script
```bash
sudo cp /home/hermes/waytv-setup.sh /home/hermes/waytv-setup.sh.v17.bak
echo "Backup complete: v17 script saved"
```

---

## 🟡 PHASE 2: Deploy & Test Setup Script v1.0

### Step 2.1: Copy new setup script to device (on your PC)
```bash
scp ./waytv-setup.sh root@192.168.1.157:/root/
ssh root@192.168.1.157 "chmod +x /root/waytv-setup.sh && ls -lah /root/waytv-setup.sh"
```

**Expected output**: File listed with -rwxr-xr-x permissions

### Step 2.2: Syntax-check the script (no execution yet)
```bash
ssh root@192.168.1.157 "bash -n /root/waytv-setup.sh && echo '✓ Syntax OK'"
```

**Expected output**: `✓ Syntax OK`

### Step 2.3: Run setup script with --force flag
This will:
- Ask for GApps choice (Play Store only) or Vanilla (Aurora + F-Droid)
- Ask for launcher choice (Projectivity or AT4K)
- Download WayDroid-ATV ~1.5 GB
- Reboot when done

**On device**:
```bash
sudo /root/waytv-setup.sh --force
```

**When prompted**:
1. **GApps?** → Answer `yes` or `no` (recommend `yes` for first test)
2. **Launcher?** → Answer `projectivity` or `at4k` (recommend `projectivity`)
3. Script will download, install, and reboot

**Wait for reboot** (~15 min for download + install)

### Step 2.4: Verify setup completed
After reboot, SSH back in:
```bash
ssh root@192.168.1.157

# Check options were saved
cat /etc/waytv/options

# Expected output:
# GAPPS=yes
# LAUNCHER=projectivity
# INSTALLED=1
```

### Step 2.5: Check Waydroid is running
```bash
waydroid status
# Expected: session is RUNNING
```

### Step 2.6: Open Waydroid and verify default launcher
```bash
waydroid shell -- getprop ro.waydroid.launcher
# Expected: com.whatever.launcher (depending on choice)
```

---

## 🟠 PHASE 3: Deploy & Test Agent v1.0

### Step 3.1: Copy agent to device (on your PC)
```bash
scp ./waytv-agent.py root@192.168.1.157:/tmp/
ssh root@192.168.1.157 "sudo cp /tmp/waytv-agent.py /etc/waytv/agent.py && sudo chown root:root /etc/waytv/agent.py"
```

### Step 3.2: Check agent syntax
```bash
ssh root@192.168.1.157 "python3 -m py_compile /etc/waytv/agent.py && echo '✓ Python syntax OK'"
```

**Expected output**: `✓ Python syntax OK`

### Step 3.3: Restart agent
```bash
ssh root@192.168.1.157 "sudo systemctl restart waytv-agent && sleep 2 && systemctl status waytv-agent"
```

**Expected output**: `Active: active (running)`

### Step 3.4: Test agent endpoints

Test health endpoint (no auth):
```bash
ssh root@192.168.1.157 "curl -s http://192.168.240.1:8765/api/health | jq ."
```

**Expected output**:
```json
{"status": "ok"}
```

Test system info endpoint (requires auth):
```bash
ssh root@192.168.1.157 "
TOKEN=\$(cat /etc/waytv/agent.token)
curl -s -H \"Authorization: Bearer \$TOKEN\" http://192.168.240.1:8765/api/system/info | jq .
"
```

**Expected output**:
```json
{
  "ip": "192.168.1.157",
  "hostname": "waytv",
  "android_version": "17",
  "gapps_status": true
}
```

Test launcher list:
```bash
ssh root@192.168.1.157 "
TOKEN=\$(cat /etc/waytv/agent.token)
curl -s -H \"Authorization: Bearer \$TOKEN\" http://192.168.240.1:8765/api/apps/launcher-list | jq .
"
```

**Expected output**:
```json
{
  "launchers": [
    {"name": "Projectivity", "package": "com.example.projectivity", "is_default": true},
    {"name": "AT4K", "package": "com.example.at4k", "is_default": false}
  ]
}
```

### Step 3.5: Verify all key endpoints
| Endpoint | Command | Expected |
|----------|---------|----------|
| `/api/health` | `curl http://192.168.240.1:8765/api/health` | `{"status":"ok"}` |
| `/api/system/info` | With Bearer token | Returns ip, hostname, android_version, gapps_status |
| `/api/apps/launcher-list` | With Bearer token | Returns launcher list with is_default flag |
| `/api/system/storage` | With Bearer token | Returns used_gb, free_gb, total_gb |

---

## 🟢 PHASE 4: Build & Deploy Settings App

### Step 4.1: Install Rust Android build tools (on your PC, if not already done)

If you haven't set up Rust Android yet:
```bash
# Install Rust (if needed)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source $HOME/.cargo/env

# Add Android targets
rustup target add aarch64-linux-android x86_64-linux-android

# Install cargo-ndk
cargo install cargo-ndk

# Set up Android NDK path (adjust version as needed)
export ANDROID_NDK_HOME=$HOME/Android/Sdk/ndk/25.1.8937393
```

### Step 4.2: Create Cargo project structure locally

```bash
cd /home/hermes/waytv-repo

# Create Cargo.toml
cat > Cargo.toml << 'EOF'
[package]
name = "waytv-settings"
version = "1.0.0"
edition = "2021"

[dependencies]
eframe = "0.27"
egui = "0.27"
reqwest = { version = "0.11", features = ["json"] }
tokio = { version = "1", features = ["full"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"

[[bin]]
name = "waytv_settings"
path = "waytv-settings-app.rs"

[profile.release]
opt-level = 3
lto = true
EOF

# Verify structure
ls -la
```

### Step 4.3: Build APK for Android

```bash
# Build for aarch64 (most common for TV boxes)
cargo ndk -t aarch64-linux-android build --release

# Output should be:
# target/aarch64-linux-android/release/waytv_settings.apk
```

**Time**: ~15–30 minutes first build (downloads dependencies)

### Step 4.4: Verify APK was created

```bash
ls -lah target/aarch64-linux-android/release/waytv_settings.apk
# Should show file > 1 MB
```

### Step 4.5: Install APK on device (on your PC)

```bash
scp target/aarch64-linux-android/release/waytv_settings.apk root@192.168.1.157:/tmp/
ssh root@192.168.1.157 "
  waydroid app install /tmp/waytv_settings.apk
  echo 'Installation complete'
"
```

### Step 4.6: Verify app installed

```bash
ssh root@192.168.1.157 "
  waydroid shell -- pm list packages | grep waytv
  # Expected: package:tv.waytv.settings (or similar)
"
```

### Step 4.7: Open app and test (on the TV screen)

On the TV, open "WayTV Settings" app. Test:

**Tab Navigation** (D-pad left/right):
- [ ] Home tab loads device info
- [ ] Display tab shows DPI slider
- [ ] Apps tab lists installed apps
- [ ] Storage tab shows space usage
- [ ] About tab shows version

**Home Tab**:
- [ ] Shows IP address
- [ ] Shows hostname
- [ ] Shows free space
- [ ] Shows Android version (should be 17)
- [ ] Shows GApps status (yes/no based on choice)

**Display Tab**:
- [ ] DPI slider visible (280–500)
- [ ] Can move slider with D-pad
- [ ] "Apply" button works
- [ ] DPI changes apply (verify with `getprop ro.sf.lcd_density` on device)

**Apps Tab**:
- [ ] Lists apps (Play Store / Aurora depending on GApps choice)
- [ ] Shows launcher apps
- [ ] Can select launcher with D-pad
- [ ] "Set Default" button applies change
- [ ] Can navigate back with B button

**Storage Tab**:
- [ ] Shows used/free space
- [ ] Shows total space
- [ ] "Clear Cache" button works (verify cache size decreases)

**About Tab**:
- [ ] Shows app version
- [ ] "Check Updates" button works
- [ ] "Factory Reset" button shows confirmation

### Step 4.8: Test launcher switching (on TV)

1. Open WayTV Settings → Apps tab
2. Select launcher (if Projectivity, switch to AT4K)
3. Press A to confirm
4. Launcher should change immediately
5. Press Home button — new launcher should load
6. Go back to WayTV Settings, verify launcher shows as default

---

## 🔵 PHASE 5: Verification Checklist

Run through this checklist and mark each item:

### Setup Script
- [ ] Script runs without errors
- [ ] Prompts GApps choice correctly
- [ ] Prompts launcher choice correctly
- [ ] Selected launcher becomes default
- [ ] Both launchers installed and available
- [ ] /etc/waytv/options has GAPPS and LAUNCHER set

### Agent v1.0
- [ ] Agent starts without errors
- [ ] Health endpoint responds (no auth)
- [ ] System info endpoint works (with auth)
- [ ] Launcher list endpoint works
- [ ] Storage endpoint returns valid data
- [ ] All endpoints have proper error handling

### Settings App
- [ ] App installs successfully
- [ ] Home tab displays all fields
- [ ] Display tab DPI slider works
- [ ] Apps tab lists all apps correctly
- [ ] Storage tab shows accurate numbers
- [ ] About tab shows version
- [ ] D-pad navigation works across all tabs
- [ ] A button confirms selections
- [ ] B button navigates back
- [ ] Launcher switching works immediately
- [ ] App uninstall works (can remove an app)

### Overall
- [ ] No errors in system logs
- [ ] Waydroid performance normal
- [ ] Settings app no terminal needed (100% TV UI)
- [ ] No splash screens at boot

---

## 🚨 Troubleshooting

### Setup script asks for input but I can't type

**Issue**: Script was piped via SSH (loses TTY)

**Solution**: Run directly on device with keyboard, or use:
```bash
ssh -t root@192.168.1.157 sudo /root/waytv-setup.sh --force
```

The `-t` flag forces a pseudo-terminal.

### Agent won't restart

```bash
# Check logs
sudo journalctl -u waytv-agent -n 50

# Verify token file exists
cat /etc/waytv/agent.token

# Manually start agent
sudo python3 /etc/waytv/agent.py
```

### APK won't build

**Issue**: Missing Android NDK or Rust targets

**Solution**:
```bash
# Verify Rust targets
rustup target list | grep aarch64

# Verify NDK path
echo $ANDROID_NDK_HOME
ls $ANDROID_NDK_HOME/

# Rebuild
cargo clean
cargo ndk -t aarch64-linux-android build --release
```

### Settings app crashes on open

**Issue**: Agent unreachable or token mismatch

**Solution**:
```bash
# On device, check agent is running
systemctl status waytv-agent

# Check agent token
cat /etc/waytv/agent.token

# Test endpoint manually
curl -H "Authorization: Bearer $(cat /etc/waytv/agent.token)" http://192.168.240.1:8765/api/system/info

# Check app logs
adb logcat | grep waytv
```

### Launcher not switching

**Issue**: Agent launcher-set endpoint not updating default

**Solution**:
```bash
# Manually test endpoint
TOKEN=$(cat /etc/waytv/agent.token)
curl -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"package":"com.example.launcher"}' \
  http://192.168.240.1:8765/api/apps/launcher-set

# Verify it was set
waydroid shell -- getprop ro.waydroid.launcher
```

---

## 📸 Screenshots to Capture

Once everything works, capture TV screenshots of:

1. Home tab with device info
2. Display tab with DPI slider
3. Apps tab with launcher list
4. Storage tab
5. About tab
6. Launcher after switching (to show it actually changed)

```bash
# Capture screenshot from device
waydroid shell -- screencap -p /sdcard/screenshot.png
waydroid pull /sdcard/screenshot.png ./screenshot.png
```

---

## ✅ Sign-off

Once all items in Phase 5 checklist are done:

1. **Report results**: What passed, what failed, what needs tweaking
2. **Push to git**: If everything works, commit v1.0 to repo
3. **Document changes**: Update README with v1.0 changes

---

## 🔄 Rollback (if needed)

If something breaks:

```bash
# Stop agent
sudo systemctl stop waytv-agent

# Restore backup
sudo tar xzf /root/waytv-backup-v17.tgz -C /

# Restore old script
sudo cp /home/hermes/waytv-setup.sh.v17.bak /home/hermes/waytv-setup.sh

# Restart agent
sudo systemctl start waytv-agent

# Verify
systemctl status waytv-agent
waydroid status
```

---

## 📞 If You Get Stuck

- Check device logs: `sudo journalctl -xe`
- Check agent logs: `sudo journalctl -u waytv-agent -n 100`
- Check Waydroid: `waydroid status` and `waydroid logcat`
- SSH and report exact error messages from Phase 2–5

Ready? Start with **PHASE 1** above on the device.

