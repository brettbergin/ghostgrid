// Port of TabTests and TabBarTests (less the macOS titlebar placement and
// the Mac keymap, which keymap.test.ts replaces with the Windows one).
import { describe, expect, it } from "vitest";
import {
  isTabColor,
  leavesBar,
  normalizedTabName,
  TAB_COLORS,
  TabBarLayout,
  tabBadge,
  tabBadgeSince,
  tabBarShows,
  tabColors,
  tabColorTitle,
  TabStrip,
  tabTitle,
  TEAR_OFF_DISTANCE,
} from "../src/core/tabs";
import type { PaneActivity } from "../src/core/paneActivity";

/// Contract for a window's tabs: a new tab opens right after the selected
/// one and is selected; closing the selected tab selects the one to its
/// right (the new last one when it was last); closing or moving another tab
/// keeps the same tab selected; Ctrl+1-8 pick that tab and Ctrl+9 the last;
/// next and previous wrap around; requests out of range do nothing.
describe("TabStrip", () => {
  it("opens a new tab right after the selected one and selects it", () => {
    const strip = new TabStrip(["a", "b", "c"], 0);
    strip.add("new");
    expect(strip.tabs).toEqual(["a", "new", "b", "c"]);
    expect(strip.selected).toBe(1);
    expect(strip.selectedTab).toBe("new");
  });

  it("makes a new tab in an empty strip the only one", () => {
    const strip = new TabStrip<string>([]);
    expect(strip.isEmpty).toBe(true);
    expect(strip.count).toBe(0);
    expect(strip.selectedTab).toBeNull();
    strip.add("a");
    expect(strip.tabs).toEqual(["a"]);
    expect(strip.selectedTab).toBe("a");
  });

  it("selects the tab to the right when the selected one closes", () => {
    const strip = new TabStrip(["a", "b", "c"], 1);
    expect(strip.close(1)).toBe("b");
    expect(strip.tabs).toEqual(["a", "c"]);
    expect(strip.selectedTab).toBe("c");
  });

  it("selects the new last tab when the selected last one closes", () => {
    const strip = new TabStrip(["a", "b", "c"], 2);
    strip.close(2);
    expect(strip.selectedTab).toBe("b");
  });

  it("keeps the selection when another tab closes", () => {
    const strip = new TabStrip(["a", "b", "c", "d"], 2);
    strip.close(0);
    expect(strip.tabs).toEqual(["b", "c", "d"]);
    expect(strip.selectedTab).toBe("c");
    strip.close(2);
    expect(strip.tabs).toEqual(["b", "c"]);
    expect(strip.selectedTab).toBe("c");
  });

  it("leaves none when the only tab closes", () => {
    const strip = new TabStrip(["a"]);
    expect(strip.close(0)).toBe("a");
    expect(strip.isEmpty).toBe(true);
    expect(strip.selectedTab).toBeNull();
    expect(strip.selected).toBe(0);
  });

  it("keeps the same tab selected when tabs move", () => {
    const strip = new TabStrip(["a", "b", "c", "d"], 1);
    strip.move(1, 3); // the selected tab itself
    expect(strip.tabs).toEqual(["a", "c", "d", "b"]);
    expect(strip.selectedTab).toBe("b");
    strip.move(0, 2); // another tab, staying left of it
    expect(strip.tabs).toEqual(["c", "d", "a", "b"]);
    expect(strip.selectedTab).toBe("b");
    strip.move(3, 0);
    expect(strip.tabs).toEqual(["b", "c", "d", "a"]);
    expect(strip.selected).toBe(0);
    strip.move(3, 0); // another tab, crossing it
    expect(strip.tabs).toEqual(["a", "b", "c", "d"]);
    expect(strip.selectedTab).toBe("b");
    expect(strip.selected).toBe(1);
  });

  it("does nothing for requests out of range", () => {
    const strip = new TabStrip(["a", "b"], 0);
    strip.select(5);
    expect(strip.selected).toBe(0);
    expect(strip.close(7)).toBeNull();
    expect(strip.close(-1)).toBeNull();
    expect(strip.tabs).toEqual(["a", "b"]);
    strip.move(0, 9);
    strip.move(-1, 0);
    expect(strip.tabs).toEqual(["a", "b"]);
  });

  it("picks tabs by number, nine being the last", () => {
    const strip = new TabStrip(["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k"], 0);
    strip.selectNumber(3);
    expect(strip.selectedTab).toBe("c");
    strip.selectNumber(8);
    expect(strip.selectedTab).toBe("h");
    strip.selectNumber(9);
    expect(strip.selectedTab).toBe("k"); // Ctrl+9 is the last tab, however many there are
    const short = new TabStrip(["a", "b"], 0);
    short.selectNumber(5);
    expect(short.selectedTab).toBe("a"); // no fifth tab: nothing changes
    short.selectNumber(9);
    expect(short.selectedTab).toBe("b");
  });

  it("wraps next and previous around", () => {
    const strip = new TabStrip(["a", "b", "c"], 2);
    strip.selectNext(1);
    expect(strip.selectedTab).toBe("a");
    strip.selectNext(-1);
    expect(strip.selectedTab).toBe("c");
    strip.selectNext(-1);
    expect(strip.selectedTab).toBe("b");
    const empty = new TabStrip<string>([]);
    empty.selectNext(1);
    empty.selectNumber(9);
    expect(empty.selected).toBe(0);
  });

  it("clamps a starting selection out of range", () => {
    expect(new TabStrip(["a", "b"], 9).selectedTab).toBe("b");
    expect(new TabStrip(["a", "b"], -1).selectedTab).toBe("a");
  });

  it("does not share its array with the caller", () => {
    const given = ["a", "b"];
    const strip = new TabStrip(given);
    strip.add("c");
    expect(given).toEqual(["a", "b"]);
    const copy = strip.clone();
    copy.close(0);
    expect(strip.tabs).toEqual(["a", "c", "b"]);
    expect(copy.tabs).toEqual(["c", "b"]);
  });
});

