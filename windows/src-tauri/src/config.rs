//! The user's Ghostty config, as ghostgrid on Windows reads it: found where
//! Ghostty looks for it, flattened (includes inlined), and turned into what
//! xterm.js needs. Everything about how terminals look stays in that file.

use std::path::{Path, PathBuf};

use ghostgrid_core::config::{self, terminal, ConfigValues};
use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TerminalConfig {
    /// The entry file in use, or where a new one would go.
    pub path: String,
    pub exists: bool,
    pub error: Option<String>,
    pub settings: terminal::TerminalSettings,
}

pub fn default_path() -> PathBuf {
    crate::paths::home().join(".config").join("ghostty").join("config")
}

fn theme_dirs(config_path: &Path) -> Vec<PathBuf> {
    let mut dirs = Vec::new();
    if let Some(parent) = config_path.parent() {
        dirs.push(parent.join("themes"));
    }
    // Bundled with ghostgrid (resources\themes next to the exe).
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            dirs.push(dir.join("themes"));
            dirs.push(dir.join("resources").join("themes"));
        }
    }
    // Running from a source checkout (`tauri dev`).
    dirs.push(PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..").join("resources").join("themes"));
    dirs
}

/// Reads and maps the config; a missing or broken file gives the defaults
/// and says why.
pub fn load() -> TerminalConfig {
    let env = |key: &str| std::env::var(key).ok();
    let exists = |path: &Path| path.is_file();
    let found = config::find_config(&env, &exists);
    let path = found.clone().unwrap_or_else(default_path);
    let (text, error) = match &found {
        Some(path) => match config::flatten(path) {
            Ok(text) => (text, None),
            Err(e) => (String::new(), Some(e.to_string())),
        },
        None => (String::new(), None),
    };
    let values = ConfigValues::new(&text);
    let dirs = theme_dirs(&path);
    let read = |p: &Path| std::fs::read_to_string(p).ok();
    let theme_text = |name: &str| config::theme_lookup(name, &dirs, &read);
    let settings = terminal::settings(&values, &theme_text);
    TerminalConfig { path: path.display().to_string(), exists: found.is_some(), error, settings }
}

/// The config file, created empty (with a pointer to the docs) when there
/// is none yet, so Open always has something to open.
pub fn ensure_exists(path: &Path) -> std::io::Result<()> {
    if path.exists() {
        return Ok(());
    }
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(
        path,
        "# Ghostty config, read by ghostgrid (https://ghostty.org/docs/config).\n# theme = Catppuccin Mocha\n# font-family = JetBrains Mono\n# font-size = 13\n",
    )
}
