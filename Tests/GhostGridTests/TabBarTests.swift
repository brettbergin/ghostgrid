import Foundation
#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Testing
@testable import GhostGridCore

/// Contract for the keyboard with tabs (the menu is built from Keymap):
/// terminal convention for tabs (Cmd+T new tab, Cmd+1-9 pick one, Cmd+Shift+]
/// / [ and Ctrl+Tab / Ctrl+Shift+Tab cycle, Cmd+Option+W closes one), new
/// panes on Cmd+D, Focus Pane N on Cmd+Option+1-9, every other shortcut as
/// before, and no shortcut doing two things.
struct KeymapTests {
    typealias Key = KeyBinding

    @Test func tabsFollowTerminalConvention() {
        #expect(Keymap.bindings(for: .newTab) == [Key("t")])
        #expect(Keymap.bindings(for: .newTabChoosingShell) == [Key("t", [.command, .shift])])
        #expect(Keymap.bindings(for: .closeTab) == [Key("w", [.command, .option])])
        #expect(Keymap.bindings(for: .nextTab) == [Key("}"), Key("\t", .control)])
        #expect(Keymap.bindings(for: .previousTab) == [Key("{"), Key("\t", [.control, .shift])])
        #expect((1...9).map(Keymap.selectTab) == (1...9).map { Key("\($0)") })
    }

    @Test func panesMoveOffTheTabKeys() {
        #expect(Keymap.bindings(for: .newPane) == [Key("d")])
        #expect(Keymap.bindings(for: .newPaneChoosingShell) == [Key("d", [.command, .shift])])
        #expect((1...9).map(Keymap.focusPane) == (1...9).map { Key("\($0)", [.command, .option]) })
    }

    @Test func everyOtherShortcutIsUnchanged() {
        let left = String(UnicodeScalar(0xF702)!), right = String(UnicodeScalar(0xF703)!)
        let up = String(UnicodeScalar(0xF700)!), down = String(UnicodeScalar(0xF701)!)
        let expected: [(MenuCommand, [Key])] = [
            (.newWindow, [Key("n")]),
            (.closePane, [Key("w")]),
            (.closeWindow, [Key("w", [.command, .shift])]),
            (.toggleBroadcast, [Key("i", [.command, .option])]),
            (.toggleZoom, [Key("\r", [.command, .shift])]),
            (.toggleCommandBlocks, [Key("b", [.command, .shift])]),
            (.copyLastCommandOutput, [Key("c", [.command, .option, .shift])]),
            (.explainLastFailure, [Key("e", [.command, .shift])]),
            (.nextPane, [Key("]")]),
            (.previousPane, [Key("[")]),
            (.focusLeft, [Key(left, [.command, .option])]),
            (.focusRight, [Key(right, [.command, .option])]),
            (.focusUp, [Key(up, [.command, .option])]),
            (.focusDown, [Key(down, [.command, .option])]),
            (.swapLeft, [Key(left, [.command, .shift])]),
            (.swapRight, [Key(right, [.command, .shift])]),
            (.swapUp, [Key(up, [.command, .shift])]),
            (.swapDown, [Key(down, [.command, .shift])]),
            (.makeMain, [Key("m", [.command, .shift])]),
            (.equalizePanes, [Key("=", [.command, .control])]),
            (.toggleAttentionGrid, [Key("a", [.command, .control])]),
            (.cycleLayout, [Key("l", [.command, .shift])]),
            (.rotateLayout, [Key("r", [.command, .control])]),
            (.showSettings, [Key(",")]),
            (.openConfiguration, [Key(",", [.command, .option])]),
            (.reloadConfiguration, [Key(",", [.command, .shift])]),
            (.hide, [Key("h")]),
            (.hideOthers, [Key("h", [.command, .option])]),
            (.quit, [Key("q")]),
            (.minimize, [Key("m")]),
            (.toggleFullScreen, [Key("f", [.command, .control]), Key("\r")]),
        ]
        for (command, keys) in expected {
            #expect(Keymap.bindings(for: command) == keys, "\(command)")
        }
    }

    @Test func noShortcutDoesTwoThings() {
        var seen: [Key: String] = [:]
        for (name, key) in Keymap.everyBinding {
            #expect(seen[key] == nil, "\(key) is both \(seen[key] ?? "") and \(name)")
            seen[key] = name
        }
        #expect(seen.count > 50)
    }
}

/// Contract for the tab bar's layout: tabs share the bar evenly between a
/// minimum and maximum width; past what fits at the minimum, the bar scrolls.
/// A dragged tab lands in the slot nearest its middle. The bar shows
/// whenever the window has a tab, so the first tab can be renamed, colored
/// and dragged like any other.
struct TabBarLayoutTests {
    let layout = TabBarLayout(minimumWidth: 100, maximumWidth: 200, spacing: 4)

    @Test func tabsShareTheBarEvenly() {
        let frames = layout.frames(count: 3, width: 460)
        #expect(frames.map(\.width) == [150, 150, 150])
        #expect(frames.map(\.minX) == [0, 154, 308])
        #expect(layout.contentWidth(count: 3, width: 460) == 458)
    }

    @Test func fewTabsStopAtTheMaximumWidth() {
        #expect(layout.frames(count: 2, width: 1000).map(\.width) == [200, 200])
    }

