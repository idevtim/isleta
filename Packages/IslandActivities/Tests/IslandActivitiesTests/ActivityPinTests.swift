import Foundation
import Testing

@testable import IslandActivities

/// The swipe's policy, answered without a clock, without AppKit and without a running app — the
/// same standard the rest of this package's suites hold to. Everything a swipe can do is a pure
/// function of a stack, a pin and a `Date`, which is the reason the pin lives in `ActivityStack`
/// rather than in the view that recognizes the gesture.
@Suite("Activity stack — pinning")
struct ActivityPinTests {

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    private func stack(_ ids: [(ActivityID, ActivityPriority)], at now: Date) -> ActivityStack {
        var stack = ActivityStack()
        for (id, priority) in ids {
            stack.insert(TestActivity(id, priority: priority), at: now)
        }
        return stack
    }

    // MARK: - What a pin does

    /// The case the swipe exists for: reaching past something that arrived on its own to get back
    /// to what the user was listening to. A pin that only broke ties would leave the banner on
    /// stage and the swipe would visibly do nothing.
    @Test("a pin outranks priority, not merely peers")
    func pinOutranksPriority() {
        var stack = stack([("music", .ambient), ("banner", .prominent)], at: t0)
        #expect(stack.presented?.id == "banner")

        #expect(stack.pin("music", at: t0) == .swapped(from: "banner", to: "music"))
        #expect(stack.presented?.id == "music")
        #expect(stack.queued.map(\.id) == ["banner"])
    }

    /// `presented` is still the head of the order — the pin changed what sorts there and nothing
    /// else. If a "currently presented" field had been added instead, this is the assertion that
    /// would have had to be weakened.
    @Test("the presented activity is still the head of the order")
    func presentedIsStillDerived() {
        var stack = stack([("music", .ambient), ("banner", .prominent)], at: t0)
        stack.pin("music", at: t0)
        #expect(stack.entries.first?.id == stack.presented?.id)
        #expect(stack.entries.map(\.id) == ["music", "banner"])
    }

    @Test("pinning what is already on stage is not a change, but does hold it there")
    func pinningTheIncumbent() {
        var stack = stack([("music", .ambient), ("banner", .prominent)], at: t0)
        #expect(stack.pin("banner", at: t0) == ActivityChange.none)
        #expect(stack.presented?.id == "banner")
        #expect(stack.pin?.id == "banner")
    }

    @Test("unpinning restores ordinary ordering")
    func unpinning() {
        var stack = stack([("music", .ambient), ("banner", .prominent)], at: t0)
        stack.pin("music", at: t0)

        #expect(stack.unpin() == .swapped(from: "music", to: "banner"))
        #expect(stack.pin == nil)
        #expect(stack.presented?.id == "banner")
        // And unpinning nothing is not a change, so it cannot make the island redraw.
        #expect(stack.unpin() == ActivityChange.none)
    }

    /// Re-pinning is the second swipe. It must move the pin rather than stacking a second one, and
    /// it must restart the hold from the swipe that just happened.
    @Test("re-pinning moves the pin and restarts its hold")
    func rePinning() {
        var stack = stack([("music", .ambient), ("banner", .prominent), ("shelf", .standard)], at: t0)
        stack.pin("music", at: t0)
        #expect(stack.pin?.deadline == t0.addingTimeInterval(8))

        let later = t0.addingTimeInterval(3)
        #expect(stack.pin("shelf", at: later) == .swapped(from: "music", to: "shelf"))
        #expect(stack.pin?.id == "shelf")
        #expect(stack.pin?.deadline == later.addingTimeInterval(8))
        // One pin, not two: the previously pinned activity is back in ordinary order.
        #expect(stack.presented?.id == "shelf")
        #expect(stack.queued.map(\.id) == ["banner", "music"])
    }

    // MARK: - The pin against the rest of the stack

