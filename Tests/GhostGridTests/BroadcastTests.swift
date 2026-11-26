import Testing
@testable import GhostGridCore

/// Contract for broadcast typing (PR 3): while it is on, what you type in
/// the focused pane also goes to every other pane in the window that runs
/// a shell; Command shortcuts stay ghostgrid's own.
struct BroadcastTests {
    @Test func offMeansNobodyElse() {
        #expect(Broadcast.targets(from: 0, running: [true, true, true], enabled: false).isEmpty)
    }

    @Test func onMeansEveryOtherRunningPane() {
        #expect(Broadcast.targets(from: 1, running: [true, true, true], enabled: true) == [0, 2])
    }

    @Test func panesStillShowingTheirMenuAreSkipped() {
        #expect(Broadcast.targets(from: 0, running: [true, false, true, false], enabled: true) == [2])
    }

    @Test func aSourceOutsideTheGridSendsToNobody() {
        #expect(Broadcast.targets(from: 5, running: [true, true], enabled: true).isEmpty)
        #expect(Broadcast.targets(from: nil, running: [true, true], enabled: true).isEmpty)
    }

    @Test func commandShortcutsAreNotMirrored() {
        #expect(Broadcast.mirrors(command: false))
        #expect(!Broadcast.mirrors(command: true))
    }
}
