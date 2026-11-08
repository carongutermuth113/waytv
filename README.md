# WayTV v1.0

**WayTV** is a complete Waydroid-based Android TV kiosk for x86_64 Debian 13, with native settings management, dual launcher support, and a REST API for remote control.

## Features

- **WayDroid-ATV**: LineageOS 24 / Android 17 build (TV-optimized)
- **Settings App**: Native Android TV UI (no terminal needed)
  - Display: Resolution, DPI, refresh rate
  - Apps: Install, uninstall, manage
  - Storage: Device info, cache cleanup
  - Launcher: Switch between Projectivity (Android-like) and AT4K (Apple TV-like)
- **First-Boot Choices**:
  - GApps (Google Play Store) OR Vanilla (Aurora + F-Droid)
  - Launcher selection (Projectivity or AT4K)
- **WayTV Agent v1.0**: REST API on port 8765
  - 14 endpoints for display, apps, storage, system control
  - Bearer token auth
- **Auto-Updates**: Weekly checks, script self-updates from GitHub

## Quick Start

```bash
sudo ./waytv-setup.sh                    # Install WayTV v1.0
sudo ./waytv-setup.sh --force            # Reinstall (rerun all steps)
sudo ./waytv-setup.sh --uninstall        # Remove WayTV stack
```

## Requirements

- **OS**: Debian 13, x86_64
- **RAM**: 4 GB (with zram + swap)
- **Storage**: 20 GB free
- **Network**: Internet for first setup

## Deployment

See `DEPLOY_STEPS.md` for phase-by-phase testing on 192.168.1.157 or another device.

## Files

- `waytv-setup.sh` — Setup script v1.0
- `waytv-agent.py` — Agent v1.0
- `waytv-settings-app.rs` — Settings app source
- `DEPLOY_STEPS.md` — Testing guide

## License

MIT
