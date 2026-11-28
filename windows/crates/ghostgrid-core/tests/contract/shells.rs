//! Contract for the shells a Windows pane can start (ShellCatalogTests,
//! RememberedShellTests, ShellLaunchTests adapted to Windows): where each
//! is looked for, the menu, and how each is launched with ghostgrid's
//! prompt marks.

use crate::support::{git_bash, temp_dir};
use ghostgrid_core::shells::{self, from_wsl_path, to_wsl_path, LaunchResources, ShellChoice};
use std::collections::{BTreeMap, HashMap, HashSet};

fn standard_env() -> HashMap<String, String> {
    [
        ("ProgramFiles", "C:\\Program Files"),
        ("LOCALAPPDATA", "C:\\Users\\me\\AppData\\Local"),
        ("USERPROFILE", "C:\\Users\\me"),
        ("SystemRoot", "C:\\Windows"),
        (
            "PATH",
            "C:\\tools;;\"C:\\quoted dir\";C:\\Windows\\System32",
        ),
    ]
    .into_iter()
    .map(|(k, v)| (k.to_string(), v.to_string()))
    .collect()
}

fn resolve(installed: &[&str]) -> Vec<ShellChoice> {
    let env = standard_env();
    let installed: HashSet<String> = installed.iter().map(|s| s.to_string()).collect();
    shells::resolve(&|key| env.get(key).cloned(), &|path| {
        installed.contains(path)
    })
}

fn executable(choices: &[ShellChoice], name: &str) -> Option<String> {
    choices
        .iter()
        .find(|c| c.name == name)
        .and_then(|c| c.executable.clone())
}

#[test]
fn menu_order_and_hotkeys() {
    let choices = resolve(&[]);
    assert_eq!(
        choices.iter().map(|c| c.name.as_str()).collect::<Vec<_>>(),
        ["pwsh", "cmd", "gitbash", "wsl", "nushell", "powershell"]
    );
    assert_eq!(
        choices
            .iter()
            .map(|c| c.hotkey.as_str())
            .collect::<Vec<_>>(),
        ["1", "2", "3", "4", "5", "6"]
    );
    assert_eq!(
        choices.iter().map(|c| c.title.as_str()).collect::<Vec<_>>(),
        [
            "PowerShell 7",
            "Command Prompt",
            "Git Bash",
            "WSL",
            "nushell",
            "Windows PowerShell"
        ]
    );
}

#[test]
fn missing_shells_are_listed_but_not_installed() {
    let choices = resolve(&[
        "C:\\Windows\\System32\\cmd.exe",
        "C:\\Windows\\System32\\wsl.exe",
    ]);
    assert_eq!(
        choices.iter().map(|c| c.is_installed()).collect::<Vec<_>>(),
        [false, true, false, true, false, false]
    );
}

#[test]
fn system_shells_are_found_under_the_system_root() {
    let choices = resolve(&[
        "C:\\Windows\\System32\\cmd.exe",
        "C:\\Windows\\System32\\wsl.exe",
        "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
    ]);
    assert_eq!(
        executable(&choices, "cmd").as_deref(),
        Some("C:\\Windows\\System32\\cmd.exe")
    );
    assert_eq!(
        executable(&choices, "wsl").as_deref(),
        Some("C:\\Windows\\System32\\wsl.exe")
    );
    assert_eq!(
        executable(&choices, "powershell").as_deref(),
        Some("C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe")
    );
}

#[test]
fn powershell_7_prefers_its_installer_then_the_store_then_path() {
    let all = [
        "C:\\Program Files\\PowerShell\\7\\pwsh.exe",
        "C:\\Users\\me\\AppData\\Local\\Microsoft\\WindowsApps\\pwsh.exe",
        "C:\\tools\\pwsh.exe",
    ];
    assert_eq!(executable(&resolve(&all), "pwsh").as_deref(), Some(all[0]));
    assert_eq!(
        executable(&resolve(&all[1..]), "pwsh").as_deref(),
        Some(all[1])
    );
    assert_eq!(
        executable(&resolve(&all[2..]), "pwsh").as_deref(),
        Some(all[2])
    );
    assert_eq!(
        executable(&resolve(&["C:\\quoted dir\\pwsh.exe"]), "pwsh").as_deref(),
        Some("C:\\quoted dir\\pwsh.exe"),
        "quoted PATH entries"
    );
}

