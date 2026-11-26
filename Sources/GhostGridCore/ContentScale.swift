import Foundation
#if canImport(CoreGraphics)
    import CoreGraphics // CGRect's Codable conformance on macOS
#endif

/// A CSS/Core Animation style cubic Bezier timing curve from (0,0) to (1,1).
/// `progress(at:)` maps elapsed time (0...1) to animation progress, which
/// may leave 0...1 when a control point does (an overshooting spring).
public struct CubicBezier: Sendable, Equatable {
    public let x1, y1, x2, y2: Double

    public init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        (self.x1, self.y1, self.x2, self.y2) = (x1, y1, x2, y2)
    }

    public func progress(at time: Double) -> Double {
        let x = min(max(time, 0), 1)
        if x == 0 || x == 1 { return x }
        // Solve bezierX(t) = x for t (x is monotonic for x1, x2 in 0...1),
        // Newton first, bisection as the fallback.
        var t = x
        for _ in 0..<8 {
            let error = Self.bezier(t, x1, x2) - x
            if abs(error) < 1e-7 { return Self.bezier(t, y1, y2) }
            let slope = Self.slope(t, x1, x2)
            if abs(slope) < 1e-6 { break }
            t -= error / slope
        }
        var low = 0.0, high = 1.0
        t = x
        for _ in 0..<50 {
            let value = Self.bezier(t, x1, x2)
            if abs(value - x) < 1e-7 { break }
            if value < x { low = t } else { high = t }
            t = (low + high) / 2
        }
        return Self.bezier(t, y1, y2)
    }

    private static func bezier(_ t: Double, _ a: Double, _ b: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
    }

    private static func slope(_ t: Double, _ a: Double, _ b: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * a + 6 * u * t * (b - a) + 3 * t * t * (1 - b)
    }
}

/// The uniform scale that makes content laid out at `new` size cover a box
/// that is `progress` of the way from `old` to `new`: the larger of the two
/// axis ratios, so the content never stretches and never leaves a gap.
public enum ContentScale {
    public static func cover(from old: CGSize, to new: CGSize, progress: Double) -> CGFloat {
        guard new.width > 0, new.height > 0 else { return 1 }
        let p = CGFloat(progress)
        let width = old.width + (new.width - old.width) * p
        let height = old.height + (new.height - old.height) * p
        return max(width / new.width, height / new.height)
    }

    /// `count` evenly timed samples of the cover scale along `curve`,
    /// for a keyframe animation that ends exactly at 1.
    public static func keyframes(from old: CGSize, to new: CGSize, curve: CubicBezier, count: Int = 40) -> [CGFloat] {
        let steps = max(count, 2)
        return (0..<steps).map { index in
            let time = Double(index) / Double(steps - 1)
            return cover(from: old, to: new, progress: curve.progress(at: time))
        }
    }
}
