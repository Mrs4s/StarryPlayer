import CoreGraphics
import Foundation
import QuartzCore
import Testing
@testable import StarryPlayer

struct CoverTiltTests {
    private let square = CGSize(width: 300, height: 300)

    @Test func handlesEmptyAndOutOfBoundsGeometry() {
        #expect(CoverTilt(offset: .zero, size: .zero) == .flat)
        #expect(CoverTilt(offset: CGVector(dx: 900, dy: -900), size: square).degrees == CoverTilt.maxDegrees)
    }

    @Test func tiltsTowardThePointerWithoutSpinningTheCover() {
        let tilt = CoverTilt(offset: CGVector(dx: 150, dy: 0), size: square)
        let t = CoverTilt.transform(degrees: tilt.degrees, axis: tilt.axis, scale: 1.02, size: square)
        #expect(Self.project(t, 0, 0) == .zero)
        let onAxis = Self.project(t, 0, 100)
        #expect(abs(onAxis.x) < 1e-9 && abs(onAxis.y - 102) < 1e-9)
        #expect(Self.project(t, 100, 0).x > 102)
        #expect(Self.project(t, -100, 0).x > -102)
        let up = CoverTilt(offset: CGVector(dx: 0, dy: 150), size: square)
        let u = CoverTilt.transform(degrees: up.degrees, axis: up.axis, scale: 1, size: square)
        #expect(Self.project(u, 0, 100).y > 100)
        #expect(Self.project(u, 0, -100).y > -100)
    }

    /// Core Animation uses row vectors followed by a perspective divide.
    private static func project(_ t: CATransform3D, _ x: CGFloat, _ y: CGFloat) -> CGPoint {
        let w = x * t.m14 + y * t.m24 + t.m44
        return CGPoint(x: (x * t.m11 + y * t.m21 + t.m41) / w, y: (x * t.m12 + y * t.m22 + t.m42) / w)
    }
}

struct CoverSpringTests {
    @Test func smoothSettlesInAboutItsDurationWithoutOvershoot() {
        var spring = SpringValue(0)
        spring.target = 1
        var peak = 0.0
        for _ in 0..<27 {
            spring.step(1.0 / 60, .smooth)
            peak = max(peak, spring.value)
        }
        #expect(peak <= 1)
        #expect(spring.value > 0.98)
    }

    @Test func playbackBouncesModeratelyAndSettles() {
        var spring = SpringValue(1)
        spring.target = 0.85
        var lowest = 1.0
        for _ in 0..<120 {
            spring.step(1.0 / 60, .playback)
            lowest = min(lowest, spring.value)
        }
        #expect(lowest < 0.845 && lowest > 0.825)
        #expect(spring.isSettled(within: 1e-3))
    }

    @Test func givesTheSameMotionAtAnyFrameRate() {
        var fast = SpringValue(0), slow = SpringValue(0)
        fast.target = 1
        slow.target = 1
        for _ in 0..<120 { fast.step(1.0 / 120, .playback) }
        for _ in 0..<30 { slow.step(1.0 / 30, .playback) }
        #expect(abs(fast.value - slow.value) < 1e-9)
        #expect(abs(fast.velocity - slow.velocity) < 1e-9)
    }

    @Test func keepsMovingSmoothlyWhenTheTargetMoves() {
        var spring = SpringValue(0)
        spring.target = 1
        for _ in 0..<6 { spring.step(1.0 / 60, .smooth) }
        let (value, velocity) = (spring.value, spring.velocity)
        spring.target = 2
        spring.step(1.0 / 600, .smooth)
        #expect(abs(spring.value - (value + velocity / 600)) < 1e-3)
    }
}