#[test]
fn git_bash_is_never_the_wsl_launcher() {
    let choices = resolve(&["C:\\Windows\\System32\\bash.exe", "C:\\tools\\bash.exe"]);
    assert_eq!(
        executable(&choices, "gitbash"),
        None,
        "System32\\bash.exe is WSL; PATH is not searched"
    );
    let all = [
        "C:\\Program Files\\Git\\bin\\bash.exe",
        "C:\\Users\\me\\AppData\\Local\\Programs\\Git\\bin\\bash.exe",
        "C:\\Users\\me\\scoop\\apps\\git\\current\\bin\\bash.exe",
    ];
    assert_eq!(
        executable(&resolve(&all), "gitbash").as_deref(),
        Some(all[0])
    );
    assert_eq!(
        executable(&resolve(&all[1..]), "gitbash").as_deref(),
        Some(all[1])
    );
    assert_eq!(
        executable(&resolve(&all[2..]), "gitbash").as_deref(),
        Some(all[2])
    );
}

#[test]
fn nushell_prefers_cargo_then_its_installers_then_path() {
    let all = [
        "C:\\Users\\me\\.cargo\\bin\\nu.exe",
        "C:\\Users\\me\\AppData\\Local\\Programs\\nu\\bin\\nu.exe",
        "C:\\Program Files\\nu\\bin\\nu.exe",
        "C:\\tools\\nu.exe",
    ];
    for start in 0..all.len() {
        assert_eq!(
            executable(&resolve(&all[start..]), "nushell").as_deref(),
            Some(all[start])
        );
    }
}

#[test]
fn missing_environment_variables_skip_their_candidates() {
    let choices = shells::resolve(&|_| None, &|_| true);
    assert_eq!(choices.len(), 6);
    assert!(choices.iter().all(|c| !c.is_installed()));
}

#[test]
fn hotkeys_pick_only_installed_shells() {
    let choices = resolve(&[
        "C:\\Windows\\System32\\cmd.exe",
        "C:\\Windows\\System32\\wsl.exe",
    ]);
    assert_eq!(
        shells::choice_for_key("2", &choices).map(|c| c.name.as_str()),
        Some("cmd")
    );
    assert_eq!(
        shells::choice_for_key("4", &choices).map(|c| c.name.as_str()),
        Some("wsl")
    );
    assert!(shells::choice_for_key("1", &choices).is_none());
    assert!(shells::choice_for_key("9", &choices).is_none());
}

#[test]
fn the_remembered_shell_is_used_only_while_installed() {
    let choices = resolve(&[
        "C:\\Windows\\System32\\cmd.exe",
        "C:\\Users\\me\\.cargo\\bin\\nu.exe",
    ]);
    assert_eq!(
        shells::remembered(Some("nushell"), &choices).and_then(|c| c.executable.as_deref()),
        Some("C:\\Users\\me\\.cargo\\bin\\nu.exe")
    );
    assert!(
        shells::remembered(None, &choices).is_none(),
        "nothing remembered means no shortcut"
    );
    assert!(
        shells::remembered(Some("pwsh"), &choices).is_none(),
        "uninstalled: show the menu"
    );
    assert!(shells::remembered(Some("fish"), &choices).is_none());
}

#[test]
fn a_choice_serializes_for_the_menu() {
    let choices = resolve(&["C:\\Windows\\System32\\cmd.exe"]);
    let json = serde_json::to_value(&choices[1]).unwrap();
    assert_eq!(json["name"], "cmd");
    assert_eq!(json["title"], "Command Prompt");
    assert_eq!(json["hotkey"], "2");
    assert_eq!(json["executable"], "C:\\Windows\\System32\\cmd.exe");
    assert_eq!(json["isInstalled"], true);
    assert_eq!(
        serde_json::to_value(&choices[0]).unwrap()["isInstalled"],
        false
    );
}

// Launching

fn shell(name: &str, executable: &str) -> ShellChoice {
    ShellChoice {
        name: name.into(),
        title: name.into(),
        hotkey: "1".into(),
        executable: Some(executable.into()),
    }
}

