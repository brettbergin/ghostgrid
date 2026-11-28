//! The wire between ghostgrid and ghostgrid-sessiond, the helper that owns
//! every pane's shell so shells outlive the app. One connection per pane
//! carries one session. Frames are a 4-byte big-endian length (of the type
//! byte plus the payload), a type byte, and a payload: raw bytes for
//! terminal data, JSON otherwise. The bytes are exactly the macOS helper's,
//! so the format is documented once and tested against it.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

/// Sent in `Hello` and `Welcome`; a helper that speaks another version is
/// replaced rather than talked to.
pub const PROTOCOL_VERSION: u32 = 1;

/// One message on a session connection.
#[derive(Debug, Clone, PartialEq)]
pub enum SessionMessage {
    // ghostgrid -> sessiond
    /// First message on a connection.
    Hello { version: u32 },
    /// Start a shell and attach to it.
    Create(SessionLaunch),
    /// Attach to a running shell; answered with `Attached` and its replay.
    Attach { id: String },
    /// Keystrokes and pastes from the terminal.
    Input(Vec<u8>),
    /// The pane's new size, in cells and in pixels.
    Resize {
        columns: u16,
        rows: u16,
        width: u16,
        height: u16,
    },
    /// End the shell (closing a pane, or quitting without keeping shells).
    Terminate,

    // sessiond -> ghostgrid
    /// Answers `Hello`.
    Welcome { version: u32 },
    /// Attached; `replay` is the shell's recent output, to rebuild the screen.
    Attached { id: String, replay: Vec<u8> },
    /// What the shell printed.
    Output(Vec<u8>),
    /// The shell ended with this status.
    Exited { code: i32 },
    /// Something went wrong (no such session, the shell would not start).
    Failure(String),
}

mod kind {
    pub const HELLO: u8 = 1;
    pub const CREATE: u8 = 2;
    pub const ATTACH: u8 = 3;
    pub const INPUT: u8 = 4;
    pub const RESIZE: u8 = 5;
    pub const TERMINATE: u8 = 6;
    pub const WELCOME: u8 = 101;
    pub const ATTACHED: u8 = 102;
    pub const OUTPUT: u8 = 103;
    pub const EXITED: u8 = 104;
    pub const FAILURE: u8 = 105;
}

#[derive(Serialize, Deserialize)]
struct Resize {
    columns: u16,
    rows: u16,
    width: u16,
    height: u16,
}

impl SessionMessage {
    /// The whole frame: length, type byte, payload.
    pub fn encode(&self) -> Vec<u8> {
        let (kind, payload): (u8, Vec<u8>) = match self {
            SessionMessage::Hello { version } => (
                kind::HELLO,
                json(&serde_json::json!({ "version": version })),
            ),
            SessionMessage::Create(launch) => (kind::CREATE, json(launch)),
            SessionMessage::Attach { id } => (kind::ATTACH, id.as_bytes().to_vec()),
            SessionMessage::Input(data) => (kind::INPUT, data.clone()),
            SessionMessage::Resize {
                columns,
                rows,
                width,
                height,
            } => (
                kind::RESIZE,
                json(&Resize {
                    columns: *columns,
                    rows: *rows,
                    width: *width,
                    height: *height,
                }),
            ),
            SessionMessage::Terminate => (kind::TERMINATE, Vec::new()),
            SessionMessage::Welcome { version } => (
                kind::WELCOME,
                json(&serde_json::json!({ "version": version })),
            ),
            SessionMessage::Attached { id, replay } => {
                // id, a newline, then the replay bytes.
                let mut payload = Vec::with_capacity(id.len() + 1 + replay.len());
                payload.extend_from_slice(id.as_bytes());
                payload.push(b'\n');
                payload.extend_from_slice(replay);
                (kind::ATTACHED, payload)
            }
            SessionMessage::Output(data) => (kind::OUTPUT, data.clone()),
            SessionMessage::Exited { code } => {
                (kind::EXITED, json(&serde_json::json!({ "code": code })))
            }
            SessionMessage::Failure(message) => (kind::FAILURE, message.as_bytes().to_vec()),
        };
        let mut frame = Vec::with_capacity(5 + payload.len());
        frame.extend_from_slice(&((payload.len() + 1) as u32).to_be_bytes());
        frame.push(kind);
        frame.extend_from_slice(&payload);
        frame
    }

