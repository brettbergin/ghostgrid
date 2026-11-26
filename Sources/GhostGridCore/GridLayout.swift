import Foundation
#if canImport(CoreGraphics)
    import CoreGraphics // CGRect's Codable conformance on macOS
#endif

/// Where each pane goes in a balanced grid.
///
/// Panes fill row by row. The grid has `ceil(sqrt(n))` columns, so it grows
/// 1, 1x2, 2+1, 2x2, 3+2, 3x2, ... and the last row's panes stretch to fill
/// it. In a window taller than it is wide the grid is transposed, so panes
/// stack in columns instead.
public enum GridLayout {
    /// How a window arranges its panes.
    public enum Mode: String, CaseIterable, Codable, Sendable {
        /// Balanced rows, ceil(sqrt(n)) columns (the default).
        case grid
        /// The first pane large on the left (top in a tall window), the rest
        /// stacked beside it.
        case mainStack
        /// Equal columns side by side (rows in a tall window).
        case columns

        public var title: String {
            switch self {
            case .grid: "Grid"
            case .mainStack: "Main + Stack"
            case .columns: "Columns"
            }
        }

        /// The next mode, for cycling.
        public var next: Mode {
            let all = Mode.allCases
            return all[(all.firstIndex(of: self)! + 1) % all.count]
        }

        /// The stored value, or grid for anything unknown.
        public init(stored: String?) {
            self = stored.flatMap(Mode.init(rawValue:)) ?? .grid
        }
    }

    /// The main pane's share of the width (or height) in mainStack.
    public static let mainShare: CGFloat = 0.6

    public static func frames(count: Int, in bounds: CGRect, gap: CGFloat, mode: Mode) -> [CGRect] {
        guard count > 0, bounds.width > 0, bounds.height > 0 else { return [] }
        switch mode {
        case .grid: return frames(count: count, in: bounds, gap: gap)
        case .columns: return strip(count: count, in: bounds, gap: gap)
        case .mainStack: return mainStack(count: count, in: bounds, gap: gap)
        }
    }

    /// Lays out in a "wide" space and swaps the axes back for tall windows.
    private static func oriented(_ bounds: CGRect, _ layout: (CGRect) -> [CGRect]) -> [CGRect] {
        guard bounds.height > bounds.width else { return layout(bounds) }
        let swapped = CGRect(x: bounds.minY, y: bounds.minX, width: bounds.height, height: bounds.width)
        return layout(swapped).map { CGRect(x: $0.minY, y: $0.minX, width: $0.height, height: $0.width) }
    }

    private static func strip(count: Int, in bounds: CGRect, gap: CGFloat) -> [CGRect] {
        oriented(bounds) { space in
            let width = max((space.width - gap * CGFloat(count + 1)) / CGFloat(count), 0)
            let height = max(space.height - gap * 2, 0)
            return (0..<count).map { index in
                CGRect(x: space.minX + gap + CGFloat(index) * (width + gap), y: space.minY + gap,
                       width: width, height: height)
            }
        }
    }

    private static func mainStack(count: Int, in bounds: CGRect, gap: CGFloat) -> [CGRect] {
        guard count > 1 else { return frames(count: count, in: bounds, gap: gap) }
        return oriented(bounds) { space in
            let inner = space.width - gap * 3
            let mainWidth = max(inner * mainShare, 0)
            let stackWidth = max(inner - mainWidth, 0)
            let main = CGRect(x: space.minX + gap, y: space.minY + gap,
                              width: mainWidth, height: max(space.height - gap * 2, 0))
            let stackCount = count - 1
            let stackHeight = max((space.height - gap * CGFloat(stackCount + 1)) / CGFloat(stackCount), 0)
            let stack = (0..<stackCount).map { index in
                CGRect(x: main.maxX + gap, y: space.minY + gap + CGFloat(index) * (stackHeight + gap),
                       width: stackWidth, height: stackHeight)
            }
            return [main] + stack
        }
    }

    /// The pane under `point`, if any (for dropping a dragged pane).
    public static func index(at point: CGPoint, in frames: [CGRect], excluding: Int? = nil) -> Int? {
        frames.indices.first { $0 != excluding && frames[$0].contains(point) }
    }

    public static func frames(count: Int, in bounds: CGRect, gap: CGFloat) -> [CGRect] {
        guard count > 0, bounds.width > 0, bounds.height > 0 else { return [] }

        let tall = bounds.height > bounds.width
        // Lay out in a "wide" space, then swap axes back for tall windows.
        let space = tall
            ? CGRect(x: bounds.minY, y: bounds.minX, width: bounds.height, height: bounds.width)
            : bounds

        let columns = Int(Double(count).squareRoot().rounded(.up))
        let rows = (count + columns - 1) / columns
        let rowHeight = (space.height - gap * CGFloat(rows + 1)) / CGFloat(rows)

        var frames: [CGRect] = []
        frames.reserveCapacity(count)
        for row in 0..<rows {
            let inRow = row == rows - 1 ? count - columns * (rows - 1) : columns
            let width = (space.width - gap * CGFloat(inRow + 1)) / CGFloat(inRow)
            let y = space.minY + gap + CGFloat(row) * (rowHeight + gap)
            for column in 0..<inRow {
                let x = space.minX + gap + CGFloat(column) * (width + gap)
                frames.append(CGRect(x: x, y: y, width: max(width, 0), height: max(rowHeight, 0)))
            }
        }

        guard tall else { return frames }
        return frames.map { CGRect(x: $0.minY, y: $0.minX, width: $0.height, height: $0.width) }
    }

    /// The pane nearest to `from` in `direction`, or nil at the edge.
    /// Frames use flipped coordinates (y grows downward).
    public static func neighbor(of from: Int, in frames: [CGRect], direction: Direction) -> Int? {
        guard frames.indices.contains(from) else { return nil }
        let origin = frames[from]
        let start = CGPoint(x: origin.midX, y: origin.midY)

        var best: (index: Int, score: CGFloat)?
        for (index, frame) in frames.enumerated() where index != from {
            let dx = frame.midX - start.x
            let dy = frame.midY - start.y
            let ahead: CGFloat
            let across: CGFloat
            switch direction {
            case .left: (ahead, across) = (-dx, dy)
            case .right: (ahead, across) = (dx, dy)
            case .up: (ahead, across) = (-dy, dx)
            case .down: (ahead, across) = (dy, dx)
            }
            guard ahead > 1 else { continue }
            // Prefer panes straight ahead over ones off to the side.
            let score = ahead + abs(across) * 2
            if best == nil || score < best!.score {
                best = (index, score)
            }
        }
        return best?.index
    }

    public enum Direction: Sendable {
        case left, right, up, down
    }
}
