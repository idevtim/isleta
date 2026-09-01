import Testing

@testable import IslandKit

/// The animation-speed multiplier, as arithmetic.
///
/// This exists because SwiftUI's `Animation` is opaque: nothing can read a response back off one, so
/// a test written against `Motion.expand` could only compare two `Animation`s for inequality — which
/// says the value changed and nothing about whether it changed in the right direction or by the
/// right amount. A slider labeled "faster" that is in fact slower compiles, runs, animates, and is
/// invisible to every test that does not do what this one does.
@Suite("Animation speed")
struct MotionSpeedTests {

    @Test("a speed of 1 leaves every token exactly as it was tuned")
    func unityIsUnchanged() {
        #expect(MotionSpeed.scale(0.38, speed: 1) == 0.38)
        #expect(MotionSpeed.scale(0.32, speed: 1) == 0.32)
        #expect(MotionSpeed.scale(0.22, speed: 1) == 0.22)
        #expect(MotionSpeed.scale(0.30, speed: 1) == 0.30)
    }

    /// The one that catches a transposed division. Faster means *less* time.
    @Test("faster is a shorter response, slower is a longer one")
    func directionIsRight() {
        #expect(MotionSpeed.scale(0.38, speed: 2) < 0.38)
        #expect(MotionSpeed.scale(0.38, speed: 0.5) > 0.38)
        #expect(MotionSpeed.scale(0.38, speed: 2) == 0.19)
        #expect(MotionSpeed.scale(0.38, speed: 0.5) == 0.76)
    }

    /// All four tokens have to keep their ratios, because §6.1's whole rule is that the island's
    /// dimensions travel together — a speed that reached three of them would put the content on a
    /// different clock from the container it follows by 40ms.
    @Test("every token scales by the same factor, so their proportions survive")
    func proportionsHold() {
        for speed in [0.5, 1, 1.5, 2.5] {
            let expand = MotionSpeed.scale(0.38, speed: speed)
            let collapse = MotionSpeed.scale(0.32, speed: speed)
            // Collapse is snappier than expand at every speed, by the ratio it was tuned at.
            #expect(collapse < expand)
            #expect(abs(collapse / expand - 0.32 / 0.38) < 1e-12)
        }
    }

    @Test("a value from outside the range is clamped rather than honored")
    func clamping() {
        #expect(MotionSpeed.clamp(0) == MotionSpeed.range.lowerBound)
        #expect(MotionSpeed.clamp(99) == MotionSpeed.range.upperBound)
        #expect(MotionSpeed.clamp(1.25) == 1.25)
        // The clamp is applied inside `scale` as well, not only by the property observer — so a
        // caller that reached this directly cannot ask for a response of zero, which is an animation
        // with no frames in it.
        #expect(MotionSpeed.scale(0.38, speed: 0) == 0.38 / MotionSpeed.range.lowerBound)
        #expect(MotionSpeed.scale(0.38, speed: 1_000_000) == 0.38 / MotionSpeed.range.upperBound)
    }

    /// Not a tautology: it is the statement that no reachable speed can collapse an animation to
    /// nothing, which is what "the island snaps" would look like and what a divide-by-zero would
    /// produce.
    @Test("no reachable speed produces a response of zero")
    func everySpeedStillAnimates() {
        for speed in stride(from: 0.1, through: 5.0, by: 0.1) {
            #expect(MotionSpeed.scale(0.22, speed: speed) > 0)
        }
    }
}
