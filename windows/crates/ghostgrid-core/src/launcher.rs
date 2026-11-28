//! The apps offered in a new pane after picking a shell, as the user
//! configures them in Settings, looked up on disk the way Windows finds
//! programs: each folder in turn, each executable extension in turn.

use crate::paths;
use serde::ser::SerializeStruct;
use serde::{Deserialize, Serialize, Serializer};

/// Keys 1-9 pick an app, so the menu holds at most nine.
pub const MAX_ENTRIES: usize = 9;

/// Extensions tried when PATHEXT is not set.
const DEFAULT_EXTENSIONS: [&str; 5] = [".exe", ".cmd", ".bat", ".com", ".ps1"];

/// One app in the launcher, as the user configures it in Settings.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct LauncherEntry {
    /// Made by the caller (the app); stable so Settings can edit in place.
    pub id: String,
    pub name: String,
    /// What gets typed at the prompt: a program, an alias, a function, or
    /// a whole command line (`lazygit -p ~/code/api`).
    pub command: String,
    /// One line shown beside the name.
    #[serde(default)]
    pub summary: String,
    /// The program to look for on disk, when it differs from the command's
    /// first word (the default `y` is a function that runs yazi).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub program: Option<String>,
}

impl LauncherEntry {
    /// The program whose presence is checked: `program`, else the
    /// command's first word.
    pub fn checked_program(&self) -> Option<String> {
        if let Some(program) = self.program.as_ref().filter(|p| !p.is_empty()) {
            return Some(program.clone());
        }
        self.command.split_whitespace().next().map(String::from)
    }
}

/// A launcher entry as the menu shows it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LaunchApp {
    pub name: String,
    /// The key that picks it in the menu ("1" to "9").
    pub hotkey: String,
    /// What gets typed at the prompt to start it. Typed rather than run as
    /// the pane's command, so quitting the app leaves you in the shell, and
    /// the command lands in your history like anything else you run.
    pub command: String,
    pub summary: String,
    /// Where the program was found, or None when it was not (it may still
    /// be an alias or a function, so the entry stays usable; the menu says
    /// so).
    pub executable: Option<String>,
}

impl LaunchApp {
    pub fn is_found(&self) -> bool {
        self.executable.is_some()
    }
}

impl Serialize for LaunchApp {
    /// camelCase, with `isFound` for the menu.
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut s = serializer.serialize_struct("LaunchApp", 6)?;
        s.serialize_field("name", &self.name)?;
        s.serialize_field("hotkey", &self.hotkey)?;
        s.serialize_field("command", &self.command)?;
        s.serialize_field("summary", &self.summary)?;
        s.serialize_field("executable", &self.executable)?;
        s.serialize_field("isFound", &self.is_found())?;
        s.end()
    }
}

/// What Settings starts with (and Reset to Defaults restores).
pub fn defaults() -> Vec<LauncherEntry> {
    let entry = |name: &str, command: &str, summary: &str, program: Option<&str>| LauncherEntry {
        id: format!("default-{name}"),
        name: name.into(),
        command: command.into(),
        summary: summary.into(),
        program: program.map(String::from),
    };
    vec![
        entry(
            "opencode",
            "opencode",
            "coding agent on the local model",
            None,
        ),
        entry("claude", "claude", "Claude Code", None),
        entry("btop", "btop", "system monitor", None),
        entry("lazygit", "lazygit", "git TUI", None),
        // `y` is the dotfiles wrapper: quitting yazi cds the pane there.
        entry(
            "yazi",
            "y",
            "file manager; q leaves you in that folder",
            Some("yazi"),
        ),
    ]
}

/// Whether the file name in `path` already has an extension.
fn has_extension(path: &str) -> bool {
    let name = path.rsplit(paths::is_separator).next().unwrap_or(path);
    name.rfind('.').is_some_and(|dot| dot > 0)
}

use paths::in_folder;

