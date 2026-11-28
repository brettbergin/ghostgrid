//! The Ghostty options a Windows pane honors, mapped to what xterm.js
//! needs. On macOS libghostty reads the config itself; on Windows the
//! terminal is xterm.js, so ghostgrid reads each option it can honor, in
//! Ghostty's terms and with Ghostty's defaults, and lists the ones it
//! cannot so the app can say so once.

use super::ConfigValues;
use serde::Serialize;

/// Fonts tried after the user's own, so a missing font still gives a
/// monospace one (Cascadia Mono and Consolas ship with Windows).
const FALLBACK_FONTS: [&str; 3] = ["JetBrains Mono", "Cascadia Mono", "Consolas"];

/// Ghostty's colors when neither the theme nor the user sets them.
const DEFAULT_BACKGROUND: &str = "#282c34";
const DEFAULT_FOREGROUND: &str = "#ffffff";

/// One appearance's colors. Each is `#rrggbb` when it was written as hex,
/// otherwise as written (a CSS color name); None leaves xterm.js's own.
#[derive(Serialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Theme {
    pub background: String,
    pub foreground: String,
    pub cursor: Option<String>,
    pub cursor_text: Option<String>,
    pub selection_background: Option<String>,
    pub selection_foreground: Option<String>,
    /// The 16 ANSI colors.
    pub palette: Vec<Option<String>>,
}

impl Default for Theme {
    fn default() -> Self {
        Theme {
            background: DEFAULT_BACKGROUND.into(),
            foreground: DEFAULT_FOREGROUND.into(),
            cursor: None,
            cursor_text: None,
            selection_background: None,
            selection_foreground: None,
            palette: vec![None; 16],
        }
    }
}

/// The colors for a light and a dark system appearance (the same theme
/// twice unless the config names a pair).
#[derive(Serialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ThemePair {
    pub light: Theme,
    pub dark: Theme,
}

/// Space around the terminal, in pixels. `x` and `y` are the left and top
/// values (Ghostty's `window-padding-x = a,b` is left and right).
#[derive(Serialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Padding {
    pub x: f64,
    pub y: f64,
    pub left: f64,
    pub right: f64,
    pub top: f64,
    pub bottom: f64,
}

/// Everything a pane's terminal is configured with.
#[derive(Serialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct TerminalSettings {
    /// The user's fonts, then the fallbacks.
    pub font_family: Vec<String>,
    /// Ghostty's font-size is in points; xterm.js wants CSS pixels.
    pub font_size_px: f64,
    pub themes: ThemePair,
    /// "block", "bar" or "underline".
    pub cursor_style: String,
    /// None: xterm.js's default.
    pub cursor_blink: Option<bool>,
    pub scrollback_lines: u32,
    pub padding: Padding,
    pub background_opacity: f64,
    /// A multiple of the font's natural line height (at least 1).
    pub line_height: f64,
    pub mouse_hide_while_typing: bool,
    pub unfocused_split_opacity: f64,
    pub copy_on_select: bool,
    pub window_save_state: Option<String>,
    pub minimum_contrast: f64,
    pub bold_is_bright: bool,
    pub shell_integration: Option<String>,
    pub shell_integration_features: Option<String>,
    pub confirm_close_surface: bool,
    /// Keys in the config that Windows ghostgrid cannot honor, each once,
    /// in the order they first appear.
    pub unsupported: Vec<String>,
}

