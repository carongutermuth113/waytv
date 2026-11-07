//! 10-foot UI drawn with egui. Everything is painted by hand at fixed
//! positions in "points" (the screen is always 540 points high, so 1 pt = 2 px
//! on a 1080p TV). Focus comes from `AppState`, never from egui.

use crate::model::{human_duration, short_time};
use crate::state::{AppState, Blocking, Click, Conn, Modal, Pane, RowKind, Section};
use egui::{
    Align, Align2, Color32, CornerRadius, FontId, Pos2, Rect, Sense, Stroke, StrokeKind, Ui, Vec2,
    pos2, vec2,
};
use std::time::Duration;

/// Logical screen height in points; pixels_per_point = screen_px_height / this.
pub const LOGICAL_HEIGHT: f32 = 540.0;

const BG: Color32 = Color32::from_rgb(0x10, 0x14, 0x1c);
const HEADER_BG: Color32 = Color32::from_rgb(0x18, 0x1e, 0x2a);
const ITEM_BG: Color32 = Color32::from_rgb(0x1f, 0x27, 0x36);
const ITEM_SEL_BG: Color32 = Color32::from_rgb(0x2a, 0x36, 0x4c);
const FOCUS_BG: Color32 = Color32::from_rgb(0x2f, 0x4f, 0x7a);
const FOCUS: Color32 = Color32::from_rgb(0x6c, 0xd4, 0xff);
const TEXT: Color32 = Color32::from_rgb(0xe8, 0xec, 0xf2);
const DIM: Color32 = Color32::from_rgb(0x9a, 0xa5, 0xb8);
const ACCENT: Color32 = Color32::from_rgb(0x8e, 0xd0, 0xff);
const WARN: Color32 = Color32::from_rgb(0xff, 0xb7, 0x4d);
const ERR_BG: Color32 = Color32::from_rgb(0x8a, 0x22, 0x22);
const OK_BG: Color32 = Color32::from_rgb(0x1e, 0x6b, 0x3a);

const BODY: f32 = 15.0; // 30 px at 1080p
const TITLE: f32 = 22.0; // 44 px
const SMALL: f32 = 12.0; // 24 px
const MONO: f32 = 10.5; // 21 px

fn font(size: f32) -> FontId {
    FontId::proportional(size)
}

fn r(v: f32) -> CornerRadius {
    CornerRadius::same(v as u8)
}

/// A selectable item: rounded box, bright outline + slightly larger when focused.
#[allow(clippy::too_many_arguments)]
fn item(
    ui: &Ui,
    rect: Rect,
    label: &str,
    value: &str,
    focused: bool,
    selected: bool,
    enabled: bool,
    value_color: Color32,
) {
    let p = ui.painter();
    let (rect, bg, size) = if focused {
        (rect.expand(3.0), FOCUS_BG, BODY + 1.5)
    } else if selected {
        (rect, ITEM_SEL_BG, BODY)
    } else {
        (rect, ITEM_BG, BODY)
    };
    p.rect_filled(rect, r(10.0), bg);
    if focused {
        p.rect_stroke(rect, r(10.0), Stroke::new(3.0, FOCUS), StrokeKind::Outside);
    }
    let tc = if !enabled {
        DIM
    } else if focused {
        Color32::WHITE
    } else {
        TEXT
    };
    let lg = p.layout_no_wrap(label.to_string(), font(size), tc);
    let ly = rect.center().y - lg.size().y / 2.0;
    p.galley(pos2(rect.left() + 18.0, ly), lg.clone(), tc);
    if !value.is_empty() {
        let max_w = rect.width() - lg.size().x - 54.0;
        let vg = p.layout(
            value.to_string(),
            font(size - 1.0),
            value_color,
            max_w.max(60.0),
        );
        let vy = rect.center().y - vg.size().y / 2.0;
        p.galley(pos2(rect.right() - 18.0 - vg.size().x, vy), vg, value_color);
    }
}