/// Contract for a tab arriving from elsewhere: it goes in at the slot it
/// was dropped on and is selected; a slot past the end is the end.
describe("TabStrip insert", () => {
  it("puts an arriving tab at its slot and selects it", () => {
    const strip = new TabStrip(["a", "b", "c"], 2);
    strip.insert("new", 1);
    expect(strip.tabs).toEqual(["a", "new", "b", "c"]);
    expect(strip.selectedTab).toBe("new");
  });

  it("treats slots past either end as the ends", () => {
    const strip = new TabStrip(["a", "b"], 0);
    strip.insert("end", 99);
    expect(strip.tabs).toEqual(["a", "b", "end"]);
    strip.insert("start", -3);
    expect(strip.tabs).toEqual(["start", "a", "b", "end"]);
    expect(strip.selectedTab).toBe("start");
  });

  it("makes a tab arriving in an empty strip the only one", () => {
    const strip = new TabStrip<string>([]);
    strip.insert("a", 3);
    expect(strip.tabs).toEqual(["a"]);
    expect(strip.selectedTab).toBe("a");
  });
});

/// Contract for tab names: an unnamed tab is "Tab N" by its position (so it
/// matches its Ctrl+N shortcut); a name wins; renaming to blank goes back to
/// the number.
describe("Tab titles", () => {
  it("numbers unnamed tabs by position", () => {
    expect(tabTitle(null, 0)).toBe("Tab 1");
    expect(tabTitle(undefined, 4)).toBe("Tab 5");
  });

  it("lets a name win over the number", () => {
    expect(tabTitle("api", 2)).toBe("api");
  });

  it("goes back to the number when renamed to blank", () => {
    expect(normalizedTabName("   ")).toBeNull();
    expect(normalizedTabName("\n\t")).toBeNull();
    expect(normalizedTabName("  build  ")).toBe("build");
    expect(tabTitle("   ", 1)).toBe("Tab 2");
    expect(tabTitle("  api ", 1)).toBe("api");
  });
});

/// Contract for tab colors: eight Catppuccin Mocha presets, in menu order.
describe("Tab colors", () => {
  it("has eight presets in menu order", () => {
    expect(tabColors).toEqual(["red", "peach", "yellow", "green", "teal", "blue", "mauve", "pink"]);
    expect(Object.keys(TAB_COLORS)).toEqual(tabColors);
    expect(tabColors.map(tabColorTitle)).toEqual(["Red", "Peach", "Yellow", "Green", "Teal", "Blue", "Mauve", "Pink"]);
  });

  it("uses Catppuccin Mocha colors", () => {
    expect(tabColors.map((c) => TAB_COLORS[c])).toEqual([
      "#f38ba8",
      "#fab387",
      "#f9e2af",
      "#a6e3a1",
      "#94e2d5",
      "#89b4fa",
      "#cba6f7",
      "#f5c2e7",
    ]);
  });

  it("recognizes stored color names", () => {
    expect(isTabColor("teal")).toBe(true);
    expect(isTabColor("Teal")).toBe(false);
    expect(isTabColor("toString")).toBe(false);
    expect(isTabColor(null)).toBe(false);
  });
});

