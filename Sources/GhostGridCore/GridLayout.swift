import CoreGraphics

/// Where each pane goes in a balanced grid.
///
/// Panes fill row by row. The grid has `ceil(sqrt(n))` columns, so it grows
/// 1, 1x2, 2+1, 2x2, 3+2, 3x2, ... and the last row's panes stretch to fill
/// it. In a window taller than it is wide the grid is transposed, so panes
/// stack in columns instead.
public enum GridLayout {
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
