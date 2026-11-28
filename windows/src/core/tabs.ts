// A window's tabs: their order and selection, names, colors, badges, and
// the tab bar's layout. A port of GhostGridCore's Tabs.swift (less
// TabBarPlacement, which places the bar in the macOS titlebar).
import { activityFailed, type PaneActivity } from "./paneActivity";

/// A window's tabs in order, and which one is selected. Each tab holds its
/// own grid of panes; the window shows only the selected one.
///
/// A new tab opens right after the selected one and is selected. Closing
/// the selected tab selects the one to its right (the new last one when it
/// was last); closing or moving any other tab keeps the same tab selected.
/// Requests for tabs that do not exist are ignored.
///
/// The Swift is a value type; here the methods change the strip in place
/// and `clone()` gives an independent copy where a value is wanted. `tabs`
/// is read-only to callers, so the strip's rules cannot be bypassed.
export class TabStrip<T> {
  private items: T[];
  private index: number;

  /// `selected` is clamped to the tabs given. The array is copied.
  constructor(tabs: readonly T[] = [], selected = 0) {
    this.items = [...tabs];
    this.index = Math.min(Math.max(Math.trunc(selected) || 0, 0), Math.max(tabs.length - 1, 0));
  }

  get tabs(): readonly T[] {
    return this.items;
  }

  /// Index of the selected tab; 0 when there are none.
  get selected(): number {
    return this.index;
  }

  get isEmpty(): boolean {
    return this.items.length === 0;
  }

  get count(): number {
    return this.items.length;
  }

  get selectedTab(): T | null {
    return this.has(this.index) ? this.items[this.index]! : null;
  }

  clone(): TabStrip<T> {
    return new TabStrip(this.items, this.index);
  }

  /// Opens `tab` right after the selected one and selects it.
  add(tab: T): void {
    const at = this.items.length === 0 ? 0 : this.index + 1;
    this.items.splice(at, 0, tab);
    this.index = at;
  }

  /// Removes the tab at `index` and returns it (null when there is none).
  close(index: number): T | null {
    if (!this.has(index)) return null;
    const [removed] = this.items.splice(index, 1);
    if (index < this.index) {
      this.index -= 1;
    } else if (index === this.index) {
      // The tab to the right slid into this place; past the end, the new
      // last tab.
      this.index = Math.min(this.index, Math.max(this.items.length - 1, 0));
    }
    return removed!;
  }

  /// Moves the tab at `from` so it ends up at `to`; the selected tab stays
  /// selected wherever it lands.
  move(from: number, to: number): void {
    if (!this.has(from) || !this.has(to) || from === to) return;
    const [tab] = this.items.splice(from, 1);
    this.items.splice(to, 0, tab!);
    if (this.index === from) {
      this.index = to;
    } else if (from < this.index && to >= this.index) {
      this.index -= 1;
    } else if (from > this.index && to <= this.index) {
      this.index += 1;
    }
  }

  /// A tab arriving from elsewhere (another window): it goes in at `index`
  /// (past either end: that end) and is selected.
  insert(tab: T, index: number): void {
    const at = Math.min(Math.max(Math.trunc(index) || 0, 0), this.items.length);
    this.items.splice(at, 0, tab);
    this.index = at;
  }

  select(index: number): void {
    if (this.has(index)) this.index = index;
  }

  /// Ctrl+1...8 select that tab (when there is one); Ctrl+9 the last tab,
  /// however many there are.
  selectNumber(number: number): void {
    if (this.items.length === 0) return;
    this.select(number === 9 ? this.items.length - 1 : number - 1);
  }

  /// Next (1) or previous (-1) tab, wrapping around.
  selectNext(step: number): void {
    const n = this.items.length;
    if (n === 0 || !Number.isInteger(step)) return;
    this.index = (((this.index + step) % n) + n) % n;
  }

  private has(i: number): boolean {
    return Number.isInteger(i) && i >= 0 && i < this.items.length;
  }
}

/// What a tab is called: the name you gave it, or "Tab N" by its position,
/// so it matches its Ctrl+N shortcut.
export function tabTitle(name: string | null | undefined, position: number): string {
  return (name == null ? null : normalizedTabName(name)) ?? `Tab ${position + 1}`;
}

/// A name as typed when renaming: trimmed; blank means no name (back to
/// "Tab N").
export function normalizedTabName(input: string): string | null {
  const trimmed = input.trim();
  return trimmed === "" ? null : trimmed;
}

/// The colors a tab can be given (Catppuccin Mocha, like the rest of
/// ghostgrid). No color is null.
export type TabColor = "red" | "peach" | "yellow" | "green" | "teal" | "blue" | "mauve" | "pink";

