//! eSCL (AirScan) bridge for the Canon imageFORMULA DR-S150 — Rust port of `src/escl_server.py`.
//!
//! Image Capture on macOS only speaks eSCL/AirScan, while Canon's macOS driver is TWAIN-only.
//! This daemon advertises a virtual AirScan scanner over Bonjour and services each scan by
//! running `DRS150Scan.app` (Objective-C), which drives the real TWAIN driver headlessly.
//!
//! Endpoints (eSCL 2.0 subset):
//!   GET    /eSCL/ScannerCapabilities
//!   GET    /eSCL/ScannerStatus            (includes <scan:Jobs>, which AirScanScanner requires)
//!   POST   /eSCL/ScanJobs                 -> 201 + Location, or 503 while a job owns the scanner
//!   GET    /eSCL/ScanJobs/<id>/NextDocument -> image/jpeg, 404 when the ADF is drained
//!   DELETE /eSCL/ScanJobs/<id>
//!
//! One job = one ADF pass: the engine scans every page in the feeder into `page-<n>.raw` and
//! rewrites `page.meta` after each page, so pages can be handed out while the rest is still
//! feeding.

use std::collections::HashMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Mutex, OnceLock};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::Deserialize;
use tiny_http::{Header, Method, Response, Server};

const NS: &str = "xmlns:scan=\"http://schemas.hp.com/imaging/escl/2011/05/03\" \
                  xmlns:pwg=\"http://www.pwg.org/schemas/2010/12/sm\"";
/// Give up ownership of a job nobody touched for this long (seconds).
const ACTIVE_TIMEOUT: f64 = 180.0;
/// How long a single `NextDocument` may block waiting for the next page.
const PAGE_TIMEOUT: u64 = 300;

// ---------------------------------------------------------------- configuration

fn env_or(key: &str, default: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| default.to_string())
}

fn port() -> u16 {
    env_or("ESCL_PORT", "8632").parse().unwrap_or(8632)
}

/// Loopback by default: the bridge drives a scanner on *this* machine, and the eSCL endpoint has
/// no authentication. Set `ESCL_BIND=0.0.0.0` to share it with the network again.
fn bind_addr() -> String {
    env_or("ESCL_BIND", "127.0.0.1")
}

fn uuid() -> String {
    env_or("ESCL_UUID", "1b3f9a52-6d74-4c1e-9f2a-drs150bridge01")
}

fn advertise_name() -> String {
    env_or("ESCL_NAME", "Canon DR-S150 (bridge)")
}

fn home() -> PathBuf {
    PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| "/tmp".into()))
}

/// XDG base directory with the spec's macOS-friendly defaults.
fn xdg_dir(env: &str, fallback: &str) -> PathBuf {
    match std::env::var(env) {
        Ok(v) if !v.is_empty() => PathBuf::from(v),
        _ => home().join(fallback),
    }
    .join("drs150-bridge")
}

/// Mutable per-run artefacts (raw pages, page.meta, mode.txt). `ESCL_DATA_DIR` overrides.
fn data_dir() -> PathBuf {
    match std::env::var("ESCL_DATA_DIR") {
        Ok(v) if !v.is_empty() => PathBuf::from(v),
        _ => xdg_dir("XDG_DATA_HOME", ".local/share"),
    }
}

/// Logs (and nothing else). `ESCL_STATE_DIR` overrides.
fn state_dir() -> PathBuf {
    match std::env::var("ESCL_STATE_DIR") {
        Ok(v) if !v.is_empty() => PathBuf::from(v),
        _ => xdg_dir("XDG_STATE_HOME", ".local/state"),
    }
}

fn spool() -> PathBuf {
    data_dir().join("spool")
}

fn log_dir() -> PathBuf {
    state_dir()
}

/// Patched copy of Canon's TWAIN driver (the system one is never modified).
fn driver_bundle() -> PathBuf {
    data_dir().join("driver/DRS150.ds")
}

const SYSTEM_DRIVER: &str = "/Library/Image Capture/TWAIN Data Sources/DRS150.ds";
const TWAIN_IMPORT: &str = "/System/Library/Frameworks/TWAIN.framework/Versions/A/TWAIN";

fn exe_dir() -> PathBuf {
    std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(Path::to_path_buf))
        .unwrap_or_else(|| PathBuf::from("."))
}

