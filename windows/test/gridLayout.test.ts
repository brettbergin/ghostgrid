// Port of GridLayoutTests, LayoutModeTests, ResizeTests, RotateLayoutTests
// and RowMoveTests (the session round-trip cases live with the session
// code, not here).
import { describe, expect, it } from "vitest";
import type { Rect } from "../src/core/geometry";
import {
  drag,
  frames,
  indexAt,
  layoutFromStored,
  layoutModes,
  layoutTitle,
  MAIN_SHARE,
  move,
  neighbor,
  nextLayout,
  splitters,
  structure,
  type LayoutMode,
  type LayoutWeights,
  type Rearrangement,
  type SplitterKind,
} from "../src/core/gridLayout";
import { attentionWeights } from "../src/core/attention";
import { intersects, maxX, maxY, rectContainsRect, shape } from "./helpers";

const wide: Rect = { x: 0, y: 0, width: 1200, height: 800 };
const tall: Rect = { x: 0, y: 0, width: 800, height: 1200 };
const zero: Rect = { x: 0, y: 0, width: 0, height: 0 };

const grid = (count: number, bounds: Rect, gap: number): Rect[] => frames({ count, bounds, gap, mode: "grid" });

function noOverlapInBounds(laid: Rect[], bounds: Rect): boolean {
  for (let i = 0; i < laid.length; i++) {
    if (!rectContainsRect(bounds, laid[i]!)) return false;
    for (let j = i + 1; j < laid.length; j++) if (intersects(laid[i]!, laid[j]!)) return false;
  }
  return true;
}

describe("GridLayout", () => {
  it("is empty for no panes or no space", () => {
    expect(grid(0, wide, 6)).toEqual([]);
    expect(grid(3, zero, 6)).toEqual([]);
  });

  it("fills the window inside the gap with one pane", () => {
    expect(grid(1, wide, 6)).toEqual([{ x: 6, y: 6, width: 1188, height: 788 }]);
  });

  it("grows row shapes balanced", () => {
    const expected: Record<number, number[]> = { 1: [1], 2: [2], 3: [2, 1], 4: [2, 2], 5: [3, 2], 6: [3, 3], 7: [3, 3, 1] };
    for (const [count, rows] of Object.entries(expected)) {
      expect(shape(grid(Number(count), wide, 6)), `count ${count}`).toEqual(rows);
    }
  });

  it("stretches the last row to the full width", () => {
    const laid = grid(3, wide, 6);
    expect(laid[2]!.x).toBe(6);
    expect(maxX(laid[2]!)).toBe(1194);
  });

  it("never overlaps panes and keeps them in bounds", () => {
    for (let count = 1; count <= 12; count++) {
      const laid = grid(count, wide, 6);
      expect(laid.length).toBe(count);
      expect(noOverlapInBounds(laid, wide), `count ${count}`).toBe(true);
    }
  });

  it("stacks tall windows in columns", () => {
    const laid = grid(2, tall, 6);
    expect(laid.every((f) => f.width === 788)).toBe(true);
    expect(maxY(laid[0]!)).toBeLessThan(laid[1]!.y);
  });

  it("finds neighbors by direction", () => {
    // 2x2: 0 1 / 2 3 (y down).
    const laid = grid(4, wide, 6);
    expect(neighbor(0, laid, "right")).toBe(1);
    expect(neighbor(0, laid, "down")).toBe(2);
    expect(neighbor(3, laid, "up")).toBe(1);
    expect(neighbor(3, laid, "left")).toBe(2);
    expect(neighbor(0, laid, "left")).toBeNull();
    expect(neighbor(0, laid, "up")).toBeNull();
    expect(neighbor(9, laid, "up")).toBeNull();
  });
});