fn button(ui: &Ui, rect: Rect, label: &str, focused: bool) {
    let p = ui.painter();
    let (rect, bg) = if focused {
        (rect.expand(3.0), FOCUS_BG)
    } else {
        (rect, ITEM_BG)
    };
    p.rect_filled(rect, r(10.0), bg);
    if focused {
        p.rect_stroke(rect, r(10.0), Stroke::new(3.0, FOCUS), StrokeKind::Outside);
    } else {
        p.rect_stroke(rect, r(10.0), Stroke::new(1.0, DIM), StrokeKind::Inside);
    }
    let size = if focused { BODY + 1.5 } else { BODY };
    p.text(
        rect.center(),
        Align2::CENTER_CENTER,
        label,
        font(size),
        if focused { Color32::WHITE } else { TEXT },
    );
}

fn clicked(ui: &Ui, rect: Rect, id: impl egui::AsIdSalt, enabled: bool) -> bool {
    enabled
        && ui
            .interact(rect, egui::Id::unique(("waytv", id)), Sense::click())
            .clicked()
}

/// Paint wrapped text, return its height.
fn text_block(ui: &Ui, pos: Pos2, text: &str, size: f32, color: Color32, width: f32) -> f32 {
    let g = ui
        .painter()
        .layout(text.to_string(), font(size), color, width);
    let h = g.size().y;
    ui.painter().galley(pos, g, color);
    h
}

fn spinner(ui: &Ui, center: Pos2, radius: f32) {
    let t = ui.input(|i| i.time);
    let p = ui.painter();
    let n = 10;
    let head = ((t * 10.0) as usize) % n;
    for k in 0..n {
        let a = k as f32 / n as f32 * std::f32::consts::TAU;
        let age = (head + n - k) % n;
        let alpha = (255.0 * (1.0 - age as f32 / n as f32)).clamp(40.0, 255.0) as u8;
        let c = Color32::from_rgba_unmultiplied(0x6c, 0xd4, 0xff, alpha);
        p.circle_filled(center + vec2(a.cos(), a.sin()) * radius, radius * 0.18, c);
    }
    ui.ctx().request_repaint_after(Duration::from_millis(60));
}

pub fn setup_style(ctx: &egui::Context) {
    ctx.set_visuals(egui::Visuals::dark());
    ctx.all_styles_mut(|s| {
        s.interaction.selectable_labels = false;
        s.spacing.scroll.bar_width = 8.0;
    });
}

/// Draw one frame. Returns mouse/touch activations.
pub fn draw(ui: &mut Ui, st: &mut AppState) -> Vec<Click> {
    let mut clicks = Vec::new();
    let screen = ui.max_rect();
    ui.painter().rect_filled(screen, 0.0, BG);
    let scroll = std::mem::take(&mut st.scroll_to_focus);

    if let Some(b) = st.blocking {
        let (t, sub) = match b {
            Blocking::Restarting => ("Android is restarting…", "This takes about a minute."),
            Blocking::Rebooting => (
                "The box is rebooting…",
                "The TV comes back in a couple of minutes.",
            ),
        };
        spinner(ui, screen.center() - vec2(0.0, 80.0), 26.0);
        ui.painter().text(
            screen.center(),
            Align2::CENTER_CENTER,
            t,
            font(TITLE + 4.0),
            TEXT,
        );
        ui.painter().text(
            screen.center() + vec2(0.0, 44.0),
            Align2::CENTER_CENTER,
            sub,
            font(BODY),
            DIM,
        );
        return clicks;
    }

    draw_header(ui, st, screen);
    let modal_open = !st.modals.is_empty();

    if st.main_visible() {
        draw_main(ui, st, screen, !modal_open, &mut clicks);
    } else {
        draw_conn(ui, st, screen, !modal_open, &mut clicks);
    }

    // Footer hint
    let hint = if modal_open {
        "Up/Down/Left/Right: move     A / OK: select     B / Back: close"
    } else if !st.changes.is_empty() {
        "D-pad: move     A / OK: select     B / Back: back     L1 / R1: section     X: apply changes"
    } else {
        "D-pad: move     A / OK: select     B / Back: back     L1 / R1: section     Y: refresh"
    };
    ui.painter().text(
        pos2(screen.center().x, screen.bottom() - 18.0),
        Align2::CENTER_CENTER,
        hint,
        font(SMALL),
        DIM,
    );

    if modal_open {
        // Dim + block everything underneath.
        ui.painter()
            .rect_filled(screen, 0.0, Color32::from_black_alpha(170));
        let n = st.modals.len();
        let top = st.modals[n - 1].clone();
        draw_modal(ui, st, &top, screen, scroll, &mut clicks);
    }

    if let Some(b) = &st.banner {
        let g = ui
            .painter()
            .layout(b.text.clone(), font(BODY), Color32::WHITE, 700.0);
        let size = g.size() + vec2(40.0, 24.0);
        let rect = Rect::from_center_size(pos2(screen.center().x, screen.bottom() - 70.0), size);
        ui.painter()
            .rect_filled(rect, r(12.0), if b.error { ERR_BG } else { OK_BG });
        ui.painter()
            .galley(rect.min + vec2(20.0, 12.0), g, Color32::WHITE);
        let left = b.until.saturating_duration_since(std::time::Instant::now());
        ui.ctx()
            .request_repaint_after(left + Duration::from_millis(20));
    }
    clicks
}

