//! Starting ghostgrid-sessiond and opening connections to it.
//!
//! The helper runs from a versioned copy of itself in
//! `%LOCALAPPDATA%\ghostgrid\bin`, not from the install folder: a running
//! exe cannot be replaced, and the helper outlives the app across updates
//! (the installer must be free to replace the bundled one). It is started
//! detached, outside the app's job and console, so ending the app does not
//! end it.

use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

use ghostgrid_core::protocol::{FrameDecoder, SessionMessage, PROTOCOL_VERSION};
use ghostgrid_sessiond::pipe;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::windows::named_pipe::NamedPipeClient;

use crate::paths;

const DETACHED_PROCESS: u32 = 0x0000_0008;
const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
const CREATE_BREAKAWAY_FROM_JOB: u32 = 0x0100_0000;
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

pub struct Helper {
    pub pipe: String,
}

impl Helper {
    pub fn new() -> std::io::Result<Helper> {
        Ok(Helper { pipe: pipe::pipe_name()? })
    }

    /// A greeted connection, starting the helper first if it is not
    /// running. Errors when it cannot be started (panes then run their
    /// shells in the app).
    pub async fn connect(&self) -> Result<Connection, String> {
        if let Ok(connection) = self.try_connect().await {
            return Ok(connection);
        }
        self.start()?;
        for _ in 0..60 {
            tokio::time::sleep(Duration::from_millis(50)).await;
            if let Ok(connection) = self.try_connect().await {
                return Ok(connection);
            }
        }
        Err("the session helper did not start".into())
    }

    /// A connection only if the helper is already running (no start).
    pub async fn try_connect(&self) -> Result<Connection, String> {
        let client = pipe::connect(&self.pipe, Duration::from_secs(2)).await.map_err(|e| e.to_string())?;
        let mut connection = Connection { client, decoder: FrameDecoder::new(), pending: Vec::new() };
        connection.send(&SessionMessage::Hello { version: PROTOCOL_VERSION }).await?;
        match connection.receive().await? {
            SessionMessage::Welcome { .. } => Ok(connection),
            SessionMessage::Failure(message) => Err(message),
            other => Err(format!("unexpected greeting {other:?}")),
        }
    }

    fn start(&self) -> Result<(), String> {
        let exe = installed_copy().map_err(|e| format!("helper copy: {e}"))?;
        std::fs::create_dir_all(paths::logs_dir()).ok();
        let log = paths::logs_dir().join("sessiond.log");
        let mut command = Command::new(&exe);
        command.arg("--pipe").arg(&self.pipe).arg("--log").arg(&log).current_dir(paths::home());
        let flags = DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW;
        // Leave the app's job when allowed (a terminal that launched the
        // app may hold it in a job that is killed on exit).
        if command.creation_flags(flags | CREATE_BREAKAWAY_FROM_JOB).spawn().is_ok() {
            return Ok(());
        }
        command.creation_flags(flags).spawn().map(|_| ()).map_err(|e| format!("start {}: {e}", exe.display()))
    }
}

/// The bundled helper next to ghostgrid.exe, copied to
/// `bin\ghostgrid-sessiond-<version>.exe` (refreshed when the bundled one
/// changed size or is newer, so a dev build picks up a rebuilt helper).
fn installed_copy() -> std::io::Result<PathBuf> {
    let bundled = bundled_helper()?;
    let target = paths::bin_dir().join(format!("ghostgrid-sessiond-{}.exe", env!("CARGO_PKG_VERSION")));
    let stale = match (std::fs::metadata(&bundled), std::fs::metadata(&target)) {
        (Ok(source), Ok(copy)) => {
            source.len() != copy.len() || source.modified().ok() > copy.modified().ok()
        }
        _ => true,
    };
    if stale {
        std::fs::create_dir_all(paths::bin_dir())?;
        // A running copy cannot be overwritten; it is the same version,
        // so keep using it.
        if let Err(e) = std::fs::copy(&bundled, &target) {
            if !target.exists() {
                return Err(e);
            }
        }
    }
    Ok(target)
}

fn bundled_helper() -> std::io::Result<PathBuf> {
    let exe = std::env::current_exe()?;
    let dir = exe.parent().unwrap_or(Path::new("."));
    for name in ["ghostgrid-sessiond.exe", "ghostgrid-sessiond-x86_64-pc-windows-msvc.exe"] {
        let candidate = dir.join(name);
        if candidate.exists() {
            return Ok(candidate);
        }
    }
    Err(std::io::Error::new(std::io::ErrorKind::NotFound, "ghostgrid-sessiond.exe is not next to ghostgrid.exe"))
}

/// One greeted pipe connection, carrying one pane's session.
pub struct Connection {
    client: NamedPipeClient,
    decoder: FrameDecoder,
    pending: Vec<SessionMessage>,
}

impl Connection {
    pub async fn send(&mut self, message: &SessionMessage) -> Result<(), String> {
        self.client.write_all(&message.encode()).await.map_err(|e| e.to_string())
    }

    pub async fn receive(&mut self) -> Result<SessionMessage, String> {
        let mut buffer = vec![0u8; 64 * 1024];
        loop {
            if !self.pending.is_empty() {
                return Ok(self.pending.remove(0));
            }
            let n = self.client.read(&mut buffer).await.map_err(|e| e.to_string())?;
            if n == 0 {
                return Err("the session helper closed the connection".into());
            }
            self.pending.extend(self.decoder.push(&buffer[..n]));
            if self.decoder.is_broken() {
                return Err("the session helper sent a malformed frame".into());
            }
        }
    }

    /// The pipe, split for a reader task and a writer task.
    pub fn into_parts(self) -> (NamedPipeClient, FrameDecoder, Vec<SessionMessage>) {
        (self.client, self.decoder, self.pending)
    }
}
