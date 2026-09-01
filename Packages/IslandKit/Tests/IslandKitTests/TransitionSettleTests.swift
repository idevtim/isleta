import Foundation
import Testing
@testable import IslandKit

@Suite("How long the island stays hidden across a space transition")
struct TransitionSettleTests {

    /// The desktop↔desktop shape: drop, then the change 780ms later. The change ends it.
    @Test("a space change after an occlusion drop closes the transition")
    func dropThenChangeCloses() {
        var settle = TransitionSettle()
        settle.begin()
        #expect(settle.delay(after: .occlusionDrop) == TransitionSettle.afterOcclusionDrop)
        #expect(settle.delay(after: .spaceChange) == TransitionSettle.afterClosingChange)
    }

    /// Entering fullscreen posts its change *first* and then runs on for another ~400ms before the
    /// drop. Treating that change as an ending is what put the island back on screen mid-slide.
    @Test("a space change before any drop opens a transition and shortens nothing")
    func changeBeforeDropDoesNotClose() {
        var settle = TransitionSettle()
        settle.begin()
        #expect(settle.delay(after: .spaceChange) == TransitionSettle.whileUnconfirmed)
        #expect(settle.delay(after: .occlusionDrop) == TransitionSettle.afterOcclusionDrop)
    }

    /// A drop after a closing change means the transition never ended — the pair is withdrawn.
    @Test("a later drop reopens a transition a change had closed")
    func dropAfterCloseReopens() {
        var settle = TransitionSettle()
        settle.begin()
        _ = settle.delay(after: .occlusionDrop)
        #expect(settle.delay(after: .spaceChange) == TransitionSettle.afterClosingChange)
        #expect(settle.delay(after: .occlusionDrop) == TransitionSettle.afterOcclusionDrop)
        #expect(settle.delay(after: .spaceChange) == TransitionSettle.afterClosingChange)
    }

    /// Leaving fullscreen: drop, `visible=true` 678ms later, then the change 779ms after that. The
    /// middle signal ends nothing, and the settle expiring across it is what produced the half
    /// bounce — so it must keep the long wait rather than shorten it.
    @Test("being shown again mid-transition keeps the long wait")
    func stillRunningKeepsWaiting() {
        var settle = TransitionSettle()
        settle.begin()
        _ = settle.delay(after: .occlusionDrop)
        #expect(settle.delay(after: .stillRunning) == TransitionSettle.afterOcclusionDrop)
        #expect(settle.delay(after: .spaceChange) == TransitionSettle.afterClosingChange)
    }

    /// `stillRunning` must never close a transition on its own, whatever came before it.
    @Test("being shown again never closes a transition by itself")
    func stillRunningNeverCloses() {
        var settle = TransitionSettle()
        settle.begin()
        #expect(settle.delay(after: .stillRunning) == TransitionSettle.whileUnconfirmed)
        _ = settle.delay(after: .spaceChange)
        #expect(settle.delay(after: .stillRunning) == TransitionSettle.whileUnconfirmed)
    }




    /// A new transition starts from nothing: the previous one's closing pair must not shorten it.
    @Test("beginning again forgets the previous transition")
    func beginResets() {
        var settle = TransitionSettle()
        settle.begin()
        _ = settle.delay(after: .occlusionDrop)
        #expect(settle.delay(after: .spaceChange) == TransitionSettle.afterClosingChange)

        settle.begin()
        #expect(settle.delay(after: .spaceChange) == TransitionSettle.whileUnconfirmed)
    }

    /// Each wait has to clear the gap it is actually waiting on, and those gaps are different sizes.
    /// Sizing the unconfirmed wait like the post-drop one is what made the island restore mid-slide,
    /// get painted into the picture, and be hidden again by the drop that arrived 1792ms after the
    /// space change that opened the transition.
    @Test("each wait clears the gap it is waiting on")
    func delaysClearTheirMeasuredGaps() {
        #expect(TransitionSettle.afterClosingChange < TransitionSettle.afterOcclusionDrop)
        #expect(TransitionSettle.afterOcclusionDrop < TransitionSettle.whileUnconfirmed)
        // drop → closing change, measured 971–997ms.
        #expect(TransitionSettle.afterOcclusionDrop > 1.0)
        // space change → drop, measured up to 1792ms.
        #expect(TransitionSettle.whileUnconfirmed > 1.792)
    }

    /// The wild gap belongs only to the unconfirmed state. Once a drop has confirmed the transition
    /// the remaining wait is the steady one, so a confirmed transition still ends promptly.
    @Test("a confirmed transition waits on the steady gap, not the wild one")
    func confirmedTransitionUsesShorterWait() {
        var settle = TransitionSettle()
        settle.begin()
        #expect(settle.delay(after: .spaceChange) == TransitionSettle.whileUnconfirmed)
        #expect(settle.delay(after: .occlusionDrop) == TransitionSettle.afterOcclusionDrop)
    }
}