fn draw_header(ui: &Ui, st: &AppState, screen: Rect) -> Option<Rect> {
    let h = Rect::from_min_size(screen.min, vec2(screen.width(), 58.0));
    let p = ui.painter();
    p.rect_filled(h, 0.0, HEADER_BG);
    let mut apply_btn: Option<Rect> = None;
    let title = p.text(
        pos2(24.0, h.center().y),
        Align2::LEFT_CENTER,
        "WayTV",
        font(TITLE),
        Color32::WHITE,
    );
    let mut x = title.right() + 24.0;
    if let Some(s) = &st.status {
        let mut parts = vec![];
        if let Some(hn) = &s.hostname {
            parts.push(hn.clone());
        }
        if let Some(ip) = s.ips.first() {
            parts.push(ip.clone());
        }
        if let Some(v) = s.script_version {
            parts.push(format!("Script v{v}"));
        }
        let r1 = p.text(
            pos2(x, h.center().y + 2.0),
            Align2::LEFT_CENTER,
            parts.join("   ·   "),
            font(BODY),
            DIM,
        );
        x = r1.right() + 20.0;
        if s.updates_waiting() {
            let g = p.layout_no_wrap("Updates waiting".into(), font(SMALL), Color32::BLACK);
            let br = Rect::from_min_size(
                pos2(x, h.center().y - g.size().y / 2.0 - 5.0),
                g.size() + vec2(24.0, 10.0),
            );
            p.rect_filled(br, r(12.0), WARN);
            p.galley(br.min + vec2(12.0, 5.0), g, Color32::BLACK);
        }
    }
    let n = st.changes.count();
    let mut apply_btn = None;
    if n > 0 {
        let text = format!("{n} change{} pending", if n == 1 { "" } else { "s" });
        let g = p.layout_no_wrap(text, font(SMALL), Color32::BLACK);
        let br = Rect::from_min_size(
            pos2(x + 150.0, h.center().y - g.size().y / 2.0 - 5.0),
            g.size() + vec2(24.0, 10.0),
        );
        p.rect_filled(br, r(12.0), WARN);
        p.galley(br.min + vec2(12.0, 5.0), g, Color32::BLACK);
        
        // Apply button in top right
        let btn_rect = Rect::from_min_size(
            pos2(screen.right() - 120.0, h.top() + 10.0),
            vec2(110.0, 38.0),
        );
        let (bg, outline) = (FOCUS_BG, FOCUS);
        p.rect_filled(btn_rect, r(8.0), bg);
        p.rect_stroke(btn_rect, r(8.0), Stroke::new(2.0, outline), StrokeKind::Outside);
        p.text(
            btn_rect.center(),
            Align2::CENTER_CENTER,
            "Apply",
            font(BODY),
            Color32::WHITE,
        );
        apply_btn = Some(btn_rect);
    }
    if let Some(pending) = &st.pending {
        p.text(
            pos2(screen.right() - 24.0, h.center().y),
            Align2::RIGHT_CENTER,
            pending,
            font(BODY),
            ACCENT,
        );
    } else if st.status.as_ref().and_then(|s| s.job.as_ref()).is_some() {
        p.text(
            pos2(screen.right() - 24.0, h.center().y),
            Align2::RIGHT_CENTER,
            "Task running…",
            font(BODY),
            ACCENT,
        );
    }
    apply_btn
}

