import Foundation

/// How much a pane wants your eyes (attention grid).
public enum AttentionLevel: Int, Comparable, Sendable {
    /// Nothing printed for a while: it gives up some room.
    case idle
    case quiet
    /// Printing right now, or the pane you are in.
    case active
    /// Waiting for you: a bell, a notification, a command that finished
    /// while you looked elsewhere (an agent asking for input).
    case wanted

    public static func < (a: AttentionLevel, b: AttentionLevel) -> Bool { a.rawValue < b.rawValue }

    /// Relative size. Kept close to 1 so the grid moves gently.
    var weight: Double {
        switch self {
        case .idle: 0.7
        case .quiet: 1
        case .active: 1.35
        case .wanted: 1.7
        }
    }
}

/// The attention grid: panes that need you or just printed grow, panes
/// quiet for a while shrink, by way of the same divider weights a drag sets.
public enum AttentionGrid {
    /// Output this recent makes a pane active.
    public static let fresh: TimeInterval = 4
    /// No output for this long makes a pane idle.
    public static let idleAfter: TimeInterval = 90

    public static func level(lastOutput: Date?, waiting: Bool, focused: Bool, now: Date) -> AttentionLevel {
        if focused { return .active }
        if waiting { return .wanted }
        guard let lastOutput else { return .idle }
        let age = now.timeIntervalSince(lastOutput)
        if age <= fresh { return .active }
        return age < idleAfter ? .quiet : .idle
    }

    /// Weights for panes at `levels` (grid order), or nil when none stands
    /// out: the balanced layout. A track (row, or main/stack) is as large
    /// as its most wanted pane; within a track each pane gets its own.
    public static func weights(for levels: [AttentionLevel], mode: GridLayout.Mode, rows: [Int]? = nil) -> LayoutWeights? {
        guard let first = levels.first, levels.contains(where: { $0 != first }) else { return nil }
        let structure = GridLayout.Structure(count: levels.count, mode: mode, rows: rows)
        var cells: [[Double]] = []
        var index = 0
        for count in structure.cellCounts {
            cells.append(levels[index..<index + count].map(\.weight))
            index += count
        }
        let tracks = zip(structure.defaultTracks, cells).map { $0 * ($1.max() ?? 1) }
        return LayoutWeights(tracks: tracks, cells: cells)
    }
}
