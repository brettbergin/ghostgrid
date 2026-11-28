//! What ghostgrid saves on quit and rebuilds on launch: each window's
//! frame and its tabs in order (which one is selected), and each tab's
//! name, color and panes in grid order (shell, working directory, kept
//! shell), with which pane had focus, which was zoomed and the layout.
//! Scrollback is not saved here (kept shells bring theirs back).
//!
//! The JSON keys are the macOS app's, so the format is one format.
//! Version 2 added tabs; a version 1 file loads as one tab per window with
//! everything it had.

use serde::de::Deserializer;
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// A window's place on screen, in Windows screen coordinates (origin
/// top-left, physical pixels as the window manager reports them).
#[derive(Serialize, Debug, Clone, Copy, PartialEq, Default)]
pub struct Frame {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Frame {
    pub const fn new(x: f64, y: f64, width: f64, height: f64) -> Self {
        Frame {
            x,
            y,
            width,
            height,
        }
    }

    fn area(&self) -> f64 {
        self.width * self.height
    }

    /// The overlap of two frames, None when they do not meet.
    fn intersection(&self, other: &Frame) -> Option<Frame> {
        let left = self.x.max(other.x);
        let top = self.y.max(other.y);
        let right = (self.x + self.width).min(other.x + other.width);
        let bottom = (self.y + self.height).min(other.y + other.height);
        (right > left && bottom > top).then(|| Frame::new(left, top, right - left, bottom - top))
    }
}

impl<'de> Deserialize<'de> for Frame {
    /// `{x, y, width, height}`, or the macOS `[[x, y], [width, height]]`.
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        struct Object {
            x: f64,
            y: f64,
            width: f64,
            height: f64,
        }
        #[derive(Deserialize)]
        #[serde(untagged)]
        enum Form {
            Object(Object),
            Pairs([[f64; 2]; 2]),
        }
        Ok(match Form::deserialize(deserializer)? {
            Form::Object(o) => Frame::new(o.x, o.y, o.width, o.height),
            Form::Pairs([[x, y], [width, height]]) => Frame::new(x, y, width, height),
        })
    }
}

/// A tab's color in the tab bar (Catppuccin Mocha's accents).
#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[serde(rename_all = "lowercase")]
pub enum TabColor {
    Red,
    Peach,
    Yellow,
    Green,
    Teal,
    Blue,
    Mauve,
    Pink,
}

impl TabColor {
    pub const ALL: [TabColor; 8] = [
        TabColor::Red,
        TabColor::Peach,
        TabColor::Yellow,
        TabColor::Green,
        TabColor::Teal,
        TabColor::Blue,
        TabColor::Mauve,
        TabColor::Pink,
    ];

    pub fn title(&self) -> &'static str {
        match self {
            TabColor::Red => "Red",
            TabColor::Peach => "Peach",
            TabColor::Yellow => "Yellow",
            TabColor::Green => "Green",
            TabColor::Teal => "Teal",
            TabColor::Blue => "Blue",
            TabColor::Mauve => "Mauve",
            TabColor::Pink => "Pink",
        }
    }

    /// 0xRRGGBB.
    pub fn rgb(&self) -> u32 {
        match self {
            TabColor::Red => 0xF38BA8,
            TabColor::Peach => 0xFAB387,
            TabColor::Yellow => 0xF9E2AF,
            TabColor::Green => 0xA6E3A1,
            TabColor::Teal => 0x94E2D5,
            TabColor::Blue => 0x89B4FA,
            TabColor::Mauve => 0xCBA6F7,
            TabColor::Pink => 0xF5C2E7,
        }
    }
}

/// A color this build does not know (saved by a newer one), or not a
/// color at all, is dropped rather than failing the whole session.
fn lenient_color<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Option<TabColor>, D::Error> {
    let value = Option::<Value>::deserialize(deserializer)?;
    Ok(value.and_then(|v| serde_json::from_value(v).ok()))
}

