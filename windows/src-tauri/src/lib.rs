//! ghostgrid for Windows: the app process. It owns the windows, talks to the
//! session helper for every pane, keeps the session and settings, and
//! serves the web views (one per window) through the commands below.

mod config;
mod explain;
mod helper;
mod panes;
mod paths;
mod platform;
mod store;
mod updates;

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use ghostgrid_core::blocks::BlockView;
use ghostgrid_core::explain::{ExplainPolicy, FailedCommand};
use ghostgrid_core::launcher::{self, LaunchApp};
use ghostgrid_core::links::{self, Link};
use ghostgrid_core::paneinfo::{GitBranch, PathDisplay};
use ghostgrid_core::session::{Frame as Rect, SessionPolicy, Tab, Window};
use ghostgrid_core::settings::Settings;
use ghostgrid_core::shells::{self, ShellChoice};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tauri::ipc::{Channel, InvokeResponseBody};
use tauri::{AppHandle, Emitter, Manager, WebviewUrl, WebviewWindow, WebviewWindowBuilder, WindowEvent};
use tokio::sync::oneshot;

use crate::config::TerminalConfig;
use crate::panes::{PaneManager, PaneOpened, PaneSpec};
use crate::store::Store;

/// What a new window starts with.
#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WindowInit {
    /// Tabs to bring back (a restored window, or a tab moved out).
    pub restore: Option<Window>,
    /// Folders to open a pane in each (gg, a dropped folder).
    pub open_dirs: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DropTarget {
    pub label: String,
    pub index: i64,
}

pub struct App {
    store: &'static Store,
    panes: Arc<PaneManager>,
    explainer: explain::Explainer,
    config: Mutex<TerminalConfig>,
    quitting: AtomicBool,
    next_window: AtomicU64,
    inits: Mutex<HashMap<String, WindowInit>>,
    next_query: AtomicU64,
    queries: Mutex<HashMap<u64, oneshot::Sender<Option<i64>>>>,
}

type State<'a> = tauri::State<'a, App>;

fn keeps_shells(app: &App) -> bool {
    let window_save_state = app.config.lock().unwrap().settings.window_save_state.clone();
    app.store.settings().keep_shells_running && window_save_state.as_deref().map(str::to_lowercase).as_deref() != Some("never")
}

fn create_window(handle: &AppHandle, init: WindowInit) -> tauri::Result<WebviewWindow> {
    let app = handle.state::<App>();
    let label = format!("w{}", app.next_window.fetch_add(1, Ordering::SeqCst));
    let frame = init.restore.as_ref().map(|w| w.frame);
    let maximized = init.restore.as_ref().and_then(|w| w.maximized).unwrap_or(false);
    app.inits.lock().unwrap().insert(label.clone(), init);
    let opacity = app.config.lock().unwrap().settings.background_opacity;
    let mut builder = WebviewWindowBuilder::new(handle, &label, WebviewUrl::App("index.html".into()))
        .title("ghostgrid")
        .inner_size(1180.0, 760.0)
        .min_inner_size(420.0, 280.0)
        .decorations(false)
        .shadow(true)
        .visible(false)
        .disable_drag_drop_handler();
    if opacity < 1.0 {
        builder = builder.transparent(true);
    }
    if let Some(frame) = frame.and_then(|f| fit_on_screen(handle, f)) {
        builder = builder.position(frame.x, frame.y).inner_size(frame.width, frame.height);
    }
    let window = builder.build()?;
    if maximized {
        let _ = window.maximize();
    }
    Ok(window)
}

/// A saved frame, kept when enough of it is on some monitor, else moved
/// onto the first one.
fn fit_on_screen(handle: &AppHandle, frame: Rect) -> Option<Rect> {
    let monitors = handle.available_monitors().ok()?;
    let screens: Vec<Rect> = monitors
        .iter()
        .map(|m| {
            let scale = m.scale_factor();
            let pos = m.position().to_logical::<f64>(scale);
            let size = m.size().to_logical::<f64>(scale);
            Rect { x: pos.x, y: pos.y, width: size.width, height: size.height }
        })
        .collect();
    SessionPolicy::fit(frame, &screens, SessionPolicy::MINIMUM_VISIBLE)
}

