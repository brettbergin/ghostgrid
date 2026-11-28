// The attention grid: panes that need you or just printed grow, panes quiet
// for a while shrink, by way of the same divider weights a drag sets. A
// port of GhostGridCore's Attention.swift.
import { structure, type LayoutMode, type LayoutWeights } from "./gridLayout";

/// How much a pane wants your eyes.
/// - idle: nothing printed for a while; it gives up some room.
/// - quiet: printed recently, not right now.
/// - active: printing right now, or the pane you are in.
/// - wanted: waiting for you: a bell, a notification, a command that
///   finished while you looked elsewhere (an agent asking for input).
export type AttentionLevel = "idle" | "quiet" | "active" | "wanted";

/// The levels from least to most wanted.
export const attentionLevels: readonly AttentionLevel[] = ["idle", "quiet", "active", "wanted"];

/// Relative size. Kept close to 1 so the grid moves gently.
export const ATTENTION_WEIGHT: Readonly<Record<AttentionLevel, number>> = {
  idle: 0.7,
  quiet: 1,
  active: 1.35,
  wanted: 1.7,
};

/// Negative when `a` wants less attention than `b`, 0 when equal.
export function compareAttention(a: AttentionLevel, b: AttentionLevel): number {
  return attentionLevels.indexOf(a) - attentionLevels.indexOf(b);
}

/// Output this recent makes a pane active.
export const FRESH_SECONDS = 4;
/// No output for this long makes a pane idle.
export const IDLE_AFTER_SECONDS = 90;

/// A pane's level. Times are epoch milliseconds (Date.now()), as the UI
/// has them; the thresholds are in seconds like the Swift's.
export function attentionLevel(pane: {
  lastOutput: number | null;
  waiting: boolean;
  focused: boolean;
  now: number;
}): AttentionLevel {
  // The pane you are in never shrinks, and is not "waiting" for you: you
  // are already there.
  if (pane.focused) return "active";
  if (pane.waiting) return "wanted";
  if (pane.lastOutput === null) return "idle";
  const age = (pane.now - pane.lastOutput) / 1000;
  if (age <= FRESH_SECONDS) return "active";
  return age < IDLE_AFTER_SECONDS ? "quiet" : "idle";
}

/// Weights for panes at `levels` (grid order), or null when none stands
/// out: the balanced layout. A track (row, or main/stack) is as large as
/// its most wanted pane; within a track each pane gets its own.
export function attentionWeights(
  levels: readonly AttentionLevel[],
  mode: LayoutMode,
  rows?: readonly number[] | null,
): LayoutWeights | null {
  const first = levels[0];
  if (first === undefined || levels.every((l) => l === first)) return null;
  const s = structure(levels.length, mode, rows);
  const cells: number[][] = [];
  let index = 0;
  for (const count of s.cellCounts) {
    cells.push(levels.slice(index, index + count).map((l) => ATTENTION_WEIGHT[l]));
    index += count;
  }
  const tracks = s.defaultTracks.map((d, i) => {
    const c = cells[i]!;
    return d * (c.length > 0 ? Math.max(...c) : 1);
  });
  return { tracks, cells };
}