/// Divider adjustments (resizable panes): track sizes, then cell sizes in
/// each track.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Default)]
pub struct LayoutWeights {
    pub tracks: Vec<f64>,
    pub cells: Vec<Vec<f64>>,
}

/// One pane: its shell and where it was.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq, Default)]
pub struct Pane {
    /// ShellChoice name ("pwsh", "cmd", "gitbash", "wsl", ...).
    pub shell: String,
    #[serde(
        rename = "workingDirectory",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub working_directory: Option<String>,
    /// The shell still running in ghostgrid-sessiond (shells that survive
    /// quitting); None when it was not kept.
    #[serde(rename = "sessionID", default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
}

impl Pane {
    pub fn new(
        shell: impl Into<String>,
        working_directory: Option<String>,
        session_id: Option<String>,
    ) -> Self {
        Pane {
            shell: shell.into(),
            working_directory,
            session_id,
        }
    }
}

/// One tab: its own grid of panes and how they are arranged.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Default)]
pub struct Tab {
    /// The name you gave it; None: "Tab N" by position.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(
        default,
        deserialize_with = "lenient_color",
        skip_serializing_if = "Option::is_none"
    )]
    pub color: Option<TabColor>,
    pub panes: Vec<Pane>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub focused: Option<usize>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub zoomed: Option<usize>,
    /// "grid", "mainStack" or "columns"; None in sessions saved before
    /// layouts existed: grid.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub layout: Option<String>,
    /// None: balanced.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub weights: Option<LayoutWeights>,
    /// The grid's panes per row after rows were moved; None: balanced.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rows: Option<Vec<usize>>,
    /// Rotate Layout: the split the window's shape would pick, turned.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rotated: Option<bool>,
}

/// One window.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Default)]
pub struct Window {
    pub frame: Frame,
    pub tabs: Vec<Tab>,
    /// Index into `tabs`; None: the first.
    #[serde(
        rename = "selectedTab",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub selected_tab: Option<usize>,
    /// Windows only: the window was maximized (`frame` is then where it
    /// goes when restored down).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub maximized: Option<bool>,
}

/// Every window, as saved.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
pub struct Session {
    pub version: u32,
    pub windows: Vec<Window>,
}

/// The format before tabs: each window held one grid of panes.
#[derive(Deserialize)]
struct Version1 {
    windows: Vec<Version1Window>,
}

#[derive(Deserialize)]
struct Version1Window {
    frame: Frame,
    panes: Vec<Pane>,
    focused: Option<usize>,
    zoomed: Option<usize>,
    layout: Option<String>,
    weights: Option<LayoutWeights>,
    rows: Option<Vec<usize>>,
    rotated: Option<bool>,
}

impl Session {
    pub const CURRENT_VERSION: u32 = 2;

    pub fn new(windows: Vec<Window>) -> Self {
        Session {
            version: Self::CURRENT_VERSION,
            windows,
        }
    }

    /// Every pane's kept shell, in window, tab and grid order.
    pub fn live_session_ids(&self) -> Vec<String> {
        self.windows
            .iter()
            .flat_map(|w| w.tabs.iter())
            .flat_map(|t| t.panes.iter())
            .filter_map(|p| p.session_id.clone())
            .collect()
    }

