//! Commands as blocks: a pane's output stream read into the commands that
//! ran in it, from the shell integration's OSC 133 prompt marks and
//! ghostgrid's own command-line report (OSC 633;E, see
//! [`CommandLineReport`]). The same pass picks out what the Windows app
//! reacts to: the working directory (OSC 7, OSC 9;9) and desktop
//! notifications (OSC 9, OSC 777), reported as [`StreamEvent`]s.

use crate::paths;
use serde::Serialize;
use std::time::{SystemTime, UNIX_EPOCH};

/// One command run in a pane: what was typed, what it printed (as plain
/// text, colors and cursor tricks removed) and how it ended.
#[derive(Debug, Clone, PartialEq)]
pub struct CommandBlock {
    /// Counts up per parser, never reused (so the app can key views by it).
    pub id: u64,
    /// None when the shell did not report it (nushell's own marks, cmd).
    pub command: Option<String>,
    pub exit_code: Option<i32>,
    pub is_finished: bool,
    /// The oldest output was dropped to stay within the parser's limit.
    pub is_truncated: bool,
    /// Seconds since the Unix epoch, from the parser's clock.
    pub started_at: f64,
    /// None while running, and for blocks rebuilt from a replay.
    pub finished_at: Option<f64>,
    /// Output bytes (UTF-8) and where the current line starts in them.
    bytes: Vec<u8>,
    line_start: usize,
}

impl CommandBlock {
    fn new(id: u64, command: Option<String>, started_at: f64) -> Self {
        CommandBlock {
            id,
            command,
            exit_code: None,
            is_finished: false,
            is_truncated: false,
            started_at,
            finished_at: None,
            bytes: Vec::new(),
            line_start: 0,
        }
    }

    pub fn output(&self) -> String {
        String::from_utf8_lossy(&self.bytes).into_owned()
    }

    /// Seconds the command ran, once it finished (and not from a replay).
    pub fn duration(&self) -> Option<f64> {
        self.finished_at.map(|end| end - self.started_at)
    }

    /// The command as typed after `prompt`, then its output.
    pub fn transcript(&self, prompt: &str) -> String {
        let mut text = format!(
            "{prompt}{}\n{}",
            self.command.as_deref().unwrap_or(""),
            self.output()
        );
        if !text.ends_with('\n') {
            text.push('\n');
        }
        text
    }

    /// "running", "ok", or "exit N".
    pub fn summary(&self) -> String {
        if !self.is_finished {
            return "running".into();
        }
        match self.exit_code {
            None | Some(0) => "ok".into(),
            Some(code) => format!("exit {code}"),
        }
    }

    /// The block as the app's blocks panel shows it.
    pub fn view(&self) -> BlockView {
        BlockView {
            id: self.id,
            command: self.command.clone(),
            exit_code: self.exit_code,
            finished: self.is_finished,
            truncated: self.is_truncated,
            started_at: self.started_at,
            finished_at: self.finished_at,
            output: self.output(),
            summary: self.summary(),
        }
    }
}

/// A [`CommandBlock`] as JSON for the web view.
#[derive(Serialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BlockView {
    pub id: u64,
    pub command: Option<String>,
    pub exit_code: Option<i32>,
    pub finished: bool,
    pub truncated: bool,
    pub started_at: f64,
    pub finished_at: Option<f64>,
    pub output: String,
    pub summary: String,
}