/// The settings for `values` (the user's flattened config).
/// `theme_text` returns a theme's config text by name (see
/// [`super::theme_lookup`]); a theme's colors apply first, then the
/// user's own color keys, which win.
pub fn settings(
    values: &ConfigValues,
    theme_text: &dyn Fn(&str) -> Option<String>,
) -> TerminalSettings {
    let font_size_pt = values.double("font-size", 13.0);
    let font_size_pt = if font_size_pt.is_finite() && font_size_pt > 0.0 {
        font_size_pt
    } else {
        13.0
    };
    let font_size_px = font_size_pt * 4.0 / 3.0;

    let (padding_left, padding_right) = padding_pair(values.string("window-padding-x"));
    let (padding_top, padding_bottom) = padding_pair(values.string("window-padding-y"));

    TerminalSettings {
        font_family: font_family(values),
        font_size_px,
        themes: themes(values, theme_text),
        cursor_style: cursor_style(values.string("cursor-style")),
        cursor_blink: match values
            .string("cursor-style-blink")
            .map(str::to_ascii_lowercase)
            .as_deref()
        {
            Some("true") => Some(true),
            Some("false") => Some(false),
            _ => None,
        },
        scrollback_lines: scrollback_lines(values.string("scrollback-limit")),
        padding: Padding {
            x: padding_left,
            y: padding_top,
            left: padding_left,
            right: padding_right,
            top: padding_top,
            bottom: padding_bottom,
        },
        background_opacity: clamp(values.double("background-opacity", 1.0), 0.0, 1.0, 1.0),
        line_height: line_height(values.string("adjust-cell-height"), font_size_px),
        mouse_hide_while_typing: values.bool("mouse-hide-while-typing", false),
        unfocused_split_opacity: clamp(
            values.double("unfocused-split-opacity", 0.7),
            0.15,
            1.0,
            0.7,
        ),
        copy_on_select: !matches!(
            values
                .string("copy-on-select")
                .map(str::to_ascii_lowercase)
                .as_deref(),
            Some("false")
        ),
        window_save_state: values.string("window-save-state").map(String::from),
        minimum_contrast: clamp(values.double("minimum-contrast", 1.0), 1.0, 21.0, 1.0),
        bold_is_bright: values.bool("bold-is-bright", false),
        shell_integration: values.string("shell-integration").map(String::from),
        shell_integration_features: values
            .string("shell-integration-features")
            .map(String::from),
        confirm_close_surface: !matches!(
            values
                .string("confirm-close-surface")
                .map(str::to_ascii_lowercase)
                .as_deref(),
            Some("false")
        ),
        unsupported: unsupported(values),
    }
}

fn clamp(value: f64, low: f64, high: f64, fallback: f64) -> f64 {
    if value.is_finite() {
        value.clamp(low, high)
    } else {
        fallback
    }
}

fn font_family(values: &ConfigValues) -> Vec<String> {
    let mut fonts: Vec<String> = values.all("font-family");
    for fallback in FALLBACK_FONTS {
        if !fonts.iter().any(|f| f.eq_ignore_ascii_case(fallback)) {
            fonts.push(fallback.to_string());
        }
    }
    fonts
}

/// Ghostty's "block_hollow" has no xterm.js equivalent: a block it is.
fn cursor_style(value: Option<&str>) -> String {
    match value.map(str::to_ascii_lowercase).as_deref() {
        Some("bar") => "bar",
        Some("underline") => "underline",
        _ => "block",
    }
    .into()
}

/// Ghostty limits scrollback in bytes (10 MB by default); xterm.js in
/// lines. About 1000 bytes a line, kept within what xterm.js handles well.
fn scrollback_lines(value: Option<&str>) -> u32 {
    let bytes = value
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(10_000_000);
    (bytes / 1000).clamp(1000, 100_000) as u32
}

/// "a" or "a,b" (Ghostty's two sides); 2 px when unset or unreadable.
fn padding_pair(value: Option<&str>) -> (f64, f64) {
    let parse = |text: &str| {
        text.trim()
            .parse::<f64>()
            .ok()
            .filter(|v| v.is_finite() && *v >= 0.0)
    };
    let Some(value) = value else {
        return (2.0, 2.0);
    };
    match value.split_once(',') {
        Some((a, b)) => {
            let a = parse(a).unwrap_or(2.0);
            (a, parse(b).unwrap_or(a))
        }
        None => {
            let a = parse(value).unwrap_or(2.0);
            (a, a)
        }
    }
}

/// `adjust-cell-height`: "10%" is 10% taller (1.1); a plain number is
/// pixels added to the cell, taken against a typical monospace line
/// (1.2 x the font size). xterm.js cannot go below 1.
fn line_height(value: Option<&str>, font_size_px: f64) -> f64 {
    let Some(value) = value.map(str::trim) else {
        return 1.0;
    };
    let height = if let Some(percent) = value.strip_suffix('%') {
        percent.trim().parse::<f64>().ok().map(|p| 1.0 + p / 100.0)
    } else {
        value
            .parse::<f64>()
            .ok()
            .map(|px| 1.0 + px / (font_size_px * 1.2))
    };
    match height {
        Some(h) if h.is_finite() => h.max(1.0),
        _ => 1.0,
    }
}

