//! Contract for the terminal options the Windows app hands xterm.js: each
//! Ghostty option ghostgrid can honor, mapped to xterm.js's terms, with
//! Ghostty's defaults, and the options it cannot honor listed.

use ghostgrid_core::config::terminal::{self, TerminalSettings, Theme};
use ghostgrid_core::config::{theme_lookup, ConfigValues};
use std::collections::HashMap;
use std::path::{Path, PathBuf};

fn read(text: &str) -> TerminalSettings {
    terminal::settings(&ConfigValues::new(text), &|_| None)
}

fn with_themes(text: &str, themes: &[(&str, &str)]) -> TerminalSettings {
    let themes: HashMap<String, String> = themes
        .iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect();
    terminal::settings(&ConfigValues::new(text), &|name| themes.get(name).cloned())
}

const MOCHA: &str = "background = 1e1e2e\nforeground = #CDD6F4\ncursor-color = f5e0dc\ncursor-text = #11111b\n\
                     selection-background = 585b70\nselection-foreground = cdd6f4\npalette = 0=#45475a\npalette = 15=a6adc8\n";
const LATTE: &str = "background = eff1f5\nforeground = 4c4f69\n";

#[test]
fn an_empty_config_gets_ghosttys_defaults() {
    let s = read("");
    assert_eq!(
        s.font_family,
        ["JetBrains Mono", "Cascadia Mono", "Consolas"]
    );
    assert!((s.font_size_px - 13.0 * 4.0 / 3.0).abs() < 1e-9);
    assert_eq!(s.themes.light, s.themes.dark);
    let theme = &s.themes.dark;
    assert_eq!(theme.background, "#282c34");
    assert_eq!(theme.foreground, "#ffffff");
    assert_eq!(theme.cursor, None);
    assert_eq!(theme.cursor_text, None);
    assert_eq!(theme.selection_background, None);
    assert_eq!(theme.selection_foreground, None);
    assert_eq!(theme.palette, vec![None; 16]);
    assert_eq!(s.cursor_style, "block");
    assert_eq!(s.cursor_blink, None);
    assert_eq!(s.scrollback_lines, 10_000);
    assert_eq!((s.padding.x, s.padding.y), (2.0, 2.0));
    assert_eq!(s.background_opacity, 1.0);
    assert_eq!(s.line_height, 1.0);
    assert!(!s.mouse_hide_while_typing);
    assert_eq!(s.unfocused_split_opacity, 0.7);
    assert!(s.copy_on_select);
    assert_eq!(s.window_save_state, None);
    assert_eq!(s.minimum_contrast, 1.0);
    assert!(!s.bold_is_bright);
    assert_eq!(s.shell_integration, None);
    assert_eq!(s.shell_integration_features, None);
    assert!(s.confirm_close_surface);
    assert!(s.unsupported.is_empty());
}

#[test]
fn the_users_fonts_come_first_with_the_fallbacks_after() {
    let s = read("font-family = Fira Code\nfont-family = \"Cascadia Mono\"\n");
    assert_eq!(
        s.font_family,
        ["Fira Code", "Cascadia Mono", "JetBrains Mono", "Consolas"]
    );
    let reset = read("font-family = Fira Code\nfont-family = \"\"\nfont-family = Iosevka\n");
    assert_eq!(
        reset.font_family,
        ["Iosevka", "JetBrains Mono", "Cascadia Mono", "Consolas"]
    );
}

#[test]
fn font_size_points_become_pixels() {
    assert_eq!(read("font-size = 15").font_size_px, 20.0);
    assert!((read("font-size = huge").font_size_px - 13.0 * 4.0 / 3.0).abs() < 1e-9);
}

#[test]
fn one_theme_colors_both_appearances() {
    let s = with_themes("theme = Mocha", &[("Mocha", MOCHA)]);
    assert_eq!(s.themes.light, s.themes.dark);
    let theme: &Theme = &s.themes.dark;
    assert_eq!(theme.background, "#1e1e2e");
    assert_eq!(theme.foreground, "#cdd6f4");
    assert_eq!(theme.cursor.as_deref(), Some("#f5e0dc"));
    assert_eq!(theme.cursor_text.as_deref(), Some("#11111b"));
    assert_eq!(theme.selection_background.as_deref(), Some("#585b70"));
    assert_eq!(theme.selection_foreground.as_deref(), Some("#cdd6f4"));
    assert_eq!(theme.palette[0].as_deref(), Some("#45475a"));
    assert_eq!(theme.palette[15].as_deref(), Some("#a6adc8"));
    assert_eq!(theme.palette[1], None);
}

