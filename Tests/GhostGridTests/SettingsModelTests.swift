import Testing
@testable import GhostGridCore

struct AnimationStyleTests {
    @Test func defaultsToSpringyForMissingOrUnknownValues() {
        #expect(AnimationStyle(stored: nil) == .springy)
        #expect(AnimationStyle(stored: "bouncy") == .springy)
        #expect(AnimationStyle(stored: "off") == .off)
    }

    @Test func springyOvershootsAndSmoothDoesNot() {
        let samples = stride(from: 0.0, through: 1.0, by: 0.02)
        #expect(samples.map { AnimationStyle.springy.curve!.progress(at: $0) }.max()! > 1)
        #expect(samples.map { AnimationStyle.smooth.curve!.progress(at: $0) }.max()! <= 1 + 1e-9)
    }

    @Test func offHasNoCurveOrDuration() {
        #expect(AnimationStyle.off.curve == nil)
        #expect(AnimationStyle.off.duration == 0)
        #expect(AnimationStyle.springy.duration > 0)
    }
}

struct PaneGapTests {
    @Test func clampsIntoRangeWithADefault() {
        #expect(PaneGap.clamped(nil) == 8)
        #expect(PaneGap.clamped(-5) == 0)
        #expect(PaneGap.clamped(100) == 24)
        #expect(PaneGap.clamped(12) == 12)
        #expect(PaneGap.clamped(.nan) == 8)
    }
}
