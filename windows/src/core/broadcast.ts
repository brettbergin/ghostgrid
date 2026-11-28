// Broadcast typing: keystrokes and pastes in the focused pane go to every
// other pane of its tab too (Shell > Broadcast Input). A port of
// GhostGridCore's Broadcast.swift, plus the cursor-key re-encoding the
// Windows front end needs.

/// The panes (grid indices) that also get what is typed in `source`: none
/// while broadcast is off, otherwise every other pane running a shell
/// (`running`; a pane still showing its menu has none).
export function broadcastTargets(source: number | null, running: readonly boolean[], enabled: boolean): number[] {
  if (!enabled || source === null || !Number.isInteger(source) || source < 0 || source >= running.length) return [];
  const out: number[] = [];
  for (let i = 0; i < running.length; i++) if (i !== source && running[i]) out.push(i);
  return out;
}

/// Whether a key is repeated in the other panes. Command chords are
/// ghostgrid's shortcuts (close, new pane, copy), not typing: they act
/// once, on the focused pane.
export function mirrors(command: boolean): boolean {
  return !command;
}

const ESC = "\x1b";
const PASTE_START = "\x1b[200~";
const PASTE_END = "\x1b[201~";

/// What `data`, encoded by a pane whose cursor-key mode (DECCKM) is
/// `sourceAppCursor`, should be for a pane in `targetAppCursor` mode.
///
/// On macOS each pane got the key event itself and encoded it for its own
/// mode. On Windows the focused pane's xterm.js has already turned the key
/// into bytes, and we forward those, so an arrow pressed in a shell (normal
/// mode, ESC [ A) would reach vim or less in another pane (application
/// mode, which expects ESC O A) as the wrong sequence. This converts the
/// unmodified cursor keys (Up, Down, Right, Left, Home, End) between the
/// two forms, and nothing else:
/// - modified keys (ESC [ 1 ; 5 C) are the same in both modes;
/// - other CSI and SS3 sequences (Delete, F1-F4, keypad) do not depend on
///   DECCKM;
/// - a bracketed paste is text, whatever escapes it contains.
/// Only the source mode's form is converted, so bytes a normal-mode pane
/// could not have produced from a cursor key pass through as they are.
export function reencodeForTarget(data: string, sourceAppCursor: boolean, targetAppCursor: boolean): string {
  if (sourceAppCursor === targetAppCursor) return data;
  let i = data.indexOf(ESC);
  if (i < 0) return data;
  const from = sourceAppCursor ? "O" : "[";
  const to = targetAppCursor ? "O" : "[";
  let out = "";
  let copied = 0;
  while (i >= 0) {
    if (data.startsWith(PASTE_START, i)) {
      const end = data.indexOf(PASTE_END, i + PASTE_START.length);
      if (end < 0) break; // the rest is pasted text
      i = data.indexOf(ESC, end + PASTE_END.length);
      continue;
    }
    if (data[i + 1] === from && isCursorFinal(data.charCodeAt(i + 2))) {
      out += data.slice(copied, i + 1) + to + data[i + 2];
      copied = i + 3;
      i = data.indexOf(ESC, copied);
      continue;
    }
    i = data.indexOf(ESC, i + 1);
  }
  return copied === 0 ? data : out + data.slice(copied);
}

/// A, B, C, D (Up, Down, Right, Left), H (Home), F (End).
function isCursorFinal(code: number): boolean {
  return (code >= 0x41 && code <= 0x44) || code === 0x48 || code === 0x46;
}