    /// PROGRESS.md's "an interrupting activity can still preempt a pinned one", at the resolution
    /// it actually matters: the keypress the user just made preempts, and it does so *immediately*
    /// rather than after the pin lapses.
    @Test("an interrupting activity arriving after the swipe preempts the pin")
    func interruptingArrivingLaterPreempts() {
        var stack = stack([("music", .ambient), ("banner", .prominent)], at: t0)
        stack.pin("music", at: t0)

        let change = stack.insert(
            TestActivity("volume", priority: .interrupting),
            at: t0.addingTimeInterval(1)
        )
        #expect(change == .swapped(from: "music", to: "volume"))
        #expect(stack.presented?.id == "volume")
        // The pin survives underneath it, so the HUD expiring hands the stage back to the swipe
        // rather than to the notification.
        #expect(stack.pin?.id == "music")
        #expect(stack.queued.map(\.id) == ["music", "banner"])
    }

    /// The other half of the same rule. A HUD the user swiped *past* stays passed: the swipe has to
    /// do something on the frame it happens, or it and its result read as two unrelated events.
    @Test("an interrupting activity already on stage when the user swiped does not preempt")
    func interruptingOlderThanThePinYields() {
        var stack = ActivityStack()
        stack.insert(TestActivity("volume", priority: .interrupting), at: t0)
        stack.insert(TestActivity("music", priority: .ambient), at: t0)
        #expect(stack.presented?.id == "volume")

        #expect(stack.pin("music", at: t0.addingTimeInterval(0.5)) == .swapped(from: "volume", to: "music"))
        #expect(stack.presented?.id == "music")
    }

    /// Pressing the volume key a second time is a new arrival — `insert` refreshes `insertedAt` —
    /// so it preempts a pin placed in between. This is what stops a swipe from muting the HUD for
    /// eight seconds.
    @Test("re-pressing a HUD key preempts a pin placed after the first press")
    func rePresentedInterruptingPreempts() {
        var stack = ActivityStack()
        let volume = TestActivity("volume", priority: .interrupting, expiry: .after(.seconds(1.5)))
        stack.insert(volume, at: t0)
        stack.insert(TestActivity("music", priority: .ambient), at: t0)
        stack.pin("music", at: t0.addingTimeInterval(0.5))
        #expect(stack.presented?.id == "music")

        stack.insert(volume, at: t0.addingTimeInterval(1))
        #expect(stack.presented?.id == "volume")
    }

    /// Deliberate, and the one place the pin is *stronger* than the default reading of "an
    /// interrupting activity can preempt": everything below interrupting queues behind a pin. For
    /// its eight seconds the island shows what the user asked for, not what arrived last.
    @Test("a notification arriving after the swipe waits behind the pin")
    func prominentDoesNotPreemptAPin() {
        var stack = stack([("music", .ambient)], at: t0)
        stack.pin("music", at: t0)

        let change = stack.insert(
            TestActivity("banner", priority: .prominent),
            at: t0.addingTimeInterval(1)
        )
        #expect(change == ActivityChange.none)
        #expect(stack.presented?.id == "music")
    }

    /// One activity is not a queue. Pinning it would look identical on screen while arming an 8s
    /// deadline — a timer bought for a gesture with nowhere to go, which is exactly what §9 objects
    /// to. `cycle` is where that is decided, so the tracker can read `.none` as "rubber-band".
    @Test("cycling with only one activity pins nothing and reports nothing")
    func cyclingASingleActivity() {
        var stack = stack([("music", .ambient)], at: t0)

        #expect(stack.canCycle(by: 1) == false)
        #expect(stack.canCycle(by: -1) == false)
        #expect(stack.cycle(by: 1, at: t0) == ActivityChange.none)
        #expect(stack.pin == nil)
        #expect(stack.nextDeadline == nil)
    }

    /// Pinning an id that is not on the stack records nothing at all, which is the first half of
    /// "a pin must not resurrect an activity that has expired out of the stack".
    @Test("pinning an activity that is not on the stack records no pin")
    func pinningAnAbsentActivity() {
        var stack = stack([("music", .ambient)], at: t0)
        #expect(stack.pin("ghost", at: t0) == ActivityChange.none)
        #expect(stack.pin == nil)
    }