describe("LayoutMode", () => {
  it("grid mode matches the balanced grid", () => {
    expect(frames({ count: 5, bounds: wide, gap: 8, mode: "grid" })).toEqual(grid(5, wide, 8));
  });

  it("columns are equal and full height", () => {
    const laid = frames({ count: 3, bounds: wide, gap: 8, mode: "columns" });
    expect(new Set(laid.map((f) => f.width)).size).toBe(1);
    expect(laid.every((f) => f.height === 784)).toBe(true);
    expect(laid.map((f) => f.x)).toEqual(laid.map((f) => f.x).sort((a, b) => a - b));
    expect(noOverlapInBounds(laid, wide)).toBe(true);
  });

  it("columns become rows in tall windows", () => {
    const laid = frames({ count: 3, bounds: tall, gap: 8, mode: "columns" });
    expect(laid.every((f) => f.width === 784)).toBe(true);
    expect(laid.map((f) => f.y)).toEqual(laid.map((f) => f.y).sort((a, b) => a - b));
  });

  it("main + stack puts the first pane big on the left", () => {
    const laid = frames({ count: 4, bounds: wide, gap: 8, mode: "mainStack" });
    const main = laid[0]!;
    expect(main.x).toBe(8);
    expect(main.height).toBe(784);
    expect(Math.abs(main.width - (1200 - 24) * 0.6)).toBeLessThan(0.001);
    // The other three stack in one column to its right, equal heights.
    expect(laid.slice(1).every((f) => f.x === maxX(main) + 8)).toBe(true);
    expect(new Set(laid.slice(1).map((f) => f.height)).size).toBe(1);
    expect(noOverlapInBounds(laid, wide)).toBe(true);
  });

  it("main + stack turns in tall windows and handles one pane", () => {
    const laid = frames({ count: 3, bounds: tall, gap: 8, mode: "mainStack" });
    expect(laid[0]!.y).toBe(8);
    expect(laid[0]!.width).toBe(784);
    expect(laid.slice(1).every((f) => f.y === maxY(laid[0]!) + 8)).toBe(true);
    expect(frames({ count: 1, bounds: wide, gap: 8, mode: "mainStack" })).toEqual([{ x: 8, y: 8, width: 1184, height: 784 }]);
  });

  it("modes cycle and decode", () => {
    expect(layoutModes).toEqual(["grid", "mainStack", "columns"]);
    expect(nextLayout("grid")).toBe("mainStack");
    expect(nextLayout("columns")).toBe("grid");
    expect(layoutFromStored("columns")).toBe("columns");
    expect(layoutFromStored(null)).toBe("grid");
    expect(layoutFromStored(undefined)).toBe("grid");
    expect(layoutFromStored("spiral")).toBe("grid");
    expect(layoutModes.map(layoutTitle)).toEqual(["Grid", "Main + Stack", "Columns"]);
    expect(MAIN_SHARE).toBe(0.6);
  });

  it("hit testing finds the pane under a point", () => {
    const laid = grid(4, wide, 8);
    expect(indexAt({ x: 900, y: 600 }, laid)).toBe(3);
    expect(indexAt({ x: 900, y: 600 }, laid, 3)).toBeNull();
    expect(indexAt({ x: 4, y: 4 }, laid)).toBeNull(); // in the gap
  });
});

