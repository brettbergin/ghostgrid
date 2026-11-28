//! Contract for saving and restoring windows (SessionTests,
//! SessionTabsTests): version 2 with tabs, version 1 upgraded, unknown tab
//! colors dropped, restore skipping empty tabs and windows. Frames are
//! Windows screen coordinates (origin top-left) saved as objects; the
//! macOS array form still reads.

use ghostgrid_core::session::{
    Frame, LayoutWeights, Pane, Session, SessionPolicy, Tab, TabColor, Window,
};

fn pane(shell: &str, folder: Option<&str>, id: Option<&str>) -> Pane {
    Pane::new(shell, folder.map(String::from), id.map(String::from))
}

fn window(frame: Frame, tabs: Vec<Tab>, selected_tab: Option<usize>) -> Window {
    Window {
        frame,
        tabs,
        selected_tab,
        maximized: None,
    }
}

fn tab(panes: Vec<Pane>) -> Tab {
    Tab {
        panes,
        ..Default::default()
    }
}

fn named(name: &str, panes: Vec<Pane>) -> Tab {
    Tab {
        name: Some(name.into()),
        panes,
        ..Default::default()
    }
}

fn session() -> Session {
    Session::new(vec![window(
        Frame::new(100.0, 200.0, 1280.0, 800.0),
        vec![Tab {
            panes: vec![
                pane("pwsh", Some("C:\\Users\\me\\code"), None),
                pane("nushell", None, None),
            ],
            focused: Some(1),
            ..Default::default()
        }],
        None,
    )])
}

fn tabbed() -> Session {
    Session::new(vec![window(
        Frame::new(10.0, 20.0, 1280.0, 800.0),
        vec![
            Tab {
                layout: Some("grid".into()),
                ..tab(vec![pane("pwsh", Some("C:\\code"), Some("a"))])
            },
            Tab {
                name: Some("logs".into()),
                color: Some(TabColor::Teal),
                panes: vec![
                    pane("gitbash", None, Some("b")),
                    pane("pwsh", Some("C:\\tmp"), None),
                ],
                focused: Some(1),
                zoomed: Some(0),
                layout: Some("mainStack".into()),
                weights: Some(LayoutWeights {
                    tracks: vec![1.2, 0.8],
                    cells: vec![vec![1.0], vec![1.0]],
                }),
                rows: Some(vec![2]),
                rotated: Some(true),
            },
        ],
        Some(1),
    )])
}

#[test]
fn round_trips_through_json() {
    assert_eq!(Session::decode(&session().encode()), Some(session()));
    assert_eq!(Session::CURRENT_VERSION, 2);
}

