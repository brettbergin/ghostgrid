//! A shell's recent output, kept by sessiond so a reattaching pane can be
//! brought back to the same screen.

use std::collections::VecDeque;

/// Bounded: the oldest bytes go first. A deque, so trimming the front of a
/// full history costs only what is dropped.
#[derive(Debug, Clone)]
pub struct OutputHistory {
    capacity: usize,
    bytes: VecDeque<u8>,
    trimmed: bool,
}

impl Default for OutputHistory {
    fn default() -> Self {
        Self::new()
    }
}

impl OutputHistory {
    /// 4 MiB, as on macOS: a few screens of scrollback for most shells.
    pub const DEFAULT_CAPACITY: usize = 4 << 20;

    pub fn new() -> Self {
        Self::with_capacity(Self::DEFAULT_CAPACITY)
    }

    pub fn with_capacity(capacity: usize) -> Self {
        OutputHistory {
            capacity,
            bytes: VecDeque::new(),
            trimmed: false,
        }
    }

    pub fn capacity(&self) -> usize {
        self.capacity
    }

    pub fn append(&mut self, data: &[u8]) {
        self.bytes.extend(data);
        if self.bytes.len() > self.capacity {
            let excess = self.bytes.len() - self.capacity;
            self.bytes.drain(..excess);
            self.trimmed = true;
        }
    }

    /// What to replay. After a trim the first line may start inside an
    /// escape sequence or a UTF-8 character, so the replay starts after the
    /// first newline then; it always begins with a terminal reset (RIS) so
    /// the new screen starts clean.
    pub fn replay(&self) -> Vec<u8> {
        let skip = if self.trimmed {
            self.bytes
                .iter()
                .position(|&b| b == b'\n')
                .map_or(0, |newline| newline + 1)
        } else {
            0
        };
        let mut out = Vec::with_capacity(2 + self.bytes.len() - skip);
        out.extend_from_slice(b"\x1bc");
        out.extend(self.bytes.iter().skip(skip));
        out
    }
}
