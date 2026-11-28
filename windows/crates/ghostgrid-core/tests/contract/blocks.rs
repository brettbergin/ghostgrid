//! Contract for commands as blocks (CommandBlockTests): the pane's output
//! stream, with the shell integration's OSC 133 marks and ghostgrid's
//! command-line report (OSC 633;E), becomes a list of commands with their
//! plain-text output and exit status. The Windows port also reports what
//! the app reacts to as events: commands starting and finishing, the
//! working directory (OSC 7, OSC 9;9) and desktop notifications (OSC 9,
//! OSC 777).

use ghostgrid_core::blocks::{CommandBlock, CommandBlockParser, CommandLineReport, StreamEvent};

const ESC: &str = "\x1b";

fn osc(body: &str) -> String {
    format!("{ESC}]{body}\x07")
}

fn osc_st(body: &str) -> String {
    format!("{ESC}]{body}{ESC}\\")
}

/// One prompt + command + output + finish, as zsh emits it.
fn run(command: &str, output: &str, code: i32) -> String {
    osc("133;A")
        + "~ \u{276F} "
        + &osc("133;B")
        + command
        + "\r\n"
        + &osc(&format!("633;E;{}", CommandLineReport::escape(command)))
        + &osc("133;C")
        + output
        + &osc(&format!("133;D;{code}"))
}

fn parse_chunked(text: &str, chunk: Option<usize>) -> Vec<CommandBlock> {
    let mut parser = CommandBlockParser::new();
    let data = text.as_bytes();
    match chunk {
        Some(chunk) => {
            for piece in data.chunks(chunk) {
                parser.feed(piece, false);
            }
        }
        None => {
            parser.feed(data, false);
        }
    }
    parser.blocks().to_vec()
}

fn parse(text: &str) -> Vec<CommandBlock> {
    parse_chunked(text, None)
}

fn events(text: &str) -> Vec<StreamEvent> {
    CommandBlockParser::new().feed(text.as_bytes(), false)
}

/// A parser whose clock reads each of `times` in turn.
fn clocked(times: &[f64]) -> CommandBlockParser {
    let owned: Vec<f64> = times.into();
    let mut times = owned.into_iter();
    let mut parser = CommandBlockParser::new();
    parser.set_clock(Box::new(move || times.next().unwrap_or(0.0)));
    parser
}

#[test]
fn each_command_becomes_a_block() {
    let blocks = parse(&(run("ls", "a\r\nb\r\n", 0) + &run("false", "", 1)));
    assert_eq!(
        blocks.iter().map(|b| b.command.clone()).collect::<Vec<_>>(),
        vec![Some("ls".into()), Some("false".into())]
    );
    assert_eq!(
        blocks.iter().map(|b| b.output()).collect::<Vec<_>>(),
        vec!["a\nb\n", ""]
    );
    assert_eq!(
        blocks.iter().map(|b| b.exit_code).collect::<Vec<_>>(),
        vec![Some(0), Some(1)]
    );
    assert_eq!(
        blocks.iter().map(|b| b.is_finished).collect::<Vec<_>>(),
        vec![true, true]
    );
}

#[test]
fn a_running_command_is_an_unfinished_block() {
    let blocks = parse(&(osc("633;E;sleep 9") + &osc("133;C") + "working"));
    assert_eq!(blocks.len(), 1);
    let block = &blocks[0];
    assert_eq!(block.command.as_deref(), Some("sleep 9"));
    assert_eq!(block.output(), "working");
    assert!(!block.is_finished && block.exit_code.is_none());
}

#[test]
fn colors_and_other_escapes_are_stripped() {
    let output =
        format!("{ESC}[1;31mred{ESC}[0m {ESC}]8;;https://x\x07link{ESC}]8;;\x07{ESC}(B done\r\n");
    assert_eq!(parse(&run("x", &output, 0))[0].output(), "red link done\n");
}

#[test]
fn carriage_returns_overwrite_the_line_like_a_progress_bar() {
    assert_eq!(
        parse(&run("x", "10%\r50%\r100%\r\nok\r\n", 0))[0].output(),
        "100%\nok\n"
    );
    assert_eq!(parse(&run("x", "abc\x08d\r\n", 0))[0].output(), "abd\n");
}

#[test]
fn split_reads_and_unicode_survive() {
    let text = run("echo h\u{e9}llo \u{1F30D}", "h\u{e9}llo \u{1F30D}\r\n", 0)
        + &run("pwd", "/tmp\r\n", 0);
    for chunk in [1, 2, 3, 5, 7] {
        let blocks = parse_chunked(&text, Some(chunk));
        assert_eq!(
            blocks
                .iter()
                .map(|b| b.command.clone().unwrap_or_default())
                .collect::<Vec<_>>(),
            vec!["echo h\u{e9}llo \u{1F30D}", "pwd"],
            "chunk {chunk}"
        );
        assert_eq!(
            blocks.iter().map(|b| b.output()).collect::<Vec<_>>(),
            vec!["h\u{e9}llo \u{1F30D}\n", "/tmp\n"],
            "chunk {chunk}"
        );
    }
}