    @Test func manyTabsStopAtTheMinimumAndScroll() {
        let frames = layout.frames(count: 10, width: 500)
        #expect(Set(frames.map(\.width)) == [100])
        #expect(layout.contentWidth(count: 10, width: 500) == CGFloat(10 * 100 + 9 * 4))
        #expect(layout.contentWidth(count: 10, width: 500) > 500, "wider than the bar: it scrolls")
    }

    @Test func aDraggedTabLandsInTheNearestSlot() {
        // Three 150-point tabs at 0, 154, 308 (middles 75, 229, 383).
        #expect(layout.dropIndex(forMiddle: 10, count: 3, width: 460) == 0)
        #expect(layout.dropIndex(forMiddle: 160, count: 3, width: 460) == 1)
        #expect(layout.dropIndex(forMiddle: 300, count: 3, width: 460) == 1)
        #expect(layout.dropIndex(forMiddle: 320, count: 3, width: 460) == 2)
        #expect(layout.dropIndex(forMiddle: 9999, count: 3, width: 460) == 2)
        #expect(layout.dropIndex(forMiddle: -50, count: 3, width: 460) == 0)
    }

    @Test func theBarShowsWhenTheWindowHasATab() {
        #expect(TabBarLayout.shows(count: 1), "a single plain tab has its bar too")
        #expect(TabBarLayout.shows(count: 2))
        #expect(!TabBarLayout.shows(count: 0))
    }
}

/// Contract for a background tab's badge over time: it shows only what
/// happened since you last looked at the tab, so switching to a tab clears
/// its badge even while a pane in it still shows its own.
struct TabActivitySinceTests {
    let looked = Date(timeIntervalSince1970: 1000)

    @Test func onlyWhatHappenedSinceYouLookedCounts() {
        let failed = PaneActivity.finished(exitCode: 1, seconds: 9)
        let panes: [(activity: PaneActivity?, at: Date?)] = [
            (failed, looked.addingTimeInterval(-5)), // before: already seen
            (.bell, looked.addingTimeInterval(5)),
            (nil, nil),
        ]
        #expect(TabActivity.badge(for: panes, since: looked) == .bell)
        #expect(TabActivity.badge(for: panes, since: looked.addingTimeInterval(10)) == nil)
        #expect(TabActivity.badge(for: panes, since: nil) == failed, "never looked at: everything counts")
    }
}

/// Contract for where the tab bar sits: in a window, in the titlebar beside
/// the traffic lights, the panes where they always were; in full screen
/// (no titlebar to sit in, even when the window still reports its height),
/// above the panes, which move down to make room only while it shows.
struct TabBarPlacementTests {
    @Test func inAWindowTheBarFillsTheTitlebar() {
        let placed = TabBarPlacement.place(fullScreen: false, titlebarHeight: 28, buttonsMaxX: 68, visible: true)
        #expect(placed == TabBarPlacement(barHeight: 28, gridTop: 0, leading: 80))
    }

    @Test func inFullScreenTheBarSitsAboveThePanes() {
        for titlebar in [0.0, 28.0] {
            let placed = TabBarPlacement.place(fullScreen: true, titlebarHeight: titlebar, buttonsMaxX: 68, visible: true)
            #expect(placed == TabBarPlacement(barHeight: 30, gridTop: 30, leading: 8), "titlebar \(titlebar)")
        }
    }

    @Test func inFullScreenAHiddenBarTakesNoRoom() {
        let placed = TabBarPlacement.place(fullScreen: true, titlebarHeight: 28, buttonsMaxX: 68, visible: false)
        #expect(placed.gridTop == 0)
    }
}

/// Contract for dropping a tab from elsewhere onto a tab bar: it goes in
/// before the first tab whose middle is right of the pointer (after the
/// last one past them all). A tab dragged within its own bar leaves it
/// once the pointer is well above or below the bar.
struct TabBarDropTests {
    let layout = TabBarLayout(minimumWidth: 100, maximumWidth: 200, spacing: 4)

    @Test func anArrivingTabGoesBeforeTheFirstTabRightOfThePointer() {
        // Three 150-point tabs at 0, 154, 308 (middles 75, 229, 383).
        #expect(layout.insertIndex(forX: 10, count: 3, width: 460) == 0)
        #expect(layout.insertIndex(forX: 80, count: 3, width: 460) == 1)
        #expect(layout.insertIndex(forX: 228, count: 3, width: 460) == 1)
        #expect(layout.insertIndex(forX: 230, count: 3, width: 460) == 2)
        #expect(layout.insertIndex(forX: 999, count: 3, width: 460) == 3)
        #expect(layout.insertIndex(forX: 50, count: 0, width: 460) == 0)
    }

    @Test func aDraggedTabLeavesTheBarWellAboveOrBelowIt() {
        #expect(!TabBarLayout.leavesBar(y: 14, height: 28))
        #expect(!TabBarLayout.leavesBar(y: -20, height: 28))
        #expect(!TabBarLayout.leavesBar(y: 48, height: 28))
        #expect(TabBarLayout.leavesBar(y: -30, height: 28))
        #expect(TabBarLayout.leavesBar(y: 60, height: 28))
    }
}