/// The scan engine: alongside the server in the Nix package, or `ESCL_SCAN_ENGINE`.
fn engine_path() -> PathBuf {
    if let Ok(p) = std::env::var("ESCL_SCAN_ENGINE") {
        if !p.is_empty() {
            return PathBuf::from(p);
        }
    }
    let beside = exe_dir().join("drs150scan");
    if beside.exists() {
        return beside;
    }
    PathBuf::from("drs150scan")
}

/// The shim the patched driver imports `DSM_Entry` from (ships in the package's `lib/`).
fn shim_path() -> PathBuf {
    if let Ok(p) = std::env::var("ESCL_SHIM") {
        if !p.is_empty() {
            return PathBuf::from(p);
        }
    }
    exe_dir()
        .parent()
        .map(|prefix| prefix.join("lib/libdsmshim2.dylib"))
        .filter(|p| p.exists())
        .unwrap_or_else(|| PathBuf::from("libdsmshim2.dylib"))
}

// ---------------------------------------------------------------- logging

fn log_file() -> &'static Mutex<fs::File> {
    static LOG: OnceLock<Mutex<fs::File>> = OnceLock::new();
    LOG.get_or_init(|| {
        let dir = log_dir();
        let _ = fs::create_dir_all(&dir);
        let file = fs::File::create(dir.join("server.log")).unwrap_or_else(|_| {
            fs::File::create("/tmp/drs150-bridge-server.log").expect("no log file at all")
        });
        Mutex::new(file)
    })
}

fn log(args: std::fmt::Arguments<'_>) {
    let stamp = chrono::Local::now().format("%H:%M:%S");
    if let Ok(mut f) = log_file().lock() {
        let _ = writeln!(f, "{stamp} {args}");
        let _ = f.flush();
    }
}

macro_rules! logln {
    ($($arg:tt)*) => { log(format_args!($($arg)*)) };
}

// ---------------------------------------------------------------- job state

#[derive(Clone)]
struct Job {
    started: bool,
    served: u32,
    state: &'static str,
    reason: &'static str,
    images: u32,
    ts: f64,
    colormode: String,
}

#[derive(Default)]
struct State {
    jobs: HashMap<String, Job>,
    active: Option<String>,
    engine_running: bool,
    engine_started: f64,
}

fn state() -> &'static Mutex<State> {
    static STATE: OnceLock<Mutex<State>> = OnceLock::new();
    STATE.get_or_init(|| Mutex::new(State::default()))
}

fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

// ---------------------------------------------------------------- engine handshake

#[derive(Deserialize, Default)]
struct MetaPage {
    #[serde(default)]
    file: String,
    #[serde(default)]
    width: u32,
    #[serde(default)]
    height: u32,
}

/// The engine may publish `true`/`false` or `1`/`0` depending on how the default was built;
/// accept both rather than failing the whole metadata document (which looks like "no scan").
fn flexible_bool<'de, D>(deserializer: D) -> Result<bool, D::Error>
where
    D: serde::Deserializer<'de>,
{
    #[derive(Deserialize)]
    #[serde(untagged)]
    enum Boolish {
        Bool(bool),
        Int(i64),
    }
    Ok(match Boolish::deserialize(deserializer)? {
        Boolish::Bool(b) => b,
        Boolish::Int(i) => i != 0,
    })
}

#[derive(Deserialize, Default)]
struct Meta {
    #[serde(default, deserialize_with = "flexible_bool")]
    ok: bool,
    #[serde(default, deserialize_with = "flexible_bool")]
    done: bool,
    #[serde(default)]
    count: u32,
    #[serde(default)]
    dpi: u32,
    #[serde(default)]
    channels: u32,
    #[serde(default)]
    pages: Vec<MetaPage>,
}

fn read_meta() -> Option<Meta> {
    // The engine publishes page.meta by atomic rename; a poll can land in the gap between the
    // unlink and the rename, so retry briefly instead of reporting "no metadata".
    for _ in 0..3 {
        if let Ok(data) = fs::read_to_string(spool().join("page.meta")) {
            if let Ok(meta) = serde_json::from_str(&data) {
                return Some(meta);
            }
        }
        thread::sleep(Duration::from_millis(50));
    }
    None
}

fn engine_child() -> &'static Mutex<Option<std::process::Child>> {
    static CHILD: OnceLock<Mutex<Option<std::process::Child>>> = OnceLock::new();
    CHILD.get_or_init(|| Mutex::new(None))
}

