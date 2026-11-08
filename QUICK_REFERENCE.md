# WayTV v1.0 Quick Reference Card

## 📦 Files
```
waytv-setup-v1.0.sh  ← Setup script (copy & run)
waytv-settings-app.rs         ← Settings app source (build APK)
waytv-agent.py         ← Agent (copy to device)
```

## ⚡ TL;DR Device Testing

### On your PC:
```bash
cd /home/hermes/waytv-repo

# 1. Copy setup script
scp waytv-setup-v1.0.sh root@192.168.1.157:/root/

# 2. Copy agent
scp waytv-agent.py root@192.168.1.157:/tmp/

# 3. Build settings app (requires cargo ndk)
cargo ndk -t aarch64-linux-android build --release

# 4. Copy APK
scp target/aarch64-linux-android/release/waytv_settings.apk root@192.168.1.157:/tmp/
```

### On device (192.168.1.157):
```bash
# Backup
sudo tar czf /root/waytv-backup-v17.tgz /etc/waytv /opt/waytv

# Run setup (will download ~1.5 GB, ask GApps + launcher, reboot)
sudo /root/waytv-setup-v1.0.sh --force

# After reboot, deploy agent
sudo cp /tmp/waytv-agent.py /etc/waytv/agent.py
sudo systemctl restart waytv-agent

# Install settings app
waydroid app install /tmp/waytv_settings.apk

# Test
curl http://192.168.240.1:8765/api/health
```

### On TV:
- Open "WayTV Settings" app
- Use D-pad to navigate, A to select, B to back
- Test all 5 tabs (Home, Display, Apps, Storage, About)
- Try launcher switch on Apps tab
- Try DPI slider on Display tab

---

## ✅ Key Tests

| Phase | What | Expected | Check |
|-------|------|----------|-------|
| 1 | Backup | Creates /root/waytv-backup-v17.tgz | `ls -lah /root/*.tgz` |
| 2 | Setup script syntax | No errors | `bash -n /root/waytv-setup-v1.0.sh` |
| 2 | Setup runs | Asks GApps, launcher, downloads, reboots | Follow prompts |
| 2 | Options saved | /etc/waytv/options has GAPPS and LAUNCHER | `cat /etc/waytv/options` |
| 3 | Agent syntax | No errors | `python3 -m py_compile /etc/waytv/agent.py` |
| 3 | Agent runs | Status is RUNNING | `systemctl status waytv-agent` |
| 3 | Agent health | Responds with {"status":"ok"} | `curl http://192.168.240.1:8765/api/health` |
| 4 | App builds | APK file created | `ls -lah target/aarch64-linux-android/release/waytv_settings.apk` |
| 4 | App installs | No errors | `waydroid app install ...` |
| 4 | App opens | Home tab shows device info | Open on TV |
| 5 | D-pad nav | Switch between tabs smoothly | Press D-pad left/right |
| 5 | Launcher switch | Launcher changes immediately | Switch on Apps tab, see effect |
| 5 | DPI change | Slider moves, DPI updates | Adjust on Display tab |

---

## 🔑 Passwords / Auth

- **Agent token**: Stored in `/etc/waytv/agent.token`
- **Root password**: None needed (SSH key or sudo NOPASSWD)
- **Device user**: root@192.168.1.157

---

## ⏱️ Timing

- Phase 1 (Backup): 5 min
- Phase 2 (Setup script): 20 min (+ 15 min download)
- Phase 3 (Agent): 10 min
- Phase 4 (App build + test): 30 min (first build takes 15–20 min)
- Phase 5 (Verification): 20 min
- **Total**: ~2–3 hours

---

## 🆘 Abort & Rollback

If Phase 2 setup script fails:

```bash
# On device
sudo cp /home/hermes/waytv-setup.sh.v17.bak /home/hermes/waytv-setup.sh
sudo /home/hermes/waytv-setup.sh --force
```

If Phase 3 agent fails:

```bash
sudo systemctl stop waytv-agent
# Restore from backup if needed
sudo systemctl start waytv-agent
```

If Phase 4 app fails:

```bash
waydroid shell -- pm uninstall tv.waytv.settings
# or rebuild APK locally and reinstall
```

---

## 📝 As You Test...

Track which items pass/fail in Phase 5 checklist (see DEPLOY_STEPS.md). Report back with:

1. ✅ Passed items
2. ❌ Failed items (with error message)
3. 📸 Screenshots of working UI
4. Any tweaks needed before pushing to git

