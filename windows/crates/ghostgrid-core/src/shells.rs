//! The shells a Windows pane can start, where each is found, and how each
//! is launched so it reports its prompt, folder and command lines to
//! ghostgrid (see [`hooks`]).

use crate::paths;
use crate::protocol::SessionLaunch;
use serde::ser::SerializeStruct;
use serde::{Serialize, Serializer};
use std::collections::BTreeMap;

pub mod hooks;

pub use crate::paths::{from_wsl_path, to_wsl_path};

/// A shell a new pane can start, and where it was found.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShellChoice {
    /// Stable name, saved in sessions and settings ("pwsh", "wsl", ...).
    pub name: String,
    /// What the menu shows ("PowerShell 7").
    pub title: String,
    /// The key that picks it in the pane's shell menu ("1", "2", ...).
    pub hotkey: String,
    /// Absolute path of the executable, or None when it is not installed.
    pub executable: Option<String>,
}

impl ShellChoice {
    pub fn is_installed(&self) -> bool {
        self.executable.is_some()
    }
}

impl Serialize for ShellChoice {
    /// camelCase, with `isInstalled` for the menu.
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut s = serializer.serialize_struct("ShellChoice", 5)?;
        s.serialize_field("name", &self.name)?;
        s.serialize_field("title", &self.title)?;
        s.serialize_field("hotkey", &self.hotkey)?;
        s.serialize_field("executable", &self.executable)?;
        s.serialize_field("isInstalled", &self.is_installed())?;
        s.end()
    }
}

/// The shells offered in every new pane, in menu order.
const CATALOG: [(&str, &str); 6] = [
    ("pwsh", "PowerShell 7"),
    ("cmd", "Command Prompt"),
    ("gitbash", "Git Bash"),
    ("wsl", "WSL"),
    ("nushell", "nushell"),
    ("powershell", "Windows PowerShell"),
];

/// Candidate locations for `name`, best first. Installers' own locations
/// come before PATH, which an app started from Explorer may see stale.
/// Git Bash is never looked up on PATH: `System32\bash.exe` is WSL's.
fn candidates(name: &str, env: &dyn Fn(&str) -> Option<String>) -> Vec<String> {
    let var = |key: &str| env(key).filter(|v| !v.is_empty());
    let system_root = || var("SystemRoot").or_else(|| var("windir"));
    let under = |base: Option<String>, sub: &str| base.map(|b| paths::in_folder(&b, sub));
    let on_path = |exe: &str| -> Vec<Option<String>> {
        crate::launcher::path_entries(env)
            .into_iter()
            .map(|dir| Some(paths::in_folder(&dir, exe)))
            .collect()
    };
    let list: Vec<Option<String>> = match name {
        "pwsh" => {
            let mut list = vec![
                under(var("ProgramFiles"), "PowerShell\\7\\pwsh.exe"),
                under(var("LOCALAPPDATA"), "Microsoft\\WindowsApps\\pwsh.exe"),
            ];
            list.extend(on_path("pwsh.exe"));
            list
        }
        "cmd" => vec![under(system_root(), "System32\\cmd.exe")],
        "gitbash" => vec![
            under(var("ProgramFiles"), "Git\\bin\\bash.exe"),
            under(var("LOCALAPPDATA"), "Programs\\Git\\bin\\bash.exe"),
            under(
                var("USERPROFILE"),
                "scoop\\apps\\git\\current\\bin\\bash.exe",
            ),
        ],
        "wsl" => vec![under(system_root(), "System32\\wsl.exe")],
        "nushell" => {
            let mut list = vec![
                under(var("USERPROFILE"), ".cargo\\bin\\nu.exe"),
                under(var("LOCALAPPDATA"), "Programs\\nu\\bin\\nu.exe"),
                under(var("ProgramFiles"), "nu\\bin\\nu.exe"),
            ];
            list.extend(on_path("nu.exe"));
            list
        }
        "powershell" => vec![under(
            system_root(),
            "System32\\WindowsPowerShell\\v1.0\\powershell.exe",
        )],
        _ => Vec::new(),
    };
    list.into_iter().flatten().collect()
}

