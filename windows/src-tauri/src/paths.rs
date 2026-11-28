//! Where ghostgrid keeps its files on Windows.
//!
//! - `%APPDATA%\ghostgrid\settings.json`: ghostgrid's own options (roams).
//! - `%LOCALAPPDATA%\ghostgrid\`: what belongs to this machine: the session
//!   (`session.json`, which names shells running here), the shell hooks,
//!   the helper's copy of itself (`bin\`) and logs (`logs\`).

use std::path::PathBuf;

fn env_dir(key: &str) -> PathBuf {
    std::env::var_os(key).map(PathBuf::from).unwrap_or_else(|| home().join("AppData"))
}

pub fn home() -> PathBuf {
    std::env::var_os("USERPROFILE")
        .or_else(|| std::env::var_os("HOME"))
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("C:\\"))
}

pub fn roaming() -> PathBuf {
    env_dir("APPDATA").join("ghostgrid")
}

pub fn local() -> PathBuf {
    env_dir("LOCALAPPDATA").join("ghostgrid")
}

pub fn settings_file() -> PathBuf {
    roaming().join("settings.json")
}

pub fn session_file() -> PathBuf {
    local().join("session.json")
}

pub fn hooks_dir() -> PathBuf {
    local().join("hooks")
}

pub fn bin_dir() -> PathBuf {
    local().join("bin")
}

pub fn logs_dir() -> PathBuf {
    local().join("logs")
}

/// Writes `contents` to `path` through a temporary file, so a crash never
/// leaves half a file behind.
pub fn write_atomic(path: &std::path::Path, contents: &[u8]) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let temp = path.with_extension("tmp");
    std::fs::write(&temp, contents)?;
    std::fs::rename(&temp, path)
}