/// Something in the stream the app reacts to.
#[derive(Debug, Clone, PartialEq)]
pub enum StreamEvent {
    /// Block `block` started (OSC 133;C).
    CommandStarted { block: u64 },
    /// Block `block` finished (OSC 133;D, or a new prompt). `seconds` is
    /// how long it ran.
    CommandFinished {
        block: u64,
        exit_code: Option<i32>,
        seconds: Option<f64>,
        command: Option<String>,
    },
    /// The shell's folder (OSC 7 or OSC 9;9), as a Windows path when it is
    /// on a drive, else as the shell wrote it (a WSL path).
    WorkingDirectory(String),
    /// A desktop notification: OSC 9 (body only) or OSC 777;notify.
    Notification { title: Option<String>, body: String },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum State {
    Ground,
    Escape,
    Csi,
    Osc,
    OscEscape,
    String,
    StringEscape,
    EscapeIntermediate,
}

/// Reads a pane's output stream into [`CommandBlock`]s, however the reads
/// split it. Keeps the newest `max_blocks` blocks and the last
/// `max_output` bytes of each block's output.
pub struct CommandBlockParser {
    blocks: Vec<CommandBlock>,
    max_blocks: usize,
    max_output: usize,
    state: State,
    osc_buffer: Vec<u8>,
    pending_command: Option<String>,
    pending_carriage_return: bool,
    /// The open block is collecting output (between 133;C and 133;D).
    capturing: bool,
    next_id: u64,
    clock: Box<dyn FnMut() -> f64 + Send>,
    events: Vec<StreamEvent>,
}

impl Default for CommandBlockParser {
    fn default() -> Self {
        Self::new()
    }
}

impl std::fmt::Debug for CommandBlockParser {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CommandBlockParser")
            .field("blocks", &self.blocks.len())
            .finish()
    }
}

/// An OSC payload is cut off past this many bytes.
const MAX_OSC: usize = 1 << 16;

fn system_now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64())
}

impl CommandBlockParser {
    /// 200 blocks of up to 256 KiB each, as on macOS.
    pub fn new() -> Self {
        Self::with_limits(200, 256 << 10)
    }

    pub fn with_limits(max_blocks: usize, max_output: usize) -> Self {
        CommandBlockParser {
            blocks: Vec::new(),
            max_blocks,
            max_output,
            state: State::Ground,
            osc_buffer: Vec::new(),
            pending_command: None,
            pending_carriage_return: false,
            capturing: false,
            next_id: 0,
            clock: Box::new(system_now),
            events: Vec::new(),
        }
    }

    /// Replaces the clock (seconds since the Unix epoch), for tests.
    pub fn set_clock(&mut self, clock: Box<dyn FnMut() -> f64 + Send>) {
        self.clock = clock;
    }

    pub fn blocks(&self) -> &[CommandBlock] {
        &self.blocks
    }

    pub fn max_blocks(&self) -> usize {
        self.max_blocks
    }

    pub fn max_output(&self) -> usize {
        self.max_output
    }

    /// Forgets every block (the pane's screen was replaced by a replay).
    /// Ids keep counting so the app never sees one reused.
    pub fn reset(&mut self) {
        self.blocks.clear();
        self.state = State::Ground;
        self.osc_buffer.clear();
        self.pending_command = None;
        self.pending_carriage_return = false;
        self.capturing = false;
    }

    /// Reads `data` and returns what happened in it. `replayed`: the bytes
    /// are a reattach's replay of earlier output, so the commands it shows
    /// are not news (no start, finish or notification events) and the
    /// blocks get no timing (it would be the replay's, not the commands').
    pub fn feed(&mut self, data: &[u8], replayed: bool) -> Vec<StreamEvent> {
        for &byte in data {
            self.step(byte);
        }
        let mut events = std::mem::take(&mut self.events);
        if replayed {
            for block in self.blocks.iter_mut().filter(|b| b.is_finished) {
                block.finished_at = None;
            }
            events.retain(|e| matches!(e, StreamEvent::WorkingDirectory(_)));
        }
        events
    }

    fn step(&mut self, byte: u8) {
        match self.state {
            State::Ground => {
                if byte == 0x1B {
                    self.state = State::Escape;
                } else if self.capturing {
                    self.text(byte);
                }
            }
            State::Escape => {
                self.state = match byte {
                    b'[' => State::Csi,
                    b']' => {
                        self.osc_buffer.clear();
                        State::Osc
                    }
                    b'P' | b'X' | b'^' | b'_' => State::String,
                    0x20..=0x2F => State::EscapeIntermediate, // ESC ( B and friends
                    0x1B => State::Escape,
                    _ => State::Ground,
                }
            }
            State::EscapeIntermediate => self.state = State::Ground,
            State::Csi => {
                if (0x40..=0x7E).contains(&byte) {
                    self.state = State::Ground;
                }
            }
            State::Osc => match byte {
                0x07 => self.finish_osc(),
                0x1B => self.state = State::OscEscape,
                _ => {
                    if self.osc_buffer.len() < MAX_OSC {
                        self.osc_buffer.push(byte);
                    }
                }
            },
            State::OscEscape => {
                self.finish_osc(); // ESC \ ends it; anything else is malformed
                if byte != b'\\' {
                    self.step(byte);
                }
            }
            State::String => {
                if byte == 0x1B {
                    self.state = State::StringEscape;
                }
            }
            State::StringEscape => {
                self.state = if byte == b'\\' {
                    State::Ground
                } else {
                    State::String
                };
            }
        }
    }

