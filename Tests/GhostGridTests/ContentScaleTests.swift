import CoreGraphics
import Testing
@testable import GhostGridCore

struct ContentScaleTests {
    let spring = CubicBezier(0.32, 1.42, 0.6, 1)

    @Test func bezierEndpointsAndLinearCase() {
        #expect(spring.progress(at: 0) == 0)
        #expect(spring.progress(at: 1) == 1)
        let linear = CubicBezier(0, 0, 1, 1)
        for time in stride(from: 0.0, through: 1.0, by: 0.1) {
            #expect(abs(linear.progress(at: time) - time) < 1e-5)
        }
    }

    @Test func springOvershootsThenSettles() {
        let samples = stride(from: 0.0, through: 1.0, by: 0.02).map(spring.progress(at:))
        #expect(samples.max()! > 1.02, "a spring curve should overshoot")
        #expect(abs(samples.last! - 1) < 1e-9)
    }

    @Test func coverMatchesTheBoxAtBothEnds() {
        let old = CGSize(width: 1200, height: 800)
        let new = CGSize(width: 600, height: 800)
        // At the start the content must cover the old, wider box.
        #expect(ContentScale.cover(from: old, to: new, progress: 0) == 2)
        #expect(ContentScale.cover(from: old, to: new, progress: 1) == 1)
    }

    @Test func coverNeverLeavesAGapEvenDuringOvershoot() {
        let old = CGSize(width: 1200, height: 800)
        let new = CGSize(width: 600, height: 380)
        for progress in stride(from: -0.1, through: 1.2, by: 0.05) {
            let scale = ContentScale.cover(from: old, to: new, progress: progress)
            let box = CGSize(
                width: old.width + (new.width - old.width) * progress,
                height: old.height + (new.height - old.height) * progress,
            )
            #expect(new.width * scale >= box.width - 1e-6)
            #expect(new.height * scale >= box.height - 1e-6)
        }
    }

    @Test func keyframesStartCoveredAndEndAtIdentity() {
        let frames = ContentScale.keyframes(
            from: CGSize(width: 300, height: 200), to: CGSize(width: 1000, height: 600), curve: spring,
        )
        #expect(frames.count == 40)
        #expect(abs(frames.first! - 1.0 / 3.0) < 1e-9)
        #expect(frames.last! == 1)
    }
}