fn engine_alive() -> bool {
    let mut slot = engine_child().lock().unwrap();
    match slot.as_mut() {
        Some(child) => match child.try_wait() {
            Ok(None) => true,
            Ok(Some(status)) => {
                logln!("scan: engine pid {} exited with {status}", child.id());
                false
            }
            Err(e) => {
                logln!("scan: cannot poll engine pid {}: {e}", child.id());
                false
            }
        },
        None => false,
    }
}

fn clear_spool() {
    if let Ok(entries) = fs::read_dir(spool()) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            if name.starts_with("page") || name == "mode.txt" {
                let _ = fs::remove_file(entry.path());
            }
        }
    }
}

/// Every engine run gets its paths through the environment, so nothing depends on being inside
/// an `.app` bundle and the XDG locations stay in one place (this process decides them).
fn engine_command() -> Command {
    let mut cmd = Command::new(engine_path());
    cmd.env("DRS150_SPOOL", spool())
        .env("DRS150_LOG_DIR", log_dir())
        .env("DRS150_SHIM", shim_path())
        .env("DRS150_DRIVER_DIR", driver_bundle().parent().map(Path::to_path_buf).unwrap_or_default());
    cmd
}

/// Is the scanner actually plugged in? Cheap `--probe` run of the engine, cached so Image
/// Capture's status polling does not spawn a Rosetta process every couple of seconds.
fn device_present() -> bool {
    // while a scan owns the driver, the device is obviously there -- and a second engine run
    // would fight the session (and, before, clobber the metadata the scan publishes)
    if engine_alive() {
        return true;
    }
    static CACHE: OnceLock<Mutex<Option<(bool, f64)>>> = OnceLock::new();
    const TTL: f64 = 20.0;
    let cache = CACHE.get_or_init(|| Mutex::new(None));
    if let Some((present, at)) = *cache.lock().unwrap() {
        if now() - at < TTL {
            return present;
        }
    }
    let present = engine_command()
        .arg("--probe")
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    *cache.lock().unwrap() = Some((present, now()));
    logln!("device: scanner {}", if present { "present" } else { "absent" });
    present
}

/// Copy Canon's driver into the XDG data dir and repoint its `DSM_Entry` import at our shim, so
/// the system installation is never modified and the service works from a read-only store.
fn provision_driver() -> Option<PathBuf> {
    let system = Path::new(SYSTEM_DRIVER);
    let bundle = driver_bundle();
    let exe = bundle.join("Contents/MacOS/DRS150");
    if !system.is_dir() {
        logln!("driver: not installed at {}", system.display());
        return None;
    }
    let mtime = |p: &Path| fs::metadata(p).ok().and_then(|m| m.modified().ok());
    let stale = match (mtime(&exe), mtime(&system.join("Contents/MacOS/DRS150"))) {
        (Some(ours), Some(theirs)) => ours < theirs,
        _ => true,
    };
    if stale {
        if let Some(parent) = bundle.parent() {
            let _ = fs::create_dir_all(parent);
        }
        let _ = fs::remove_dir_all(&bundle);
        let copied = Command::new("/bin/cp")
            .arg("-R")
            .arg(system)
            .arg(bundle.parent().unwrap_or(Path::new(".")))
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
        let shim = shim_path();
        let repointed = copied
            && Command::new("/usr/bin/install_name_tool")
                .arg("-change")
                .arg(TWAIN_IMPORT)
                .arg(&shim)
                .arg(&exe)
                .status()
                .map(|s| s.success())
                .unwrap_or(false);
        let _ = Command::new("/usr/bin/codesign")
            .args(["-f", "-s", "-", "--deep"])
            .arg(&bundle)
            .status();
        if !repointed {
            logln!("driver: failed to prepare {}", bundle.display());
            return None;
        }
        logln!("driver: prepared {} -> {}", bundle.display(), shim.display());
    }
    Some(bundle)
}

fn start_scan(colormode: &str) -> bool {
    if provision_driver().is_none() {
        return false;
    }
    if !device_present() {
        logln!("scan: scanner not connected, refusing to start a pass");
        return false;
    }
    wait_engine_idle();
    clear_spool();
    let _ = fs::write(spool().join("mode.txt"), colormode);
    let started = engine_command().spawn();
    match started {
        Ok(child) => {
            *engine_child().lock().unwrap() = Some(child);
            let mut st = state().lock().unwrap();
            st.engine_running = true;
            st.engine_started = now();
            logln!("scan: started {} as {}", engine_path().display(), colormode);
            true
        }
        Err(e) => {
            logln!("scan: cannot start {}: {e}", engine_path().display());
            false
        }
    }
}

