import type { Rect } from "../src/core/geometry";

/// Swift's stride(from:through:by:) for the sampled curve tests: computed by
/// multiplication so the last sample lands on `through` exactly.
export function stride(from: number, through: number, by: number): number[] {
  const steps = Math.round((through - from) / by);
  return Array.from({ length: steps + 1 }, (_, i) => from + i * by);
}

/// Panes per row, top to bottom (rows grouped by their top edge).
export function shape(frames: Rect[]): number[] {
  const rows = new Map<number, number>();
  for (const f of frames) rows.set(f.y, (rows.get(f.y) ?? 0) + 1);
  return [...rows.entries()].sort((a, b) => a[0] - b[0]).map(([, n]) => n);
}

/// CGRect.contains(CGRect): `inner` lies entirely within `outer`.
export function rectContainsRect(outer: Rect, inner: Rect): boolean {
  return (
    inner.x >= outer.x &&
    inner.y >= outer.y &&
    inner.x + inner.width <= outer.x + outer.width &&
    inner.y + inner.height <= outer.y + outer.height
  );
}

/// CGRect.intersects: the two share some area.
export function intersects(a: Rect, b: Rect): boolean {
  return a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height;
}

export const maxX = (r: Rect): number => r.x + r.width;
export const maxY = (r: Rect): number => r.y + r.height;
