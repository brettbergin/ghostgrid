// The Windows keyboard. Not a port of the Mac keymap: Cmd shortcuts would
// land on terminal control keys, so ghostgrid uses Ctrl+Shift (like Windows
// Terminal) and Ctrl+Alt, and no shortcut does two things.
import { describe, expect, it } from "vitest";
import {
  bindings,
  commands,
  describe as describeChord,
  everyBinding,
  focusPaneChord,
  matchKey,
  selectTabChord,
  type Command,
  type KeyChord,
} from "../src/core/keymap";

type Mods = Partial<Pick<KeyChord, "ctrl" | "shift" | "alt" | "meta">>;
const chord = (code: string, mods: Mods = {}): KeyChord => ({
  code,
  ctrl: mods.ctrl ?? false,
  shift: mods.shift ?? false,
  alt: mods.alt ?? false,
  meta: mods.meta ?? false,
});
const C = { ctrl: true };
const CS = { ctrl: true, shift: true };
const CA = { ctrl: true, alt: true };
const CAS = { ctrl: true, alt: true, shift: true };

const event = (code: string, mods: Mods = {}) => ({
  code,
  ctrlKey: mods.ctrl ?? false,
  shiftKey: mods.shift ?? false,
  altKey: mods.alt ?? false,
  metaKey: mods.meta ?? false,
});

const key = (c: KeyChord) => `${c.ctrl}${c.alt}${c.shift}${c.meta}:${c.code}`;

describe("Keymap bindings", () => {
  it("binds every command as specified", () => {
    const expected: [Command, KeyChord[]][] = [
      ["newWindow", [chord("KeyN", CS)]],
      ["newTab", [chord("KeyT", CS)]],
      ["newTabChoosingShell", [chord("KeyT", CAS)]],
      ["newPane", [chord("KeyD", CS)]],
      ["newPaneChoosingShell", [chord("KeyD", CAS)]],
      ["closePane", [chord("KeyW", CS)]],
      ["closeTab", [chord("KeyW", CA)]],
      ["closeWindow", [chord("KeyW", CAS)]],
      ["toggleBroadcast", [chord("KeyI", CA)]],
      ["nextTab", [chord("Tab", C), chord("PageDown", C)]],
      ["previousTab", [chord("Tab", CS), chord("PageUp", C)]],
      ["toggleZoom", [chord("Enter", CS)]],
      ["toggleCommandBlocks", [chord("KeyB", CS)]],
      ["copyLastCommandOutput", [chord("KeyC", CAS)]],
      ["explainLastFailure", [chord("KeyE", CS)]],
      ["nextPane", [chord("BracketRight", CS)]],
      ["previousPane", [chord("BracketLeft", CS)]],
      ["focusLeft", [chord("ArrowLeft", CA)]],
      ["focusRight", [chord("ArrowRight", CA)]],
      ["focusUp", [chord("ArrowUp", CA)]],
      ["focusDown", [chord("ArrowDown", CA)]],
      ["swapLeft", [chord("ArrowLeft", CAS)]],
      ["swapRight", [chord("ArrowRight", CAS)]],
      ["swapUp", [chord("ArrowUp", CAS)]],
      ["swapDown", [chord("ArrowDown", CAS)]],
      ["makeMain", [chord("KeyM", CS)]],
      ["equalizePanes", [chord("Equal", CA)]],
      ["toggleAttentionGrid", [chord("KeyA", CA)]],
      ["cycleLayout", [chord("KeyL", CS)]],
      ["rotateLayout", [chord("KeyR", CA)]],
      ["showSettings", [chord("Comma", C)]],
      ["openConfiguration", [chord("Comma", CA)]],
      ["reloadConfiguration", [chord("Comma", CS)]],
      ["quit", [chord("KeyQ", CS)]],
      ["minimize", []],
      ["toggleFullScreen", [chord("F11"), chord("Enter", { alt: true })]],
      ["copy", [chord("KeyC", CS), chord("Insert", C)]],
      ["paste", [chord("KeyV", CS), chord("Insert", { shift: true })]],
      ["find", [chord("KeyF", CS)]],
      ["clearScreen", [chord("KeyK", CS)]],
      ["fontBigger", [chord("Equal", C), chord("Equal", CS), chord("NumpadAdd", C)]],
      ["fontSmaller", [chord("Minus", C), chord("NumpadSubtract", C)]],
      ["fontReset", [chord("Digit0", C), chord("Numpad0", C)]],
      ["renameTab", [chord("KeyR", CAS)]],
      ["moveTabToNewWindow", []],
    ];
    expect(commands.length).toBe(expected.length);
    expect([...commands].sort()).toEqual(expected.map(([c]) => c).sort());
    for (const [command, chords] of expected) expect(bindings(command), command).toEqual(chords);
  });

  it("picks tabs on Ctrl+1-9 and panes on Ctrl+Alt+1-9", () => {
    for (let n = 1; n <= 9; n++) {
      expect(selectTabChord(n)).toEqual(chord(`Digit${n}`, C));
      expect(focusPaneChord(n)).toEqual(chord(`Digit${n}`, CA));
    }
  });

  it("has no shortcut doing two things", () => {
    const seen = new Map<string, string>();
    for (const { name, chord: c } of everyBinding()) {
      const k = key(c);
      expect(seen.get(k), `${describeChord(c)} is both ${seen.get(k)} and ${name}`).toBeUndefined();
      seen.set(k, name);
    }
    expect(seen.size).toBeGreaterThan(50);
  });

  it("keeps ordinary typing off the shortcuts", () => {
    // Every chord needs Ctrl or Alt, or is a function key, or is
    // Shift+Insert (the Windows paste convention).
    for (const { name, chord: c } of everyBinding()) {
      const ok = c.ctrl || c.alt || /^F\d+$/.test(c.code) || (c.code === "Insert" && c.shift);
      expect(ok, `${name}: ${describeChord(c)}`).toBe(true);
      expect(c.meta, `${name} uses the Windows key`).toBe(false);
    }
  });

  it("never takes Ctrl alone on a letter (terminal control keys)", () => {
    // Ctrl+letter is a control character a shell or editor needs.
    for (const { name, chord: c } of everyBinding()) {
      if (c.code.startsWith("Key") && c.ctrl && !c.alt) expect(c.shift, name).toBe(true);
    }
  });

  it("lists every binding with its name", () => {
    const names = everyBinding().map((b) => b.name);
    expect(names).toContain("newTab");
    expect(names).toContain("selectTab1");
    expect(names).toContain("selectTab9");
    expect(names).toContain("focusPane9");
    expect(names).not.toContain("minimize");
  });
});