/// Contract for a background tab's badge: the most important of its panes'
/// badges (a failure, then a bell, then a finished command), the first
/// pane's among equals; none when no pane has one.
describe("Tab activity", () => {
  const succeeded: PaneActivity = { kind: "finished", exitCode: 0, seconds: 12 };
  const failed: PaneActivity = { kind: "finished", exitCode: 2, seconds: 30 };
  const bell: PaneActivity = { kind: "bell" };

  it("gives a quiet tab no badge", () => {
    expect(tabBadge([])).toBeNull();
    expect(tabBadge([null, null])).toBeNull();
  });

  it("ranks a failure over a bell over a success", () => {
    expect(tabBadge([succeeded, bell, failed, null])).toBe(failed);
    expect(tabBadge([succeeded, null, bell])).toBe(bell);
    expect(tabBadge([null, succeeded])).toBe(succeeded);
  });

  it("lets the first pane win among equals", () => {
    const alsoFailed: PaneActivity = { kind: "finished", exitCode: 1, seconds: 99 };
    expect(tabBadge([null, failed, alsoFailed])).toBe(failed);
  });

  it("counts only what happened since you looked", () => {
    const looked = 1_000_000; // ms
    const failedLater: PaneActivity = { kind: "finished", exitCode: 1, seconds: 9 };
    const panes = [
      { activity: failedLater, at: looked - 5000 }, // before: already seen
      { activity: bell, at: looked + 5000 },
      { activity: null, at: null },
    ];
    expect(tabBadgeSince(panes, looked)).toEqual(bell);
    expect(tabBadgeSince(panes, looked + 10_000)).toBeNull();
    expect(tabBadgeSince(panes, null)).toEqual(failedLater); // never looked at: everything counts
    expect(tabBadgeSince([{ activity: bell, at: looked }], looked)).toEqual(bell); // at the same moment counts
    expect(tabBadgeSince([{ activity: bell, at: null }], looked)).toBeNull(); // no time: already seen
  });
});

/// Contract for the tab bar's layout: tabs share the bar evenly between a
/// minimum and maximum width; past what fits at the minimum, the bar
/// scrolls. A dragged tab lands in the slot nearest its middle.
describe("TabBarLayout", () => {
  const layout = new TabBarLayout({ minimumWidth: 100, maximumWidth: 200, spacing: 4 });

  it("shares the bar evenly", () => {
    const slots = layout.frames(3, 460);
    expect(slots.map((s) => s.width)).toEqual([150, 150, 150]);
    expect(slots.map((s) => s.minX)).toEqual([0, 154, 308]);
    expect(slots.map((s) => s.midX)).toEqual([75, 229, 383]);
    expect(layout.contentWidth(3, 460)).toBe(458);
  });

  it("stops few tabs at the maximum width", () => {
    expect(layout.frames(2, 1000).map((s) => s.width)).toEqual([200, 200]);
  });

  it("stops many tabs at the minimum and scrolls", () => {
    const slots = layout.frames(10, 500);
    expect([...new Set(slots.map((s) => s.width))]).toEqual([100]);
    expect(layout.contentWidth(10, 500)).toBe(10 * 100 + 9 * 4);
    expect(layout.contentWidth(10, 500)).toBeGreaterThan(500); // wider than the bar: it scrolls
  });

  it("has nothing for no tabs", () => {
    expect(layout.tabWidth(0, 500)).toBe(0);
    expect(layout.frames(0, 500)).toEqual([]);
    expect(layout.contentWidth(0, 500)).toBe(0);
    expect(layout.dropIndex(50, 0, 500)).toBe(0);
  });

  it("rounds shares down to whole pixels", () => {
    expect(layout.tabWidth(3, 470)).toBe(154); // (470 - 8) / 3 = 154
    expect(layout.tabWidth(3, 471)).toBe(154);
  });

  it("lands a dragged tab in the nearest slot", () => {
    // Three 150-pixel tabs at 0, 154, 308 (middles 75, 229, 383).
    expect(layout.dropIndex(10, 3, 460)).toBe(0);
    expect(layout.dropIndex(160, 3, 460)).toBe(1);
    expect(layout.dropIndex(300, 3, 460)).toBe(1);
    expect(layout.dropIndex(320, 3, 460)).toBe(2);
    expect(layout.dropIndex(9999, 3, 460)).toBe(2);
    expect(layout.dropIndex(-50, 3, 460)).toBe(0);
  });

  it("puts an arriving tab before the first tab right of the pointer", () => {
    expect(layout.insertIndex(10, 3, 460)).toBe(0);
    expect(layout.insertIndex(80, 3, 460)).toBe(1);
    expect(layout.insertIndex(228, 3, 460)).toBe(1);
    expect(layout.insertIndex(230, 3, 460)).toBe(2);
    expect(layout.insertIndex(999, 3, 460)).toBe(3);
    expect(layout.insertIndex(50, 0, 460)).toBe(0);
  });

  it("lets a dragged tab leave the bar well above or below it", () => {
    expect(TEAR_OFF_DISTANCE).toBe(24);
    expect(leavesBar(14, 28)).toBe(false);
    expect(leavesBar(-20, 28)).toBe(false);
    expect(leavesBar(48, 28)).toBe(false);
    expect(leavesBar(-30, 28)).toBe(true);
    expect(leavesBar(60, 28)).toBe(true);
  });

  it("shows the bar whenever the window has a tab", () => {
    expect(tabBarShows(1)).toBe(true); // a single plain tab has its bar too
    expect(tabBarShows(2)).toBe(true);
    expect(tabBarShows(0)).toBe(false);
  });
});
