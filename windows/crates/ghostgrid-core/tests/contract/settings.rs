//! Contract for ghostgrid's own settings (SettingsModelTests and the macOS
//! app's defaults): every value has the macOS default, a stored value out
//! of range or of the wrong kind falls back, and unreadable settings mean
//! all defaults.

use ghostgrid_core::launcher;
use ghostgrid_core::settings::{clamped_gap, Settings};

#[test]
fn the_gap_clamps_into_range_with_a_default() {
    assert_eq!(clamped_gap(None), 8.0);
    assert_eq!(clamped_gap(Some(-5.0)), 0.0);
    assert_eq!(clamped_gap(Some(100.0)), 24.0);
    assert_eq!(clamped_gap(Some(12.0)), 12.0);
    assert_eq!(clamped_gap(Some(f64::NAN)), 8.0);
    assert_eq!(clamped_gap(Some(f64::INFINITY)), 8.0);
}

#[test]
fn defaults_match_the_mac_app() {
    let s = Settings::default();
    assert!(s.new_pane_uses_last_shell);
    assert!(s.offer_apps_after_shell);
    assert_eq!(s.last_shell, None);
    assert_eq!(s.pane_gap, 8.0);
    assert_eq!(s.animation_style, "springy");
    assert!(s.show_pane_headers);
    assert_eq!(s.default_layout, "grid");
    assert_eq!(s.launcher_entries, launcher::defaults());
    assert!(s.show_activity_badges);
    assert!(s.keep_shells_running);
    assert!(s.explain_failures);
    assert!(s.attention_grid);
    assert_eq!(s.model_endpoint, "http://localhost:1234/v1");
    assert_eq!(s.model_name, "");
    assert!(s.check_for_updates);
    assert_eq!(s.last_update_check, None);
}

#[test]
fn unreadable_settings_are_all_defaults() {
    assert_eq!(Settings::load(""), Settings::default());
    assert_eq!(Settings::load("nope"), Settings::default());
    assert_eq!(Settings::load("[1,2]"), Settings::default());
}

#[test]
fn stored_values_are_normalized() {
    let s = Settings::load(
        r#"{"paneGap": 100, "animationStyle": "bouncy", "defaultLayout": "spiral", "lastShell": "wsl"}"#,
    );
    assert_eq!(s.pane_gap, 24.0);
    assert_eq!(
        s.animation_style, "springy",
        "defaults to springy for unknown values"
    );
    assert_eq!(s.default_layout, "grid");
    assert_eq!(s.last_shell.as_deref(), Some("wsl"));
    assert!(s.show_pane_headers, "what is not stored keeps its default");
    let kept = Settings::load(r#"{"animationStyle": "off", "defaultLayout": "mainStack"}"#);
    assert_eq!(kept.animation_style, "off");
    assert_eq!(kept.default_layout, "mainStack");
    assert_eq!(
        Settings::load(r#"{"animationStyle": "smooth", "defaultLayout": "columns"}"#)
            .default_layout,
        "columns"
    );
}

#[test]
fn a_value_of_the_wrong_kind_falls_back_alone() {
    let s = Settings::load(
        r#"{"paneGap": "wide", "showPaneHeaders": false, "launcherEntries": 7, "lastUpdateCheck": 1700000000.5}"#,
    );
    assert_eq!(s.pane_gap, 8.0);
    assert!(!s.show_pane_headers);
    assert_eq!(s.launcher_entries, launcher::defaults());
    assert_eq!(s.last_update_check, Some(1700000000.5));
}

#[test]
fn an_emptied_launcher_stays_empty() {
    assert!(Settings::load(r#"{"launcherEntries": []}"#)
        .launcher_entries
        .is_empty());
}

#[test]
fn settings_round_trip_in_camel_case() {
    let s = Settings {
        last_shell: Some("pwsh".into()),
        pane_gap: 4.0,
        model_name: "qwen".into(),
        last_update_check: Some(12.5),
        ..Default::default()
    };
    let json = s.to_json();
    assert_eq!(Settings::load(&json), s);
    let value: serde_json::Value = serde_json::from_str(&json).unwrap();
    for key in [
        "newPaneUsesLastShell",
        "offerAppsAfterShell",
        "lastShell",
        "paneGap",
        "animationStyle",
        "showPaneHeaders",
        "defaultLayout",
        "launcherEntries",
        "showActivityBadges",
        "keepShellsRunning",
        "explainFailures",
        "attentionGrid",
        "modelEndpoint",
        "modelName",
        "checkForUpdates",
        "lastUpdateCheck",
    ] {
        assert!(value.get(key).is_some(), "{key}");
    }
}

#[test]
fn settings_deserialize_with_serde_defaults() {
    let s: Settings = serde_json::from_str(r#"{"modelName":"m"}"#).unwrap();
    assert_eq!(s.model_name, "m");
    assert_eq!(s.pane_gap, 8.0);
    assert!(s.keep_shells_running);
}