fn wait_engine_idle() {
    let deadline = now() + 180.0;
    loop {
        let running = {
            let st = state().lock().unwrap();
            st.engine_running
        };
        if !running || now() > deadline {
            break;
        }
        if read_meta().map(|m| m.done).unwrap_or(false) || !engine_alive() {
            break;
        }
        thread::sleep(Duration::from_millis(300));
    }
    state().lock().unwrap().engine_running = false;
}

/// raw 8-bit samples (grey or RGB) -> JPEG, cached next to the .raw file.
fn page_jpeg(entry: &MetaPage, channels: u32) -> Option<PathBuf> {
    let channels = channels.max(1);
    let raw_path = spool().join(&entry.file);
    let (w, h) = (entry.width as usize, entry.height as usize);
    if w == 0 || h == 0 || !raw_path.exists() {
        return None;
    }
    let data = fs::read(&raw_path).ok()?;
    let stride = w * channels as usize;
    let h = h.min(data.len() / stride);
    if h == 0 {
        return None;
    }
    let jpg_path = raw_path.with_extension("raw.jpg");
    let mut out = fs::File::create(&jpg_path).ok()?;
    let pixels = &data[..stride * h];
    let mut encoder = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, 85);
    let encoded = if channels == 1 {
        encoder.encode(pixels, w as u32, h as u32, image::ExtendedColorType::L8)
    } else {
        encoder.encode(pixels, w as u32, h as u32, image::ExtendedColorType::Rgb8)
    };
    encoded.ok()?;
    drop(out);
    let size = fs::metadata(&jpg_path).ok()?.len();
    logln!("scan: jpeg {} {}", jpg_path.file_name()?.to_string_lossy(), size);
    Some(jpg_path)
}

enum PageState {
    Ready(PathBuf),
    Empty,
    Pending,
}

fn page_state(idx: u32) -> PageState {
    match read_meta() {
        Some(meta) => match meta.pages.get(idx as usize) {
            Some(entry) => match page_jpeg(entry, meta.channels) {
                Some(jpg) => PageState::Ready(jpg),
                None => PageState::Pending,
            },
            None if meta.done => PageState::Empty,
            None => PageState::Pending,
        },
        None => PageState::Pending,
    }
}

/// Block until page `idx` exists, or the session ends without it.
fn wait_page(idx: u32) -> Option<PathBuf> {
    let deadline = now() + PAGE_TIMEOUT as f64;
    while now() < deadline {
        match page_state(idx) {
            PageState::Ready(jpg) => return Some(jpg),
            PageState::Empty => return None, // ADF drained, no such page
            PageState::Pending => {}
        }
        let started = state().lock().unwrap().engine_started;
        if now() - started > 5.0 && !engine_alive() {
            // The run just finished: the last atomic write (or the final page.meta) may still be
            // landing, so look once more before writing the job off.
            for _ in 0..20 {
                thread::sleep(Duration::from_millis(100));
                match page_state(idx) {
                    PageState::Ready(jpg) => return Some(jpg),
                    PageState::Empty => return None,
                    PageState::Pending => {}
                }
            }
            logln!("scan: engine exited without producing page {}", idx + 1);
            return None;
        }
        thread::sleep(Duration::from_millis(300));
    }
    logln!("scan: timeout waiting for page {}", idx + 1);
    None
}

// ---------------------------------------------------------------- XML documents