/// Every shell in menu order, each with where it was found. `env` reads
/// an environment variable; `is_file` checks a path on disk.
pub fn resolve(
    env: &dyn Fn(&str) -> Option<String>,
    is_file: &dyn Fn(&str) -> bool,
) -> Vec<ShellChoice> {
    CATALOG
        .iter()
        .enumerate()
        .map(|(index, (name, title))| ShellChoice {
            name: name.to_string(),
            title: title.to_string(),
            hotkey: (index + 1).to_string(),
            executable: candidates(name, env).into_iter().find(|path| is_file(path)),
        })
        .collect()
}

/// The shell remembered from the last menu pick, if it is still
/// installed; None means show the menu instead.
pub fn remembered<'a>(name: Option<&str>, choices: &'a [ShellChoice]) -> Option<&'a ShellChoice> {
    let name = name?;
    choices.iter().find(|c| c.name == name && c.is_installed())
}

/// The installed choice a key press selects, if any.
pub fn choice_for_key<'a>(key: &str, choices: &'a [ShellChoice]) -> Option<&'a ShellChoice> {
    choices.iter().find(|c| c.hotkey == key && c.is_installed())
}

/// What a launch needs besides the shell.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LaunchResources {
    /// Where [`hooks::install`] wrote the hook files (a Windows path).
    pub hooks_dir: String,
    /// false when the Ghostty config says `shell-integration = none`.
    pub integration: bool,
}

/// Windows environment names ignore case: the value of `key` however the
/// base environment spells it.
fn get_env<'a>(env: &'a BTreeMap<String, String>, key: &str) -> Option<&'a str> {
    env.iter()
        .find(|(k, _)| k.eq_ignore_ascii_case(key))
        .map(|(_, v)| v.as_str())
}

/// Sets `key`, replacing it however it was spelled, so the shell sees one.
fn set_env(env: &mut BTreeMap<String, String>, key: &str, value: impl Into<String>) {
    env.retain(|k, _| !k.eq_ignore_ascii_case(key));
    env.insert(key.to_string(), value.into());
}

/// Variables a WSL shell gets from Windows (WSLENV's `/u`: Windows to
/// Linux only).
const WSLENV_SHARED: &str =
    "GHOSTGRID/u:GHOSTGRID_SHELL/u:GHOSTGRID_SESSION/u:TERM_PROGRAM/u:COLORTERM/u";

/// A single-quoted POSIX shell word.
fn sh_quote(text: &str) -> String {
    format!("'{}'", text.replace('\'', "'\\''"))
}

/// The script WSL's `sh -lc` runs: the user's login shell, through
/// ghostgrid's hooks (zsh via ZDOTDIR, bash via --rcfile); any other
/// shell starts plain.
fn wsl_script(wsl_hooks: &str) -> String {
    let zdotdir = sh_quote(&format!("{wsl_hooks}/zsh"));
    let rcfile = sh_quote(&format!("{wsl_hooks}/bash/ghostgrid.bash"));
    format!(
        ": \"${{SHELL:=/bin/sh}}\"\n\
         case \"${{SHELL##*/}}\" in\n\
         zsh)\n    \
             if [ -n \"${{ZDOTDIR+x}}\" ]; then export GHOSTGRID_ZDOTDIR=\"$ZDOTDIR\"; else unset GHOSTGRID_ZDOTDIR; fi\n    \
             export ZDOTDIR={zdotdir}\n    \
             exec \"$SHELL\" -l ;;\n\
         bash)\n    \
             exec \"$SHELL\" --rcfile {rcfile} -i ;;\n\
         *)\n    \
             exec \"$SHELL\" -l ;;\n\
         esac\n"
    )
}

/// The folder a Windows shell can start in: a Windows path as is, a WSL
/// `/mnt/<drive>` path mapped back, nothing else (a folder inside WSL is
/// not one Windows can start a process in).
fn windows_folder(cwd: &str) -> Option<String> {
    if paths::is_windows_folder(cwd) {
        Some(cwd.to_string())
    } else {
        paths::from_wsl_path(cwd)
    }
}

