import { describe, expect, it } from "vitest";
import { contains, maxX, maxY, midX, midY, transposed, type Rect } from "../src/core/geometry";

describe("geometry", () => {
  const r: Rect = { x: 10, y: 20, width: 100, height: 50 };

  it("has the edges and middles", () => {
    expect([midX(r), midY(r), maxX(r), maxY(r)]).toEqual([60, 45, 110, 70]);
  });

  it("contains points on its top and left edges, not its bottom and right", () => {
    expect(contains(r, { x: 10, y: 20 })).toBe(true);
    expect(contains(r, { x: 109.9, y: 69.9 })).toBe(true);
    expect(contains(r, { x: 110, y: 30 })).toBe(false);
    expect(contains(r, { x: 30, y: 70 })).toBe(false);
    expect(contains(r, { x: 9, y: 30 })).toBe(false);
  });

  it("swaps the axes when transposed", () => {
    expect(transposed(r)).toEqual({ x: 20, y: 10, width: 50, height: 100 });
    expect(transposed(transposed(r))).toEqual(r);
  });
});
