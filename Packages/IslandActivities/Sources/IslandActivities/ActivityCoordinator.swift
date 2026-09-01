import Foundation
import Observation

/// Owns the activity stack for the whole app and the single sleep that expires it.
///
/// **Main-actor isolated, not an actor — this deviates from the package README, deliberately.**
/// The README calls for `actor ActivityCoordinator`, which is the right instinct for something that
/// takes input from background sources. It is the wrong answer here for three reasons:
///
/// 1. Everything downstream is main-actor UI. `IslandScreenModel` is `@MainActor @Observable`, and
///    the presented activity is read from inside a SwiftUI `body`. From an `actor`, that read is an
///    `await`, so the view can never see the current activity synchronously — it can only mirror a
///    copy, which means two sources of truth for what is on the island and a window in which they
///    disagree. That is the exact failure `IslandPresentation` exists to prevent at the other end.
/// 2. §6.2's ordering has no slack. The container leads the content by 40ms — a little over two
///    frames. An actor hop puts an unbounded number of frames between "the coordinator decided" and
///    "the view knows", and `withAnimation` cannot span it, so the morph and the content swap stop
///    being one animation.
/// 3. There is nothing to protect. The stack holds single digits of entries and every mutation is a
///    sort of that array; moving it off the main thread buys nothing and costs a hop per keystroke
///    of the volume key.
///
/// The concurrency requirement that made `actor` attractive is met anyway: sources produce
/// `Sendable` value types off the main actor and hop once to hand them over, which is one hop
/// instead of one per read.
///
/// The coordinator holds no policy. Ordering, preemption, ties and expiry all live in
/// `ActivityStack`, which is a pure value type — this class supplies `now`, schedules the sleep,
/// and publishes changes.
@MainActor
@Observable
public final class ActivityCoordinator {

    /// The stack itself, exposed so IslandUI can observe it and the debug overlay can enumerate it.
    /// Mutated only through this class, so the scheduled expiry can never fall out of step with it.
    public private(set) var stack = ActivityStack()

    /// Called after every change that the island would have to redraw for, on the main actor.
    ///
    /// A callback rather than only observation because the app shell has to pick a *motion token*
    /// from the change (§6.2), and observation tells you that something changed without telling you
    /// what kind of change it was.
    @ObservationIgnored
    public var onChange: ((ActivityChange) -> Void)?

    /// Injected so expiry is testable without waiting for a clock. Reads `Date()` in production.
    @ObservationIgnored
    private let now: @Sendable () -> Date

    /// The one outstanding sleep. Never more than one, and none at all while nothing can expire —
    /// see `rescheduleExpiry`.
    @ObservationIgnored
    private var expiryTask: Task<Void, Never>?

    /// The deadline `expiryTask` was started for, so an update that does not move the earliest
    /// deadline does not tear the sleep down and build it again.
    @ObservationIgnored
    private var scheduledDeadline: Date?

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    // MARK: - Reading

    /// The one activity the island is showing, or nil.
    /// The user's dwell multiplier, forwarded to the stack. See `ActivityStack.dwellScale` for why
    /// it is applied at insertion and why changing it leaves outstanding deadlines alone.
    ///
    /// Assigned rather than passed to `init` because the app shell builds this coordinator before it
    /// reads the settings store, and a configuration change has to be able to reach it afterwards —
    /// the same shape every other setting takes through `AppDelegate.apply`.
    public var dwellScale: Double {
        get { stack.dwellScale }
        set { stack.dwellScale = newValue }
    }

    public var presented: (any IslandActivity)? { stack.presented }

    /// Everything waiting behind it, in the order it would be presented.
    public var queued: [any IslandActivity] { stack.queued }

    /// The pair the island draws at rest — see `ActivityStage`. Nil on an empty stack.
    public var stage: ActivityStage? { stack.stage }

    /// Everything outstanding as switcher chips, in a stable order. See `ActivityStack.chips`.
    public var chips: [ActivityChip] { stack.chips }

    public var isEmpty: Bool { stack.isEmpty }

    /// The next instant anything on the stack goes stale, or nil if nothing does.
    public var nextExpiry: Date? { stack.nextExpiry }