fn base() -> BTreeMap<String, String> {
    BTreeMap::from([
        ("Path".to_string(), "C:\\Windows\\System32".to_string()),
        ("USERPROFILE".to_string(), "C:\\Users\\me".to_string()),
    ])
}

fn resources(integration: bool) -> LaunchResources {
    LaunchResources {
        hooks_dir: "C:\\H".into(),
        integration,
    }
}

fn launch(
    name: &str,
    exe: &str,
    integration: bool,
    cwd: Option<&str>,
) -> ghostgrid_core::protocol::SessionLaunch {
    shells::launch(
        "s1",
        &shell(name, exe),
        &base(),
        &resources(integration),
        cwd,
    )
    .expect("launches")
}

/// The value of `key`, matched as Windows matches environment names.
fn env_value<'a>(
    launch: &'a ghostgrid_core::protocol::SessionLaunch,
    key: &str,
) -> Option<&'a str> {
    let matches: Vec<_> = launch
        .environment
        .iter()
        .filter(|(k, _)| k.eq_ignore_ascii_case(key))
        .collect();
    assert!(matches.len() <= 1, "{key} is set once: {matches:?}");
    matches.first().map(|(_, v)| v.as_str())
}

#[test]
fn every_shell_gets_ghostgrids_environment() {
    let launch = launch("pwsh", "C:\\pwsh.exe", true, Some("C:\\code"));
    assert_eq!(launch.id, "s1");
    assert_eq!(launch.executable, "C:\\pwsh.exe");
    assert_eq!(launch.working_directory.as_deref(), Some("C:\\code"));
    assert_eq!(env_value(&launch, "TERM"), Some("xterm-256color"));
    assert_eq!(env_value(&launch, "COLORTERM"), Some("truecolor"));
    assert_eq!(env_value(&launch, "TERM_PROGRAM"), Some("ghostgrid"));
    assert_eq!(
        env_value(&launch, "TERM_PROGRAM_VERSION"),
        Some(env!("CARGO_PKG_VERSION"))
    );
    assert_eq!(env_value(&launch, "GHOSTGRID"), Some("1"));
    assert_eq!(env_value(&launch, "GHOSTGRID_SHELL"), Some("pwsh"));
    assert_eq!(env_value(&launch, "GHOSTGRID_SESSION"), Some("s1"));
    assert_eq!(
        env_value(&launch, "PATH"),
        Some("C:\\Windows\\System32"),
        "the base environment is kept"
    );
}

#[test]
fn environment_names_match_without_case() {
    let mut base = base();
    base.insert("Term".into(), "dumb".into());
    base.insert("Prompt".into(), "$T$G".into());
    let launch = shells::launch(
        "s",
        &shell("cmd", "C:\\cmd.exe"),
        &base,
        &resources(true),
        None,
    )
    .unwrap();
    assert_eq!(env_value(&launch, "TERM"), Some("xterm-256color"));
    assert!(env_value(&launch, "PROMPT").unwrap().contains("$T$G"));
}

#[test]
fn powershell_dot_sources_the_hook() {
    for name in ["pwsh", "powershell"] {
        let launch = launch(name, "C:\\ps.exe", true, None);
        assert_eq!(
            launch.arguments,
            [
                "C:\\ps.exe",
                "-NoLogo",
                "-NoExit",
                "-Command",
                ". 'C:\\H\\pwsh\\ghostgrid.ps1'"
            ],
            "{name}"
        );
        assert_eq!(launch.working_directory, None);
        assert_eq!(
            self::launch(name, "C:\\ps.exe", false, None).arguments,
            ["C:\\ps.exe", "-NoLogo"]
        );
    }
    let quoted = shells::launch(
        "s",
        &shell("pwsh", "C:\\ps.exe"),
        &base(),
        &LaunchResources {
            hooks_dir: "C:\\Users\\O'Brien\\hooks\\".into(),
            integration: true,
        },
        None,
    )
    .unwrap();
    assert_eq!(
        quoted.arguments[4],
        ". 'C:\\Users\\O''Brien\\hooks\\pwsh\\ghostgrid.ps1'"
    );
}