fn open_window_count(handle: &AppHandle) -> usize {
    handle.webview_windows().len()
}

/// Quits ghostgrid: shells are kept (the helper holds them) unless
/// Settings or `window-save-state = never` say otherwise, and the session
/// is saved for the next launch.
fn quit(handle: &AppHandle) {
    let app = handle.state::<App>();
    if app.quitting.swap(true, Ordering::SeqCst) {
        return;
    }
    let keep = keeps_shells(&app);
    let mut ended = false;
    for pane in app.panes.all() {
        if keep {
            app.panes.release(&pane.id);
        } else {
            app.panes.terminate(&pane.id);
            ended = true;
        }
    }
    app.store.save();
    let handle = handle.clone();
    std::thread::spawn(move || {
        // Let the terminate requests reach the helper.
        if ended {
            std::thread::sleep(Duration::from_millis(300));
        }
        handle.exit(0);
    });
}

/// A window the user closes ends its shells and leaves the session; the
/// last window closing quits instead, so its shells are kept like on quit.
fn close_window(handle: &AppHandle, label: &str) {
    let app = handle.state::<App>();
    if app.quitting.load(Ordering::SeqCst) {
        return;
    }
    if open_window_count(handle) <= 1 {
        quit(handle);
        return;
    }
    for id in app.panes.panes_in_window(label) {
        app.panes.terminate(&id);
    }
    app.store.remove_window(label);
    if let Some(window) = handle.get_webview_window(label) {
        let _ = window.destroy();
    }
}

/// Folders from a command line (gg, a second launch): `--open a b` or bare
/// arguments, relative to `--cwd` (or the launch folder); only existing
/// folders count, and a file stands for its folder.
fn folders_from_args(args: &[String], cwd: &str) -> Vec<String> {
    let mut base = PathBuf::from(cwd);
    let mut folders = Vec::new();
    let mut iter = args.iter().skip(1).peekable();
    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "--cwd" => {
                if let Some(dir) = iter.next() {
                    base = PathBuf::from(dir);
                }
            }
            "--open" => {}
            other if other.starts_with("--") => {}
            other => {
                let path = Path::new(other);
                let path = if path.is_absolute() { path.to_path_buf() } else { base.join(path) };
                let path = if path.is_file() { path.parent().map(Path::to_path_buf).unwrap_or(path) } else { path };
                if path.is_dir() {
                    let text = path.display().to_string();
                    folders.push(text.strip_prefix(r"\\?\").unwrap_or(&text).to_string());
                }
            }
        }
    }
    folders
}

fn open_folders(handle: &AppHandle, folders: Vec<String>) {
    if folders.is_empty() {
        if let Some(window) = handle.webview_windows().values().next() {
            let _ = window.unminimize();
            let _ = window.set_focus();
        } else {
            let _ = create_window(handle, WindowInit::default());
        }
        return;
    }
    let target = handle
        .webview_windows()
        .values()
        .find(|w| w.is_focused().unwrap_or(false))
        .cloned()
        .or_else(|| handle.webview_windows().values().next().cloned());
    match target {
        Some(window) => {
            let _ = window.emit_to(window.label(), "open-dirs", folders);
            let _ = window.unminimize();
            let _ = window.set_focus();
        }
        None => {
            let _ = create_window(handle, WindowInit { restore: None, open_dirs: folders });
        }
    }
}

// ---- commands ---------------------------------------------------------------

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct InitData {
    label: String,
    init: WindowInit,
    settings: Settings,
    config: TerminalConfig,
    shells: Vec<ShellChoice>,
    version: String,
    home: String,
    updates_configured: bool,
    /// For xterm.js's ConPTY handling (reflow differs by Windows build).
    os_build: u32,
}