    /// Windows worth restoring: tabs with at least one pane (focus and zoom
    /// indices that point at no pane are dropped) and windows with at least
    /// one such tab. The selected tab stays selected; when it was dropped,
    /// the tab that took its place (or the new last one) is.
    pub fn restorable(&self) -> Vec<Window> {
        self.windows
            .iter()
            .filter_map(|window| {
                let wanted = window.selected_tab.unwrap_or(0);
                let mut tabs: Vec<Tab> = Vec::new();
                let mut selected = None;
                for (index, tab) in window.tabs.iter().enumerate() {
                    if tab.panes.is_empty() {
                        continue;
                    }
                    let mut tab = tab.clone();
                    if tab.focused.is_some_and(|f| f >= tab.panes.len()) {
                        tab.focused = None;
                    }
                    if tab.zoomed.is_some_and(|z| z >= tab.panes.len()) {
                        tab.zoomed = None;
                    }
                    if index == wanted {
                        selected = Some(tabs.len());
                    }
                    // The first kept tab at or after a dropped selection.
                    if selected.is_none() && index > wanted {
                        selected = Some(tabs.len());
                    }
                    tabs.push(tab);
                }
                if tabs.is_empty() {
                    return None;
                }
                let selected = selected.unwrap_or(tabs.len() - 1);
                Some(Window {
                    frame: window.frame,
                    tabs,
                    selected_tab: Some(selected),
                    maximized: window.maximized,
                })
            })
            .collect()
    }

    /// Pretty JSON with sorted keys, as the macOS app writes it.
    pub fn encode(&self) -> String {
        // serde_json's Value keeps object keys sorted.
        let value = serde_json::to_value(self).unwrap_or(Value::Null);
        serde_json::to_string_pretty(&value).unwrap_or_default()
    }

    /// None for unreadable text or a version this build does not know.
    /// Version 1 files are brought up to date.
    pub fn decode(text: &str) -> Option<Session> {
        let value: Value = serde_json::from_str(text).ok()?;
        match value.get("version")?.as_u64()? {
            1 => {
                let old: Version1 = serde_json::from_value(value).ok()?;
                Some(Session::new(
                    old.windows
                        .into_iter()
                        .map(|w| Window {
                            frame: w.frame,
                            tabs: vec![Tab {
                                name: None,
                                color: None,
                                panes: w.panes,
                                focused: w.focused,
                                zoomed: w.zoomed,
                                layout: w.layout,
                                weights: w.weights,
                                rows: w.rows,
                                rotated: w.rotated,
                            }],
                            selected_tab: Some(0),
                            maximized: None,
                        })
                        .collect(),
                ))
            }
            2 => serde_json::from_value(value).ok(),
            _ => None,
        }
    }
}

/// Whether and where to restore the last session.
pub struct SessionPolicy;

impl SessionPolicy {
    /// How much of a saved frame must be on some screen to stay put.
    pub const MINIMUM_VISIBLE: f64 = 0.3;

    /// Following Ghostty's `window-save-state`: "always" restores, "never"
    /// does not. Windows has no system "reopen windows" setting for
    /// "default" (or unset) to follow, so it restores exactly when shells
    /// were kept running: the windows come back to show them.
    pub fn should_restore(window_save_state: Option<&str>, keeps_shells: bool) -> bool {
        match window_save_state
            .map(|s| s.trim().to_ascii_lowercase())
            .as_deref()
        {
            Some("always") => true,
            Some("never") => false,
            _ => keeps_shells,
        }
    }

    /// A saved window frame placed back on screen: kept when at least
    /// `minimum_visible` of it is on some screen, otherwise moved onto the
    /// first screen (shrunk to fit), so a window saved on a disconnected
    /// display is not lost off-screen. None when there are no screens.
    pub fn fit(frame: Frame, screens: &[Frame], minimum_visible: f64) -> Option<Frame> {
        let main = *screens.first()?;
        if frame.width <= 0.0 || frame.height <= 0.0 {
            return Some(main);
        }
        let area = frame.area();
        if screens.iter().any(|screen| {
            frame
                .intersection(screen)
                .is_some_and(|overlap| overlap.area() >= area * minimum_visible)
        }) {
            return Some(frame);
        }
        let width = frame.width.min(main.width);
        let height = frame.height.min(main.height);
        Some(Frame::new(
            main.x + (main.width - width) / 2.0,
            main.y + (main.height - height) / 2.0,
            width,
            height,
        ))
    }
}
