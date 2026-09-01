import IslandActivities
import IslandKit
import IslandUI

/// Joins the swipe to the activity queue (§5). Wiring, like everything else in the app shell.
///
/// The three parts it holds together each live somewhere else on purpose: `IslandHitTestView` knows
/// which events arrive, `SwipeTracker` knows what they mean, and `ActivityStack` knows what a pin
/// does. This class knows only the order to call them in.
///
/// **One tracker for the whole app, not one per screen.** Every island shows the same thing, so a
/// gesture on the laptop and a gesture on an external are the same gesture as far as the queue is
/// concerned — and a tracker per screen would let two of them accumulate travel independently and
/// commit twice. The samples carry a screen so that a future gesture that *is* per-screen has it;
/// this one deliberately ignores it.
@MainActor
final class SwipeController {

    private var tracker = SwipeTracker()
    private var stowGesture = IslandStowGesture()
    private var closeGesture = IslandCloseGesture()
    private let activities: ActivityCoordinator
    private let swipeModels: @MainActor () -> [IslandSwipeModel]
    private let reduceMotion: @MainActor () -> Bool

    /// Reading and writing the stow, handed in rather than reached for: the models live per screen
    /// and the hit region has to move with the outline, both of which are the app shell's business.
    private let isStowed: @MainActor () -> Bool
    private let isExpanded: @MainActor () -> Bool
    private let setStowed: @MainActor (Bool) -> Void

    /// Closes every open island, by the same route Escape and a click elsewhere take.
    private let collapse: @MainActor () -> Void

    /// Whether the open shelf has anything off screen, and how to scroll it.
    ///
    /// **Conditional where the other surfaces are not**, and that asymmetry is the design rather
    /// than an oversight. The drop history and Up Next can own the vertical axis outright because
    /// each carries its own exits — Clear All, the ✕, Escape, a click on a row. The shelf has none
    /// of those: the way out of an open shelf is a click elsewhere, Escape, or the upward flick this
    /// would be taking. So the shelf is handed the axis only when it can actually use it, and a
    /// shelf whose files all fit stays closable with the same gesture as every other island.
    private let canScrollShelf: @MainActor () -> Bool
    private let scrollShelf: @MainActor (IslandScrollSample) -> Void

    /// Whether the open island is showing the Up Next surface, and how to scroll it.
    ///
    /// **Unconditional, unlike the shelf.** The condition on the shelf is there because it carries
    /// no exits of its own, so a shelf whose files all fit has to give the axis back or it cannot be
    /// closed with a flick. This surface carries its own — the ✕
    /// in its header, and the Up Next button in the transport row it is drawn over — so it can own
    /// the axis outright and a short queue is still a queue you cannot get stuck in.
    private let isShowingNowPlayingQueue: @MainActor () -> Bool
    private let scrollNowPlayingQueue: @MainActor (IslandScrollSample) -> Void

    /// The drop history, on the same terms as the two above and for the same reason: it carries its
    /// own exits — Clear All and the ✕ in its header — so it can own the axis outright and a short
    /// history is still one you cannot get stuck in.
    private let isShowingDropHistory: @MainActor () -> Bool

    /// Whether the open island may turn pages at all right now, and how to turn one.
    ///
    /// False while a surface the user drilled into is up — the month grid — because a horizontal
    /// swipe over one of those is a gesture with nowhere to go rather than a request for the next
    /// page. The full-body surfaces that take the *vertical* axis above have already returned by the
    /// time this is asked, so they need no clause here.
    ///
    /// Handed in as closures like everything else in this class: it knows the order to call things
    /// in and nothing about where the page lives or what resizing the island for one costs.
    private let canTurnPage: @MainActor () -> Bool

    /// The three moments of a page drag, which is now a drag rather than a trigger.
    ///
    /// **`beginPageDrag` is called on every tracked sample and must be cheap after the first.** It
    /// is what puts the page being headed toward on screen and starts the island's outline
    /// following the finger toward that page's height; the shell keeps the last direction and
    /// ignores the repeats. It is re-called with the other neighbour when a gesture reverses under
    /// the finger, which is a reversal rather than a new gesture.
    ///
    /// `commitPageDrag` finishes the crossing and swaps the pages when it lands; `settlePageDrag`
    /// springs the offset home when the swipe did not carry. Both tighten the hit region on
    /// completion, which is the other half of the widen `beginPageDrag` performs.
    private let beginPageDrag: @MainActor (Int) -> Void
    private let commitPageDrag: @MainActor (Int) -> Void
    private let settlePageDrag: @MainActor () -> Void

    /// Publishes which way a turn is about to travel, from the finger rather than from the commit.
    ///
    /// **Called while the gesture is still tracking**, and that timing is the point: the departing
    /// page's transition is built from its *last* render, so a direction written at commit reaches
    /// the arriving page only. Publishing it as soon as the finger has a direction means the render
    /// that will supply the removal already carries it. See `IslandPageModel.lastTurn`.
    private let setTurnDirection: @MainActor (Int) -> Void