fn resolve_shells() -> Vec<ShellChoice> {
    let env = |key: &str| std::env::var(key).ok();
    let is_file = |path: &str| Path::new(path).is_file();
    shells::resolve(&env, &is_file)
}

#[tauri::command]
fn window_init(window: WebviewWindow, state: State) -> InitData {
    let init = state.inits.lock().unwrap().remove(window.label()).unwrap_or_default();
    InitData {
        label: window.label().to_string(),
        init,
        settings: state.store.settings(),
        config: state.config.lock().unwrap().clone(),
        shells: resolve_shells(),
        version: env!("CARGO_PKG_VERSION").to_string(),
        home: paths::home().display().to_string(),
        updates_configured: updates::configured(),
        os_build: platform::os_build(),
    }
}

#[tauri::command]
fn get_settings(state: State) -> Settings {
    state.store.settings()
}

#[tauri::command]
fn set_settings(handle: AppHandle, state: State, settings: Settings) -> Settings {
    let saved = state.store.set_settings(settings);
    let _ = handle.emit("settings-changed", &saved);
    saved
}

#[tauri::command]
fn reload_config(handle: AppHandle, state: State) -> TerminalConfig {
    let loaded = config::load();
    *state.panes.integration.lock().unwrap() = integration_enabled(&loaded);
    *state.config.lock().unwrap() = loaded.clone();
    let _ = handle.emit("config-changed", &loaded);
    loaded
}

fn integration_enabled(config: &TerminalConfig) -> bool {
    config.settings.shell_integration.as_deref().map(|s| s.trim().to_lowercase()).as_deref() != Some("none")
}

#[tauri::command]
fn open_config(state: State) -> Result<(), String> {
    let path = PathBuf::from(state.config.lock().unwrap().path.clone());
    config::ensure_exists(&path).map_err(|e| e.to_string())?;
    platform::open_in_editor(&path.display().to_string())
}

#[tauri::command]
fn get_shells() -> Vec<ShellChoice> {
    resolve_shells()
}

#[tauri::command]
fn get_launcher_apps(state: State) -> Vec<LaunchApp> {
    let env = |key: &str| std::env::var(key).ok();
    let dirs = launcher::default_search_dirs(&env);
    let extensions = launcher::default_extensions(&env);
    let is_file = |path: &str| Path::new(path).is_file();
    launcher::resolve(&state.store.settings().launcher_entries, &dirs, &extensions, &is_file)
}

#[tauri::command]
async fn pane_open(
    window: WebviewWindow,
    state: State<'_>,
    spec: PaneSpec,
    data: Channel<InvokeResponseBody>,
    events: Channel<Value>,
) -> Result<PaneOpened, String> {
    let panes = state.panes.clone();
    panes.open(window.label().to_string(), spec, data, events).await
}

#[tauri::command]
fn pane_input(state: State, id: String, data: String) {
    state.panes.input(&id, data.into_bytes());
}

/// xterm.js's binary data (mouse reports in X10 mode): one byte per char.
#[tauri::command]
fn pane_input_bytes(state: State, id: String, data: Vec<u8>) {
    state.panes.input(&id, data);
}

#[tauri::command]
fn pane_resize(state: State, id: String, cols: u16, rows: u16, width: u16, height: u16) {
    state.panes.resize(&id, cols, rows, width, height);
}

#[tauri::command]
fn pane_close(state: State, id: String) {
    state.explainer.cancel(&id);
    state.panes.terminate(&id);
}

#[tauri::command]
fn pane_release(state: State, id: String) {
    state.panes.release(&id);
}

