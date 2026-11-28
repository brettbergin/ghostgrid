// Port of ContentScaleTests, AnimationStyleTests and PaneGapTests.
import { describe, expect, it } from "vitest";
import {
  animationCurve,
  animationDuration,
  animationFromStored,
  animationStyles,
  animationTitle,
  clampedGap,
  coverKeyframes,
  coverScale,
  CubicBezier,
  PANE_GAP,
} from "../src/core/animation";
import { stride } from "./helpers";

describe("CubicBezier and ContentScale", () => {
  const spring = new CubicBezier(0.32, 1.42, 0.6, 1);

  it("hits the endpoints and follows the linear case", () => {
    expect(spring.progress(0)).toBe(0);
    expect(spring.progress(1)).toBe(1);
    const linear = new CubicBezier(0, 0, 1, 1);
    for (const time of stride(0, 1, 0.1)) {
      expect(Math.abs(linear.progress(time) - time)).toBeLessThan(1e-5);
    }
  });

  it("clamps time outside 0...1", () => {
    expect(spring.progress(-0.5)).toBe(0);
    expect(spring.progress(3)).toBe(1);
  });

  it("overshoots then settles on a spring", () => {
    const samples = stride(0, 1, 0.02).map((t) => spring.progress(t));
    expect(Math.max(...samples)).toBeGreaterThan(1.02); // a spring curve should overshoot
    expect(Math.abs(samples[samples.length - 1]! - 1)).toBeLessThan(1e-9);
  });

  it("covers the box at both ends", () => {
    const old = { width: 1200, height: 800 };
    const next = { width: 600, height: 800 };
    // At the start the content must cover the old, wider box.
    expect(coverScale(old, next, 0)).toBe(2);
    expect(coverScale(old, next, 1)).toBe(1);
  });

  it("is 1 for an empty target size", () => {
    expect(coverScale({ width: 100, height: 100 }, { width: 0, height: 50 }, 0.5)).toBe(1);
  });

  it("never leaves a gap, even during overshoot", () => {
    const old = { width: 1200, height: 800 };
    const next = { width: 600, height: 380 };
    for (const progress of stride(-0.1, 1.2, 0.05)) {
      const scale = coverScale(old, next, progress);
      const box = {
        width: old.width + (next.width - old.width) * progress,
        height: old.height + (next.height - old.height) * progress,
      };
      expect(next.width * scale).toBeGreaterThanOrEqual(box.width - 1e-6);
      expect(next.height * scale).toBeGreaterThanOrEqual(box.height - 1e-6);
    }
  });

  it("starts keyframes covered and ends at identity", () => {
    const frames = coverKeyframes({ width: 300, height: 200 }, { width: 1000, height: 600 }, spring);
    expect(frames.length).toBe(40);
    expect(Math.abs(frames[0]! - 1 / 3)).toBeLessThan(1e-9);
    expect(frames[frames.length - 1]).toBe(1);
    expect(coverKeyframes({ width: 1, height: 1 }, { width: 2, height: 2 }, spring, 0).length).toBe(2);
  });
});

describe("AnimationStyle", () => {
  it("defaults to springy for missing or unknown values", () => {
    expect(animationFromStored(null)).toBe("springy");
    expect(animationFromStored(undefined)).toBe("springy");
    expect(animationFromStored("bouncy")).toBe("springy");
    expect(animationFromStored("off")).toBe("off");
    expect(animationFromStored("smooth")).toBe("smooth");
  });

  it("springy overshoots and smooth does not", () => {
    const samples = stride(0, 1, 0.02);
    expect(Math.max(...samples.map((t) => animationCurve("springy")!.progress(t)))).toBeGreaterThan(1);
    expect(Math.max(...samples.map((t) => animationCurve("smooth")!.progress(t)))).toBeLessThanOrEqual(1 + 1e-9);
  });

  it("has no curve or duration when off", () => {
    expect(animationCurve("off")).toBeNull();
    expect(animationDuration("off")).toBe(0);
    expect(animationDuration("springy")).toBe(0.46);
    expect(animationDuration("smooth")).toBe(0.3);
  });

  it("lists the styles with titles", () => {
    expect(animationStyles).toEqual(["springy", "smooth", "off"]);
    expect(animationStyles.map(animationTitle)).toEqual(["Springy", "Smooth", "Off"]);
  });
});

describe("PaneGap", () => {
  it("clamps into range with a default", () => {
    expect(PANE_GAP).toEqual({ min: 0, max: 24, standard: 8 });
    expect(clampedGap(null)).toBe(8);
    expect(clampedGap(undefined)).toBe(8);
    expect(clampedGap()).toBe(8);
    expect(clampedGap(-5)).toBe(0);
    expect(clampedGap(100)).toBe(24);
    expect(clampedGap(12)).toBe(12);
    expect(clampedGap(Number.NaN)).toBe(8);
    expect(clampedGap(Number.POSITIVE_INFINITY)).toBe(8);
  });
});