fn info_lines(st: &AppState, sec: Section) -> Vec<(String, String)> {
    let Some(s) = &st.status else { return vec![] };
    let opt = |v: &Option<String>| v.clone().unwrap_or_else(|| "Unknown".into());
    match sec {
        Section::Updates => {
            let u = &s.updates;
            let mut v = vec![
                (
                    "Status".into(),
                    u.status_line
                        .clone()
                        .unwrap_or_else(|| "Not checked yet".into()),
                ),
                (
                    "WayTV script".into(),
                    format!(
                        "installed v{}, latest {}",
                        s.script_version
                            .map(|v| v.to_string())
                            .unwrap_or("?".into()),
                        u.script_latest
                            .map(|v| format!("v{v}"))
                            .unwrap_or("unknown".into())
                    ),
                ),
                (
                    "WayTV app".into(),
                    {
                        let cur = s.app_version.map(|v| v.to_string()).unwrap_or_else(|| "?".into());
                        let latest = s.app_update.as_ref()
                            .and_then(|u| u.get("tag"))
                            .and_then(|t| t.as_str())
                            .unwrap_or("?");
                        if latest == "?" {
                            format!("installed v{}", cur)
                        } else {
                            format!("installed v{}, latest {}", cur, latest)
                        }
                    }
                ),
                (
                    "Debian updates pending".into(),
                    u.debian_pending
                        .map(|v| v.to_string())
                        .unwrap_or("unknown".into()),
                ),
                (
                    "Reboot needed".into(),
                    match u.reboot_needed {
                        Some(true) => "Yes".into(),
                        Some(false) => "No".into(),
                        None => "unknown".into(),
                    },
                ),
                (
                    "Last checked".into(),
                    u.checked_at
                        .as_deref()
                        .map(short_time)
                        .unwrap_or("never".into()),
                ),
            ];
            v
        }
        Section::System => {
            let mut v = vec![
                (
                    "IP address".into(),
                    if s.ips.is_empty() {
                        "none".into()
                    } else {
                        s.ips.join(", ")
                    },
                ),
                ("SSH".into(), opt(&s.ssh)),
                ("User".into(), opt(&s.user)),
                ("Hostname".into(), opt(&s.hostname)),
                (
                    "Uptime".into(),
                    s.uptime_s.map(human_duration).unwrap_or("unknown".into()),
                ),
            ];
            if let Some(perf) = &s.perf {
                v.push(("Performance".into(), perf.clone()));
            }
            v
        }
        _ => vec![],
    }
}

