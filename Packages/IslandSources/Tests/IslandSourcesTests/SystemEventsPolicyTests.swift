import Foundation
import Testing

@testable import IslandSources

/// The §2.5 event matrix, driven by hand.
///
/// Every case here is a physical thing a person does to a Mac, written as the ordering of
/// `SystemEvent`s it produces. That is the point of the policy being a pure value: an eight-hour
/// absence is `advanced(by: .seconds(8 * 3600))` and costs nothing, where reproducing these against
/// the real notifications would mean closing a lid sixteen times and waiting overnight for one of
/// them.
@Suite("WelcomeBackPolicy")
struct WelcomeBackPolicyTests {

    private let origin = ContinuousClock.now

    private func at(_ seconds: Double) -> ContinuousClock.Instant {
        origin.advanced(by: .seconds(seconds))
    }

    /// Runs a script and returns every greeting it produced. Counting greetings is the assertion in
    /// most of these — "shows it twice" and "never shows it" are the two failures.
    private func greetings(
        _ script: [(SystemEvent, Double)],
        minimumAbsence: Duration = WelcomeBackPolicy.defaultMinimumAbsence
    ) -> [Duration] {
        var policy = WelcomeBackPolicy(minimumAbsence: minimumAbsence)
        return script.compactMap { event, seconds in
            if case .welcomeBack(let absence) = policy.handle(event, at: at(seconds)) {
                return absence
            }
            return nil
        }
    }

    // MARK: - The ordinary returns

    @Test("closing the lid and reopening it on a Mac that asks for a password greets exactly once")
    func lidOpenWithPassword() {
        // The full sequence for one physical return: the screen locks as the machine goes down, the
        // system comes back, the displays light, and only then does a human authenticate. A source
        // that greeted on wake *and* on unlock would say hello twice here for one lid.
        let shown = greetings([
            (.sessionDidLock, 0),
            (.systemWillSleep, 0.2),
            (.systemDidWake, 28_800),
            (.displaysDidWake, 28_801),
            (.sessionDidUnlock, 28_805),
        ])
        #expect(shown.count == 1)
        #expect(shown.first == .seconds(28_805))
    }

    @Test("waking a Mac that asks for no password greets when the displays light")
    func lidOpenWithoutPassword() {
        // No lock, no unlock — the two events the naive implementation keys off never arrive at all.
        let shown = greetings([
            (.systemWillSleep, 0),
            (.systemDidWake, 3_600),
            (.displaysDidWake, 3_601),
        ])
        #expect(shown.count == 1)
        #expect(shown.first == .seconds(3_601))
    }

    @Test("locking the screen and unlocking it later greets with no sleep involved")
    func unlockWithoutWake() {
        let shown = greetings([
            (.sessionDidLock, 0),
            (.sessionDidUnlock, 1_800),
        ])
        #expect(shown == [.seconds(1_800)])
    }

    @Test("the displays waking without the system waking greets")
    func displaysWakeWithoutSystemWake() {
        // The idle display timer, not sleep. The user was reading something on paper for twenty
        // minutes and came back to a dark screen; that is a return.
        let shown = greetings([
            (.displaysDidSleep, 0),
            (.displaysDidWake, 1_200),
        ])
        #expect(shown == [.seconds(1_200)])
    }

    // MARK: - The orderings

    @Test("wake before unlock greets once, at the unlock")
    func wakeThenUnlock() {
        var policy = WelcomeBackPolicy()
        #expect(policy.handle(.systemWillSleep, at: at(0)) == .departed)
        #expect(policy.handle(.systemDidWake, at: at(7_200)) == .unchanged)
        #expect(policy.handle(.sessionDidLock, at: at(7_200.1)) == .unchanged)
        #expect(policy.handle(.sessionDidUnlock, at: at(7_205)) == .welcomeBack(absence: .seconds(7_205)))
    }

    @Test("unlock before wake greets once, at the wake")
    func unlockThenWake() {
        // Not a sequence a lid produces, but the notifications come from two different centers and
        // nothing guarantees their relative order. The conjunction makes the answer the same either
        // way: whichever event completes presence is the one that greets, and the other is inert.
        var policy = WelcomeBackPolicy()
        #expect(policy.handle(.sessionDidLock, at: at(0)) == .departed)
        #expect(policy.handle(.systemWillSleep, at: at(0.1)) == .unchanged)
        #expect(policy.handle(.sessionDidUnlock, at: at(7_200)) == .unchanged)
        #expect(policy.handle(.systemDidWake, at: at(7_201)) == .welcomeBack(absence: .seconds(7_201)))
    }

    @Test("repeated unlocks greet once")
    func repeatedUnlocks() {
        // `loginwindow` is not obliged to post exactly one unlock, and a user can lock and unlock in
        // a rhythm. Only the first completes an absence; the rest have nothing left to consume, and
        // that is structural rather than a suppression window.
        let shown = greetings([
            (.sessionDidLock, 0),
            (.sessionDidUnlock, 3_600),
            (.sessionDidUnlock, 3_601),
            (.sessionDidUnlock, 3_602),
        ])
        #expect(shown.count == 1)
    }

    @Test("a return with no departure behind it greets nothing")
    func returnWithoutDeparture() {
        var policy = WelcomeBackPolicy()
        #expect(policy.handle(.sessionDidUnlock, at: at(0)) == .unchanged)
        #expect(policy.handle(.displaysDidWake, at: at(1)) == .unchanged)
        #expect(policy.handle(.systemDidWake, at: at(2)) == .unchanged)
        #expect(policy.isTrackingAbsence == false)
    }

    // MARK: - The absences that are not absences

