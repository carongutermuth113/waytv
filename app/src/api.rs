//! Pairing file + a tiny blocking HTTP/1.1 client for the waytv-agent
//! (cleartext, only ever talks to the Waydroid bridge address).

use serde::Deserialize;
use std::io::{Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::path::Path;
use std::time::Duration;

pub const DEFAULT_URL: &str = "http://192.168.240.1:8765";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Pairing {
    pub url: String,
    pub token: String,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct PairingFile {
    url: Option<serde_json::Value>,
    token: Option<serde_json::Value>,
}

impl Pairing {
    /// Parse agent.json. Missing/null/empty token -> None. Missing url -> default.
    pub fn parse(text: &str) -> Option<Pairing> {
        let f: PairingFile = serde_json::from_str(text).ok()?;
        let token = f.token.as_ref()?.as_str()?.trim().to_string();
        if token.is_empty() {
            return None;
        }
        let url = f
            .url
            .as_ref()
            .and_then(|v| v.as_str())
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| DEFAULT_URL.to_string());
        Some(Pairing { url, token })
    }

    pub fn load(path: &Path) -> Option<Pairing> {
        Pairing::parse(&std::fs::read_to_string(path).ok()?)
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum ApiError {
    /// No agent.json (or it has no token).
    NotPaired,
    /// HTTP 401.
    Unauthorized,
    /// Could not connect / timed out / connection broke.
    Unreachable(String),
    /// Any other non-2xx answer; message from {"error": "..."} if present.
    Http(u16, String),
    /// 2xx but the body was not JSON.
    BadResponse(String),
}

impl ApiError {
    pub fn message(&self) -> String {
        match self {
            ApiError::NotPaired => "Not paired yet".into(),
            ApiError::Unauthorized => "The app is not paired with the box (401)".into(),
            ApiError::Unreachable(e) => format!("Can't reach the WayTV service on the box ({e})"),
            ApiError::Http(_, m) => m.clone(),
            ApiError::BadResponse(e) => format!("Unexpected answer from the box: {e}"),
        }
    }
}

pub struct HttpResponse {
    pub code: u16,
    pub body: Vec<u8>,
}

/// Split "http://host:port/prefix" into (host, port, prefix-without-trailing-slash).
pub fn parse_url(url: &str) -> Option<(String, u16, String)> {
    let rest = url.trim().strip_prefix("http://")?;
    let (hostport, path) = match rest.find('/') {
        Some(i) => (&rest[..i], rest[i..].trim_end_matches('/').to_string()),
        None => (rest, String::new()),
    };
    if hostport.is_empty() {
        return None;
    }
    let (host, port) = match hostport.rsplit_once(':') {
        Some((h, p)) => (h.to_string(), p.parse().ok()?),
        _ => (hostport.to_string(), 80),
    };
    Some((host, port, path))
}

/// Perform one HTTP request (Connection: close) and return status + body.
pub fn http_request(
    url: &str,
    method: &str,
    path: &str,
    token: &str,
    body: Option<&str>,
    timeout: Duration,
) -> Result<HttpResponse, ApiError> {
    let (host, port, prefix) =
        parse_url(url).ok_or_else(|| ApiError::Unreachable(format!("bad url {url}")))?;
    let addr = (host.as_str(), port)
        .to_socket_addrs()
        .map_err(|e| ApiError::Unreachable(e.to_string()))?
        .next()
        .ok_or_else(|| ApiError::Unreachable("no address".into()))?;
    let mut s = TcpStream::connect_timeout(&addr, Duration::from_secs(4))
        .map_err(|e| ApiError::Unreachable(e.to_string()))?;
    let _ = s.set_read_timeout(Some(timeout));
    let _ = s.set_write_timeout(Some(timeout));
    let _ = s.set_nodelay(true);
    let body = body.unwrap_or("");
    let mut req = format!(
        "{method} {prefix}{path} HTTP/1.1\r\nHost: {host}:{port}\r\nUser-Agent: waytv-settings\r\n\
         Accept: application/json\r\nAuthorization: Bearer {token}\r\nConnection: close\r\n"
    );
    if method != "GET" {
        req.push_str(&format!(
            "Content-Type: application/json\r\nContent-Length: {}\r\n",
            body.len()
        ));
    }
    req.push_str("\r\n");
    req.push_str(body);
    s.write_all(req.as_bytes())
        .map_err(|e| ApiError::Unreachable(e.to_string()))?;
    let mut raw = Vec::new();
    // Read until EOF (Connection: close) or until Content-Length is satisfied.
    let mut buf = [0u8; 16 * 1024];
    loop {
        match s.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                raw.extend_from_slice(&buf[..n]);
                if let Some(total) = complete_length(&raw)
                    && raw.len() >= total
                {
                    break;
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(e) => {
                if raw.is_empty() {
                    return Err(ApiError::Unreachable(e.to_string()));
                }
                break;
            }
        }
    }
    parse_response(&raw)
}

fn find_header_end(raw: &[u8]) -> Option<usize> {
    raw.windows(4).position(|w| w == b"\r\n\r\n").map(|p| p + 4)
}

/// If headers are complete and declare Content-Length, return the total message length.
fn complete_length(raw: &[u8]) -> Option<usize> {
    let he = find_header_end(raw)?;
    let head = String::from_utf8_lossy(&raw[..he]);
    for line in head.lines().skip(1) {
        if let Some((k, v)) = line.split_once(':')
            && k.trim().eq_ignore_ascii_case("content-length")
        {
            return v.trim().parse::<usize>().ok().map(|n| he + n);
        }
    }
    None
}

pub fn parse_response(raw: &[u8]) -> Result<HttpResponse, ApiError> {
    let he = find_header_end(raw)
        .ok_or_else(|| ApiError::Unreachable("connection closed before the answer".into()))?;
    let head = String::from_utf8_lossy(&raw[..he]);
    let mut lines = head.lines();
    let status = lines.next().unwrap_or("");
    let code: u16 = status
        .split_whitespace()
        .nth(1)
        .and_then(|c| c.parse().ok())
        .ok_or_else(|| ApiError::BadResponse(format!("bad status line {status:?}")))?;
    let mut chunked = false;
    let mut clen: Option<usize> = None;
    for line in lines {
        if let Some((k, v)) = line.split_once(':') {
            let k = k.trim();
            if k.eq_ignore_ascii_case("transfer-encoding")
                && v.to_ascii_lowercase().contains("chunked")
            {
                chunked = true;
            } else if k.eq_ignore_ascii_case("content-length") {
                clen = v.trim().parse().ok();
            }
        }
    }
    let mut body = raw[he..].to_vec();
    if chunked {
        body = dechunk(&body);
    } else if let Some(n) = clen {
        body.truncate(n);
    }
    Ok(HttpResponse { code, body })
}

fn dechunk(mut data: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    while let Some(nl) = data.windows(2).position(|w| w == b"\r\n") {
        let size_str = String::from_utf8_lossy(&data[..nl]);
        let size =
            usize::from_str_radix(size_str.split(';').next().unwrap_or("").trim(), 16).unwrap_or(0);
        data = &data[nl + 2..];
        if size == 0 || data.len() < size {
            out.extend_from_slice(&data[..size.min(data.len())]);
            break;
        }
        out.extend_from_slice(&data[..size]);
        data = data.get(size + 2..).unwrap_or(&[]);
    }
    out
}

/// The requests the app makes.
#[derive(Debug, Clone, PartialEq)]
pub enum ApiReq {
    Status,
    Timezones,
    JobsLast,
    Job(String),
    SetDisplay { width: i64, height: i64 },
    SetDensity(DensityValue),
    SetNavbar { visible: bool },
    SetOverlay { on: bool },
    SetTimezone(String),
    /// API v2: several staged changes in one request (one Android restart at most).
    Apply(Changes),
    UpdateCheck,
    UpdateRun,
    RestartAndroid,
    Reboot,
}

#[derive(Debug, Clone, PartialEq)]
pub enum DensityValue {
    Auto,
    Reset,
    Dpi(i64),
}

impl DensityValue {
    pub fn to_json(&self) -> serde_json::Value {
        match self {
            DensityValue::Auto => serde_json::json!("auto"),
            DensityValue::Reset => serde_json::json!("reset"),
            DensityValue::Dpi(n) => serde_json::json!(n),
        }
    }
}

/// Staged settings changes; `None` = unchanged.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Changes {
    /// (width, height, refresh); refresh None = automatic (fastest up to 60 Hz).
    pub display: Option<(i64, i64, Option<f64>)>,
    pub density: Option<DensityValue>,
    /// true = bottom bar hidden.
    pub navbar_hidden: Option<bool>,
    pub overlay: Option<bool>,
    pub timezone: Option<String>,
}

impl Changes {
    pub fn is_empty(&self) -> bool {
        self.count() == 0
    }
    pub fn count(&self) -> usize {
        [
            self.display.is_some(),
            self.density.is_some(),
            self.navbar_hidden.is_some(),
            self.overlay.is_some(),
            self.timezone.is_some(),
        ]
        .iter()
        .filter(|b| **b)
        .count()
    }
    /// Changing these restarts Android.
    pub fn needs_restart(&self) -> bool {
        self.display.is_some() || self.navbar_hidden.is_some() || self.overlay.is_some()
    }
    /// JSON body for POST /api/apply: only the changed keys.
    pub fn to_json(&self) -> serde_json::Value {
        let mut m = serde_json::Map::new();
        if let Some((w, h, r)) = self.display {
            m.insert(
                "display".into(),
                serde_json::json!({"width": w, "height": h, "refresh": r}),
            );
        }
        if let Some(d) = &self.density {
            m.insert("density".into(), d.to_json());
        }
        if let Some(hidden) = self.navbar_hidden {
            m.insert("navbar".into(), serde_json::json!(if hidden { "off" } else { "on" }));
        }
        if let Some(on) = self.overlay {
            m.insert("overlay".into(), serde_json::json!(if on { "on" } else { "off" }));
        }
        if let Some(tz) = &self.timezone {
            m.insert("timezone".into(), serde_json::json!(tz));
        }
        serde_json::Value::Object(m)
    }
}

impl ApiReq {
    pub fn method_path_body(&self) -> (&'static str, String, Option<String>) {
        use serde_json::json;
        match self {
            ApiReq::Status => ("GET", "/api/status".into(), None),
            ApiReq::Timezones => ("GET", "/api/timezones".into(), None),
            ApiReq::JobsLast => ("GET", "/api/jobs/last".into(), None),
            ApiReq::Job(id) => ("GET", format!("/api/jobs/{}", urlencode(id)), None),
            ApiReq::SetDisplay { width, height } => (
                "POST",
                "/api/display".into(),
                Some(json!({"width": width, "height": height}).to_string()),
            ),
            ApiReq::Apply(c) => ("POST", "/api/apply".into(), Some(c.to_json().to_string())),
            ApiReq::SetDensity(v) => {
                let value = v.to_json();
                (
                    "POST",
                    "/api/density".into(),
                    Some(json!({ "value": value }).to_string()),
                )
            }
            ApiReq::SetNavbar { visible } => (
                "POST",
                "/api/navbar".into(),
                Some(json!({"state": if *visible { "on" } else { "off" }}).to_string()),
            ),
            ApiReq::SetOverlay { on } => (
                "POST",
                "/api/overlay".into(),
                Some(json!({"state": if *on { "on" } else { "off" }}).to_string()),
            ),
            ApiReq::SetTimezone(tz) => (
                "POST",
                "/api/timezone".into(),
                Some(json!({ "tz": tz }).to_string()),
            ),
            ApiReq::UpdateCheck => ("POST", "/api/update/check".into(), Some("{}".into())),
            ApiReq::UpdateRun => ("POST", "/api/update/run".into(), Some("{}".into())),
            ApiReq::RestartAndroid => ("POST", "/api/restart-android".into(), Some("{}".into())),
            ApiReq::Reboot => ("POST", "/api/reboot".into(), Some("{}".into())),
        }
    }
}

fn urlencode(s: &str) -> String {
    s.bytes()
        .map(|b| {
            if b.is_ascii_alphanumeric() || b"-_.~".contains(&b) {
                (b as char).to_string()
            } else {
                format!("%{b:02X}")
            }
        })
        .collect()
}

/// Execute a request and return the parsed JSON body (2xx) or an error.
pub fn execute(pairing: Option<&Pairing>, req: &ApiReq) -> Result<serde_json::Value, ApiError> {
    let p = pairing.ok_or(ApiError::NotPaired)?;
    let (method, path, body) = req.method_path_body();
    let timeout = Duration::from_secs(if matches!(req, ApiReq::Status | ApiReq::Job(_)) {
        8
    } else {
        20
    });
    let resp = http_request(&p.url, method, &path, &p.token, body.as_deref(), timeout)?;
    let json: Option<serde_json::Value> = serde_json::from_slice(&resp.body).ok();
    match resp.code {
        200..=299 => json.ok_or_else(|| {
            ApiError::BadResponse(
                String::from_utf8_lossy(&resp.body)
                    .chars()
                    .take(80)
                    .collect(),
            )
        }),
        401 => Err(ApiError::Unauthorized),
        code => {
            let msg = json
                .as_ref()
                .and_then(|j| j.get("error"))
                .and_then(|e| e.as_str())
                .map(|s| s.to_string())
                .unwrap_or_else(|| format!("The box answered with error {code}"));
            Err(ApiError::Http(code, msg))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;
    use std::sync::mpsc;
    use std::thread;

    #[test]
    fn pairing_parse() {
        let p = Pairing::parse(r#"{"url":"http://192.168.240.1:8765","token":"abc","extra":1}"#)
            .unwrap();
        assert_eq!(p.url, "http://192.168.240.1:8765");
        assert_eq!(p.token, "abc");
        assert_eq!(
            Pairing::parse(r#"{"token":"abc"}"#).unwrap().url,
            DEFAULT_URL
        );
        assert_eq!(
            Pairing::parse(r#"{"url":null,"token":"abc"}"#).unwrap().url,
            DEFAULT_URL
        );
        assert!(Pairing::parse(r#"{"url":"http://x","token":null}"#).is_none());
        assert!(Pairing::parse(r#"{"url":"http://x"}"#).is_none());
        assert!(Pairing::parse(r#"{"token":""}"#).is_none());
        assert!(Pairing::parse("not json").is_none());
        assert!(Pairing::parse("null").is_none());
        assert!(Pairing::load(Path::new("/nonexistent/agent.json")).is_none());
    }

    #[test]
    fn url_parsing() {
        assert_eq!(
            parse_url("http://192.168.240.1:8765"),
            Some(("192.168.240.1".into(), 8765, "".into()))
        );
        assert_eq!(
            parse_url("http://h:1/x/"),
            Some(("h".into(), 1, "/x".into()))
        );
        assert_eq!(parse_url("http://h"), Some(("h".into(), 80, "".into())));
        assert_eq!(parse_url("https://h"), None);
    }

    #[test]
    fn request_bodies() {
        let (m, p, b) = ApiReq::SetDensity(DensityValue::Auto).method_path_body();
        assert_eq!(
            (m, p.as_str(), b.as_deref()),
            ("POST", "/api/density", Some(r#"{"value":"auto"}"#))
        );
        let (_, _, b) = ApiReq::SetDensity(DensityValue::Dpi(320)).method_path_body();
        assert_eq!(b.as_deref(), Some(r#"{"value":320}"#));
        let (_, _, b) = ApiReq::SetDensity(DensityValue::Reset).method_path_body();
        assert_eq!(b.as_deref(), Some(r#"{"value":"reset"}"#));
        let (_, _, b) = ApiReq::SetNavbar { visible: false }.method_path_body();
        assert_eq!(b.as_deref(), Some(r#"{"state":"off"}"#));
        let (_, p, _) = ApiReq::Job("1731-update".into()).method_path_body();
        assert_eq!(p, "/api/jobs/1731-update");
        let (_, _, b) = ApiReq::SetDisplay {
            width: 1920,
            height: 1080,
        }
        .method_path_body();
        let v: serde_json::Value = serde_json::from_str(&b.unwrap()).unwrap();
        assert_eq!(v["width"], 1920);
    }

    #[test]
    fn chunked_body() {
        let raw = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\n{\"a\"\r\n3\r\n:1}\r\n0\r\n\r\n";
        let r = parse_response(raw).unwrap();
        assert_eq!(r.body, b"{\"a\":1}");
    }

    /// One-shot mock server: answers one request with the given status/body and
    /// reports the raw request it got.
    fn mock(status: &'static str, body: &'static str) -> (String, mpsc::Receiver<String>) {
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", l.local_addr().unwrap());
        let (tx, rx) = mpsc::channel();
        thread::spawn(move || {
            let (mut s, _) = l.accept().unwrap();
            let mut req = Vec::new();
            let mut buf = [0u8; 4096];
            loop {
                let n = s.read(&mut buf).unwrap();
                req.extend_from_slice(&buf[..n]);
                if let Some(total) = complete_length(&req) {
                    if req.len() >= total {
                        break;
                    }
                } else if find_header_end(&req).is_some() && req.starts_with(b"GET") {
                    break;
                }
                if n == 0 {
                    break;
                }
            }
            tx.send(String::from_utf8_lossy(&req).to_string()).unwrap();
            let resp = format!(
                "HTTP/1.0 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{body}",
                body.len()
            );
            s.write_all(resp.as_bytes()).unwrap();
        });
        (url, rx)
    }

    fn pairing(url: String) -> Pairing {
        Pairing {
            url,
            token: "tok123".into(),
        }
    }

    #[test]
    fn http_200_status() {
        let (url, rx) = mock(
            "200 OK",
            r#"{"ok":true,"hostname":"androidtv","ips":["192.168.1.157"]}"#,
        );
        let v = execute(Some(&pairing(url)), &ApiReq::Status).unwrap();
        let s: crate::model::Status = serde_json::from_value(v).unwrap();
        assert_eq!(s.hostname.as_deref(), Some("androidtv"));
        let req = rx.recv().unwrap();
        assert!(req.starts_with("GET /api/status HTTP/1.1\r\n"), "{req}");
        assert!(req.contains("Authorization: Bearer tok123\r\n"));
    }

    #[test]
    fn http_post_body_sent() {
        let (url, rx) = mock("200 OK", r#"{"ok":true,"density":320}"#);
        let v = execute(
            Some(&pairing(url)),
            &ApiReq::SetDensity(DensityValue::Dpi(320)),
        )
        .unwrap();
        assert_eq!(v["density"], 320);
        let req = rx.recv().unwrap();
        assert!(req.starts_with("POST /api/density HTTP/1.1\r\n"));
        assert!(req.contains("Content-Type: application/json"));
        assert!(req.ends_with(r#"{"value":320}"#), "{req}");
    }

    #[test]
    fn http_401() {
        let (url, _rx) = mock("401 Unauthorized", r#"{"ok":false,"error":"bad token"}"#);
        assert_eq!(
            execute(Some(&pairing(url)), &ApiReq::Status),
            Err(ApiError::Unauthorized)
        );
    }

    #[test]
    fn http_409() {
        let (url, _rx) = mock(
            "409 Conflict",
            r#"{"ok":false,"error":"Another task is running: Update"}"#,
        );
        assert_eq!(
            execute(Some(&pairing(url)), &ApiReq::UpdateCheck),
            Err(ApiError::Http(
                409,
                "Another task is running: Update".into()
            ))
        );
    }

    #[test]
    fn http_500_without_json() {
        let (url, _rx) = mock("500 Internal Server Error", "oops");
        match execute(Some(&pairing(url)), &ApiReq::Status) {
            Err(ApiError::Http(500, m)) => assert!(m.contains("500")),
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn connection_refused() {
        // Bind then drop to get a port that is (almost certainly) closed.
        let port = TcpListener::bind("127.0.0.1:0")
            .unwrap()
            .local_addr()
            .unwrap()
            .port();
        let p = pairing(format!("http://127.0.0.1:{port}"));
        assert!(matches!(
            execute(Some(&p), &ApiReq::Status),
            Err(ApiError::Unreachable(_))
        ));
    }

    #[test]
    fn not_paired() {
        assert_eq!(execute(None, &ApiReq::Status), Err(ApiError::NotPaired));
    }
}