#[test]
fn rejects_garbage_and_unknown_versions() {
    assert_eq!(Session::decode("not json"), None);
    let mut future = session();
    future.version = 99;
    assert_eq!(Session::decode(&future.encode()), None);
    for version in [0, 3, 99] {
        assert_eq!(
            Session::decode(&format!(r#"{{"version":{version},"windows":[]}}"#)),
            None,
            "version {version}"
        );
    }
}

#[test]
fn restorable_drops_empty_windows_and_bad_indices() {
    let messy = Session::new(vec![
        window(Frame::default(), vec![tab(vec![])], None),
        window(
            Frame::default(),
            vec![Tab {
                focused: Some(5),
                zoomed: Some(0),
                ..tab(vec![pane("cmd", Some("C:\\tmp"), None)])
            }],
            None,
        ),
    ]);
    let restorable = messy.restorable();
    assert_eq!(restorable.len(), 1);
    assert_eq!(restorable[0].tabs[0].focused, None);
    assert_eq!(restorable[0].tabs[0].zoomed, Some(0));
}

#[test]
fn the_json_keys_match_the_mac_app() {
    let json: serde_json::Value = serde_json::from_str(&tabbed().encode()).unwrap();
    assert_eq!(json["version"], 2);
    let window = &json["windows"][0];
    assert_eq!(window["selectedTab"], 1);
    assert_eq!(
        window["frame"],
        serde_json::json!({"x": 10.0, "y": 20.0, "width": 1280.0, "height": 800.0})
    );
    assert!(
        window.get("maximized").is_none(),
        "nothing saved for what is unset"
    );
    let logs = &window["tabs"][1];
    assert_eq!(logs["color"], "teal");
    assert_eq!(logs["weights"]["tracks"], serde_json::json!([1.2, 0.8]));
    assert_eq!(logs["panes"][0]["sessionID"], "b");
    assert_eq!(logs["panes"][1]["workingDirectory"], "C:\\tmp");
    assert!(logs["panes"][0].get("workingDirectory").is_none());
    let first = &window["tabs"][0];
    assert!(first.get("name").is_none() && first.get("color").is_none());
    let text = tabbed().encode();
    assert!(text.contains('\n'), "pretty printed");
    assert!(
        text.find("\"selectedTab\"").unwrap() < text.find("\"tabs\"").unwrap(),
        "keys sorted"
    );
}

#[test]
fn a_maximized_window_round_trips() {
    let mut session = session();
    session.windows[0].maximized = Some(true);
    assert_eq!(
        Session::decode(&session.encode()).unwrap().windows[0].maximized,
        Some(true)
    );
}

// SessionPolicy: Windows has no system setting to follow.

#[test]
fn follows_window_save_state() {
    assert!(SessionPolicy::should_restore(Some("always"), false));
    assert!(SessionPolicy::should_restore(Some("Always"), false));
    assert!(!SessionPolicy::should_restore(Some("never"), true));
    assert!(
        SessionPolicy::should_restore(Some("default"), true),
        "kept shells come back with their windows"
    );
    assert!(!SessionPolicy::should_restore(Some("default"), false));
    assert!(!SessionPolicy::should_restore(None, false));
    assert!(SessionPolicy::should_restore(None, true));
}

const SCREEN: Frame = Frame {
    x: 0.0,
    y: 0.0,
    width: 1728.0,
    height: 1117.0,
};

fn contains(outer: Frame, inner: Frame) -> bool {
    inner.x >= outer.x
        && inner.y >= outer.y
        && inner.x + inner.width <= outer.x + outer.width
        && inner.y + inner.height <= outer.y + outer.height
}

#[test]
fn keeps_frames_that_are_on_screen() {
    let frame = Frame::new(100.0, 100.0, 1280.0, 800.0);
    assert_eq!(
        SessionPolicy::fit(frame, &[SCREEN], SessionPolicy::MINIMUM_VISIBLE),
        Some(frame)
    );
    let second = Frame::new(1728.0, 0.0, 1920.0, 1080.0);
    let there = Frame::new(1800.0, 50.0, 800.0, 600.0);
    assert_eq!(
        SessionPolicy::fit(there, &[SCREEN, second], SessionPolicy::MINIMUM_VISIBLE),
        Some(there)
    );
}

#[test]
fn moves_frames_from_a_missing_display_onto_the_main_screen() {
    let off_screen = Frame::new(3000.0, 0.0, 1280.0, 800.0);
    let fitted = SessionPolicy::fit(off_screen, &[SCREEN], SessionPolicy::MINIMUM_VISIBLE).unwrap();
    assert!(contains(SCREEN, fitted));
    assert_eq!(
        (fitted.width, fitted.height),
        (off_screen.width, off_screen.height)
    );
}

#[test]
fn shrinks_frames_bigger_than_the_screen() {
    let huge = Frame::new(5000.0, 5000.0, 4000.0, 3000.0);
    let fitted = SessionPolicy::fit(huge, &[SCREEN], SessionPolicy::MINIMUM_VISIBLE).unwrap();
    assert_eq!((fitted.width, fitted.height), (SCREEN.width, SCREEN.height));
}

#[test]
fn a_frame_mostly_off_screen_moves() {
    let barely = Frame::new(1700.0, 0.0, 1000.0, 800.0);
    assert_ne!(SessionPolicy::fit(barely, &[SCREEN], 0.3), Some(barely));
}

#[test]
fn no_screens_means_no_frame() {
    assert_eq!(SessionPolicy::fit(Frame::default(), &[], 0.3), None);
}

#[test]
fn layout_round_trips_and_old_sessions_still_decode() {
    let session = Session::new(vec![window(
        Frame::default(),
        vec![Tab {
            layout: Some("mainStack".into()),
            ..tab(vec![pane("pwsh", None, None)])
        }],
        None,
    )]);
    assert_eq!(
        Session::decode(&session.encode()).unwrap().windows[0].tabs[0]
            .layout
            .as_deref(),
        Some("mainStack")
    );
    let old = r#"{"version":1,"windows":[{"frame":[[0,0],[10,10]],"panes":[{"shell":"zsh"}]}]}"#;
    assert_eq!(
        Session::decode(old).unwrap().windows[0].tabs[0].layout,
        None
    );
}

// SessionTabsTests

#[test]
fn tabs_round_trip_with_their_name_color_and_layout() {
    let decoded = Session::decode(&tabbed().encode()).unwrap();
    assert_eq!(decoded, tabbed());
    assert_eq!(decoded.version, 2);
    assert_eq!(decoded.windows[0].selected_tab, Some(1));
    assert_eq!(
        decoded.windows[0]
            .tabs
            .iter()
            .map(|t| t.name.clone())
            .collect::<Vec<_>>(),
        [None, Some("logs".into())]
    );
    assert_eq!(
        decoded.windows[0]
            .tabs
            .iter()
            .map(|t| t.color)
            .collect::<Vec<_>>(),
        [None, Some(TabColor::Teal)]
    );
    assert_eq!(decoded.windows[0].tabs[1].rotated, Some(true));
}

/// session.json as ghostgrid 0.2.1 writes it: version 1, no tabs.
const VERSION_1: &str = r#"
{
  "version" : 1,
  "windows" : [
    {
      "focused" : 1,
      "frame" : [[100, 200], [1280, 800]],
      "layout" : "mainStack",
      "panes" : [
        {"sessionID" : "s1", "shell" : "zsh", "workingDirectory" : "/Users/me/code"},
        {"shell" : "nushell"}
      ],
      "rotated" : true,
      "rows" : [1, 1],
      "weights" : {"cells" : [[1.35], [0.6, 0.8]], "tracks" : [0.7, 1.3]},
      "zoomed" : 0
    },
    {"frame" : [[0, 0], [800, 600]], "panes" : [{"shell" : "bash", "sessionID" : "s2"}]}
  ]
}
"#;

#[test]
fn a_version_1_session_loads_as_one_tab_per_window() {
    let session = Session::decode(VERSION_1).unwrap();
    assert_eq!(session.version, Session::CURRENT_VERSION);
    assert_eq!(session.windows.len(), 2);
    let window = &session.windows[0];
    assert_eq!(window.frame, Frame::new(100.0, 200.0, 1280.0, 800.0));
    assert_eq!(window.selected_tab, Some(0));
    assert_eq!(window.tabs.len(), 1);
    let tab = &window.tabs[0];
    assert_eq!(tab.name, None);
    assert_eq!(tab.color, None);
    assert_eq!(
        tab.panes,
        [
            pane("zsh", Some("/Users/me/code"), Some("s1")),
            pane("nushell", None, None)
        ]
    );
    assert_eq!(tab.focused, Some(1));
    assert_eq!(tab.zoomed, Some(0));
    assert_eq!(tab.layout.as_deref(), Some("mainStack"));
    assert_eq!(tab.rows, Some(vec![1, 1]));
    assert_eq!(tab.rotated, Some(true));
    assert_eq!(
        tab.weights,
        Some(LayoutWeights {
            tracks: vec![0.7, 1.3],
            cells: vec![vec![1.35], vec![0.6, 0.8]]
        })
    );
    let plain = &session.windows[1].tabs[0];
    assert!(
        plain.layout.is_none()
            && plain.weights.is_none()
            && plain.rows.is_none()
            && plain.rotated.is_none()
    );
    assert_eq!(
        session.live_session_ids(),
        ["s1", "s2"],
        "kept shells survive the update"
    );
}

#[test]
fn an_unknown_tab_color_is_dropped_not_the_session() {
    let json = r#"{"version":2,"windows":[{"frame":[[0,0],[10,10]],"selectedTab":0,
        "tabs":[{"name":"api","color":"chartreuse","panes":[{"shell":"zsh"}]},
                {"color":7,"panes":[{"shell":"zsh"}]}]}]}"#;
    let session = Session::decode(json).unwrap();
    assert_eq!(session.windows[0].tabs[0].name.as_deref(), Some("api"));
    assert_eq!(session.windows[0].tabs[0].color, None);
    assert_eq!(session.windows[0].tabs[1].color, None);
}

