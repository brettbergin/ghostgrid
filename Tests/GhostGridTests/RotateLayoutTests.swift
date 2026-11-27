import Foundation
#if canImport(CoreGraphics)
    import CoreGraphics // CGRect's Codable conformance on macOS
#endif
import Testing
@testable import GhostGridCore

/// Contract for Rotate Layout: a window's shape picks the split (side by
/// side when wide, stacked when tall); rotating turns that choice for every
/// mode, so two panes can stack in a wide window. Dividers and dragging
/// follow the rotated split. Not rotated, nothing changes.
struct RotateLayoutTests {
    let wide = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let tall = CGRect(x: 0, y: 0, width: 800, height: 1200)

    @Test func twoPanesStackInARotatedWideWindow() {
        let frames = GridLayout.frames(count: 2, in: wide, gap: 6, mode: .grid, weights: nil, rotated: true)
        #expect(frames.count == 2)
        #expect(frames[0].minX == 6 && frames[0].maxX == 1194, "full width")
        #expect(frames[1].minX == 6 && frames[1].maxX == 1194)
        #expect(frames[0].maxY < frames[1].minY, "first on top")
    }

    @Test func twoPanesSitSideBySideInARotatedTallWindow() {
        let frames = GridLayout.frames(count: 2, in: tall, gap: 6, mode: .grid, weights: nil, rotated: true)
        #expect(frames[0].minY == 6 && frames[0].maxY == 1194, "full height")
        #expect(frames[0].maxX < frames[1].minX, "first on the left")
    }

    @Test func everyModeTurns() {
        let main = GridLayout.frames(count: 3, in: wide, gap: 6, mode: .mainStack, weights: nil, rotated: true)
        #expect(main[0].minX == 6 && main[0].maxX == 1194 && main[0].minY == 6, "the main pane across the top")
        let rows = GridLayout.frames(count: 3, in: wide, gap: 6, mode: .columns, weights: nil, rotated: true)
        #expect(Set(rows.map(\.width)) == [1188], "Columns become full-width rows")
        #expect(rows[0].maxY < rows[1].minY && rows[1].maxY < rows[2].minY)
    }

    @Test func notRotatedIsUnchanged() {
        for mode in GridLayout.Mode.allCases {
            for count in 1...7 {
                for bounds in [wide, tall] {
                    #expect(GridLayout.frames(count: count, in: bounds, gap: 6, mode: mode, weights: nil, rotated: false)
                        == GridLayout.frames(count: count, in: bounds, gap: 6, mode: mode, weights: nil))
                }
            }
        }
    }

    @Test func theDividerRunsAcrossARotatedSplit() throws {
        let splitters = GridLayout.splitters(count: 2, in: wide, gap: 6, mode: .grid, weights: nil, rotated: true)
        let divider = try #require(splitters.first)
        #expect(splitters.count == 1)
        #expect(divider.rect.width > divider.rect.height, "a horizontal divider between stacked panes")
        #expect(divider.rect.minX == 6 && divider.rect.maxX == 1194, "across the panes, as in an unrotated tall window")
        let tallDivider = try #require(GridLayout.splitters(count: 2, in: CGRect(x: 0, y: 0, width: 1200, height: 1300),
                                                            gap: 6, mode: .grid, weights: nil).first)
        #expect(tallDivider.rect.minX == divider.rect.minX && tallDivider.rect.width == divider.rect.width)
    }

    @Test func draggingTheDividerMovesItByThatMuch() throws {
        let before = GridLayout.frames(count: 2, in: wide, gap: 6, mode: .grid, weights: nil, rotated: true)
        let divider = try #require(GridLayout.splitters(count: 2, in: wide, gap: 6, mode: .grid, weights: nil, rotated: true).first)
        let weights = GridLayout.drag(divider.kind, by: 100, count: 2, in: wide, gap: 6, mode: .grid,
                                      weights: nil, rotated: true, minimum: 80)
        let after = GridLayout.frames(count: 2, in: wide, gap: 6, mode: .grid, weights: weights, rotated: true)
        #expect(abs(after[0].height - (before[0].height + 100)) < 0.001)
        #expect(abs(after[1].height - (before[1].height - 100)) < 0.001)
    }

    @Test func rotationIsSaved() throws {
        let window = Session.Window(frame: wide, panes: [], layout: .grid, rotated: true)
        let decoded = try JSONDecoder().decode(Session.Window.self, from: JSONEncoder().encode(window))
        #expect(decoded.rotated == true)
        let old = Data(#"{"frame":[[0,0],[10,10]],"panes":[]}"#.utf8)
        #expect(try JSONDecoder().decode(Session.Window.self, from: old).rotated == nil)
    }
}
