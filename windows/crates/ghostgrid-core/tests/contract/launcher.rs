//! Contract for the app launcher offered after picking a shell
//! (LaunchCatalogTests), looking programs up the way Windows does: each
//! folder, each executable extension.

use ghostgrid_core::launcher::{self, LaunchApp, LauncherEntry};
use std::collections::{HashMap, HashSet};

fn dirs() -> Vec<String> {
    vec![
        "C:\\Users\\me\\.local\\bin".into(),
        "C:\\Users\\me\\scoop\\shims\\".into(),
        "C:\\Program Files\\Git\\cmd".into(),
    ]
}

fn exts() -> Vec<String> {
    vec![".exe".into(), ".cmd".into()]
}

fn resolve(entries: &[LauncherEntry], installed: &[&str]) -> Vec<LaunchApp> {
    let installed: HashSet<String> = installed.iter().map(|s| s.to_string()).collect();
    launcher::resolve(entries, &dirs(), &exts(), &|path| installed.contains(path))
}

fn entry(name: &str, command: &str) -> LauncherEntry {
    LauncherEntry {
        id: format!("id-{name}"),
        name: name.into(),
        command: command.into(),
        summary: String::new(),
        program: None,
    }
}

#[test]
fn defaults_are_the_five_suggested_apps() {
    let apps = resolve(&launcher::defaults(), &[]);
    assert_eq!(
        apps.iter().map(|a| a.name.as_str()).collect::<Vec<_>>(),
        ["opencode", "claude", "btop", "lazygit", "yazi"]
    );
    assert_eq!(
        apps.iter().map(|a| a.hotkey.as_str()).collect::<Vec<_>>(),
        ["1", "2", "3", "4", "5"]
    );
    assert_eq!(apps[4].command, "y");
    let ids: HashSet<String> = launcher::defaults().into_iter().map(|e| e.id).collect();
    assert_eq!(ids.len(), 5, "each default has its own id");
}

#[test]
fn finds_programs_in_each_folder_with_each_extension() {
    let apps = resolve(
        &launcher::defaults(),
        &[
            "C:\\Users\\me\\scoop\\shims\\btop.exe",
            "C:\\Users\\me\\.local\\bin\\claude.exe",
            "C:\\Users\\me\\scoop\\shims\\yazi.exe",
            "C:\\Program Files\\Git\\cmd\\lazygit.cmd",
        ],
    );
    assert_eq!(
        apps[2].executable.as_deref(),
        Some("C:\\Users\\me\\scoop\\shims\\btop.exe")
    );
    assert_eq!(
        apps[1].executable.as_deref(),
        Some("C:\\Users\\me\\.local\\bin\\claude.exe")
    );
    assert_eq!(
        apps[3].executable.as_deref(),
        Some("C:\\Program Files\\Git\\cmd\\lazygit.cmd")
    );
    assert!(apps[4].is_found(), "y is checked as yazi");
    assert!(!apps[0].is_found());
}

#[test]
fn earlier_folders_and_extensions_win() {
    let apps = resolve(
        &[entry("k9s", "k9s")],
        &[
            "C:\\Program Files\\Git\\cmd\\k9s.exe",
            "C:\\Users\\me\\.local\\bin\\k9s.cmd",
            "C:\\Users\\me\\.local\\bin\\k9s.exe",
        ],
    );
    assert_eq!(
        apps[0].executable.as_deref(),
        Some("C:\\Users\\me\\.local\\bin\\k9s.exe")
    );
}

#[test]
fn custom_entries_use_the_commands_first_word() {
    let apps = resolve(
        &[entry("k9s", "k9s --readonly")],
        &["C:\\Users\\me\\scoop\\shims\\k9s.exe"],
    );
    assert!(apps[0].is_found());
    assert_eq!(apps[0].command, "k9s --readonly");
}

#[test]
fn a_program_given_as_a_path_is_checked_as_is() {
    let mut with_path = entry("tool", "tool");
    with_path.program = Some("C:\\tools\\tool".into());
    assert_eq!(
        resolve(&[with_path.clone()], &["C:\\tools\\tool.cmd"])[0]
            .executable
            .as_deref(),
        Some("C:\\tools\\tool.cmd")
    );
    with_path.program = Some("D:/bin/tool.exe".into());
    assert_eq!(
        resolve(&[with_path.clone()], &["D:/bin/tool.exe"])[0]
            .executable
            .as_deref(),
        Some("D:/bin/tool.exe")
    );
    assert!(!resolve(&[with_path], &["D:/bin/tool.exe.exe"])[0].is_found());
    let named = entry("x", "notepad.exe");
    assert_eq!(
        resolve(&[named], &["C:\\Users\\me\\.local\\bin\\notepad.exe"])[0]
            .executable
            .as_deref(),
        Some("C:\\Users\\me\\.local\\bin\\notepad.exe"),
        "a bare name with an extension is looked up as is"
    );
}