    // MARK: - Cycling

    /// The swipe walks the order the stack would have had if nobody had swiped. Walking the *live*
    /// order instead gives a two-element loop: the successor of the pinned entry is whatever the
    /// pin displaced, so swipe-swipe lands back where it started.
    @Test("repeated swipes walk the whole queue rather than flipping between two")
    func cyclingWalksTheNaturalOrder() {
        var stack = stack([("music", .ambient), ("shelf", .standard), ("banner", .prominent)], at: t0)
        #expect(stack.cycleOrder == ["banner", "shelf", "music"])

        #expect(stack.cycle(by: 1, at: t0) == .swapped(from: "banner", to: "shelf"))
        #expect(stack.cycle(by: 1, at: t0) == .swapped(from: "shelf", to: "music"))
        // And back again.
        #expect(stack.cycle(by: -1, at: t0) == .swapped(from: "music", to: "shelf"))
        #expect(stack.cycle(by: -1, at: t0) == .swapped(from: "shelf", to: "banner"))
    }

    /// §5's resistance needs an end to resist at, which a wrapping cycle does not have.
    @Test("the queue does not wrap at either end")
    func cyclingDoesNotWrap() {
        var stack = stack([("music", .ambient), ("banner", .prominent)], at: t0)

        #expect(stack.canCycle(by: -1) == false)
        #expect(stack.cycle(by: -1, at: t0) == ActivityChange.none)

        stack.cycle(by: 1, at: t0)
        #expect(stack.presented?.id == "music")
        #expect(stack.canCycle(by: 1) == false)
        #expect(stack.cycle(by: 1, at: t0) == ActivityChange.none)
        // The failed swipe must not have disturbed the pin it already had.
        #expect(stack.pin?.id == "music")
    }

    @Test("an empty stack cannot be cycled or pinned")
    func cyclingAnEmptyStack() {
        var stack = ActivityStack()
        #expect(stack.cycle(by: 1, at: t0) == ActivityChange.none)
        #expect(stack.canCycle(by: 1) == false)
        #expect(stack.pin == nil)
    }

    // MARK: - Expiry

    /// The pin's own deadline, which is the cost PROGRESS.md accepted: a second reason for the
    /// island to move on its own. It arrives as an ordinary `ActivityChange`.
    @Test("a pin lapses on its own and ordinary ordering resumes")
    func pinLapses() {
        var stack = stack([("music", .ambient), ("banner", .prominent)], at: t0)
        stack.pin("music", at: t0)

        #expect(stack.removeExpired(at: t0.addingTimeInterval(7.999)) == ActivityChange.none)
        #expect(stack.presented?.id == "music")

        #expect(stack.removeExpired(at: t0.addingTimeInterval(8)) == .swapped(from: "music", to: "banner"))
        #expect(stack.pin == nil)
        #expect(stack.presented?.id == "banner")
    }

    /// "The 8s is measured from the last interaction, not from the swipe." Hovering at t+7 has to
    /// buy another eight seconds, or the island changes under a user who is still working with it.
    @Test("an interaction restarts the hold from the interaction, not from the swipe")
    func interactionRestartsTheHold() {
        var stack = stack([("music", .ambient), ("banner", .prominent)], at: t0)
        stack.pin("music", at: t0)

        stack.refreshPin(at: t0.addingTimeInterval(7))
        #expect(stack.pin?.deadline == t0.addingTimeInterval(15))
        #expect(stack.removeExpired(at: t0.addingTimeInterval(9)) == ActivityChange.none)
        #expect(stack.presented?.id == "music")

        #expect(stack.removeExpired(at: t0.addingTimeInterval(15)) == .swapped(from: "music", to: "banner"))
    }

