import Testing
@testable import GhostGridCore

/// Contract for a window's tabs (TabStrip): a new tab opens right after the
/// selected one and is selected; closing the selected tab selects the one to
/// its right (the new last one when it was last); closing or moving another
/// tab keeps the same tab selected; Cmd+1-8 pick that tab and Cmd+9 the
/// last; next and previous wrap around; requests out of range do nothing.
struct TabStripTests {
    @Test func aNewTabOpensRightAfterTheSelectedOneAndIsSelected() {
        var strip = TabStrip(["a", "b", "c"], selected: 0)
        strip.add("new")
        #expect(strip.tabs == ["a", "new", "b", "c"])
        #expect(strip.selected == 1)
        #expect(strip.selectedTab == "new")
    }

    @Test func aNewTabInAnEmptyStripIsTheOnlyOne() {
        var strip = TabStrip<String>([])
        #expect(strip.isEmpty)
        #expect(strip.selectedTab == nil)
        strip.add("a")
        #expect(strip.tabs == ["a"])
        #expect(strip.selectedTab == "a")
    }

    @Test func closingTheSelectedTabSelectsTheOneToItsRight() {
        var strip = TabStrip(["a", "b", "c"], selected: 1)
        #expect(strip.close(at: 1) == "b")
        #expect(strip.tabs == ["a", "c"])
        #expect(strip.selectedTab == "c")
    }

    @Test func closingTheLastTabWhileSelectedSelectsTheNewLastOne() {
        var strip = TabStrip(["a", "b", "c"], selected: 2)
        strip.close(at: 2)
        #expect(strip.selectedTab == "b")
    }

    @Test func closingAnotherTabKeepsTheSelection() {
        var strip = TabStrip(["a", "b", "c", "d"], selected: 2)
        strip.close(at: 0)
        #expect(strip.tabs == ["b", "c", "d"])
        #expect(strip.selectedTab == "c")
        strip.close(at: 2)
        #expect(strip.tabs == ["b", "c"])
        #expect(strip.selectedTab == "c")
    }

    @Test func closingTheOnlyTabLeavesNone() {
        var strip = TabStrip(["a"])
        #expect(strip.close(at: 0) == "a")
        #expect(strip.isEmpty)
        #expect(strip.selectedTab == nil)
    }

    @Test func movingATabKeepsTheSameTabSelected() {
        var strip = TabStrip(["a", "b", "c", "d"], selected: 1)
        strip.move(from: 1, to: 3) // the selected tab itself
        #expect(strip.tabs == ["a", "c", "d", "b"])
        #expect(strip.selectedTab == "b")
        strip.move(from: 0, to: 2) // another tab, staying left of it
        #expect(strip.tabs == ["c", "d", "a", "b"])
        #expect(strip.selectedTab == "b")
        strip.move(from: 3, to: 0)
        #expect(strip.tabs == ["b", "c", "d", "a"])
        #expect(strip.selected == 0)
        strip.move(from: 3, to: 0) // another tab, crossing it
        #expect(strip.tabs == ["a", "b", "c", "d"])
        #expect(strip.selectedTab == "b")
        #expect(strip.selected == 1)
    }

    @Test func requestsOutOfRangeDoNothing() {
        var strip = TabStrip(["a", "b"], selected: 0)
        strip.select(at: 5)
        #expect(strip.selected == 0)
        #expect(strip.close(at: 7) == nil)
        #expect(strip.tabs == ["a", "b"])
        strip.move(from: 0, to: 9)
        strip.move(from: -1, to: 0)
        #expect(strip.tabs == ["a", "b"])
    }

    @Test func commandNumbersPickTabsAndNinePicksTheLast() {
        var strip = TabStrip(["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k"], selected: 0)
        strip.select(number: 3)
        #expect(strip.selectedTab == "c")
        strip.select(number: 8)
        #expect(strip.selectedTab == "h")
        strip.select(number: 9)
        #expect(strip.selectedTab == "k", "Cmd+9 is the last tab, however many there are")
        var short = TabStrip(["a", "b"], selected: 0)
        short.select(number: 5)
        #expect(short.selectedTab == "a", "no fifth tab: nothing changes")
        short.select(number: 9)
        #expect(short.selectedTab == "b")
    }

    @Test func nextAndPreviousWrapAround() {
        var strip = TabStrip(["a", "b", "c"], selected: 2)
        strip.selectNext(1)
        #expect(strip.selectedTab == "a")
        strip.selectNext(-1)
        #expect(strip.selectedTab == "c")
        strip.selectNext(-1)
        #expect(strip.selectedTab == "b")
    }

