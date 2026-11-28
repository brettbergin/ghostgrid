// Where each pane goes in a balanced grid. A port of GhostGridCore's
// GridLayout.swift; the numbers match the macOS app's exactly.
//
// Panes fill row by row. The grid has ceil(sqrt(n)) columns, so it grows
// 1, 1x2, 2+1, 2x2, 3+2, 3x2, ... and the last row's panes stretch to fill
// it. In a window taller than it is wide the grid is transposed, so panes
// stack in columns instead.
//
// The UI calls these every animation frame, so they allocate little and
// never touch the DOM.
import { contains, midX, midY, transposed, type Point, type Rect } from "./geometry";

/// How a window arranges its panes.
/// - grid: balanced rows, ceil(sqrt(n)) columns (the default).
/// - mainStack: the first pane large on the left (top in a tall window),
///   the rest stacked beside it.
/// - columns: equal columns side by side (rows in a tall window).
export type LayoutMode = "grid" | "mainStack" | "columns";

/// Every mode, in the order Cycle Layout walks them.
export const layoutModes: readonly LayoutMode[] = ["grid", "mainStack", "columns"];

export function layoutTitle(mode: LayoutMode): string {
  switch (mode) {
    case "grid":
      return "Grid";
    case "mainStack":
      return "Main + Stack";
    case "columns":
      return "Columns";
  }
}

/// The next mode, for cycling.
export function nextLayout(mode: LayoutMode): LayoutMode {
  return layoutModes[(layoutModes.indexOf(mode) + 1) % layoutModes.length]!;
}

/// The stored value, or grid for anything unknown (an old or hand-edited
/// session must still open).
export function layoutFromStored(stored?: string | null): LayoutMode {
  return (layoutModes as readonly string[]).includes(stored ?? "") ? (stored as LayoutMode) : "grid";
}

/// The main pane's share of the width (or height) in mainStack.
export const MAIN_SHARE = 0.6;

/// Divider adjustments for one window: a weight per track (grid row, or
/// the main and stack sides of Main + Stack) and per cell of each track.
/// Saved in the session; ignored when they do not fit the window's pane
/// count and mode, which is how adding or removing a pane rebalances.
export interface LayoutWeights {
  tracks: number[];
  cells: number[][];
}

/// Which divider: between tracks `index` and `index + 1`, or between cells
/// `index` and `index + 1` of track `track`.
export type SplitterKind = { kind: "track"; index: number } | { kind: "cell"; track: number; index: number };

/// A draggable divider between two panes, and the rect to grab it by.
export interface Splitter {
  kind: SplitterKind;
  rect: Rect;
}

export type Direction = "left" | "right" | "up" | "down";

export interface LayoutOptions {
  count: number;
  bounds: Rect;
  gap: number;
  mode: LayoutMode;
  /// nil, or weights made for another pane count or mode: balanced.
  weights?: LayoutWeights | null;
  /// The grid's panes per row, top to bottom, after rows were moved (see
  /// `move`); null, or a shape that does not fit: the balanced one, short
  /// row last.
  rows?: readonly number[] | null;
  /// Rotate Layout: the split the window's shape would pick, turned
  /// (stacked in a wide window, side by side in a tall one).
  rotated?: boolean;
}

/// Frames for `count` panes, with the divider adjustments in `weights`.
export function frames(opts: LayoutOptions): Rect[] {
  const { count, bounds, gap, mode } = opts;
  if (!(count > 0) || !(bounds.width > 0) || !(bounds.height > 0)) return [];
  const s = new Structure(count, mode, opts.rows);
  const { tracks, cells } = s.resolve(opts.weights);
  if (!isTall(bounds, opts.rotated ?? false)) return s.frames(bounds, gap, tracks, cells);
  return s.frames(transposed(bounds), gap, tracks, cells).map(transposed);
}

/// The draggable dividers between panes: between tracks (grid rows, the
/// main/stack split) and between cells of a track. Each rect covers the
/// gap, at least `minimumThickness` wide so it can be grabbed with no gap.
export function splitters(opts: LayoutOptions & { minimumThickness?: number }): Splitter[] {
  const { count, bounds, gap, mode } = opts;
  if (!(count > 1) || !(bounds.width > 0) || !(bounds.height > 0)) return [];
  const s = new Structure(count, mode, opts.rows);
  const { tracks, cells } = s.resolve(opts.weights);
  const tall = isTall(bounds, opts.rotated ?? false);
  const space = tall ? transposed(bounds) : bounds;
  const found = s.splitters(space, gap, tracks, cells, Math.max(gap, opts.minimumThickness ?? 8));
  return tall ? found.map((d) => ({ kind: d.kind, rect: transposed(d.rect) })) : found;
}