    /// The refresh must not move `placedAt`, or a HUD that was already on screen when the user
    /// swiped would drop below the pin the next time the pointer moved.
    @Test("an interaction does not move the line an interrupting activity is judged against")
    func interactionDoesNotMovePlacedAt() {
        var stack = ActivityStack()
        stack.insert(TestActivity("volume", priority: .interrupting), at: t0)
        stack.insert(TestActivity("music", priority: .ambient), at: t0)
        stack.pin("music", at: t0.addingTimeInterval(1))

        stack.refreshPin(at: t0.addingTimeInterval(2))
        #expect(stack.pin?.placedAt == t0.addingTimeInterval(1))
        #expect(stack.presented?.id == "music")
    }

    /// An interaction with no pin behind it must not invent one — this is the §9 assertion at the
    /// pure-policy end, matching `noteInteraction`'s at the coordinator end.
    @Test("refreshing with nothing pinned creates no deadline")
    func refreshingWithoutAPin() {
        var stack = stack([("music", .ambient), ("banner", .prominent)], at: t0)
        stack.refreshPin(at: t0.addingTimeInterval(1))
        #expect(stack.pin == nil)
        #expect(stack.nextDeadline == nil)
    }

    /// The rule PROGRESS.md states outright. The pinned activity expiring takes the pin with it, so
    /// the next time that source presents — the next track, the next keypress — it arrives in
    /// ordinary order rather than jumping the queue for a swipe made minutes ago.
    @Test("an activity expiring out of the stack takes its pin with it")
    func expiryRetiresThePin() {
        var stack = ActivityStack()
        stack.insert(TestActivity("banner", priority: .prominent, expiry: .after(.seconds(5))), at: t0)
        stack.insert(TestActivity("music", priority: .ambient, expiry: .never), at: t0)
        stack.pin("banner", at: t0)
        #expect(stack.presented?.id == "banner")

        #expect(stack.removeExpired(at: t0.addingTimeInterval(5)) == .swapped(from: "banner", to: "music"))
        #expect(stack.pin == nil)

        // And the pin does not resurrect it: re-presenting takes ordinary order.
        stack.insert(TestActivity("banner", priority: .prominent), at: t0.addingTimeInterval(6))
        #expect(stack.presented?.id == "banner")
        #expect(stack.pin == nil)
        stack.insert(TestActivity("hud", priority: .interrupting), at: t0.addingTimeInterval(7))
        #expect(stack.presented?.id == "hud")
    }

    @Test("dismissing the pinned activity retires the pin")
    func dismissalRetiresThePin() {
        var stack = stack([("music", .ambient), ("banner", .prominent)], at: t0)
        stack.pin("music", at: t0)

        #expect(stack.remove("music") == .swapped(from: "music", to: "banner"))
        #expect(stack.pin == nil)
        #expect(stack.nextDeadline == nil)
    }

    @Test("clearing the stack clears the pin")
    func removeAllRetiresThePin() {
        var stack = stack([("music", .ambient), ("banner", .prominent)], at: t0)
        stack.pin("music", at: t0)
        stack.removeAll()
        #expect(stack.pin == nil)
        #expect(stack.nextDeadline == nil)
    }

    /// The §9 shape of the whole feature: two deadlines, one value. The coordinator schedules
    /// against this and therefore still holds at most one sleep.
    @Test("the pin's deadline merges into the stack's single next deadline")
    func deadlinesMerge() {
        var stack = ActivityStack()
        stack.insert(TestActivity("music", priority: .ambient, expiry: .never), at: t0)
        stack.insert(TestActivity("banner", priority: .prominent, expiry: .after(.seconds(20))), at: t0)
        #expect(stack.nextDeadline == t0.addingTimeInterval(20))

        stack.pin("music", at: t0)
        // The pin is sooner, so it owns the deadline.
        #expect(stack.nextDeadline == t0.addingTimeInterval(8))
        #expect(stack.nextExpiry == t0.addingTimeInterval(20))

        // Interaction pushes the pin past the activity's expiry; the activity owns it again.
        stack.refreshPin(at: t0.addingTimeInterval(15))
        #expect(stack.nextDeadline == t0.addingTimeInterval(20))
    }

