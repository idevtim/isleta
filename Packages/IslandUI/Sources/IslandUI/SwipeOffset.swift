import IslandKit
import Observation
import SwiftUI

/// How far the island's content is currently displaced by a swipe in progress (§5).
///
/// Its own object rather than a property on `IslandScreenModel`, and the separation is not
/// bookkeeping. Everything on `IslandScreenModel` is an *input to the island's shape* — hovering,
/// expansion, what is on stage — and the shape is what `islandPath` has to track. The swipe offset
/// was for a long time the one piece of live motion here that changed **nothing** about the
/// island's outline: the content slid under a stationary mask and the panel's alpha, the window
/// server's event shape and the hit region were all exactly as they were.
///
/// ## That stopped being true on 2026-08-28, deliberately, and only for the pages
///
/// A page carousel that drags the content a full page while the outline stands still slides a 278pt
/// weather page through a 144pt music-shaped window. So `incoming` and `progress` were added, and
/// `IslandScreenModel.metrics` now interpolates the outline between the page being left and the one
/// being dragged toward — the island's bottom edge follows the finger.
///
/// **`islandPath` still tracks a settled shape at rest, and the rule it appears to break is intact
/// where it was written.** That rule is about a height following live *content* — a track title
/// arriving, an event appearing — under a pointer that is trying to click something. This is a
/// height following the user's own hand, during a gesture in which they are demonstrably not
/// clicking, and it is covered the way every other moving outline in this app is: the shell widens
/// the hit region to the union of both pages before the gesture and tightens it when the offset
/// lands. See `SwipeController` for that pair.
///
/// The offset itself is still applied *inside* the mask, so nothing here moves opaque pixels out
/// over the menu bar.
@MainActor
@Observable
public final class IslandSwipeModel {

    /// Points. Negative means the content has been pushed left and the next activity is arriving
    /// from the right.
    ///
    /// **The sum of two things, and the split is what lets one gesture start before the last one
    /// has finished.** `landing` is the tail of a committed turn still easing into its detent;
    /// `drag` is where the finger has it. A new swipe writes `drag` only, so the tail goes on
    /// decaying underneath it exactly as it was — which is the difference between picking a moving
    /// page up and having it snap to the grid the instant a finger touches it.
    public var offset: CGFloat { landing + drag }

    /// The part of the offset still travelling home from a committed turn, or from a swipe that did
    /// not carry. Animated; zero at rest, which is almost always.
    private(set) var landing: CGFloat = 0

    /// The part of the offset the finger is holding. Never animated — see `track`.
    private(set) var drag: CGFloat = 0

    /// Bumped whenever a gesture re-arms the carousel, so a completion left over from the turn
    /// before it cannot tear down the gesture that interrupted it.
    ///
    /// **This is the whole of what made a quick second swipe stop dead on the page the first one
    /// was still arriving at.** The completions here tear the carousel down — they take the
    /// neighbouring pages off screen and tighten the hit region — and a spring interrupted part way
    /// still delivers one. So the second gesture armed the carousel and the first gesture's
    /// completion immediately unarmed it, leaving a live drag with nothing either side of it to
    /// drag to. Whoever armed the carousel last is the only one allowed to take it down.
    @ObservationIgnored private var generation = 0

    /// One page, in points — how far the content has to travel for a turn to be complete.
    ///
    /// Set by the shell from `IslandLayout.expandedBodySize.width`, and zero until it is. Zero
    /// disables everything below rather than dividing by it: a model nobody configured is a model
    /// with no carousel, which is the right answer for a preview and for the flanks.
    public var pageSpan: CGFloat = 0

    /// The shape of the page the finger is currently heading toward, or nil when it is heading
    /// nowhere.
    ///
    /// **This is what lets the island's outline follow the drag.** The three pages are different
    /// heights — 144, 153–185 and 278 — so a carousel that dragged the *content* across a
    /// stationary outline would slide a 278pt page through a 144pt window and then pop. Held here,
    /// beside the offset it is interpolated against, so `IslandScreenModel.metrics` can answer
    /// "what shape is the island right now" from one place.
    ///
    /// Set by the shell, which is the only layer that can compute another page's metrics for this
    /// screen. Cleared when the gesture is over.
    public var incoming: IslandShapeMetrics?

    /// Whether a page gesture is live — from the first tracked sample until the settle has landed.
    ///
    /// **What it actually gates is whether the two neighbouring pages are rendered at all.** A
    /// carousel needs them on screen to slide; the island at rest emphatically does not, and §9 is
    /// why — the music page owns a `CALayer` equaliser and the weather page a precipitation view,
    /// and drawing all three whenever the island is open would spend the idle budget on two
    /// surfaces nobody is looking at. So they exist for the length of a gesture and not one frame
    /// longer.
    public private(set) var isPaging = false

    /// How far through the turn the finger is: `-1`…`1`, signed the way `offset` is.
    ///
    /// Clamped, because `offset` can exceed a page — the band past the edge is deliberate and the
    /// island must not keep growing past the page it is arriving at.
    public var progress: CGFloat {
        guard pageSpan > 0 else { return 0 }
        return max(-1, min(1, offset / pageSpan))
    }

    public init() {}

    /// A page gesture has started, heading toward `incoming`.
    ///
    /// Idempotent within a gesture: the direction can reverse under the finger, and the shell
    /// re-arms this with the other neighbour rather than ending and restarting the gesture.
    public func beginPaging(toward incoming: IslandShapeMetrics?, span: CGFloat) {
        generation &+= 1
        pageSpan = span
        self.incoming = incoming
        isPaging = true
    }

    /// The gesture is over and the offset is home. Takes the neighbours off screen.
    public func endPaging() {
        isPaging = false
        incoming = nil
    }

