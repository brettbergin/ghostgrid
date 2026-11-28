/// Plain rectangles and points for the layout code. Top-left origin, y
/// grows downward (the same as the Swift's flipped view coordinates, and
/// the DOM's), so layout numbers match the macOS app's exactly.
export interface Rect {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface Point {
  x: number;
  y: number;
}

export interface Size {
  width: number;
  height: number;
}

export const maxX = (r: Rect): number => r.x + r.width;
export const maxY = (r: Rect): number => r.y + r.height;
export const midX = (r: Rect): number => r.x + r.width / 2;
export const midY = (r: Rect): number => r.y + r.height / 2;

/// Whether `p` is inside `r`: the top and left edges count, the bottom and
/// right ones do not (CGRect.contains), so a point on a shared edge belongs
/// to exactly one of two touching rects.
export function contains(r: Rect, p: Point): boolean {
  return p.x >= r.x && p.x < r.x + r.width && p.y >= r.y && p.y < r.y + r.height;
}

/// The rect with its axes swapped. The layout works in a "wide" space and
/// transposes to serve tall windows, so one code path covers both.
export function transposed(r: Rect): Rect {
  return { x: r.y, y: r.x, width: r.height, height: r.width };
}