fn draw_main(ui: &mut Ui, st: &AppState, screen: Rect, interactive: bool, clicks: &mut Vec<Click>) {
    let apply_btn = draw_header(ui, st, screen);
    let top = 82.0;
    // Left column: sections
    for (i, sec) in Section::ALL.iter().enumerate() {
        let rect = Rect::from_min_size(pos2(24.0, top + i as f32 * 64.0), vec2(230.0, 54.0));
        let focused = st.pane == Pane::Sections && st.section == i;
        let selected = st.section == i;
        item(ui, rect, sec.title(), "", focused, selected, true, ACCENT);
        if selected && !focused {
            ui.painter().rect_filled(
                Rect::from_min_size(rect.min + vec2(0.0, 10.0), vec2(5.0, rect.height() - 20.0)),
                r(2.0),
                FOCUS,
            );
        }
        if clicked(ui, rect, ("sec", i), interactive) {
            clicks.push(Click::Section(i));
        }
    }
    // Right column
    let x0 = 290.0;
    let w = screen.right() - 24.0 - x0;
    let sec = st.section_kind();
    let mut y = top;
    ui.painter().text(
        pos2(x0, y),
        Align2::LEFT_TOP,
        sec.title(),
        font(TITLE - 2.0),
        TEXT,
    );
    y += 40.0;
    let info = info_lines(st, sec);
    if !info.is_empty() {
        let label_w = 250.0;
        for (k, v) in &info {
            ui.painter().text(
                pos2(x0 + 4.0, y),
                Align2::LEFT_TOP,
                k,
                font(BODY - 1.0),
                DIM,
            );
            let h = text_block(ui, pos2(x0 + label_w, y), v, BODY - 1.0, TEXT, w - label_w);
            y += h.max(BODY) + 8.0;
        }
        y += 10.0;
    }
    let rows = st.rows();
    // Fit every row above the footer: shrink the spacing when there are many.
    let avail = screen.bottom() - 44.0 - y;
    let pitch = (avail / rows.len().max(1) as f32).clamp(50.0, 70.0);
    let row_h = pitch - 10.0;
    for (i, kind) in rows.into_iter().enumerate() {
        let rect = Rect::from_min_size(pos2(x0, y), vec2(w, row_h));
        let (name, value) = st.row_text(&kind);
        let focused = st.pane == Pane::Rows && st.row == i;
        let color = if st.row_pending(&kind) { WARN } else { ACCENT };
        item(ui, rect, &name, &value, focused, false, true, color);
        if clicked(ui, rect, ("row", sec.title(), i), interactive) {
            clicks.push(Click::Row(i));
        }
        y += pitch;
    }
    // Header Apply button
    if let Some(btn) = apply_btn {
        if clicked(ui, btn, "apply_btn", interactive) {
            clicks.push(Click::ApplyBtn);
        }
    }
}

fn draw_conn(ui: &mut Ui, st: &AppState, screen: Rect, interactive: bool, clicks: &mut Vec<Click>) {
    let c = screen.center();
    let (title, body, retry) = match &st.conn {
        Conn::NotPaired => (
            "Not paired yet".to_string(),
            "On the box run:  sudo waytv-agent pair".to_string(),
            true,
        ),
        Conn::Unreachable(e) => (
            "Can't reach the WayTV service on the box".to_string(),
            e.clone(),
            true,
        ),
        _ => ("Connecting to the box…".to_string(), String::new(), false),
    };
    ui.painter().text(
        c - vec2(0.0, 90.0),
        Align2::CENTER_CENTER,
        title,
        font(TITLE),
        TEXT,
    );
    if !body.is_empty() {
        let g = ui.painter().layout(body, font(BODY), DIM, 760.0);
        let pos = c - vec2(g.size().x / 2.0, 50.0);
        ui.painter().galley(pos, g, DIM);
    }
    if retry {
        let rect = Rect::from_center_size(c + vec2(0.0, 40.0), vec2(220.0, 58.0));
        button(ui, rect, "Retry", true);
        if clicked(ui, rect, "retry", interactive) {
            clicks.push(Click::Retry);
        }
    } else {
        spinner(ui, c + vec2(0.0, 30.0), 22.0);
    }
}

