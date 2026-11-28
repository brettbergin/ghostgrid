//! Contract for shells that survive quitting: the wire format between
//! ghostgrid and sessiond (SessionProtocolTests). The bytes match the macOS
//! helper's exactly.

use ghostgrid_core::protocol::{FrameDecoder, SessionLaunch, SessionMessage, PROTOCOL_VERSION};
use std::collections::BTreeMap;

fn launch() -> SessionLaunch {
    SessionLaunch {
        id: "a".into(),
        executable: "C:\\Windows\\System32\\cmd.exe".into(),
        arguments: vec!["C:\\Windows\\System32\\cmd.exe".into()],
        environment: BTreeMap::from([("TERM".to_string(), "xterm-256color".to_string())]),
        working_directory: Some("C:\\Users\\me".into()),
        columns: 120,
        rows: 40,
    }
}

fn all() -> Vec<SessionMessage> {
    vec![
        SessionMessage::Hello { version: 1 },
        SessionMessage::Create(launch()),
        SessionMessage::Attach { id: "a".into() },
        SessionMessage::Input(vec![0x6C, 0x73, 0x0D]),
        SessionMessage::Resize {
            columns: 132,
            rows: 43,
            width: 1320,
            height: 860,
        },
        SessionMessage::Terminate,
        SessionMessage::Welcome { version: 1 },
        SessionMessage::Attached {
            id: "a".into(),
            replay: b"\x1bcprompt\n".to_vec(),
        },
        SessionMessage::Output((0..=255u8).collect()),
        SessionMessage::Exited { code: 130 },
        SessionMessage::Failure("no such session".into()),
    ]
}

fn stream() -> Vec<u8> {
    all().iter().flat_map(|m| m.encode()).collect()
}

/// A frame as the macOS helper writes it.
fn frame(kind: u8, payload: &[u8]) -> Vec<u8> {
    let mut out = ((payload.len() + 1) as u32).to_be_bytes().to_vec();
    out.push(kind);
    out.extend_from_slice(payload);
    out
}

#[test]
fn every_message_round_trips() {
    let mut decoder = FrameDecoder::new();
    assert_eq!(decoder.push(&stream()), all());
    assert!(!decoder.is_broken());
}

#[test]
fn frames_survive_any_split() {
    let stream = stream();
    for chunk in [1, 2, 3, 7, 64] {
        let mut decoder = FrameDecoder::new();
        let mut decoded = Vec::new();
        for piece in stream.chunks(chunk) {
            decoded.extend(decoder.push(piece));
        }
        assert_eq!(decoded, all(), "chunk {chunk}");
    }
}

#[test]
fn garbage_breaks_the_stream() {
    let mut decoder = FrameDecoder::new();
    assert!(decoder.push(&[0, 0, 0, 2, 0xEE, 0]).is_empty());
    assert!(decoder.is_broken());
    let mut huge = FrameDecoder::new();
    let _ = huge.push(&[0xFF, 0xFF, 0xFF, 0xFF]);
    assert!(huge.is_broken());
}

#[test]
fn a_broken_stream_stays_broken() {
    let mut decoder = FrameDecoder::new();
    let _ = decoder.push(&[0, 0, 0, 0]);
    assert!(
        decoder.is_broken(),
        "a frame must hold at least the type byte"
    );
    assert!(decoder.push(&SessionMessage::Terminate.encode()).is_empty());
}

#[test]
fn frames_up_to_the_maximum_are_accepted() {
    assert_eq!(FrameDecoder::MAX_FRAME, 64 << 20);
    let mut ok = FrameDecoder::new();
    assert!(ok
        .push(&(FrameDecoder::MAX_FRAME as u32).to_be_bytes())
        .is_empty());
    assert!(
        !ok.is_broken(),
        "waits for the rest of a maximum-size frame"
    );
    let mut over = FrameDecoder::new();
    let _ = over.push(&((FrameDecoder::MAX_FRAME + 1) as u32).to_be_bytes());
    assert!(over.is_broken());
}

#[test]
fn the_wire_format_matches_the_mac_helper() {
    assert_eq!(PROTOCOL_VERSION, 1);
    assert_eq!(
        SessionMessage::Hello { version: 1 }.encode(),
        frame(1, br#"{"version":1}"#)
    );
    assert_eq!(
        SessionMessage::Attach { id: "abc".into() }.encode(),
        frame(3, b"abc")
    );
    assert_eq!(
        SessionMessage::Input(b"ls\r".to_vec()).encode(),
        frame(4, b"ls\r")
    );
    assert_eq!(SessionMessage::Terminate.encode(), frame(6, b""));
    assert_eq!(
        SessionMessage::Welcome { version: 1 }.encode(),
        frame(101, br#"{"version":1}"#)
    );
    assert_eq!(
        SessionMessage::Attached {
            id: "x".into(),
            replay: b"yz".to_vec()
        }
        .encode(),
        frame(102, b"x\nyz")
    );
    assert_eq!(
        SessionMessage::Output(b"hi".to_vec()).encode(),
        frame(103, b"hi")
    );
    assert_eq!(
        SessionMessage::Exited { code: -1 }.encode(),
        frame(104, br#"{"code":-1}"#)
    );
    assert_eq!(
        SessionMessage::Failure("nope".into()).encode(),
        frame(105, b"nope")
    );
}

#[test]
fn json_payloads_written_by_the_mac_helper_decode() {
    let resize = frame(5, br#"{"columns":80,"rows":24,"width":800,"height":600}"#);
    assert_eq!(
        SessionMessage::decode_body(&resize[4..]),
        Some(SessionMessage::Resize {
            columns: 80,
            rows: 24,
            width: 800,
            height: 600
        })
    );
    let create = frame(
        2,
        br#"{"id":"a","executable":"/bin/zsh","arguments":["-zsh"],"environment":{"TERM":"xterm-ghostty"},"columns":80,"rows":24}"#,
    );
    let Some(SessionMessage::Create(launch)) = SessionMessage::decode_body(&create[4..]) else {
        panic!("create did not decode");
    };
    assert_eq!(
        launch.working_directory, None,
        "a missing workingDirectory is none"
    );
    assert_eq!(launch.arguments, vec!["-zsh".to_string()]);
}

#[test]
fn a_launch_uses_the_mac_json_keys() {
    let json = serde_json::to_value(launch()).unwrap();
    assert_eq!(json["workingDirectory"], "C:\\Users\\me");
    assert_eq!(json["columns"], 120);
    assert!(json.get("working_directory").is_none());
}

#[test]
fn malformed_bodies_do_not_decode() {
    assert_eq!(SessionMessage::decode_body(&[]), None);
    assert_eq!(SessionMessage::decode_body(&[7]), None, "unknown type");
    assert_eq!(
        SessionMessage::decode_body(&[1, b'{']),
        None,
        "bad hello JSON"
    );
    assert_eq!(
        SessionMessage::decode_body(&[102, b'a', b'b']),
        None,
        "attached without a newline"
    );
    assert_eq!(
        SessionMessage::decode_body(&[3, 0xFF, 0xFE]),
        None,
        "attach id is not UTF-8"
    );
}