/// Weights after dragging the divider `kind` by `delta` pixels across
/// itself (x for a vertical divider, y for a horizontal one). Only the two
/// neighbours change, their sum stays, and neither gets smaller than
/// `minimum` pixels. The weights passed in are not changed.
export function drag(kind: SplitterKind, delta: number, opts: LayoutOptions & { minimum: number }): LayoutWeights {
  const { count, bounds, gap, mode, minimum } = opts;
  const s = new Structure(count, mode, opts.rows);
  const { tracks, cells } = s.resolve(opts.weights);
  const space = isTall(bounds, opts.rotated ?? false) ? transposed(bounds) : bounds;
  if (kind.kind === "track") {
    const i = kind.index;
    if (isIndex(i, tracks.length) && isIndex(i + 1, tracks.length)) {
      const sizes = distribute(s.trackExtent(space) - gap * (tracks.length + 1), tracks);
      [tracks[i], tracks[i + 1]] = shifted(tracks[i]!, tracks[i + 1]!, sizes[i]!, sizes[i + 1]!, delta, minimum);
    }
  } else {
    const row = cells[kind.track];
    const i = kind.index;
    if (isIndex(kind.track, cells.length) && row && isIndex(i, row.length) && isIndex(i + 1, row.length)) {
      const sizes = distribute(s.cellExtent(space) - gap * (row.length + 1), row);
      [row[i], row[i + 1]] = shifted(row[i]!, row[i + 1]!, sizes[i]!, sizes[i + 1]!, delta, minimum);
    }
  }
  return { tracks, cells };
}

/// What moving one pane onto another does to a window's layout.
export interface Rearrangement {
  /// The new grid order, as indices into the old one.
  order: number[];
  /// The grid's panes per row after the move (null: balanced).
  rows: number[] | null;
  weights: LayoutWeights | null;
  /// The panes (old indices) that make way: the target pane, or its whole
  /// row when rows trade places. For the drop highlight.
  displaced: number[];
}

/// Moving the pane at `from` onto the pane at `to` (a Swap command or a
/// drop). In the grid, a pane moving into a row with a different number of
/// panes takes its row with it: the two rows trade places, sizes and all,
/// so a long pane stays long. Otherwise the two panes trade places and the
/// layout keeps its shape.
export function move(
  from: number,
  to: number,
  opts: { count: number; mode: LayoutMode; rows?: readonly number[] | null; weights?: LayoutWeights | null },
): Rearrangement {
  const { count, mode } = opts;
  const order = range(0, count);
  const rows = opts.rows ? [...opts.rows] : null;
  const weights = opts.weights ? cloneWeights(opts.weights) : null;
  if (!isIndex(from, count) || !isIndex(to, count) || from === to) {
    return { order, rows, weights, displaced: [] };
  }
  const s = new Structure(count, mode, opts.rows);
  const counts = s.cellCounts;
  const starts: number[] = [];
  let sum = 0;
  for (const n of counts) {
    starts.push(sum);
    sum += n;
  }
  const trackOf = (pane: number): number => {
    for (let t = starts.length - 1; t >= 0; t--) if (starts[t]! <= pane) return t;
    return 0;
  };
  const source = trackOf(from);
  const target = trackOf(to);
  if (mode !== "grid" || source === target || counts[source] === counts[target]) {
    [order[from], order[to]] = [order[to]!, order[from]!];
    return { order, rows, weights, displaced: [to] };
  }
  // The two rows trade places, each with its panes and its sizes.
  const tracks = range(0, counts.length);
  [tracks[source], tracks[target]] = [target, source];
  const moved = tracks.map((t) => counts[t]!);
  const resolved = s.resolve(opts.weights);
  return {
    order: tracks.flatMap((t) => range(starts[t]!, starts[t]! + counts[t]!)),
    rows: sameNumbers(moved, new Structure(count, mode).cellCounts) ? null : moved,
    weights: weights === null ? null : { tracks: tracks.map((t) => resolved.tracks[t]!), cells: tracks.map((t) => resolved.cells[t]!) },
    displaced: range(starts[target]!, starts[target]! + counts[target]!),
  };
}

/// The pane under `point`, if any (for dropping a dragged pane).
export function indexAt(point: Point, laid: readonly Rect[], excluding?: number | null): number | null {
  for (let i = 0; i < laid.length; i++) if (i !== excluding && contains(laid[i]!, point)) return i;
  return null;
}