    @Test func aStartingSelectionOutOfRangeIsClamped() {
        #expect(TabStrip(["a", "b"], selected: 9).selectedTab == "b")
        #expect(TabStrip(["a", "b"], selected: -1).selectedTab == "a")
    }
}

/// Contract for tab names: an unnamed tab is "Tab N" by its position (so it
/// matches its Cmd+N shortcut); a name wins; renaming to blank goes back to
/// the number.
struct TabTitleTests {
    @Test func unnamedTabsAreNumberedByPosition() {
        #expect(TabTitle.display(name: nil, position: 0) == "Tab 1")
        #expect(TabTitle.display(name: nil, position: 4) == "Tab 5")
    }

    @Test func aNameWinsOverTheNumber() {
        #expect(TabTitle.display(name: "api", position: 2) == "api")
    }

    @Test func renamingToBlankGoesBackToTheNumber() {
        #expect(TabTitle.normalized("   ") == nil)
        #expect(TabTitle.normalized("\n\t") == nil)
        #expect(TabTitle.normalized("  build  ") == "build")
        #expect(TabTitle.display(name: "   ", position: 1) == "Tab 2")
    }
}

/// Contract for tab colors: eight Catppuccin Mocha presets (ghostgrid's
/// palette), in menu order; no color is nil.
struct TabColorTests {
    @Test func eightPresetsInMenuOrder() {
        #expect(TabColor.allCases.map(\.rawValue) == ["red", "peach", "yellow", "green", "teal", "blue", "mauve", "pink"])
        #expect(TabColor.allCases.map(\.title) == ["Red", "Peach", "Yellow", "Green", "Teal", "Blue", "Mauve", "Pink"])
    }

    @Test func presetsAreCatppuccinMochaColors() {
        #expect(TabColor.allCases.map(\.rgb) == [0xF38BA8, 0xFAB387, 0xF9E2AF, 0xA6E3A1, 0x94E2D5, 0x89B4FA, 0xCBA6F7, 0xF5C2E7])
    }
}

/// Contract for a background tab's badge: the most important of its panes'
/// badges (a failure, then a bell, then a finished command), the first pane's
/// among equals; none when no pane has one.
struct TabActivityTests {
    let succeeded = PaneActivity.finished(exitCode: 0, seconds: 12)
    let failed = PaneActivity.finished(exitCode: 2, seconds: 30)

    @Test func aQuietTabHasNoBadge() {
        #expect(TabActivity.badge(for: []) == nil)
        #expect(TabActivity.badge(for: [nil, nil]) == nil)
    }

    @Test func aFailureOutranksABellWhichOutranksASuccess() {
        #expect(TabActivity.badge(for: [succeeded, .bell, failed, nil]) == failed)
        #expect(TabActivity.badge(for: [succeeded, nil, .bell]) == .bell)
        #expect(TabActivity.badge(for: [nil, succeeded]) == succeeded)
    }

    @Test func amongEqualsTheFirstPaneWins() {
        let alsoFailed = PaneActivity.finished(exitCode: 1, seconds: 99)
        #expect(TabActivity.badge(for: [nil, failed, alsoFailed]) == failed)
    }
}

/// Contract for a tab arriving from elsewhere (dragged from another window,
/// or out to a new one): it goes in at the slot it was dropped on and is
/// selected; a slot past the end is the end.
struct TabStripInsertTests {
    @Test func anArrivingTabGoesInAtItsSlotAndIsSelected() {
        var strip = TabStrip(["a", "b", "c"], selected: 2)
        strip.insert("new", at: 1)
        #expect(strip.tabs == ["a", "new", "b", "c"])
        #expect(strip.selectedTab == "new")
    }

    @Test func slotsPastEitherEndAreTheEnds() {
        var strip = TabStrip(["a", "b"], selected: 0)
        strip.insert("end", at: 99)
        #expect(strip.tabs == ["a", "b", "end"])
        strip.insert("start", at: -3)
        #expect(strip.tabs == ["start", "a", "b", "end"])
        #expect(strip.selectedTab == "start")
    }

    @Test func aTabArrivingInAnEmptyStripIsTheOnlyOne() {
        var strip = TabStrip<String>([])
        strip.insert("a", at: 3)
        #expect(strip.tabs == ["a"])
        #expect(strip.selectedTab == "a")
    }
}