#[test]
fn osc_with_string_terminator_and_no_command_report_work() {
    // nushell emits its own marks, without a command-line report.
    let text = osc_st("133;A")
        + "> "
        + &osc_st("133;B")
        + "ls\r\n"
        + &osc_st("133;C")
        + "x\r\n"
        + &osc_st("133;D;0");
    let blocks = parse(&text);
    assert_eq!(blocks.len(), 1);
    assert_eq!(blocks[0].output(), "x\n");
    assert_eq!(blocks[0].command, None);
}

#[test]
fn command_line_escapes_round_trip() {
    for command in [
        "a;b",
        r#"echo "x\y""#,
        "for i in 1 2\ndo echo $i\ndone",
        "tab\there",
        "\x1b[x",
    ] {
        assert_eq!(
            CommandLineReport::unescape(&CommandLineReport::escape(command)),
            command
        );
        assert!(!CommandLineReport::escape(command).contains(';'));
        assert!(!CommandLineReport::escape(command).contains('\n'));
    }
    let blocks = parse(&run("for i in 1 2\ndo echo $i;\ndone", "1\r\n2\r\n", 0));
    assert_eq!(
        blocks[0].command.as_deref(),
        Some("for i in 1 2\ndo echo $i;\ndone")
    );
}

#[test]
fn command_line_escapes_are_exact() {
    assert_eq!(
        CommandLineReport::escape("a\\b;c\nd\u{7f}"),
        "a\\\\b\\x3bc\\x0ad\\x7f"
    );
    assert_eq!(
        CommandLineReport::unescape("\\x41\\\\\\q\\"),
        "A\\\\q\\",
        "unknown escapes stay literal"
    );
}

#[test]
fn history_and_output_are_bounded() {
    let mut parser = CommandBlockParser::with_limits(3, 10);
    for index in 0..5 {
        parser.feed(
            run(&format!("c{index}"), &("x".repeat(25) + "\r\n"), 0).as_bytes(),
            false,
        );
    }
    assert_eq!(
        parser
            .blocks()
            .iter()
            .map(|b| b.command.clone().unwrap())
            .collect::<Vec<_>>(),
        vec!["c2", "c3", "c4"]
    );
    assert!(parser
        .blocks()
        .iter()
        .all(|b| b.output().len() <= 10 && b.is_truncated));
    assert_eq!(
        parser.blocks().iter().map(|b| b.id).collect::<Vec<_>>(),
        vec![2, 3, 4],
        "ids keep counting"
    );
}

#[test]
fn a_reset_starts_over() {
    let mut parser = CommandBlockParser::new();
    parser.feed(run("ls", "a\r\n", 0).as_bytes(), false);
    parser.reset();
    assert!(parser.blocks().is_empty());
}

#[test]
fn replayed_blocks_have_no_timing() {
    let mut parser = CommandBlockParser::new();
    parser.feed(run("ls", "a\r\n", 0).as_bytes(), true);
    assert_eq!(
        parser
            .blocks()
            .iter()
            .map(|b| b.duration())
            .collect::<Vec<_>>(),
        vec![None],
        "a replay's timing is not the command's"
    );
    parser.feed(run("pwd", "/\r\n", 0).as_bytes(), false);
    assert_eq!(
        parser
            .blocks()
            .iter()
            .map(|b| b.duration().is_some())
            .collect::<Vec<_>>(),
        vec![false, true]
    );
}

#[test]
fn a_block_reads_as_command_then_output() {
    let block = parse(&run("ls -1", "a\r\nb\r\n", 2)).remove(0);
    assert_eq!(block.transcript("$ "), "$ ls -1\na\nb\n");
    assert_eq!(block.summary(), "exit 2");
    let running = parse(&(osc("133;C") + "x")).remove(0);
    assert_eq!(running.summary(), "running");
    assert_eq!(parse(&run("ok", "", 0))[0].summary(), "ok");
}

#[test]
fn a_block_view_carries_what_the_app_shows() {
    let mut parser = clocked(&[10.0, 12.5]);
    parser.feed(run("ls", "a\r\n", 0).as_bytes(), false);
    let json = serde_json::to_value(parser.blocks()[0].view()).unwrap();
    assert_eq!(json["id"], 0);
    assert_eq!(json["command"], "ls");
    assert_eq!(json["exitCode"], 0);
    assert_eq!(json["finished"], true);
    assert_eq!(json["truncated"], false);
    assert_eq!(json["startedAt"], 10.0);
    assert_eq!(json["finishedAt"], 12.5);
    assert_eq!(json["output"], "a\n");
    assert_eq!(json["summary"], "ok");
}

