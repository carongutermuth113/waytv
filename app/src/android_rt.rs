//! Android runtime: NativeActivity event loop (android-activity), EGL/GLES
//! context (khronos-egl), egui rendering (egui_glow), raw key/axis/touch input,
//! background HTTP workers and polling timers.
//!
//! We deliberately do NOT use winit/eframe: winit's Android backend drops
//! gamepad buttons (KEYCODE_BUTTON_A/B/Y/L1/R1 become unidentified keys that
//! egui ignores) and ignores joystick MotionEvents (hat/stick). Reading
//! android-activity's InputEvents directly gives us every raw key code and
//! axis, and lets us mark BACK as handled so the activity is not finished.

use crate::api::{self, ApiError, ApiReq, Pairing};
use crate::keys::{StickRepeater, fires_on_repeat, map_keycode};
use crate::state::{AppState, Effect};
use crate::ui;
use android_activity::input::{Axis, InputEvent, KeyAction, MotionAction, Source};
use android_activity::{AndroidApp, InputStatus, MainEvent, PollEvent};
use khronos_egl as egl;
use std::collections::HashSet;
use std::ffi::CString;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::mpsc::{Receiver, Sender, channel};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

// khronos-egl's "static" feature expects the app to link libEGL itself.
#[link(name = "EGL")]
unsafe extern "C" {}

type Reply = (ApiReq, Result<serde_json::Value, ApiError>);

const STATUS_EVERY: Duration = Duration::from_secs(5);
const JOB_EVERY: Duration = Duration::from_secs(1);

struct Gfx {
    egl: egl::Instance<egl::Static>,
    display: egl::Display,
    config: egl::Config,
    context: egl::Context,
    surface: Option<egl::Surface>,
    window: Option<ndk::native_window::NativeWindow>,
    painter: Option<egui_glow::Painter>,
    gl: Option<Arc<glow::Context>>,
}

impl Gfx {
    fn new() -> Option<Gfx> {
        let egl = egl::Instance::new(egl::Static);
        let display = unsafe { egl.get_display(egl::DEFAULT_DISPLAY) }?;
        egl.initialize(display).ok()?;
        let attrs = [
            egl::RED_SIZE,
            8,
            egl::GREEN_SIZE,
            8,
            egl::BLUE_SIZE,
            8,
            egl::ALPHA_SIZE,
            8,
            egl::SURFACE_TYPE,
            egl::WINDOW_BIT,
            egl::RENDERABLE_TYPE,
            egl::OPENGL_ES3_BIT,
            egl::NONE,
        ];
        let config = match egl.choose_first_config(display, &attrs) {
            Ok(Some(c)) => c,
            _ => {
                let attrs2 = [
                    egl::SURFACE_TYPE,
                    egl::WINDOW_BIT,
                    egl::RENDERABLE_TYPE,
                    egl::OPENGL_ES2_BIT,
                    egl::NONE,
                ];
                egl.choose_first_config(display, &attrs2).ok()??
            }
        };
        egl.bind_api(egl::OPENGL_ES_API).ok()?;
        let context = egl
            .create_context(
                display,
                config,
                None,
                &[egl::CONTEXT_CLIENT_VERSION, 3, egl::NONE],
            )
            .or_else(|_| {
                egl.create_context(
                    display,
                    config,
                    None,
                    &[egl::CONTEXT_CLIENT_VERSION, 2, egl::NONE],
                )
            })
            .ok()?;
        Some(Gfx {
            egl,
            display,
            config,
            context,
            surface: None,
            window: None,
            painter: None,
            gl: None,
        })
    }