    /// The next instant *anything* wants the stack looked at — an activity expiring or a pin
    /// lapsing. Nil is the condition under which no timer exists at all.
    public var nextDeadline: Date? { stack.nextDeadline }

    /// What the user's last swipe is holding on stage, if it is still holding.
    public var pinned: ActivityID? { stack.pin?.id }

    /// Everything outstanding in the order it would be presented had nobody swiped. What the swipe
    /// walks, and what the island's rubber-banding asks about its ends.
    public var cycleOrder: [ActivityID] { stack.cycleOrder }

    /// Whether a swipe in this direction has anywhere to go, or should resist and spring back (§5).
    public func canCycle(by steps: Int) -> Bool { stack.canCycle(by: steps) }

    /// Test seam for §9's "no polling when idle". Not public: the outside world has no business
    /// knowing whether a sleep is outstanding, but the test suite has to be able to prove that an
    /// idle coordinator holds nothing at all rather than a task that wakes up to find no work.
    var hasScheduledExpiry: Bool { expiryTask != nil }

    // MARK: - Mutating

    /// Presents an activity, or updates one already outstanding under the same id.
    @discardableResult
    public func present(_ activity: any IslandActivity) -> ActivityChange {
        apply { $0.insert(activity, at: self.now()) }
    }

    @discardableResult
    public func dismiss(_ id: ActivityID) -> ActivityChange {
        apply { $0.remove(id) }
    }

    @discardableResult
    public func dismissAll() -> ActivityChange {
        apply { $0.removeAll() }
    }

    /// Drops everything that has expired as of `instant`, defaulting to now — and retires a pin
    /// that has lapsed by then, which is the island's second reason to move on its own (§5). It
    /// arrives at the app shell as an ordinary `ActivityChange`, so nothing downstream has to know
    /// a pin exists to animate its departure on the right token.
    ///
    /// Public because two callers outside this file need it. The scheduled sleep is one. The other
    /// is waking from system sleep: `Task.sleep` runs on the continuous clock, so a Mac that slept
    /// through a deadline resumes with the sleep already elapsed and this fires immediately — but
    /// the app shell should call it from `didWakeNotification` anyway rather than trusting the
    /// resume path, because a stale HUD on wake is exactly the kind of thing a user reports.
    @discardableResult
    public func refresh(at instant: Date? = nil) -> ActivityChange {
        apply { $0.removeExpired(at: instant ?? self.now()) }
    }

    // MARK: - Cycling

    /// Moves the island `steps` along the queue and pins it there (§5). What a swipe calls.
    ///
    /// Returns `.none` when there is nothing that way, which is the caller's cue to rubber-band.
    @discardableResult
    public func cycle(by steps: Int) -> ActivityChange {
        apply { $0.cycle(by: steps, at: self.now()) }
    }

    @discardableResult
    /// - Parameter hold: how long the pin survives without interaction. Defaults to the swipe's
    ///   eight seconds; a deliberate pick from the switcher row asks for longer, because a swipe is
    ///   made in passing and a click is a statement about what the user wants to look at.
    public func pin(
        _ id: ActivityID,
        holding hold: Duration = ActivityStack.defaultPinHold
    ) -> ActivityChange {
        apply { $0.pin(id, at: self.now(), holding: hold) }
    }

    @discardableResult
    public func unpin() -> ActivityChange {
        apply { $0.unpin() }
    }

    /// Restarts the pin's hold, because the user just did something to the island.
    ///
    /// Separate from `cycle` so hovering and clicking count as interaction too — PROGRESS.md says
    /// the eight seconds runs from the last interaction, not from the swipe.
    ///
    /// **This is the call that must not cost anything when nothing is pinned**, because the app
    /// shell makes it from every hover and every click. It cannot: with no pin, `refreshPin` writes
    /// nothing, `nextDeadline` is unmoved, and `rescheduleExpiry` returns at its first `guard`
    /// without touching the task. An idle Isleta with the pointer wandering over the notch still
    /// holds no timer at all.
    public func noteInteraction() {
        stack.refreshPin(at: now())
        rescheduleExpiry()
    }

    // MARK: - The pointer

    /// Whether the pointer is resting on an island. See `ActivityStack.isPointerOverIsland`.
    public var isPointerOverIsland: Bool { stack.isPointerOverIsland }