    private let scrollDropHistory: @MainActor (IslandScrollSample) -> Void

    /// Diagnostics for the debug overlay and the self-test: what the last sample did.
    private(set) var lastOutcome: SwipeTracker.Outcome = .ignored
    private(set) var sampleCount = 0

    init(
        activities: ActivityCoordinator,
        swipeModels: @escaping @MainActor () -> [IslandSwipeModel],
        reduceMotion: @escaping @MainActor () -> Bool,
        isStowed: @escaping @MainActor () -> Bool,
        isExpanded: @escaping @MainActor () -> Bool,
        setStowed: @escaping @MainActor (Bool) -> Void,
        collapse: @escaping @MainActor () -> Void,
        canScrollShelf: @escaping @MainActor () -> Bool = { false },
        scrollShelf: @escaping @MainActor (IslandScrollSample) -> Void = { _ in },
        isShowingNowPlayingQueue: @escaping @MainActor () -> Bool = { false },
        scrollNowPlayingQueue: @escaping @MainActor (IslandScrollSample) -> Void = { _ in },
        isShowingDropHistory: @escaping @MainActor () -> Bool = { false },
        canTurnPage: @escaping @MainActor () -> Bool = { false },
        beginPageDrag: @escaping @MainActor (Int) -> Void = { _ in },
        commitPageDrag: @escaping @MainActor (Int) -> Void = { _ in },
        settlePageDrag: @escaping @MainActor () -> Void = {},
        setTurnDirection: @escaping @MainActor (Int) -> Void = { _ in },
        scrollDropHistory: @escaping @MainActor (IslandScrollSample) -> Void = { _ in }
    ) {
        self.activities = activities
        self.swipeModels = swipeModels
        self.reduceMotion = reduceMotion
        self.isStowed = isStowed
        self.isExpanded = isExpanded
        self.setStowed = setStowed
        self.collapse = collapse
        self.canScrollShelf = canScrollShelf
        self.scrollShelf = scrollShelf
        self.isShowingNowPlayingQueue = isShowingNowPlayingQueue
        self.scrollNowPlayingQueue = scrollNowPlayingQueue
        self.isShowingDropHistory = isShowingDropHistory
        self.canTurnPage = canTurnPage
        self.beginPageDrag = beginPageDrag
        self.commitPageDrag = commitPageDrag
        self.settlePageDrag = settlePageDrag
        self.setTurnDirection = setTurnDirection
        self.scrollDropHistory = scrollDropHistory
    }