/// `#rrggbb` for a hex color with or without `#` (`#rgb` expanded); any
/// other text as written.
fn color(value: &str) -> String {
    let value = value.trim();
    let hex = value.strip_prefix('#').unwrap_or(value);
    if hex.bytes().all(|b| b.is_ascii_hexdigit()) {
        if hex.len() == 6 {
            return format!("#{}", hex.to_ascii_lowercase());
        }
        if hex.len() == 3 {
            let expanded: String = hex.chars().flat_map(|c| [c, c]).collect();
            return format!("#{}", expanded.to_ascii_lowercase());
        }
    }
    value.to_string()
}

/// Ghostty's cursor and selection colors may follow the cell instead of
/// naming one; xterm.js has no such option, so those are left unset.
fn optional_color(value: &str) -> Option<String> {
    match value.trim().to_ascii_lowercase().as_str() {
        "" | "cell-foreground" | "cell-background" => None,
        _ => Some(color(value)),
    }
}

/// Applies the color keys in `values` to `theme`.
fn apply(theme: &mut Theme, values: &ConfigValues) {
    if let Some(v) = values.string("background").filter(|v| !v.is_empty()) {
        theme.background = color(v);
    }
    if let Some(v) = values.string("foreground").filter(|v| !v.is_empty()) {
        theme.foreground = color(v);
    }
    if let Some(v) = values.string("cursor-color") {
        theme.cursor = optional_color(v);
    }
    if let Some(v) = values.string("cursor-text") {
        theme.cursor_text = optional_color(v);
    }
    if let Some(v) = values.string("selection-background") {
        theme.selection_background = optional_color(v);
    }
    if let Some(v) = values.string("selection-foreground") {
        theme.selection_foreground = optional_color(v);
    }
    for entry in values.all("palette") {
        let Some((index, value)) = entry.split_once('=') else {
            continue;
        };
        let Ok(index) = index.trim().parse::<usize>() else {
            continue;
        };
        if index < theme.palette.len() && !value.trim().is_empty() {
            theme.palette[index] = Some(color(value));
        }
    }
}

/// `theme = X` colors both appearances; `theme = light:A,dark:B` each.
fn theme_names(value: &str) -> (String, String) {
    let mut light = None;
    let mut dark = None;
    for part in value.split(',') {
        let part = part.trim();
        if let Some(name) = part.strip_prefix("light:") {
            light = Some(name.trim().to_string());
        } else if let Some(name) = part.strip_prefix("dark:") {
            dark = Some(name.trim().to_string());
        }
    }
    match (light, dark) {
        (None, None) => (value.trim().to_string(), value.trim().to_string()),
        (Some(light), None) => (light.clone(), light),
        (None, Some(dark)) => (dark.clone(), dark),
        (Some(light), Some(dark)) => (light, dark),
    }
}

fn themes(values: &ConfigValues, theme_text: &dyn Fn(&str) -> Option<String>) -> ThemePair {
    let build = |name: Option<&str>| {
        let mut theme = Theme::default();
        if let Some(text) = name.filter(|n| !n.is_empty()).and_then(theme_text) {
            apply(&mut theme, &ConfigValues::new(&text));
        }
        apply(&mut theme, values);
        theme
    };
    match values.string("theme").filter(|v| !v.trim().is_empty()) {
        Some(value) => {
            let (light, dark) = theme_names(value);
            ThemePair {
                light: build(Some(&light)),
                dark: build(Some(&dark)),
            }
        }
        None => {
            let theme = build(None);
            ThemePair {
                light: theme.clone(),
                dark: theme,
            }
        }
    }
}

/// Whether Windows ghostgrid cannot honor `key`: shaders, background
/// images and blur, window decorations, and macOS-, GTK- and
/// quick-terminal-only options.
fn is_unsupported(key: &str) -> bool {
    key == "window-decoration"
        || [
            "custom-shader",
            "background-image",
            "background-blur",
            "macos-",
            "quick-terminal-",
            "gtk-",
        ]
        .iter()
        .any(|prefix| key.starts_with(prefix))
}

fn unsupported(values: &ConfigValues) -> Vec<String> {
    let mut found: Vec<String> = Vec::new();
    for key in values.keys() {
        if is_unsupported(key) && !found.iter().any(|k| k == key) {
            found.push(key.to_string());
        }
    }
    found
}