/// Contract for resizable panes: balanced by default, a drag moves only the
/// two neighbours of a gap and keeps their sum, a minimum size holds, every
/// mode and tall windows work, a changed pane count goes back to balanced.
describe("Resize", () => {
  const gap = 8;
  const laid = (count: number, mode: LayoutMode, weights: LayoutWeights | null, bounds: Rect = wide): Rect[] =>
    frames({ count, bounds, gap, mode, weights });
  const dragged = (
    kind: SplitterKind,
    delta: number,
    count: number,
    mode: LayoutMode,
    weights: LayoutWeights | null = null,
    bounds: Rect = wide,
  ): LayoutWeights => drag(kind, delta, { count, bounds, gap, mode, weights, minimum: 100 });
  const near = (a: number, b: number, tolerance = 0.01) => expect(Math.abs(a - b)).toBeLessThan(tolerance);
  const cell = (track: number, index: number): SplitterKind => ({ kind: "cell", track, index });
  const track = (index: number): SplitterKind => ({ kind: "track", index });

  it("no weights is the balanced layout", () => {
    for (const mode of layoutModes) {
      for (let count = 1; count <= 8; count++) {
        expect(laid(count, mode, null), `${mode} ${count}`).toEqual(frames({ count, bounds: wide, gap, mode }));
      }
    }
  });

  it("the grid has a divider between rows and between columns in each row", () => {
    const dividers = splitters({ count: 4, bounds: wide, gap, mode: "grid", weights: null });
    const kinds = dividers.map((d) => JSON.stringify(d.kind)).sort();
    expect(kinds).toEqual([cell(0, 0), cell(1, 0), track(0)].map((k) => JSON.stringify(k)).sort());
    const panes = laid(4, "grid", null);
    for (const divider of dividers) {
      const mid = { x: divider.rect.x + divider.rect.width / 2, y: divider.rect.y + divider.rect.height / 2 };
      expect(indexAt(mid, panes)).toBeNull();
    }
  });

  it("dragging a column divider moves only its two panes", () => {
    const before = laid(4, "grid", null);
    const after = laid(4, "grid", dragged(cell(0, 0), 100, 4, "grid"));
    near(after[0]!.width, before[0]!.width + 100);
    near(after[1]!.width, before[1]!.width - 100);
    near(maxX(after[1]!), maxX(before[1]!)); // the pair's outer edge stays
    expect(after[2]).toEqual(before[2]); // the other row is untouched
    expect(after[3]).toEqual(before[3]);
    expect(after[0]!.height).toBe(before[0]!.height);
  });

  it("dragging a row divider moves row heights", () => {
    const before = laid(4, "grid", null);
    const after = laid(4, "grid", dragged(track(0), 50, 4, "grid"));
    near(after[0]!.height, before[0]!.height + 50);
    near(after[2]!.height, before[2]!.height - 50);
    near(maxY(after[2]!), maxY(before[2]!));
  });

  it("drags compound from the current weights", () => {
    const once = dragged(cell(0, 0), 60, 4, "grid");
    const twice = dragged(cell(0, 0), 40, 4, "grid", once);
    const direct = dragged(cell(0, 0), 100, 4, "grid");
    near(laid(4, "grid", twice)[0]!.width, laid(4, "grid", direct)[0]!.width);
  });

  it("a drag does not change the weights it was given", () => {
    const once = dragged(cell(0, 0), 60, 4, "grid");
    const copy = JSON.parse(JSON.stringify(once)) as LayoutWeights;
    dragged(cell(0, 0), 40, 4, "grid", once);
    dragged(track(0), 40, 4, "grid", once);
    expect(once).toEqual(copy);
  });

  it("a pane never goes below the minimum", () => {
    near(laid(4, "grid", dragged(cell(0, 0), 5000, 4, "grid"))[1]!.width, 100);
    near(laid(4, "grid", dragged(cell(0, 0), -5000, 4, "grid"))[0]!.width, 100);
  });

  it("the main + stack divider sets the main share", () => {
    const before = laid(3, "mainStack", null);
    const after = laid(3, "mainStack", dragged(track(0), -120, 3, "mainStack"));
    near(after[0]!.width, before[0]!.width - 120);
    near(after[1]!.width, before[1]!.width + 120);
    near(maxX(after[1]!), maxX(before[1]!));
  });

  it("the stack divider sets stack heights", () => {
    const before = laid(3, "mainStack", null);
    const after = laid(3, "mainStack", dragged(cell(1, 0), 80, 3, "mainStack"));
    near(after[1]!.height, before[1]!.height + 80);
    near(after[2]!.height, before[2]!.height - 80);
    expect(after[0]).toEqual(before[0]);
  });

  it("columns in a tall window resize vertically", () => {
    const before = laid(3, "columns", null, tall);
    const weights = dragged(cell(0, 1), 70, 3, "columns", null, tall);
    const after = laid(3, "columns", weights, tall);
    near(after[1]!.height, before[1]!.height + 70);
    near(after[2]!.height, before[2]!.height - 70);
    expect(after[0]).toEqual(before[0]);
    const dividers = splitters({ count: 3, bounds: tall, gap, mode: "columns", weights: null });
    // Rows in a tall window: horizontal dividers.
    expect(dividers.every((d) => d.rect.width > d.rect.height)).toBe(true);
  });

  it("a different pane count goes back to balanced", () => {
    const weights = dragged(cell(0, 0), 100, 4, "grid");
    expect(laid(5, "grid", weights)).toEqual(laid(5, "grid", null));
    expect(laid(4, "columns", weights)).toEqual(laid(4, "columns", null)); // a different mode too
  });

  it("dividers stay grabbable with no gap", () => {
    const dividers = splitters({ count: 2, bounds: wide, gap: 0, mode: "columns", weights: null });
    expect(dividers.length).toBe(1);
    expect(dividers[0]!.rect.width).toBeGreaterThanOrEqual(6);
  });

  it("ignores a drag on a divider that does not exist", () => {
    for (const kind of [track(1), track(-1), cell(0, 1), cell(5, 0), cell(0, -1)]) {
      expect(dragged(kind, 50, 4, "grid"), JSON.stringify(kind)).toEqual({ tracks: [1, 1], cells: [[1, 1], [1, 1]] });
    }
  });
});

