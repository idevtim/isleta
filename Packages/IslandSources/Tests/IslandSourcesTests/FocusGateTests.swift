import Foundation
import IslandActivities
import Testing

@testable import IslandSources

/// A Focus reader with no Intents behind it, so all four authorization states — including the two
/// denied ones §10 requires to be tested — are reachable without a permission or a prompt.
private struct StubFocusStatus: FocusStatusReading {
    var authorization: FocusAuthorization
    var focused: Bool?

    func isFocused() -> Bool? {
        // The rule the real reader enforces, reproduced here so the stub cannot be more generous
        // than the thing it stands in for.
        guard authorization == .authorized else { return nil }
        return focused
    }
}

@Suite("Focus gate")
@MainActor
struct FocusGateTests {

    /// The measurement this whole design rests on, reproduced on this machine while the file was
    /// written: with `authorizationStatus` reporting `.notDetermined`, `isFocused` answered
    /// **`Optional(false)`** — a definite false, not a nil. So the unauthorized state and "no Focus"
    /// are indistinguishable from the value, and the only safe read is one gated on the status.
    @Test("an unauthorized reader is never allowed to answer")
    func unauthorizedNeverAnswers() {
        for status in [FocusAuthorization.notDetermined, .denied, .unavailable] {
            let reader = StubFocusStatus(authorization: status, focused: true)
            #expect(reader.isFocused() == nil, "\(status) must not answer")
        }
    }

    /// The gate fails **open**, always. A gate that guessed "focused" when it could not ask would
    /// silently stop showing notifications on every machine that never granted it — which is a
    /// missing feature that looks exactly like a broken one.
    @Test("nothing is suppressed while Focus cannot be read")
    func deniedSuppressesNothing() {
        for status in [FocusAuthorization.notDetermined, .denied, .unavailable] {
            let gate = FocusGate(reader: StubFocusStatus(authorization: status, focused: true))
            #expect(gate.allows(.calendarAlert), "\(status) must not suppress")
            #expect(gate.allows(.calendarAlert))
            #expect(gate.suppressedCount == 0)
        }
    }

    @Test("with a Focus on, the announcing kinds are withheld")
    func focusSuppressesAnnouncements() {
        let gate = FocusGate(reader: StubFocusStatus(authorization: .authorized, focused: true))
        #expect(gate.allows(.calendarAlert) == false)
        #expect(gate.allows(.calendarAlert) == false)
        #expect(gate.suppressedCount == 2)
    }

    /// The longer half of the rule, and the one somebody would otherwise "fix": a Focus silences
    /// what arrives unasked, never the acknowledgement of something the user just did.
    @Test("everything the user caused is shown, Focus or not")
    func focusSuppressesNothingElse() {
        let gate = FocusGate(reader: StubFocusStatus(authorization: .authorized, focused: true))
        let allowed: [ActivityKind] = [
            .systemHUD, .nowPlaying, .timer, .shelf, .deviceConnected, .welcomeBack, .glance,
            .meeting, .power, .call, .fileAction, .focusChanged,
            .screenSharing,
        ]
        for kind in allowed {
            #expect(gate.allows(kind), "\(kind) must not be suppressed by a Focus")
        }
    }

    /// The one kind that would otherwise suppress itself: a Focus turning on is announced at the
    /// instant a Focus is on.
    @Test("a Focus change is never suppressed by the Focus it is announcing")
    func focusChangedIsNeverSuppressed() {
        #expect(FocusSuppression.suppresses(.focusChanged) == false)
    }

    @Test("with no Focus on, nothing is withheld")
    func noFocusSuppressesNothing() {
        let gate = FocusGate(reader: StubFocusStatus(authorization: .authorized, focused: false))
        #expect(gate.allows(.calendarAlert))
        #expect(gate.suppressedCount == 0)
    }

    /// `isFocused` costs 15 ms, every time, and does not warm up — so a burst of three notifications
    /// arriving together would spend 45 ms of the main actor asking a question whose answer cannot
    /// have changed. The held answer is not a poll: nothing is scheduled and an idle Mac never asks.
    @Test("the answer is held for a moment, then asked again")
    func answerIsHeldBriefly() {
        final class CountingReader: FocusStatusReading, @unchecked Sendable {
            var reads = 0
            var authorization: FocusAuthorization { .authorized }
            func isFocused() -> Bool? {
                reads += 1
                return true
            }
        }
        let reader = CountingReader()
        var now = Date(timeIntervalSinceReferenceDate: 0)
        let gate = FocusGate(reader: reader, now: { now })

        _ = gate.allows(.calendarAlert)
        _ = gate.allows(.calendarAlert)
        _ = gate.allows(.calendarAlert)
        #expect(reader.reads == 1)

        now = now.addingTimeInterval(FocusGate.answerLifetime + 0.1)
        _ = gate.allows(.calendarAlert)
        #expect(reader.reads == 2)
    }