#[test]
fn aliases_stay_usable_when_not_found() {
    let apps = resolve(&[entry("deploy", "dpl")], &[]);
    assert!(!apps[0].is_found());
    assert_eq!(
        launcher::choice_for_key("1", &apps).map(|a| a.command.as_str()),
        Some("dpl")
    );
}

#[test]
fn blank_commands_are_dropped_and_the_menu_stops_at_nine() {
    let mut entries: Vec<_> = (1..=12)
        .map(|i| entry(&format!("app{i}"), &format!("app{i}")))
        .collect();
    entries.insert(0, entry("blank", "   "));
    let apps = resolve(&entries, &[]);
    assert_eq!(apps.len(), launcher::MAX_ENTRIES);
    assert_eq!(apps[0].name, "app1");
    assert_eq!(apps.last().unwrap().hotkey, "9");
    assert!(launcher::choice_for_key("0", &apps).is_none());
}

#[test]
fn empty_names_fall_back_to_the_command() {
    assert_eq!(resolve(&[entry(" ", " htop ")], &[])[0].name, "htop");
    assert_eq!(resolve(&[entry(" ", " htop ")], &[])[0].command, "htop");
}

#[test]
fn stored_entries_round_trip_and_bad_data_means_defaults() {
    let custom = vec![LauncherEntry {
        summary: "cluster".into(),
        ..entry("k9s", "k9s")
    }];
    assert_eq!(launcher::decode(Some(&launcher::encode(&custom))), custom);
    assert_eq!(
        launcher::decode(None)
            .iter()
            .map(|e| e.name.clone())
            .collect::<Vec<_>>(),
        launcher::defaults()
            .iter()
            .map(|e| e.name.clone())
            .collect::<Vec<_>>()
    );
    assert_eq!(launcher::decode(Some("nope")).len(), 5);
    assert!(
        launcher::decode(Some(&launcher::encode(&[]))).is_empty(),
        "an emptied list stays empty"
    );
}

#[test]
fn entries_use_camel_case_json() {
    let mut yazi = entry("yazi", "y");
    yazi.program = Some("yazi".into());
    let json = serde_json::to_value(&yazi).unwrap();
    assert_eq!(json["id"], "id-yazi");
    assert_eq!(json["program"], "yazi");
    let decoded: LauncherEntry =
        serde_json::from_str(r#"{"id":"a","name":"n","command":"c"}"#).unwrap();
    assert_eq!(decoded.summary, "");
    assert_eq!(decoded.program, None);
    let app = &resolve(&[yazi], &[])[0];
    let json = serde_json::to_value(app).unwrap();
    assert_eq!(json["isFound"], false);
    assert_eq!(json["hotkey"], "1");
}

#[test]
fn search_folders_are_path_then_per_user_installs() {
    let env: HashMap<&str, &str> = [
        (
            "PATH",
            "C:\\Windows;\"C:\\Program Files\\Git\\cmd\";;C:\\Users\\me\\scoop\\shims",
        ),
        ("USERPROFILE", "C:\\Users\\me"),
        ("LOCALAPPDATA", "C:\\Users\\me\\AppData\\Local"),
    ]
    .into_iter()
    .collect();
    let dirs = launcher::default_search_dirs(&|key| env.get(key).map(|v| v.to_string()));
    assert_eq!(
        dirs,
        [
            "C:\\Windows",
            "C:\\Program Files\\Git\\cmd",
            "C:\\Users\\me\\scoop\\shims",
            "C:\\Users\\me\\.local\\bin",
            "C:\\Users\\me\\.bun\\bin",
            "C:\\Users\\me\\.opencode\\bin",
            "C:\\Users\\me\\AppData\\Local\\Microsoft\\WinGet\\Links",
        ],
        "each folder once"
    );
}

#[test]
fn extensions_come_from_pathext() {
    assert_eq!(
        launcher::default_extensions(&|_| Some(".COM;.EXE;;.BAT".into())),
        [".com", ".exe", ".bat"]
    );
    assert_eq!(
        launcher::default_extensions(&|_| None),
        [".exe", ".cmd", ".bat", ".com", ".ps1"]
    );
}
