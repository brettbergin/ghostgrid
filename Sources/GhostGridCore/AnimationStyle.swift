/// How the grid animates when panes are added, closed, zoomed or rebalanced.
public enum AnimationStyle: String, CaseIterable, Sendable {
    /// A quick spring that overshoots a little and settles (the default).
    case springy
    /// Fast start, soft landing, no overshoot.
    case smooth
    /// Panes jump straight to their new places.
    case off

    public var title: String {
        switch self {
        case .springy: "Springy"
        case .smooth: "Smooth"
        case .off: "Off"
        }
    }

    /// The timing curve for grid changes; nil when animations are off.
    public var curve: CubicBezier? {
        switch self {
        case .springy: CubicBezier(0.32, 1.42, 0.6, 1)
        case .smooth: CubicBezier(0.2, 0.9, 0.25, 1)
        case .off: nil
        }
    }

    /// Seconds for a grid change; 0 when animations are off.
    public var duration: Double {
        switch self {
        case .springy: 0.46
        case .smooth: 0.3
        case .off: 0
        }
    }

    /// The stored value, or the default for anything unknown.
    public init(stored: String?) {
        self = stored.flatMap(Self.init(rawValue:)) ?? .springy
    }
}

/// The space between panes and around the grid, in points.
public enum PaneGap {
    public static let range: ClosedRange<Double> = 0...24
    public static let standard: Double = 8

    /// A stored value clamped into range; the default when unset.
    public static func clamped(_ stored: Double?) -> Double {
        guard let stored, stored.isFinite else { return standard }
        return min(max(stored, range.lowerBound), range.upperBound)
    }
}