    fn attach(&mut self, window: ndk::native_window::NativeWindow) {
        self.detach();
        let surface = unsafe {
            self.egl.create_window_surface(
                self.display,
                self.config,
                window.ptr().as_ptr() as _,
                None,
            )
        };
        let surface = match surface {
            Ok(s) => s,
            Err(e) => {
                log::error!("eglCreateWindowSurface failed: {e:?}");
                return;
            }
        };
        if let Err(e) = self.egl.make_current(
            self.display,
            Some(surface),
            Some(surface),
            Some(self.context),
        ) {
            log::error!("eglMakeCurrent failed: {e:?}");
            return;
        }
        let _ = self.egl.swap_interval(self.display, 1);
        self.surface = Some(surface);
        self.window = Some(window);
        if self.painter.is_none() {
            let gles = unsafe {
                libc::dlopen(c"libGLESv2.so".as_ptr(), libc::RTLD_NOW | libc::RTLD_LOCAL)
            };
            let egl_inst = &self.egl;
            let gl = unsafe {
                glow::Context::from_loader_function(|name| {
                    if let Some(f) = egl_inst.get_proc_address(name) {
                        return f as *const _;
                    }
                    if gles.is_null() {
                        return std::ptr::null();
                    }
                    let c = CString::new(name).unwrap_or_default();
                    libc::dlsym(gles, c.as_ptr()) as *const _
                })
            };
            let gl = Arc::new(gl);
            match egui_glow::Painter::new(gl.clone(), "", None, true) {
                Ok(p) => {
                    self.painter = Some(p);
                    self.gl = Some(gl);
                }
                Err(e) => log::error!("egui_glow painter: {e}"),
            }
        }
    }

    fn detach(&mut self) {
        if let Some(s) = self.surface.take() {
            let _ = self
                .egl
                .make_current(self.display, None, None, Some(self.context));
            let _ = self.egl.destroy_surface(self.display, s);
        }
        self.window = None;
    }

    fn size(&self) -> Option<(u32, u32)> {
        let s = self.surface?;
        let w = self.egl.query_surface(self.display, s, egl::WIDTH).ok()?;
        let h = self.egl.query_surface(self.display, s, egl::HEIGHT).ok()?;
        (w > 0 && h > 0).then_some((w as u32, h as u32))
    }
}

struct Runtime {
    app: AndroidApp,
    data_dir: PathBuf,
    pairing: Option<Pairing>,
    state: AppState,
    tx: Sender<Reply>,
    rx: Receiver<Reply>,
    inflight: HashSet<String>,
    next_status: Instant,
    next_job: Instant,
    visible: bool,
    stick: StickRepeater,
    hat: StickRepeater,
    egui_events: Vec<egui::Event>,
    ppp: f32,
    dirty: bool,
    repaint_at: Option<Instant>,
    quit: bool,
    t0: Instant,
}

impl Runtime {
    fn reload_pairing(&mut self) -> bool {
        let new = Pairing::load(&self.data_dir.join("agent.json"));
        let changed = new != self.pairing;
        if changed {
            log::info!(
                "pairing {}",
                if new.is_some() { "loaded" } else { "missing" }
            );
        }
        self.pairing = new;
        changed
    }

    fn run_effects(&mut self, fx: Vec<Effect>) {
        let mut queue = fx;
        while !queue.is_empty() {
            let mut next = vec![];
            for e in queue {
                match e {
                    Effect::Request(req) => self.request(req),
                    Effect::ReloadPairing => {
                        let changed = self.reload_pairing();
                        next.extend(self.state.on_pairing(self.pairing.is_some(), changed));
                    }
                    Effect::MarkJobSeen(id) => {
                        let _ = std::fs::write(self.data_dir.join("last_job_seen"), id);
                    }
                    Effect::Exit => self.quit = true,
                }
            }
            queue = next;
        }
        self.dirty = true;
    }

    fn request(&mut self, req: ApiReq) {
        let is_get = matches!(
            req,
            ApiReq::Status | ApiReq::Job(_) | ApiReq::JobsLast | ApiReq::Timezones
        );
        let key = format!("{req:?}");
        if is_get && !self.inflight.insert(key) {
            return;
        }
        if req == ApiReq::Status {
            self.next_status = Instant::now() + STATUS_EVERY;
        }
        if matches!(req, ApiReq::Job(_)) {
            self.next_job = Instant::now() + JOB_EVERY;
        }
        let pairing = self.pairing.clone();
        let tx = self.tx.clone();
        let waker = self.app.create_waker();
        std::thread::spawn(move || {
            let res = api::execute(pairing.as_ref(), &req);
            if let Err(e) = &res {
                log::warn!("{req:?} -> {e:?}");
            }
            let _ = tx.send((req, res));
            waker.wake();
        });
    }