    /// One message from a frame body (type byte + payload), nil if
    /// malformed.
    pub fn decode_body(body: &[u8]) -> Option<SessionMessage> {
        let (&kind, payload) = body.split_first()?;
        match kind {
            kind::HELLO => integer(payload, "version")
                .and_then(|v| u32::try_from(v).ok())
                .map(|version| SessionMessage::Hello { version }),
            kind::CREATE => serde_json::from_slice(payload)
                .ok()
                .map(SessionMessage::Create),
            kind::ATTACH => String::from_utf8(payload.to_vec())
                .ok()
                .map(|id| SessionMessage::Attach { id }),
            kind::INPUT => Some(SessionMessage::Input(payload.to_vec())),
            kind::RESIZE => {
                serde_json::from_slice::<Resize>(payload)
                    .ok()
                    .map(|r| SessionMessage::Resize {
                        columns: r.columns,
                        rows: r.rows,
                        width: r.width,
                        height: r.height,
                    })
            }
            kind::TERMINATE => Some(SessionMessage::Terminate),
            kind::WELCOME => integer(payload, "version")
                .and_then(|v| u32::try_from(v).ok())
                .map(|version| SessionMessage::Welcome { version }),
            kind::ATTACHED => {
                let newline = payload.iter().position(|&b| b == b'\n')?;
                let id = String::from_utf8(payload[..newline].to_vec()).ok()?;
                Some(SessionMessage::Attached {
                    id,
                    replay: payload[newline + 1..].to_vec(),
                })
            }
            kind::OUTPUT => Some(SessionMessage::Output(payload.to_vec())),
            // Truncated to 32 bits as the macOS helper does.
            kind::EXITED => {
                integer(payload, "code").map(|code| SessionMessage::Exited { code: code as i32 })
            }
            kind::FAILURE => Some(SessionMessage::Failure(
                String::from_utf8_lossy(payload).into_owned(),
            )),
            _ => None,
        }
    }
}

fn json(value: &impl Serialize) -> Vec<u8> {
    serde_json::to_vec(value).unwrap_or_default()
}

/// `key` of a JSON object whose values are all integers (the macOS helper
/// decodes these payloads as `[String: Int]`).
fn integer(payload: &[u8], key: &str) -> Option<i64> {
    let Value::Object(object) = serde_json::from_slice::<Value>(payload).ok()? else {
        return None;
    };
    if !object.values().all(|v| v.is_i64() || v.is_u64()) {
        return None;
    }
    object.get(key)?.as_i64()
}

/// Collects bytes from a pipe and yields whole messages, however the reads
/// split them. A frame over `MAX_FRAME` (or a malformed one) marks the
/// stream broken: the connection should be closed.
#[derive(Debug, Default)]
pub struct FrameDecoder {
    buffer: Vec<u8>,
    broken: bool,
}

impl FrameDecoder {
    /// The largest frame accepted (64 MiB); anything bigger is garbage.
    pub const MAX_FRAME: usize = 64 << 20;

    pub fn new() -> Self {
        Self::default()
    }

    /// Whether the stream went bad; nothing more will be decoded.
    pub fn is_broken(&self) -> bool {
        self.broken
    }

    /// Adds `data` and returns every message it completes.
    pub fn push(&mut self, data: &[u8]) -> Vec<SessionMessage> {
        if self.broken {
            return Vec::new();
        }
        self.buffer.extend_from_slice(data);
        let mut messages = Vec::new();
        let mut start = 0;
        while self.buffer.len() - start >= 4 {
            let header: [u8; 4] = self.buffer[start..start + 4]
                .try_into()
                .expect("four bytes");
            let length = u32::from_be_bytes(header) as usize;
            if !(1..=Self::MAX_FRAME).contains(&length) {
                self.broken = true;
                self.buffer.clear();
                return messages;
            }
            if self.buffer.len() - start < 4 + length {
                break;
            }
            let body = &self.buffer[start + 4..start + 4 + length];
            match SessionMessage::decode_body(body) {
                Some(message) => messages.push(message),
                None => {
                    self.broken = true;
                    self.buffer.clear();
                    return messages;
                }
            }
            start += 4 + length;
        }
        self.buffer.drain(..start);
        messages
    }
}

/// What a new pane asks sessiond to start.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SessionLaunch {
    pub id: String,
    pub executable: String,
    /// The full argv, starting with argv[0] (on Windows, the executable).
    pub arguments: Vec<String>,
    /// The whole environment of the shell.
    pub environment: BTreeMap<String, String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub working_directory: Option<String>,
    pub columns: u16,
    pub rows: u16,
}