fn capabilities_xml() -> String {
    let resolutions: String = [200, 300, 600]
        .iter()
        .map(|d| {
            format!(
                "<scan:DiscreteResolution><scan:XResolution>{d}</scan:XResolution>\
                 <scan:YResolution>{d}</scan:YResolution></scan:DiscreteResolution>"
            )
        })
        .collect();
    let profile = format!(
        "<scan:SettingProfiles><scan:SettingProfile>\
         <scan:ColorModes><scan:ColorMode>Grayscale8</scan:ColorMode>\
         <scan:ColorMode>RGB24</scan:ColorMode></scan:ColorModes>\
         <scan:SupportedResolutions><scan:DiscreteResolutions>{resolutions}\
         </scan:DiscreteResolutions></scan:SupportedResolutions>\
         <scan:DocumentFormats><pwg:DocumentFormat>image/jpeg</pwg:DocumentFormat>\
         </scan:DocumentFormats></scan:SettingProfile></scan:SettingProfiles>"
    );
    let region = |h: u32| {
        format!(
            "<scan:ScanRegions><scan:ScanRegion><scan:XOffset>0</scan:XOffset>\
             <scan:YOffset>0</scan:YOffset><scan:Width>2480</scan:Width>\
             <scan:Height>{h}</scan:Height>\
             <scan:ContentRegionUnits>escl:ThreeHundredthsOfInches</scan:ContentRegionUnits>\
             </scan:ScanRegion></scan:ScanRegions>"
        )
    };
    format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\
         <scan:ScannerCapabilities {NS} version=\"2.0\">\n\
         <pwg:Version>2.0</pwg:Version>\n\
         <pwg:MakeAndModel>Canon imageFORMULA DR-S150</pwg:MakeAndModel>\n\
         <scan:SerialNumber>DRS150-ESCL</scan:SerialNumber>\n\
         <scan:UUID>{}</scan:UUID>\n\
         <scan:AdminURI>/eSCL/</scan:AdminURI>\n\
         <scan:Platen><scan:PlatenInputCaps>\
         <scan:MinWidth>148</scan:MinWidth><scan:MaxWidth>2480</scan:MaxWidth>\
         <scan:MinHeight>148</scan:MinHeight><scan:MaxHeight>3508</scan:MaxHeight>\
         <scan:MaxScanRegions>1</scan:MaxScanRegions>{profile}{}</scan:PlatenInputCaps></scan:Platen>\n\
         <scan:Adf><scan:AdfSimplexInputCaps>\
         <scan:MinWidth>148</scan:MinWidth><scan:MaxWidth>2480</scan:MaxWidth>\
         <scan:MinHeight>148</scan:MinHeight><scan:MaxHeight>4200</scan:MaxHeight>\
         <scan:MaxScanRegions>1</scan:MaxScanRegions>{profile}{}\
         <scan:AdfOptions><scan:AdfOption>DetectPaperLoaded</scan:AdfOption></scan:AdfOptions>\
         </scan:AdfSimplexInputCaps></scan:Adf>\n\
         </scan:ScannerCapabilities>",
        uuid(),
        region(3508),
        region(4200)
    )
}

/// AirScanScanner.app looks the job it just created up with `jobInfoForURI:` and cancels it
/// ("Unable to fetch JobInfo for job %@") when the status document lists no matching
/// `<scan:JobInfo>` — so the job list is mandatory, not decoration.
fn status_xml(state_name: &str, jobs: &HashMap<String, Job>, adf: &str) -> String {
    let mut body = String::new();
    let mut ids: Vec<&String> = jobs.keys().collect();
    ids.sort();
    for jid in ids {
        let j = &jobs[jid];
        body.push_str(&format!(
            "<scan:JobInfo><pwg:JobUri>/eSCL/ScanJobs/{jid}</pwg:JobUri>\
             <pwg:JobUuid>{jid}</pwg:JobUuid><scan:Age>0</scan:Age>\
             <pwg:ImagesCompleted>{}</pwg:ImagesCompleted>\
             <pwg:JobState>{}</pwg:JobState>\
             <pwg:JobStateReasons><pwg:JobStateReason>{}</pwg:JobStateReason>\
             </pwg:JobStateReasons></scan:JobInfo>",
            j.images, j.state, j.reason
        ));
    }
    format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\
         <scan:ScannerStatus {NS} version=\"2.0\">\n\
         <pwg:State>{state_name}</pwg:State>\n\
         <scan:AdfState>{adf}</scan:AdfState>\n\
         <scan:Jobs>{body}</scan:Jobs>\n\
         </scan:ScannerStatus>"
    )
}

// ---------------------------------------------------------------- HTTP

fn header(name: &str, value: &str) -> Header {
    Header::from_bytes(name.as_bytes(), value.as_bytes()).expect("valid header")
}

fn respond_xml(request: tiny_http::Request, code: u16, body: String) {
    let response = Response::from_string(body)
        .with_status_code(code)
        .with_header(header("Content-Type", "application/xml"));
    let _ = request.respond(response);
}

