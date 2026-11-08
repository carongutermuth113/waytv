#!/usr/bin/env python3
"""
WayTV Agent v1.0 - Full Settings App Backend
Endpoints for Display, Apps, Storage, System Information
"""

import os
import json
import subprocess
import re
from pathlib import Path
from flask import Flask, request, jsonify
from functools import wraps
from typing import Dict, List, Optional

app = Flask(__name__)
AGENT_PORT = 8765
PAIRING_FILE = "/data/data/tv.waytv.settings/files/agent.json"
CONFIG_FILE = "/etc/waytv/options"

def get_agent_token() -> str:
    """Read paired agent token from file."""
    if Path(PAIRING_FILE).exists():
        try:
            with open(PAIRING_FILE) as f:
                return json.load(f).get('token', 'waytv-default')
        except:
            return 'waytv-default'
    return 'waytv-default'

def require_auth(f):
    """Decorator: require Authorization: Bearer <token>"""
    @wraps(f)
    def wrapper(*args, **kwargs):
        auth = request.headers.get('Authorization', '').replace('Bearer ', '')
        expected = get_agent_token()
        if not auth or auth != expected:
            return jsonify({'error': 'Not paired', 'status': 401}), 401
        return f(*args, **kwargs)
    return wrapper

def run_waydroid_shell(cmd: str) -> str:
    """Run a command inside the Waydroid container and return output."""
    try:
        result = subprocess.run(
            ['waydroid', 'shell', '--'] + cmd.split(),
            capture_output=True,
            text=True,
            timeout=10
        )
        return result.stdout.strip()
    except Exception as e:
        return f"Error: {e}"

def run_host_cmd(cmd: str) -> str:
    """Run a command on the host and return output."""
    try:
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=10)
        return result.stdout.strip()
    except Exception as e:
        return f"Error: {e}"

# ============== System Information Endpoints

@app.route('/api/system/info', methods=['GET'])
@require_auth
def system_info():
    """GET /api/system/info: Full system information."""
    ip = run_host_cmd("hostname -I | awk '{print $1}'")
    hostname = run_host_cmd("hostname")
    
    # Android version: ro.build.version.sdk (integer) maps to Android 17 for API 34
    sdk = run_waydroid_shell("getprop ro.build.version.sdk")
    android_versions = {"34": "17", "33": "13", "32": "12"}
    android_version = android_versions.get(sdk, sdk)
    
    # Check GApps presence
    gapps_present = "yes" if run_waydroid_shell("test -d /system/app/GmsCore && echo 1") == "1" else "no"
    
    return jsonify({
        'ip': ip,
        'hostname': hostname,
        'android_version': f"Android {android_version}",
        'gapps_status': gapps_present,
        'api_version': 2
    })

@app.route('/api/system/gapps-status', methods=['GET'])
@require_auth
def gapps_status():
    """GET /api/system/gapps-status: Check if GApps (Google Play Services) are installed."""
    gapps_installed = run_waydroid_shell("pm list packages com.google.android.gms")
    return jsonify({'gapps': 'yes' if gapps_installed else 'no'})

@app.route('/api/system/storage', methods=['GET'])
@require_auth
def storage_info():
    """GET /api/system/storage: Disk space info for /data partition."""
    df_out = run_waydroid_shell("df /data")
    # Parse 'df' output: Filesystem ... Used Available ... Mounted
    lines = df_out.split('\n')
    if len(lines) >= 2:
        parts = lines[1].split()
        if len(parts) >= 3:
            try:
                total_kb = int(parts[1])
                used_kb = int(parts[2])
                free_kb = int(parts[3])
                return jsonify({
                    'used_gb': round(used_kb / 1048576, 1),
                    'free_gb': round(free_kb / 1048576, 1),
                    'total_gb': round(total_kb / 1048576, 1),
                    'cache_mb': 120  # Placeholder: real impl uses dumpsys
                })
            except ValueError:
                pass
    return jsonify({
        'used_gb': 5.2,
        'free_gb': 8.8,
        'total_gb': 14.0,
        'cache_mb': 120,
        'error': 'Could not read storage'
    }), 503

# ============== Display Endpoints

@app.route('/api/display/info', methods=['GET'])
@require_auth
def display_info():
    """GET /api/display/info: Current display resolution and DPI."""
    # Get current DPI
    dpi_output = run_waydroid_shell("wm density")
    dpi = 240  # default
    if "Override density:" in dpi_output:
        match = re.search(r"Override density:\s*(\d+)", dpi_output)
        if match:
            dpi = int(match.group(1))
    
    # Get resolution
    size_output = run_waydroid_shell("wm size")
    width, height = 1920, 1080  # defaults
    if "Override size:" in size_output:
        match = re.search(r"Override size:\s*(\d+)x(\d+)", size_output)
        if match:
            width, height = int(match.group(1)), int(match.group(2))
    
    return jsonify({
        'width': width,
        'height': height,
        'dpi': dpi,
        'refresh_rate': 60.0
    })

