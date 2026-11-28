// ghostgrid's keyboard on Windows. Not a port of the Mac keymap: there
// every shortcut is on Cmd, which no terminal program sees. On Windows the
// same letters on Ctrl are terminal control keys (Ctrl+D is EOF, Ctrl+W
// deletes a word, Ctrl+T transposes), so ghostgrid's shortcuts use
// Ctrl+Shift (like Windows Terminal) and Ctrl+Alt, and Ctrl alone only on
// keys that send nothing useful to a shell (digits, Tab, PageUp/Down,
// "=", "-", ",").
//
// Chords match KeyboardEvent.code, the physical key, not .key: the code
// is the same on every layout and with Shift held ("Digit1", not "!"),
// so a shortcut stays where the menus say it is.

/// The commands that can have shortcuts, in menu order.
export const commands = [
  "newWindow",
  "newTab",
  "newTabChoosingShell",
  "newPane",
  "newPaneChoosingShell",
  "closePane",
  "closeTab",
  "closeWindow",
  "toggleBroadcast",
  "nextTab",
  "previousTab",
  "toggleZoom",
  "toggleCommandBlocks",
  "copyLastCommandOutput",
  "explainLastFailure",
  "nextPane",
  "previousPane",
  "focusLeft",
  "focusRight",
  "focusUp",
  "focusDown",
  "swapLeft",
  "swapRight",
  "swapUp",
  "swapDown",
  "makeMain",
  "equalizePanes",
  "toggleAttentionGrid",
  "cycleLayout",
  "rotateLayout",
  "showSettings",
  "openConfiguration",
  "reloadConfiguration",
  "quit",
  "minimize",
  "toggleFullScreen",
  "copy",
  "paste",
  "find",
  "clearScreen",
  "fontBigger",
  "fontSmaller",
  "fontReset",
  "renameTab",
  "moveTabToNewWindow",
] as const;

export type Command = (typeof commands)[number];

/// A physical key and the exact modifiers held with it.
export interface KeyChord {
  code: string;
  ctrl: boolean;
  shift: boolean;
  alt: boolean;
  meta: boolean;
}

type Mods = "" | "C" | "CS" | "CA" | "CAS" | "A" | "S";

function k(code: string, mods: Mods = ""): KeyChord {
  return { code, ctrl: mods.includes("C"), shift: mods.includes("S"), alt: mods.includes("A"), meta: false };
}

/// Each command's shortcuts: the first is shown in menus, the rest work
/// too (hidden alternates). Minimize and Move Tab to New Window have none:
/// the window and tab menus are enough, and every free chord is one fewer
/// for the programs running in the panes.
const table: Readonly<Record<Command, readonly KeyChord[]>> = {
  newWindow: [k("KeyN", "CS")],
  newTab: [k("KeyT", "CS")],
  newTabChoosingShell: [k("KeyT", "CAS")],
  newPane: [k("KeyD", "CS")],
  newPaneChoosingShell: [k("KeyD", "CAS")],
  closePane: [k("KeyW", "CS")],
  closeTab: [k("KeyW", "CA")],
  closeWindow: [k("KeyW", "CAS")],
  toggleBroadcast: [k("KeyI", "CA")],
  nextTab: [k("Tab", "C"), k("PageDown", "C")],
  previousTab: [k("Tab", "CS"), k("PageUp", "C")],
  toggleZoom: [k("Enter", "CS")],
  toggleCommandBlocks: [k("KeyB", "CS")],
  copyLastCommandOutput: [k("KeyC", "CAS")],
  explainLastFailure: [k("KeyE", "CS")],
  nextPane: [k("BracketRight", "CS")],
  previousPane: [k("BracketLeft", "CS")],
  focusLeft: [k("ArrowLeft", "CA")],
  focusRight: [k("ArrowRight", "CA")],
  focusUp: [k("ArrowUp", "CA")],
  focusDown: [k("ArrowDown", "CA")],
  swapLeft: [k("ArrowLeft", "CAS")],
  swapRight: [k("ArrowRight", "CAS")],
  swapUp: [k("ArrowUp", "CAS")],
  swapDown: [k("ArrowDown", "CAS")],
  makeMain: [k("KeyM", "CS")],
  equalizePanes: [k("Equal", "CA")],
  toggleAttentionGrid: [k("KeyA", "CA")],
  cycleLayout: [k("KeyL", "CS")],
  rotateLayout: [k("KeyR", "CA")],
  showSettings: [k("Comma", "C")],
  openConfiguration: [k("Comma", "CA")],
  reloadConfiguration: [k("Comma", "CS")],
  quit: [k("KeyQ", "CS")],
  minimize: [],
  // F11 as in every Windows app; Alt+Enter as in Windows Terminal and the
  // old console.
  toggleFullScreen: [k("F11"), k("Enter", "A")],
  // Ctrl+Shift+C/V because Ctrl+C is the shell's interrupt; Ctrl+Insert
  // and Shift+Insert are the older Windows convention.
  copy: [k("KeyC", "CS"), k("Insert", "C")],
  paste: [k("KeyV", "CS"), k("Insert", "S")],
  find: [k("KeyF", "CS")],
  clearScreen: [k("KeyK", "CS")],
  // Ctrl+Shift+= is Ctrl+Plus on US layouts; the keypad keys work too.
  fontBigger: [k("Equal", "C"), k("Equal", "CS"), k("NumpadAdd", "C")],
  fontSmaller: [k("Minus", "C"), k("NumpadSubtract", "C")],
  fontReset: [k("Digit0", "C"), k("Numpad0", "C")],
  // Not Ctrl+Shift+R: PSReadLine and some shells use it for search.
  renameTab: [k("KeyR", "CAS")],
  moveTabToNewWindow: [],
};