fn respond_empty(request: tiny_http::Request, code: u16, headers: Vec<Header>) {
    let mut response = Response::from_string(String::new())
        .with_status_code(code)
        .with_header(header("Content-Type", "text/plain"));
    for h in headers {
        response = response.with_header(h);
    }
    let _ = request.respond(response);
}

/// Current colour mode requested by a job's `<scan:ColorMode>` element.
fn parse_colormode(body: &str) -> String {
    let lower = body.to_ascii_lowercase();
    if let Some(pos) = lower.find("colormode>") {
        let rest = &lower[pos + "colormode>".len()..];
        let value = rest.trim_start();
        if value.starts_with("rgb") || value.starts_with("color") || value.starts_with("colour") {
            return "RGB24".to_string();
        }
    }
    "Grayscale8".to_string()
}

fn next_job_id() -> String {
    // short, opaque, unique enough for a local bridge
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("{:012x}", nanos & 0xffff_ffff_ffff)
}

fn handle(mut request: tiny_http::Request) {
    let method = request.method().clone();
    let full_url = request.url().to_string();
    let path = full_url.split('?').next().unwrap_or("/").to_string();
    let client = request
        .remote_addr()
        .map(|a| a.ip().to_string())
        .unwrap_or_else(|| "?".to_string());

    match (&method, path.as_str()) {
        (Method::Get, "/eSCL/ScannerCapabilities") | (Method::Get, "/ScannerCapabilities") => {
            logln!("{client} GET {path}");
            respond_xml(request, 200, capabilities_xml());
        }
        (Method::Get, "/eSCL/ScannerStatus") | (Method::Get, "/ScannerStatus") => {
            logln!("{client} GET {path}");
            let st = state().lock().unwrap();
            let busy = st
                .active
                .as_ref()
                .and_then(|id| st.jobs.get(id))
                .map(|j| j.state != "Completed" && j.state != "Aborted")
                .unwrap_or(false);
            let scanning = st.jobs.values().any(|j| j.state == "Processing");
            // "Processing" also covers a queued job that owns the scanner, so other clients see
            // the scanner as busy instead of creating a job that would be refused with 503
            let present = device_present();
            let state_name = if !present {
                // eSCL: a scanner that cannot be reached is "Stopped"; clients grey it out
                // instead of queueing a job that would fail.
                "Stopped"
            } else if busy || scanning {
                "Processing"
            } else {
                "Idle"
            };
            let adf = if scanning {
                "ScannerAdfProcessing"
            } else if present {
                "ScannerAdfLoaded"
            } else {
                "ScannerAdfEmpty"
            };
            let body = status_xml(state_name, &st.jobs, adf);
            drop(st);
            respond_xml(request, 200, body);
        }
        (Method::Post, "/eSCL/ScanJobs") | (Method::Post, "/ScanJobs") => {
            let mut body = String::new();
            let _ = request.as_reader().read_to_string(&mut body);
            logln!("{client} POST {path} {}", body.bytes().take(300).len());
            if !device_present() {
                logln!("{client} job refused, scanner not connected");
                respond_empty(request, 503, vec![]);
                return;
            }
            let colormode = parse_colormode(&body);
            let mut st = state().lock().unwrap();
            let now = now();
            let busy = st
                .active
                .as_ref()
                .and_then(|id| st.jobs.get(id))
                .map(|j| now - j.ts < ACTIVE_TIMEOUT && j.state != "Completed" && j.state != "Aborted")
                .unwrap_or(false);
            if busy {
                let owner = st.active.clone().unwrap_or_default();
                drop(st);
                // one physical scanner: a second job would fight over the spool
                logln!("{client} job refused, busy with {owner}");
                respond_empty(request, 503, vec![]);
                return;
            }
            st.jobs
                .retain(|_, j| !(j.state == "Completed" || j.state == "Aborted") || now - j.ts < 120.0);
            let jid = next_job_id();
            st.jobs.insert(
                jid.clone(),
                Job {
                    started: false,
                    served: 0,
                    state: "Pending",
                    reason: "JobQueued",
                    images: 0,
                    ts: now,
                    colormode,
                },
            );
            st.active = Some(jid.clone());
            drop(st);
            let host = request
                .headers()
                .iter()
                .find(|h| h.field.equiv("Host"))
                .map(|h| h.value.as_str().to_string())
                .unwrap_or_else(|| format!("127.0.0.1:{}", port()));
            respond_empty(
                request,
                201,
                vec![header("Location", &format!("http://{host}/eSCL/ScanJobs/{jid}"))],
            );
        }
        (Method::Delete, p) if p.starts_with("/eSCL/ScanJobs/") => {
            let jid = p.trim_start_matches("/eSCL/ScanJobs/").to_string();
            logln!("{client} DELETE {path}");
            let mut st = state().lock().unwrap();
            st.jobs.remove(&jid);
            if st.active.as_deref() == Some(jid.as_str()) {
                st.active = None;
            }
            drop(st);
            respond_empty(request, 200, vec![]);
        }
        (Method::Get, p) if p.starts_with("/eSCL/ScanJobs/") && p.ends_with("/NextDocument") => {
            let jid = p
                .trim_start_matches("/eSCL/ScanJobs/")
                .trim_end_matches("/NextDocument")
                .to_string();
            logln!("{client} GET {path}");
            let (started, served, colormode) = {
                let st = state().lock().unwrap();
                match st.jobs.get(&jid) {
                    Some(j) => (j.started, j.served, j.colormode.clone()),
                    None => {
                        drop(st);
                        respond_empty(request, 410, vec![]);
                        return;
                    }
                }
            };
            if !started {
                if !start_scan(&colormode) {
                    let mut st = state().lock().unwrap();
                    if let Some(j) = st.jobs.get_mut(&jid) {
                        j.state = "Aborted";
                        j.reason = "JobCompletedWithErrors";
                    }
                    if st.active.as_deref() == Some(jid.as_str()) {
                        st.active = None;
                    }
                    drop(st);
                    logln!("{client} job {jid} refused (scanner not available)");
                    respond_empty(request, 503, vec![]);
                    return;
                }
                let mut st = state().lock().unwrap();
                if let Some(j) = st.jobs.get_mut(&jid) {
                    j.started = true;
                    j.state = "Processing";
                    j.reason = "JobScanning";
                }
            }
            match wait_page(served) {
                Some(jpg) => {
                    let bytes = fs::read(&jpg).unwrap_or_default();
                    {
                        let mut st = state().lock().unwrap();
                        if let Some(j) = st.jobs.get_mut(&jid) {
                            j.served += 1;
                            j.images = j.served;
                            j.ts = now();
                        }
                    }
                    logln!("{client} job {jid} page {}", served + 1);
                    let response = Response::from_data(bytes)
                        .with_status_code(200)
                        .with_header(header("Content-Type", "image/jpeg"));
                    let _ = request.respond(response);
                }
                None => {
                    let meta = read_meta().unwrap_or_default();
                    let done = meta.done || !engine_alive();
                    logln!(
                        "scan: meta ok={} count={} dpi={} done={}",
                        meta.ok, meta.count, meta.dpi, meta.done
                    );
                    let mut st = state().lock().unwrap();
                    if let Some(j) = st.jobs.get_mut(&jid) {
                        if served > 0 && done {
                            j.state = "Completed";
                            j.reason = "JobCompletedSuccessfully";
                        } else {
                            j.state = "Aborted";
                            j.reason = "JobCompletedWithErrors";
                        }
                    }
                    if st.active.as_deref() == Some(jid.as_str()) {
                        st.active = None;
                    }
                    drop(st);
                    if served > 0 && done {
                        // eSCL: 404 on NextDocument means "no more documents" -> job is done
                        logln!("{client} job {jid} complete after {served} page(s)");
                        respond_empty(request, 404, vec![]);
                    } else {
                        logln!("{client} job {jid} aborted");
                        respond_empty(request, 500, vec![]);
                    }
                }
            }
        }
        _ => {
            logln!("{client} {} {path} -> 404", method);
            respond_empty(request, 404, vec![]);
        }
    }
}

