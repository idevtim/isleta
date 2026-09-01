import CoreGraphics
import IslandKit
import Testing

@testable import IslandUI

@Suite("Swiping the open island closed")
struct CloseGestureTests {

    private func sample(
        _ phase: IslandScrollSample.Phase,
        dx: CGFloat = 0,
        dy: CGFloat = 0,
        isPrecise: Bool = true,
        inverted: Bool = true
    ) -> IslandScrollSample {
        IslandScrollSample(
            phase: phase,
            deltaX: dx,
            deltaY: dy,
            isPrecise: isPrecise,
            timestamp: 0,
            isDirectionInverted: inverted
        )
    }

    /// Drives a whole gesture and returns what it decided.
    ///
    /// - Parameter up: how far the *fingers* travel up the glass, in points. The sign AppKit reports
    ///   for that depends on the user's scrolling setting, which is the whole point of the
    ///   `inverted` parameter — both spellings of the same physical flick are tested below.
    private func swipe(
        up: CGFloat,
        dx: CGFloat = 0,
        isExpanded: Bool = true,
        inverted: Bool = true,
        steps: Int = 6,
        phases: [IslandScrollSample.Phase] = [.ended]
    ) -> IslandCloseGesture.Outcome {
        var gesture = IslandCloseGesture()
        let deltaY = inverted ? -up : up
        _ = gesture.consume(sample(.began, inverted: inverted), isExpanded: isExpanded)
        for _ in 0..<steps {
            _ = gesture.consume(
                sample(.changed, dx: dx / CGFloat(steps), dy: deltaY / CGFloat(steps), inverted: inverted),
                isExpanded: isExpanded
            )
        }
        var outcome = IslandCloseGesture.Outcome.none
        for phase in phases {
            outcome = gesture.consume(sample(phase, inverted: inverted), isExpanded: isExpanded)
        }
        return outcome
    }

    /// The gesture the user asked for.
    @Test("two fingers up on an open island closes it")
    func upCloses() {
        #expect(swipe(up: 60) == .close)
    }

    /// The thing `isDirectionInverted` exists for. With "natural" scrolling on, a finger moving up
    /// reports a negative delta; with it off, the same finger reports positive. Both are the same
    /// flick and both must close the island, or the gesture works on one Mac and not the next.
    @Test("the same physical flick closes it whichever way scrolling is set", arguments: [true, false])
    func scrollDirectionSettingDoesNotMatter(inverted: Bool) {
        #expect(swipe(up: 60, inverted: inverted) == .close)
        #expect(swipe(up: -60, inverted: inverted) == .none)
    }

    /// Not a toggle, so it has a direction — down would have to mean "open", and the island already
    /// is.
    @Test("swiping down does nothing")
    func downIsIgnored() {
        #expect(swipe(up: -80) == .none)
    }

    @Test("a collapsed island ignores it entirely")
    func collapsedIsUntouched() {
        // There is nothing to close, and the same fingers on the same glass are how
        // `IslandStowGesture` is offered a stow.
        #expect(swipe(up: 200, isExpanded: false) == .none)
    }

    @Test("a small scroll is not a swipe")
    func shortTravelIsIgnored() {
        #expect(swipe(up: IslandCloseGesture.commitDistance - 1) == .none)
        #expect(swipe(up: IslandCloseGesture.commitDistance) == .close)
    }

    /// The axis lock is what keeps the three gestures disjoint: a horizontal flick belongs to
    /// `IslandStowGesture`, which will refuse it too while the island is open — but this one must
    /// not answer for it either.
    @Test("a mostly horizontal flick is not this gesture")
    func horizontalIsIgnored() {
        #expect(swipe(up: 40, dx: 120) == .none)
    }

    /// Momentum is the trackpad's inertia, not the user's intent. A flick already judged and
    /// refused must not get a second chance once the fingers have left the glass.
    @Test("momentum after a refused swipe does not close it")
    func momentumIsIgnored() {
        #expect(swipe(up: 10, phases: [.ended, .momentum, .momentumEnded]) == .none)
    }

    /// A wheel has no way to say "two fingers", and a wheel notch over an open island is a scroll
    /// aimed at whatever is behind it.
    @Test("a mouse wheel cannot close the island")
    func wheelIsIgnored() {
        var gesture = IslandCloseGesture()
        #expect(gesture.consume(sample(.discrete, dy: -50, isPrecise: false), isExpanded: true) == .none)
    }

    /// One gesture, one answer: the fingers coming back down after a commit must not re-arm it.
    @Test("a gesture commits at most once")
    func commitsOnce() {
        var gesture = IslandCloseGesture()
        _ = gesture.consume(sample(.began), isExpanded: true)
        for _ in 0..<6 { _ = gesture.consume(sample(.changed, dy: -20), isExpanded: true) }
        #expect(gesture.consume(sample(.ended), isExpanded: true) == .close)
        #expect(gesture.consume(sample(.ended), isExpanded: true) == .none)
    }
}
