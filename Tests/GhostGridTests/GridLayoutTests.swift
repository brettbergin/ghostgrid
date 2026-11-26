import Foundation
#if canImport(CoreGraphics)
    import CoreGraphics // CGRect's Codable conformance on macOS
#endif
import Testing
@testable import GhostGridCore

struct GridLayoutTests {
    let wide = CGRect(x: 0, y: 0, width: 1200, height: 800)

    @Test func emptyAndDegenerate() {
        #expect(GridLayout.frames(count: 0, in: wide, gap: 6).isEmpty)
        #expect(GridLayout.frames(count: 3, in: .zero, gap: 6).isEmpty)
    }

    @Test func onePaneFillsTheWindowInsideTheGap() {
        let frames = GridLayout.frames(count: 1, in: wide, gap: 6)
        #expect(frames == [CGRect(x: 6, y: 6, width: 1188, height: 788)])
    }

    @Test func rowShapesGrowBalanced() {
        // Panes per row, top to bottom, for 1...7 panes in a wide window.
        let expected: [Int: [Int]] = [1: [1], 2: [2], 3: [2, 1], 4: [2, 2], 5: [3, 2], 6: [3, 3], 7: [3, 3, 1]]
        for (count, shape) in expected {
            let frames = GridLayout.frames(count: count, in: wide, gap: 6)
            let rows = Dictionary(grouping: frames, by: \.minY).sorted { $0.key < $1.key }.map(\.value.count)
            #expect(rows == shape, "count \(count)")
        }
    }

    @Test func lastRowStretchesToFullWidth() {
        let frames = GridLayout.frames(count: 3, in: wide, gap: 6)
        #expect(frames[2].minX == 6)
        #expect(frames[2].maxX == 1194)
    }

    @Test func panesNeverOverlapAndStayInBounds() {
        for count in 1...12 {
            let frames = GridLayout.frames(count: count, in: wide, gap: 6)
            #expect(frames.count == count)
            for (i, a) in frames.enumerated() {
                #expect(wide.contains(a))
                for b in frames[(i + 1)...] {
                    #expect(!a.intersects(b), "count \(count)")
                }
            }
        }
    }

    @Test func tallWindowsStackInColumns() {
        let tall = CGRect(x: 0, y: 0, width: 800, height: 1200)
        let frames = GridLayout.frames(count: 2, in: tall, gap: 6)
        // Two panes stacked vertically, each full width.
        #expect(frames.allSatisfy { $0.width == 788 })
        #expect(frames[0].maxY < frames[1].minY)
    }

    @Test func neighborsFollowDirection() {
        // 2x2: 0 1 / 2 3 (flipped, y down).
        let frames = GridLayout.frames(count: 4, in: wide, gap: 6)
        #expect(GridLayout.neighbor(of: 0, in: frames, direction: .right) == 1)
        #expect(GridLayout.neighbor(of: 0, in: frames, direction: .down) == 2)
        #expect(GridLayout.neighbor(of: 3, in: frames, direction: .up) == 1)
        #expect(GridLayout.neighbor(of: 3, in: frames, direction: .left) == 2)
        #expect(GridLayout.neighbor(of: 0, in: frames, direction: .left) == nil)
        #expect(GridLayout.neighbor(of: 0, in: frames, direction: .up) == nil)
    }
}

struct LayoutModeTests {
    let wide = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let tall = CGRect(x: 0, y: 0, width: 800, height: 1200)

    private func noOverlapInBounds(_ frames: [CGRect], _ bounds: CGRect) -> Bool {
        for (i, a) in frames.enumerated() {
            guard bounds.contains(a) else { return false }
            for b in frames[(i + 1)...] where a.intersects(b) { return false }
        }
        return true
    }

    @Test func gridModeMatchesTheBalancedGrid() {
        #expect(GridLayout.frames(count: 5, in: wide, gap: 8, mode: .grid) == GridLayout.frames(count: 5, in: wide, gap: 8))
    }

    @Test func columnsAreEqualAndFullHeight() {
        let frames = GridLayout.frames(count: 3, in: wide, gap: 8, mode: .columns)
        #expect(Set(frames.map(\.width)).count == 1)
        #expect(frames.allSatisfy { $0.height == 784 })
        #expect(frames.map(\.minX) == frames.map(\.minX).sorted())
        #expect(noOverlapInBounds(frames, wide))
    }

    @Test func columnsBecomeRowsInTallWindows() {
        let frames = GridLayout.frames(count: 3, in: tall, gap: 8, mode: .columns)
        #expect(frames.allSatisfy { $0.width == 784 })
        #expect(frames.map(\.minY) == frames.map(\.minY).sorted())
    }

    @Test func mainStackPutsTheFirstPaneBigOnTheLeft() {
        let frames = GridLayout.frames(count: 4, in: wide, gap: 8, mode: .mainStack)
        let main = frames[0]
        #expect(main.minX == 8 && main.height == 784)
        #expect(abs(main.width - (1200 - 24) * 0.6) < 0.001)
        // The other three stack in one column to its right, equal heights.
        #expect(frames[1...].allSatisfy { $0.minX == main.maxX + 8 })
        #expect(Set(frames[1...].map(\.height)).count == 1)
        #expect(noOverlapInBounds(frames, wide))
    }

    @Test func mainStackTurnsInTallWindowsAndHandlesOnePane() {
        let frames = GridLayout.frames(count: 3, in: tall, gap: 8, mode: .mainStack)
        #expect(frames[0].minY == 8 && frames[0].width == 784)
        #expect(frames[1...].allSatisfy { $0.minY == frames[0].maxY + 8 })
        #expect(GridLayout.frames(count: 1, in: wide, gap: 8, mode: .mainStack) == [CGRect(x: 8, y: 8, width: 1184, height: 784)])
    }

    @Test func modesCycleAndDecode() {
        #expect(GridLayout.Mode.grid.next == .mainStack)
        #expect(GridLayout.Mode.columns.next == .grid)
        #expect(GridLayout.Mode(stored: "columns") == .columns)
        #expect(GridLayout.Mode(stored: nil) == .grid)
        #expect(GridLayout.Mode(stored: "spiral") == .grid)
    }

    @Test func hitTestingFindsThePaneUnderAPoint() {
        let frames = GridLayout.frames(count: 4, in: wide, gap: 8)
        #expect(GridLayout.index(at: CGPoint(x: 900, y: 600), in: frames) == 3)
        #expect(GridLayout.index(at: CGPoint(x: 900, y: 600), in: frames, excluding: 3) == nil)
        #expect(GridLayout.index(at: CGPoint(x: 4, y: 4), in: frames) == nil) // in the gap
    }
}
