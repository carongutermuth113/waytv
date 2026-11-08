# WayTV v1.0 Repository Setup

## What's Ready

WayTV v1.0 is a complete Waydroid-based Android TV kiosk system with:

- **waytv-setup.sh** (v1.0): Main installation script
- **waytv-agent.py** (v1.0): REST API backend (14 endpoints)
- **waytv-settings-app.rs** (v1.0): Native Android TV settings UI
- **DEPLOY_STEPS.md**: Phase-by-phase testing guide
- **QUICK_REFERENCE.md**: Command cheat sheet

## Files in This Repo

```
/home/hermes/waytv-repo/
├── README.md                    # Project overview
├── LICENSE                      # MIT License
├── .gitignore                   # Git ignore rules
├── waytv-setup.sh              # Setup script v1.0 (verified ✓)
├── waytv-agent.py              # Agent v1.0 (verified ✓)
├── waytv-settings-app.rs       # Settings app source
├── DEPLOY_STEPS.md             # Testing guide
└── QUICK_REFERENCE.md          # Command reference
```

## Verification Status

- ✓ **waytv-setup.sh**: bash -n passed (no syntax errors)
- ✓ **waytv-agent.py**: python3 -m py_compile passed
- ✓ **Version**: All files updated to v1.0

## Next Steps to Deploy

### Option A: Push to GitHub (Recommended)

1. Create a GitHub repository named `waytv` under your account
2. Initialize git:
   ```bash
   cd /home/hermes/waytv-repo
   git init
   git add .
   git commit -m "WayTV v1.0: Initial release"
   git branch -M main
   git remote add origin https://github.com/YOUR_USERNAME/waytv.git
   git push -u origin main
   ```

3. Update the setup script to reference your repo:
   ```bash
   sed -i 's/YOUR_GITHUB_USERNAME/YOUR_ACTUAL_USERNAME/g' waytv-setup.sh
   git add waytv-setup.sh
   git commit -m "Update GitHub repo reference to YOUR_USERNAME/waytv"
   git push
   ```

### Option B: Test Locally First

1. On your device (192.168.1.157), backup current state:
   ```bash
   sudo tar czf /root/waytv-backup-v17.tgz /etc/waytv /opt/waytv
   ```

2. Deploy from local repo:
   ```bash
   sudo /home/hermes/waytv-repo/waytv-setup.sh
   ```

3. Follow DEPLOY_STEPS.md for phase-by-phase verification

## What the Setup Script Does

- Installs Waydroid (WayDroid-ATV variant)
- Configures kernel, memory, swap (4 GB RAM optimization)
- Installs WayTV agent on port 8765
- Deploys WayTV settings app as native Android TV UI
- Sets up SSH, auto-updates, systemd services
- Offers choice: GApps vs Vanilla + Projectivity vs AT4K launcher

## First Boot on New Machine

```bash
sudo ./waytv-setup.sh
# Prompts:
# 1. GApps or Vanilla? (default: Vanilla)
# 2. Launcher choice? (default: Projectivity)
# Installs everything (~30-45 minutes)
# Reboots into WayTV kiosk mode
```

## Help

- **Settings on TV**: Ctrl+Alt+F2 → log in → WayTV Settings app appears in launcher
- **Remote control**: `sudo waytv-remote` (SSH tunnel to device)
- **Check status**: `sudo waytv-check`
- **Troubleshoot**: See DEPLOY_STEPS.md phase 5 (verification)

---

**Ready to deploy?** Choose Option A (GitHub) or Option B (local test), then report results.
