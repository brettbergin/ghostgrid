//! End to end against the built ghostgrid-sessiond (ported from the macOS
//! Tests/GhostGridTests/SessionDaemonTests.swift): a shell keeps running
//! when its pane disconnects, a reattach replays its output and takes input
//! again, a newer pane takes a shell over, terminating it ends it for good,
//! and only one helper serves a pipe, which admits only the user.
//!
//! Every test starts its own helper on its own pipe and kills it (and the
//! shells under it) when done. The shell is cmd.exe, which is always there.
#![cfg(windows)]

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use ghostgrid_core::protocol::{FrameDecoder, SessionLaunch, SessionMessage, PROTOCOL_VERSION};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::windows::named_pipe::NamedPipeClient;

const HELPER: &str = env!("CARGO_BIN_EXE_ghostgrid-sessiond");
const CMD: &str = r"C:\Windows\System32\cmd.exe";
/// ConPTY can be slow to start a console and to render, especially when
/// many tests start shells at once.
const OUTPUT_TIMEOUT: Duration = Duration::from_secs(30);
const SHORT_TIMEOUT: Duration = Duration::from_secs(10);

// ---------------------------------------------------------------- helper

/// A running helper on a pipe of its own; killed (with its shells) on drop.
struct Helper {
    child: Option<Child>,
    pipe: String,
    log: PathBuf,
}

fn unique_suffix() -> String {
    static COUNTER: AtomicU32 = AtomicU32::new(0);
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.subsec_nanos()).unwrap_or(0);
    format!("{}-{}-{nanos}", std::process::id(), COUNTER.fetch_add(1, Ordering::SeqCst))
}

fn unique_pipe() -> String {
    format!(r"\\.\pipe\ghostgrid-test-{}", unique_suffix())
}

fn spawn_helper(pipe: &str, log: &PathBuf) -> Child {
    Command::new(HELPER)
        .args(["--pipe", pipe, "--log"])
        .arg(log)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("start ghostgrid-sessiond")
}

impl Helper {
    /// Starts a helper and waits until it accepts connections.
    async fn start() -> Helper {
        let pipe = unique_pipe();
        let log = std::env::temp_dir().join(format!("ghostgrid-sessiond-test-{}.log", unique_suffix()));
        let child = spawn_helper(&pipe, &log);
        let helper = Helper { child: Some(child), pipe, log };
        helper.wait_listening().await;
        helper
    }

    async fn wait_listening(&self) {
        let deadline = Instant::now() + SHORT_TIMEOUT;
        loop {
            match ghostgrid_sessiond::pipe::connect(&self.pipe, Duration::from_secs(1)).await {
                // A probe connection: closed straight away.
                Ok(probe) => {
                    drop(probe);
                    return;
                }
                Err(e) if Instant::now() < deadline => {
                    let _ = e;
                    tokio::time::sleep(Duration::from_millis(50)).await;
                }
                Err(e) => panic!("sessiond did not start listening on {}: {e}\nlog:\n{}", self.pipe, self.log_text()),
            }
        }
    }

    async fn connect(&self) -> Client {
        Client::connect(&self.pipe).await
    }

    /// A connected client that has been welcomed.
    async fn greeted(&self) -> Client {
        let mut client = self.connect().await;
        client.send(&SessionMessage::Hello { version: PROTOCOL_VERSION }).await;
        let got = client.receive_until(SHORT_TIMEOUT, |m| m.contains(&welcome())).await;
        assert!(got.contains(&welcome()), "no Welcome: {got:?}");
        client
    }

    fn pid(&self) -> u32 {
        self.child.as_ref().expect("helper running").id()
    }

    fn try_wait(&mut self) -> Option<ExitStatus> {
        self.child.as_mut().and_then(|c| c.try_wait().ok().flatten())
    }

    fn log_text(&self) -> String {
        std::fs::read_to_string(&self.log).unwrap_or_default()
    }
}

impl Drop for Helper {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            if child.try_wait().ok().flatten().is_none() {
                // The whole tree: the helper, its consoles and their shells.
                let _ = Command::new(r"C:\Windows\System32\taskkill.exe")
                    .args(["/F", "/T", "/PID", &child.id().to_string()])
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .status();
                let _ = child.kill();
            }
            let _ = child.wait();
        }
        let _ = std::fs::remove_file(&self.log);
    }
}