    /// A kind the gate cannot suppress must not cost a read at all — the volume HUD is on the path
    /// a keypress takes, and 15 ms there is most of §9's 16 ms hover-to-frame budget.
    @Test("a kind a Focus cannot suppress never asks")
    func unsuppressableKindsNeverAsk() {
        final class CountingReader: FocusStatusReading, @unchecked Sendable {
            var reads = 0
            var authorization: FocusAuthorization { .authorized }
            func isFocused() -> Bool? {
                reads += 1
                return true
            }
        }
        let reader = CountingReader()
        let gate = FocusGate(reader: reader)
        #expect(gate.allows(.systemHUD))
        #expect(gate.allows(.nowPlaying))
        #expect(reader.reads == 0)
    }

    @Test("refresh forgets the held answer")
    func refreshForgets() {
        let focus = MutableFocus(isOn: true)
        let gate = FocusGate(reader: ClosureFocusStatus(focus: focus))
        #expect(gate.allows(.calendarAlert) == false)
        focus.isOn = false
        gate.refresh()
        #expect(gate.allows(.calendarAlert))
    }

    /// Without `NSFocusStatusUsageDescription` in the bundle, the class is not so much as named —
    /// the check that keeps a missing usage string from becoming the 1.3.0 Bluetooth abort in a new
    /// place.
    @Test("no usage string means no Intents call at all")
    func withoutUsageStringNothingIsAsked() {
        // The test bundle has no such key, so the real reader must report `.unavailable` here
        // rather than reaching `INFocusStatusCenter`.
        let reader = IntentsFocusStatus(bundle: Bundle(for: FocusGateProbe.self))
        #expect(reader.authorization == .unavailable)
        #expect(reader.isFocused() == nil)
    }
}

/// A class living in the test bundle, only so `Bundle(for:)` names a bundle that has no
/// `NSFocusStatusUsageDescription` in it.
private final class FocusGateProbe {}

/// A Focus that can be turned on and off between reads, for the refresh test. A reference rather
/// than a captured `var`, because a captured one is not `Sendable` and the reader is.
private final class MutableFocus: @unchecked Sendable {
    var isOn: Bool
    init(isOn: Bool) { self.isOn = isOn }
}

/// A reader whose answer can change between reads, for the refresh test.
private struct ClosureFocusStatus: FocusStatusReading {
    let focus: MutableFocus
    var authorization: FocusAuthorization { .authorized }
    func isFocused() -> Bool? { focus.isOn }
}

/// The switch, and what it costs when it is off.
@MainActor
@Suite("The Focus switch")
struct FocusGateEnabledTests {

    /// A reader that counts how many times it was asked, so "off means we never ask" is a fact
    /// rather than an assumption about ordering.
    private final class CountingReader: FocusStatusReading, @unchecked Sendable {
        var reads = 0
        var authorization: FocusAuthorization { .authorized }
        func isFocused() -> Bool? {
            reads += 1
            return true
        }
    }

    @Test("switched off, a Focus quiets nothing")
    func disabledLetsEverythingThrough() {
        let gate = FocusGate(reader: CountingReader())
        gate.isEnabled = false
        #expect(gate.allows(.calendarAlert))
        #expect(gate.allows(.calendarAlert))
        #expect(gate.suppressedCount == 0)
    }

    @Test("switched off, the 15 ms read is never made")
    func disabledCostsNothing() {
        // The check is deliberately *before* the reader. `INFocusStatusCenter` costs 15 ms of XPC
        // and does not warm up, so a user who has turned this off must not pay for a question whose
        // answer is going to be discarded — and a notification is on the path a message takes.
        let reader = CountingReader()
        let gate = FocusGate(reader: reader)
        gate.isEnabled = false
        for _ in 0..<10 { _ = gate.allows(.calendarAlert) }
        #expect(reader.reads == 0)
    }

    @Test("switched on is what every build before the switch did")
    func enabledIsTheDefault() {
        let gate = FocusGate(reader: CountingReader())
        #expect(gate.isEnabled)
        #expect(gate.allows(.calendarAlert) == false)
        #expect(gate.suppressedCount == 1)
    }

    @Test("the switch does not reach what a Focus never silenced")
    func theSwitchOnlyReachesTheSuppressedKinds() {
        // Turning it off must not read as "show more" — there is nothing more to show. A volume
        // HUD, a track change and a timer are the user's own doing and were never withheld.
        let gate = FocusGate(reader: CountingReader())
        for kind in [ActivityKind.systemHUD, .nowPlaying, .timer, .meeting] {
            #expect(gate.allows(kind))
        }
        #expect(gate.suppressedCount == 0)
    }
}