#[test]
fn a_light_and_dark_theme_pair_colors_each_appearance() {
    let s = with_themes(
        "theme = light:Latte,dark:Mocha",
        &[("Mocha", MOCHA), ("Latte", LATTE)],
    );
    assert_eq!(s.themes.light.background, "#eff1f5");
    assert_eq!(s.themes.dark.background, "#1e1e2e");
    let spaced = with_themes(
        "theme = \"dark: Mocha , light: Latte\"",
        &[("Mocha", MOCHA), ("Latte", LATTE)],
    );
    assert_eq!(spaced.themes.light.background, "#eff1f5");
    assert_eq!(spaced.themes.dark.background, "#1e1e2e");
}

#[test]
fn the_users_own_colors_win_over_the_theme() {
    let s = with_themes(
        "theme = light:Latte,dark:Mocha\nbackground = #000000\npalette = 0=#FF0000\npalette = 3 = 00ff00\n",
        &[("Mocha", MOCHA), ("Latte", LATTE)],
    );
    for theme in [&s.themes.light, &s.themes.dark] {
        assert_eq!(theme.background, "#000000");
        assert_eq!(theme.palette[0].as_deref(), Some("#ff0000"));
        assert_eq!(theme.palette[3].as_deref(), Some("#00ff00"));
    }
    assert_eq!(
        s.themes.dark.foreground, "#cdd6f4",
        "what the user did not set still comes from the theme"
    );
}

#[test]
fn colors_are_normalized_when_they_are_hex() {
    let s = read("background = ABCDEF\nforeground = black\ncursor-color = #FFF\npalette = 99=#123456\npalette = x\n");
    assert_eq!(s.themes.dark.background, "#abcdef");
    assert_eq!(s.themes.dark.foreground, "black");
    assert_eq!(s.themes.dark.cursor.as_deref(), Some("#ffffff"));
    assert_eq!(
        s.themes.dark.palette,
        vec![None; 16],
        "out-of-range and malformed entries are ignored"
    );
    assert_eq!(
        read("cursor-color = cell-foreground").themes.dark.cursor,
        None
    );
}

#[test]
fn an_unknown_theme_is_ignored() {
    assert_eq!(read("theme = Nope").themes.dark.background, "#282c34");
}

#[test]
fn cursor_options_map_to_xterm() {
    assert_eq!(read("cursor-style = bar").cursor_style, "bar");
    assert_eq!(read("cursor-style = underline").cursor_style, "underline");
    assert_eq!(read("cursor-style = block_hollow").cursor_style, "block");
    assert_eq!(read("cursor-style = squiggle").cursor_style, "block");
    assert_eq!(read("cursor-style-blink = false").cursor_blink, Some(false));
    assert_eq!(read("cursor-style-blink = true").cursor_blink, Some(true));
}

#[test]
fn scrollback_bytes_become_lines() {
    assert_eq!(read("scrollback-limit = 5000000").scrollback_lines, 5000);
    assert_eq!(read("scrollback-limit = 100").scrollback_lines, 1000);
    assert_eq!(
        read("scrollback-limit = 1000000000000").scrollback_lines,
        100_000
    );
}

#[test]
fn padding_takes_one_or_two_values() {
    let s = read("window-padding-x = 4,8\nwindow-padding-y = 6");
    assert_eq!(
        (s.padding.x, s.padding.left, s.padding.right),
        (4.0, 4.0, 8.0)
    );
    assert_eq!(
        (s.padding.y, s.padding.top, s.padding.bottom),
        (6.0, 6.0, 6.0)
    );
}

#[test]
fn cell_height_adjustments_become_a_line_height() {
    assert!((read("adjust-cell-height = 10%").line_height - 1.1).abs() < 1e-9);
    assert_eq!(
        read("adjust-cell-height = -50%").line_height,
        1.0,
        "xterm.js cannot go below 1"
    );
    let px = read("adjust-cell-height = 4").line_height;
    assert!(px > 1.0 && px < 2.0, "{px}");
    assert_eq!(read("adjust-cell-height = tall").line_height, 1.0);
}