/// Waits (polling) for a process to exit.
fn wait_exit(child: &mut Child, timeout: Duration) -> Option<ExitStatus> {
    let deadline = Instant::now() + timeout;
    loop {
        if let Ok(Some(status)) = child.try_wait() {
            return Some(status);
        }
        if Instant::now() >= deadline {
            return None;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}

// ---------------------------------------------------------------- client

/// One pane's connection: a pipe and a decoder.
struct Client {
    pipe: NamedPipeClient,
    decoder: FrameDecoder,
    /// The helper closed the connection.
    closed: bool,
}

impl Client {
    async fn connect(name: &str) -> Client {
        let pipe = ghostgrid_sessiond::pipe::connect(name, SHORT_TIMEOUT).await.expect("connect to sessiond");
        Client { pipe, decoder: FrameDecoder::new(), closed: false }
    }

    async fn send(&mut self, message: &SessionMessage) {
        self.pipe.write_all(&message.encode()).await.expect("write to sessiond");
    }

    /// Like `send`, but a closed pipe is not a panic.
    async fn try_send(&mut self, message: &SessionMessage) -> bool {
        self.pipe.write_all(&message.encode()).await.is_ok()
    }

    async fn input(&mut self, text: &str) {
        self.send(&SessionMessage::Input(text.as_bytes().to_vec())).await;
    }

    /// Messages until `done` says stop, the connection closes, or `timeout`
    /// passes. Answers ConPTY's cursor position request (ESC [ 6 n) as a
    /// terminal would, since the console waits for it before rendering.
    async fn receive_until(&mut self, timeout: Duration, done: impl Fn(&[SessionMessage]) -> bool) -> Vec<SessionMessage> {
        let mut messages = Vec::new();
        let deadline = tokio::time::Instant::now() + timeout;
        let mut buffer = vec![0u8; 64 * 1024];
        while !done(&messages) && !self.closed {
            let read = tokio::time::timeout_at(deadline, self.pipe.read(&mut buffer)).await;
            let n = match read {
                Err(_) => break,
                Ok(Ok(0)) | Ok(Err(_)) => {
                    self.closed = true;
                    break;
                }
                Ok(Ok(n)) => n,
            };
            let fresh = self.decoder.push(&buffer[..n]);
            let asks_cursor = fresh.iter().any(|m| match m {
                SessionMessage::Output(data) | SessionMessage::Attached { replay: data, .. } => contains(data, b"\x1b[6n"),
                _ => false,
            });
            messages.extend(fresh);
            if asks_cursor {
                let _ = self.try_send(&SessionMessage::Input(b"\x1b[1;1R".to_vec())).await;
            }
        }
        messages
    }

    /// Reads until the shell's visible output contains `needle`.
    async fn expect_output(&mut self, needle: &str) -> Vec<SessionMessage> {
        let got = self.receive_until(OUTPUT_TIMEOUT, |m| text(m).contains(needle)).await;
        assert!(text(&got).contains(needle), "never saw {needle:?}; got {:?} (closed: {})", text(&got), self.closed);
        got
    }

    /// Reads until the helper closes the connection (or `timeout`).
    async fn expect_closed(&mut self, timeout: Duration) -> Vec<SessionMessage> {
        let got = self.receive_until(timeout, |_| false).await;
        assert!(self.closed, "the helper kept the connection open; got {got:?}");
        got
    }
}

fn welcome() -> SessionMessage {
    SessionMessage::Welcome { version: PROTOCOL_VERSION }
}

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    haystack.windows(needle.len()).any(|w| w == needle)
}

fn exited(messages: &[SessionMessage]) -> Option<i32> {
    messages.iter().find_map(|m| match m {
        SessionMessage::Exited { code } => Some(*code),
        _ => None,
    })
}

fn failures(messages: &[SessionMessage]) -> Vec<String> {
    messages
        .iter()
        .filter_map(|m| match m {
            SessionMessage::Failure(reason) => Some(reason.clone()),
            _ => None,
        })
        .collect()
}

fn attached(messages: &[SessionMessage]) -> Option<(String, Vec<u8>)> {
    messages.iter().find_map(|m| match m {
        SessionMessage::Attached { id, replay } => Some((id.clone(), replay.clone())),
        _ => None,
    })
}

/// Everything the shell printed (replays and output, in order), with
/// escape sequences and carriage returns removed.
fn text(messages: &[SessionMessage]) -> String {
    let mut bytes = Vec::new();
    for message in messages {
        match message {
            SessionMessage::Output(data) | SessionMessage::Attached { replay: data, .. } => bytes.extend_from_slice(data),
            _ => {}
        }
    }
    strip_escapes(&bytes)
}

/// Plain text from terminal output: drops CSI, OSC, DCS/APC/PM/SOS strings,
/// two- and three-byte escapes, and CRs. ConPTY paints with cursor moves,
/// so text split by them reads as joined.
fn strip_escapes(bytes: &[u8]) -> String {
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    let string_end = |mut i: usize| -> usize {
        // Up to BEL or ST (ESC \).
        while i < bytes.len() {
            if bytes[i] == 0x07 {
                return i + 1;
            }
            if bytes[i] == 0x1b && bytes.get(i + 1) == Some(&b'\\') {
                return i + 2;
            }
            i += 1;
        }
        i
    };
    while i < bytes.len() {
        match bytes[i] {
            0x1b => {
                i += 1;
                match bytes.get(i) {
                    None => {}
                    Some(b'[') => {
                        i += 1;
                        while i < bytes.len() && !(0x40..=0x7e).contains(&bytes[i]) {
                            i += 1;
                        }
                        i += 1;
                    }
                    Some(b']' | b'P' | b'_' | b'^' | b'X') => i = string_end(i + 1),
                    Some(b'(' | b')' | b'*' | b'+' | b'#' | b'%') => i += 2,
                    Some(_) => i += 1,
                }
            }
            b'\r' | 0x07 => i += 1,
            b => {
                out.push(b);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// cmd.exe that prints `ready` once it is up, then reads commands.
fn cmd_launch(id: &str, ready: &str) -> SessionLaunch {
    let environment: BTreeMap<String, String> = std::env::vars().filter(|(k, _)| !k.is_empty() && !k.starts_with('=')).collect();
    SessionLaunch {
        id: id.into(),
        executable: CMD.into(),
        // Not typed, so the marker only shows up when cmd actually ran it.
        arguments: vec![CMD.into(), "/K".into(), "echo".into(), ready.into()],
        environment,
        working_directory: Some(std::env::temp_dir().to_string_lossy().into_owned()),
        columns: 120,
        rows: 30,
    }
}

/// A typed command whose output contains `marker` but whose echo does not
/// (the caret is eaten by cmd), so seeing `marker` proves the command ran.
fn echo_command(marker: &str) -> String {
    let (head, tail) = marker.split_at(marker.len() / 2);
    format!("echo {head}^{tail}\r")
}

/// A greeted client with a fresh cmd.exe session `id` that has printed its
/// ready marker.
async fn started(helper: &Helper, id: &str) -> (Client, Vec<SessionMessage>) {
    let mut client = helper.greeted().await;
    client.send(&SessionMessage::Create(cmd_launch(id, "ghostgrid-ready"))).await;
    let got = client.expect_output("ghostgrid-ready").await;
    let (attached_id, replay) = attached(&got).expect("Create is answered with Attached");
    assert_eq!(attached_id, id);
    assert!(replay.starts_with(b"\x1bc"), "replays start with a reset");
    (client, got)
}

// ---------------------------------------------------------------- tests

#[tokio::test(flavor = "multi_thread")]
async fn hello_is_answered_with_welcome() {
    let helper = Helper::start().await;
    let mut client = helper.connect().await;
    client.send(&SessionMessage::Hello { version: PROTOCOL_VERSION }).await;
    let got = client.receive_until(SHORT_TIMEOUT, |m| !m.is_empty()).await;
    assert_eq!(got.first(), Some(&welcome()), "got {got:?}");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_wrong_protocol_version_is_refused() {
    let helper = Helper::start().await;
    let mut client = helper.connect().await;
    client.send(&SessionMessage::Hello { version: 999 }).await;
    let got = client.receive_until(SHORT_TIMEOUT, |m| !failures(m).is_empty()).await;
    assert_eq!(failures(&got), vec!["protocol version mismatch".to_string()], "got {got:?} (closed: {})", client.closed);
    assert!(!got.contains(&welcome()));
    client.expect_closed(SHORT_TIMEOUT).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_message_before_hello_closes_the_connection() {
    let helper = Helper::start().await;
    let mut client = helper.connect().await;
    client.send(&SessionMessage::Attach { id: "nothing".into() }).await;
    let got = client.expect_closed(SHORT_TIMEOUT).await;
    assert!(got.is_empty(), "nothing is answered before Hello: {got:?}");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_created_shell_runs_input_and_its_output_arrives() {
    let helper = Helper::start().await;
    let (mut pane, _) = started(&helper, "create-1").await;
    pane.input(&echo_command("ghostgrid-marker")).await;
    pane.expect_output("ghostgrid-marker").await;
    pane.send(&SessionMessage::Terminate).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn resize_reaches_the_console() {
    let helper = Helper::start().await;
    let (mut pane, _) = started(&helper, "resize-1").await;
    pane.send(&SessionMessage::Resize { columns: 100, rows: 40, width: 800, height: 640 }).await;
    // Give the console a moment, then ask it.
    tokio::time::sleep(Duration::from_millis(500)).await;
    pane.input("mode con\r").await;
    // ConPTY paints runs of spaces as cursor moves: compare without spaces.
    let got = pane
        .receive_until(OUTPUT_TIMEOUT, |m| text(m).split_whitespace().collect::<String>().contains("Columns:100"))
        .await;
    let squeezed: String = text(&got).split_whitespace().collect();
    assert!(squeezed.contains("Columns:100"), "mode con did not report 100 columns: {:?}", text(&got));
    pane.send(&SessionMessage::Terminate).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn attaching_from_a_second_connection_replays_and_takes_the_shell_over() {
    let helper = Helper::start().await;
    let (mut first, _) = started(&helper, "take-1").await;
    first.input(&echo_command("before-takeover")).await;
    first.expect_output("before-takeover").await;

    let mut second = helper.greeted().await;
    second.send(&SessionMessage::Attach { id: "take-1".into() }).await;
    let got = second.receive_until(OUTPUT_TIMEOUT, |m| attached(m).is_some()).await;
    let (id, replay) = attached(&got).expect("Attach is answered with Attached");
    assert_eq!(id, "take-1");
    assert!(replay.starts_with(b"\x1bc"), "replays start with a reset: {:?}", String::from_utf8_lossy(&replay));
    let replayed = strip_escapes(&replay);
    assert!(replayed.contains("ghostgrid-ready"), "replay lacks the shell's first output: {replayed:?}");
    assert!(replayed.contains("before-takeover"), "replay lacks later output: {replayed:?}");

    // The stale pane is told and dropped.
    let stale = first.receive_until(SHORT_TIMEOUT, |m| !failures(m).is_empty()).await;
    assert_eq!(failures(&stale), vec!["attached elsewhere".to_string()], "got {stale:?}");
    first.expect_closed(SHORT_TIMEOUT).await;

    // The shell now answers the new pane.
    second.input(&echo_command("after-takeover")).await;
    second.expect_output("after-takeover").await;
    second.send(&SessionMessage::Terminate).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn creating_an_existing_id_attaches_to_the_running_shell() {
    let helper = Helper::start().await;
    let (mut first, _) = started(&helper, "dup-1").await;
    first.input(&echo_command("first-shell")).await;
    first.expect_output("first-shell").await;

    let mut second = helper.greeted().await;
    second.send(&SessionMessage::Create(cmd_launch("dup-1", "second-shell-started"))).await;
    let got = second.receive_until(OUTPUT_TIMEOUT, |m| attached(m).is_some()).await;
    let (id, replay) = attached(&got).expect("Create of a running id is answered with Attached");
    assert_eq!(id, "dup-1");
    assert!(strip_escapes(&replay).contains("first-shell"), "not the running shell's replay");
    let stale = first.receive_until(SHORT_TIMEOUT, |m| !failures(m).is_empty()).await;
    assert_eq!(failures(&stale), vec!["attached elsewhere".to_string()]);
    // No second shell was started.
    tokio::time::sleep(Duration::from_secs(2)).await;
    let later = second.receive_until(Duration::from_millis(500), |_| false).await;
    assert!(!text(&got).contains("second-shell-started") && !text(&later).contains("second-shell-started"));
    second.send(&SessionMessage::Terminate).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn attaching_an_unknown_id_fails() {
    let helper = Helper::start().await;
    let mut client = helper.greeted().await;
    client.send(&SessionMessage::Attach { id: "no-such-id".into() }).await;
    let got = client.receive_until(SHORT_TIMEOUT, |m| !failures(m).is_empty()).await;
    assert_eq!(failures(&got), vec!["no such session".to_string()], "got {got:?}");
    assert!(attached(&got).is_none());
}

/// ghostgrid's pane answers "no such session" (the kept shell is gone) by
/// sending Create on the same connection (Sources/GhostGrid/PaneView.swift,
/// onFailure: `client.pendingCreate = launch; client.startPending()`), and
/// the macOS helper keeps the connection open after that failure.
#[tokio::test(flavor = "multi_thread")]
async fn a_fresh_shell_can_be_created_after_no_such_session_on_the_same_connection() {
    let helper = Helper::start().await;
    let mut client = helper.greeted().await;
    client.send(&SessionMessage::Attach { id: "gone-1".into() }).await;
    let got = client.receive_until(SHORT_TIMEOUT, |m| !failures(m).is_empty()).await;
    assert_eq!(failures(&got), vec!["no such session".to_string()]);
    let sent = client.try_send(&SessionMessage::Create(cmd_launch("gone-1", "fresh-shell-ready"))).await;
    let got = client.receive_until(OUTPUT_TIMEOUT, |m| text(m).contains("fresh-shell-ready")).await;
    assert!(
        sent && attached(&got).is_some() && text(&got).contains("fresh-shell-ready"),
        "Create after \"no such session\" was not served (write ok: {sent}, closed: {}): {got:?}",
        client.closed
    );
    client.send(&SessionMessage::Terminate).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_shell_that_cannot_start_fails() {
    let helper = Helper::start().await;
    let mut client = helper.greeted().await;
    let mut launch = cmd_launch("bad-1", "never");
    launch.executable = r"C:\definitely\not\here\nothing.exe".into();
    launch.arguments[0] = launch.executable.clone();
    client.send(&SessionMessage::Create(launch)).await;
    let got = client.receive_until(OUTPUT_TIMEOUT, |m| !failures(m).is_empty()).await;
    let reasons = failures(&got);
    assert_eq!(reasons.len(), 1, "got {got:?}");
    assert!(reasons[0].contains("could not start"), "unexpected reason {:?}", reasons[0]);
    assert!(attached(&got).is_none());

    // And it was not kept.
    let mut other = helper.greeted().await;
    other.send(&SessionMessage::Attach { id: "bad-1".into() }).await;
    let got = other.receive_until(SHORT_TIMEOUT, |m| !failures(m).is_empty()).await;
    assert_eq!(failures(&got), vec!["no such session".to_string()]);
}

#[tokio::test(flavor = "multi_thread")]
async fn terminate_ends_the_shell_for_good_and_logs_who_asked() {
    let helper = Helper::start().await;
    let (mut pane, _) = started(&helper, "term-1").await;
    pane.send(&SessionMessage::Terminate).await;
    let got = pane.receive_until(OUTPUT_TIMEOUT, |m| exited(m).is_some()).await;
    assert!(exited(&got).is_some(), "no Exited after Terminate: {got:?} (closed: {})", pane.closed);

    let mut late = helper.greeted().await;
    late.send(&SessionMessage::Attach { id: "term-1".into() }).await;
    let got = late.receive_until(SHORT_TIMEOUT, |m| !failures(m).is_empty()).await;
    assert_eq!(failures(&got), vec!["no such session".to_string()]);

    // The log says who ended it: this test process.
    let me = format!("terminate term-1 from pid {} ", std::process::id());
    let log = helper.log_text();
    assert!(log.contains(&me), "log does not name the sender ({me:?}):\n{log}");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_shell_that_exits_reports_its_code() {
    let helper = Helper::start().await;
    let (mut pane, _) = started(&helper, "exit-1").await;
    pane.input("exit 7\r").await;
    let got = pane.receive_until(OUTPUT_TIMEOUT, |m| exited(m).is_some()).await;
    assert_eq!(exited(&got), Some(7), "got {got:?}");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_shell_outlives_its_connection_and_can_be_reattached() {
    let helper = Helper::start().await;
    let (mut first, _) = started(&helper, "keep-1").await;
    first.input(&echo_command("kept-marker")).await;
    first.expect_output("kept-marker").await;

    // The pane goes away (ghostgrid quit): the shell keeps running.
    drop(first);
    tokio::time::sleep(Duration::from_millis(500)).await;

    // A new ghostgrid reattaches and gets the earlier output back.
    let mut again = helper.greeted().await;
    again.send(&SessionMessage::Attach { id: "keep-1".into() }).await;
    let got = again.receive_until(OUTPUT_TIMEOUT, |m| attached(m).is_some()).await;
    let (id, replay) = attached(&got).expect("reattach is answered with Attached");
    assert_eq!(id, "keep-1");
    assert!(replay.starts_with(b"\x1bc"), "replays start with a reset");
    assert!(strip_escapes(&replay).contains("kept-marker"), "replay lost the output: {:?}", strip_escapes(&replay));

    // It still takes input.
    again.input(&echo_command("ping-marker")).await;
    again.expect_output("ping-marker").await;

    // Terminating ends it, and it cannot be reattached.
    again.send(&SessionMessage::Terminate).await;
    let ended = again.receive_until(OUTPUT_TIMEOUT, |m| exited(m).is_some()).await;
    assert!(exited(&ended).is_some(), "no Exited: {ended:?}");
    let mut late = helper.greeted().await;
    late.send(&SessionMessage::Attach { id: "keep-1".into() }).await;
    let got = late.receive_until(SHORT_TIMEOUT, |m| !failures(m).is_empty()).await;
    assert_eq!(failures(&got), vec!["no such session".to_string()]);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_second_helper_on_the_same_pipe_exits_without_taking_over() {
    let helper = Helper::start().await;
    let (pane, _) = started(&helper, "solo-1").await;
    drop(pane);

    let second_log = std::env::temp_dir().join(format!("ghostgrid-sessiond-test-{}.log", unique_suffix()));
    let mut second = spawn_helper(&helper.pipe, &second_log);
    let status = wait_exit(&mut second, Duration::from_secs(15));
    let second_text = std::fs::read_to_string(&second_log).unwrap_or_default();
    let _ = std::fs::remove_file(&second_log);
    if status.is_none() {
        let _ = second.kill();
        let _ = second.wait();
    }
    let status = status.expect("a second helper on a served pipe exits");
    assert!(status.success(), "second helper exit status {status:?}; log:\n{second_text}");
    assert!(second_text.contains("is taken"), "second helper log:\n{second_text}");

    // The first one still serves the pipe and still has the shell.
    let mut again = helper.greeted().await;
    again.send(&SessionMessage::Attach { id: "solo-1".into() }).await;
    let got = again.receive_until(OUTPUT_TIMEOUT, |m| attached(m).is_some()).await;
    assert!(attached(&got).is_some_and(|(_, r)| strip_escapes(&r).contains("ghostgrid-ready")), "got {got:?}");
    assert!(helper.log_text().contains(&format!("(pid {})", helper.pid())));
    again.send(&SessionMessage::Terminate).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn an_idle_helper_exits_on_its_own() {
    let mut helper = Helper::start().await;
    // 30 s idle, checked every 10 s: gone within about 50 s.
    let deadline = Instant::now() + Duration::from_secs(75);
    let status = loop {
        if let Some(status) = helper.try_wait() {
            break Some(status);
        }
        if Instant::now() >= deadline {
            break None;
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    };
    let status = status.expect("an idle helper exits by itself");
    assert!(status.success(), "idle exit status {status:?}");
    assert!(helper.log_text().contains("idle: exiting"), "log:\n{}", helper.log_text());
}

#[tokio::test(flavor = "multi_thread")]
async fn a_helper_with_a_shell_does_not_exit_idle() {
    let mut helper = Helper::start().await;
    let (pane, _) = started(&helper, "busy-1").await;
    // No connections, but a shell: it must stay.
    drop(pane);
    tokio::time::sleep(Duration::from_secs(55)).await;
    assert!(helper.try_wait().is_none(), "the helper exited while it had a shell; log:\n{}", helper.log_text());
    let mut again = helper.greeted().await;
    again.send(&SessionMessage::Attach { id: "busy-1".into() }).await;
    let got = again.receive_until(OUTPUT_TIMEOUT, |m| attached(m).is_some()).await;
    assert!(attached(&got).is_some(), "got {got:?}");
    again.send(&SessionMessage::Terminate).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn the_same_user_is_admitted_and_the_dacl_names_only_the_user_and_system() {
    let helper = Helper::start().await;
    // The same user connects (every test does) and is served.
    let client = helper.greeted().await;

    let sddl = dacl_sddl(&client.pipe).expect("read the pipe's DACL");
    let user = ghostgrid_sessiond::pipe::current_user_sid().expect("user SID");
    let aces = sddl_aces(&sddl);
    assert!(sddl.starts_with("D:P"), "the DACL is not protected from inheritance: {sddl}");
    assert_eq!(aces.len(), 2, "expected exactly the user's and SYSTEM's ACEs: {sddl}");
    for ace in &aces {
        assert!(ace.starts_with("A;"), "not an allow ACE: {ace} in {sddl}");
        let trustee = ace.rsplit(';').next().unwrap_or_default();
        assert!(is_user(trustee, &user) || trustee == "SY", "unexpected trustee {trustee} in {sddl}");
    }
    assert!(
        aces.iter().any(|a| is_user(a.rsplit(';').next().unwrap_or_default(), &user)),
        "the user is not admitted: {sddl}"
    );
    for outsider in ["WD", "AN", "BU", "AU", "IU", "NU", "BG"] {
        assert!(!aces.iter().any(|a| a.ends_with(&format!(";{outsider}"))), "{outsider} is admitted: {sddl}");
    }
}

/// Whether an SDDL trustee is the current user. SDDL writes the built-in
/// local Administrator and Guest by their aliases (LA, LG) instead of their
/// SIDs (RID 500 and 501): GitHub's Windows runners run as the former.
fn is_user(trustee: &str, user: &str) -> bool {
    trustee == user || (trustee == "LA" && user.ends_with("-500")) || (trustee == "LG" && user.ends_with("-501"))
}

/// The DACL of the pipe behind `pipe` as SDDL.
fn dacl_sddl(pipe: &NamedPipeClient) -> std::io::Result<String> {
    use std::os::windows::io::AsRawHandle;
    use std::ptr::null_mut;
    use windows_sys::Win32::Foundation::{LocalFree, HANDLE};
    use windows_sys::Win32::Security::Authorization::{
        ConvertSecurityDescriptorToStringSecurityDescriptorW, GetSecurityInfo, SDDL_REVISION_1, SE_KERNEL_OBJECT,
    };
    use windows_sys::Win32::Security::{DACL_SECURITY_INFORMATION, PSECURITY_DESCRIPTOR};

    // SAFETY: the handle is a live pipe client; both buffers are freed.
    unsafe {
        let mut descriptor: PSECURITY_DESCRIPTOR = null_mut();
        let status = GetSecurityInfo(
            pipe.as_raw_handle() as HANDLE,
            SE_KERNEL_OBJECT,
            DACL_SECURITY_INFORMATION,
            null_mut(),
            null_mut(),
            null_mut(),
            null_mut(),
            &mut descriptor,
        );
        if status != 0 {
            return Err(std::io::Error::from_raw_os_error(status as i32));
        }
        let mut text: *mut u16 = null_mut();
        let ok = ConvertSecurityDescriptorToStringSecurityDescriptorW(
            descriptor,
            SDDL_REVISION_1,
            DACL_SECURITY_INFORMATION,
            &mut text,
            null_mut(),
        );
        let result = if ok == 0 {
            Err(std::io::Error::last_os_error())
        } else {
            let mut len = 0;
            while *text.add(len) != 0 {
                len += 1;
            }
            let s = String::from_utf16_lossy(std::slice::from_raw_parts(text, len));
            LocalFree(text.cast());
            Ok(s)
        };
        LocalFree(descriptor.cast());
        result
    }
}

/// "D:P(A;;FA;;;S-1-...)(A;;FA;;;SY)" > ["A;;FA;;;S-1-...", "A;;FA;;;SY"].
fn sddl_aces(sddl: &str) -> Vec<String> {
    sddl.split('(').skip(1).map(|s| s.trim_end_matches(')').to_string()).collect()
}

#[test]
fn strip_escapes_removes_terminal_sequences() {
    let raw = b"\x1bc\x1b[?25l\x1b[2J\x1b[mhel\x1b[3Clo\r\n\x1b]0;title\x07wor\x1b(Bld\x1b[6n";
    assert_eq!(strip_escapes(raw), "hello\nworld");
    assert_eq!(echo_command("ghostgrid-marker"), "echo ghostgri^d-marker\r");
}