#[test]
fn cmd_marks_its_prompt() {
    let launch = launch("cmd", "C:\\Windows\\System32\\cmd.exe", true, None);
    assert_eq!(launch.arguments, ["C:\\Windows\\System32\\cmd.exe"]);
    assert_eq!(
        env_value(&launch, "PROMPT"),
        Some("$e]133;D$e\\$e]133;A$e\\$e]9;9;$P$e\\$P$G$e]133;B$e\\")
    );
    let mut custom = base();
    custom.insert("PROMPT".into(), "$T $P$G".into());
    let launch = shells::launch(
        "s",
        &shell("cmd", "C:\\cmd.exe"),
        &custom,
        &resources(true),
        None,
    )
    .unwrap();
    assert_eq!(
        env_value(&launch, "PROMPT"),
        Some("$e]133;D$e\\$e]133;A$e\\$e]9;9;$P$e\\$T $P$G$e]133;B$e\\")
    );
    assert_eq!(
        env_value(&self::launch("cmd", "C:\\cmd.exe", false, None), "PROMPT"),
        None,
        "integration off"
    );
}

#[test]
fn git_bash_starts_through_the_hook_file() {
    let launch = launch(
        "gitbash",
        "C:\\Program Files\\Git\\bin\\bash.exe",
        true,
        Some("C:\\code"),
    );
    assert_eq!(
        launch.arguments,
        [
            "C:\\Program Files\\Git\\bin\\bash.exe",
            "--rcfile",
            "C:/H/bash/ghostgrid.bash",
            "-i"
        ]
    );
    assert_eq!(
        env_value(&launch, "CHERE_INVOKING"),
        Some("1"),
        "keeps the working directory"
    );
    assert_eq!(env_value(&launch, "MSYSTEM"), Some("MINGW64"));
    let plain = self::launch("gitbash", "C:\\bash.exe", false, None);
    assert_eq!(plain.arguments, ["C:\\bash.exe", "--login", "-i"]);
    let mut ucrt = base();
    ucrt.insert("MSYSTEM".into(), "UCRT64".into());
    let launch = shells::launch(
        "s",
        &shell("gitbash", "C:\\bash.exe"),
        &ucrt,
        &resources(true),
        None,
    )
    .unwrap();
    assert_eq!(
        env_value(&launch, "MSYSTEM"),
        Some("UCRT64"),
        "a user's MSYSTEM is kept"
    );
}

#[test]
fn wsl_runs_the_users_shell_through_the_hooks() {
    let launch = launch("wsl", "C:\\Windows\\System32\\wsl.exe", true, None);
    assert_eq!(
        launch.arguments[..6],
        [
            "C:\\Windows\\System32\\wsl.exe",
            "--cd",
            "~",
            "-e",
            "sh",
            "-lc"
        ]
    );
    assert_eq!(launch.arguments.len(), 7);
    let script = &launch.arguments[6];
    assert!(script.contains("/mnt/c/H/zsh"), "{script}");
    assert!(script.contains("/mnt/c/H/bash/ghostgrid.bash"), "{script}");
    assert!(script.contains("GHOSTGRID_ZDOTDIR"), "{script}");
    assert!(script.contains("exec \"$SHELL\" -l"), "{script}");
    assert_eq!(
        env_value(&launch, "WSLENV"),
        Some("GHOSTGRID/u:GHOSTGRID_SHELL/u:GHOSTGRID_SESSION/u:TERM_PROGRAM/u:COLORTERM/u")
    );
    assert_eq!(launch.working_directory, None);

    let plain = self::launch("wsl", "C:\\wsl.exe", false, Some("/home/me/src"));
    assert_eq!(plain.arguments, ["C:\\wsl.exe", "--cd", "/home/me/src"]);
    assert_eq!(
        plain.working_directory, None,
        "a Linux folder is not a Windows working directory"
    );
    let windows = self::launch("wsl", "C:\\wsl.exe", false, Some("C:\\code"));
    assert_eq!(windows.arguments, ["C:\\wsl.exe", "--cd", "C:\\code"]);
    assert_eq!(windows.working_directory.as_deref(), Some("C:\\code"));

    let mut shared = base();
    shared.insert("WSLENV".into(), "FOO/p".into());
    let launch = shells::launch(
        "s",
        &shell("wsl", "C:\\wsl.exe"),
        &shared,
        &resources(false),
        None,
    )
    .unwrap();
    assert_eq!(
        env_value(&launch, "WSLENV"),
        Some("FOO/p:GHOSTGRID/u:GHOSTGRID_SHELL/u:GHOSTGRID_SESSION/u:TERM_PROGRAM/u:COLORTERM/u")
    );
}