    @Test("a five second screensaver blip is not a return")
    func screensaverBlip() {
        var policy = WelcomeBackPolicy()
        #expect(policy.handle(.displaysDidSleep, at: at(0)) == .departed)
        #expect(policy.handle(.displaysDidWake, at: at(5)) == .returnedBriefly(absence: .seconds(5)))
    }

    @Test("locking the screen for thirty seconds is not a return")
    func briefLock() {
        var policy = WelcomeBackPolicy()
        #expect(policy.handle(.sessionDidLock, at: at(0)) == .departed)
        #expect(policy.handle(.sessionDidUnlock, at: at(30)) == .returnedBriefly(absence: .seconds(30)))
    }

    @Test("an absence exactly at the threshold greets")
    func thresholdIsInclusive() {
        // `>=`, not `>`. A policy built with `.zero` — which is what a test or a settings slider at
        // its minimum produces — has to greet rather than fall silent for reasons nobody can see.
        let shown = greetings([(.displaysDidSleep, 0), (.displaysDidWake, 300)])
        #expect(shown == [.seconds(300)])

        let alwaysGreets = greetings(
            [(.displaysDidSleep, 0), (.displaysDidWake, 0)],
            minimumAbsence: .zero
        )
        #expect(alwaysGreets == [.zero])
    }

    @Test("a brief return clears the absence rather than banking it")
    func briefReturnResetsTheClock() {
        // Otherwise a screensaver blip at breakfast would still be "in progress" at lunchtime and
        // the next blink of the display would greet for six hours the user spent at the machine.
        var policy = WelcomeBackPolicy()
        policy.handle(.displaysDidSleep, at: at(0))
        policy.handle(.displaysDidWake, at: at(5))
        #expect(policy.isTrackingAbsence == false)
        #expect(policy.handle(.displaysDidSleep, at: at(21_600)) == .departed)
        #expect(policy.handle(.displaysDidWake, at: at(21_605)) == .returnedBriefly(absence: .seconds(5)))
    }

    // MARK: - The awkward ones

    @Test("a maintenance wake with the displays dark does not spend the greeting")
    func darkWakeDoesNotConsumeTheAbsence() {
        // Power Nap wakes the machine overnight and puts it back to sleep. `didWake` arrives with
        // nobody in the room. If it counted as a return, the greeting would fire at 3am, expire
        // unseen four seconds later, and the morning's real lid-open would find an absence of a few
        // minutes and say nothing at all — a feature that silently stops working on exactly the
        // machines that sleep the most.
        var policy = WelcomeBackPolicy()
        #expect(policy.handle(.systemWillSleep, at: at(0)) == .departed)
        #expect(policy.handle(.systemDidWake, at: at(10_800)) == .unchanged)
        #expect(policy.userIsPresent == false)
        #expect(policy.handle(.systemWillSleep, at: at(10_830)) == .unchanged)

        #expect(policy.handle(.systemDidWake, at: at(28_800)) == .unchanged)
        #expect(policy.handle(.displaysDidWake, at: at(28_801)) == .welcomeBack(absence: .seconds(28_801)))
    }

    @Test("an unlock relights the displays, so a missing screensDidWake cannot silence the greeting")
    func unlockImpliesLitDisplays() {
        // Nobody types a password into a dark screen. Without this the model would need
        // `screensDidWake` to arrive after every system wake, and one missed delivery would leave
        // `displaysAreAwake` false for the life of the process — the greeting gone for good, with
        // nothing anywhere to say why.
        var policy = WelcomeBackPolicy()
        policy.handle(.systemWillSleep, at: at(0))
        policy.handle(.systemDidWake, at: at(7_200))
        #expect(policy.handle(.sessionDidUnlock, at: at(7_210)) == .welcomeBack(absence: .seconds(7_210)))
        #expect(policy.userIsPresent)
    }

    @Test("the absence is stamped at the first departure event, not the last")
    func absenceStartsAtTheFirstDeparture() {
        // Going away is three or four notifications a few milliseconds apart. Restamping on each
        // would measure the gap between the last two and every overnight absence would come out at
        // a fraction of a second.
        var policy = WelcomeBackPolicy()
        #expect(policy.handle(.sessionDidLock, at: at(0)) == .departed)
        #expect(policy.handle(.systemWillSleep, at: at(0.02)) == .unchanged)
        #expect(policy.handle(.displaysDidSleep, at: at(0.05)) == .unchanged)

        policy.handle(.systemDidWake, at: at(600))
        policy.handle(.displaysDidWake, at: at(600.1))
        #expect(policy.handle(.sessionDidUnlock, at: at(602)) == .welcomeBack(absence: .seconds(602)))
    }

    @Test("no single event from rest can produce a greeting", arguments: SystemEvent.allCases)
    func noEventGreetsFromRest(event: SystemEvent) {
        // A fresh policy believes the user is at the machine, because the only way to be running is
        // for somebody to have logged in. Nothing that arrives first should ever say hello.
        var policy = WelcomeBackPolicy()
        if case .welcomeBack = policy.handle(event, at: at(0)) {
            Issue.record("\(event) greeted a user who never went away")
        }
    }

    @Test("presence is the conjunction of all three inputs", arguments: SystemEvent.allCases)
    func departureBreaksPresence(event: SystemEvent) {
        var policy = WelcomeBackPolicy()
        #expect(policy.userIsPresent)
        policy.handle(event, at: at(0))
        let isDeparture = [
            SystemEvent.systemWillSleep, .displaysDidSleep, .sessionDidLock,
        ].contains(event)
        #expect(policy.userIsPresent == !isDeparture)
        #expect(policy.isTrackingAbsence == isDeparture)
    }
}