    /// The pointer arrived on an island, or left the last one it was on.
    ///
    /// One flag for the whole app rather than one per screen, because there is one pointer: the app
    /// shell tracks which islands it is on (`AppDelegate.hoveredScreens`) and hands this the answer
    /// to "any of them". Giving the stack a set of display ids would put a `CGDirectDisplayID` in a
    /// package that has no business knowing what a display is.
    ///
    /// The two directions are not symmetric, and neither may be dropped:
    ///
    /// - **Arriving** reschedules, because the entry now being held drops out of `nextExpiry` — the
    ///   sleep that was going to remove it has to be torn down, or it fires into a `removeExpired`
    ///   that holds the entry and immediately reschedules the same past deadline. That is the tight
    ///   loop `ActivityStack.nextExpiry` describes.
    /// - **Leaving** refreshes, because a deadline that passed under the pointer has no sleep left
    ///   to fire for it. Without this, an expired notification would sit on the island until the
    ///   *next* activity happened to arrive.
    public func setPointerOverIsland(_ over: Bool) {
        guard stack.isPointerOverIsland != over else { return }
        // **Before the flag is cleared**, because `heldEntry` is defined in terms of it — and
        // because the entry has to get its dwell back before `refresh()` runs, or the sweep this is
        // written to prevent happens in the same call. See `ActivityStack.releasePointerHold`.
        if !over { stack.releasePointerHold(at: now()) }
        stack.isPointerOverIsland = over
        if over {
            rescheduleExpiry()
        } else {
            refresh()
        }
    }

    // MARK: - Scheduling

    private func apply(_ mutation: (inout ActivityStack) -> ActivityChange) -> ActivityChange {
        let change = mutation(&stack)
        rescheduleExpiry()
        if change != .none { onChange?(change) }
        return change
    }

    /// Keeps exactly one sleep outstanding, for the earliest deadline on the stack.
    ///
    /// The two properties §9 asks for are both here. **No timer when idle:** an empty stack, or a
    /// stack holding only `.never` activities and carrying no pin, has no `nextDeadline`, so there
    /// is no task — the idle path costs nothing at all, which is what a repeating timer that checks
    /// for expiries could never manage. **No churn when busy:** a Now Playing update arrives on
    /// every scrub, and each one would otherwise cancel and rebuild a task for a deadline that did
    /// not move, so the existing sleep is reused whenever the earliest deadline is unchanged.
    ///
    /// **Milestone 2 put a second deadline on the stack and did not add a second task.** A pin
    /// lapsing is one more candidate inside `ActivityStack.nextDeadline`'s `min`, so it reaches this
    /// method as a date like any other — the pin does not know it is a pin by the time it gets here,
    /// and there is nothing to arbitrate. The alternative, a `pinTask` beside `expiryTask`, needs a
    /// rule for which fires first when they coincide, and would leave a pin's timer running after a
    /// wake had already dropped its activity.
    ///
    /// The sleep interval is recomputed from `now()` on each schedule rather than carried forward,
    /// so a deadline that is already in the past fires on the next turn of the run loop instead of
    /// waiting out an interval that has elapsed.
    private func rescheduleExpiry() {
        let deadline = stack.nextDeadline
        guard deadline != scheduledDeadline else { return }

        expiryTask?.cancel()
        expiryTask = nil
        scheduledDeadline = deadline

        guard let deadline else { return }
        let interval = deadline.timeIntervalSince(now())

        // `[weak self]` rather than a cancel in `deinit`: a sleeping task that owned the
        // coordinator would keep it alive for the length of the sleep, and a `deinit` on a
        // main-actor-isolated class cannot touch isolated state to cancel it.
        expiryTask = Task { [weak self] in
            if interval > 0 {
                try? await Task.sleep(for: .seconds(interval))
            }
            guard !Task.isCancelled, let self else { return }
            // Both cleared *before* refreshing, and both matter. Leaving `scheduledDeadline` set
            // would let the reschedule that `refresh` triggers mistake this already-fired sleep for
            // a live one and decline to start a replacement; leaving `expiryTask` set would leave a
            // finished task on record as an outstanding timer, which is exactly the §9 claim this
            // class is making.
            self.expiryTask = nil
            self.scheduledDeadline = nil
            self.refresh()
        }
    }
}