describe("matchKey", () => {
  it("finds commands", () => {
    expect(matchKey(event("KeyT", CS))).toEqual({ command: "newTab" });
    expect(matchKey(event("KeyT", CAS))).toEqual({ command: "newTabChoosingShell" });
    expect(matchKey(event("Tab", C))).toEqual({ command: "nextTab" });
    expect(matchKey(event("PageDown", C))).toEqual({ command: "nextTab" });
    expect(matchKey(event("Tab", CS))).toEqual({ command: "previousTab" });
    expect(matchKey(event("BracketRight", CS))).toEqual({ command: "nextPane" });
    expect(matchKey(event("ArrowLeft", CA))).toEqual({ command: "focusLeft" });
    expect(matchKey(event("ArrowDown", CAS))).toEqual({ command: "swapDown" });
    expect(matchKey(event("F11"))).toEqual({ command: "toggleFullScreen" });
    expect(matchKey(event("Enter", { alt: true }))).toEqual({ command: "toggleFullScreen" });
    expect(matchKey(event("Insert", { shift: true }))).toEqual({ command: "paste" });
    expect(matchKey(event("Insert", C))).toEqual({ command: "copy" });
    expect(matchKey(event("NumpadAdd", C))).toEqual({ command: "fontBigger" });
    expect(matchKey(event("Equal", CS))).toEqual({ command: "fontBigger" });
    expect(matchKey(event("Equal", CA))).toEqual({ command: "equalizePanes" });
    expect(matchKey(event("Comma", C))).toEqual({ command: "showSettings" });
    expect(matchKey(event("KeyR", CAS))).toEqual({ command: "renameTab" });
  });

  it("finds tab and pane numbers", () => {
    expect(matchKey(event("Digit1", C))).toEqual({ selectTab: 1 });
    expect(matchKey(event("Digit9", C))).toEqual({ selectTab: 9 });
    expect(matchKey(event("Digit3", CA))).toEqual({ focusPane: 3 });
    expect(matchKey(event("Digit0", C))).toEqual({ command: "fontReset" });
  });

  it("needs the modifiers to match exactly", () => {
    expect(matchKey(event("KeyT", C))).toBeNull(); // Ctrl+T is the shell's (transpose)
    expect(matchKey(event("KeyT", { ctrl: true, shift: true, meta: true }))).toBeNull();
    expect(matchKey(event("KeyW", { ctrl: true, alt: true, shift: true, meta: true }))).toBeNull();
    expect(matchKey(event("Digit1", CS))).toBeNull();
    expect(matchKey(event("Digit1", CAS))).toBeNull();
    expect(matchKey(event("ArrowLeft", C))).toBeNull(); // word left in the shell
    expect(matchKey(event("Insert"))).toBeNull();
    expect(matchKey(event("Enter"))).toBeNull();
  });

  it("leaves ordinary typing alone", () => {
    for (const code of ["KeyA", "KeyT", "Digit1", "Space", "Enter", "Tab", "ArrowUp", "Escape", "Backspace", "Equal"]) {
      expect(matchKey(event(code)), code).toBeNull();
      expect(matchKey(event(code, { shift: true })), `Shift+${code}`).toBeNull();
    }
    for (const code of ["KeyC", "KeyD", "KeyL", "KeyR", "KeyW", "KeyZ", "BracketLeft"]) {
      expect(matchKey(event(code, C)), `Ctrl+${code}`).toBeNull();
    }
  });

  it("leaves AltGr characters alone", () => {
    // AltGr reports as Ctrl+Alt on Windows: AltGr+7 is "{" on a German
    // layout, and must type, not focus pane 7.
    expect(matchKey({ ...event("Digit7", CA), altGraph: true })).toBeNull();
    expect(matchKey({ ...event("KeyI", CA), altGraph: true })).toBeNull();
    expect(matchKey({ ...event("Digit7", CA), altGraph: false })).toEqual({ focusPane: 7 });
    // Ctrl+Shift shortcuts never involve AltGr.
    expect(matchKey({ ...event("KeyT", CS), altGraph: false })).toEqual({ command: "newTab" });
  });

  it("round-trips every binding", () => {
    for (const { name, chord: c } of everyBinding()) {
      const found = matchKey(event(c.code, c));
      const label = found === null ? "none" : "command" in found ? found.command : "selectTab" in found ? `selectTab${found.selectTab}` : `focusPane${found.focusPane}`;
      expect(label, describeChord(c)).toBe(name);
    }
  });
});

