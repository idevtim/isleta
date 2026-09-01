import Foundation
import Testing

@testable import IslandActivities

/// The pointer holds the stage.
///
/// An activity that runs out of dwell under the pointer that is reading it has not stopped being
/// what the user is looking at. The rule is deliberately about the *stage* rather than about
/// notifications: nothing is taken off the island while the pointer is on it, and everything queued
/// behind it keeps expiring on the ordinary clock.
@Suite("Pointer hold")
struct PointerHoldStackTests {

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    @Test("what is on stage survives its deadline while the pointer is on the island")
    func heldPastItsDeadline() {
        var stack = ActivityStack()
        stack.insert(TestActivity("banner", priority: .prominent, expiry: .after(.seconds(5))), at: t0)
        stack.isPointerOverIsland = true

        #expect(stack.removeExpired(at: t0.addingTimeInterval(60)) == ActivityChange.none)
        #expect(stack.presented?.id == "banner")
    }

    @Test("it leaves on the first refresh after the pointer does")
    func leavesWithThePointer() {
        var stack = ActivityStack()
        stack.insert(TestActivity("banner", priority: .prominent, expiry: .after(.seconds(5))), at: t0)
        stack.isPointerOverIsland = true
        stack.removeExpired(at: t0.addingTimeInterval(60))

        stack.isPointerOverIsland = false
        #expect(stack.removeExpired(at: t0.addingTimeInterval(60)) == .dismissed("banner"))
        #expect(stack.isEmpty)
    }

    /// The hold is one entry deep. A burst arriving while the pointer rests on the island must not
    /// pile up behind the one it is holding — the queue is not what the user is reading.
    @Test("only the stage is held; the queue expires on the ordinary clock")
    func theQueueStillExpires() {
        var stack = ActivityStack()
        stack.insert(TestActivity("banner", priority: .prominent, expiry: .after(.seconds(5))), at: t0)
        stack.insert(TestActivity("second", priority: .standard, expiry: .after(.seconds(5))), at: t0)
        stack.isPointerOverIsland = true

        #expect(stack.removeExpired(at: t0.addingTimeInterval(60)) == ActivityChange.none)
        #expect(stack.entries.map(\.id) == ["banner"])
    }

    /// Nothing is held indefinitely by being *behind* the pointer's entry. Once something else takes
    /// the stage, what was being held is expired, unpresented, and goes with the next sweep.
    @Test("an entry the pointer is no longer on stage with goes at the next sweep")
    func preemptedHeldEntryGoes() {
        var stack = ActivityStack()
        stack.insert(TestActivity("banner", priority: .prominent, expiry: .after(.seconds(5))), at: t0)
        stack.isPointerOverIsland = true
        stack.removeExpired(at: t0.addingTimeInterval(60))

        let arrival = t0.addingTimeInterval(60)
        stack.insert(TestActivity("hud", priority: .interrupting, expiry: .after(.seconds(1.5))), at: arrival)
        #expect(stack.presented?.id == "hud")
        // The HUD is now the held entry, so the sweep that ends it is the one the pointer leaving
        // triggers — and it takes the stale banner with it.
        stack.isPointerOverIsland = false
        #expect(stack.removeExpired(at: arrival.addingTimeInterval(1.5)) == .dismissed("hud"))
        #expect(stack.isEmpty)
    }

    /// The §9 half of this. A deadline that cannot remove anything must leave the schedule, or the
    /// coordinator wakes at it, holds the entry, and schedules the same past instant again — a tight
    /// loop on the main actor for as long as the pointer rests on the island.
    @Test("a held deadline is not scheduled against")
    func heldDeadlineLeavesTheSchedule() {
        var stack = ActivityStack()
        stack.insert(TestActivity("banner", priority: .prominent, expiry: .after(.seconds(5))), at: t0)
        #expect(stack.nextExpiry == t0.addingTimeInterval(5))

        stack.isPointerOverIsland = true
        #expect(stack.nextExpiry == nil)
        #expect(stack.nextDeadline == nil)

        stack.isPointerOverIsland = false
        #expect(stack.nextExpiry == t0.addingTimeInterval(5))
    }

    /// The pin is a separate deadline, and the pointer touches neither it nor what it displaces.
    /// A user who swiped past a notification to get back to their music has moved on from it, so it
    /// expires behind the pin on the ordinary clock — the hold is about what is *on stage*, and a
    /// pinned activity that never expires holds nothing at all.
    @Test("the pin still lapses, and what it displaced still expires")
    func thePinIsUnaffected() {
        var stack = ActivityStack()
        stack.insert(TestActivity("banner", priority: .prominent, expiry: .after(.seconds(5))), at: t0)
        stack.insert(TestActivity("music", priority: .ambient, expiry: .never), at: t0)
        stack.pin("music", at: t0)
        stack.isPointerOverIsland = true

        // Music is on stage and never expires, so nothing is held: the banner's deadline and the
        // pin's lapse are both still in the schedule, earliest first.
        #expect(stack.nextDeadline == t0.addingTimeInterval(5))
        #expect(stack.removeExpired(at: t0.addingTimeInterval(5)) == ActivityChange.none)
        #expect(stack.entries.map(\.id) == ["music"])

        #expect(stack.nextDeadline == t0.addingTimeInterval(8))
        #expect(stack.removeExpired(at: t0.addingTimeInterval(8)) == ActivityChange.none)
        #expect(stack.pin == nil)
    }
}

