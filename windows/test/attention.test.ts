// Port of AttentionTests: a pane that needs you (a bell, a notification, a
// finished background command: an agent waiting) or that just printed
// grows; panes quiet for a while shrink; the layout stays gentle and
// balanced when nothing stands out.
import { describe, expect, it } from "vitest";
import {
  ATTENTION_WEIGHT,
  attentionLevel,
  attentionLevels,
  attentionWeights,
  compareAttention,
  FRESH_SECONDS,
  IDLE_AFTER_SECONDS,
  type AttentionLevel,
} from "../src/core/attention";
import { frames, type LayoutMode } from "../src/core/gridLayout";
import type { Rect } from "../src/core/geometry";

const now = 1_000_000_000; // ms
const bounds: Rect = { x: 0, y: 0, width: 1200, height: 800 };

function level(secondsAgo: number | null, waiting = false, focused = false): AttentionLevel {
  return attentionLevel({ lastOutput: secondsAgo === null ? null : now - secondsAgo * 1000, waiting, focused, now });
}

function laid(levels: AttentionLevel[], mode: LayoutMode): Rect[] {
  return frames({ count: levels.length, bounds, gap: 8, mode, weights: attentionWeights(levels, mode) });
}

describe("Attention", () => {
  it("has its constants and order", () => {
    expect(FRESH_SECONDS).toBe(4);
    expect(IDLE_AFTER_SECONDS).toBe(90);
    expect(attentionLevels).toEqual(["idle", "quiet", "active", "wanted"]);
    expect(ATTENTION_WEIGHT).toEqual({ idle: 0.7, quiet: 1, active: 1.35, wanted: 1.7 });
    expect(compareAttention("idle", "wanted")).toBeLessThan(0);
    expect(compareAttention("active", "quiet")).toBeGreaterThan(0);
    expect(compareAttention("quiet", "quiet")).toBe(0);
  });

  it("follows what the pane is doing", () => {
    expect(level(500, true)).toBe("wanted"); // an agent waiting for you
    expect(level(1)).toBe("active"); // fresh output
    expect(level(30)).toBe("quiet");
    expect(level(500)).toBe("idle");
    expect(level(null)).toBe("idle");
    expect(level(500, false, true)).toBe("active"); // the pane you are in never shrinks
    expect(level(500, true, true)).toBe("active"); // you are already there
  });

  it("puts the boundaries where the Swift does", () => {
    expect(level(4)).toBe("active");
    expect(level(4.001)).toBe("quiet");
    expect(level(89.999)).toBe("quiet");
    expect(level(90)).toBe("idle");
  });

  it("is balanced when nothing stands out", () => {
    expect(attentionWeights(["quiet", "quiet", "quiet", "quiet"], "grid")).toBeNull();
    expect(attentionWeights(["idle", "idle"], "columns")).toBeNull();
    expect(attentionWeights([], "grid")).toBeNull();
  });

  it("grows a wanted pane in the grid", () => {
    const balanced = frames({ count: 4, bounds, gap: 8, mode: "grid" });
    const grown = laid(["wanted", "idle", "quiet", "quiet"], "grid");
    expect(grown[0]!.width).toBeGreaterThan(balanced[0]!.width);
    expect(grown[0]!.height).toBeGreaterThan(balanced[0]!.height);
    expect(grown[1]!.width).toBeLessThan(balanced[1]!.width); // its idle neighbour gives way
    expect(grown[0]!.width).toBeGreaterThan(grown[1]!.width);
  });

  it("main and stack follow attention", () => {
    const balanced = frames({ count: 3, bounds, gap: 8, mode: "mainStack" });
    const grown = laid(["idle", "wanted", "quiet"], "mainStack");
    expect(grown[0]!.width).toBeLessThan(balanced[0]!.width); // an idle main pane yields to the stack
    expect(grown[1]!.height).toBeGreaterThan(grown[2]!.height); // the wanted stack pane is the tallest there
  });

  it("columns follow attention", () => {
    const grown = laid(["active", "idle", "idle"], "columns");
    expect(grown[0]!.width).toBeGreaterThan(grown[1]!.width);
    expect(Math.abs(grown[1]!.width - grown[2]!.width)).toBeLessThan(0.5);
  });

  it("stays gentle", () => {
    const balanced = frames({ count: 4, bounds, gap: 8, mode: "grid" });
    const grown = laid(["wanted", "idle", "idle", "idle"], "grid");
    balanced.forEach((before, i) => {
      const after = grown[i]!;
      const area = after.width * after.height;
      const was = before.width * before.height;
      expect(area).toBeGreaterThanOrEqual(was * 0.5); // no pane shrinks below half
      expect(area).toBeLessThanOrEqual(was * 2.2); // and none takes over
    });
  });

  it("sizes a track by its most wanted pane", () => {
    expect(attentionWeights(["wanted", "idle", "quiet", "quiet"], "grid")).toEqual({
      tracks: [1.7, 1],
      cells: [
        [1.7, 0.7],
        [1, 1],
      ],
    });
    const main = attentionWeights(["idle", "wanted", "quiet"], "mainStack")!;
    expect(main.cells).toEqual([[0.7], [1.7, 1]]);
    expect(main.tracks[0]).toBeCloseTo(0.6 * 0.7, 12);
    expect(main.tracks[1]).toBeCloseTo(0.4 * 1.7, 12);
  });
});
