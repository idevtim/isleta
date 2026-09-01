import Foundation
import Testing

@testable import IslandActivities

@Suite("Activity coordinator")
@MainActor
struct ActivityCoordinatorTests {

    @Test("a fresh coordinator presents nothing and holds no timer")
    func startsIdle() {
        let coordinator = ActivityCoordinator()
        #expect(coordinator.isEmpty)
        #expect(coordinator.presented == nil)
        #expect(coordinator.nextExpiry == nil)
        #expect(!coordinator.hasScheduledExpiry)
    }

    @Test("the coordinator delegates ordering to the stack")
    func delegatesOrdering() {
        let clock = TestClock()
        let coordinator = ActivityCoordinator(now: clock.provider)

        coordinator.present(TestActivity("music", priority: .ambient))
        #expect(coordinator.present(TestActivity("hud", priority: .interrupting)) == .swapped(from: "music", to: "hud"))
        #expect(coordinator.presented?.id == "hud")
        #expect(coordinator.queued.map(\.id) == ["music"])

        #expect(coordinator.dismiss("hud") == .swapped(from: "hud", to: "music"))
        #expect(coordinator.dismissAll() == .dismissed("music"))
        #expect(coordinator.isEmpty)
    }

    /// §9's "no polling when idle", asserted rather than assumed. An activity that never expires
    /// must leave the coordinator with nothing outstanding — not a sleep that wakes to find no work.
    @Test("a never-expiring activity leaves no timer outstanding")
    func neverExpiringHoldsNoTimer() {
        let clock = TestClock()
        let coordinator = ActivityCoordinator(now: clock.provider)

        coordinator.present(TestActivity("music", priority: .ambient, expiry: .never))
        #expect(!coordinator.hasScheduledExpiry)
        #expect(coordinator.nextExpiry == nil)
    }

    @Test("a timer appears only while something can expire, and goes again when it does")
    func timerFollowsTheStack() {
        let clock = TestClock()
        let coordinator = ActivityCoordinator(now: clock.provider)

        coordinator.present(TestActivity("hud", priority: .interrupting, expiry: .after(.seconds(1.5))))
        #expect(coordinator.hasScheduledExpiry)

        clock.advance(1.5)
        #expect(coordinator.refresh() == .dismissed("hud"))
        #expect(coordinator.isEmpty)
        #expect(!coordinator.hasScheduledExpiry)
    }

    /// The §9 half that is easy to get wrong in the other direction: Now Playing updates on every
    /// scrub, and tearing down and rebuilding the sleep on each one is churn nobody asked for. The
    /// deadline is unchanged, so the sleep must be too.
    @Test("an update that does not move the deadline does not rebuild the sleep")
    func unchangedDeadlineReusesTheSleep() {
        let clock = TestClock()
        let coordinator = ActivityCoordinator(now: clock.provider)

        let deadline = clock.now.addingTimeInterval(30)
        coordinator.present(TestActivity("timer", expiry: .at(deadline), title: "0:30"))
        let scheduled = coordinator.nextExpiry

        clock.advance(1)
        coordinator.present(TestActivity("timer", expiry: .at(deadline), title: "0:29"))
        #expect(coordinator.nextExpiry == scheduled)
        #expect(coordinator.hasScheduledExpiry)

        // Leaves nothing sleeping behind the test.
        coordinator.dismissAll()
        #expect(!coordinator.hasScheduledExpiry)
    }

    @Test("refresh honors an explicit instant, so expiry needs no wall clock to test")
    func refreshAtAnInstant() {
        let coordinator = ActivityCoordinator(now: TestClock().provider)
        let t0 = Date(timeIntervalSinceReferenceDate: 0)

        coordinator.present(TestActivity("banner", priority: .prominent, expiry: .after(.seconds(5))))
        #expect(coordinator.refresh(at: t0.addingTimeInterval(4)) == ActivityChange.none)
        #expect(coordinator.refresh(at: t0.addingTimeInterval(5)) == .dismissed("banner"))
    }

    /// The app shell picks a motion token from this (§6.2), so it has to arrive for every change
    /// the island would redraw for — and for nothing else.
    @Test("onChange reports every visible change and no invisible one")
    func changeCallback() {
        let clock = TestClock()
        let coordinator = ActivityCoordinator(now: clock.provider)
        var reported: [ActivityChange] = []
        coordinator.onChange = { reported.append($0) }

        coordinator.present(TestActivity("music", priority: .ambient, title: "First"))
        coordinator.present(TestActivity("music", priority: .ambient, title: "Second"))
        // Queued behind nothing visible changing: silent.
        coordinator.present(TestActivity("shelf", priority: .ambient))
        coordinator.present(TestActivity("hud", priority: .interrupting))
        coordinator.dismiss("hud")
        coordinator.dismissAll()

        #expect(reported == [
            .presented("music"),
            .contentChanged("music"),
            .swapped(from: "music", to: "hud"),
            .swapped(from: "hud", to: "music"),
            .dismissed("music"),
        ])
    }

    /// Everything above drives expiry by hand so the suite never waits on a clock. This one proves
    /// the scheduled sleep actually fires, which is the single thing the injected clock cannot show.
    /// Deliberately the only time-dependent test in the package, with an order of magnitude of slack.
    @Test("the scheduled sleep really fires")
    func scheduledExpiryFires() async throws {
        let coordinator = ActivityCoordinator()
        coordinator.present(TestActivity("hud", priority: .interrupting, expiry: .after(.milliseconds(20))))
        #expect(coordinator.presented?.id == "hud")

        try await Task.sleep(for: .milliseconds(400))
        #expect(coordinator.isEmpty)
        #expect(!coordinator.hasScheduledExpiry)
    }

    /// A deadline already in the past must not wait out an interval that has elapsed — the wake
    /// from system sleep case, where the sleep resumes to find its deadline hours gone.
    @Test("a deadline already past clears on the next turn of the run loop")
    func pastDeadlineClearsImmediately() async throws {
        let coordinator = ActivityCoordinator()
        coordinator.present(
            TestActivity("stale", priority: .prominent, expiry: .at(Date(timeIntervalSinceReferenceDate: 0)))
        )

        try await Task.sleep(for: .milliseconds(200))
        #expect(coordinator.isEmpty)
    }
}