#[test]
fn opacities_are_clamped() {
    assert_eq!(
        read("unfocused-split-opacity = 0.05").unfocused_split_opacity,
        0.15
    );
    assert_eq!(
        read("unfocused-split-opacity = 3").unfocused_split_opacity,
        1.0
    );
    assert_eq!(read("background-opacity = 0.8").background_opacity, 0.8);
    assert_eq!(read("background-opacity = 7").background_opacity, 1.0);
}

#[test]
fn behavior_options_are_read() {
    assert!(read("copy-on-select = clipboard").copy_on_select);
    assert!(!read("copy-on-select = false").copy_on_select);
    assert!(read("copy-on-select = true").copy_on_select);
    assert!(!read("confirm-close-surface = false").confirm_close_surface);
    assert!(read("confirm-close-surface = always").confirm_close_surface);
    assert!(read("mouse-hide-while-typing = true").mouse_hide_while_typing);
    assert!(read("bold-is-bright = true").bold_is_bright);
    assert_eq!(read("minimum-contrast = 3").minimum_contrast, 3.0);
    let s = read("window-save-state = never\nshell-integration = none\nshell-integration-features = no-cursor");
    assert_eq!(s.window_save_state.as_deref(), Some("never"));
    assert_eq!(s.shell_integration.as_deref(), Some("none"));
    assert_eq!(s.shell_integration_features.as_deref(), Some("no-cursor"));
}

#[test]
fn options_windows_cannot_honor_are_listed_once() {
    let s = read(
        "custom-shader = a\nmacos-titlebar-style = tabs\nfont-size = 12\ncustom-shader = b\ngtk-single-instance = true\n\
         quick-terminal-position = top\nbackground-blur = 20\nwindow-decoration = false\nbackground-image = x.png\n",
    );
    assert_eq!(
        s.unsupported,
        [
            "custom-shader",
            "macos-titlebar-style",
            "gtk-single-instance",
            "quick-terminal-position",
            "background-blur",
            "window-decoration",
            "background-image",
        ]
    );
}

#[test]
fn settings_serialize_in_camel_case() {
    let json = serde_json::to_value(read("")).unwrap();
    for key in [
        "fontFamily",
        "fontSizePx",
        "themes",
        "cursorStyle",
        "cursorBlink",
        "scrollbackLines",
        "padding",
        "backgroundOpacity",
        "lineHeight",
        "mouseHideWhileTyping",
        "unfocusedSplitOpacity",
        "copyOnSelect",
        "windowSaveState",
        "minimumContrast",
        "boldIsBright",
        "shellIntegration",
        "shellIntegrationFeatures",
        "confirmCloseSurface",
        "unsupported",
    ] {
        assert!(json.get(key).is_some(), "{key}");
    }
    let theme = &json["themes"]["dark"];
    for key in [
        "background",
        "foreground",
        "cursor",
        "cursorText",
        "selectionBackground",
        "selectionForeground",
        "palette",
    ] {
        assert!(theme.get(key).is_some(), "{key}");
    }
}

#[test]
fn themes_are_found_by_path_or_in_each_folder() {
    let files: HashMap<PathBuf, String> = [
        (PathBuf::from("C:\\themes\\Mocha"), "a".to_string()),
        (PathBuf::from("D:\\more\\Mocha"), "b".into()),
        (PathBuf::from("D:\\more\\Latte"), "c".into()),
        (PathBuf::from("E:\\mine.theme"), "d".into()),
    ]
    .into_iter()
    .collect();
    let read = |path: &Path| files.get(path).cloned();
    let dirs = [PathBuf::from("C:\\themes"), PathBuf::from("D:\\more")];
    assert_eq!(theme_lookup("Mocha", &dirs, &read).as_deref(), Some("a"));
    assert_eq!(theme_lookup("Latte", &dirs, &read).as_deref(), Some("c"));
    assert_eq!(
        theme_lookup("E:\\mine.theme", &dirs, &read).as_deref(),
        Some("d")
    );
    assert_eq!(theme_lookup("Nope", &dirs, &read), None);
}