    /// A plain byte of the running command's output.
    fn text(&mut self, byte: u8) {
        let max_output = self.max_output;
        let Some(block) = self.blocks.last_mut() else {
            return;
        };
        match byte {
            0x0D => self.pending_carriage_return = true,
            0x0A => {
                self.pending_carriage_return = false;
                block.bytes.push(byte);
                block.line_start = block.bytes.len();
            }
            0x08 => {
                // Back over one character (and its UTF-8 continuation bytes).
                while block.bytes.len() > block.line_start {
                    let removed = block.bytes.pop().unwrap_or(0);
                    if removed & 0xC0 != 0x80 {
                        break;
                    }
                }
            }
            0x09 => Self::append(byte, block, &mut self.pending_carriage_return, max_output),
            0x00..=0x1F | 0x7F => {}
            _ => Self::append(byte, block, &mut self.pending_carriage_return, max_output),
        }
    }

    fn append(
        byte: u8,
        block: &mut CommandBlock,
        pending_carriage_return: &mut bool,
        max_output: usize,
    ) {
        if *pending_carriage_return {
            // A carriage return without a newline: the line is redrawn
            // (progress bars, spinners); keep only the last version.
            *pending_carriage_return = false;
            block.bytes.truncate(block.line_start);
        }
        block.bytes.push(byte);
        if block.bytes.len() > max_output {
            let mut drop = block.bytes.len() - max_output * 3 / 4;
            // Do not start in the middle of a character.
            while drop < block.bytes.len() && block.bytes[drop] & 0xC0 == 0x80 {
                drop += 1;
            }
            block.bytes.drain(..drop);
            block.line_start = block.line_start.saturating_sub(drop);
            block.is_truncated = true;
        }
    }

    fn finish_osc(&mut self) {
        self.state = State::Ground;
        let payload = String::from_utf8_lossy(&self.osc_buffer).into_owned();
        self.osc_buffer.clear();
        let fields: Vec<&str> = payload.splitn(3, ';').collect();
        let kind = fields[0];
        let mark = fields.get(1).copied().unwrap_or("");
        let rest = fields.get(2).copied();
        match kind {
            "133" if mark.starts_with('C') => self.start(),
            "133" if mark.starts_with('D') => {
                let code = rest.and_then(|r| exit_code(r.split(';').next().unwrap_or("")));
                self.finish(code);
            }
            "133" if mark.starts_with('A') => {
                // A new prompt: whatever ran before it is over.
                if self.capturing {
                    self.finish(None);
                }
            }
            "633" if mark == "E" => {
                let report = rest.unwrap_or("");
                let command = CommandLineReport::unescape(report.split(';').next().unwrap_or(""));
                match self.blocks.last_mut() {
                    Some(block) if self.capturing => {
                        if block.command.is_none() {
                            block.command = Some(command);
                        }
                    }
                    _ => self.pending_command = Some(command),
                }
            }
            "7" => {
                if let Some(folder) = paths::file_url_to_path(payload.get(2..).unwrap_or("")) {
                    self.events.push(StreamEvent::WorkingDirectory(folder));
                }
            }
            "9" => self.osc_9(payload.get(2..).unwrap_or(""), mark, rest),
            "777" if mark == "notify" => {
                let rest = rest.unwrap_or("");
                let (title, body) = rest.split_once(';').unwrap_or((rest, ""));
                self.events.push(StreamEvent::Notification {
                    title: (!title.is_empty()).then(|| title.to_string()),
                    body: body.to_string(),
                });
            }
            _ => {}
        }
    }

