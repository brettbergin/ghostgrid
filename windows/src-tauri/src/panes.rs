//! Every pane's shell, as the app sees it: a connection to the session
//! helper (or, when the helper cannot start, a ConPTY of the app's own),
//! the pane's command blocks, and the window the pane is showing in.
//!
//! Panes are keyed by their session ID, which is also the helper's name for
//! the shell, so a pane moving to another window, or a relaunch, attaches
//! to the same shell by the same ID.

use std::collections::{BTreeMap, HashMap};
use std::io::{Read, Write};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use ghostgrid_core::blocks::{BlockView, CommandBlockParser, StreamEvent};
use ghostgrid_core::history::OutputHistory;
use ghostgrid_core::protocol::{SessionLaunch, SessionMessage};
use ghostgrid_core::shells;
use portable_pty::{native_pty_system, ChildKiller, CommandBuilder, MasterPty, PtySize};
use serde::{Deserialize, Serialize};
use serde_json::json;
use tauri::ipc::{Channel, InvokeResponseBody};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::mpsc;

use crate::helper::Helper;

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PaneSpec {
    /// The shell to attach to (a kept shell, or a pane moving between
    /// windows); nil starts a new one.
    pub session_id: Option<String>,
    /// A ShellChoice name ("pwsh", "cmd", ...).
    pub shell: String,
    pub cwd: Option<String>,
    pub cols: u16,
    pub rows: u16,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PaneOpened {
    pub session_id: String,
    /// It came back to a shell that was already running.
    pub reattached: bool,
    /// The shell runs in the app, not the helper (it ends with the app).
    pub local: bool,
}

struct Sink {
    data: Channel<InvokeResponseBody>,
    events: Channel<serde_json::Value>,
}

enum Backend {
    None,
    Remote(mpsc::UnboundedSender<SessionMessage>),
    Local(Arc<LocalPty>),
}

pub struct Pane {
    pub id: String,
    pub shell: String,
    window: Mutex<String>,
    sink: Mutex<Option<Sink>>,
    parser: Mutex<CommandBlockParser>,
    cwd: Mutex<Option<String>>,
    backend: Mutex<Backend>,
    /// Bumped on every attach, so a superseded connection stops delivering.
    generation: AtomicU64,
}

impl Pane {
    fn new(id: String, shell: String, window: String, cwd: Option<String>) -> Pane {
        Pane {
            id,
            shell,
            window: Mutex::new(window),
            sink: Mutex::new(None),
            parser: Mutex::new(CommandBlockParser::new()),
            cwd: Mutex::new(cwd),
            backend: Mutex::new(Backend::None),
            generation: AtomicU64::new(0),
        }
    }

    pub fn window(&self) -> String {
        self.window.lock().unwrap().clone()
    }

    pub fn cwd(&self) -> Option<String> {
        self.cwd.lock().unwrap().clone()
    }

    fn event(&self, value: serde_json::Value) {
        if let Some(sink) = self.sink.lock().unwrap().as_ref() {
            let _ = sink.events.send(value);
        }
    }

    /// Live output: parsed for blocks and marks, then shown.
    fn deliver(&self, data: Vec<u8>) {
        let events = self.parser.lock().unwrap().feed(&data, false);
        self.send_data(data);
        for event in events {
            self.stream_event(event);
        }
    }

    /// A reattach's replay of earlier output: the screen is rebuilt and the
    /// blocks with it, without timing (it would be the replay's).
    fn deliver_replay(&self, data: Vec<u8>) {
        let events = {
            let mut parser = self.parser.lock().unwrap();
            parser.reset();
            parser.feed(&data, true)
        };
        self.send_data(data);
        for event in events {
            self.stream_event(event);
        }
        self.event(json!({ "type": "blocksChanged" }));
    }

    fn send_data(&self, data: Vec<u8>) {
        if let Some(sink) = self.sink.lock().unwrap().as_ref() {
            let _ = sink.data.send(InvokeResponseBody::Raw(data));
        }
    }

    fn stream_event(&self, event: StreamEvent) {
        match event {
            StreamEvent::CommandStarted { block } => {
                self.event(json!({ "type": "commandStarted", "block": block }));
            }
            StreamEvent::CommandFinished { block, exit_code, seconds, command } => {
                self.event(json!({
                    "type": "commandFinished", "block": block, "exitCode": exit_code,
                    "seconds": seconds, "command": command,
                }));
            }
            StreamEvent::WorkingDirectory(path) => {
                *self.cwd.lock().unwrap() = Some(path.clone());
                self.event(json!({ "type": "cwd", "path": path }));
            }
            StreamEvent::Notification { title, body } => {
                self.event(json!({ "type": "notification", "title": title, "body": body }));
            }
        }
    }

    pub fn blocks(&self) -> Vec<BlockView> {
        self.parser.lock().unwrap().blocks().iter().map(|b| b.view()).collect()
    }

    /// The command line, output and exit code of block `id`.
    pub fn block(&self, id: u64) -> Option<(Option<String>, String, Option<i32>)> {
        let parser = self.parser.lock().unwrap();
        parser.blocks().iter().find(|b| b.id == id).map(|b| (b.command.clone(), b.output(), b.exit_code))
    }

    fn send(&self, message: SessionMessage) {
        match &*self.backend.lock().unwrap() {
            Backend::Remote(tx) => {
                let _ = tx.send(message);
            }
            Backend::Local(local) => match message {
                SessionMessage::Input(data) => local.input(&data),
                SessionMessage::Resize { columns, rows, width, height } => local.resize(columns, rows, width, height),
                SessionMessage::Terminate => local.terminate(),
                _ => {}
            },
            Backend::None => {}
        }
    }
}

/// A shell run by the app itself when the helper is not available.
struct LocalPty {
    writer: Mutex<Box<dyn Write + Send>>,
    master: Mutex<Option<Box<dyn MasterPty + Send>>>,
    killer: Mutex<Box<dyn ChildKiller + Send + Sync>>,
    history: Mutex<OutputHistory>,
}

impl LocalPty {
    fn input(&self, data: &[u8]) {
        let mut writer = self.writer.lock().unwrap();
        let _ = writer.write_all(data).and_then(|_| writer.flush());
    }

    fn resize(&self, columns: u16, rows: u16, width: u16, height: u16) {
        if let Some(master) = self.master.lock().unwrap().as_ref() {
            let _ = master.resize(PtySize { rows: rows.max(1), cols: columns.max(1), pixel_width: width, pixel_height: height });
        }
    }

    fn terminate(&self) {
        let _ = self.killer.lock().unwrap().kill();
    }
}

pub struct PaneManager {
    panes: Mutex<HashMap<String, Arc<Pane>>>,
    helper: Option<Helper>,
    /// The helper could not be started once: later panes go local at once
    /// instead of waiting for it again.
    helper_failed: AtomicBool,
    pub hooks_dir: String,
    pub integration: Mutex<bool>,
}

impl PaneManager {
    pub fn new(hooks_dir: String) -> PaneManager {
        PaneManager {
            panes: Mutex::new(HashMap::new()),
            helper: Helper::new().ok(),
            helper_failed: AtomicBool::new(false),
            hooks_dir,
            integration: Mutex::new(true),
        }
    }

    pub fn get(&self, id: &str) -> Option<Arc<Pane>> {
        self.panes.lock().unwrap().get(id).cloned()
    }

    pub fn all(&self) -> Vec<Arc<Pane>> {
        self.panes.lock().unwrap().values().cloned().collect()
    }

    fn launch(&self, id: &str, spec: &PaneSpec) -> Result<SessionLaunch, String> {
        let env = |key: &str| std::env::var(key).ok();
        let is_file = |path: &str| std::path::Path::new(path).is_file();
        let choices = shells::resolve(&env, &is_file);
        let choice = choices
            .iter()
            .find(|c| c.name == spec.shell && c.executable.is_some())
            .ok_or_else(|| format!("{} is not installed", spec.shell))?;
        let base: BTreeMap<String, String> = std::env::vars().collect();
        let resources = shells::LaunchResources { hooks_dir: self.hooks_dir.clone(), integration: *self.integration.lock().unwrap() };
        let mut launch = shells::launch(id, choice, &base, &resources, spec.cwd.as_deref())
            .ok_or_else(|| format!("cannot start {}", spec.shell))?;
        launch.columns = spec.cols.max(2);
        launch.rows = spec.rows.max(1);
        Ok(launch)
    }

    pub async fn open(
        self: &Arc<Self>,
        window: String,
        spec: PaneSpec,
        data: Channel<InvokeResponseBody>,
        events: Channel<serde_json::Value>,
    ) -> Result<PaneOpened, String> {
        // A pane this app already runs (moving between windows): show it
        // here and replay its screen.
        if let Some(pane) = spec.session_id.as_deref().and_then(|id| self.get(id)) {
            *pane.window.lock().unwrap() = window;
            *pane.sink.lock().unwrap() = Some(Sink { data, events });
            let local = matches!(&*pane.backend.lock().unwrap(), Backend::Local(_));
            if local {
                let replay = match &*pane.backend.lock().unwrap() {
                    Backend::Local(l) => l.history.lock().unwrap().replay(),
                    _ => Vec::new(),
                };
                pane.deliver_replay(replay);
            } else {
                self.connect_remote(&pane, SessionMessage::Attach { id: pane.id.clone() }, None).await?;
            }
            pane.send(SessionMessage::Resize { columns: spec.cols, rows: spec.rows, width: 0, height: 0 });
            return Ok(PaneOpened { session_id: pane.id.clone(), reattached: true, local });
        }

        let id = spec.session_id.clone().unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
        let launch = self.launch(&id, &spec)?;
        let pane = Arc::new(Pane::new(id.clone(), spec.shell.clone(), window, spec.cwd.clone()));
        *pane.sink.lock().unwrap() = Some(Sink { data, events });
        self.panes.lock().unwrap().insert(id.clone(), pane.clone());

        if self.helper.is_some() && !self.helper_failed.load(Ordering::SeqCst) {
            let first = match spec.session_id {
                // A kept shell from the last run, or a fresh one in its folder.
                Some(_) => SessionMessage::Attach { id: id.clone() },
                None => SessionMessage::Create(launch.clone()),
            };
            match self.connect_remote(&pane, first, Some(launch.clone())).await {
                Ok(reattached) => return Ok(PaneOpened { session_id: id, reattached, local: false }),
                Err(error) => {
                    eprintln!("ghostgrid: session helper unavailable ({error}); running the shell in the app");
                    self.helper_failed.store(true, Ordering::SeqCst);
                }
            }
        }
        match self.spawn_local(&pane, &launch) {
            Ok(()) => Ok(PaneOpened { session_id: id, reattached: false, local: true }),
            Err(error) => {
                self.panes.lock().unwrap().remove(&id);
                Err(error)
            }
        }
    }

    /// Attaches `pane` to its shell in the helper over a new connection.
    /// An Attach for a shell that is gone falls back to `create`. Returns
    /// whether it attached to a shell that was already running.
    async fn connect_remote(self: &Arc<Self>, pane: &Arc<Pane>, first: SessionMessage, create: Option<SessionLaunch>) -> Result<bool, String> {
        let helper = self.helper.as_ref().ok_or("no session helper")?;
        let mut connection = helper.connect().await?;
        let mut attaching = matches!(first, SessionMessage::Attach { .. });
        connection.send(&first).await?;
        let replay = loop {
            match connection.receive().await? {
                SessionMessage::Attached { replay, .. } => break replay,
                SessionMessage::Failure(_) if attaching && create.is_some() => {
                    attaching = false;
                    connection.send(&SessionMessage::Create(create.clone().unwrap())).await?;
                }
                SessionMessage::Failure(message) => return Err(message),
                _ => {}
            }
        };
        let generation = pane.generation.fetch_add(1, Ordering::SeqCst) + 1;
        let reattached = attaching;
        // A fresh shell's "replay" is just the reset; a kept one's rebuilds
        // its screen.
        pane.deliver_replay(replay);

        let (client, mut decoder, pending) = connection.into_parts();
        let (tx, mut rx) = mpsc::unbounded_channel::<SessionMessage>();
        *pane.backend.lock().unwrap() = Backend::Remote(tx);
        let manager = self.clone();
        let pane = pane.clone();
        tauri::async_runtime::spawn(async move {
            let (mut reader, mut writer) = tokio::io::split(client);
            let writing = async {
                while let Some(message) = rx.recv().await {
                    if writer.write_all(&message.encode()).await.is_err() {
                        break;
                    }
                }
            };
            let reading = async {
                let mut queue = pending;
                let mut buffer = vec![0u8; 64 * 1024];
                loop {
                    for message in queue.drain(..) {
                        if pane.generation.load(Ordering::SeqCst) != generation {
                            return;
                        }
                        match message {
                            SessionMessage::Output(data) => pane.deliver(data),
                            SessionMessage::Exited { code } => {
                                manager.ended(&pane, code);
                                return;
                            }
                            SessionMessage::Failure(message) if message == "attached elsewhere" => return,
                            SessionMessage::Failure(message) => pane.event(json!({ "type": "failure", "message": message })),
                            _ => {}
                        }
                    }
                    let n = match reader.read(&mut buffer).await {
                        Ok(0) | Err(_) => break,
                        Ok(n) => n,
                    };
                    queue = decoder.push(&buffer[..n]);
                    if decoder.is_broken() {
                        break;
                    }
                }
                // The helper went away under a live pane.
                if pane.generation.load(Ordering::SeqCst) == generation {
                    pane.event(json!({ "type": "failure", "message": "lost the connection to the session helper" }));
                }
            };
            tokio::select! {
                _ = writing => {},
                _ = reading => {},
            }
        });
        Ok(reattached)
    }

    fn spawn_local(self: &Arc<Self>, pane: &Arc<Pane>, launch: &SessionLaunch) -> Result<(), String> {
        let size = PtySize { rows: launch.rows, cols: launch.columns, pixel_width: 0, pixel_height: 0 };
        let pair = native_pty_system().openpty(size).map_err(|e| e.to_string())?;
        let mut command = CommandBuilder::new(&launch.executable);
        if launch.arguments.len() > 1 {
            command.args(&launch.arguments[1..]);
        }
        command.env_clear();
        for (key, value) in &launch.environment {
            command.env(key, value);
        }
        if let Some(dir) = launch.working_directory.as_deref().filter(|d| std::path::Path::new(d).is_dir()) {
            command.cwd(dir);
        }
        let mut child = pair.slave.spawn_command(command).map_err(|e| format!("could not start {}: {e}", launch.executable))?;
        drop(pair.slave);
        let mut reader = pair.master.try_clone_reader().map_err(|e| e.to_string())?;
        let writer = pair.master.take_writer().map_err(|e| e.to_string())?;
        let local = Arc::new(LocalPty {
            writer: Mutex::new(writer),
            master: Mutex::new(Some(pair.master)),
            killer: Mutex::new(child.clone_killer()),
            history: Mutex::new(OutputHistory::new()),
        });
        *pane.backend.lock().unwrap() = Backend::Local(local.clone());
        pane.deliver_replay(b"\x1bc".to_vec());

        let reading = pane.clone();
        let history = local.clone();
        std::thread::spawn(move || {
            let mut buffer = vec![0u8; 64 * 1024];
            while let Ok(n) = reader.read(&mut buffer) {
                if n == 0 {
                    break;
                }
                history.history.lock().unwrap().append(&buffer[..n]);
                reading.deliver(buffer[..n].to_vec());
            }
        });
        let manager = self.clone();
        let waiting = pane.clone();
        std::thread::spawn(move || {
            let code = child.wait().map(|s| s.exit_code() as i32).unwrap_or(-1);
            std::thread::sleep(std::time::Duration::from_millis(200));
            if let Backend::Local(local) = &*waiting.backend.lock().unwrap() {
                local.master.lock().unwrap().take();
            }
            manager.ended(&waiting, code);
        });
        Ok(())
    }

    fn ended(&self, pane: &Arc<Pane>, code: i32) {
        pane.event(json!({ "type": "exited", "code": code }));
        let mut panes = self.panes.lock().unwrap();
        if panes.get(&pane.id).is_some_and(|p| Arc::ptr_eq(p, pane)) {
            panes.remove(&pane.id);
        }
    }

    pub fn input(&self, id: &str, data: Vec<u8>) {
        if let Some(pane) = self.get(id) {
            pane.send(SessionMessage::Input(data));
        }
    }

    pub fn resize(&self, id: &str, columns: u16, rows: u16, width: u16, height: u16) {
        if let Some(pane) = self.get(id) {
            pane.send(SessionMessage::Resize { columns, rows, width, height });
        }
    }

    /// Ends the pane's shell (closing a pane, a tab or a window).
    pub fn terminate(&self, id: &str) {
        if let Some(pane) = self.panes.lock().unwrap().remove(id) {
            *pane.sink.lock().unwrap() = None;
            pane.send(SessionMessage::Terminate);
        }
    }

    /// Lets go of the pane without ending its shell: it is moving to
    /// another window, or the app is quitting with shells kept.
    pub fn release(&self, id: &str) {
        if let Some(pane) = self.get(id) {
            *pane.sink.lock().unwrap() = None;
            pane.generation.fetch_add(1, Ordering::SeqCst);
            let mut backend = pane.backend.lock().unwrap();
            if matches!(&*backend, Backend::Remote(_)) {
                // Dropping the sender ends the connection; the shell stays.
                *backend = Backend::None;
            }
        }
    }

    /// Shells kept from an earlier run that no window wants (window-save-state
    /// = never, or keeping shells is off): end them.
    pub async fn end_kept(&self, ids: Vec<String>) {
        let Some(helper) = self.helper.as_ref() else { return };
        for id in ids {
            if let Ok(mut connection) = helper.try_connect().await {
                if connection.send(&SessionMessage::Attach { id }).await.is_ok() {
                    if let Ok(SessionMessage::Attached { .. }) = connection.receive().await {
                        let _ = connection.send(&SessionMessage::Terminate).await;
                    }
                }
            }
        }
    }

    /// Hands a pane to another window (or, with "", to none until a new
    /// window attaches it).
    pub fn move_to_window(&self, id: &str, window: &str) {
        if let Some(pane) = self.get(id) {
            *pane.window.lock().unwrap() = window.to_string();
        }
    }

    pub fn panes_in_window(&self, window: &str) -> Vec<String> {
        self.panes.lock().unwrap().values().filter(|p| p.window() == window).map(|p| p.id.clone()).collect()
    }
}
