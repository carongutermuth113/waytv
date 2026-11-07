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
def scan_apps():
    """List available APKs in /data/apps/ with metadata."""
    apps_dir = "/data/apps"
    apps = []
    
    if os.path.isdir(apps_dir):
        for fn in sorted(os.listdir(apps_dir)):
            if not fn.endswith(".apk"):
                continue
            path = os.path.join(apps_dir, fn)
            pkg = extract_apk_package(path)
            if not pkg:
                continue
            
            # Check if installed
            installed = android("/system/bin/pm", "list", "packages") and pkg in android("/system/bin/pm", "list", "packages")
            
            apps.append({
                "name": fn.replace(".apk", "").replace("-", " "),
                "package": pkg,
                "version": "1.0",
                "installed": bool(installed),
                "installing": False
            })
    
    # Demo apps if directory is empty or no APKs were found
    if not apps:
        apps = [
            {"name": "SmartTube", "package": "com.smarttube.tv", "version": "1.0", "installed": False, "installing": False},
            {"name": "Titanium Browser", "package": "com.jqssun.browser", "version": "1.0", "installed": False, "installing": False},
            {"name": "Aurora Store", "package": "com.aurora.store", "version": "1.0", "installed": False, "installing": False},
        ]
    
    return apps


def extract_apk_package(apk_path):
    """Extract package name from AndroidManifest.xml in APK (quick parse)."""
    try:
        with zipfile.ZipFile(apk_path, "r") as z:
            manifest = z.read("AndroidManifest.xml")
            # Look for package=" in the binary XML
            i = manifest.find(b'package="')
            if i > 0:
                i += 9
                j = manifest.find(b'"', i)
                return manifest[i:j].decode("utf-8", "ignore")
    except Exception:
        pass
    return None


def get_app_version():
    """Get installed WayTV Settings app version code."""
    if not android_up():
        return None
    out = android("/system/bin/dumpsys", "package", "tv.waytv.settings")
    m = re.search(r"versionCode=(\d+)", out)
    return int(m.group(1)) if m else None


def get_latest_app_version():
    """Fetch latest app version from GitHub releases."""
    try:
        rc, out = run(["curl", "-s", "https://api.github.com/repos/carongutermuth113/waytv/releases/latest"], 10)
        if rc == 0:
            data = json.loads(out)
            tag = data.get("tag_name", "")
            if tag.startswith("app-v"):
                # Extract version code from tag name (e.g., app-v1.5 -> 1.5, but we need integer)
                # For now, assume tag format is app-vX where X maps to version code
                # Simpler: just check if there's a newer tag by comparing GitHub release date
                return {"tag": tag, "url": data.get("assets", [{}])[0].get("browser_download_url", "")}
    except Exception:
        pass
    return None


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
        "perf": perf, "job": running_job(), "apps": scan_apps(),
        "app_version": get_app_version(),
        "app_update": get_latest_app_version(),
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


def install_app(body):
    """Install an APK from /data/apps/ directory."""
    need_android()
    pkg = body.get("package", "").strip()
    if not pkg or not re.fullmatch(r"[a-z0-9.]+", pkg):
        raise ApiError(400, "Invalid package name.")
    
    # Find APK file by package name
    apk_path = None
    if os.path.isdir("/data/apps"):
        for fn in os.listdir("/data/apps"):
            if fn.endswith(".apk") and extract_apk_package(f"/data/apps/{fn}") == pkg:
                apk_path = f"/data/apps/{fn}"
                break
    
    if not apk_path:
        raise ApiError(404, f"App not found: {pkg}")
    
    # Install via pm install
    job = start_job("install", f"Installing {pkg}", f"{BIN}/waytv-apps install {apk_path}")
    return {"ok": True, "restarting": False, "job": job}


def update_app():
    """Download and install the latest WayTV Settings app from GitHub."""
    need_android()
    latest = get_latest_app_version()
    if not latest or not latest.get("url"):
        raise ApiError(404, "Could not find latest app version on GitHub.")
    
    url = latest["url"]
    apk_path = "/tmp/waytv-app-update.apk"
    
    # Download APK
    rc, _ = run(["curl", "-s", "-L", "-o", apk_path, url], 60)
    if rc != 0 or not os.path.exists(apk_path):
        raise ApiError(500, "Failed to download app from GitHub.")
    
    # Install
    job = start_job("app_update", f"Updating WayTV app to {latest['tag']}", 
                   f"{BIN}/waytv-apps install {apk_path}")
    return {"ok": True, "restarting": False, "job": job}


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
                    "/api/apps/install": lambda: install_app(body),
                    "/api/app/update": lambda: update_app(),
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