fn draw_modal(
    ui: &mut Ui,
    st: &AppState,
    m: &Modal,
    screen: Rect,
    scroll: bool,
    clicks: &mut Vec<Click>,
) {
    let p = ui.painter().clone();
    match m {
        Modal::Confirm {
            title,
            body,
            ok_label,
            focus,
            ..
        } => {
            let w = 640.0;
            let tg = p.layout(title.clone(), font(TITLE - 2.0), Color32::WHITE, w - 60.0);
            let bg = p.layout(body.clone(), font(BODY), TEXT, w - 60.0);
            let h = 30.0 + tg.size().y + 16.0 + bg.size().y + 34.0 + 58.0 + 30.0;
            let rect = Rect::from_center_size(screen.center(), vec2(w, h));
            p.rect_filled(rect, r(16.0), HEADER_BG);
            p.rect_stroke(rect, r(16.0), Stroke::new(1.0, DIM), StrokeKind::Inside);
            let mut y = rect.top() + 30.0;
            let th = tg.size().y;
            p.galley(pos2(rect.left() + 30.0, y), tg, Color32::WHITE);
            y += th + 16.0;
            let bh = bg.size().y;
            p.galley(pos2(rect.left() + 30.0, y), bg, TEXT);
            y += bh + 34.0;
            let bw = 230.0;
            let cancel = Rect::from_min_size(pos2(rect.center().x - bw - 15.0, y), vec2(bw, 58.0));
            let ok = Rect::from_min_size(pos2(rect.center().x + 15.0, y), vec2(bw, 58.0));
            button(ui, cancel, "Cancel", *focus == 0);
            button(ui, ok, ok_label, *focus == 1);
            if clicked(ui, cancel, "m_cancel", true) {
                clicks.push(Click::ModalItem(0));
            }
            if clicked(ui, ok, "m_ok", true) {
                clicks.push(Click::ModalItem(1));
            }
        }
        Modal::Info { title, body } => {
            let w = 700.0;
            let tg = p.layout(title.clone(), font(TITLE - 2.0), Color32::WHITE, w - 60.0);
            let bg = p.layout(body.clone(), font(BODY), TEXT, w - 60.0);
            let h = 30.0 + tg.size().y + 16.0 + bg.size().y + 34.0 + 58.0 + 30.0;
            let rect = Rect::from_center_size(screen.center(), vec2(w, h));
            p.rect_filled(rect, r(16.0), HEADER_BG);
            p.rect_stroke(rect, r(16.0), Stroke::new(1.0, DIM), StrokeKind::Inside);
            let mut y = rect.top() + 30.0;
            let th = tg.size().y;
            p.galley(pos2(rect.left() + 30.0, y), tg, Color32::WHITE);
            y += th + 16.0;
            let bh = bg.size().y;
            p.galley(pos2(rect.left() + 30.0, y), bg, TEXT);
            y += bh + 34.0;
            let ok = Rect::from_min_size(pos2(rect.center().x - 115.0, y), vec2(230.0, 58.0));
            button(ui, ok, "OK", true);
            if clicked(ui, ok, "m_info_ok", true) {
                clicks.push(Click::ModalItem(0));
            }
        }
        Modal::List {
            title,
            items,
            focus,
            ..
        } => {
            let w = 660.0;
            let row_h = 52.0;
            let list_h = (items.len() as f32 * (row_h + 8.0)).min(screen.height() - 230.0);
            let h = 30.0 + 36.0 + 20.0 + list_h + 26.0;
            let rect = Rect::from_center_size(screen.center() - vec2(0.0, 10.0), vec2(w, h));
            p.rect_filled(rect, r(16.0), HEADER_BG);
            p.rect_stroke(rect, r(16.0), Stroke::new(1.0, DIM), StrokeKind::Inside);
            p.text(
                rect.left_top() + vec2(30.0, 30.0),
                Align2::LEFT_TOP,
                title,
                font(TITLE - 2.0),
                Color32::WHITE,
            );
            let list_rect =
                Rect::from_min_size(rect.left_top() + vec2(20.0, 86.0), vec2(w - 40.0, list_h));
            let mut child = ui.new_child(
                egui::UiBuilder::new()
                    .max_rect(list_rect)
                    .layout(egui::Layout::top_down(Align::Min)),
            );
            child.set_clip_rect(list_rect);
            egui::ScrollArea::vertical()
                .id_salt(("list", title))
                .auto_shrink(false)
                .max_height(list_h)
                .show(&mut child, |ui| {
                    ui.add_space(5.0);
                    for (i, it) in items.iter().enumerate() {
                        let (rr, resp) = ui.allocate_exact_size(
                            vec2(list_rect.width() - 22.0, row_h),
                            Sense::click(),
                        );
                        let rr = rr.translate(vec2(6.0, 0.0));
                        let value = if !it.enabled {
                            "not available"
                        } else if it.current {
                            "current"
                        } else {
                            ""
                        };
                        item(
                            ui,
                            rr,
                            &it.label,
                            value,
                            *focus == i,
                            it.current,
                            it.enabled,
                            ACCENT,
                        );
                        if i == *focus && scroll {
                            ui.scroll_to_rect(rr.expand(8.0), Some(Align::Center));
                        }
                        if resp.clicked() {
                            clicks.push(Click::ModalItem(i));
                        }
                        ui.add_space(8.0);
                    }
                });
        }
        Modal::Job { job } => {
            let rect = screen.shrink2(vec2(40.0, 34.0));
            p.rect_filled(rect, r(16.0), HEADER_BG);
            p.rect_stroke(rect, r(16.0), Stroke::new(1.0, DIM), StrokeKind::Inside);
            p.text(
                rect.left_top() + vec2(30.0, 24.0),
                Align2::LEFT_TOP,
                job.title(),
                font(TITLE),
                Color32::WHITE,
            );
            let sy = rect.top() + 84.0;
            let (state_text, color) = if job.is_running() {
                spinner(ui, pos2(rect.left() + 46.0, sy + 10.0), 13.0);
                ("Running…".to_string(), ACCENT)
            } else if job.failed() {
                (
                    match job.exit_code {
                        Some(c) => format!("Failed (exit code {c})"),
                        None => "Failed".into(),
                    },
                    WARN,
                )
            } else {
                ("Finished".to_string(), Color32::from_rgb(0x7c, 0xe0, 0x8a))
            };
            let sx = if job.is_running() {
                rect.left() + 72.0
            } else {
                rect.left() + 30.0
            };
            p.text(
                pos2(sx, sy + 10.0),
                Align2::LEFT_CENTER,
                state_text,
                font(BODY),
                color,
            );
            let close = Rect::from_min_size(
                pos2(rect.right() - 230.0, rect.top() + 22.0),
                vec2(200.0, 52.0),
            );
            button(
                ui,
                close,
                if job.is_running() { "Hide" } else { "Close" },
                true,
            );
            if clicked(ui, close, "job_close", true) {
                clicks.push(Click::Back);
            }
            let log_rect = Rect::from_min_max(
                pos2(rect.left() + 24.0, sy + 34.0),
                rect.max - vec2(24.0, 24.0),
            );
            p.rect_filled(log_rect, r(8.0), Color32::from_rgb(0x08, 0x0b, 0x10));
            let inner = log_rect.shrink(12.0);
            let mut child = ui.new_child(
                egui::UiBuilder::new()
                    .max_rect(inner)
                    .layout(egui::Layout::top_down(Align::Min)),
            );
            child.set_clip_rect(inner);
            let log = job.log.clone().unwrap_or_default();
            let log = if log.trim().is_empty() {
                "(no output yet)".to_string()
            } else {
                log
            };
            egui::ScrollArea::vertical()
                .id_salt(("joblog", job.id.clone()))
                .auto_shrink(false)
                .stick_to_bottom(true)
                .max_height(inner.height())
                .show(&mut child, |ui| {
                    let g = ui.painter().layout(
                        log.trim_end().to_string(),
                        FontId::monospace(MONO),
                        Color32::from_rgb(0xc8, 0xd2, 0xdc),
                        inner.width() - 16.0,
                    );
                    let (rr, _) = ui.allocate_exact_size(
                        Vec2::new(inner.width() - 16.0, g.size().y),
                        Sense::hover(),
                    );
                    ui.painter().galley(rr.min, g, TEXT);
                });
        }
    }
    let _ = st;
}