    /// Puts the content back at the page it is on, with no animation and no carousel around it.
    ///
    /// For the island closing, and for anything else that has to leave the swipe with no opinion.
    /// A dropped completion (see `generation`) can otherwise leave a tail of `landing` behind on a
    /// surface nobody is dragging any more.
    public func clearOffsetWithoutAnimation() {
        withTransaction(Transaction(animation: nil)) {
            landing = 0
            drag = 0
        }
    }

    /// Finishes a committed turn, against a page that has **already swapped underneath**.
    ///
    /// ## The swap happens first now, and that is the fix for a quick second swipe
    ///
    /// Until 2026-08-28 this travelled the last of the page and swapped the identities in the
    /// completion, so for the length of the spring `IslandPageModel.current` still named the page
    /// being left. A second swipe starting in that window therefore computed its neighbours from
    /// the wrong page, and the first turn's completion then landed on top of it — zeroing a live
    /// finger offset and taking the carousel down mid-gesture. What the user saw was the island
    /// stopping on the page it was animating into and refusing the next one.
    ///
    /// So the shell swaps the page at the moment of commit and calls this, which **re-expresses the
    /// offset against the new page rather than continuing to travel toward it**. Nothing moves on
    /// screen: the content was `offset` from the old page and is `offset - destination` from the
    /// new one, which is the same pixels described from the other end. `incoming` becomes the page
    /// being *left* for the same reason — `IslandScreenModel` lerps the outline from the current
    /// page toward it, and lerping the old shape at `1 - progress` is the identical height it was
    /// lerping the new shape at `progress`. Both are continuous across the swap by construction.
    ///
    /// What is left to animate is `landing`, from wherever the finger stopped to zero, on
    /// `Motion.pageTurn` — a page settling into a detent it is already most of the way inside, with
    /// no overshoot to correct. It was `Motion.expand` and its bounce was reported as the page
    /// sliding a few points past centre and coming back.
    public func landTurn(
        by destination: CGFloat,
        incoming: IslandShapeMetrics?,
        reduceMotion: Bool,
        completion: @escaping @MainActor () -> Void = {}
    ) {
        // Un-animated and in one transaction: this is a change of description, not a movement, and
        // a spring on it would animate from a value to itself.
        withTransaction(Transaction(animation: nil)) {
            landing = Self.rebased(offset: offset, by: destination)
            drag = 0
            self.incoming = incoming
        }
        animate(to: 0, on: Motion.pageTurn, reduceMotion: reduceMotion, completion: completion)
    }

    /// Where the content sits once the page has stepped under it: the same pixels, measured from
    /// the other end of the step.
    ///
    /// Pure and `static` so that the one thing about the swap that can actually be wrong is pinned
    /// by a test. The spring around it cannot be — `withAnimation` writes its final value
    /// immediately and only the *view* interpolates, so a headless test can never observe the tail
    /// travelling. That half is what `SwipeSelfTest` walks on a real panel.
    static func rebased(offset: CGFloat, by destination: CGFloat) -> CGFloat {
        offset - destination
    }

    /// Follows the finger. Deliberately outside any animation transaction — see
    /// `SwipeTracker.Outcome.tracking`.
    ///
    /// **Writes `drag` alone, so a turn still easing home keeps easing.** A gesture that starts
    /// during the tail of the last one adds to a moving surface rather than seizing it; the two
    /// resolve within a few frames because `landing` is on its way to zero either way.
    public func track(_ offset: CGFloat) {
        drag = offset
    }

    /// Releases the band: a swipe that did not carry, or one that had nowhere to go.
    ///
    /// **`Motion.pageTurn`, which is the same spring `landTurn` lands on**, and that is the point —
    /// a swipe that carries and a swipe that does not are one gesture with two endings, and giving
    /// them different curves made the failure look like a different gesture from the success.
    ///
    /// It was `Motion.nudge` while the travel was 56pt, where the overshoot *was* the message, then
    /// `Motion.expand` once the travel became a page. Both bounce, and a page is a detent: the
    /// island visibly sprang past the page it was returning to and came back, which reads as the
    /// carousel missing its mark rather than as a swipe being abandoned.
    public func settle(reduceMotion: Bool, completion: @escaping @MainActor () -> Void = {}) {
        // The finger has left, so everything it was holding becomes part of what is travelling home
        // — otherwise the spring would carry `landing` to zero and leave `drag` standing.
        withTransaction(Transaction(animation: nil)) {
            landing = offset
            drag = 0
        }
        animate(to: 0, on: Motion.pageTurn, reduceMotion: reduceMotion, completion: completion)
    }

    /// Springs `landing` to `value`, and reports back only if the carousel is still the one this
    /// animation was started for. See `generation`.
    private func animate(
        to value: CGFloat,
        on token: Animation,
        reduceMotion: Bool,
        completion: @escaping @MainActor () -> Void = {}
    ) {
        guard landing != value else { completion(); return }
        let started = generation
        withAnimation(Motion.respectingReduceMotion(token, reduceMotion: reduceMotion)) {
            landing = value
        } completion: { [weak self] in
            guard let self, self.generation == started else { return }
            completion()
        }
    }
}

/// Slides the island's content by the live swipe offset.
///
/// Applied *inside* the mask in `IslandRootView`, which is what makes the swipe cost nothing in hit
/// testing: the content moves, the island outline does not, so `islandPath` still tracks the drawn
/// shape and the panel's alpha is unchanged. Applying it outside the mask would drag opaque pixels
/// across the menu bar and start swallowing clicks meant for the app underneath.
struct SwipeOffsetEffect: ViewModifier {

    let swipe: IslandSwipeModel

    func body(content: Content) -> some View {
        content.offset(x: swipe.offset)
    }
}
