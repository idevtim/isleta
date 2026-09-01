import CoreGraphics
import IslandKit
import Testing

@testable import IslandUI

@Suite("Swiping the island away")
struct StowGestureTests {

    private func sample(
        _ phase: IslandScrollSample.Phase,
        dx: CGFloat = 0,
        dy: CGFloat = 0
    ) -> IslandScrollSample {
        IslandScrollSample(phase: phase, deltaX: dx, deltaY: dy, isPrecise: true, timestamp: 0)
    }

    /// Drives a whole gesture and returns what it decided.
    private func swipe(
        dx: CGFloat,
        dy: CGFloat = 0,
        isStowed: Bool = false,
        isExpanded: Bool = false,
        steps: Int = 6
    ) -> IslandStowGesture.Outcome {
        var gesture = IslandStowGesture()
        _ = gesture.consume(sample(.began), isStowed: isStowed, isExpanded: isExpanded)
        for _ in 0..<steps {
            _ = gesture.consume(
                sample(.changed, dx: dx / CGFloat(steps), dy: dy / CGFloat(steps)),
                isStowed: isStowed,
                isExpanded: isExpanded
            )
        }
        return gesture.consume(sample(.ended), isStowed: isStowed, isExpanded: isExpanded)
    }

    @Test("either direction toggles, because there is no direction both Macs agree on")
    func eitherDirectionToggles() {
        // `deltaX`'s sign depends on the trackpad's scroll direction setting, so a directional
        // gesture means opposite things on two machines and no reading of the constant is right for
        // everybody. Toggling needs no such agreement.
        #expect(swipe(dx: -60) == .stow)
        #expect(swipe(dx: 60) == .stow)
        #expect(swipe(dx: -60, isStowed: true) == .unstow)
        #expect(swipe(dx: 60, isStowed: true) == .unstow)
    }

    @Test("an open island ignores the gesture entirely")
    func expandedIsUntouchable() {
        // Stowing is what you do to an island that is in your way; an open one is one you asked for.
        // Swiping across a scrub bar and having the whole thing vanish is the sort of thing that
        // stops people touching the island at all.
        #expect(swipe(dx: -200, isExpanded: true) == .none)
        #expect(swipe(dx: 200, isStowed: true, isExpanded: true) == .none)
    }

    @Test("a small scroll is not a swipe")
    func shortTravelIsIgnored() {
        // The cost of a false positive is high: content vanishing because someone scrolled a page
        // while the pointer crossed the notch is indistinguishable, to them, from a crash.
        #expect(swipe(dx: -8) == .none)
        #expect(swipe(dx: -(IslandStowGesture.commitDistance - 1)) == .none)
        #expect(swipe(dx: -IslandStowGesture.commitDistance) == .stow)
    }

    @Test("a vertical scroll is not this gesture")
    func verticalIsIgnored() {
        // Scrolling a page while the pointer crosses the notch must not put the island away.
        #expect(swipe(dx: -60, dy: -200) == .none)
        #expect(swipe(dx: 10, dy: 200, isStowed: true) == .none)
    }

    @Test("a diagonal swipe resolves to its dominant axis")
    func diagonalPicksAnAxis() {
        // Mostly horizontal still stows; the axis is locked by the first sample that moved, so a
        // little vertical drift does not disqualify a deliberate swipe.
        #expect(swipe(dx: -80, dy: -12) == .stow)
    }

    @Test("momentum cannot commit a gesture the fingers did not")
    func momentumDoesNotCommit() {
        // Inertia is the trackpad's, not the user's. Without this, a hard scroll already judged and
        // refused gets a second, softer chance after the fingers have left.
        var gesture = IslandStowGesture()
        _ = gesture.consume(sample(.began), isStowed: false, isExpanded: false)
        _ = gesture.consume(sample(.changed, dx: -10), isStowed: false, isExpanded: false)
        #expect(gesture.consume(sample(.momentum, dx: -200), isStowed: false, isExpanded: false) == .none)
    }

    @Test("a mouse wheel cannot make a two-finger gesture")
    func discreteIsIgnored() {
        var gesture = IslandStowGesture()
        #expect(gesture.consume(sample(.discrete, dx: -400), isStowed: false, isExpanded: false) == .none)
    }

    @Test("one gesture commits at most once")
    func commitsOnce() {
        var gesture = IslandStowGesture()
        _ = gesture.consume(sample(.began), isStowed: false, isExpanded: false)
        _ = gesture.consume(sample(.changed, dx: -60), isStowed: false, isExpanded: false)
        #expect(gesture.consume(sample(.ended), isStowed: false, isExpanded: false) == .stow)
        // The gesture is over; nothing further from it may act.
        #expect(gesture.consume(sample(.ended), isStowed: false, isExpanded: false) == .none)
    }

    @Test("a canceled gesture still resets, so the next one starts clean")
    func cancelResets() {
        var gesture = IslandStowGesture()
        _ = gesture.consume(sample(.began), isStowed: false, isExpanded: false)
        _ = gesture.consume(sample(.changed, dx: -200), isStowed: false, isExpanded: false)
        _ = gesture.consume(sample(.canceled), isStowed: false, isExpanded: false)
        // A fresh, too-short gesture must not inherit the previous one's travel.
        #expect(swipe(dx: -5) == .none)
    }
}