    fn nav(&mut self, n: crate::keys::Nav) {
        let fx = self.state.nav(n);
        self.run_effects(fx);
    }

    fn handle_input(&mut self) {
        let mut navs = Vec::new();
        let mut events = Vec::new();
        let mut axes: Vec<(bool, f32, f32)> = Vec::new();
        let ppp = self.ppp;
        if let Ok(mut iter) = self.app.input_events_iter() {
            loop {
                let more = iter.next(|ev| match ev {
                    InputEvent::KeyEvent(k) => {
                        let code: u32 = k.key_code().into();
                        let nav = map_keycode(code, k.meta_state().shift_on());
                        log::info!(
                            "key code={code} action={:?} repeat={} dev={} src={:?} -> {nav:?}",
                            k.action(),
                            k.repeat_count(),
                            k.device_id(),
                            k.source()
                        );
                        match nav {
                            Some(n) => {
                                if k.action() == KeyAction::Down
                                    && (k.repeat_count() == 0 || fires_on_repeat(n))
                                {
                                    navs.push(n);
                                }
                                InputStatus::Handled
                            }
                            None => InputStatus::Unhandled,
                        }
                    }
                    InputEvent::MotionEvent(m) => {
                        let src = m.source();
                        if src.is_joystick_class()
                            || src == Source::Joystick
                            || src == Source::Gamepad
                        {
                            let p = m.pointer_at_index(0);
                            axes.push((true, p.axis_value(Axis::HatX), p.axis_value(Axis::HatY)));
                            axes.push((false, p.axis_value(Axis::X), p.axis_value(Axis::Y)));
                            return InputStatus::Handled;
                        }
                        if src.is_pointer_class() {
                            let idx = m.pointer_index();
                            let p =
                                m.pointer_at_index(idx.min(m.pointer_count().saturating_sub(1)));
                            let pos = egui::pos2(p.x() / ppp, p.y() / ppp);
                            let modifiers = egui::Modifiers::default();
                            if matches!(m.action(), MotionAction::Down | MotionAction::Up) {
                                log::info!(
                                    "pointer {:?} src={src:?} px=({:.0},{:.0}) pt=({:.0},{:.0})",
                                    m.action(),
                                    p.x(),
                                    p.y(),
                                    pos.x,
                                    pos.y
                                );
                            }
                            match m.action() {
                                MotionAction::Down | MotionAction::PointerDown => {
                                    events.push(egui::Event::PointerMoved(pos));
                                    events.push(egui::Event::PointerButton {
                                        pos,
                                        button: egui::PointerButton::Primary,
                                        pressed: true,
                                        modifiers,
                                    });
                                }
                                MotionAction::Up
                                | MotionAction::PointerUp
                                | MotionAction::Cancel => {
                                    events.push(egui::Event::PointerButton {
                                        pos,
                                        button: egui::PointerButton::Primary,
                                        pressed: false,
                                        modifiers,
                                    });
                                    if src == Source::Touchscreen {
                                        events.push(egui::Event::PointerGone);
                                    }
                                }
                                MotionAction::Move | MotionAction::HoverMove => {
                                    events.push(egui::Event::PointerMoved(pos))
                                }
                                MotionAction::Scroll => {
                                    let v = p.axis_value(Axis::Vscroll);
                                    events.push(egui::Event::MouseWheel {
                                        unit: egui::MouseWheelUnit::Line,
                                        delta: egui::vec2(0.0, v),
                                        phase: egui::TouchPhase::Move,
                                        source: egui::MouseWheelSource::Unknown,
                                        modifiers,
                                    });
                                }
                                MotionAction::HoverExit => events.push(egui::Event::PointerGone),
                                _ => {}
                            }
                            return InputStatus::Handled;
                        }
                        InputStatus::Unhandled
                    }
                    _ => InputStatus::Unhandled,
                });
                if !more {
                    break;
                }
            }
        }
        let now = Instant::now();
        for (hat, x, y) in axes {
            let r = if hat { &mut self.hat } else { &mut self.stick };
            if let Some(n) = r.update(x, y, now) {
                log::info!(
                    "axis {} ({x:.2},{y:.2}) -> {n:?}",
                    if hat { "hat" } else { "stick" }
                );
                navs.push(n);
            }
        }
        if !events.is_empty() {
            self.egui_events.extend(events);
            self.dirty = true;
        }
        for n in navs {
            self.nav(n);
        }
    }

