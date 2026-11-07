//! WayTV Settings: a controller-friendly TV settings app for WayTV boxes.
//!
//! Pure NativeActivity app (no Java/Kotlin). The platform-independent parts
//! (API client, JSON model, focus/state machine, input mapping, UI drawing)
//! are unit tested on the host; `android_rt` holds the Android event loop.

pub mod api;
pub mod keys;
pub mod model;
pub mod state;
pub mod ui;

#[cfg(target_os = "android")]
mod android_rt;

#[cfg(target_os = "android")]
#[unsafe(no_mangle)]
fn android_main(app: android_activity::AndroidApp) {
    android_rt::run(app);
}