#[test]
fn nushell_uses_its_own_login_flag() {
    let launch = launch("nushell", "C:\\nu.exe", true, None);
    assert_eq!(launch.arguments, ["C:\\nu.exe", "-l"]);
    assert_eq!(env_value(&launch, "PROMPT"), None);
}

#[test]
fn a_missing_shell_cannot_launch() {
    let missing = ShellChoice {
        name: "pwsh".into(),
        title: "PowerShell 7".into(),
        hotkey: "1".into(),
        executable: None,
    };
    assert!(shells::launch("s", &missing, &base(), &resources(true), None).is_none());
}

#[test]
fn windows_shells_start_only_in_windows_folders() {
    assert_eq!(
        launch("cmd", "C:\\cmd.exe", true, Some("/mnt/d/src"))
            .working_directory
            .as_deref(),
        Some("D:\\src")
    );
    assert_eq!(
        launch("cmd", "C:\\cmd.exe", true, Some("/home/me")).working_directory,
        None
    );
    assert_eq!(
        launch("cmd", "C:\\cmd.exe", true, Some("\\\\server\\share"))
            .working_directory
            .as_deref(),
        Some("\\\\server\\share")
    );
}

#[test]
fn windows_paths_map_into_wsl_and_back() {
    assert_eq!(to_wsl_path("C:\\Users\\x"), "/mnt/c/Users/x");
    assert_eq!(to_wsl_path("D:\\"), "/mnt/d/");
    assert_eq!(to_wsl_path("E:/a/b"), "/mnt/e/a/b");
    assert_eq!(to_wsl_path("\\\\wsl$\\Ubuntu\\home\\me"), "/home/me");
    assert_eq!(to_wsl_path("\\\\wsl.localhost\\Ubuntu\\home"), "/home");
    assert_eq!(
        from_wsl_path("/mnt/c/Users/x").as_deref(),
        Some("C:\\Users\\x")
    );
    assert_eq!(from_wsl_path("/mnt/d").as_deref(), Some("D:\\"));
    assert_eq!(from_wsl_path("/home/x"), None);
}

/// The WSL start script, run by Git Bash's sh with stand-in shells, execs
/// the user's shell the way the script says.
#[test]
fn the_wsl_script_execs_the_users_shell() {
    let Some(bash) = git_bash() else { return };
    let dir = temp_dir("wsl-script");
    let fake = |name: &str| {
        let path = dir.join(name);
        std::fs::write(
            &path,
            "#!/bin/sh\nprintf '%s|%s|%s' \"$ZDOTDIR\" \"${GHOSTGRID_ZDOTDIR-unset}\" \"$*\"\n",
        )
        .unwrap();
        path.display().to_string().replace('\\', "/")
    };
    let script = launch("wsl", "C:\\wsl.exe", true, None).arguments[6].clone();
    let run = |shell_path: &str, zdotdir: Option<&str>| {
        let mut command = std::process::Command::new(&bash);
        command
            .args(["--norc", "--noprofile", "-c", &script])
            .env("SHELL", shell_path)
            .env_remove("ZDOTDIR");
        command.env("MSYS_NO_PATHCONV", "1");
        if let Some(z) = zdotdir {
            command.env("ZDOTDIR", z);
        }
        String::from_utf8_lossy(&command.output().unwrap().stdout).into_owned()
    };
    let zsh = fake("zsh");
    assert_eq!(run(&zsh, None), "/mnt/c/H/zsh|unset|-l");
    assert_eq!(
        run(&zsh, Some("/home/me/.zsh")),
        "/mnt/c/H/zsh|/home/me/.zsh|-l"
    );
    let bash_shell = fake("bash");
    assert_eq!(
        run(&bash_shell, None),
        "|unset|--rcfile /mnt/c/H/bash/ghostgrid.bash -i"
    );
    let fish = fake("fish");
    assert_eq!(run(&fish, None), "|unset|-l");
}