/// The pane nearest to `from` in `direction`, or null at the edge. Frames
/// use top-left coordinates (y grows downward).
export function neighbor(from: number, laid: readonly Rect[], direction: Direction): number | null {
  const origin = laid[from];
  if (!isIndex(from, laid.length) || !origin) return null;
  const sx = midX(origin);
  const sy = midY(origin);
  let best: number | null = null;
  let bestScore = 0;
  for (let i = 0; i < laid.length; i++) {
    if (i === from) continue;
    const dx = midX(laid[i]!) - sx;
    const dy = midY(laid[i]!) - sy;
    let ahead: number;
    let across: number;
    switch (direction) {
      case "left":
        [ahead, across] = [-dx, dy];
        break;
      case "right":
        [ahead, across] = [dx, dy];
        break;
      case "up":
        [ahead, across] = [-dy, dx];
        break;
      case "down":
        [ahead, across] = [dy, dx];
        break;
    }
    if (!(ahead > 1)) continue;
    // Prefer panes straight ahead over ones off to the side.
    const score = ahead + Math.abs(across) * 2;
    if (best === null || score < bestScore) {
      best = i;
      bestScore = score;
    }
  }
  return best;
}

/// The tracks-of-cells shape of `count` panes in `mode` (see Structure).
/// The attention grid builds its weights from it.
export function structure(count: number, mode: LayoutMode, rows?: readonly number[] | null): Structure {
  return new Structure(count, mode, rows);
}

/// Every mode as tracks of cells, in a wide space. Tracks run along y
/// (grid rows, the single columns track) or along x (main | stack); cells
/// run along the other axis. Panes are numbered track by track.
export class Structure {
  readonly tracksAlongY: boolean;
  readonly cellCounts: readonly number[];
  readonly defaultTracks: readonly number[];

  constructor(count: number, mode: LayoutMode, moved?: readonly number[] | null) {
    if (!(count > 0)) {
      // Nothing to lay out (the Swift never builds one; frames guards).
      this.tracksAlongY = true;
      this.cellCounts = [];
      this.defaultTracks = [];
    } else if (mode === "mainStack" && count > 1) {
      this.tracksAlongY = false;
      this.cellCounts = [1, count - 1];
      this.defaultTracks = [MAIN_SHARE, 1 - MAIN_SHARE];
    } else if (mode === "columns") {
      this.tracksAlongY = true;
      this.cellCounts = [count];
      this.defaultTracks = [1];
    } else {
      // grid, and mainStack with one pane.
      const columns = Math.ceil(Math.sqrt(count));
      const rows = Math.floor((count + columns - 1) / columns);
      const counts = range(0, rows).map((r) => (r === rows - 1 ? count - columns * (rows - 1) : columns));
      this.tracksAlongY = true;
      // Rows moved with move(): the same rows, reordered.
      const fits = mode === "grid" && moved && sameNumbers(sorted(moved), sorted(counts));
      this.cellCounts = fits ? [...moved] : counts;
      this.defaultTracks = new Array<number>(rows).fill(1);
    }
  }

  /// `weights` when they fit this structure, else the balanced defaults.
  /// Always fresh arrays, so callers may change them.
  resolve(weights?: LayoutWeights | null): { tracks: number[]; cells: number[][] } {
    const counts = this.cellCounts;
    const fits =
      weights &&
      weights.tracks.length === counts.length &&
      weights.cells.length === counts.length &&
      weights.cells.every((c, i) => c.length === counts[i]) &&
      weights.tracks.every(positive) &&
      weights.cells.every((c) => c.every(positive));
    if (fits) return cloneWeights(weights);
    return { tracks: [...this.defaultTracks], cells: counts.map((n) => new Array<number>(n).fill(1)) };
  }

  trackExtent(space: Rect): number {
    return this.tracksAlongY ? space.height : space.width;
  }

  cellExtent(space: Rect): number {
    return this.tracksAlongY ? space.width : space.height;
  }

  /// Track spans (start, size) along the track axis, and cell spans along
  /// the other axis for each track. Flat [start, size, start, size, ...].
  private spans(space: Rect, gap: number, tracks: number[], cells: number[][]): { tracks: number[]; cells: number[][] } {
    const lay = (start: number, extent: number, weights: number[]): number[] => {
      const sizes = distribute(extent - gap * (weights.length + 1), weights);
      const out: number[] = [];
      let position = start + gap;
      for (const size of sizes) {
        out.push(position, size);
        position += size + gap;
      }
      return out;
    };
    const trackStart = this.tracksAlongY ? space.y : space.x;
    const cellStart = this.tracksAlongY ? space.x : space.y;
    return {
      tracks: lay(trackStart, this.trackExtent(space), tracks),
      cells: cells.map((c) => lay(cellStart, this.cellExtent(space), c)),
    };
  }