@app.route('/api/display/modes', methods=['GET'])
@require_auth
def display_modes():
    """GET /api/display/modes: Available display modes (resolution + refresh rate combos)."""
    # Placeholder: real impl queries GPU capabilities
    return jsonify({
        'modes': [
            {'width': 1280, 'height': 720, 'refresh': 60.0},
            {'width': 1920, 'height': 1080, 'refresh': 60.0},
            {'width': 3840, 'height': 2160, 'refresh': 30.0},
        ]
    })

@app.route('/api/display/dpi', methods=['POST'])
@require_auth
def set_dpi():
    """POST /api/display/dpi: Set screen density/DPI."""
    data = request.json or {}
    dpi = data.get('dpi', 240)
    
    if not (100 <= dpi <= 800):
        return jsonify({'error': 'DPI must be 100-800'}), 400
    
    run_waydroid_shell(f"wm density {dpi}")
    return jsonify({'status': 'ok', 'dpi': dpi})

# ============== Applications Endpoints

@app.route('/api/apps', methods=['GET'])
@require_auth
def list_apps():
    """GET /api/apps: List installed non-system apps."""
    pkgs_out = run_waydroid_shell("pm list packages")
    apps = []
    for line in pkgs_out.split('\n'):
        pkg = line.replace('package:', '').strip()
        if pkg and not pkg.startswith('android'):
            # Get app name via dumpsys (slow, but accurate)
            # For demo, fake some common apps
            app_name = pkg.split('.')[-1].replace('_', ' ').title()
            apps.append({
                'package': pkg,
                'name': app_name,
                'version': '1.0',
                'installed': True
            })
    
    return jsonify({'apps': apps[:20]})  # Limit output

@app.route('/api/apps/launcher-list', methods=['GET'])
@require_auth
def launcher_list():
    """GET /api/apps/launcher-list: List available launchers."""
    projectivity_installed = "yes" if run_waydroid_shell("pm list packages com.projectivity.launcher") else "no"
    at4k_installed = "yes" if run_waydroid_shell("pm list packages com.overdevs.at4k") else "no"
    
    # Get current default launcher
    default_pkg = run_waydroid_shell("cmd package resolve-activity --brief -c android.intent.category.HOME com.android.internal.intent.action.MAIN").split('\n')[0].strip()
    
    return jsonify({
        'launchers': [
            {
                'name': 'Projectivity',
                'package': 'com.projectivity.launcher',
                'installed': projectivity_installed == 'yes',
                'is_default': default_pkg.startswith('com.projectivity')
            },
            {
                'name': 'AT4K',
                'package': 'com.overdevs.at4k',
                'installed': at4k_installed == 'yes',
                'is_default': default_pkg.startswith('com.overdevs')
            }
        ]
    })

@app.route('/api/apps/launcher-set', methods=['POST'])
@require_auth
def launcher_set():
    """POST /api/apps/launcher-set: Set default launcher."""
    data = request.json or {}
    pkg = data.get('package', '')
    
    valid_launchers = ['com.projectivity.launcher', 'com.overdevs.at4k']
    if pkg not in valid_launchers:
        return jsonify({'error': f'Unknown launcher: {pkg}'}), 400
    
    # Use the 'cmd package set-home-activity' to change default launcher
    # Alternatively: 'input keyevent KEYCODE_HOME' then let system dialog appear
    run_waydroid_shell(f"cmd package set-home-activity {pkg}/.MainActivity")
    
    return jsonify({'status': 'ok', 'launcher': pkg})

@app.route('/api/apps/uninstall', methods=['POST'])
@require_auth
def uninstall_app():
    """POST /api/apps/uninstall: Uninstall an app by package name."""
    data = request.json or {}
    pkg = data.get('package', '')
    
    if not pkg or pkg.startswith('android') or pkg.startswith('com.android'):
        return jsonify({'error': 'Cannot uninstall system apps'}), 400
    
    result = run_waydroid_shell(f"pm uninstall --user 0 {pkg}")
    success = 'Success' in result
    
    return jsonify({
        'status': 'ok' if success else 'failed',
        'package': pkg,
        'message': result
    })

# ============== Health & Pairing

@app.route('/api/health', methods=['GET'])
def health():
    """GET /api/health: Health check (no auth required)."""
    return jsonify({'status': 'ok', 'version': '1.0'})

@app.route('/api/pair', methods=['POST'])
def pair():
    """POST /api/pair: Establish pairing with a token."""
    data = request.json or {}
    device_token = data.get('device_token', 'waytv-default')
    
    # Save pairing info (real impl would write PAIRING_FILE securely)
    pairing_info = {
        'token': device_token,
        'agent_url': AGENT_URL or "http://192.168.240.1:8765",
        'paired_at': subprocess.run(['date', '+%s'], capture_output=True, text=True).stdout.strip()
    }
    
    # In real impl: write to PAIRING_FILE with 0600 perms inside Android container
    return jsonify({'status': 'ok', 'token': device_token})

# ============== Serve the App

if __name__ == '__main__':
    # Use a production server in real deployment (gunicorn, etc.)
    print(f"Starting WayTV Agent v1.0 on 0.0.0.0:{AGENT_PORT}")
    print(f"Token: {get_agent_token()}")
    app.run(host='0.0.0.0', port=AGENT_PORT, debug=False, threaded=True)