/// Contract for Rotate Layout: a window's shape picks the split (side by
/// side when wide, stacked when tall); rotating turns that choice for every
/// mode. Dividers and dragging follow the rotated split.
describe("Rotate layout", () => {
  it("stacks two panes in a rotated wide window", () => {
    const laid = frames({ count: 2, bounds: wide, gap: 6, mode: "grid", weights: null, rotated: true });
    expect(laid.length).toBe(2);
    expect([laid[0]!.x, maxX(laid[0]!)]).toEqual([6, 1194]); // full width
    expect([laid[1]!.x, maxX(laid[1]!)]).toEqual([6, 1194]);
    expect(maxY(laid[0]!)).toBeLessThan(laid[1]!.y); // first on top
  });

  it("puts two panes side by side in a rotated tall window", () => {
    const laid = frames({ count: 2, bounds: tall, gap: 6, mode: "grid", weights: null, rotated: true });
    expect([laid[0]!.y, maxY(laid[0]!)]).toEqual([6, 1194]); // full height
    expect(maxX(laid[0]!)).toBeLessThan(laid[1]!.x); // first on the left
  });

  it("turns every mode", () => {
    const main = frames({ count: 3, bounds: wide, gap: 6, mode: "mainStack", weights: null, rotated: true });
    expect([main[0]!.x, maxX(main[0]!), main[0]!.y]).toEqual([6, 1194, 6]); // the main pane across the top
    const rows = frames({ count: 3, bounds: wide, gap: 6, mode: "columns", weights: null, rotated: true });
    expect([...new Set(rows.map((f) => f.width))]).toEqual([1188]); // columns become full-width rows
    expect(maxY(rows[0]!) < rows[1]!.y && maxY(rows[1]!) < rows[2]!.y).toBe(true);
  });

  it("is unchanged when not rotated", () => {
    for (const mode of layoutModes) {
      for (let count = 1; count <= 7; count++) {
        for (const bounds of [wide, tall]) {
          expect(frames({ count, bounds, gap: 6, mode, weights: null, rotated: false })).toEqual(
            frames({ count, bounds, gap: 6, mode, weights: null }),
          );
        }
      }
    }
  });

  it("runs the divider across a rotated split", () => {
    const found = splitters({ count: 2, bounds: wide, gap: 6, mode: "grid", weights: null, rotated: true });
    expect(found.length).toBe(1);
    const divider = found[0]!;
    expect(divider.rect.width).toBeGreaterThan(divider.rect.height); // horizontal, between stacked panes
    expect([divider.rect.x, maxX(divider.rect)]).toEqual([6, 1194]); // across the panes
    const tallDivider = splitters({
      count: 2,
      bounds: { x: 0, y: 0, width: 1200, height: 1300 },
      gap: 6,
      mode: "grid",
      weights: null,
    })[0]!;
    expect(tallDivider.rect.x).toBe(divider.rect.x);
    expect(tallDivider.rect.width).toBe(divider.rect.width);
  });

  it("moves the divider by exactly the drag", () => {
    const opts = { count: 2, bounds: wide, gap: 6, mode: "grid" as const, weights: null, rotated: true };
    const before = frames(opts);
    const divider = splitters(opts)[0]!;
    const weights = drag(divider.kind, 100, { ...opts, minimum: 80 });
    const after = frames({ ...opts, weights });
    expect(Math.abs(after[0]!.height - (before[0]!.height + 100))).toBeLessThan(0.001);
    expect(Math.abs(after[1]!.height - (before[1]!.height - 100))).toBeLessThan(0.001);
  });
});