#[tauri::command]
fn pane_blocks(state: State, id: String) -> Vec<BlockView> {
    state.panes.get(&id).map(|p| p.blocks()).unwrap_or_default()
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PaneInfo {
    display: String,
    branch: Option<String>,
}

#[tauri::command]
fn pane_info(cwd: String) -> PaneInfo {
    let home = paths::home().display().to_string();
    let branch = GitBranch::read(
        &cwd,
        &|p: &Path| p.exists(),
        &|p: &Path| p.is_dir(),
        &|p: &Path| std::fs::read_to_string(p).ok(),
    );
    PaneInfo { display: PathDisplay::short(&cwd, &home, 48), branch }
}

#[tauri::command]
fn explain_start(state: State, id: String, block: u64, channel: Channel<Value>) -> Result<(), String> {
    let pane = state.panes.get(&id).ok_or("no such pane")?;
    let (command, output, exit_code) = pane.block(block).ok_or("no such command")?;
    if !ExplainPolicy::offers(exit_code.map(i64::from), command.as_deref()) {
        return Err("that command did not fail".into());
    }
    let failure = FailedCommand {
        command: command.unwrap_or_default(),
        output,
        exit_code: exit_code.map(i64::from).unwrap_or(1),
        shell: pane.shell.clone(),
        directory: pane.cwd(),
    };
    let settings = state.store.settings();
    state.explainer.start(id, failure, settings.model_endpoint, settings.model_name, channel);
    Ok(())
}

#[tauri::command]
fn explain_cancel(state: State, id: String) {
    state.explainer.cancel(&id);
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ResolvedLink {
    kind: &'static str,
    target: String,
}

fn resolve(raw: &str, cwd: Option<&str>) -> Option<ResolvedLink> {
    let home = paths::home().display().to_string();
    match links::resolve(raw, cwd, &home, &|p: &str| Path::new(p).exists())? {
        Link::Url(url) => Some(ResolvedLink { kind: "url", target: url }),
        Link::File(path) => Some(ResolvedLink { kind: "file", target: path }),
    }
}

#[tauri::command]
fn resolve_link(raw: String, cwd: Option<String>) -> Option<ResolvedLink> {
    resolve(&raw, cwd.as_deref())
}

#[tauri::command]
fn open_link(raw: String, cwd: Option<String>) -> Result<bool, String> {
    match resolve(&raw, cwd.as_deref()) {
        Some(link) => platform::shell_open(&link.target).map(|_| true),
        None => Ok(false),
    }
}

#[tauri::command]
fn clipboard_read() -> Option<String> {
    platform::clipboard_read()
}

#[tauri::command]
fn clipboard_write(text: String) -> Result<(), String> {
    platform::clipboard_write(&text)
}

#[tauri::command]
fn save_window(window: WebviewWindow, state: State, value: Window) {
    if !state.quitting.load(Ordering::SeqCst) {
        state.store.update_window(window.label(), value);
    }
}

#[tauri::command]
fn window_close(handle: AppHandle, window: WebviewWindow) {
    close_window(&handle, window.label());
}

#[tauri::command]
fn app_quit(handle: AppHandle) {
    quit(&handle);
}

#[tauri::command]
fn new_window(handle: AppHandle, open_dirs: Option<Vec<String>>) -> Result<(), String> {
    create_window(&handle, WindowInit { restore: None, open_dirs: open_dirs.unwrap_or_default() }).map(|_| ()).map_err(|e| e.to_string())
}

/// A tab let go away from every tab bar: a window of its own, under the
/// pointer.
#[tauri::command]
fn tab_to_new_window(handle: AppHandle, state: State, tab: Tab, x: f64, y: f64) -> Result<(), String> {
    for pane in &tab.panes {
        if let Some(id) = &pane.session_id {
            state.panes.release(id);
            state.panes.move_to_window(id, "");
        }
    }
    let frame = Rect { x: x - 120.0, y: y - 18.0, width: 1000.0, height: 680.0 };
    let window = Window { frame, maximized: None, tabs: vec![tab], selected_tab: Some(0) };
    create_window(&handle, WindowInit { restore: Some(window), open_dirs: Vec::new() }).map(|_| ()).map_err(|e| e.to_string())
}

/// Which other ghostgrid window is under a screen point, and where in it
/// a dragged tab or pane would go (that window answers; nil: not over its
/// tab bar).
#[tauri::command]
async fn drop_query(handle: AppHandle, window: WebviewWindow, state: State<'_>, kind: String, x: f64, y: f64) -> Result<Option<DropTarget>, String> {
    let scale = window.scale_factor().unwrap_or(1.0);
    let Some(hwnd) = platform::window_at((x * scale) as i32, (y * scale) as i32) else { return Ok(None) };
    let target = handle
        .webview_windows()
        .into_values()
        .find(|w| w.label() != window.label() && w.hwnd().ok().map(|h| h.0 as isize) == Some(hwnd));
    let Some(target) = target else { return Ok(None) };
    let id = state.next_query.fetch_add(1, Ordering::SeqCst);
    let (tx, rx) = oneshot::channel();
    state.queries.lock().unwrap().insert(id, tx);
    target.emit_to(target.label(), "drop-query", json!({ "id": id, "kind": kind, "x": x, "y": y })).map_err(|e| e.to_string())?;
    let answer = tokio::time::timeout(Duration::from_millis(800), rx).await.ok().and_then(|r| r.ok()).flatten();
    state.queries.lock().unwrap().remove(&id);
    Ok(answer.map(|index| DropTarget { label: target.label().to_string(), index }))
}

#[tauri::command]
fn drop_answer(state: State, id: u64, index: Option<i64>) {
    if let Some(tx) = state.queries.lock().unwrap().remove(&id) {
        let _ = tx.send(index);
    }
}

/// Hands a tab or pane (its saved form, shells by session ID) to another
/// window, which attaches to the same shells.
#[tauri::command]
fn transfer(handle: AppHandle, state: State, target: String, kind: String, payload: Value, index: i64) -> Result<(), String> {
    let ids: Vec<String> = match kind.as_str() {
        "tab" => serde_json::from_value::<Tab>(payload.clone())
            .map_err(|e| e.to_string())?
            .panes
            .into_iter()
            .filter_map(|p| p.session_id)
            .collect(),
        _ => payload.get("sessionID").and_then(|v| v.as_str()).map(|s| vec![s.to_string()]).unwrap_or_default(),
    };
    for id in &ids {
        state.panes.release(id);
        // Belongs to the target now: the source window closing (its last
        // tab left) must not end it.
        state.panes.move_to_window(id, &target);
    }
    let window = handle.get_webview_window(&target).ok_or("that window is gone")?;
    window.emit_to(&target, "adopt", json!({ "kind": kind, "payload": payload, "index": index })).map_err(|e| e.to_string())?;
    let _ = window.set_focus();
    Ok(())
}

#[tauri::command]
fn notify(handle: AppHandle, title: String, body: String) {
    use tauri_plugin_notification::NotificationExt;
    let _ = handle.notification().builder().title(title).body(body).show();
}

#[tauri::command]
fn install_gg() -> Result<String, String> {
    platform::install_gg()
}

#[tauri::command]
async fn check_update(handle: AppHandle) -> Result<Option<updates::UpdateInfo>, String> {
    updates::check(&handle).await
}

#[tauri::command]
async fn install_update(handle: AppHandle) -> Result<(), String> {
    // The helper (and so every shell) keeps running through the update;
    // quitting first saves the session the new version restores.
    let app = handle.state::<App>();
    for pane in app.panes.all() {
        app.panes.release(&pane.id);
    }
    app.store.save();
    app.quitting.store(true, Ordering::SeqCst);
    updates::install(&handle).await
}

// ---- startup ----------------------------------------------------------------

pub fn run() {
    let store: &'static Store = Box::leak(Box::new(Store::load()));
    let loaded = config::load();
    let panes = Arc::new(PaneManager::new(paths::hooks_dir().display().to_string()));
    *panes.integration.lock().unwrap() = integration_enabled(&loaded);
    if let Err(e) = shells::hooks::install(&paths::hooks_dir()) {
        eprintln!("ghostgrid: could not write the shell hooks: {e}");
    }

    let mut builder = tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|handle, args, cwd| {
            open_folders(handle, folders_from_args(&args, &cwd));
        }))
        .plugin(tauri_plugin_notification::init());
    builder = updates::plugin(builder);

    builder
        .manage(App {
            store,
            panes,
            explainer: explain::Explainer::default(),
            config: Mutex::new(loaded),
            quitting: AtomicBool::new(false),
            next_window: AtomicU64::new(1),
            inits: Mutex::new(HashMap::new()),
            next_query: AtomicU64::new(1),
            queries: Mutex::new(HashMap::new()),
        })
        .invoke_handler(tauri::generate_handler![
            window_init,
            get_settings,
            set_settings,
            reload_config,
            open_config,
            get_shells,
            get_launcher_apps,
            pane_open,
            pane_input,
            pane_input_bytes,
            pane_resize,
            pane_close,
            pane_release,
            pane_blocks,
            pane_info,
            explain_start,
            explain_cancel,
            resolve_link,
            open_link,
            clipboard_read,
            clipboard_write,
            save_window,
            window_close,
            app_quit,
            new_window,
            tab_to_new_window,
            drop_query,
            drop_answer,
            transfer,
            notify,
            install_gg,
            check_update,
            install_update,
        ])
        .on_window_event(|window, event| {
            if let WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                close_window(window.app_handle(), window.label());
            }
        })
        .setup(move |app| {
            let handle = app.handle().clone();
            let state = handle.state::<App>();
            Store::autosave(state.store);

            let cwd = std::env::current_dir().map(|p| p.display().to_string()).unwrap_or_default();
            let args: Vec<String> = std::env::args().collect();
            let mut folders = folders_from_args(&args, &cwd);

            let previous = state.store.previous.lock().unwrap().take();
            let window_save_state = state.config.lock().unwrap().settings.window_save_state.clone();
            let keep = state.store.settings().keep_shells_running;
            let restore = SessionPolicy::should_restore(window_save_state.as_deref(), keep);
            let mut created = 0;
            if let Some(previous) = previous {
                if restore {
                    for window in previous.restorable() {
                        let open_dirs = if created == 0 { std::mem::take(&mut folders) } else { Vec::new() };
                        create_window(&handle, WindowInit { restore: Some(window), open_dirs })?;
                        created += 1;
                    }
                } else {
                    let ids = previous.live_session_ids();
                    let panes = state.panes.clone();
                    if !ids.is_empty() {
                        tauri::async_runtime::spawn(async move { panes.end_kept(ids).await });
                    }
                }
            }
            if created == 0 {
                create_window(&handle, WindowInit { restore: None, open_dirs: folders })?;
            }
            updates::schedule(&handle);
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error while building ghostgrid")
        .run(|handle, event| {
            if let tauri::RunEvent::ExitRequested { api, code, .. } = &event {
                // Closing the last window ends here too: save and keep shells.
                let app = handle.state::<App>();
                if code.is_none() && !app.quitting.load(Ordering::SeqCst) {
                    api.prevent_exit();
                    quit(handle);
                }
            }
            if let tauri::RunEvent::Exit = event {
                let app = handle.state::<App>();
                app.store.save();
            }
        });
}

#[cfg(test)]
mod tests {
    use super::folders_from_args;

    #[test]
    fn reads_folders_from_gg_arguments() {
        let temp = std::env::temp_dir();
        let cwd = temp.display().to_string();
        let args = vec!["ghostgrid.exe".to_string(), "--cwd".into(), cwd.clone(), "--open".into(), ".".into(), "does-not-exist-xyz".into()];
        let folders = folders_from_args(&args, "C:\\");
        assert_eq!(folders.len(), 1);
        assert!(folders[0].starts_with(cwd.trim_end_matches('\\')));
    }
}
