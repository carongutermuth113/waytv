# WayTV Settings (Android app, Rust)

Controller / remote friendly settings app for WayTV boxes. It runs inside Waydroid
(LineageOS 20, x86_64) and talks to `waytv-agent` on the Debian host
(API: [`../docs/agent-api.md`](../docs/agent-api.md)).

All logic and UI are Rust. The APK is a pure `android.app.NativeActivity`
(`android:hasCode="false"`): no Java/Kotlin sources, no Gradle.

## Layout

| Path | What |
|---|---|
| `src/model.rs` | serde types for status/job/replies; every field optional, `null`/wrong types/unknown fields tolerated |
| `src/api.rs` | `agent.json` pairing, tiny HTTP/1.1 client over `TcpStream`, request bodies |
| `src/keys.rs` | Android key code -> navigation command; stick/hat -> repeating moves |
| `src/state.rs` | own focus model + screens/dialogs + reactions to agent answers (pure, unit tested) |
| `src/ui.rs` | egui drawing (hand-placed, 540 logical points high -> 2 px/pt at 1080p) |
| `src/android_rt.rs` | android-activity event loop, EGL/GLES (khronos-egl + glow), egui_glow painter, worker threads, timers |
| `AndroidManifest.xml`, `res/` | manifest, adaptive icon and 320x180 TV banner (vector drawables) |
| `build-apk.sh` | cargo-ndk -> aapt2 -> zipalign -> apksigner (v2+v3) |

Why not eframe/winit: winit's Android backend turns gamepad buttons
(`KEYCODE_BUTTON_A/B/Y/L1/R1`) into unidentified keys that egui drops, and ignores
joystick `MotionEvent`s. Reading android-activity's `InputEvent`s directly gives every raw
key code and axis, and lets the app mark BACK as handled so Android doesn't finish the
activity.

## Controls

| Input | Android key code / axis | Action |
|---|---|---|
| D-pad / arrow keys | `DPAD_UP/DOWN/LEFT/RIGHT` (19-22) | move focus (auto-repeat when held) |
| Hat / left stick | `AXIS_HAT_X/Y`, `AXIS_X/Y` (dead zone 0.5, repeat 400 ms then 140 ms) | move focus |
| OK | `DPAD_CENTER` 23, `ENTER` 66, `NUMPAD_ENTER` 160, `BUTTON_A` 96, `SPACE` 62, `BUTTON_START` 108 | select |
| Back | `BUTTON_B` 97, `BACK` 4, `ESCAPE` 111 | close dialog / rows -> section list / exit (only from the section list) |
| Section | `BUTTON_L1` 102 / `BUTTON_R1` 103, `PAGE_UP/DOWN`, (Shift+)`TAB` | previous / next section (in long lists: jump 10) |
| Refresh | `BUTTON_Y` 100, `BUTTON_X` 99, `F5` | reload status |
| Mouse / touch | pointer events | click sections, rows, list items, dialog buttons |

Other keys (HOME, volume, ...) are returned unhandled so Android processes them.
Every key is logged: `logcat -s WayTV:I`.

## Build

Needs: Rust (stable) with target `x86_64-linux-android`, `cargo-ndk` 4.x, Android SDK with
`platforms;android-34`, `build-tools;34.0.0`, `ndk;27.3.13750724`, Java 17 (for apksigner), python3.

```sh
rustup target add x86_64-linux-android
cargo install cargo-ndk --version 4.1.2 --locked
cargo test                      # host unit tests (JSON, state machine, HTTP mock server)
export ANDROID_HOME=...         # SDK
export WAYTV_KEYSTORE=/path/waytv-release.jks WAYTV_KEYSTORE_PASSWORD=... WAYTV_KEY_ALIAS=waytv WAYTV_KEY_PASSWORD=...
VERSION_CODE=1 VERSION_NAME=1.0 ./build-apk.sh   # -> build/waytv-settings.apk
```

Without `WAYTV_KEYSTORE` the script produces `build/waytv-settings-unsigned.apk`.
CI: `.github/workflows/app.yml` (tag `app-vN` -> versionCode N, versionName 1.N, GitHub Release).

Install on the box: `sudo waytv-apps install waytv-settings.apk` (re-pairs automatically).