    fn timers(&mut self) {
        let now = Instant::now();
        if let Some(n) = self.stick.tick(now) {
            self.nav(n);
        }
        if let Some(n) = self.hat.tick(now) {
            self.nav(n);
        }
        if self.state.tick(now) {
            self.dirty = true;
        }
        if self.visible && self.state.polling_allowed() && self.pairing.is_some() {
            if now >= self.next_status {
                self.request(ApiReq::Status);
            }
            if let Some(id) = self.state.job_to_poll()
                && now >= self.next_job
            {
                self.request(ApiReq::Job(id));
            }
        }
        if self.repaint_at.is_some_and(|t| now >= t) {
            self.repaint_at = None;
            self.dirty = true;
        }
    }

    fn drain_replies(&mut self) {
        while let Ok((req, res)) = self.rx.try_recv() {
            self.inflight.remove(&format!("{req:?}"));
            let now_unix = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_secs() as i64)
                .unwrap_or(0);
            let fx = self.state.on_response(&req, res, now_unix);
            self.run_effects(fx);
        }
    }

    fn timeout(&self) -> Duration {
        let now = Instant::now();
        let mut t = now + Duration::from_secs(1);
        let mut consider = |d: Option<Instant>| {
            if let Some(d) = d
                && d < t
            {
                t = d;
            }
        };
        consider(self.stick.deadline());
        consider(self.hat.deadline());
        consider(self.repaint_at);
        if self.visible {
            consider(Some(self.next_status));
            if self.state.job_to_poll().is_some() {
                consider(Some(self.next_job));
            }
        }
        consider(self.state.banner.as_ref().map(|b| b.until));
        t.saturating_duration_since(now)
    }

    fn render(&mut self, ctx: &egui::Context, gfx: &mut Gfx) {
        let Some((w, h)) = gfx.size() else { return };
        let (Some(painter), Some(gl)) = (gfx.painter.as_mut(), gfx.gl.clone()) else {
            return;
        };
        self.dirty = false;
        let ppp = h as f32 / ui::LOGICAL_HEIGHT;
        self.ppp = ppp;
        let mut raw = egui::RawInput {
            screen_rect: Some(egui::Rect::from_min_size(
                egui::Pos2::ZERO,
                egui::vec2(w as f32 / ppp, h as f32 / ppp),
            )),
            time: Some(self.t0.elapsed().as_secs_f64()),
            events: std::mem::take(&mut self.egui_events),
            max_texture_side: Some(4096),
            ..Default::default()
        };
        raw.viewports
            .entry(egui::ViewportId::ROOT)
            .or_default()
            .native_pixels_per_point = Some(ppp);
        raw.viewports
            .entry(egui::ViewportId::ROOT)
            .or_default()
            .focused = Some(true);
        let mut clicks = Vec::new();
        let state = &mut self.state;
        let out = ctx.run_ui(raw, |ui| {
            clicks = ui::draw(ui, state);
        });
        let delay = out
            .viewport_output
            .get(&egui::ViewportId::ROOT)
            .map(|v| v.repaint_delay);
        let prims = ctx.tessellate(out.shapes, out.pixels_per_point);
        let mut tex = out.textures_delta;
        unsafe {
            use glow::HasContext;
            gl.clear_color(0.06, 0.08, 0.11, 1.0);
            gl.clear(glow::COLOR_BUFFER_BIT);
        }
        painter.paint_and_update_textures([w, h], out.pixels_per_point, &prims, &mut tex);
        if let Some(s) = gfx.surface
            && let Err(e) = gfx.egl.swap_buffers(gfx.display, s)
        {
            log::warn!("eglSwapBuffers: {e:?}");
        }
        if let Some(d) = delay
            && d < Duration::from_secs(5)
        {
            let at = Instant::now() + d;
            if self.repaint_at.is_none_or(|t| at < t) {
                self.repaint_at = Some(at);
            }
        }
        for c in clicks {
            log::info!("click {c:?}");
            let fx = self.state.click(c);
            self.run_effects(fx);
        }
    }
}