/// Each color's hex, in menu order (object key order is insertion order).
export const TAB_COLORS: Readonly<Record<TabColor, string>> = {
  red: "#f38ba8",
  peach: "#fab387",
  yellow: "#f9e2af",
  green: "#a6e3a1",
  teal: "#94e2d5",
  blue: "#89b4fa",
  mauve: "#cba6f7",
  pink: "#f5c2e7",
};

/// The colors in menu order.
export const tabColors: readonly TabColor[] = Object.keys(TAB_COLORS) as TabColor[];

export function tabColorTitle(color: TabColor): string {
  return color.charAt(0).toUpperCase() + color.slice(1);
}

/// Whether a stored value names a color (sessions are hand-editable).
export function isTabColor(value: unknown): value is TabColor {
  return typeof value === "string" && Object.prototype.hasOwnProperty.call(TAB_COLORS, value);
}

/// The badge a tab shows while you are looking at another tab: the most
/// important of its panes' badges. A failed command first, then a bell,
/// then a finished command; the first pane's among equals. null when no
/// pane has a badge.
export function tabBadge(panes: readonly (PaneActivity | null)[]): PaneActivity | null {
  let bell: PaneActivity | null = null;
  let first: PaneActivity | null = null;
  for (const p of panes) {
    if (p === null) continue;
    if (activityFailed(p)) return p;
    if (bell === null && p.kind === "bell") bell = p;
    if (first === null) first = p;
  }
  return bell ?? first;
}

/// A tab's badge counting only what happened since you last looked at it
/// (`since`, epoch ms; null: never, so everything counts). A badge with no
/// time is treated as already seen.
export function tabBadgeSince(
  panes: readonly { activity: PaneActivity | null; at: number | null }[],
  since: number | null,
): PaneActivity | null {
  if (since === null) return tabBadge(panes.map((p) => p.activity));
  return tabBadge(panes.map((p) => (p.at !== null && p.at >= since ? p.activity : null)));
}

/// A tab's place in the bar.
export interface TabSlot {
  minX: number;
  width: number;
  midX: number;
}

/// Where tabs sit in the tab bar: they share its width evenly, in whole
/// pixels, between a minimum and a maximum; when they would be narrower
/// than the minimum they stay at it and the bar scrolls.
export class TabBarLayout {
  readonly minimumWidth: number;
  readonly maximumWidth: number;
  readonly spacing: number;

  constructor(opts: { minimumWidth: number; maximumWidth: number; spacing: number }) {
    this.minimumWidth = opts.minimumWidth;
    this.maximumWidth = opts.maximumWidth;
    this.spacing = opts.spacing;
  }

  /// Each tab's width for `count` tabs in a bar `width` wide.
  tabWidth(count: number, width: number): number {
    if (!(count > 0)) return 0;
    const share = Math.floor((width - this.spacing * (count - 1)) / count);
    return Math.min(Math.max(share, this.minimumWidth), this.maximumWidth);
  }

  frames(count: number, width: number): TabSlot[] {
    const tab = this.tabWidth(count, width);
    const out: TabSlot[] = [];
    for (let i = 0; i < count; i++) {
      const minX = i * (tab + this.spacing);
      out.push({ minX, width: tab, midX: minX + tab / 2 });
    }
    return out;
  }

  /// How wide the tabs are together; more than `width` means the bar
  /// scrolls.
  contentWidth(count: number, width: number): number {
    if (!(count > 0)) return 0;
    return count * this.tabWidth(count, width) + this.spacing * (count - 1);
  }

  /// The slot a tab dragged along the bar lands in: the one whose middle
  /// is nearest the dragged tab's middle (the first of two equally near).
  dropIndex(middle: number, count: number, width: number): number {
    const slots = this.frames(count, width);
    let best = 0;
    for (let i = 1; i < slots.length; i++) {
      if (Math.abs(slots[i]!.midX - middle) < Math.abs(slots[best]!.midX - middle)) best = i;
    }
    return best;
  }

  /// Where a tab dropped from elsewhere goes in a bar of `count` tabs:
  /// before the first tab whose middle is right of `x`.
  insertIndex(x: number, count: number, width: number): number {
    return this.frames(count, width).filter((s) => s.midX < x).length;
  }
}

/// How far above or below the bar the pointer goes before a dragged tab
/// leaves it (to another window, or a new one).
export const TEAR_OFF_DISTANCE = 24;

/// Whether a tab dragged in a bar `height` tall has left it, the pointer
/// at `y` (0 at the bar's top, growing downward).
export function leavesBar(y: number, height: number): boolean {
  return y < -TEAR_OFF_DISTANCE || y > height + TEAR_OFF_DISTANCE;
}

/// The bar shows whenever the window has a tab, so the first tab can be
/// renamed, colored and dragged like any other.
export function tabBarShows(count: number): boolean {
  return count > 0;
}