// ---------------------------------------------------------------- Bonjour

/// Host name our SRV record points at.
///
/// It must **not** be the Mac's own `.local` name. `mdns-sd` is a second mDNS responder next to
/// macOS's `mDNSResponder`, so publishing an A record for `Rishabs-MacBook-Pro.local` looks like a
/// duplicate claim: `mDNSResponder` yields and renames the system's LocalHostName to
/// `Rishabs-MacBook-Pro-2`. A bridge-specific name keeps the two claim sets disjoint.
/// (The old `dns-sd -R` design never had this problem because the system responder did the
/// publishing itself.)
fn mdns_host() -> String {
    env_or("ESCL_MDNS_HOST", "drs150-bridge.local.")
}

fn advertise() -> Option<mdns_sd::ServiceDaemon> {
    use mdns_sd::{ServiceDaemon, ServiceInfo};

    let daemon = match ServiceDaemon::new() {
        Ok(d) => d,
        Err(e) => {
            logln!("bonjour: daemon failed: {e}");
            return None;
        }
    };
    let properties = [
        ("txtvers", "1".to_string()),
        ("rs", "eSCL".to_string()),
        ("ty", "Canon imageFORMULA DR-S150".to_string()),
        ("pdl", "image/jpeg".to_string()),
        ("cs", "grayscale,color".to_string()),
        ("is", "platen,adf".to_string()),
        ("duplex", "F".to_string()),
        ("vers", "2.0".to_string()),
        ("uuid", uuid()),
        ("representation", "/eSCL/ScannerCapabilities".to_string()),
        ("adminurl", "/eSCL/".to_string()),
    ];
    let host = mdns_host();
    let info = match ServiceInfo::new(
        "_uscan._tcp.local.",
        &advertise_name(),
        &host,
        (),
        port(),
        &properties[..],
    ) {
        Ok(info) => info.enable_addr_auto(),
        Err(e) => {
            logln!("bonjour: invalid service info: {e}");
            return None;
        }
    };
    match daemon.register(info) {
        Ok(()) => {
            logln!("bonjour: registered {} on {}:{}", advertise_name(), host, port());
            Some(daemon)
        }
        Err(e) => {
            logln!("bonjour: register failed: {e}");
            None
        }
    }
}