    /// A Mac that slept through both deadlines must come back with neither still in force, in one
    /// pass — the same guarantee `removeExpired` already made for activities alone.
    @Test("a long jump forward lapses the pin and expires the stack together")
    func wakeFromSleep() {
        var stack = ActivityStack()
        stack.insert(TestActivity("hud", priority: .interrupting, expiry: .after(.seconds(1.5))), at: t0)
        stack.insert(TestActivity("music", priority: .ambient, expiry: .never), at: t0)
        stack.pin("music", at: t0)

        #expect(stack.removeExpired(at: t0.addingTimeInterval(8 * 3600)) == ActivityChange.none)
        #expect(stack.pin == nil)
        #expect(stack.entries.map(\.id) == ["music"])
    }
}

@Suite("Activity coordinator — pinning")
@MainActor
struct ActivityCoordinatorPinTests {

    /// The §9 claim, asserted rather than assumed: the pin's deadline goes into the sleep that
    /// already existed. One task while a pin holds, and none once it lapses.
    @Test("a pin schedules the one sleep, and leaves nothing behind when it lapses")
    func pinUsesTheOneSleep() {
        let clock = TestClock()
        let coordinator = ActivityCoordinator(now: clock.provider)

        coordinator.present(TestActivity("music", priority: .ambient, expiry: .never))
        coordinator.present(TestActivity("banner", priority: .prominent, expiry: .never))
        // Nothing can expire, so nothing is scheduled — the Milestone 1 state.
        #expect(!coordinator.hasScheduledExpiry)

        coordinator.cycle(by: 1)
        #expect(coordinator.presented?.id == "music")
        #expect(coordinator.hasScheduledExpiry)
        #expect(coordinator.nextDeadline == clock.now.addingTimeInterval(8))
        // The activities themselves still never expire; the deadline is the pin's alone.
        #expect(coordinator.nextExpiry == nil)

        clock.advance(8)
        #expect(coordinator.refresh() == .swapped(from: "music", to: "banner"))
        #expect(coordinator.pinned == nil)
        #expect(!coordinator.hasScheduledExpiry)
    }

    /// The call the app shell makes from every hover and every click. With no pin it must not arm
    /// anything — an idle Isleta with the pointer wandering over the notch holds no timer.
    @Test("noteInteraction with nothing pinned schedules nothing")
    func interactionWithoutAPinIsFree() {
        let clock = TestClock()
        let coordinator = ActivityCoordinator(now: clock.provider)
        coordinator.present(TestActivity("music", priority: .ambient, expiry: .never))

        for _ in 0..<20 {
            coordinator.noteInteraction()
            clock.advance(0.1)
        }
        #expect(!coordinator.hasScheduledExpiry)
        #expect(coordinator.nextDeadline == nil)
    }

    @Test("noteInteraction pushes a live pin's deadline out without rebuilding anything visible")
    func interactionExtendsTheHold() {
        let clock = TestClock()
        let coordinator = ActivityCoordinator(now: clock.provider)
        var reported: [ActivityChange] = []

        coordinator.present(TestActivity("music", priority: .ambient, expiry: .never))
        coordinator.present(TestActivity("banner", priority: .prominent, expiry: .never))
        coordinator.cycle(by: 1)
        coordinator.onChange = { reported.append($0) }

        clock.advance(7)
        coordinator.noteInteraction()
        #expect(coordinator.nextDeadline == clock.now.addingTimeInterval(8))
        #expect(coordinator.refresh() == ActivityChange.none)
        #expect(coordinator.presented?.id == "music")
        // Nothing on screen moved, so nothing was reported.
        #expect(reported.isEmpty)

        coordinator.dismissAll()
        #expect(!coordinator.hasScheduledExpiry)
    }

    @Test("a swipe with nowhere to go changes nothing and schedules nothing")
    func swipeWithNowhereToGo() {
        let clock = TestClock()
        let coordinator = ActivityCoordinator(now: clock.provider)
        coordinator.present(TestActivity("music", priority: .ambient, expiry: .never))

        #expect(coordinator.canCycle(by: 1) == false)
        #expect(coordinator.cycle(by: 1) == ActivityChange.none)
        #expect(!coordinator.hasScheduledExpiry)
    }
}