/// Where `program` is: a path (containing `\` or `/`) is checked as is,
/// with each extension when it has none; a bare name in each folder.
fn find(
    program: &str,
    search_dirs: &[String],
    extensions: &[String],
    is_file: &dyn Fn(&str) -> bool,
) -> Option<String> {
    let names: Vec<String> = if has_extension(program) {
        vec![program.to_string()]
    } else {
        extensions
            .iter()
            .map(|ext| format!("{program}{ext}"))
            .collect()
    };
    if program.contains(paths::is_separator) {
        return names.into_iter().find(|candidate| is_file(candidate));
    }
    search_dirs
        .iter()
        .flat_map(|dir| names.iter().map(move |name| in_folder(dir, name)))
        .find(|candidate| is_file(candidate))
}

/// The menu for `entries`: blank commands dropped, at most nine, keys
/// 1-9 in order, each looked up on disk.
pub fn resolve(
    entries: &[LauncherEntry],
    search_dirs: &[String],
    extensions: &[String],
    is_file: &dyn Fn(&str) -> bool,
) -> Vec<LaunchApp> {
    entries
        .iter()
        .filter(|entry| !entry.command.trim().is_empty())
        .take(MAX_ENTRIES)
        .enumerate()
        .map(|(index, entry)| {
            let executable = entry
                .checked_program()
                .and_then(|p| find(&p, search_dirs, extensions, is_file));
            let name = entry.name.trim();
            let command = entry.command.trim();
            LaunchApp {
                name: if name.is_empty() {
                    command.to_string()
                } else {
                    name.to_string()
                },
                hotkey: (index + 1).to_string(),
                command: command.to_string(),
                summary: entry.summary.clone(),
                executable,
            }
        })
        .collect()
}

/// The app a key press selects, if any.
pub fn choice_for_key<'a>(key: &str, apps: &'a [LaunchApp]) -> Option<&'a LaunchApp> {
    apps.iter().find(|app| app.hotkey == key)
}

/// Stored entries (JSON), or the defaults when nothing usable is stored.
pub fn decode(text: Option<&str>) -> Vec<LauncherEntry> {
    text.and_then(|t| serde_json::from_str(t).ok())
        .unwrap_or_else(defaults)
}

pub fn encode(entries: &[LauncherEntry]) -> String {
    serde_json::to_string(entries).unwrap_or_else(|_| "[]".into())
}

/// The folders in PATH (an app started from Explorer has the user's PATH,
/// but an installer may have added to it since), then per-user install
/// locations that are often missing from it: Claude Code's
/// (~\.local\bin), bun's, opencode's, scoop's shims and WinGet's links.
/// Each folder once.
pub fn default_search_dirs(env: &dyn Fn(&str) -> Option<String>) -> Vec<String> {
    let mut dirs: Vec<String> = path_entries(env);
    let set = |key: &str| env(key).filter(|v| !v.is_empty());
    if let Some(profile) = set("USERPROFILE") {
        for sub in [".local\\bin", ".bun\\bin", ".opencode\\bin", "scoop\\shims"] {
            dirs.push(in_folder(&profile, sub));
        }
    }
    if let Some(local) = set("LOCALAPPDATA") {
        dirs.push(in_folder(&local, "Microsoft\\WinGet\\Links"));
    }
    let mut seen: Vec<String> = Vec::new();
    dirs.retain(|dir| {
        let key = dir
            .trim_end_matches(paths::is_separator)
            .to_ascii_lowercase();
        if seen.contains(&key) {
            false
        } else {
            seen.push(key);
            true
        }
    });
    dirs
}

/// PATH's folders, without empty entries or quotes.
pub fn path_entries(env: &dyn Fn(&str) -> Option<String>) -> Vec<String> {
    env("PATH")
        .or_else(|| env("Path"))
        .unwrap_or_default()
        .split(';')
        .map(|entry| entry.trim().trim_matches('"').to_string())
        .filter(|entry| !entry.is_empty())
        .collect()
}

/// PATHEXT's extensions (lowercased), or a sensible set without it.
pub fn default_extensions(env: &dyn Fn(&str) -> Option<String>) -> Vec<String> {
    let from_env: Vec<String> = env("PATHEXT")
        .unwrap_or_default()
        .split(';')
        .map(|ext| ext.trim().to_ascii_lowercase())
        .filter(|ext| !ext.is_empty())
        .collect();
    if from_env.is_empty() {
        DEFAULT_EXTENSIONS.iter().map(|e| e.to_string()).collect()
    } else {
        from_env
    }
}
