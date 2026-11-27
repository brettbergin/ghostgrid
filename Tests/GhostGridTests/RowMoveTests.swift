import Foundation
#if canImport(CoreGraphics)
    import CoreGraphics // CGRect's Codable conformance on macOS
#endif
import Testing
@testable import GhostGridCore

/// Contract for moving panes between rows of the grid. Swapping keeps its
/// feel (two panes trade places) except where the rows differ in shape: a
/// pane moving into a row with a different number of panes takes its whole
/// row with it, sizes included, so a long thin pane (btop, say) stays long
/// and thin wherever it goes.
struct RowMoveTests {
    let wide = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let tall = CGRect(x: 0, y: 0, width: 800, height: 1200)

    /// Panes per row, top to bottom.
    private func shape(_ frames: [CGRect]) -> [Int] {
        Dictionary(grouping: frames, by: \.minY).sorted { $0.key < $1.key }.map(\.value.count)
    }

    private func frames(_ move: GridLayout.Rearrangement, count: Int, in bounds: CGRect? = nil) -> [CGRect] {
        GridLayout.frames(count: count, in: bounds ?? wide, gap: 6, mode: .grid, weights: move.weights, rows: move.rows)
    }

    @Test func theLongBottomPaneMovesUpWithItsRow() {
        // 2 on top (0, 1), 0 long below (2). Move 2 up onto 0.
        let move = GridLayout.move(2, onto: 0, count: 3, mode: .grid, rows: nil, weights: nil)
        #expect(move.order == [2, 0, 1], "the long pane first, the other two keep their order")
        #expect(move.rows == [1, 2])
        let laid = frames(move, count: 3)
        #expect(shape(laid) == [1, 2])
        #expect(laid[0].minY == 6 && laid[0].minX == 6 && laid[0].maxX == 1194, "the long pane spans the top")
    }

    @Test func movingATopPaneDownOntoTheLongOneMovesTheRowsToo() {
        let move = GridLayout.move(0, onto: 2, count: 3, mode: .grid, rows: nil, weights: nil)
        #expect(move.order == [2, 0, 1])
        #expect(move.rows == [1, 2])
    }

    @Test func aRowKeepsItsHeightWhenItMoves() {
        // The long bottom row dragged thin.
        let thin = LayoutWeights(tracks: [1, 0.4], cells: [[1, 1], [1]])
        let before = GridLayout.frames(count: 3, in: wide, gap: 6, mode: .grid, weights: thin)
        let move = GridLayout.move(2, onto: 1, count: 3, mode: .grid, rows: nil, weights: thin)
        let after = frames(move, count: 3)
        let long = try! #require(move.order.firstIndex(of: 2))
        #expect(abs(after[long].height - before[2].height) < 0.001)
        #expect(after[long].width == before[2].width)
        #expect(after[long].minY == 6)
        #expect(move.weights == LayoutWeights(tracks: [0.4, 1], cells: [[1], [1, 1]]))
    }

    @Test func panesInRowsOfTheSameShapeJustSwap() {
        // 2x2: moving 0 down onto 2 trades those two panes only.
        let move = GridLayout.move(0, onto: 2, count: 4, mode: .grid, rows: nil, weights: nil)
        #expect(move.order == [2, 1, 0, 3])
        #expect(move.rows == nil)
        #expect(move.displaced == [2])
    }

    @Test func panesInTheSameRowJustSwap() {
        let weights = LayoutWeights(tracks: [1, 1], cells: [[2, 1], [1]])
        let move = GridLayout.move(0, onto: 1, count: 3, mode: .grid, rows: nil, weights: weights)
        #expect(move.order == [1, 0, 2])
        #expect(move.rows == nil)
        #expect(move.weights == weights, "cells keep their sizes; the panes trade places")
    }

    @Test func theShortRowCanTravelThroughTheMiddle() {
        // 7 panes: 3, 3, 1. Move the lone pane up onto the middle row, then the top.
        let middle = GridLayout.move(6, onto: 3, count: 7, mode: .grid, rows: nil, weights: nil)
        #expect(middle.order == [0, 1, 2, 6, 3, 4, 5])
        #expect(middle.rows == [3, 1, 3])
        #expect(shape(frames(middle, count: 7)) == [3, 1, 3])
        let top = GridLayout.move(3, onto: 0, count: 7, mode: .grid, rows: middle.rows, weights: nil)
        #expect(top.order == [3, 0, 1, 2, 4, 5, 6])
        #expect(top.rows == [1, 3, 3])
    }

    @Test func aRowMoveDisplacesTheWholeTargetRow() {
        let move = GridLayout.move(2, onto: 1, count: 3, mode: .grid, rows: nil, weights: nil)
        #expect(Set(move.displaced) == [0, 1])
    }

    @Test func movingBackRestoresTheBalancedShape() {
        let up = GridLayout.move(2, onto: 0, count: 3, mode: .grid, rows: nil, weights: nil)
        let down = GridLayout.move(0, onto: 1, count: 3, mode: .grid, rows: up.rows, weights: up.weights)
        #expect(down.rows == nil, "short row last again: the balanced shape")
        #expect(down.order == [1, 2, 0])
    }

    @Test func mainStackKeepsItsMainPane() {
        let move = GridLayout.move(2, onto: 0, count: 3, mode: .mainStack, rows: nil, weights: nil)
        #expect(move.order == [2, 1, 0])
        #expect(move.rows == nil)
    }

    @Test func inATallWindowRowsAreColumns() {
        let move = GridLayout.move(2, onto: 0, count: 3, mode: .grid, rows: nil, weights: nil)
        let laid = frames(move, count: 3, in: tall)
        #expect(laid[0].minX == 6 && laid[0].minY == 6 && laid[0].maxY == 1194, "the long pane spans the left column")
    }

    @Test func aShapeThatDoesNotFitIsIgnored() {
        let balanced = GridLayout.frames(count: 3, in: wide, gap: 6, mode: .grid, weights: nil)
        for rows in [[1, 1, 1], [3], [2, 2], [0, 3], [1, 2, 0]] {
            #expect(GridLayout.frames(count: 3, in: wide, gap: 6, mode: .grid, weights: nil, rows: rows) == balanced, "\(rows)")
        }
        let columns = GridLayout.frames(count: 3, in: wide, gap: 6, mode: .columns, weights: nil)
        #expect(GridLayout.frames(count: 3, in: wide, gap: 6, mode: .columns, weights: nil, rows: [1, 2]) == columns)
    }

    @Test func dividersAndAttentionFollowTheMovedRows() {
        let rows = [1, 2]
        let splitters = GridLayout.splitters(count: 3, in: wide, gap: 6, mode: .grid, weights: nil, rows: rows)
        #expect(splitters.contains { $0.kind == .cell(track: 1, index: 0) })
        #expect(!splitters.contains { $0.kind == .cell(track: 0, index: 0) })
        let attention = AttentionGrid.weights(for: [.active, .idle, .idle], mode: .grid, rows: rows)
        #expect(attention?.cells.map(\.count) == [1, 2])
    }

    @Test func theMovedShapeIsSaved() throws {
        let tab = Session.Tab(panes: [], layout: .grid, rows: [1, 2])
        let decoded = try JSONDecoder().decode(Session.Tab.self, from: JSONEncoder().encode(tab))
        #expect(decoded.rows == [1, 2])
        let old = Data(#"{"panes":[]}"#.utf8)
        #expect(try JSONDecoder().decode(Session.Tab.self, from: old).rows == nil)
    }
}