/// A command's shortcuts (fresh copies; the first is the one menus show).
export function bindings(command: Command): KeyChord[] {
  return table[command].map((c) => ({ ...c }));
}

/// Ctrl+1...9: that tab (Ctrl+9: the last one), as in browsers and
/// Windows Terminal.
export function selectTabChord(number: number): KeyChord {
  return k(`Digit${number}`, "C");
}

/// Ctrl+Alt+1...9: the pane at that position in the current tab.
export function focusPaneChord(number: number): KeyChord {
  return k(`Digit${number}`, "CA");
}

/// Every shortcut with what it belongs to: a command's name, or
/// selectTab1...9 and focusPane1...9.
export function everyBinding(): { name: string; chord: KeyChord }[] {
  const out: { name: string; chord: KeyChord }[] = [];
  for (const command of commands) for (const chord of bindings(command)) out.push({ name: command, chord });
  for (let n = 1; n <= 9; n++) out.push({ name: `selectTab${n}`, chord: selectTabChord(n) });
  for (let n = 1; n <= 9; n++) out.push({ name: `focusPane${n}`, chord: focusPaneChord(n) });
  return out;
}

export type KeyMatch = { command: Command } | { selectTab: number } | { focusPane: number };

function chordKey(code: string, ctrl: boolean, shift: boolean, alt: boolean, meta: boolean): string {
  return `${ctrl ? "C" : ""}${alt ? "A" : ""}${shift ? "S" : ""}${meta ? "M" : ""}:${code}`;
}

// Built once: matchKey runs on every keystroke in every pane.
const lookup: ReadonlyMap<string, KeyMatch> = (() => {
  const map = new Map<string, KeyMatch>();
  const add = (c: KeyChord, match: KeyMatch) => map.set(chordKey(c.code, c.ctrl, c.shift, c.alt, c.meta), match);
  for (const command of commands) for (const c of table[command]) add(c, { command });
  for (let n = 1; n <= 9; n++) {
    add(selectTabChord(n), { selectTab: n });
    add(focusPaneChord(n), { focusPane: n });
  }
  return map;
})();

/// The shortcut a key press is, or null when it is typing for the pane.
/// The modifiers must match exactly: Ctrl+Shift+T is New Tab, but
/// Ctrl+Shift+Win+T is not.
///
/// `altGraph`: pass e.getModifierState("AltGraph"). Windows reports AltGr
/// as Ctrl+Alt, so on layouts where AltGr types characters (German AltGr+7
/// is "{") a Ctrl+Alt chord would otherwise swallow them. Chromium sets
/// AltGraph when the key types a character that way; such a key is always
/// typing.
export function matchKey(e: {
  code: string;
  ctrlKey: boolean;
  shiftKey: boolean;
  altKey: boolean;
  metaKey: boolean;
  altGraph?: boolean;
}): KeyMatch | null {
  if (e.altGraph && e.ctrlKey && e.altKey) return null;
  return lookup.get(chordKey(e.code, e.ctrlKey, e.shiftKey, e.altKey, e.metaKey)) ?? null;
}

const keyNames: Readonly<Record<string, string>> = {
  BracketRight: "]",
  BracketLeft: "[",
  Equal: "=",
  Minus: "-",
  Comma: ",",
  Period: ".",
  Slash: "/",
  Backslash: "\\",
  Semicolon: ";",
  Quote: "'",
  Backquote: "`",
  ArrowLeft: "Left",
  ArrowRight: "Right",
  ArrowUp: "Up",
  ArrowDown: "Down",
  NumpadAdd: "Num+",
  NumpadSubtract: "Num-",
  NumpadMultiply: "Num*",
  NumpadDivide: "Num/",
  NumpadDecimal: "Num.",
  NumpadEnter: "NumEnter",
  Escape: "Esc",
};

/// A chord as menus and settings show it, the Windows way: "Ctrl+Shift+T",
/// "Ctrl+Alt+Left", "Ctrl+]". Keys are named by their US-layout label.
export function describe(chord: KeyChord): string {
  const parts: string[] = [];
  if (chord.ctrl) parts.push("Ctrl");
  if (chord.alt) parts.push("Alt");
  if (chord.shift) parts.push("Shift");
  if (chord.meta) parts.push("Win");
  parts.push(keyName(chord.code));
  return parts.join("+");
}

function keyName(code: string): string {
  const named = keyNames[code];
  if (named !== undefined) return named;
  const letter = /^Key([A-Z])$/.exec(code);
  if (letter) return letter[1]!;
  const digit = /^Digit(\d)$/.exec(code);
  if (digit) return digit[1]!;
  const pad = /^Numpad(\d)$/.exec(code);
  if (pad) return `Num${pad[1]!}`;
  return code; // Tab, Enter, PageDown, F11, Insert, ...
}