/// How sessiond starts `shell` for pane `id` in `cwd`: ghostgrid's
/// environment on top of `base_env`, and with integration each shell's
/// prompt marks (OSC 133), folder (OSC 7 / 9;9) and command-line report
/// (OSC 633;E). None when the shell is not installed.
pub fn launch(
    id: &str,
    shell: &ShellChoice,
    base_env: &BTreeMap<String, String>,
    resources: &LaunchResources,
    cwd: Option<&str>,
) -> Option<SessionLaunch> {
    let executable = shell.executable.clone()?;
    let mut env = base_env.clone();
    set_env(&mut env, "TERM", "xterm-256color");
    set_env(&mut env, "COLORTERM", "truecolor");
    set_env(&mut env, "TERM_PROGRAM", "ghostgrid");
    set_env(&mut env, "TERM_PROGRAM_VERSION", env!("CARGO_PKG_VERSION"));
    set_env(&mut env, "GHOSTGRID", "1");
    set_env(&mut env, "GHOSTGRID_SHELL", shell.name.as_str());
    set_env(&mut env, "GHOSTGRID_SESSION", id);

    let hooks = resources.hooks_dir.trim_end_matches(paths::is_separator);
    let integration = resources.integration;
    let mut working_directory = cwd.and_then(windows_folder);
    let exe = executable.clone();
    let arguments: Vec<String> = match shell.name.as_str() {
        "pwsh" | "powershell" => {
            if integration {
                let script = format!("{hooks}\\pwsh\\ghostgrid.ps1").replace('\'', "''");
                vec![
                    exe,
                    "-NoLogo".into(),
                    "-NoExit".into(),
                    "-Command".into(),
                    format!(". '{script}'"),
                ]
            } else {
                vec![exe, "-NoLogo".into()]
            }
        }
        "cmd" => {
            if integration {
                // cmd has no hooks; its prompt can carry the marks. $e is
                // ESC and `$e\` the string terminator; $P the folder.
                let user = get_env(&env, "PROMPT")
                    .filter(|p| !p.is_empty())
                    .unwrap_or("$P$G")
                    .to_string();
                if !user.contains("$e]133;") {
                    set_env(
                        &mut env,
                        "PROMPT",
                        format!("$e]133;D$e\\$e]133;A$e\\$e]9;9;$P$e\\{user}$e]133;B$e\\"),
                    );
                }
            }
            vec![exe]
        }
        "gitbash" => {
            // Git Bash's profile cds home unless CHERE_INVOKING is set.
            set_env(&mut env, "CHERE_INVOKING", "1");
            if get_env(&env, "MSYSTEM").is_none_or(str::is_empty) {
                set_env(&mut env, "MSYSTEM", "MINGW64");
            }
            if integration {
                let rcfile = format!("{}/bash/ghostgrid.bash", hooks.replace('\\', "/"));
                vec![exe, "--rcfile".into(), rcfile, "-i".into()]
            } else {
                vec![exe, "--login".into(), "-i".into()]
            }
        }
        "wsl" => {
            let shared = match get_env(&env, "WSLENV").filter(|v| !v.is_empty()) {
                Some(existing) if existing.contains("GHOSTGRID_SESSION") => existing.to_string(),
                Some(existing) => format!("{existing}:{WSLENV_SHARED}"),
                None => WSLENV_SHARED.to_string(),
            };
            set_env(&mut env, "WSLENV", shared);
            // wsl --cd takes Windows and Linux folders alike; the process
            // itself can only start in a Windows one.
            working_directory = cwd
                .filter(|c| paths::is_windows_folder(c))
                .map(String::from);
            let cd = cwd.unwrap_or("~").to_string();
            if integration {
                vec![
                    exe,
                    "--cd".into(),
                    cd,
                    "-e".into(),
                    "sh".into(),
                    "-lc".into(),
                    wsl_script(&to_wsl_path(hooks)),
                ]
            } else {
                vec![exe, "--cd".into(), cd]
            }
        }
        // nushell emits its own OSC 133, 7 and 9;9.
        "nushell" => vec![exe, "-l".into()],
        _ => vec![exe],
    };

    Some(SessionLaunch {
        id: id.to_string(),
        executable,
        arguments,
        environment: env,
        working_directory,
        columns: 80,
        rows: 24,
    })
}
