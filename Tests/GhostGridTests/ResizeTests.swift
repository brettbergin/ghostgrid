import Foundation
#if canImport(CoreGraphics)
    import CoreGraphics // CGRect's Codable conformance on macOS
#endif
import Testing
@testable import GhostGridCore

/// Contract for resizable panes (PR 1): balanced by default, a drag moves
/// only the two neighbours of a gap and keeps their sum, a minimum size
/// holds, every mode and tall windows work, a changed pane count goes back
/// to balanced, and weights survive the session file.
struct ResizeTests {
    let wide = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let tall = CGRect(x: 0, y: 0, width: 800, height: 1200)
    let gap: CGFloat = 8

    private func frames(_ count: Int, _ mode: GridLayout.Mode, _ weights: LayoutWeights?, in bounds: CGRect? = nil) -> [CGRect] {
        GridLayout.frames(count: count, in: bounds ?? wide, gap: gap, mode: mode, weights: weights)
    }

    private func drag(_ kind: Splitter.Kind, _ delta: CGFloat, _ count: Int, _ mode: GridLayout.Mode,
                      _ weights: LayoutWeights? = nil, in bounds: CGRect? = nil) -> LayoutWeights {
        GridLayout.drag(kind, by: delta, count: count, in: bounds ?? wide, gap: gap, mode: mode,
                        weights: weights, minimum: 100)
    }

    @Test func noWeightsIsTheBalancedLayout() {
        for mode in GridLayout.Mode.allCases {
            for count in 1...8 {
                #expect(frames(count, mode, nil) == GridLayout.frames(count: count, in: wide, gap: gap, mode: mode),
                        "\(mode) \(count)")
            }
        }
    }

    @Test func gridHasADividerBetweenRowsAndBetweenColumnsInEachRow() {
        let dividers = GridLayout.splitters(count: 4, in: wide, gap: gap, mode: .grid, weights: nil)
        #expect(Set(dividers.map(\.kind)) == [.track(0), .cell(track: 0, index: 0), .cell(track: 1, index: 0)])
        let panes = frames(4, .grid, nil)
        for divider in dividers {
            #expect(!panes.contains { $0.contains(CGPoint(x: divider.rect.midX, y: divider.rect.midY)) })
        }
    }

    @Test func draggingAColumnDividerMovesOnlyItsTwoPanes() {
        let before = frames(4, .grid, nil)
        let after = frames(4, .grid, drag(.cell(track: 0, index: 0), 100, 4, .grid))
        #expect(abs(after[0].width - (before[0].width + 100)) < 0.01)
        #expect(abs(after[1].width - (before[1].width - 100)) < 0.01)
        #expect(abs(after[1].maxX - before[1].maxX) < 0.01, "the pair's outer edge stays")
        #expect(after[2] == before[2] && after[3] == before[3], "the other row is untouched")
        #expect(after[0].height == before[0].height)
    }

    @Test func draggingARowDividerMovesRowHeights() {
        let before = frames(4, .grid, nil)
        let after = frames(4, .grid, drag(.track(0), 50, 4, .grid))
        #expect(abs(after[0].height - (before[0].height + 50)) < 0.01)
        #expect(abs(after[2].height - (before[2].height - 50)) < 0.01)
        #expect(abs(after[2].maxY - before[2].maxY) < 0.01)
    }

    @Test func dragsCompoundFromTheCurrentWeights() {
        let once = drag(.cell(track: 0, index: 0), 60, 4, .grid)
        let twice = drag(.cell(track: 0, index: 0), 40, 4, .grid, once)
        let direct = drag(.cell(track: 0, index: 0), 100, 4, .grid)
        #expect(abs(frames(4, .grid, twice)[0].width - frames(4, .grid, direct)[0].width) < 0.01)
    }

    @Test func aPaneNeverGoesBelowTheMinimum() {
        let after = frames(4, .grid, drag(.cell(track: 0, index: 0), 5000, 4, .grid))
        #expect(abs(after[1].width - 100) < 0.01)
        let other = frames(4, .grid, drag(.cell(track: 0, index: 0), -5000, 4, .grid))
        #expect(abs(other[0].width - 100) < 0.01)
    }

    @Test func mainStackDividerSetsTheMainShare() {
        let before = frames(3, .mainStack, nil)
        let after = frames(3, .mainStack, drag(.track(0), -120, 3, .mainStack))
        #expect(abs(after[0].width - (before[0].width - 120)) < 0.01)
        #expect(abs(after[1].width - (before[1].width + 120)) < 0.01)
        #expect(abs(after[1].maxX - before[1].maxX) < 0.01)
    }

    @Test func mainStackStackDividerSetsStackHeights() {
        let before = frames(3, .mainStack, nil)
        let after = frames(3, .mainStack, drag(.cell(track: 1, index: 0), 80, 3, .mainStack))
        #expect(abs(after[1].height - (before[1].height + 80)) < 0.01)
        #expect(abs(after[2].height - (before[2].height - 80)) < 0.01)
        #expect(after[0] == before[0])
    }

    @Test func columnsInATallWindowResizeVertically() {
        let before = frames(3, .columns, nil, in: tall)
        let weights = drag(.cell(track: 0, index: 1), 70, 3, .columns, in: tall)
        let after = frames(3, .columns, weights, in: tall)
        #expect(abs(after[1].height - (before[1].height + 70)) < 0.01)
        #expect(abs(after[2].height - (before[2].height - 70)) < 0.01)
        #expect(after[0] == before[0])
        let dividers = GridLayout.splitters(count: 3, in: tall, gap: gap, mode: .columns, weights: nil)
        #expect(dividers.allSatisfy { $0.rect.width > $0.rect.height }, "rows in a tall window: horizontal dividers")
    }

    @Test func aDifferentPaneCountGoesBackToBalanced() {
        let weights = drag(.cell(track: 0, index: 0), 100, 4, .grid)
        #expect(frames(5, .grid, weights) == frames(5, .grid, nil))
        #expect(frames(4, .columns, weights) == frames(4, .columns, nil), "a different mode too")
    }

    @Test func dividersStayGrabbableWithNoGap() {
        let dividers = GridLayout.splitters(count: 2, in: wide, gap: 0, mode: .columns, weights: nil)
        #expect(dividers.count == 1)
        #expect(dividers[0].rect.width >= 6)
    }

    @Test func weightsRoundTripThroughTheSession() throws {
        let weights = drag(.track(0), 50, 4, .grid)
        let session = Session(windows: [.init(frame: .zero, tabs: [
            .init(panes: [.init(shell: "zsh", workingDirectory: nil)], layout: .grid, weights: weights),
        ])])
        #expect(Session.decode(try session.encoded())?.windows.first?.tabs.first?.weights == weights)
        let old = #"{"version":1,"windows":[{"frame":[[0,0],[10,10]],"panes":[{"shell":"zsh"}]}]}"#
        #expect(Session.decode(Data(old.utf8))?.windows.first?.tabs.first?.weights == nil)
    }
}