// ---------------------------------------------------------------- main

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn colormode_parsing() {
        assert_eq!(parse_colormode("<scan:ColorMode>RGB24</scan:ColorMode>"), "RGB24");
        assert_eq!(parse_colormode("<pwg:ColorMode>Grayscale8</pwg:ColorMode>"), "Grayscale8");
        assert_eq!(parse_colormode("<scan:Intent>TextAndGraphic</scan:Intent>"), "Grayscale8");
    }

    #[test]
    fn encodes_grey_and_colour_pages_to_jpeg() {
        let tmp = std::env::temp_dir().join(format!("drs150test{}", std::process::id()));
        std::env::set_var("HOME", &tmp); // spool()/log_dir() hang off HOME
        let dir = spool();
        fs::create_dir_all(&dir).unwrap();

        fs::write(dir.join("page-1.raw"), [0u8, 64, 128, 255, 0, 64, 128, 255]).unwrap();
        let grey = MetaPage { file: "page-1.raw".into(), width: 4, height: 2 };
        let jpg = page_jpeg(&grey, 1).expect("grey page encodes");
        let bytes = fs::read(&jpg).unwrap();
        assert_eq!(&bytes[..3], &[0xff, 0xd8, 0xff], "JPEG SOI marker");

        fs::write(dir.join("page-2.raw"), [255u8, 0, 0, 0, 255, 0]).unwrap();
        let colour = MetaPage { file: "page-2.raw".into(), width: 2, height: 1 };
        let jpg = page_jpeg(&colour, 3).expect("colour page encodes");
        assert!(fs::metadata(&jpg).unwrap().len() > 0);
    }
}

fn main() {
    let _ = fs::create_dir_all(spool());
    let _ = fs::create_dir_all(log_dir());

    let bind = bind_addr();
    let port = port();
    let _bonjour = advertise();
    logln!(
        "listening on {bind}:{port} engine: {} | data: {} | state: {} | advertised as {}",
        engine_path().display(),
        data_dir().display(),
        state_dir().display(),
        advertise_name()
    );
    if bind == "127.0.0.1" || bind == "localhost" {
        logln!("note: loopback only (ESCL_BIND=0.0.0.0 to share it on the network)");
    } else {
        logln!("note: reachable from the network - unauthenticated, every job pulls paper");
    }
    // do this before the first request so the first scan does not pay for it
    provision_driver();
    device_present();

    let server = match Server::http((bind.as_str(), port)) {
        Ok(s) => s,
        Err(e) => {
            logln!("FATAL: cannot bind {bind}:{port}: {e}");
            std::process::exit(1);
        }
    };
    for request in server.incoming_requests() {
        // the scan work blocks for a whole ADF pass, so it must never run on the accept loop
        thread::spawn(move || handle(request));
    }
}