// Events (Windows port).

#[test]
fn starting_and_finishing_commands_are_reported_with_their_timing() {
    let mut parser = clocked(&[100.0, 102.5]);
    let events = parser.feed(run("ls", "a\r\n", 3).as_bytes(), false);
    assert_eq!(
        events,
        vec![
            StreamEvent::CommandStarted { block: 0 },
            StreamEvent::CommandFinished {
                block: 0,
                exit_code: Some(3),
                seconds: Some(2.5),
                command: Some("ls".into())
            },
        ]
    );
}

#[test]
fn a_new_prompt_finishes_a_command_without_a_status() {
    let events = events(&(osc("133;C") + "x" + &osc("133;A")));
    assert!(matches!(
        events.as_slice(),
        [
            StreamEvent::CommandStarted { block: 0 },
            StreamEvent::CommandFinished {
                block: 0,
                exit_code: None,
                ..
            }
        ]
    ));
}

#[test]
fn windows_status_codes_read_as_signed() {
    // cmd and pwsh report NTSTATUS codes either way round.
    let blocks = parse(
        &(osc("133;C") + &osc("133;D;3221225786") + &osc("133;C") + &osc("133;D;-1073741510")),
    );
    assert_eq!(
        blocks.iter().map(|b| b.exit_code).collect::<Vec<_>>(),
        vec![Some(-1073741510), Some(-1073741510)]
    );
}

#[test]
fn a_replay_reports_only_the_working_directory() {
    let text = run("ls", "a\r\n", 0) + &osc("7;file://box/C:/Users/me") + &osc("9;hello");
    let events = CommandBlockParser::new().feed(text.as_bytes(), true);
    assert_eq!(
        events,
        vec![StreamEvent::WorkingDirectory("C:\\Users\\me".into())]
    );
}

#[test]
fn osc_7_gives_the_working_directory() {
    let cases = [
        ("7;file://box/C:/Users/me/code", "C:\\Users\\me\\code"),
        ("7;file:///C:/x", "C:\\x"),
        (
            "7;file://box/c:/My%20Files/caf%C3%A9",
            "c:\\My Files\\caf\u{e9}",
        ),
        ("7;file:///D:", "D:\\"),
        ("7;file://ubuntu/home/me/src", "/home/me/src"),
    ];
    for (body, expected) in cases {
        assert_eq!(
            events(&osc(body)),
            vec![StreamEvent::WorkingDirectory(expected.into())],
            "{body}"
        );
        assert_eq!(
            events(&osc_st(body)),
            vec![StreamEvent::WorkingDirectory(expected.into())],
            "{body} with ST"
        );
    }
    assert!(
        events(&osc("7;kitty-shell-cwd://box/x")).is_empty(),
        "not a file URL"
    );
}

#[test]
fn osc_9_9_gives_the_working_directory() {
    assert_eq!(
        events(&osc("9;9;\"C:\\Users\\me\\My Code\"")),
        vec![StreamEvent::WorkingDirectory(
            "C:\\Users\\me\\My Code".into()
        )]
    );
    assert_eq!(
        events(&osc_st("9;9;C:\\Windows")),
        vec![StreamEvent::WorkingDirectory("C:\\Windows".into())]
    );
}

#[test]
fn osc_9_is_a_notification_unless_it_is_a_numbered_subcommand() {
    assert_eq!(
        events(&osc("9;Build finished; 3 warnings")),
        vec![StreamEvent::Notification {
            title: None,
            body: "Build finished; 3 warnings".into()
        }]
    );
    assert!(events(&osc("9;4;1;50")).is_empty(), "progress");
    assert!(events(&osc("9;12")).is_empty(), "a ConEmu subcommand");
    assert!(events(&osc("9;")).is_empty(), "nothing to say");
}

#[test]
fn osc_777_notify_is_a_notification_with_a_title() {
    assert_eq!(
        events(&osc("777;notify;Claude;Needs your input; now")),
        vec![StreamEvent::Notification {
            title: Some("Claude".into()),
            body: "Needs your input; now".into()
        }]
    );
    assert!(events(&osc("777;other;x;y")).is_empty());
}

#[test]
fn a_replay_clears_finished_times() {
    let mut parser = clocked(&[1.0, 2.0, 3.0, 4.0]);
    parser.feed(run("a", "", 0).as_bytes(), false);
    assert_eq!(parser.blocks()[0].finished_at, Some(2.0));
    parser.feed(b"", true);
    assert_eq!(
        parser.blocks()[0].finished_at,
        None,
        "as the macOS parser does"
    );
    assert_eq!(parser.blocks()[0].started_at, 1.0);
}
