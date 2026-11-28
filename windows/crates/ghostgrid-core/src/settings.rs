//! ghostgrid's own settings (the Ghostty config still owns how terminals
//! look), with the macOS app's defaults. Stored as one JSON file; a value
//! that is missing, of the wrong kind or out of range falls back to its
//! default on its own, so one bad value never resets the rest.

use crate::launcher::{self, LauncherEntry};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

/// The space between panes when unset, and its range, in pixels.
const GAP_DEFAULT: f64 = 8.0;
const GAP_RANGE: (f64, f64) = (0.0, 24.0);

/// A stored gap clamped into range; the default when unset or not a
/// number.
pub fn clamped_gap(stored: Option<f64>) -> f64 {
    match stored {
        Some(gap) if gap.is_finite() => gap.clamp(GAP_RANGE.0, GAP_RANGE.1),
        _ => GAP_DEFAULT,
    }
}

const ANIMATION_STYLES: [&str; 3] = ["springy", "smooth", "off"];
const LAYOUTS: [&str; 3] = ["grid", "mainStack", "columns"];

fn yes() -> bool {
    true
}
fn gap() -> f64 {
    GAP_DEFAULT
}
fn springy() -> String {
    "springy".into()
}
fn grid() -> String {
    "grid".into()
}
fn endpoint() -> String {
    "http://localhost:1234/v1".into()
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Settings {
    /// New tabs and panes start the last used shell (true) or always show
    /// the menu.
    #[serde(default = "yes")]
    pub new_pane_uses_last_shell: bool,
    /// After picking a shell from the menu, offer the app launcher.
    #[serde(default = "yes")]
    pub offer_apps_after_shell: bool,
    /// The shell picked last in a pane's menu (None: none yet).
    #[serde(default)]
    pub last_shell: Option<String>,
    /// Space between panes, in pixels (0-24).
    #[serde(default = "gap")]
    pub pane_gap: f64,
    /// "springy", "smooth" or "off".
    #[serde(default = "springy")]
    pub animation_style: String,
    /// A header on each pane: shell, folder, git branch.
    #[serde(default = "yes")]
    pub show_pane_headers: bool,
    /// The arrangement new windows start with: "grid", "mainStack" or
    /// "columns".
    #[serde(default = "grid")]
    pub default_layout: String,
    /// The apps offered after choosing a shell.
    #[serde(default = "launcher::defaults")]
    pub launcher_entries: Vec<LauncherEntry>,
    /// Badges for a bell or a long command finishing in a pane you were
    /// not looking at.
    #[serde(default = "yes")]
    pub show_activity_badges: bool,
    /// Shells keep running in ghostgrid-sessiond when ghostgrid quits and
    /// come back, scrollback and all, on the next launch.
    #[serde(default = "yes")]
    pub keep_shells_running: bool,
    /// Explain a failed command in the focused pane as soon as it fails.
    #[serde(default = "yes")]
    pub explain_failures: bool,
    /// Panes that need you or just printed grow; quiet ones shrink.
    #[serde(default = "yes")]
    pub attention_grid: bool,
    /// The local model server (OpenAI-style API; LM Studio's by default).
    #[serde(default = "endpoint")]
    pub model_endpoint: String,
    /// The model to ask; empty: the first chat model the server has.
    #[serde(default)]
    pub model_name: String,
    #[serde(default = "yes")]
    pub check_for_updates: bool,
    /// When updates were last checked, in seconds since the Unix epoch.
    #[serde(default)]
    pub last_update_check: Option<f64>,
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            new_pane_uses_last_shell: true,
            offer_apps_after_shell: true,
            last_shell: None,
            pane_gap: GAP_DEFAULT,
            animation_style: springy(),
            show_pane_headers: true,
            default_layout: grid(),
            launcher_entries: launcher::defaults(),
            show_activity_badges: true,
            keep_shells_running: true,
            explain_failures: true,
            attention_grid: true,
            model_endpoint: endpoint(),
            model_name: String::new(),
            check_for_updates: true,
            last_update_check: None,
        }
    }
}

/// `key` of `object` as a `T`, or `fallback` when missing or of the
/// wrong kind.
fn field<T: DeserializeOwned>(object: &Map<String, Value>, key: &str, fallback: T) -> T {
    object
        .get(key)
        .and_then(|v| serde_json::from_value(v.clone()).ok())
        .unwrap_or(fallback)
}

impl Settings {
    /// The stored settings; unreadable text means all defaults.
    pub fn load(text: &str) -> Settings {
        let Ok(Value::Object(object)) = serde_json::from_str::<Value>(text) else {
            return Settings::default();
        };
        let d = Settings::default();
        let mut s = Settings {
            new_pane_uses_last_shell: field(
                &object,
                "newPaneUsesLastShell",
                d.new_pane_uses_last_shell,
            ),
            offer_apps_after_shell: field(&object, "offerAppsAfterShell", d.offer_apps_after_shell),
            last_shell: field(&object, "lastShell", d.last_shell),
            pane_gap: d.pane_gap,
            animation_style: field(&object, "animationStyle", d.animation_style),
            show_pane_headers: field(&object, "showPaneHeaders", d.show_pane_headers),
            default_layout: field(&object, "defaultLayout", d.default_layout),
            launcher_entries: field(&object, "launcherEntries", d.launcher_entries),
            show_activity_badges: field(&object, "showActivityBadges", d.show_activity_badges),
            keep_shells_running: field(&object, "keepShellsRunning", d.keep_shells_running),
            explain_failures: field(&object, "explainFailures", d.explain_failures),
            attention_grid: field(&object, "attentionGrid", d.attention_grid),
            model_endpoint: field(&object, "modelEndpoint", d.model_endpoint),
            model_name: field(&object, "modelName", d.model_name),
            check_for_updates: field(&object, "checkForUpdates", d.check_for_updates),
            last_update_check: field(&object, "lastUpdateCheck", d.last_update_check),
        };
        s.pane_gap = clamped_gap(object.get("paneGap").and_then(Value::as_f64));
        s.normalize();
        s
    }

    /// Values out of range or unknown replaced by their defaults.
    pub fn normalize(&mut self) {
        self.pane_gap = clamped_gap(Some(self.pane_gap));
        if !ANIMATION_STYLES.contains(&self.animation_style.as_str()) {
            self.animation_style = springy();
        }
        if !LAYOUTS.contains(&self.default_layout.as_str()) {
            self.default_layout = grid();
        }
    }

    /// Pretty JSON, camelCase keys.
    pub fn to_json(&self) -> String {
        serde_json::to_string_pretty(self).unwrap_or_else(|_| "{}".into())
    }
}