/// Contract for moving panes between rows of the grid: two panes trade
/// places, except where the rows differ in shape: then a pane moving into a
/// row with a different number of panes takes its whole row with it.
describe("Row moves", () => {
  const laidOut = (m: Rearrangement, count: number, bounds: Rect = wide): Rect[] =>
    frames({ count, bounds, gap: 6, mode: "grid", weights: m.weights, rows: m.rows });

  it("moves the long bottom pane up with its row", () => {
    // 2 on top (0, 1), the long one below (2). Move 2 up onto 0.
    const m = move(2, 0, { count: 3, mode: "grid", rows: null, weights: null });
    expect(m.order).toEqual([2, 0, 1]); // the long pane first, the other two keep their order
    expect(m.rows).toEqual([1, 2]);
    const laid = laidOut(m, 3);
    expect(shape(laid)).toEqual([1, 2]);
    expect([laid[0]!.y, laid[0]!.x, maxX(laid[0]!)]).toEqual([6, 6, 1194]); // the long pane spans the top
  });

  it("moves the rows too when a top pane moves down onto the long one", () => {
    const m = move(0, 2, { count: 3, mode: "grid", rows: null, weights: null });
    expect(m.order).toEqual([2, 0, 1]);
    expect(m.rows).toEqual([1, 2]);
  });

  it("keeps a row's height when it moves", () => {
    // The long bottom row dragged thin.
    const thin: LayoutWeights = { tracks: [1, 0.4], cells: [[1, 1], [1]] };
    const before = frames({ count: 3, bounds: wide, gap: 6, mode: "grid", weights: thin });
    const m = move(2, 1, { count: 3, mode: "grid", rows: null, weights: thin });
    const after = laidOut(m, 3);
    const long = m.order.indexOf(2);
    expect(long).toBeGreaterThanOrEqual(0);
    expect(Math.abs(after[long]!.height - before[2]!.height)).toBeLessThan(0.001);
    expect(after[long]!.width).toBe(before[2]!.width);
    expect(after[long]!.y).toBe(6);
    expect(m.weights).toEqual({ tracks: [0.4, 1], cells: [[1], [1, 1]] });
  });

  it("just swaps panes in rows of the same shape", () => {
    const m = move(0, 2, { count: 4, mode: "grid", rows: null, weights: null });
    expect(m.order).toEqual([2, 1, 0, 3]);
    expect(m.rows).toBeNull();
    expect(m.displaced).toEqual([2]);
  });

  it("just swaps panes in the same row", () => {
    const weights: LayoutWeights = { tracks: [1, 1], cells: [[2, 1], [1]] };
    const m = move(0, 1, { count: 3, mode: "grid", rows: null, weights });
    expect(m.order).toEqual([1, 0, 2]);
    expect(m.rows).toBeNull();
    expect(m.weights).toEqual(weights); // cells keep their sizes; the panes trade places
  });

  it("lets the short row travel through the middle", () => {
    // 7 panes: 3, 3, 1. Move the lone pane up onto the middle row, then the top.
    const middle = move(6, 3, { count: 7, mode: "grid", rows: null, weights: null });
    expect(middle.order).toEqual([0, 1, 2, 6, 3, 4, 5]);
    expect(middle.rows).toEqual([3, 1, 3]);
    expect(shape(laidOut(middle, 7))).toEqual([3, 1, 3]);
    const top = move(3, 0, { count: 7, mode: "grid", rows: middle.rows, weights: null });
    expect(top.order).toEqual([3, 0, 1, 2, 4, 5, 6]);
    expect(top.rows).toEqual([1, 3, 3]);
  });

  it("displaces the whole target row in a row move", () => {
    const m = move(2, 1, { count: 3, mode: "grid", rows: null, weights: null });
    expect([...m.displaced].sort()).toEqual([0, 1]);
  });

  it("restores the balanced shape when moving back", () => {
    const up = move(2, 0, { count: 3, mode: "grid", rows: null, weights: null });
    const down = move(0, 1, { count: 3, mode: "grid", rows: up.rows, weights: up.weights });
    expect(down.rows).toBeNull(); // short row last again: the balanced shape
    expect(down.order).toEqual([1, 2, 0]);
  });

  it("keeps the main pane in main + stack", () => {
    const m = move(2, 0, { count: 3, mode: "mainStack", rows: null, weights: null });
    expect(m.order).toEqual([2, 1, 0]);
    expect(m.rows).toBeNull();
  });

  it("does nothing for a pane onto itself or out of range", () => {
    for (const [from, to] of [[1, 1], [-1, 0], [0, 3]] as const) {
      const m = move(from, to, { count: 3, mode: "grid", rows: [1, 2], weights: null });
      expect(m).toEqual({ order: [0, 1, 2], rows: [1, 2], weights: null, displaced: [] });
    }
  });

  it("treats rows as columns in a tall window", () => {
    const m = move(2, 0, { count: 3, mode: "grid", rows: null, weights: null });
    const laid = laidOut(m, 3, tall);
    expect([laid[0]!.x, laid[0]!.y, maxY(laid[0]!)]).toEqual([6, 6, 1194]); // the long pane spans the left column
  });

  it("ignores a shape that does not fit", () => {
    const balanced = frames({ count: 3, bounds: wide, gap: 6, mode: "grid", weights: null });
    for (const rows of [[1, 1, 1], [3], [2, 2], [0, 3], [1, 2, 0]]) {
      expect(frames({ count: 3, bounds: wide, gap: 6, mode: "grid", weights: null, rows }), `${rows}`).toEqual(balanced);
    }
    const columns = frames({ count: 3, bounds: wide, gap: 6, mode: "columns", weights: null });
    expect(frames({ count: 3, bounds: wide, gap: 6, mode: "columns", weights: null, rows: [1, 2] })).toEqual(columns);
  });

  it("dividers and attention follow the moved rows", () => {
    const rows = [1, 2];
    const found = splitters({ count: 3, bounds: wide, gap: 6, mode: "grid", weights: null, rows });
    const has = (k: SplitterKind) => found.some((s) => JSON.stringify(s.kind) === JSON.stringify(k));
    expect(has({ kind: "cell", track: 1, index: 0 })).toBe(true);
    expect(has({ kind: "cell", track: 0, index: 0 })).toBe(false);
    expect(attentionWeights(["active", "idle", "idle"], "grid", rows)?.cells.map((c) => c.length)).toEqual([1, 2]);
    expect(structure(3, "grid", rows).cellCounts).toEqual([1, 2]);
    expect(structure(3, "grid").cellCounts).toEqual([2, 1]);
  });
});