    func handle(_ sample: IslandScrollSample) {
        sampleCount += 1
        noteInteractionIfBoundary(sample)

        let expanded = isExpanded()

        // The three gestures are disjoint by construction and each still sees every sample, because
        // each has to watch the early ones to lock its own axis. `SwipeTracker` returns `.ignored`
        // for anything it has locked as vertical; `IslandStowGesture` does the same for anything
        // vertical *and* ignores an open island; `IslandCloseGesture` ignores anything horizontal
        // and every island that is not open. So no flick can ever be two answers.
        switch stowGesture.consume(sample, isStowed: isStowed(), isExpanded: expanded) {
        case .stow: setStowed(true)
        case .unstow: setStowed(false)
        case .none: break
        }

        // **The drop history owns the vertical axis while it is up.** A flick up over a list of
        // rows is a scroll on every other surface on the machine, and asking a gesture recognizer to
        // decide whether this one meant "next row" or "close the island" would be the arbitration
        // the other two gestures were designed to avoid rather than to win. So the surface is handed
        // the sample and the close gesture is not offered it at all — which it can afford because it
        // carries its own exits: Clear All, the ✕, Escape, and a click on a row.
        //
        // `closeGesture` is still *reset* by the sample rather than skipped outright: a gesture
        // half-accumulated before the surface opened must not commit against the island the user is
        // now reading in.
        //
        // Above Up Next in this chain because it is drawn over it — the same order `IslandRootView`
        // draws them in and `expandedContentHeightForStage` sizes them in, and all three have to
        // agree or the island is sized for one surface and scrolling another.
        if isShowingDropHistory() {
            _ = closeGesture.consume(sample, isExpanded: false)
            scrollDropHistory(sample)
            return
        }

        // **The Up Next surface owns the vertical axis while it is up.** Same reasoning as the
        // list above, including the clause that lets it be unconditional: the surface carries its
        // own way out. Below the list in this chain because the list is drawn over it — asking for
        // the list is asking to leave whatever surface was up, so while both flags are somehow true
        // the samples belong to the one the user can see.
        //
        // `closeGesture` is reset by the sample rather than skipped outright, for the reason it is
        // above: a gesture half-accumulated before the surface opened must not commit against the
        // island the user is now reading in.
        if isShowingNowPlayingQueue() {
            _ = closeGesture.consume(sample, isExpanded: false)
            scrollNowPlayingQueue(sample)
            return
        }

        // **The open shelf owns the vertical axis while it has somewhere to scroll to**, and only
        // then. Same reasoning as the list above with one clause removed: a flick over a grid of
        // files is a scroll everywhere else on the machine, so asking a recognizer whether this one
        // meant "next row" or "close the island" would be the arbitration the three gestures are
        // designed to avoid rather than to win. The clause that has to stay is the condition — the
        // shelf carries no exits of its own, so a shelf whose files all fit gives the axis back and
        // stays closable with a flick. See `ShelfController.canScroll`.
        if expanded, canScrollShelf() {
            _ = closeGesture.consume(sample, isExpanded: false)
            scrollShelf(sample)
            return
        }

        // Swipe up on an open island: the same thing clicking it would do. Deliberately routed
        // through the shell's own collapse rather than setting the models directly — an island
        // closed by a gesture has to give back the Escape hot key and the outside-click monitor
        // exactly as one closed by a click does.
        switch closeGesture.consume(sample, isExpanded: expanded) {
        case .close: collapse()
        case .none: break
        }

        // **The horizontal axis on an open island turns pages** (§5).
        //
        // This is the tracker's second life. It drove swipe-to-cycle, which was disconnected because
        // it and stowing wanted the same axis and one gesture cannot mean "show me the next
        // activity" and "put them all away" and be predictable about which. The note left at the
        // time said the physics were kept because they were "a working answer to a question that may
        // come back with a different input" — and the pages are that question: the axis is free here
        // because `IslandStowGesture` ignores an open island outright (its first `guard`), so there
        // is nothing left to arbitrate against.
        //
        // Nothing to cycle *through* on a closed island, so the whole thing is gated on `expanded`.
        guard expanded, canTurnPage() else { return }

        // **Both directions are always open, because the pages wrap.** `SwipeBounds` exists to tell
        // the tracker when to rubber-band instead of travelling, and a three-page carousel that
        // stopped dead at the weather would make the user learn which end they were at. What is left
        // of the resistance is the un-carried swipe, which still settles back on `Motion.nudge`.
        let outcome = tracker.consume(sample, bounds: SwipeBounds(canAdvance: true, canRetreat: true))
        lastOutcome = outcome

        switch outcome {
        case .ignored:
            break
        case .tracking(let offset):
            // **The direction first, then the offset, and the order is load-bearing.** A negative
            // offset is content pushed left, which is the next page arriving from the right —
            // forward. `beginPageDrag` is what puts that page on screen and hands the island the
            // shape it is heading toward, so tracking an offset before it would slide the strip a
            // frame before there was anything either side of it to slide.
            //
            // Both are called on every sample rather than once at the start. The gesture can
            // reverse under the finger, and the shell ignores a direction it is already armed for
            // — it arms against the direction the *content* is displaced in rather than this one,
            // which is how a gesture that starts on the tail of the last turn stays honest.
            if offset != 0 {
                let step = offset < 0 ? 1 : -1
                setTurnDirection(step)
                beginPageDrag(step)
            }
            // Deliberately outside any animation transaction — see `SwipeTracker.Outcome.tracking`:
            // animating a tracked value is what makes a drag feel like it is being pulled through
            // treacle, because the spring is always interpolating towards a position the finger has
            // already left. The island's *outline* follows on the same terms, because
            // `IslandScreenModel.metrics` reads this offset rather than being animated toward it.
            for model in swipeModels() { model.track(offset) }
        case .settle:
            settlePageDrag()
        case .commit(let steps):
            // **The page swaps here and now, and the content finishes crossing to it afterwards.**
            // Not a trigger — the surface under the fingers is already most of the way across, and
            // what is left is a tail travelling into a detent. The swap moves nothing on screen
            // because the offset is re-expressed against the new page rather than travelling toward
            // it, which is also what lets the *next* swipe start before this one has settled. See
            // `AppDelegate.commitPageDrag` and `IslandSwipeModel.landTurn`.
            commitPageDrag(steps)
        }
    }

    /// Restarts the pin's hold at the edges of a gesture, and only there.
    ///
    /// Not on every sample, which is the obvious way to write "measured from the last interaction"
    /// and is wrong twice over: a trackpad delivers ~120 samples a second, and every one of them
    /// would move the pin's deadline — so `rescheduleExpiry` would cancel and rebuild the
    /// coordinator's sleep 120 times a second for the length of the gesture. Three calls per
    /// gesture buy exactly the same 8s of hold.
    private func noteInteractionIfBoundary(_ sample: IslandScrollSample) {
        switch sample.phase {
        case .began, .ended, .canceled, .discrete:
            activities.noteInteraction()
        case .changed, .momentum, .momentumEnded:
            break
        }
    }
}