    /// OSC 9: `9;9;<folder>` is ConEmu's (and Windows Terminal's) working
    /// directory; any other numbered subcommand (`9;4;...` is progress) is
    /// not ours; anything else is an iTerm2-style notification.
    fn osc_9(&mut self, body: &str, mark: &str, rest: Option<&str>) {
        let numbered = !mark.is_empty() && mark.bytes().all(|b| b.is_ascii_digit());
        if numbered {
            if mark == "9" {
                let folder = rest.unwrap_or("").trim();
                let folder = folder
                    .strip_prefix('"')
                    .and_then(|f| f.strip_suffix('"'))
                    .unwrap_or(folder);
                if !folder.is_empty() {
                    self.events
                        .push(StreamEvent::WorkingDirectory(folder.to_string()));
                }
            }
            return;
        }
        if !body.is_empty() {
            self.events.push(StreamEvent::Notification {
                title: None,
                body: body.to_string(),
            });
        }
    }

    fn start(&mut self) {
        if self.capturing {
            self.finish(None);
        }
        let now = (self.clock)();
        self.blocks.push(CommandBlock::new(
            self.next_id,
            self.pending_command.take(),
            now,
        ));
        self.events.push(StreamEvent::CommandStarted {
            block: self.next_id,
        });
        self.next_id += 1;
        self.pending_carriage_return = false;
        self.capturing = true;
        if self.blocks.len() > self.max_blocks {
            let excess = self.blocks.len() - self.max_blocks;
            self.blocks.drain(..excess);
        }
    }

    fn finish(&mut self, code: Option<i32>) {
        if !self.capturing || self.blocks.is_empty() {
            return;
        }
        let now = (self.clock)();
        let block = self.blocks.last_mut().expect("a block");
        block.is_finished = true;
        block.exit_code = code;
        block.finished_at = Some(now);
        self.events.push(StreamEvent::CommandFinished {
            block: block.id,
            exit_code: code,
            seconds: block.duration(),
            command: block.command.clone(),
        });
        self.capturing = false;
        self.pending_carriage_return = false;
    }
}

/// An exit status as a shell prints it. Windows statuses are 32-bit and
/// show up signed (pwsh, -1073741510) or unsigned (cmd, 3221225786); both
/// read as the same signed value.
fn exit_code(text: &str) -> Option<i32> {
    text.parse::<i32>()
        .ok()
        .or_else(|| text.parse::<u32>().ok().map(|code| code as i32))
}

/// How ghostgrid's shell hooks report each command line before it runs:
/// `OSC 633 ; E ; <command> BEL`, VS Code's convention, with `\` written
/// `\\`, and `;` and control characters written `\xNN`.
pub struct CommandLineReport;

impl CommandLineReport {
    pub fn escape(command: &str) -> String {
        let mut out = String::with_capacity(command.len());
        for c in command.chars() {
            match c {
                '\\' => out.push_str("\\\\"),
                ';' => out.push_str("\\x3b"),
                c if (c as u32) < 0x20 || c as u32 == 0x7F => {
                    out.push_str(&format!("\\x{:02x}", c as u32))
                }
                c => out.push(c),
            }
        }
        out
    }

    pub fn unescape(text: &str) -> String {
        let chars: Vec<char> = text.chars().collect();
        let mut out = String::with_capacity(text.len());
        let mut index = 0;
        while index < chars.len() {
            let c = chars[index];
            if c != '\\' || index + 1 >= chars.len() {
                out.push(c);
                index += 1;
                continue;
            }
            let next = chars[index + 1];
            if next == '\\' {
                out.push('\\');
                index += 2;
                continue;
            }
            if next == 'x' && index + 4 <= chars.len() {
                let hex: String = chars[index + 2..index + 4].iter().collect();
                if hex.chars().all(|h| h.is_ascii_hexdigit()) {
                    if let Some(decoded) =
                        u32::from_str_radix(&hex, 16).ok().and_then(char::from_u32)
                    {
                        out.push(decoded);
                        index += 4;
                        continue;
                    }
                }
            }
            out.push(c);
            index += 1;
        }
        out
    }
}