@Suite("Pointer hold — coordinator")
@MainActor
struct PointerHoldCoordinatorTests {

    @Test("the pointer arriving takes the held deadline out of the schedule")
    func arrivingCancelsTheSleep() {
        let clock = TestClock()
        let coordinator = ActivityCoordinator(now: clock.provider)
        coordinator.present(TestActivity("banner", priority: .prominent, expiry: .after(.seconds(5))))
        #expect(coordinator.hasScheduledExpiry)

        coordinator.setPointerOverIsland(true)
        #expect(!coordinator.hasScheduledExpiry)
        #expect(coordinator.presented?.id == "banner")
    }

    /// The other direction, and it is the one that was reported from use. The deadline passed under
    /// the pointer, so there is no sleep left to fire for it — and the first version *swept* on the
    /// way out, which made reading a notification carefully the one way to make it vanish the
    /// instant you looked away.
    ///
    /// It gets its own dwell back instead, and then leaves on that. Both halves are the test: the
    /// entry survives the pointer leaving, and it does not survive the five seconds after it.
    @Test("the pointer leaving gives back the dwell it was holding, and the entry leaves on that")
    func leavingRestartsTheDwell() {
        let clock = TestClock()
        let coordinator = ActivityCoordinator(now: clock.provider)
        var changes: [ActivityChange] = []
        coordinator.onChange = { changes.append($0) }

        coordinator.present(TestActivity("banner", priority: .prominent, expiry: .after(.seconds(5))))
        coordinator.setPointerOverIsland(true)
        clock.advance(60)
        #expect(coordinator.presented?.id == "banner")

        coordinator.setPointerOverIsland(false)
        #expect(changes == [.presented("banner")])
        #expect(coordinator.presented?.id == "banner")
        // A deadline again, which is the other half: a held entry is deliberately out of the
        // schedule (`nextExpiry`), so an entry handed its dwell back that nothing was scheduled
        // against would sit on the island until some unrelated activity arrived.
        #expect(coordinator.hasScheduledExpiry)

        clock.advance(4)
        coordinator.refresh()
        #expect(coordinator.presented?.id == "banner")

        clock.advance(2)
        coordinator.refresh()
        #expect(changes == [.presented("banner"), .dismissed("banner")])
        #expect(coordinator.isEmpty)
    }

    /// An entry whose deadline has **not** passed is not touched by the pointer leaving. Extending
    /// one that was still live would make a pointer crossing the island a way to add five seconds to
    /// whatever it happened to pass over.
    @Test("a deadline that has not passed is left exactly where it was")
    func leavingDoesNotExtendALiveDeadline() {
        let clock = TestClock()
        var stack = ActivityStack()
        _ = stack.insert(
            TestActivity("banner", priority: .prominent, expiry: .after(.seconds(5))),
            at: clock.now
        )
        stack.isPointerOverIsland = true
        clock.advance(1)
        let before = stack.entries.first?.deadline
        #expect(stack.releasePointerHold(at: clock.now) == false)
        #expect(stack.entries.first?.deadline == before)
    }

    /// And an activity with no deadline at all — `.never`, which is what a pinned or permanent
    /// surface uses — is not given one. `heldEntry` already refuses those; this pins the refusal
    /// from the other side, because handing one a deadline would retire something built never to
    /// leave.
    @Test("an activity that never expires is not given a deadline by the pointer leaving")
    func leavingDoesNotDeadlineAPermanentEntry() {
        let clock = TestClock()
        var stack = ActivityStack()
        _ = stack.insert(TestActivity("player", priority: .ambient, expiry: .never), at: clock.now)
        stack.isPointerOverIsland = true
        clock.advance(60)
        #expect(stack.releasePointerHold(at: clock.now) == false)
        #expect(stack.entries.first?.deadline == nil)
    }

    /// §9 again, from the app's side: the pointer wandering over an island with nothing expiring on
    /// it must not buy a timer, and setting the flag to what it already holds must not do work.
    @Test("hovering an idle island holds nothing at all")
    func hoveringIdleIsFree() {
        let clock = TestClock()
        let coordinator = ActivityCoordinator(now: clock.provider)
        var changes = 0
        coordinator.onChange = { _ in changes += 1 }

        coordinator.setPointerOverIsland(true)
        coordinator.setPointerOverIsland(true)
        #expect(!coordinator.hasScheduledExpiry)

        coordinator.present(TestActivity("music", priority: .ambient, expiry: .never))
        coordinator.setPointerOverIsland(false)
        #expect(!coordinator.hasScheduledExpiry)
        #expect(coordinator.presented?.id == "music")
        #expect(changes == 1)
    }
}
