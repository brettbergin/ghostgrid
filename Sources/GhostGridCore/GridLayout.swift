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
        frames(count: count, in: bounds, gap: gap, mode: mode, weights: nil)
    }

    /// Frames for `count` panes, with the divider adjustments in `weights`
    /// (nil, or weights made for another pane count or mode: balanced).
    /// `rows`: the grid's panes per row, top to bottom, after rows were
    /// moved (see ``move(_:onto:count:mode:rows:weights:)``); nil, or a
    /// shape that does not fit: the balanced one, short row last.
    public static func frames(
        count: Int, in bounds: CGRect, gap: CGFloat, mode: Mode, weights: LayoutWeights?, rows: [Int]? = nil,
    ) -> [CGRect] {
        guard count > 0, bounds.width > 0, bounds.height > 0 else { return [] }
        let structure = Structure(count: count, mode: mode, rows: rows)
        let (tracks, cells) = structure.resolve(weights)
        return oriented(bounds) { space in
            structure.frames(in: space, gap: gap, tracks: tracks, cells: cells)
        }
    }

    /// The draggable dividers between panes: between tracks (grid rows, the
    /// main/stack split) and between cells of a track. Each rect covers the
    /// gap, at least `minimumThickness` wide so it can be grabbed with no gap.
    public static func splitters(
        count: Int, in bounds: CGRect, gap: CGFloat, mode: Mode, weights: LayoutWeights?, rows: [Int]? = nil,
        minimumThickness: CGFloat = 8,
    ) -> [Splitter] {
        guard count > 1, bounds.width > 0, bounds.height > 0 else { return [] }
        let structure = Structure(count: count, mode: mode, rows: rows)
        let (tracks, cells) = structure.resolve(weights)
        let tall = bounds.height > bounds.width
        let space = tall ? transposed(bounds) : bounds
        let wide = structure.splitters(in: space, gap: gap, tracks: tracks, cells: cells, thickness: max(gap, minimumThickness))
        return tall ? wide.map { Splitter(kind: $0.kind, rect: transposed($0.rect)) } : wide
    }

    /// Weights after dragging the divider `kind` by `delta` points across
    /// itself (x for a vertical divider, y for a horizontal one). Only the two
    /// neighbours change, their sum stays, and neither gets smaller than
    /// `minimum` points.
    public static func drag(
        _ kind: Splitter.Kind, by delta: CGFloat, count: Int, in bounds: CGRect, gap: CGFloat,
        mode: Mode, weights: LayoutWeights?, rows: [Int]? = nil, minimum: CGFloat,
    ) -> LayoutWeights {
        let structure = Structure(count: count, mode: mode, rows: rows)
        var (tracks, cells) = structure.resolve(weights)
        let tall = bounds.height > bounds.width
        let space = tall ? transposed(bounds) : bounds
        let trackExtent = structure.trackExtent(in: space, gap: gap)
        switch kind {
        case let .track(index) where tracks.indices.contains(index + 1):
            let sizes = distribute(trackExtent - gap * CGFloat(tracks.count + 1), tracks)
            (tracks[index], tracks[index + 1]) = shifted(tracks[index], tracks[index + 1], sizes[index], sizes[index + 1], delta, minimum)
        case let .cell(track, index) where cells.indices.contains(track) && cells[track].indices.contains(index + 1):
            let cellExtent = structure.cellExtent(in: space)
            let sizes = distribute(cellExtent - gap * CGFloat(cells[track].count + 1), cells[track])
            (cells[track][index], cells[track][index + 1]) =
                shifted(cells[track][index], cells[track][index + 1], sizes[index], sizes[index + 1], delta, minimum)
        default:
            break
        }
        return LayoutWeights(tracks: tracks, cells: cells)
    }

    /// Two neighbouring weights after moving their shared edge by `delta`.
    private static func shifted(
        _ wa: Double, _ wb: Double, _ a: CGFloat, _ b: CGFloat, _ delta: CGFloat, _ minimum: CGFloat,
    ) -> (Double, Double) {
        let total = a + b
        guard total > 0 else { return (wa, wb) }
        let low = min(minimum, total / 2)
        let newA = min(max(a + delta, low), total - low)
        let weightSum = wa + wb
        let newWA = weightSum * Double(newA / total)
        return (newWA, weightSum - newWA)
    }

    /// `extent` shared out by `weights`.
    static func distribute(_ extent: CGFloat, _ weights: [Double]) -> [CGFloat] {
        let sum = weights.reduce(0, +)
        guard sum > 0 else { return weights.map { _ in 0 } }
        return weights.map { max(extent * CGFloat($0 / sum), 0) }
    }

    private static func transposed(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minY, y: rect.minX, width: rect.height, height: rect.width)
    }

    /// Lays out in a "wide" space and swaps the axes back for tall windows.
    private static func oriented(_ bounds: CGRect, _ layout: (CGRect) -> [CGRect]) -> [CGRect] {
        guard bounds.height > bounds.width else { return layout(bounds) }
        return layout(transposed(bounds)).map(transposed)
    }

    /// Every mode as tracks of cells, in a wide space. Tracks run along y
    /// (grid rows, the single columns track) or along x (main | stack);
    /// cells run along the other axis. Panes are numbered track by track.
    struct Structure {
        var tracksAlongY: Bool
        var cellCounts: [Int]
        var defaultTracks: [Double]

        init(count: Int, mode: Mode, rows moved: [Int]? = nil) {
            switch mode {
            case .mainStack where count > 1:
                tracksAlongY = false
                cellCounts = [1, count - 1]
                defaultTracks = [Double(GridLayout.mainShare), Double(1 - GridLayout.mainShare)]
            case .columns:
                tracksAlongY = true
                cellCounts = [count]
                defaultTracks = [1]
            case .grid, .mainStack:
                let columns = Int(Double(count).squareRoot().rounded(.up))
                let rows = (count + columns - 1) / columns
                tracksAlongY = true
                cellCounts = (0..<rows).map { $0 == rows - 1 ? count - columns * (rows - 1) : columns }
                defaultTracks = Array(repeating: 1, count: rows)
                // Rows moved with move(_:onto:...): the same rows, reordered.
                if mode == .grid, let moved, moved.sorted() == cellCounts.sorted() {
                    cellCounts = moved
                }
            }
        }

        /// `weights` when they fit this structure, else the balanced defaults.
        func resolve(_ weights: LayoutWeights?) -> (tracks: [Double], cells: [[Double]]) {
            let defaults = (defaultTracks, cellCounts.map { Array(repeating: 1.0, count: $0) })
            guard let weights,
                  weights.tracks.count == cellCounts.count,
                  weights.cells.map(\.count) == cellCounts,
                  (weights.tracks + weights.cells.flatMap { $0 }).allSatisfy({ $0.isFinite && $0 > 0 })
            else { return defaults }
            return (weights.tracks, weights.cells)
        }

        func trackExtent(in space: CGRect, gap _: CGFloat) -> CGFloat {
            tracksAlongY ? space.height : space.width
        }

        func cellExtent(in space: CGRect) -> CGFloat {
            tracksAlongY ? space.width : space.height
        }

        /// Track spans (start, size) along the track axis, and cell spans
        /// along the other axis for each track.
        private func spans(in space: CGRect, gap: CGFloat, tracks: [Double], cells: [[Double]])
            -> (tracks: [(CGFloat, CGFloat)], cells: [[(CGFloat, CGFloat)]])
        {
            func lay(_ start: CGFloat, _ extent: CGFloat, _ weights: [Double]) -> [(CGFloat, CGFloat)] {
                let sizes = GridLayout.distribute(extent - gap * CGFloat(weights.count + 1), weights)
                var position = start + gap
                return sizes.map { size in
                    defer { position += size + gap }
                    return (position, size)
                }
            }
            let trackStart = tracksAlongY ? space.minY : space.minX
            let cellStart = tracksAlongY ? space.minX : space.minY
            return (lay(trackStart, trackExtent(in: space, gap: gap), tracks),
                    cells.map { lay(cellStart, cellExtent(in: space), $0) })
        }

        func frames(in space: CGRect, gap: CGFloat, tracks: [Double], cells: [[Double]]) -> [CGRect] {
            let laid = spans(in: space, gap: gap, tracks: tracks, cells: cells)
            var frames: [CGRect] = []
            for (track, (trackPosition, trackSize)) in laid.tracks.enumerated() {
                for (cellPosition, cellSize) in laid.cells[track] {
                    frames.append(tracksAlongY
                        ? CGRect(x: cellPosition, y: trackPosition, width: cellSize, height: trackSize)
                        : CGRect(x: trackPosition, y: cellPosition, width: trackSize, height: cellSize))
                }
            }
            return frames
        }

        func splitters(in space: CGRect, gap: CGFloat, tracks: [Double], cells: [[Double]], thickness: CGFloat) -> [Splitter] {
            let laid = spans(in: space, gap: gap, tracks: tracks, cells: cells)
            // A strip centred on the gap after `end`, `thickness` thick.
            func across(_ end: CGFloat) -> (CGFloat, CGFloat) { (end + gap / 2 - thickness / 2, thickness) }
            var result: [Splitter] = []
            for index in laid.tracks.indices.dropLast() {
                let (position, size) = laid.tracks[index]
                let (start, thick) = across(position + size)
                let crossStart = tracksAlongY ? space.minX : space.minY
                let crossExtent = cellExtent(in: space)
                result.append(Splitter(kind: .track(index), rect: tracksAlongY
                    ? CGRect(x: crossStart, y: start, width: crossExtent, height: thick)
                    : CGRect(x: start, y: crossStart, width: thick, height: crossExtent)))
            }
            for (track, (trackPosition, trackSize)) in laid.tracks.enumerated() {
                for index in laid.cells[track].indices.dropLast() {
                    let (position, size) = laid.cells[track][index]
                    let (start, thick) = across(position + size)
                    result.append(Splitter(kind: .cell(track: track, index: index), rect: tracksAlongY
                        ? CGRect(x: start, y: trackPosition, width: thick, height: trackSize)
                        : CGRect(x: trackPosition, y: start, width: trackSize, height: thick)))
                }
            }
            return result
        }
    }

    /// What moving one pane onto another does to a window's layout.
    public struct Rearrangement: Equatable, Sendable {
        /// The new grid order, as indices into the old one.
        public var order: [Int]
        /// The grid's panes per row after the move (nil: balanced).
        public var rows: [Int]?
        public var weights: LayoutWeights?
        /// The panes (old indices) that make way: the target pane, or its
        /// whole row when rows trade places. For the drop highlight.
        public var displaced: [Int]
    }

    /// Moving the pane at `from` onto the pane at `to` (a Swap command or
    /// a drop). In the grid, a pane moving into a row with a different
    /// number of panes takes its row with it: the two rows trade places,
    /// sizes and all, so a long pane stays long. Otherwise the two panes
    /// trade places and the layout keeps its shape.
    public static func move(
        _ from: Int, onto to: Int, count: Int, mode: Mode, rows: [Int]?, weights: LayoutWeights?,
    ) -> Rearrangement {
        var order = Array(0..<count)
        guard order.indices.contains(from), order.indices.contains(to), from != to else {
            return Rearrangement(order: order, rows: rows, weights: weights, displaced: [])
        }
        let structure = Structure(count: count, mode: mode, rows: rows)
        let counts = structure.cellCounts
        let starts = counts.indices.map { counts[..<$0].reduce(0, +) }
        func track(of pane: Int) -> Int { starts.lastIndex { $0 <= pane } ?? 0 }
        let (source, target) = (track(of: from), track(of: to))
        guard mode == .grid, source != target, counts[source] != counts[target] else {
            order.swapAt(from, to)
            return Rearrangement(order: order, rows: rows, weights: weights, displaced: [to])
        }
        // The two rows trade places, each with its panes and its sizes.
        var tracks = Array(counts.indices)
        tracks.swapAt(source, target)
        order = tracks.flatMap { Array(starts[$0]..<starts[$0] + counts[$0]) }
        let moved = tracks.map { counts[$0] }
        let resolved = structure.resolve(weights)
        return Rearrangement(
            order: order,
            rows: moved == Structure(count: count, mode: mode).cellCounts ? nil : moved,
            weights: weights == nil ? nil
                : LayoutWeights(tracks: tracks.map { resolved.tracks[$0] }, cells: tracks.map { resolved.cells[$0] }),
            displaced: Array(starts[target]..<starts[target] + counts[target]),
        )
    }

    /// The pane under `point`, if any (for dropping a dragged pane).
    public static func index(at point: CGPoint, in frames: [CGRect], excluding: Int? = nil) -> Int? {
        frames.indices.first { $0 != excluding && frames[$0].contains(point) }
    }

    public static func frames(count: Int, in bounds: CGRect, gap: CGFloat) -> [CGRect] {
        frames(count: count, in: bounds, gap: gap, mode: .grid, weights: nil)
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

/// Divider adjustments for one window: a weight per track (grid row, or
/// the main and stack sides of Main + Stack) and per cell of each track.
/// Saved in the session; ignored when they do not fit the window's pane
/// count and mode, which is how adding or removing a pane rebalances.
public struct LayoutWeights: Codable, Equatable, Sendable {
    public var tracks: [Double]
    public var cells: [[Double]]
    public init(tracks: [Double], cells: [[Double]]) {
        self.tracks = tracks
        self.cells = cells
    }
}

/// A draggable divider between two panes, and the rect to grab it by.
public struct Splitter: Equatable, Sendable {
    public enum Kind: Hashable, Sendable {
        case track(Int)
        case cell(track: Int, index: Int)
    }
    public var kind: Kind
    public var rect: CGRect
}