  frames(space: Rect, gap: number, tracks: number[], cells: number[][]): Rect[] {
    const laid = this.spans(space, gap, tracks, cells);
    const out: Rect[] = [];
    for (let t = 0; t * 2 < laid.tracks.length; t++) {
      const trackPosition = laid.tracks[t * 2]!;
      const trackSize = laid.tracks[t * 2 + 1]!;
      const row = laid.cells[t]!;
      for (let c = 0; c < row.length; c += 2) {
        const cellPosition = row[c]!;
        const cellSize = row[c + 1]!;
        out.push(
          this.tracksAlongY
            ? { x: cellPosition, y: trackPosition, width: cellSize, height: trackSize }
            : { x: trackPosition, y: cellPosition, width: trackSize, height: cellSize },
        );
      }
    }
    return out;
  }

  splitters(space: Rect, gap: number, tracks: number[], cells: number[][], thickness: number): Splitter[] {
    const laid = this.spans(space, gap, tracks, cells);
    // A strip centred on the gap after `end`, `thickness` thick.
    const across = (end: number): number => end + gap / 2 - thickness / 2;
    const result: Splitter[] = [];
    const trackCount = laid.tracks.length / 2;
    const crossStart = this.tracksAlongY ? space.x : space.y;
    const crossExtent = this.cellExtent(space);
    for (let t = 0; t < trackCount - 1; t++) {
      const start = across(laid.tracks[t * 2]! + laid.tracks[t * 2 + 1]!);
      result.push({
        kind: { kind: "track", index: t },
        rect: this.tracksAlongY
          ? { x: crossStart, y: start, width: crossExtent, height: thickness }
          : { x: start, y: crossStart, width: thickness, height: crossExtent },
      });
    }
    for (let t = 0; t < trackCount; t++) {
      const trackPosition = laid.tracks[t * 2]!;
      const trackSize = laid.tracks[t * 2 + 1]!;
      const row = laid.cells[t]!;
      for (let c = 0; c < row.length / 2 - 1; c++) {
        const start = across(row[c * 2]! + row[c * 2 + 1]!);
        result.push({
          kind: { kind: "cell", track: t, index: c },
          rect: this.tracksAlongY
            ? { x: start, y: trackPosition, width: thickness, height: trackSize }
            : { x: trackPosition, y: start, width: trackSize, height: thickness },
        });
      }
    }
    return result;
  }
}

/// `extent` shared out by `weights`.
function distribute(extent: number, weights: readonly number[]): number[] {
  let sum = 0;
  for (const w of weights) sum += w;
  if (!(sum > 0)) return weights.map(() => 0);
  return weights.map((w) => Math.max(extent * (w / sum), 0));
}

/// Two neighbouring weights after moving their shared edge by `delta`.
function shifted(wa: number, wb: number, a: number, b: number, delta: number, minimum: number): [number, number] {
  const total = a + b;
  if (!(total > 0)) return [wa, wb];
  const low = Math.min(minimum, total / 2);
  const newA = Math.min(Math.max(a + delta, low), total - low);
  const weightSum = wa + wb;
  const newWA = weightSum * (newA / total);
  return [newWA, weightSum - newWA];
}

/// Whether to lay out as in a tall window: a tall window, unless rotated
/// (Rotate Layout turns the split the shape would pick).
function isTall(bounds: Rect, rotated: boolean): boolean {
  return bounds.height > bounds.width !== rotated;
}

function isIndex(i: number, length: number): boolean {
  return Number.isInteger(i) && i >= 0 && i < length;
}

function positive(w: number): boolean {
  return Number.isFinite(w) && w > 0;
}

function range(start: number, end: number): number[] {
  const out: number[] = [];
  for (let i = start; i < end; i++) out.push(i);
  return out;
}

function sorted(xs: readonly number[]): number[] {
  return [...xs].sort((a, b) => a - b);
}

function sameNumbers(a: readonly number[], b: readonly number[]): boolean {
  return a.length === b.length && a.every((x, i) => x === b[i]);
}

function cloneWeights(w: LayoutWeights): LayoutWeights {
  return { tracks: [...w.tracks], cells: w.cells.map((c) => [...c]) };
}
