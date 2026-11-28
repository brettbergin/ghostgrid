//! Contract for the bounded output history a reattach replays
//! (OutputHistoryTests).

use ghostgrid_core::history::OutputHistory;

#[test]
fn replay_starts_with_a_reset_and_keeps_everything_when_small() {
    let mut history = OutputHistory::with_capacity(100);
    history.append(b"hello\n");
    history.append(b"world");
    assert_eq!(history.replay(), b"\x1bchello\nworld".to_vec());
}

#[test]
fn keeps_only_the_newest_bytes_and_starts_at_a_line_boundary() {
    let mut history = OutputHistory::with_capacity(16);
    history.append(b"first line\nsecond line\nthird\n");
    let replay = String::from_utf8(history.replay()).unwrap();
    assert!(replay.starts_with("\x1bc"));
    assert!(!replay.contains("first"));
    assert!(replay.ends_with("third\n"));
    assert!(history.replay().len() <= 16 + 2);
}

#[test]
fn many_small_appends_stay_bounded() {
    let mut history = OutputHistory::with_capacity(64);
    for index in 0..1000 {
        history.append(format!("line {index}\n").as_bytes());
    }
    let replay = String::from_utf8(history.replay()).unwrap();
    assert!(replay.len() <= 64 + 2);
    assert!(replay.ends_with("line 999\n"));
    assert!(
        replay[2..].starts_with("line "),
        "starts on a whole line: {replay:?}"
    );
}

#[test]
fn the_default_capacity_is_four_mebibytes() {
    assert_eq!(OutputHistory::new().capacity(), 4 << 20);
    assert_eq!(
        OutputHistory::new().replay(),
        b"\x1bc".to_vec(),
        "an empty history replays just the reset"
    );
}