describe("describe", () => {
  it("writes chords the Windows way", () => {
    expect(describeChord(chord("KeyT", CS))).toBe("Ctrl+Shift+T");
    expect(describeChord(chord("ArrowLeft", CA))).toBe("Ctrl+Alt+Left");
    expect(describeChord(chord("ArrowDown", CAS))).toBe("Ctrl+Alt+Shift+Down");
    expect(describeChord(chord("BracketRight", C))).toBe("Ctrl+]");
    expect(describeChord(chord("BracketLeft", CS))).toBe("Ctrl+Shift+[");
    expect(describeChord(chord("Digit1", C))).toBe("Ctrl+1");
    expect(describeChord(chord("Equal", CA))).toBe("Ctrl+Alt+=");
    expect(describeChord(chord("Minus", C))).toBe("Ctrl+-");
    expect(describeChord(chord("Comma", C))).toBe("Ctrl+,");
    expect(describeChord(chord("Enter", { alt: true }))).toBe("Alt+Enter");
    expect(describeChord(chord("Tab", CS))).toBe("Ctrl+Shift+Tab");
    expect(describeChord(chord("PageDown", C))).toBe("Ctrl+PageDown");
    expect(describeChord(chord("F11"))).toBe("F11");
    expect(describeChord(chord("Insert", { shift: true }))).toBe("Shift+Insert");
    expect(describeChord(chord("NumpadAdd", C))).toBe("Ctrl+Num+");
    expect(describeChord(chord("NumpadSubtract", C))).toBe("Ctrl+Num-");
    expect(describeChord(chord("Numpad0", C))).toBe("Ctrl+Num0");
    expect(describeChord(chord("KeyQ", { meta: true }))).toBe("Win+Q");
  });

  it("describes the first binding of every bound command", () => {
    for (const command of commands) {
      const first = bindings(command)[0];
      if (first) expect(describeChord(first)).toMatch(/^(Ctrl|Alt|Shift|F\d)/);
    }
  });
});
