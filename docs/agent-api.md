# WayTV agent API (v2)

The WayTV Settings app (inside Android, written in Rust) talks to `waytv-agent`, a small root service on the
Debian host. The agent listens **only** on the host side of Waydroid's bridge, so nothing on
the LAN can reach it:

- Base URL: `http://192.168.240.1:8765` (default; the real value is pushed to the app, see "Pairing")
- Every request needs `Authorization: Bearer <token>`. Wrong/missing token -> `401`.
- Requests from outside `192.168.240.0/24` -> `403`.
- Bodies are JSON (`Content-Type: application/json`), responses are JSON, UTF-8.
- Errors: HTTP 4xx/5xx with `{"ok": false, "error": "plain-language message"}`.
- Unknown fields must be ignored by both sides. The app must tolerate missing fields/nulls.

## Pairing (how the app gets the token)

The agent writes the URL and token into the app's private files folder, as root inside
Android, and gives the file to the app's user id:

```
/data/data/tv.waytv.settings/files/agent.json      (mode 600, owner = the app's uid)
{"url": "http://192.168.240.1:8765", "token": "<64 hex chars>"}
```

The app reads it from its internal data path (`<internalDataPath>/agent.json`, the same
folder) at start, on resume, and again after any `401`. Other Android apps cannot read it.
The agent re-writes it after every Android start and after the app is installed or updated
(`sudo waytv-agent pair` does it by hand). If the file is missing the app shows
"Not paired yet. On the box run: sudo waytv-agent pair" with a Retry button.

## Endpoints

### GET /api/status
```json
{
  "ok": true,
  "api": 1,
  "name": "WayTV",
  "script_version": 18,
  "hostname": "androidtv",
  "ips": ["192.168.1.157"],
  "ssh": "active",
  "user": "tv",
  "uptime_s": 5231,
  "display": {
    "width": 1920, "height": 1080, "refresh": 60.0,
    "refresh_setting": null,
    "modes": [
      {"width": 3840, "height": 2160, "refresh": 30.0,  "label": "3840x2160 at 30 Hz",  "current": false},
      {"width": 1920, "height": 1080, "refresh": 120.0, "label": "1920x1080 at 120 Hz", "current": false},
      {"width": 1920, "height": 1080, "refresh": 60.0,  "label": "1920x1080 at 60 Hz",  "current": true}
    ],
    "presets": [
      {"id": "1080p", "width": 1920, "height": 1080, "label": "1080p (1920x1080) at 60 Hz", "available": true},
      {"id": "4k",    "width": 3840, "height": 2160, "label": "4K (3840x2160) at 30 Hz",   "available": true},
      {"id": "720p",  "width": 1280, "height": 720,  "label": "720p (1280x720) at 60 Hz",  "available": true}
    ]
  },
  "hdr": {"tv": ["HDR10", "HLG"], "available": false,
          "reasons": ["Waydroid draws Android in SDR only: ...", "The screen program (wlroots 0.18 in Debian 13) has no HDR output."]},
  "density": {"current": 240, "suggested": 240, "default": 180},
  "navbar": "hidden",
  "overlay": "off",
  "timezone": {"android": "America/New_York", "box": "America/New_York"},
  "updates": {
    "status_line": "Everything is up to date.",
    "script_latest": 18,
    "debian_pending": 0,
    "reboot_needed": false,
    "checked_at": "2026-11-07T05:30:00-05:00"
  },
  "perf": "FPS 60  CPU 40%  RAM 1.6/3.7 GB  GPU 78%",
  "job": null
}
```
`display.modes` lists every mode the TV offers (biggest first; what the box's GPU can drive),
`current` marks the active one. `display.refresh_setting` is the chosen refresh rate, or null for
"automatic" (fastest rate up to 60 Hz). `hdr.tv` lists the HDR formats the TV announces;
`hdr.available` says whether the box can output HDR now, `hdr.reasons` explains why not.
`density.current` is null when Android uses its default. `navbar` is `hidden`/`shown`,
`overlay` is `on`/`off`. `perf` is null when the overlay service is off. `job` is the
running job (same shape as GET /api/jobs/<id>) or null. `updates.*` may be null before
the first check.

### POST /api/apply  (v2, preferred)
Apply several settings at once with **at most one Android restart**. Every key is optional;
send only what the user changed:
```json
{"display": {"width": 3840, "height": 2160, "refresh": 30},
 "density": 480, "navbar": "off", "overlay": "on", "timezone": "Europe/Madrid"}
```
`display.refresh` may be a number from `display.modes` or null/"auto" (fastest up to 60 Hz).
`density` is 100-800, "auto" or "reset". Everything is validated first; if anything is invalid
nothing changes and you get `400` with the reason. Time zone and scaling apply at once; display,
navbar and overlay are combined into one task that restarts Android once.
-> `{"ok": true, "applied": ["display", "density"], "restarting": true, "job": {...} | null}`.
Values equal to the current ones are skipped (not listed in `applied`).

### POST /api/display  `{"width": 1920, "height": 1080, "refresh": 60}`
Any mode from `display.modes` is accepted (`refresh` optional). Saves the choice, switches the HDMI output
and Android, adjusts scaling if a custom scaling was set. **Restarts Android** about 2 s after
replying: `{"ok": true, "restarting": true}`.

### POST /api/density  `{"value": 240}` or `{"value": "auto"}` or `{"value": "reset"}`
Number 100-800. Applies at once, no restart. -> `{"ok": true, "density": 240}`.

### POST /api/navbar  `{"state": "off"}` / `{"state": "on"}`
`off` hides the bottom bar. **Restarts Android** -> `{"ok": true, "restarting": true}`
(or `{"ok": true, "restarting": false}` if nothing changed).

### POST /api/overlay  `{"state": "on"}` / `{"state": "off"}`
Performance overlay (FPS, CPU, RAM, GPU). **Restarts Android** -> `{"ok": true, "restarting": true}`.
Turning it on the first time installs packages, so it runs as a job:
`{"ok": true, "job": {...}}` then restarts Android when done.

### GET /api/timezones
`{"ok": true, "timezones": ["Africa/Abidjan", ...]}` sorted, Area/City names only.

### POST /api/timezone  `{"tz": "America/New_York"}`
Sets the box's and Android's time zone. -> `{"ok": true, "tz": "America/New_York"}`.

### POST /api/update/check
Starts a job: checks GitHub for a new script/app and Debian for updates. -> `{"ok": true, "job": {...}}`

### POST /api/update/run
Starts a job: script self-update, Debian full-upgrade, Android image upgrade, app update.
At the end Android restarts (the app is killed). The job log is kept on disk, so after
Android comes back the app shows the result via GET /api/jobs/last.
-> `{"ok": true, "job": {...}}`. Only one job runs at a time; a second one gets
`409 {"ok": false, "error": "Another task is running: Update"}`.

### GET /api/jobs/<id>  and  GET /api/jobs/last
```json
{"ok": true, "job": {"id": "1731000000-update", "kind": "update", "title": "Update",
 "state": "running", "exit_code": null, "started": "2026-11-07T05:31:00-05:00",
 "finished": null, "log": "last ~200 lines of output, plain text"}}
```
`state` is `running`, `done` or `failed`. `/api/jobs/last` returns `{"ok": true, "job": null}` if none.

### POST /api/restart-android
`{"ok": true, "restarting": true}`; Android restarts 2 s later.

### POST /api/reboot
`{"ok": true, "rebooting": true}`; the box reboots 3 s later.
