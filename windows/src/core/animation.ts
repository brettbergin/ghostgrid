// How the grid animates, and how a pane's content is scaled while its box
// changes size. Ports of GhostGridCore's AnimationStyle.swift and
// ContentScale.swift.
import type { Size } from "./geometry";

/// A CSS/Core Animation style cubic Bezier timing curve from (0,0) to
/// (1,1). `progress(t)` maps elapsed time (0...1) to animation progress,
/// which may leave 0...1 when a control point does (an overshooting
/// spring). CSS can run such a curve itself, but the content scale needs
/// the value per frame, so it is computed here.
export class CubicBezier {
  constructor(
    readonly x1: number,
    readonly y1: number,
    readonly x2: number,
    readonly y2: number,
  ) {}

  progress(time: number): number {
    const x = Number.isNaN(time) ? 0 : Math.min(Math.max(time, 0), 1);
    if (x === 0 || x === 1) return x;
    // Solve bezierX(t) = x for t (x is monotonic for x1, x2 in 0...1),
    // Newton first, bisection as the fallback.
    let t = x;
    for (let i = 0; i < 8; i++) {
      const error = bezier(t, this.x1, this.x2) - x;
      if (Math.abs(error) < 1e-7) return bezier(t, this.y1, this.y2);
      const d = slope(t, this.x1, this.x2);
      if (Math.abs(d) < 1e-6) break;
      t -= error / d;
    }
    let low = 0;
    let high = 1;
    t = x;
    for (let i = 0; i < 50; i++) {
      const value = bezier(t, this.x1, this.x2);
      if (Math.abs(value - x) < 1e-7) break;
      if (value < x) low = t;
      else high = t;
      t = (low + high) / 2;
    }
    return bezier(t, this.y1, this.y2);
  }
}

function bezier(t: number, a: number, b: number): number {
  const u = 1 - t;
  return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t;
}

function slope(t: number, a: number, b: number): number {
  const u = 1 - t;
  return 3 * u * u * a + 6 * u * t * (b - a) + 3 * t * t * (1 - b);
}

/// How the grid animates when panes are added, closed, zoomed or
/// rebalanced.
/// - springy: a quick spring that overshoots a little and settles (the
///   default).
/// - smooth: fast start, soft landing, no overshoot.
/// - off: panes jump straight to their new places.
export type AnimationStyle = "springy" | "smooth" | "off";

export const animationStyles: readonly AnimationStyle[] = ["springy", "smooth", "off"];

export function animationTitle(style: AnimationStyle): string {
  switch (style) {
    case "springy":
      return "Springy";
    case "smooth":
      return "Smooth";
    case "off":
      return "Off";
  }
}

// Shared instances: the UI asks for the curve every frame.
const SPRINGY = new CubicBezier(0.32, 1.42, 0.6, 1);
const SMOOTH = new CubicBezier(0.2, 0.9, 0.25, 1);

/// The timing curve for grid changes; null when animations are off.
export function animationCurve(style: AnimationStyle): CubicBezier | null {
  switch (style) {
    case "springy":
      return SPRINGY;
    case "smooth":
      return SMOOTH;
    case "off":
      return null;
  }
}

/// Seconds for a grid change; 0 when animations are off.
export function animationDuration(style: AnimationStyle): number {
  switch (style) {
    case "springy":
      return 0.46;
    case "smooth":
      return 0.3;
    case "off":
      return 0;
  }
}

/// The stored value, or the default for anything unknown.
export function animationFromStored(stored?: string | null): AnimationStyle {
  return (animationStyles as readonly string[]).includes(stored ?? "") ? (stored as AnimationStyle) : "springy";
}

/// The space between panes and around the grid, in pixels.
export const PANE_GAP = { min: 0, max: 24, standard: 8 } as const;

/// A stored value clamped into range; the default when unset or not a
/// finite number (a hand-edited config must not break the layout).
export function clampedGap(stored?: number | null): number {
  if (stored === null || stored === undefined || !Number.isFinite(stored)) return PANE_GAP.standard;
  return Math.min(Math.max(stored, PANE_GAP.min), PANE_GAP.max);
}

/// The uniform scale that makes content laid out at `next` size cover a
/// box that is `progress` of the way from `old` to `next`: the larger of
/// the two axis ratios, so the content never stretches and never leaves a
/// gap. The terminal is laid out once at its final size and scaled, rather
/// than reflowed every frame.
export function coverScale(old: Size, next: Size, progress: number): number {
  if (!(next.width > 0) || !(next.height > 0)) return 1;
  const width = old.width + (next.width - old.width) * progress;
  const height = old.height + (next.height - old.height) * progress;
  return Math.max(width / next.width, height / next.height);
}

/// `count` evenly timed samples of the cover scale along `curve`, for a
/// keyframe animation that ends exactly at 1.
export function coverKeyframes(old: Size, next: Size, curve: CubicBezier, count = 40): number[] {
  const steps = Math.max(count, 2);
  const out: number[] = [];
  for (let i = 0; i < steps; i++) out.push(coverScale(old, next, curve.progress(i / (steps - 1))));
  return out;
}
