//! Contract for the helper's log when something stops it: the line names
//! who sent it, by process ID and executable, and what started that
//! process (QuitSenderTests).

use ghostgrid_core::quit_sender::QuitSender;

fn sender(
    pid: Option<u32>,
    path: Option<&str>,
    parent_pid: Option<u32>,
    parent_path: Option<&str>,
) -> QuitSender {
    QuitSender {
        pid,
        path: path.map(String::from),
        parent_pid,
        parent_path: parent_path.map(String::from),
    }
}

#[test]
fn a_sender_is_named_with_what_started_it() {
    let text = sender(
        Some(812),
        Some("C:\\Windows\\System32\\taskkill.exe"),
        Some(640),
        Some("C:\\Windows\\System32\\cmd.exe"),
    )
    .to_string();
    assert_eq!(
        text,
        "from pid 812 C:\\Windows\\System32\\taskkill.exe (started by pid 640 C:\\Windows\\System32\\cmd.exe)"
    );
}

#[test]
fn a_process_without_a_parent_names_none() {
    // launchd on macOS; System on Windows.
    assert_eq!(
        sender(Some(4), Some("System"), Some(0), None).to_string(),
        "from pid 4 System"
    );
}

#[test]
fn a_parent_already_gone_is_still_named_by_its_id() {
    assert_eq!(
        sender(Some(812), Some("a.exe"), Some(640), None).to_string(),
        "from pid 812 a.exe (started by pid 640 (no longer running))"
    );
}

#[test]
fn a_sender_already_gone_is_still_named_by_its_id() {
    assert_eq!(
        sender(Some(4242), None, None, None).to_string(),
        "from pid 4242 (no longer running)"
    );
}

#[test]
fn an_event_without_a_sender_says_so() {
    assert_eq!(
        sender(None, None, None, None).to_string(),
        "from an unknown sender"
    );
    assert_eq!(
        sender(Some(0), None, None, None).to_string(),
        "from an unknown sender"
    );
}
