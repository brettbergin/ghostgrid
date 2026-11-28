// Port of BroadcastTests, plus the Windows-only re-encoding of cursor keys
// for panes whose cursor-key mode differs from the source pane's.
import { describe, expect, it } from "vitest";
import { broadcastTargets, mirrors, reencodeForTarget } from "../src/core/broadcast";

describe("Broadcast targets", () => {
  it("sends to nobody else when off", () => {
    expect(broadcastTargets(0, [true, true, true], false)).toEqual([]);
  });

  it("sends to every other running pane when on", () => {
    expect(broadcastTargets(1, [true, true, true], true)).toEqual([0, 2]);
  });

  it("skips panes still showing their menu", () => {
    expect(broadcastTargets(0, [true, false, true, false], true)).toEqual([2]);
  });

  it("sends to nobody from a source outside the grid", () => {
    expect(broadcastTargets(5, [true, true], true)).toEqual([]);
    expect(broadcastTargets(-1, [true, true], true)).toEqual([]);
    expect(broadcastTargets(null, [true, true], true)).toEqual([]);
  });

  it("does not mirror command shortcuts", () => {
    expect(mirrors(false)).toBe(true);
    expect(mirrors(true)).toBe(false);
  });
});

const ESC = "\x1b";
const normal = (k: string) => `${ESC}[${k}`;
const app = (k: string) => `${ESC}O${k}`;

describe("reencodeForTarget", () => {
  const keys = ["A", "B", "C", "D", "H", "F"];

  it("leaves data alone when both panes are in the same mode", () => {
    for (const k of keys) {
      expect(reencodeForTarget(normal(k), false, false)).toBe(normal(k));
      expect(reencodeForTarget(app(k), true, true)).toBe(app(k));
    }
  });

  it("turns normal-mode cursor keys into application mode", () => {
    for (const k of keys) expect(reencodeForTarget(normal(k), false, true)).toBe(app(k));
  });

  it("turns application-mode cursor keys into normal mode", () => {
    for (const k of keys) expect(reencodeForTarget(app(k), true, false)).toBe(normal(k));
  });

  it("converts every cursor key in a burst, and nothing else", () => {
    const source = `ls${normal("A")}${normal("A")}x${normal("D")}\r`;
    expect(reencodeForTarget(source, false, true)).toBe(`ls${app("A")}${app("A")}x${app("D")}\r`);
    expect(reencodeForTarget(reencodeForTarget(source, false, true), true, false)).toBe(source);
  });

  it("leaves plain text alone", () => {
    for (const text of ["", "hello", "[A", "OA", "echo [A] O B\r", "\x03", "\t", "\x7f", "café \u{1f600}"]) {
      expect(reencodeForTarget(text, false, true)).toBe(text);
      expect(reencodeForTarget(text, true, false)).toBe(text);
    }
  });

  it("leaves modified cursor keys alone (the same in both modes)", () => {
    for (const seq of [`${ESC}[1;5C`, `${ESC}[1;2A`, `${ESC}[1;3D`, `${ESC}[1;5H`, `${ESC}[1;6F`]) {
      expect(reencodeForTarget(seq, false, true)).toBe(seq);
      expect(reencodeForTarget(seq, true, false)).toBe(seq);
    }
  });

  it("leaves other CSI and SS3 sequences alone", () => {
    const others = [
      `${ESC}[3~`, // Delete
      `${ESC}[5~`, // Page Up
      `${ESC}[2~`, // Insert
      `${ESC}[15~`, // F5
      `${ESC}[Z`, // Shift+Tab
      `${ESC}[E`, // keypad 5
      `${ESC}[I`, // focus in
      `${ESC}[O`, // focus out
      `${ESC}OP`, // F1
      `${ESC}OQ`, // F2
      `${ESC}OR`, // F3
      `${ESC}OS`, // F4
      `${ESC}Op`, // application keypad 0
      `${ESC}OM`, // application keypad Enter
    ];
    for (const seq of others) {
      expect(reencodeForTarget(seq, false, true), JSON.stringify(seq)).toBe(seq);
      expect(reencodeForTarget(seq, true, false), JSON.stringify(seq)).toBe(seq);
    }
  });

  it("only converts the sequence of the source's own mode", () => {
    // A normal-mode source never sends ESC O A as a cursor key; leave it be.
    expect(reencodeForTarget(app("A"), false, true)).toBe(app("A"));
    expect(reencodeForTarget(normal("A"), true, false)).toBe(normal("A"));
  });

  it("converts Alt+cursor keys sent as a lone ESC prefix", () => {
    expect(reencodeForTarget(`${ESC}${normal("C")}`, false, true)).toBe(`${ESC}${app("C")}`);
    expect(reencodeForTarget(`${ESC}${app("C")}`, true, false)).toBe(`${ESC}${normal("C")}`);
  });

  it("leaves a lone or trailing ESC alone", () => {
    expect(reencodeForTarget(ESC, false, true)).toBe(ESC);
    expect(reencodeForTarget(`a${ESC}`, true, false)).toBe(`a${ESC}`);
    expect(reencodeForTarget(`${ESC}[`, false, true)).toBe(`${ESC}[`);
    expect(reencodeForTarget(`${ESC}O`, true, false)).toBe(`${ESC}O`);
  });

  it("leaves bracketed pastes alone, escapes and all", () => {
    const paste = `${ESC}[200~printf '${ESC}[H${ESC}OA'${ESC}[201~`;
    expect(reencodeForTarget(paste, false, true)).toBe(paste);
    expect(reencodeForTarget(paste, true, false)).toBe(paste);
    // Keys around a paste still convert.
    expect(reencodeForTarget(`${normal("A")}${paste}${normal("B")}`, false, true)).toBe(`${app("A")}${paste}${app("B")}`);
  });

  it("leaves the rest of an unterminated paste alone", () => {
    const open = `${normal("A")}${ESC}[200~${ESC}[A`;
    expect(reencodeForTarget(open, false, true)).toBe(`${app("A")}${ESC}[200~${ESC}[A`);
  });
});
