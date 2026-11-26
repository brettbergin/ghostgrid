import Foundation
#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Testing
@testable import GhostGridCore

/// Contract for the attention grid (PR 6): a pane that needs you (a bell, a
/// notification, a finished background command: an agent waiting) or that
/// just printed grows; panes quiet for a while shrink; the layout stays
/// gentle and balanced when nothing stands out.
struct AttentionTests {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)

    func level(output secondsAgo: Double?, waiting: Bool = false, focused: Bool = false) -> AttentionLevel {
        AttentionGrid.level(lastOutput: secondsAgo.map { now.addingTimeInterval(-$0) }, waiting: waiting,
                            focused: focused, now: now)
    }

    @Test func levelsFollowWhatThePaneIsDoing() {
        #expect(level(output: 500, waiting: true) == .wanted, "an agent waiting for you")
        #expect(level(output: 1) == .active, "fresh output")
        #expect(level(output: 30) == .quiet)
        #expect(level(output: 500) == .idle)
        #expect(level(output: nil) == .idle)
        #expect(level(output: 500, focused: true) == .active, "the pane you are in never shrinks")
        #expect(level(output: 500, waiting: true, focused: true) == .active, "you are already there")
    }

    @Test func nothingStandingOutMeansBalanced() {
        #expect(AttentionGrid.weights(for: [.quiet, .quiet, .quiet, .quiet], mode: .grid) == nil)
        #expect(AttentionGrid.weights(for: [.idle, .idle], mode: .columns) == nil)
        #expect(AttentionGrid.weights(for: [], mode: .grid) == nil)
    }

    private func frames(_ levels: [AttentionLevel], _ mode: GridLayout.Mode) -> [CGRect] {
        GridLayout.frames(count: levels.count, in: bounds, gap: 8, mode: mode,
                          weights: AttentionGrid.weights(for: levels, mode: mode))
    }

    @Test func aWantedPaneGrowsInTheGrid() {
        let balanced = GridLayout.frames(count: 4, in: bounds, gap: 8, mode: .grid)
        let grown = frames([.wanted, .idle, .quiet, .quiet], .grid)
        #expect(grown[0].width > balanced[0].width && grown[0].height > balanced[0].height)
        #expect(grown[1].width < balanced[1].width, "its idle neighbour gives way")
        #expect(grown[0].width > grown[1].width)
    }

    @Test func mainAndStackFollowAttention() {
        let balanced = GridLayout.frames(count: 3, in: bounds, gap: 8, mode: .mainStack)
        let grown = frames([.idle, .wanted, .quiet], .mainStack)
        #expect(grown[0].width < balanced[0].width, "an idle main pane yields to the stack")
        #expect(grown[1].height > grown[2].height, "the wanted stack pane is the tallest there")
    }

    @Test func columnsFollowAttention() {
        let grown = frames([.active, .idle, .idle], .columns)
        #expect(grown[0].width > grown[1].width)
        #expect(abs(grown[1].width - grown[2].width) < 0.5)
    }

    @Test func itStaysGentle() {
        let balanced = GridLayout.frames(count: 4, in: bounds, gap: 8, mode: .grid)
        let grown = frames([.wanted, .idle, .idle, .idle], .grid)
        for (before, after) in zip(balanced, grown) {
            #expect(after.width * after.height >= before.width * before.height * 0.5, "no pane shrinks below half")
            #expect(after.width * after.height <= before.width * before.height * 2.2, "and none takes over")
        }
    }
}