pub fn run(app: AndroidApp) {
    android_logger::init_once(
        android_logger::Config::default()
            .with_max_level(log::LevelFilter::Info)
            .with_tag("WayTV"),
    );
    log::info!("WayTV Settings {} starting", env!("CARGO_PKG_VERSION"));
    let data_dir = app
        .internal_data_path()
        .unwrap_or_else(|| PathBuf::from("/data/data/tv.waytv.settings/files"));
    let last_seen = std::fs::read_to_string(data_dir.join("last_job_seen"))
        .ok()
        .map(|s| s.trim().to_string());
    let (tx, rx) = channel();
    let mut rt = Runtime {
        app: app.clone(),
        data_dir,
        pairing: None,
        state: AppState::new(last_seen),
        tx,
        rx,
        inflight: HashSet::new(),
        next_status: Instant::now() + STATUS_EVERY,
        next_job: Instant::now(),
        visible: true,
        stick: StickRepeater::default(),
        hat: StickRepeater::default(),
        egui_events: Vec::new(),
        ppp: 2.0,
        dirty: true,
        repaint_at: None,
        quit: false,
        t0: Instant::now(),
    };
    rt.reload_pairing();
    let fx = rt.state.start(rt.pairing.is_some());
    rt.run_effects(fx);

    let ctx = egui::Context::default();
    ui::setup_style(&ctx);
    let mut gfx = Gfx::new();
    if gfx.is_none() {
        log::error!("EGL init failed");
    }
    let mut destroyed = false;

    while !destroyed && !rt.quit {
        let timeout = rt.timeout();
        app.poll_events(Some(timeout), |event| {
            if let PollEvent::Main(me) = event {
                match me {
                    MainEvent::InitWindow { .. } => {
                        if let (Some(g), Some(w)) = (gfx.as_mut(), app.native_window()) {
                            g.attach(w);
                        }
                        rt.dirty = true;
                    }
                    MainEvent::TerminateWindow { .. } => {
                        if let Some(g) = gfx.as_mut() {
                            g.detach();
                        }
                    }
                    MainEvent::WindowResized { .. }
                    | MainEvent::RedrawNeeded { .. }
                    | MainEvent::ContentRectChanged { .. }
                    | MainEvent::ConfigChanged { .. }
                    | MainEvent::GainedFocus
                    | MainEvent::InsetsChanged { .. } => rt.dirty = true,
                    MainEvent::Resume { .. } => {
                        rt.visible = true;
                        let changed = rt.reload_pairing();
                        let mut fx = rt.state.on_pairing(rt.pairing.is_some(), changed);
                        if fx.is_empty() && rt.pairing.is_some() {
                            fx.push(Effect::Request(ApiReq::Status));
                        }
                        rt.run_effects(fx);
                    }
                    MainEvent::Pause => {
                        rt.visible = false;
                        rt.stick.reset();
                        rt.hat.reset();
                    }
                    MainEvent::Destroy => destroyed = true,
                    _ => {}
                }
            }
        });
        rt.handle_input();
        rt.drain_replies();
        rt.timers();
        if rt.dirty
            && let Some(g) = gfx.as_mut()
        {
            rt.render(&ctx, g);
        }
    }
    log::info!("WayTV Settings exiting (quit={})", rt.quit);
    if let Some(g) = gfx.as_mut() {
        if let Some(mut p) = g.painter.take() {
            p.destroy();
        }
        g.detach();
    }
}
