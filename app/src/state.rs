//! The app's state machine: own focus model (section / row / dialog button),
//! screens, and reactions to agent answers. Pure logic, no UI or IO, so it can
//! be unit tested on the host. The UI layer only renders this state and feeds
//! `Nav` commands / clicks back; IO happens in the runtime through `Effect`s.

use crate::api::{ApiError, ApiReq, Changes, DensityValue};
use crate::keys::Nav;
use crate::model::{ActionReply, Job, JobEnvelope, Status, TimezoneList, parse_iso8601};
use std::time::{Duration, Instant};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Section {
    Display,
    Android,
    Updates,
    System,
    Apps,
}

impl Section {
    pub const ALL: [Section; 5] = [
        Section::Display,
        Section::Android,
        Section::Updates,
        Section::System,
        Section::Apps,
    ];
    pub fn title(self) -> &'static str {
        match self {
            Section::Display => "Display",
            Section::Android => "Android",
            Section::Updates => "Updates",
            Section::System => "System",
            Section::Apps => "Apps",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RowKind {
    Resolution,
    Scaling,
    Overlay,
    Hdr,
    Navbar,
    TimeZone,
    RestartAndroid,
    CheckUpdates,
    UpdateAll,
    ShowJob,
    Reboot,
    /// Apps to install (from /data/apps/*)
    InstallApp(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Pane {
    Sections,
    Rows,
}

#[derive(Debug, Clone, PartialEq)]
pub enum ListKind {
    Resolution,
    /// Second step of the resolution picker: refresh rates for (width, height).
    Refresh(i64, i64),
    Scaling,
    TzRegion,
    TzCity(String),
}

#[derive(Debug, Clone, PartialEq)]
pub enum ListValue {
    /// First step: a resolution; opens its refresh-rate list.
    Resolution(i64, i64),
    /// Final choice: (width, height, refresh or None = automatic).
    Display(i64, i64, Option<f64>),
    Density(DensityValue),
    Region(String),
    Tz(String),
}

#[derive(Debug, Clone, PartialEq)]
pub struct ListItem {
    pub label: String,
    pub current: bool,
    pub enabled: bool,
    pub value: ListValue,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Modal {
    /// focus 0 = Cancel (the safe default), 1 = OK.
    Confirm {
        title: String,
        body: String,
        ok_label: String,
        action: ApiReq,
        focus: usize,
    },
    List {
        kind: ListKind,
        title: String,
        items: Vec<ListItem>,
        focus: usize,
    },
    Job {
        job: Job,
    },
    /// Read-only message with one OK button.
    Info {
        title: String,
        body: String,
    },
}

#[derive(Debug, Clone, PartialEq)]
pub enum Conn {
    Loading,
    Ok,
    NotPaired,
    Unreachable(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Blocking {
    Restarting,
    Rebooting,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Banner {
    pub text: String,
    pub error: bool,
    pub until: Instant,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Effect {
    Request(ApiReq),
    /// Re-read agent.json; the runtime answers with `on_pairing`.
    ReloadPairing,
    /// Persist the id of a finished job whose result was shown.
    MarkJobSeen(String),
    /// finish() the activity.
    Exit,
}

/// Mouse / touch activations coming from the UI.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Click {
    Section(usize),
    Row(usize),
    /// Item i of the top dialog (list entry, or confirm button 0=Cancel/1=OK).
    ModalItem(usize),
    ApplyBtn,
    Back,
    Retry,
}

pub const SCALING_CHOICES: [i64; 6] = [160, 240, 320, 360, 480, 560];
const BANNER_TIME: Duration = Duration::from_secs(5);

pub struct AppState {
    pub section: usize,
    pub row: usize,
    pub pane: Pane,
    pub modals: Vec<Modal>,
    pub status: Option<Status>,
    pub conn: Conn,
    pub banner: Option<Banner>,
    pub blocking: Option<Blocking>,
    pub timezones: Vec<String>,
    /// Text shown while an action request is in flight.
    pub pending: Option<String>,
    pub last_job_seen: Option<String>,
    /// Consecutive failed status polls.
    pub failures: u32,
    /// Set when focus moved; the UI scrolls the focused item into view and clears it.
    pub scroll_to_focus: bool,
    /// Staged changes, sent together with Apply.
    pub changes: Changes,
}

impl Default for AppState {
    fn default() -> Self {
        Self::new(None)
    }
}

impl AppState {
    pub fn new(last_job_seen: Option<String>) -> Self {
        AppState {
            section: 0,
            row: 0,
            pane: Pane::Sections,
            modals: Vec::new(),
            status: None,
            conn: Conn::Loading,
            banner: None,
            blocking: None,
            timezones: Vec::new(),
            pending: None,
            last_job_seen,
            failures: 0,
            scroll_to_focus: false,
            changes: Changes::default(),
        }
    }

    /// Effects to run when the app starts (after pairing was loaded).
    pub fn start(&mut self, paired: bool) -> Vec<Effect> {
        if !paired {
            self.conn = Conn::NotPaired;
            return vec![];
        }
        self.conn = Conn::Loading;
        vec![
            Effect::Request(ApiReq::Status),
            Effect::Request(ApiReq::JobsLast),
        ]
    }

    /// The runtime re-read agent.json (on resume, retry or after a 401).
    pub fn on_pairing(&mut self, paired: bool, changed: bool) -> Vec<Effect> {
        if !paired {
            self.conn = Conn::NotPaired;
            return vec![];
        }
        if changed || self.conn == Conn::NotPaired {
            if self.status.is_none() || self.conn == Conn::NotPaired {
                self.conn = Conn::Loading;
            }
            return vec![Effect::Request(ApiReq::Status)];
        }
        vec![]
    }

    pub fn section_kind(&self) -> Section {
        Section::ALL[self.section.min(Section::ALL.len() - 1)]
    }

    pub fn rows_for(&self, s: Section) -> Vec<RowKind> {
        self.base_rows(s)
    }

    fn base_rows(&self, s: Section) -> Vec<RowKind> {
        match s {
            Section::Display => vec![
                RowKind::Resolution,
                RowKind::Scaling,
                RowKind::Overlay,
                RowKind::Hdr,
            ],
            Section::Android => vec![RowKind::Navbar, RowKind::TimeZone, RowKind::RestartAndroid],
            Section::Updates => {
                let mut v = vec![RowKind::CheckUpdates, RowKind::UpdateAll];
                if self.status.as_ref().and_then(|s| s.job.as_ref()).is_some() {
                    v.insert(0, RowKind::ShowJob);
                }
                v
            }
            Section::System => vec![RowKind::Reboot],
            Section::Apps => {
                self.status
                    .as_ref()
                    .map(|st| {
                        st.apps
                            .iter()
                            .map(|a| RowKind::InstallApp(a.package.clone()))
                            .collect()
                    })
                    .unwrap_or_default()
            }
        }
    }

    pub fn rows(&self) -> Vec<RowKind> {
        self.rows_for(self.section_kind())
    }

    /// The main screens (section list + rows) are usable.
    pub fn main_visible(&self) -> bool {
        self.blocking.is_none() && self.status.is_some() && self.conn == Conn::Ok
    }

    /// Name and current value of a row.
    pub fn row_text(&self, kind: &RowKind) -> (String, String) {
        let st = self.status.clone().unwrap_or_default();
        let onoff = |v: Option<&str>, on: &str, a: &str, b: &str| match v {
            Some(x) if x == on => a.to_string(),
            Some(_) => b.to_string(),
            None => "Unknown".to_string(),
        };
        let arrow = |cur: String, new: Option<String>| match new {
            Some(n) => format!("{cur}  →  {n}"),
            None => cur,
        };
        let c = &self.changes;
        match kind {
            RowKind::Resolution => (
                "Resolution".into(),
                arrow(
                    current_resolution(&st),
                    c.display.map(|(w, h, r)| display_label(w, h, r)),
                ),
            ),
            RowKind::Scaling => (
                "Scaling".into(),
                arrow(scaling_value(&st), c.density.as_ref().map(|d| density_label(&st, d))),
            ),
            RowKind::Overlay => (
                "Performance overlay".into(),
                arrow(
                    onoff(st.overlay.as_deref(), "on", "On", "Off"),
                    c.overlay.map(|on| if on { "On" } else { "Off" }.to_string()),
                ),
            ),
            RowKind::Hdr => ("HDR".into(), hdr_value(&st)),
            RowKind::Navbar => (
                "Bottom bar".into(),
                arrow(
                    onoff(st.navbar.as_deref(), "hidden", "Hidden", "Shown"),
                    c.navbar_hidden.map(|h| if h { "Hidden" } else { "Shown" }.to_string()),
                ),
            ),
            RowKind::TimeZone => (
                "Time zone".into(),
                arrow(
                    st.timezone
                        .android
                        .clone()
                        .or(st.timezone.box_.clone())
                        .unwrap_or_else(|| "Unknown".into()),
                    c.timezone.clone(),
                ),
            ),
            RowKind::RestartAndroid => ("Restart Android".into(), String::new()),
            RowKind::CheckUpdates => ("Check for updates".into(), String::new()),
            RowKind::UpdateAll => (
                "Update everything now".into(),
                if st.updates_waiting() {
                    "Updates waiting".into()
                } else {
                    String::new()
                },
            ),
            RowKind::ShowJob => (
                "Show running task".into(),
                st.job.as_ref().map(|j| j.title()).unwrap_or_default(),
            ),
            RowKind::Reboot => ("Reboot box".into(), String::new()),
            RowKind::InstallApp(pkg) => {
                let app = st
                    .apps
                    .iter()
                    .find(|a| a.package == *pkg)
                    .cloned()
                    .unwrap_or_default();
                let status = if app.installed {
                    if app.installing {
                        "Installing…".into()
                    } else {
                        "Installed".into()
                    }
                } else {
                    format!(
                        "v{}",
                        app.version.as_deref().unwrap_or("?")
                    )
                };
                (app.name, status)
            }
        }
    }

    /// The row shows a staged (not yet applied) value.
    pub fn row_pending(&self, kind: &RowKind) -> bool {
        let c = &self.changes;
        match kind {
            RowKind::Resolution => c.display.is_some(),
            RowKind::Scaling => c.density.is_some(),
            RowKind::Overlay => c.overlay.is_some(),
            RowKind::Navbar => c.navbar_hidden.is_some(),
            RowKind::TimeZone => c.timezone.is_some(),
            _ => false,
        }
    }

    /// Drop staged values that equal the current ones (after a status refresh or a toggle).
    pub fn prune_changes(&mut self) {
        let Some(st) = self.status.clone() else { return };
        let c = &mut self.changes;
        if let Some((w, h, r)) = c.display
            && st.display.width == Some(w)
            && st.display.height == Some(h)
            && same_rate(r, st.display.refresh_setting)
        {
            c.display = None;
        }
        if let Some(d) = &c.density {
            let same = match d {
                DensityValue::Dpi(n) => st.density.current == Some(*n),
                DensityValue::Reset => st.density.current.is_none(),
                DensityValue::Auto => {
                    st.density.current.is_some() && st.density.current == st.density.suggested
                }
            };
            if same {
                c.density = None;
            }
        }
        if let Some(hidden) = c.navbar_hidden
            && st.navbar.is_some()
            && hidden == (st.navbar.as_deref() == Some("hidden"))
        {
            c.navbar_hidden = None;
        }
        if let Some(on) = c.overlay
            && st.overlay.is_some()
            && on == (st.overlay.as_deref() == Some("on"))
        {
            c.overlay = None;
        }
        let cur_tz = st.timezone.android.clone().or(st.timezone.box_.clone());
        if c.timezone.is_some() && c.timezone == cur_tz {
            c.timezone = None;
        }
        let n = self.rows().len();
        if n == 0 {
            self.pane = Pane::Sections;
        } else if self.row >= n {
            self.row = n - 1;
        }
    }

    fn open_apply(&mut self) -> Vec<Effect> {
        if self.changes.is_empty() {
            self.set_banner("No changes to apply", false);
            return vec![];
        }
        let st = self.status.clone().unwrap_or_default();
        let mut lines: Vec<String> = Vec::new();
        for kind in [
            RowKind::Resolution,
            RowKind::Scaling,
            RowKind::Overlay,
            RowKind::Navbar,
            RowKind::TimeZone,
        ] {
            if self.row_pending(&kind) {
                let (name, value) = self.row_text(&kind);
                lines.push(format!("• {name}: {value}"));
            }
        }
        let _ = st;
        lines.push(String::new());
        lines.push(if self.changes.needs_restart() {
            "Android restarts once to apply them, about a minute.".into()
        } else {
            "No restart needed.".into()
        });
        let n = self.changes.count();
        self.confirm(
            &format!("Apply {n} change{}?", if n == 1 { "" } else { "s" }),
            &lines.join("\n"),
            "Apply",
            ApiReq::Apply(self.changes.clone()),
        )
    }

    fn set_banner(&mut self, text: impl Into<String>, error: bool) {
        self.banner = Some(Banner {
            text: text.into(),
            error,
            until: Instant::now() + BANNER_TIME,
        });
    }

    /// Drop an expired banner. Returns true if something changed.
    pub fn tick(&mut self, now: Instant) -> bool {
        if self.banner.as_ref().is_some_and(|b| now >= b.until) {
            self.banner = None;
            return true;
        }
        false
    }

    /// Id of a running job whose progress view is open (poll it every second).
    pub fn job_to_poll(&self) -> Option<String> {
        self.modals.iter().find_map(|m| match m {
            Modal::Job { job } if job.is_running() => job.id.clone(),
            _ => None,
        })
    }

    pub fn polling_allowed(&self) -> bool {
        self.blocking.is_none()
    }

    // ---------------------------------------------------------------- input

    pub fn nav(&mut self, n: Nav) -> Vec<Effect> {
        self.scroll_to_focus = true;
        if self.blocking.is_some() {
            return if n == Nav::Back {
                vec![Effect::Exit]
            } else {
                vec![]
            };
        }
        if !self.modals.is_empty() {
            return self.nav_modal(n);
        }
        if !self.main_visible() {
            return match n {
                Nav::Select | Nav::Refresh => self.retry(),
                Nav::Back => vec![Effect::Exit],
                _ => vec![],
            };
        }
        let nrows = self.rows().len();
        match (n, self.pane) {
            (Nav::PrevSection, _) => {
                self.section = (self.section + Section::ALL.len() - 1) % Section::ALL.len();
                self.row = 0;
            }
            (Nav::NextSection, _) => {
                self.section = (self.section + 1) % Section::ALL.len();
                self.row = 0;
            }
            (Nav::Refresh, _) => return vec![Effect::Request(ApiReq::Status)],
            (Nav::Apply, _) => return self.open_apply(),
            (Nav::Up, Pane::Sections) => {
                if self.section > 0 {
                    self.section -= 1;
                    self.row = 0;
                }
            }
            (Nav::Down, Pane::Sections) => {
                if self.section + 1 < Section::ALL.len() {
                    self.section += 1;
                    self.row = 0;
                }
            }
            (Nav::Right | Nav::Select, Pane::Sections) => {
                if nrows > 0 {
                    self.pane = Pane::Rows;
                    self.row = self.row.min(nrows - 1);
                }
            }
            (Nav::Back, Pane::Sections) => return vec![Effect::Exit],
            (Nav::Left, Pane::Sections) => {}
            (Nav::Up, Pane::Rows) => self.row = self.row.saturating_sub(1),
            (Nav::Down, Pane::Rows) => {
                if self.row + 1 < nrows {
                    self.row += 1;
                }
            }
            (Nav::Left | Nav::Back, Pane::Rows) => self.pane = Pane::Sections,
            (Nav::Right, Pane::Rows) => {}
            (Nav::Select, Pane::Rows) => {
                if let Some(k) = self.rows().get(self.row) {
                    return self.activate(k);
                }
            }
        }
        vec![]
    }

    pub fn retry(&mut self) -> Vec<Effect> {
        self.conn = Conn::Loading;
        self.failures = 0;
        vec![Effect::ReloadPairing, Effect::Request(ApiReq::Status)]
    }

    pub fn click(&mut self, c: Click) -> Vec<Effect> {
        match c {
            Click::Section(i) if self.modals.is_empty() && self.main_visible() => {
                if i < Section::ALL.len() {
                    if self.section != i {
                        self.row = 0;
                    }
                    self.section = i;
                    self.pane = Pane::Sections;
                }
                vec![]
            }
            Click::Row(i) if self.modals.is_empty() && self.main_visible() => {
                if i < self.rows().len() {
                    self.pane = Pane::Rows;
                    self.row = i;
                    return self.nav(Nav::Select);
                }
                vec![]
            }
            Click::ModalItem(i) => {
                match self.modals.last_mut() {
                    Some(Modal::Confirm { focus, .. }) if i < 2 => *focus = i,
                    Some(Modal::List { items, focus, .. }) if i < items.len() => *focus = i,
                    Some(Modal::Job { .. }) | Some(Modal::Info { .. }) => {}
                    _ => return vec![],
                }
                self.nav(Nav::Select)
            }
            Click::ApplyBtn if self.modals.is_empty() && self.main_visible() => self.open_apply(),
            Click::Back => self.nav(Nav::Back),
            Click::Retry => self.retry(),
            _ => vec![],
        }
    }

    fn nav_modal(&mut self, n: Nav) -> Vec<Effect> {
        let Some(top) = self.modals.last_mut() else {
            return vec![];
        };
        match top {
            Modal::Confirm { focus, action, .. } => match n {
                Nav::Left | Nav::Up => *focus = 0,
                Nav::Right | Nav::Down => *focus = 1,
                Nav::Back => {
                    self.modals.pop();
                }
                Nav::Select => {
                    if *focus == 0 {
                        self.modals.pop();
                    } else {
                        let a = action.clone();
                        self.modals.clear();
                        return self.send_action(a);
                    }
                }
                _ => {}
            },
            Modal::List {
                items, focus, kind, ..
            } => {
                let len = items.len();
                match n {
                    Nav::Up => *focus = focus.saturating_sub(1),
                    Nav::Down => *focus = (*focus + 1).min(len.saturating_sub(1)),
                    Nav::PrevSection => *focus = focus.saturating_sub(10),
                    Nav::NextSection => *focus = (*focus + 10).min(len.saturating_sub(1)),
                    Nav::Back | Nav::Left => {
                        self.modals.pop();
                    }
                    Nav::Right if *kind != ListKind::TzRegion => {}
                    Nav::Select | Nav::Right => {
                        if let Some(item) = items.get(*focus).cloned() {
                            return self.choose(item);
                        }
                    }
                    Nav::Refresh | Nav::Apply => {}
                }
            }
            Modal::Job { .. } => {
                if matches!(n, Nav::Back | Nav::Select) {
                    self.modals.pop();
                    return vec![Effect::Request(ApiReq::Status)];
                }
            }
            Modal::Info { .. } => {
                if matches!(n, Nav::Back | Nav::Select) {
                    self.modals.pop();
                }
            }
        }
        vec![]
    }

    fn choose(&mut self, item: ListItem) -> Vec<Effect> {
        if !item.enabled {
            self.set_banner("Not available on this TV", true);
            return vec![];
        }
        match item.value {
            ListValue::Resolution(w, h) => {
                self.open_refresh_list(w, h);
                vec![]
            }
            ListValue::Display(w, h, r) => {
                self.modals.clear();
                self.changes.display = Some((w, h, r));
                self.staged()
            }
            ListValue::Density(v) => {
                self.modals.clear();
                self.changes.density = Some(v);
                self.staged()
            }
            ListValue::Region(r) => {
                let current = self.current_tz();
                let prefix = format!("{r}/");
                let items: Vec<ListItem> = self
                    .timezones
                    .iter()
                    .filter(|t| t.starts_with(&prefix))
                    .map(|t| ListItem {
                        label: t[prefix.len()..].replace('_', " "),
                        current: Some(t.as_str()) == current.as_deref(),
                        enabled: true,
                        value: ListValue::Tz(t.clone()),
                    })
                    .collect();
                let focus = items.iter().position(|i| i.current).unwrap_or(0);
                self.modals.push(Modal::List {
                    kind: ListKind::TzCity(r.clone()),
                    title: format!("Time zone: {}", r.replace('_', " ")),
                    items,
                    focus,
                });
                vec![]
            }
            ListValue::Tz(tz) => {
                self.modals.clear();
                self.changes.timezone = Some(tz);
                self.staged()
            }
        }
    }

    /// After staging a value: drop no-op changes and tell the user how to apply.
    fn staged(&mut self) -> Vec<Effect> {
        self.prune_changes();
        if self.changes.is_empty() {
            self.set_banner("No changes pending", false);
        } else {
            self.set_banner("Change staged: choose Apply (or press X) to use it", false);
        }
        vec![]
    }

    /// Unique resolutions the TV offers (API v2 modes), biggest first, with their rates.
    fn resolutions(&self) -> Vec<(i64, i64, Vec<f64>)> {
        let st = self.status.clone().unwrap_or_default();
        let mut out: Vec<(i64, i64, Vec<f64>)> = Vec::new();
        for m in &st.display.modes {
            let (Some(w), Some(h)) = (m.width, m.height) else { continue };
            let r = m.refresh.unwrap_or(0.0);
            match out.iter_mut().find(|(ow, oh, _)| *ow == w && *oh == h) {
                Some((_, _, rates)) => {
                    if r > 0.0 && !rates.iter().any(|x| (x - r).abs() < 0.01) {
                        rates.push(r)
                    }
                }
                None => out.push((w, h, if r > 0.0 { vec![r] } else { vec![] })),
            }
        }
        out.sort_by(|a, b| (b.0 * b.1).cmp(&(a.0 * a.1)));
        for (_, _, rates) in out.iter_mut() {
            rates.sort_by(|a, b| b.partial_cmp(a).unwrap_or(std::cmp::Ordering::Equal));
        }
        out
    }

    fn open_refresh_list(&mut self, w: i64, h: i64) {
        let st = self.status.clone().unwrap_or_default();
        let is_cur = st.display.width == Some(w) && st.display.height == Some(h);
        let rates = self
            .resolutions()
            .into_iter()
            .find(|(rw, rh, _)| *rw == w && *rh == h)
            .map(|(_, _, r)| r)
            .unwrap_or_default();
        let mut items = vec![ListItem {
            label: "Automatic (fastest up to 60 Hz)".into(),
            current: is_cur && st.display.refresh_setting.is_none(),
            enabled: true,
            value: ListValue::Display(w, h, None),
        }];
        for r in rates {
            items.push(ListItem {
                label: format!("{} Hz", fmt_rate(r)),
                current: is_cur && same_rate(Some(r), st.display.refresh_setting),
                enabled: true,
                value: ListValue::Display(w, h, Some(r)),
            });
        }
        let focus = items.iter().position(|i| i.current).unwrap_or(0);
        self.modals.push(Modal::List {
            kind: ListKind::Refresh(w, h),
            title: format!("{w}x{h}: refresh rate"),
            items,
            focus,
        });
    }

    fn current_tz(&self) -> Option<String> {
        let st = self.status.as_ref()?;
        st.timezone.android.clone().or(st.timezone.box_.clone())
    }

    fn confirm(&mut self, title: &str, body: &str, ok: &str, action: ApiReq) -> Vec<Effect> {
        self.modals.push(Modal::Confirm {
            title: title.into(),
            body: body.into(),
            ok_label: ok.into(),
            action,
            focus: 0,
        });
        vec![]
    }

    fn activate(&mut self, k: &RowKind) -> Vec<Effect> {
        let st = self.status.clone().unwrap_or_default();
        match k {
            RowKind::Resolution => {
                let res = self.resolutions();
                let items: Vec<ListItem> = if !res.is_empty() {
                    res.iter()
                        .map(|(w, h, rates)| ListItem {
                            label: match rates.first() {
                                Some(r) => format!("{w}x{h}   (up to {} Hz)", fmt_rate(*r)),
                                None => format!("{w}x{h}"),
                            },
                            current: st.display.width == Some(*w) && st.display.height == Some(*h),
                            enabled: true,
                            value: ListValue::Resolution(*w, *h),
                        })
                        .collect()
                } else {
                    // API v1 agent: fixed presets, no refresh choice.
                    st.display
                        .presets
                        .iter()
                        .filter(|p| p.width.is_some() && p.height.is_some())
                        .map(|p| ListItem {
                            label: p.label(),
                            current: p.width == st.display.width && p.height == st.display.height,
                            enabled: p.is_available(),
                            value: ListValue::Display(p.width.unwrap_or(0), p.height.unwrap_or(0), None),
                        })
                        .collect()
                };
                if items.is_empty() {
                    self.set_banner("The box did not report any resolutions", true);
                    return vec![];
                }
                let focus = items.iter().position(|i| i.current).unwrap_or(0);
                self.modals.push(Modal::List { kind: ListKind::Resolution, title: "Resolution".into(), items, focus });
                vec![]
            }
            RowKind::Scaling => {
                let items = scaling_items(&st);
                let focus = items.iter().position(|i| i.current).unwrap_or(0);
                self.modals.push(Modal::List { kind: ListKind::Scaling, title: "Scaling".into(), items, focus });
                vec![]
            }
            RowKind::Overlay => {
                let cur_on = st.overlay.as_deref() == Some("on");
                let now = self.changes.overlay.unwrap_or(cur_on);
                self.changes.overlay = Some(!now);
                self.staged()
            }
            RowKind::Navbar => {
                let cur_hidden = st.navbar.as_deref() == Some("hidden");
                let now = self.changes.navbar_hidden.unwrap_or(cur_hidden);
                self.changes.navbar_hidden = Some(!now);
                self.staged()
            }
            RowKind::Hdr => {
                let mut body = String::new();
                match &st.hdr {
                    None => body.push_str("This box's WayTV version does not report HDR yet. Update it from the Updates section."),
                    Some(h) => {
                        if h.tv.is_empty() {
                            body.push_str("The TV does not announce HDR support.\n");
                        } else {
                            body.push_str(&format!("The TV supports: {}.\n", h.tv.join(", ")));
                        }
                        if h.available == Some(true) {
                            body.push_str("\nHDR output is available on this box.");
                        } else {
                            body.push_str("\nHDR is not available on this box yet:");
                            for r in &h.reasons {
                                body.push_str(&format!("\n• {r}"));
                            }
                        }
                    }
                }
                self.modals.push(Modal::Info { title: "HDR".into(), body });
                vec![]
            }
            RowKind::TimeZone => {
                if self.timezones.is_empty() {
                    self.pending = Some("Loading time zones…".into());
                    vec![Effect::Request(ApiReq::Timezones)]
                } else {
                    self.open_regions();
                    vec![]
                }
            }
            RowKind::RestartAndroid => self.confirm(
                "Restart Android?",
                "Apps will close. Android is back in about a minute.",
                "Restart",
                ApiReq::RestartAndroid,
            ),
            RowKind::CheckUpdates => self.send_action(ApiReq::UpdateCheck),
            RowKind::UpdateAll => self.confirm(
                "Update everything now?",
                "Updates the WayTV script, Debian, Android and this app. Android restarts at the end.",
                "Update",
                ApiReq::UpdateRun,
            ),
            RowKind::ShowJob => {
                if let Some(job) = st.job.clone() {
                    self.modals.push(Modal::Job { job });
                }
                vec![]
            }
            RowKind::Reboot => self.confirm(
                "Reboot the box?",
                "The TV turns dark and the box starts again, about two minutes.",
                "Reboot",
                ApiReq::Reboot,
            ),
            RowKind::InstallApp(pkg) => {
                let app = st
                    .apps
                    .iter()
                    .find(|a| a.package == *pkg)
                    .cloned()
                    .unwrap_or_default();
                if app.installed {
                    self.set_banner(format!("{} is already installed", app.name), false);
                    vec![]
                } else {
                    self.confirm(
                        &format!("Install {}?", app.name),
                        &format!("Download and install from {}. About a minute.", app.package),
                        "Install",
                        ApiReq::InstallApp(pkg.clone()),
                    )
                }
            }
        }
    }

    fn open_regions(&mut self) {
        let current = self.current_tz();
        let cur_region = current
            .as_deref()
            .and_then(|t| t.split_once('/'))
            .map(|(r, _)| r.to_string());
        let mut regions: Vec<String> = Vec::new();
        for t in &self.timezones {
            if let Some((r, _)) = t.split_once('/')
                && regions.last().map(|l| l != r).unwrap_or(true)
                && !regions.iter().any(|x| x == r)
            {
                regions.push(r.to_string());
            }
        }
        let items: Vec<ListItem> = regions
            .into_iter()
            .map(|r| ListItem {
                label: r.replace('_', " "),
                current: Some(&r) == cur_region.as_ref(),
                enabled: true,
                value: ListValue::Region(r),
            })
            .collect();
        let focus = items.iter().position(|i| i.current).unwrap_or(0);
        self.modals.push(Modal::List {
            kind: ListKind::TzRegion,
            title: "Time zone: region".into(),
            items,
            focus,
        });
    }

    fn send_action(&mut self, a: ApiReq) -> Vec<Effect> {
        if let Some(p) = &self.pending {
            self.set_banner(format!("Please wait: {p}"), true);
            return vec![];
        }
        self.pending = Some("Working…".into());
        vec![Effect::Request(a)]
    }

    // ------------------------------------------------------------ responses

    pub fn on_response(
        &mut self,
        req: &ApiReq,
        res: Result<serde_json::Value, ApiError>,
        now_unix: i64,
    ) -> Vec<Effect> {
        self.scroll_to_focus = true;
        let is_get = matches!(req, ApiReq::Status | ApiReq::Job(_) | ApiReq::JobsLast);
        if !is_get {
            self.pending = None;
        }
        let v = match res {
            Ok(v) => v,
            Err(e) => return self.on_error(req, e),
        };
        match req {
            ApiReq::Status => {
                let st: Status = serde_json::from_value(v).unwrap_or_default();
                self.status = Some(st);
                self.conn = Conn::Ok;
                self.failures = 0;
                self.prune_changes();
                let n = self.rows().len();
                if n == 0 {
                    self.pane = Pane::Sections;
                } else if self.row >= n {
                    self.row = n - 1;
                }
                vec![]
            }
            ApiReq::Timezones => {
                let l: TimezoneList = serde_json::from_value(v).unwrap_or_default();
                self.timezones = l
                    .timezones
                    .into_iter()
                    .filter(|t| t.contains('/'))
                    .collect();
                self.timezones.sort();
                if self.timezones.is_empty() {
                    self.set_banner("The box did not list any time zones", true);
                } else if self.modals.is_empty() {
                    self.open_regions();
                }
                vec![]
            }
            ApiReq::JobsLast => {
                let env: JobEnvelope = serde_json::from_value(v).unwrap_or_default();
                let Some(job) = env.job else { return vec![] };
                if self.modals.iter().any(|m| matches!(m, Modal::Job { .. })) {
                    return vec![];
                }
                if job.is_running() {
                    self.modals.push(Modal::Job { job });
                    return vec![];
                }
                let recent = job
                    .finished
                    .as_deref()
                    .and_then(parse_iso8601)
                    .map(|t| now_unix - t <= 30 * 60 && now_unix - t >= -5 * 60)
                    .unwrap_or(false);
                match job.id.clone() {
                    Some(id) if recent && self.last_job_seen.as_deref() != Some(id.as_str()) => {
                        self.last_job_seen = Some(id.clone());
                        self.modals.push(Modal::Job { job });
                        vec![Effect::MarkJobSeen(id)]
                    }
                    _ => vec![],
                }
            }
            ApiReq::Job(id) => {
                let env: JobEnvelope = serde_json::from_value(v).unwrap_or_default();
                let Some(new) = env.job else { return vec![] };
                let mut fx = vec![];
                for m in self.modals.iter_mut() {
                    if let Modal::Job { job } = m
                        && job.id.as_deref() == Some(id.as_str())
                    {
                        let was_running = job.is_running();
                        *job = new.clone();
                        if was_running && !new.is_running() {
                            self.last_job_seen = Some(id.clone());
                            fx.push(Effect::MarkJobSeen(id.clone()));
                            fx.push(Effect::Request(ApiReq::Status));
                        }
                    }
                }
                fx
            }
            _ => {
                let r: ActionReply = serde_json::from_value(v).unwrap_or_default();
                if matches!(req, ApiReq::Apply(_)) {
                    self.changes = Changes::default();
                }
                if r.rebooting == Some(true) {
                    self.modals.clear();
                    self.blocking = Some(Blocking::Rebooting);
                    return vec![];
                }
                if r.restarting == Some(true) {
                    self.modals.clear();
                    self.blocking = Some(Blocking::Restarting);
                    return vec![];
                }
                if let Some(job) = r.job {
                    self.modals.retain(|m| !matches!(m, Modal::Job { .. }));
                    self.modals.push(Modal::Job { job });
                    return vec![Effect::Request(ApiReq::Status)];
                }
                let msg = match req {
                    ApiReq::SetDensity(_) => match r.density {
                        Some(d) => format!("Scaling set to {d}"),
                        None => "Scaling set to Android default".into(),
                    },
                    ApiReq::SetTimezone(tz) => {
                        format!("Time zone set to {}", r.tz.unwrap_or(tz.clone()))
                    }
                    ApiReq::SetNavbar { .. } | ApiReq::SetOverlay { .. } => {
                        "Nothing to change".into()
                    }
                    ApiReq::Apply(_) if r.applied.is_empty() => "Nothing to change".into(),
                    ApiReq::Apply(_) => format!("Applied: {}", r.applied.join(", ")),
                    _ => "Done".into(),
                };
                self.set_banner(msg, false);
                vec![Effect::Request(ApiReq::Status)]
            }
        }
    }

    fn on_error(&mut self, req: &ApiReq, e: ApiError) -> Vec<Effect> {
        if self.blocking.is_some() {
            // Android / the box is going down; errors are expected now.
            return vec![];
        }
        match e {
            ApiError::NotPaired => {
                self.conn = Conn::NotPaired;
                vec![]
            }
            ApiError::Unauthorized => {
                self.conn = Conn::NotPaired;
                vec![Effect::ReloadPairing]
            }
            ApiError::Unreachable(msg) => {
                if *req == ApiReq::Status {
                    self.failures += 1;
                    if self.status.is_none() || self.failures >= 3 {
                        self.conn = Conn::Unreachable(msg);
                    }
                } else if !matches!(req, ApiReq::Job(_) | ApiReq::JobsLast) {
                    self.set_banner("Can't reach the WayTV service on the box", true);
                }
                vec![]
            }
            other => {
                if !matches!(req, ApiReq::Job(_) | ApiReq::JobsLast) {
                    self.set_banner(other.message(), true);
                }
                vec![]
            }
        }
    }
}

pub fn fmt_rate(r: f64) -> String {
    if (r - r.round()).abs() < 0.005 {
        format!("{:.0}", r)
    } else {
        format!("{:.2}", r)
    }
}

/// Two refresh settings are the same (None = automatic).
pub fn same_rate(a: Option<f64>, b: Option<f64>) -> bool {
    match (a, b) {
        (None, None) => true,
        (Some(x), Some(y)) => (x - y).abs() < 0.01,
        _ => false,
    }
}

pub fn display_label(w: i64, h: i64, r: Option<f64>) -> String {
    match r {
        Some(r) => format!("{w}x{h} at {} Hz", fmt_rate(r)),
        None => format!("{w}x{h} (auto Hz)"),
    }
}

pub fn density_label(st: &Status, d: &DensityValue) -> String {
    match d {
        DensityValue::Auto => match st.density.suggested {
            Some(s) => format!("Auto ({s})"),
            None => "Auto".into(),
        },
        DensityValue::Reset => "Android default".into(),
        DensityValue::Dpi(n) => n.to_string(),
    }
}

pub fn hdr_value(st: &Status) -> String {
    match &st.hdr {
        None => "Unknown".into(),
        Some(h) => {
            let tv = if h.tv.is_empty() {
                "TV: no HDR".to_string()
            } else {
                format!("TV: {}", h.tv.join(", "))
            };
            if h.available == Some(true) {
                format!("{tv} · available")
            } else {
                format!("{tv} · not available on this box")
            }
        }
    }
}

pub fn current_resolution(st: &Status) -> String {
    let (w, h) = (st.display.width, st.display.height);
    if !st.display.modes.is_empty()
        && let (Some(w), Some(h), Some(r)) = (w, h, st.display.refresh)
    {
        return format!("{w}x{h} at {} Hz", fmt_rate(r));
    }
    if let Some(p) = st
        .display
        .presets
        .iter()
        .find(|p| w.is_some() && p.width == w && p.height == h)
    {
        return p.label();
    }
    match (w, h, st.display.refresh) {
        (Some(w), Some(h), Some(r)) => format!("{w}x{h} at {r:.0} Hz"),
        (Some(w), Some(h), None) => format!("{w}x{h}"),
        _ => "Unknown".into(),
    }
}

pub fn scaling_value(st: &Status) -> String {
    match st.density.current {
        None => match st.density.default_ {
            Some(d) => format!("Android default ({d})"),
            None => "Android default".into(),
        },
        Some(c) if Some(c) == st.density.suggested => format!("{c} (suggested)"),
        Some(c) => c.to_string(),
    }
}

pub fn scaling_items(st: &Status) -> Vec<ListItem> {
    let cur = st.density.current;
    let mut v = vec![ListItem {
        label: match st.density.suggested {
            Some(s) => format!("Auto (suggested {s})"),
            None => "Auto".into(),
        },
        current: false,
        enabled: true,
        value: ListValue::Density(DensityValue::Auto),
    }];
    for d in SCALING_CHOICES {
        v.push(ListItem {
            label: if Some(d) == st.density.suggested {
                format!("{d} (suggested)")
            } else {
                d.to_string()
            },
            current: cur == Some(d),
            enabled: true,
            value: ListValue::Density(DensityValue::Dpi(d)),
        });
    }
    v.push(ListItem {
        label: match st.density.default_ {
            Some(d) => format!("Android default ({d})"),
            None => "Android default".into(),
        },
        current: cur.is_none(),
        enabled: true,
        value: ListValue::Density(DensityValue::Reset),
    });
    v
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn status_json() -> serde_json::Value {
        json!({
            "ok": true, "script_version": 18, "hostname": "androidtv", "ips": ["192.168.1.157"],
            "display": {"width": 1920, "height": 1080, "refresh": 60.0, "presets": [
                {"id": "1080p", "width": 1920, "height": 1080, "label": "1080p", "available": true},
                {"id": "4k", "width": 3840, "height": 2160, "label": "4K", "available": true},
                {"id": "720p", "width": 1280, "height": 720, "label": "720p", "available": false}]},
            "density": {"current": 240, "suggested": 240, "default": 180},
            "navbar": "hidden", "overlay": "off",
            "timezone": {"android": "America/New_York", "box": "America/New_York"},
            "updates": {}, "perf": null, "job": null
        })
    }

    fn loaded() -> AppState {
        let mut s = AppState::new(None);
        assert_eq!(
            s.start(true),
            vec![
                Effect::Request(ApiReq::Status),
                Effect::Request(ApiReq::JobsLast)
            ]
        );
        s.on_response(&ApiReq::Status, Ok(status_json()), 0);
        assert!(s.main_visible());
        s
    }

    #[test]
    fn section_and_row_navigation() {
        let mut s = loaded();
        assert_eq!((s.section, s.pane), (0, Pane::Sections));
        s.nav(Nav::Up);
        assert_eq!(s.section, 0, "clamped at top");
        s.nav(Nav::Down);
        s.nav(Nav::Down);
        assert_eq!(s.section_kind(), Section::Updates);
        s.nav(Nav::Down);
        assert_eq!(s.section_kind(), Section::System);
        s.nav(Nav::Down);
        assert_eq!(s.section_kind(), Section::Apps, "clamped at bottom");
        s.nav(Nav::NextSection);
        assert_eq!(s.section_kind(), Section::Display, "R1 wraps");
        s.nav(Nav::PrevSection);
        assert_eq!(s.section_kind(), Section::Apps, "L1 wraps");
        s.nav(Nav::PrevSection);
        s.nav(Nav::PrevSection);
        s.nav(Nav::PrevSection);
        assert_eq!(s.section_kind(), Section::Android);
        s.nav(Nav::Right);
        assert_eq!((s.pane, s.row), (Pane::Rows, 0));
        s.nav(Nav::Down);
        s.nav(Nav::Down);
        s.nav(Nav::Down);
        assert_eq!(s.row, 2, "clamped at last row");
        s.nav(Nav::NextSection);
        assert_eq!(
            (s.section_kind(), s.pane, s.row),
            (Section::Updates, Pane::Rows, 0)
        );
        s.nav(Nav::Left);
        assert_eq!(s.pane, Pane::Sections);
    }

    #[test]
    fn back_behaviour() {
        let mut s = loaded();
        s.nav(Nav::Select);
        assert_eq!(s.pane, Pane::Rows);
        assert_eq!(s.nav(Nav::Back), vec![], "back from rows does not exit");
        assert_eq!(s.pane, Pane::Sections);
        assert_eq!(
            s.nav(Nav::Back),
            vec![Effect::Exit],
            "back from section list exits"
        );
    }

    #[test]
    fn confirm_dialog_defaults_to_cancel() {
        let mut s = loaded();
        s.section = 3; // System
        s.nav(Nav::Select);
        assert_eq!(
            s.nav(Nav::Select),
            vec![],
            "opening the dialog sends nothing"
        );
        assert!(matches!(
            s.modals.last(),
            Some(Modal::Confirm {
                focus: 0,
                action: ApiReq::Reboot,
                ..
            })
        ));
        assert_eq!(s.nav(Nav::Select), vec![], "Cancel is focused");
        assert!(s.modals.is_empty());
        // B closes it too, and does not leave the rows pane.
        s.nav(Nav::Select);
        assert_eq!(s.nav(Nav::Back), vec![]);
        assert!(s.modals.is_empty());
        assert_eq!(s.pane, Pane::Rows);
        // Right then A confirms.
        s.nav(Nav::Select);
        s.nav(Nav::Right);
        assert_eq!(s.nav(Nav::Select), vec![Effect::Request(ApiReq::Reboot)]);
        s.on_response(
            &ApiReq::Reboot,
            Ok(json!({"ok": true, "rebooting": true})),
            0,
        );
        assert_eq!(s.blocking, Some(Blocking::Rebooting));
        assert!(!s.main_visible());
        assert_eq!(s.nav(Nav::Down), vec![]);
    }




    #[test]
    fn jobs() {
        let mut s = loaded();
        s.section = 2;
        s.nav(Nav::Select);
        let fx = s.nav(Nav::Select);
        assert_eq!(fx, vec![Effect::Request(ApiReq::UpdateCheck)]);
        let job = json!({"id": "1-check", "title": "Check", "state": "running", "log": "a"});
        s.on_response(&ApiReq::UpdateCheck, Ok(json!({"ok": true, "job": job})), 0);
        assert_eq!(s.job_to_poll().as_deref(), Some("1-check"));
        let fx = s.on_response(
            &ApiReq::Job("1-check".into()),
            Ok(json!({"ok": true, "job": {"id": "1-check", "state": "done", "exit_code": 0, "log": "a\nb"}})),
            0,
        );
        assert!(fx.contains(&Effect::MarkJobSeen("1-check".into())));
        assert_eq!(s.job_to_poll(), None);
        s.nav(Nav::Back);
        assert!(s.modals.is_empty());
        assert_eq!(s.pane, Pane::Rows);
        // A second job while one runs -> 409 banner
        s.nav(Nav::Select);
        s.on_response(
            &ApiReq::UpdateCheck,
            Err(ApiError::Http(
                409,
                "Another task is running: Update".into(),
            )),
            0,
        );
        assert_eq!(
            s.banner.as_ref().unwrap().text,
            "Another task is running: Update"
        );
    }

    #[test]
    fn last_job_shown_once() {
        let now = parse_iso8601("2026-11-07T06:00:00-05:00").unwrap();
        let last = json!({"ok": true, "job": {"id": "9-update", "state": "done",
            "finished": "2026-11-07T05:45:00-05:00", "log": "ok"}});
        let mut s = loaded();
        assert_eq!(
            s.on_response(&ApiReq::JobsLast, Ok(last.clone()), now),
            vec![Effect::MarkJobSeen("9-update".into())]
        );
        assert!(matches!(s.modals.last(), Some(Modal::Job { .. })));
        let mut s = AppState::new(Some("9-update".into()));
        s.on_response(&ApiReq::JobsLast, Ok(last.clone()), now);
        assert!(s.modals.is_empty(), "already seen");
        let mut s = AppState::new(None);
        s.on_response(&ApiReq::JobsLast, Ok(last), now + 3600);
        assert!(s.modals.is_empty(), "too old");
        let mut s = AppState::new(None);
        s.on_response(&ApiReq::JobsLast, Ok(json!({"ok": true, "job": null})), now);
        assert!(s.modals.is_empty());
    }

    #[test]
    fn not_paired_and_unreachable() {
        let mut s = AppState::new(None);
        assert_eq!(s.start(false), vec![]);
        assert_eq!(s.conn, Conn::NotPaired);
        assert_eq!(
            s.nav(Nav::Select),
            vec![Effect::ReloadPairing, Effect::Request(ApiReq::Status)]
        );
        assert_eq!(s.on_pairing(false, false), vec![]);
        assert_eq!(s.conn, Conn::NotPaired);
        assert_eq!(s.nav(Nav::Back), vec![Effect::Exit]);

        let mut s = loaded();
        assert_eq!(
            s.on_response(&ApiReq::Status, Err(ApiError::Unauthorized), 0),
            vec![Effect::ReloadPairing]
        );
        assert_eq!(s.conn, Conn::NotPaired);
        assert_eq!(
            s.on_pairing(true, true),
            vec![Effect::Request(ApiReq::Status)]
        );
        s.on_response(&ApiReq::Status, Ok(status_json()), 0);
        assert_eq!(s.conn, Conn::Ok);

        // One failed poll with data shown -> stay; three -> unreachable screen.
        for _ in 0..2 {
            s.on_response(
                &ApiReq::Status,
                Err(ApiError::Unreachable("refused".into())),
                0,
            );
            assert_eq!(s.conn, Conn::Ok);
        }
        s.on_response(
            &ApiReq::Status,
            Err(ApiError::Unreachable("refused".into())),
            0,
        );
        assert!(matches!(s.conn, Conn::Unreachable(_)));
        assert!(!s.main_visible());
        assert_eq!(
            s.nav(Nav::Select),
            vec![Effect::ReloadPairing, Effect::Request(ApiReq::Status)]
        );

        let mut s = AppState::new(None);
        s.start(true);
        s.on_response(
            &ApiReq::Status,
            Err(ApiError::Unreachable("refused".into())),
            0,
        );
        assert!(
            matches!(s.conn, Conn::Unreachable(_)),
            "first failure without data"
        );
    }


    #[test]
    fn row_texts() {
        let s = loaded();
        assert_eq!(s.row_text(&RowKind::Resolution).1, "1080p");
        assert_eq!(s.row_text(&RowKind::Scaling).1, "240 (suggested)");
        assert_eq!(s.row_text(&RowKind::Navbar).1, "Hidden");
        assert_eq!(s.row_text(&RowKind::Overlay).1, "Off");
        assert_eq!(s.row_text(&RowKind::TimeZone).1, "America/New_York");
        let mut st: Status = serde_json::from_value(status_json()).unwrap();
        st.density.current = None;
        assert_eq!(scaling_value(&st), "Android default (180)");
        assert!(scaling_items(&st).last().unwrap().current);
    }
    fn status_v2() -> serde_json::Value {
        let mut v = status_json();
        v["api"] = json!(2);
        v["display"]["refresh_setting"] = json!(null);
        v["display"]["modes"] = json!([
            {"width": 3840, "height": 2160, "refresh": 30.0, "current": false},
            {"width": 3840, "height": 2160, "refresh": 24.0, "current": false},
            {"width": 1920, "height": 1080, "refresh": 120.0, "current": false},
            {"width": 1920, "height": 1080, "refresh": 60.0, "current": true},
            {"width": 1280, "height": 720, "refresh": 60.0, "current": false}
        ]);
        v["hdr"] = json!({"tv": ["HDR10", "HLG"], "available": false,
                          "reasons": ["Waydroid draws Android in SDR only."]});
        v
    }

    fn loaded_v2() -> AppState {
        let mut s = loaded();
        s.on_response(&ApiReq::Status, Ok(status_v2()), 0);
        s
    }

    #[test]
    fn resolution_two_step_picker_stages_change() {
        let mut s = loaded_v2();
        s.nav(Nav::Select); // Display rows
        assert_eq!(s.rows(), vec![RowKind::Resolution, RowKind::Scaling, RowKind::Overlay, RowKind::Hdr]);
        assert_eq!(s.nav(Nav::Select), vec![]); // resolution list
        let Some(Modal::List { kind: ListKind::Resolution, items, focus, .. }) = s.modals.last() else { panic!() };
        assert_eq!(
            items.iter().map(|i| i.label.as_str()).collect::<Vec<_>>(),
            ["3840x2160   (up to 30 Hz)", "1920x1080   (up to 120 Hz)", "1280x720   (up to 60 Hz)"]
        );
        assert_eq!(*focus, 1, "current 1080p focused");
        // 1080p -> refresh list: Automatic (current), 120, 60
        assert_eq!(s.nav(Nav::Select), vec![]);
        let Some(Modal::List { kind: ListKind::Refresh(1920, 1080), items, focus, .. }) = s.modals.last() else { panic!() };
        assert_eq!(
            items.iter().map(|i| i.label.as_str()).collect::<Vec<_>>(),
            ["Automatic (fastest up to 60 Hz)", "120 Hz", "60 Hz"]
        );
        assert_eq!(*focus, 0);
        s.nav(Nav::Back); // back to resolutions
        assert!(matches!(s.modals.last(), Some(Modal::List { kind: ListKind::Resolution, .. })));
        s.nav(Nav::Up); // 4K
        s.nav(Nav::Select);
        s.nav(Nav::Down); // 30 Hz
        assert_eq!(s.nav(Nav::Select), vec![], "choosing only stages, nothing is sent");
        assert!(s.modals.is_empty());
        assert_eq!(s.changes.display, Some((3840, 2160, Some(30.0))));
        assert!(s.row_pending(&RowKind::Resolution));
        assert_eq!(s.row_text(&RowKind::Resolution).1, "1920x1080 at 60 Hz  →  3840x2160 at 30 Hz");
    }

    #[test]
    fn apply_sends_only_changed_keys_once() {
        let mut s = loaded_v2();
        s.changes.density = Some(DensityValue::Dpi(320));
        s.changes.timezone = Some("Europe/Berlin".into());
        s.prune_changes();
        assert_eq!(s.changes.count(), 2);
        assert!(!s.changes.needs_restart());
        assert_eq!(
            s.changes.to_json(),
            json!({"density": 320, "timezone": "Europe/Berlin"})
        );
        // X opens the confirm dialog with Cancel focused.
        assert_eq!(s.nav(Nav::Apply), vec![]);
        let Some(Modal::Confirm { focus: 0, body, action: ApiReq::Apply(c), .. }) = s.modals.last() else { panic!() };
        assert!(body.contains("Scaling: 240 (suggested)  →  320"), "{body}");
        assert!(body.contains("No restart needed"));
        assert_eq!(c.count(), 2);
        assert_eq!(s.nav(Nav::Select), vec![], "Cancel keeps the changes");
        assert_eq!(s.changes.count(), 2);
        s.nav(Nav::Apply);
        s.nav(Nav::Right);
        let fx = s.nav(Nav::Select);
        let req = ApiReq::Apply(s.changes.clone());
        assert_eq!(fx, vec![Effect::Request(req.clone())]);
        let (m, path, body) = req.method_path_body();
        assert_eq!((m, path.as_str()), ("POST", "/api/apply"));
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&body.unwrap()).unwrap(),
            json!({"density": 320, "timezone": "Europe/Berlin"})
        );
        // 400 keeps the pending changes.
        s.on_response(&req, Err(ApiError::Http(400, "Unknown time zone".into())), 0);
        assert_eq!(s.changes.count(), 2);
        // Success clears them.
        let fx = s.on_response(&req, Ok(json!({"ok": true, "applied": ["timezone", "density"], "restarting": false, "job": null})), 0);
        assert!(s.changes.is_empty());
        assert_eq!(fx, vec![Effect::Request(ApiReq::Status)]);
        assert_eq!(s.banner.as_ref().unwrap().text, "Applied: timezone, density");
    }

    #[test]
    fn restart_changes_and_toggles() {
        let mut s = loaded_v2();
        s.section = 1; // Android
        s.nav(Nav::Select);
        assert_eq!(s.nav(Nav::Select), vec![], "bottom bar toggle only stages");
        assert_eq!(s.changes.navbar_hidden, Some(false));
        s.nav(Nav::Select);
        assert!(s.changes.is_empty(), "toggling back drops the change");
        s.nav(Nav::Select);
        s.changes.display = Some((3840, 2160, None));
        assert!(s.changes.needs_restart());
        s.nav(Nav::Apply);
        let Some(Modal::Confirm { body, .. }) = s.modals.last() else { panic!() };
        assert!(body.contains("Android restarts once"));
        s.nav(Nav::Right);
        let fx = s.nav(Nav::Select);
        let Some(Effect::Request(req)) = fx.first().cloned() else { panic!() };
        assert_eq!(
            req.method_path_body().2.map(|b| serde_json::from_str::<serde_json::Value>(&b).unwrap()),
            Some(json!({"display": {"width": 3840, "height": 2160, "refresh": null}, "navbar": "on"}))
        );
        s.on_response(&req, Ok(json!({"ok": true, "applied": ["display", "navbar"], "restarting": true, "job": {"id": "1-apply", "state": "running"}})), 0);
        assert_eq!(s.blocking, Some(Blocking::Restarting));
        assert!(s.changes.is_empty());
    }

    #[test]
    fn pending_dropped_when_status_catches_up() {
        let mut s = loaded_v2();
        s.changes.density = Some(DensityValue::Dpi(320));
        s.changes.overlay = Some(true);
        let mut v = status_v2();
        v["density"]["current"] = json!(320);
        s.on_response(&ApiReq::Status, Ok(v), 0);
        assert_eq!(s.changes.density, None);
        assert_eq!(s.changes.overlay, Some(true));
        // Manually clear changes (no Discard row in header anymore)
        assert_eq!(s.click(Click::ApplyBtn), vec![]); // opens confirm dialog
        s.nav(Nav::Back); // close without applying
        s.changes = Changes::default();
        s.prune_changes();
        assert!(s.changes.is_empty());
    }

    #[test]
    fn scaling_and_timezone_stage() {
        let mut s = loaded_v2();
        s.nav(Nav::Select);
        s.nav(Nav::Down);
        s.nav(Nav::Select);
        let Some(Modal::List { items, focus, .. }) = s.modals.last() else { panic!() };
        assert_eq!(items[*focus].label, "240 (suggested)");
        s.nav(Nav::Down);
        assert_eq!(s.nav(Nav::Select), vec![]);
        assert_eq!(s.changes.density, Some(DensityValue::Dpi(320)));
        // time zone two-level picker stages too
        s.nav(Nav::NextSection);
        s.nav(Nav::Down);
        assert_eq!(s.nav(Nav::Select), vec![Effect::Request(ApiReq::Timezones)]);
        s.on_response(
            &ApiReq::Timezones,
            Ok(json!({"ok": true, "timezones": ["America/New_York", "Europe/Berlin", "Europe/Paris"]})),
            0,
        );
        s.nav(Nav::Down); // Europe
        s.nav(Nav::Select);
        assert_eq!(s.nav(Nav::Select), vec![]); // Berlin
        assert_eq!(s.changes.timezone.as_deref(), Some("Europe/Berlin"));
        assert_eq!(s.changes.count(), 2);
    }

    #[test]
    fn hdr_row_and_info_dialog() {
        let mut s = loaded_v2();
        assert_eq!(s.row_text(&RowKind::Hdr).1, "TV: HDR10, HLG · not available on this box");
        s.nav(Nav::Select);
        s.row = 3;
        s.nav(Nav::Select);
        let Some(Modal::Info { body, .. }) = s.modals.last() else { panic!() };
        assert!(body.contains("HDR10, HLG") && body.contains("SDR only"));
        s.nav(Nav::Back);
        assert!(s.modals.is_empty());
        // v1 agent: no hdr field
        let s1 = loaded();
        assert_eq!(s1.row_text(&RowKind::Hdr).1, "Unknown");
    }

    #[test]
    fn v1_agent_presets_fallback() {
        let mut s = loaded();
        s.nav(Nav::Select);
        s.nav(Nav::Select);
        let Some(Modal::List { items, .. }) = s.modals.last() else { panic!() };
        assert_eq!(items.len(), 3);
        s.nav(Nav::Down);
        s.nav(Nav::Select);
        assert_eq!(s.changes.display, Some((3840, 2160, None)));
    }

    #[test]
    fn clicks() {
        let mut s = loaded_v2();
        s.click(Click::Section(3));
        assert_eq!((s.section, s.pane), (3, Pane::Sections));
        s.click(Click::Row(0));
        assert!(matches!(s.modals.last(), Some(Modal::Confirm { .. })));
        assert_eq!(s.click(Click::ModalItem(0)), vec![]);
        assert!(s.modals.is_empty());
        s.click(Click::Section(0));
        s.click(Click::Row(1));
        assert_eq!(s.click(Click::ModalItem(7)), vec![]);
        assert_eq!(s.changes.density, Some(DensityValue::Reset));
    }

}
