import AppKit
import Foundation
import IslandActivities
import Testing

@testable import IslandSources

/// A `ContinuousClock` the test moves by hand.
///
/// Locked rather than actor-isolated because the source takes its clock as a `@Sendable` closure —
/// it is called from the notification block, which the compiler will not assume is anywhere in
/// particular.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private let origin = ContinuousClock.now
    private var offset: Duration = .zero

    var instant: ContinuousClock.Instant {
        lock.withLock { origin.advanced(by: offset) }
    }

    func advance(by duration: Duration) {
        lock.withLock { offset += duration }
    }
}

/// `.serialized` because several of these post real notifications into
/// `NSWorkspace.shared.notificationCenter`, which is one shared object for the whole process.
/// swift-testing runs a suite in parallel by default, and `settle()` spins the run loop — which is
/// exactly where another test's `post` gets delivered to *this* test's source. The contamination
/// does not fail the same test twice running, which is the worst kind.
@MainActor
@Suite("SystemEventsSource", .serialized)
struct SystemEventsSourceTests {

    /// Drains anything a `post` left on the main queue.
    ///
    /// Posting from the main thread to an observer registered with `queue: .main` turns out to run
    /// the block inline — `NotificationCenter` short-circuits when the target queue is the current
    /// one — so in practice this finds nothing to drain and returns at once. It is here because the
    /// documented contract is "scheduled on the queue", not "run inline", and an assertion that
    /// depends on an undocumented short-circuit is one SDK away from a test that fails on a busy
    /// machine only. `RunLoop.run(until:)` on its own would not do: with no input source attached it
    /// returns immediately and drains nothing at all.
    private func settle() {
        let deadline = Date().addingTimeInterval(0.5)
        while !OperationQueue.main.operations.isEmpty, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    // MARK: - Authorization

    @Test("the source needs nothing granted")
    func needsNoPermission() {
        // The reason this milestone is the one that proves the pipeline: every other source can be
        // denied, and a denied source producing nothing is indistinguishable from a broken wire.
        let source = SystemEventsSource()
        #expect(source.authorization == .notRequired)
        #expect(source.authorization.isUsable)
        #expect(SystemEventsSource.sourceName == "SystemEvents")
        #expect(source.sourceName == "SystemEvents")
    }

    // MARK: - Lifecycle

    @Test("start registers on both centers and stop removes every observer")
    func stopRemovesEveryObserver() {
        let source = SystemEventsSource()
        source.start()

        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter
        let centers = source.observedCenters
        #expect(centers.count == 6)
        #expect(centers.filter { $0 === workspace }.count == 4)
        #expect(centers.filter { $0 === distributed }.count == 2)

        source.stop()
        // The distributed observer is the one that leaks: its token means nothing to
        // `NSWorkspace`'s center or to `NotificationCenter.default`, and handing it to either
        // removes nothing while raising nothing. Emptying the list is only true if each token went
        // back to the center that issued it.
        #expect(source.observedCenters.isEmpty)
        #expect(source.isObserving == false)
    }

    @Test("start is idempotent")
    func startIsIdempotent() {
        // `IslandController` rebuilds on display changes and one clamshell open emits several. A
        // second registration set would greet twice per lid, and the count would climb for the life
        // of the process.
        let source = SystemEventsSource()
        source.start()
        source.start()
        source.start()
        #expect(source.observedCenters.count == 6)
        source.stop()
    }

    @Test("stop leaves the absence in progress alone")
    func stopDoesNotForgetTheAbsence() {
        // Stopping describes our observers, not the world. Resetting to "present" here would
        // swallow the greeting for an absence that is genuinely still running when the source is
        // re-wired by a settings toggle.
        let clock = TestClock()
        let source = SystemEventsSource(elapsed: { clock.instant })
        var greetings: [any IslandActivity] = []
        source.onActivity = { greetings.append($0) }

        source.receive(.displaysDidSleep, at: clock.instant)
        source.stop()
        source.start()
        clock.advance(by: .seconds(7_200))
        source.receive(.displaysDidWake, at: clock.instant)
        source.stop()

        #expect(greetings.count == 1)
    }

    // MARK: - The wire

    @Test("the workspace notifications are wired to the events they mean")
    func workspaceNotificationsReachTheIsland() {
        // Proves the names, not the policy: a sleep/wake pair posted for real has to arrive as
        // `systemWillSleep` then `systemDidWake`, or the whole model is correct about events nobody
        // sends. Posted into `NSWorkspace.shared.notificationCenter`, which delivers in-process, so
        // no other application on the machine sees anything.
        let clock = TestClock()
        let source = SystemEventsSource(elapsed: { clock.instant })
        var greetings: [any IslandActivity] = []
        source.onActivity = { greetings.append($0) }
        source.start()
        defer { source.stop() }

        let center = NSWorkspace.shared.notificationCenter
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        settle()
        clock.advance(by: .seconds(28_800))
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        settle()
        #expect(greetings.isEmpty, "a wake with the displays still dark is a maintenance wake")

        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        settle()
        #expect(greetings.count == 1)
        #expect(greetings.first?.kind == .welcomeBack)
    }

    @Test("a display blip posted for real greets nothing")
    func realDisplayBlipIsIgnored() {
        let clock = TestClock()
        let source = SystemEventsSource(elapsed: { clock.instant })
        var greetings: [any IslandActivity] = []
        source.onActivity = { greetings.append($0) }
        source.start()
        defer { source.stop() }

        let center = NSWorkspace.shared.notificationCenter
        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        settle()
        clock.advance(by: .seconds(5))
        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        settle()
        #expect(greetings.isEmpty)
    }

    @Test("a stopped source hears nothing")
    func stoppedSourceIsSilent() {
        let clock = TestClock()
        let source = SystemEventsSource(elapsed: { clock.instant })
        var greetings: [any IslandActivity] = []
        source.onActivity = { greetings.append($0) }
        source.start()

        let center = NSWorkspace.shared.notificationCenter
        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        settle()
        source.stop()
        clock.advance(by: .seconds(28_800))
        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        settle()

        #expect(greetings.isEmpty)
    }

    // MARK: - What it produces

    @Test("the greeting is phrased for the wall clock, not for the absence")
    func greetingUsesTheWallClock() {
        // Two clocks, and each is asked only what it can answer. The absence comes off
        // `ContinuousClock`, which knows nothing about mornings; the phrasing comes off the wall
        // clock, which cannot be trusted to measure an absence across a wake-time resync.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 19
        components.hour = 8
        let morning = calendar.date(from: components)!

        let clock = TestClock()
        let source = SystemEventsSource(now: { morning }, elapsed: { clock.instant })
        var greetings: [any IslandActivity] = []
        source.onActivity = { greetings.append($0) }

        source.receive(.sessionDidLock, at: clock.instant)
        clock.advance(by: .seconds(3_600))
        source.receive(.sessionDidUnlock, at: clock.instant)

        #expect(greetings.count == 1)
        #expect(greetings.first?.presentations.compact.title == WelcomeBackGreeting(at: morning, calendar: calendar).title)
    }

    // MARK: - The user's threshold

    /// The bug this setting exists for, written down: a lock and an immediate unlock is silent at
    /// five minutes and greets at zero, and until the threshold was settable there was no way to
    /// tell the first of those from the source being broken.
    @Test("a threshold of zero greets a return that the default would have called too brief")
    func zeroThresholdGreetsEveryReturn() {
        let clock = TestClock()
        let source = SystemEventsSource(elapsed: { clock.instant })
        var greetings: [any IslandActivity] = []
        source.onActivity = { greetings.append($0) }

        source.minimumAbsence = .zero
        source.receive(.sessionDidLock, at: clock.instant)
        clock.advance(by: .seconds(2))
        source.receive(.sessionDidUnlock, at: clock.instant)

        #expect(greetings.count == 1)
    }

    @Test("the default threshold stays silent for a two-second lock")
    func defaultThresholdIgnoresABriefLock() {
        let clock = TestClock()
        let source = SystemEventsSource(elapsed: { clock.instant })
        var greetings: [any IslandActivity] = []
        source.onActivity = { greetings.append($0) }

        source.receive(.sessionDidLock, at: clock.instant)
        clock.advance(by: .seconds(2))
        source.receive(.sessionDidUnlock, at: clock.instant)

        #expect(greetings.isEmpty)
        #expect(source.minimumAbsence == WelcomeBackPolicy.defaultMinimumAbsence)
    }

    /// The reason the setter assigns one field rather than rebuilding the policy. The app shell
    /// writes this on every `SourceHub.apply`, which includes the apply at launch — and a machine
    /// that launched Isleta while an absence was outstanding would otherwise have it swallowed.
    @Test("changing the threshold mid-absence keeps the absence rather than resetting it")
    func thresholdChangeDoesNotResetTheAbsence() {
        let clock = TestClock()
        let source = SystemEventsSource(elapsed: { clock.instant })
        var greetings: [any IslandActivity] = []
        source.onActivity = { greetings.append($0) }

        source.receive(.sessionDidLock, at: clock.instant)
        clock.advance(by: .seconds(600))
        // Mid-absence, as a settings change or a launch-time apply would arrive.
        source.minimumAbsence = .seconds(60)
        source.receive(.sessionDidUnlock, at: clock.instant)

        #expect(greetings.count == 1)
    }

    /// The other direction, and the one a suppression window would get wrong: raising the threshold
    /// above an absence already in progress has to silence it, not greet on the old number.
    @Test("raising the threshold above an absence in progress silences it")
    func raisingTheThresholdSilencesAnAbsenceInProgress() {
        let clock = TestClock()
        let source = SystemEventsSource(elapsed: { clock.instant })
        var greetings: [any IslandActivity] = []
        source.onActivity = { greetings.append($0) }

        source.receive(.sessionDidLock, at: clock.instant)
        clock.advance(by: .seconds(600))
        source.minimumAbsence = .seconds(900)
        source.receive(.sessionDidUnlock, at: clock.instant)

        #expect(greetings.isEmpty)
    }

    @Test("nothing is ever dismissed by the source")
    func nothingIsDismissed() {
        // The greeting stops being interesting rather than becoming untrue, which is
        // `ActivityExpiry`'s job. `onDismiss` is set because the protocol has it and is never called.
        let clock = TestClock()
        let source = SystemEventsSource(elapsed: { clock.instant })
        var dismissed: [ActivityID] = []
        source.onDismiss = { dismissed.append($0) }

        source.receive(.systemWillSleep, at: clock.instant)
        clock.advance(by: .seconds(28_800))
        source.receive(.systemDidWake, at: clock.instant)
        source.receive(.displaysDidWake, at: clock.instant)

        #expect(dismissed.isEmpty)
    }
}