#[test]
fn restoring_skips_empty_tabs_and_windows_and_keeps_the_selected_tab() {
    let p = || pane("pwsh", None, None);
    let messy = Session::new(vec![
        window(Frame::default(), vec![tab(vec![])], None),
        window(
            Frame::default(),
            vec![
                tab(vec![]),
                Tab {
                    focused: Some(5),
                    zoomed: Some(0),
                    ..named("b", vec![p()])
                },
                named("c", vec![p()]),
            ],
            Some(2),
        ),
        window(
            Frame::default(),
            vec![named("d", vec![p()]), tab(vec![])],
            Some(1),
        ),
        window(Frame::default(), vec![named("e", vec![p()])], Some(7)),
        window(Frame::default(), vec![named("f", vec![p()])], None),
        window(Frame::default(), vec![], None),
    ]);
    let restorable = messy.restorable();
    assert_eq!(
        restorable
            .iter()
            .map(|w| w
                .tabs
                .iter()
                .filter_map(|t| t.name.clone())
                .collect::<Vec<_>>())
            .collect::<Vec<_>>(),
        [
            vec!["b".to_string(), "c".into()],
            vec!["d".into()],
            vec!["e".into()],
            vec!["f".into()]
        ]
    );
    assert_eq!(restorable[0].selected_tab, Some(1), "still tab c");
    assert_eq!(restorable[0].tabs[0].focused, None);
    assert_eq!(restorable[0].tabs[0].zoomed, Some(0));
    assert_eq!(
        restorable[1].selected_tab,
        Some(0),
        "the selected tab was empty: its neighbour"
    );
    assert_eq!(restorable[2].selected_tab, Some(0));
    assert_eq!(restorable[3].selected_tab, Some(0));
}

#[test]
fn every_kept_shell_is_found_across_windows_and_tabs() {
    let session = Session::new(vec![
        window(
            Frame::default(),
            vec![
                tab(vec![
                    pane("pwsh", None, Some("a")),
                    pane("pwsh", None, None),
                ]),
                tab(vec![pane("cmd", None, Some("b"))]),
            ],
            None,
        ),
        window(
            Frame::default(),
            vec![tab(vec![pane("wsl", None, Some("c"))])],
            None,
        ),
    ]);
    assert_eq!(session.live_session_ids(), ["a", "b", "c"]);
}

#[test]
fn tab_colors_have_titles_and_rgb() {
    assert_eq!(TabColor::ALL.len(), 8);
    assert_eq!(TabColor::Teal.title(), "Teal");
    assert_eq!(TabColor::Red.rgb(), 0xF38BA8);
}
