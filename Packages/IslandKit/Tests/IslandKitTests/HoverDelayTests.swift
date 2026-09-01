import AppKit
import Testing

@testable import IslandKit

/// The hover delay, at the level a test without a pointer can reach.
///
/// What is testable here is the *latch*: whether a delay is pending, and whether the things that
/// should clear it do. What is not is the timer firing — that needs a real pointer inside a real
/// tracking rect on a real window, which is what `--hover-test` exists for. The split is deliberate
/// rather than a gap: every bug this feature can have that is not "the timer did not fire" is a bug
/// in the latch, and the latch is a pure state machine.
@Suite("Hover delay")
@MainActor
struct HoverDelayTests {

    private func makeView(delay: TimeInterval) -> IslandHitTestView {
        _ = NSApplication.shared
        let view = IslandHitTestView(frame: CGRect(x: 0, y: 0, width: 603, height: 200))
        view.hoverRegion = CGRect(x: 200, y: 0, width: 200, height: 40)
        view.hoverDelay = delay
        return view
    }

    /// The default, and the one the island shipped with: the pointer arriving *is* the peek. The
    /// island is invisible at rest, so this is the only thing that tells a user Isleta exists.
    @Test("with no delay set, the pointer arriving peeks immediately and arms no timer")
    func zeroDelayIsImmediate() {
        let view = makeView(delay: 0)
        var reported: [Bool] = []
        view.onHoverChanged = { reported.append($0) }

        view.mouseEntered(with: NSEvent())

        #expect(view.isHovering)
        #expect(view.isAwaitingHoverDelay == false)
        #expect(reported == [true])
    }

    @Test("with a delay set, the pointer arriving starts a countdown rather than a peek")
    func delayDefersThePeek() {
        let view = makeView(delay: 0.3)
        var reported: [Bool] = []
        view.onHoverChanged = { reported.append($0) }

        view.mouseEntered(with: NSEvent())

        #expect(view.isHovering == false)
        #expect(view.isAwaitingHoverDelay)
        // Nothing announced. A `false` here would be as wrong as a `true`: the island's state has
        // not changed, and reporting that it had would put a no-op transition through `AppDelegate`.
        #expect(reported.isEmpty)
    }

    /// The case that would otherwise leave an island peeking a second after the user left.
    @Test("leaving before the delay elapses cancels it")
    func leavingCancelsTheCountdown() {
        let view = makeView(delay: 0.3)
        var reported: [Bool] = []
        view.onHoverChanged = { reported.append($0) }

        view.mouseEntered(with: NSEvent())
        view.mouseExited(with: NSEvent())

        #expect(view.isAwaitingHoverDelay == false)
        #expect(view.isHovering == false)
        // Still nothing announced, because the island never peeked. A `false` would describe a
        // collapse that did not happen.
        #expect(reported.isEmpty)
    }

    /// `cancelHover` is what a panel rebuild and a display reconfiguration call. A pending countdown
    /// that outlived the panel it was started for would peek an island on a screen that no longer
    /// exists in that shape.
    @Test("canceling hover clears a pending countdown as well as a live peek")
    func cancelHoverClearsThePending() {
        let view = makeView(delay: 0.3)
        view.mouseEntered(with: NSEvent())
        #expect(view.isAwaitingHoverDelay)

        view.cancelHover()
        #expect(view.isAwaitingHoverDelay == false)
        #expect(view.isHovering == false)
    }

    /// Dragging the slider while the pointer is in the notch. Re-arming from the original entry
    /// instant — rather than from now — is what stops a shortened delay being served at the old,
    /// longer length exactly once, which reads as the setting not working.
    @Test("changing the delay mid-countdown re-arms rather than leaving the old one running")
    func changingTheDelayReArms() {
        let view = makeView(delay: 0.5)
        view.mouseEntered(with: NSEvent())
        #expect(view.isAwaitingHoverDelay)

        view.hoverDelay = 0.1
        #expect(view.isAwaitingHoverDelay)
        #expect(view.isHovering == false)
    }

    @Test("changing the delay with the pointer elsewhere arms nothing")
    func changingTheDelayWhileAwayIsInert() {
        let view = makeView(delay: 0)
        view.hoverDelay = 0.4
        #expect(view.isAwaitingHoverDelay == false)
        #expect(view.isHovering == false)
    }

    /// §9: the idle path holds no timer. This is the property that keeps that true — nothing is
    /// armed until the pointer is actually in the region.
    @Test("nothing is pending until the pointer arrives")
    func idleHoldsNothing() {
        let view = makeView(delay: 0.5)
        #expect(view.isAwaitingHoverDelay == false)
        #expect(view.isHovering == false)
    }

    /// `refreshHover` is what the unlock calls, and the distinction from `cancelHover` is that it
    /// *asks*: hover ends up wherever the pointer actually is rather than always false. A view with
    /// no window has no pointer to find — the panelless case, which is also what a torn-down island
    /// looks like — so the answer here is false, reported once, with any countdown dropped.
    @Test("refreshing hover answers from the pointer, not from the last crossing")
    func refreshHoverAsksThePointer() {
        let view = makeView(delay: 0.3)
        var reported: [Bool] = []
        view.mouseEntered(with: NSEvent())
        view.onHoverChanged = { reported.append($0) }

        view.refreshHover()

        #expect(view.isAwaitingHoverDelay == false)
        #expect(view.isHovering == false)
        // Nothing to announce: the countdown never reached a peek, so there is no collapse to
        // report. A `false` here would describe a state change that did not happen.
        #expect(reported.isEmpty)
    }

    /// The stale half of the same call: a hover that was live when the screen went away is dropped
    /// once, rather than being left for a `mouseExited` that is not coming.
    @Test("refreshing hover clears a live peek the pointer has left")
    func refreshHoverClearsAStalePeek() {
        let view = makeView(delay: 0)
        view.mouseEntered(with: NSEvent())
        #expect(view.isHovering)

        var reported: [Bool] = []
        view.onHoverChanged = { reported.append($0) }
        view.refreshHover()

        #expect(view.isHovering == false)
        #expect(reported == [false])
    }
}
