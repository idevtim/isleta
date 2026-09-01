import Foundation
import Intents
import IslandActivities
import IslandKit

/// What Isleta is allowed to know about the user's Focus.
///
/// Four cases rather than three, because "we cannot ask at all" is a real state here and is not a
/// refusal: without `NSFocusStatusUsageDescription` in the Info.plist there is no request to make,
/// and a build in that state must behave as though Focus did not exist rather than as though the
/// user had said no.
public enum FocusAuthorization: Equatable, Sendable {
    case unavailable
    case notDetermined
    case authorized
    case denied
}

/// Reading whether a Focus is on. A seam, so the gate's whole matrix — including the denied state
/// §10 requires to be tested — is reachable without a permission, a prompt or a Focus.
public protocol FocusStatusReading: Sendable {

    var authorization: FocusAuthorization { get }

    /// Whether a Focus is on, or **nil when nobody is allowed to say**.
    ///
    /// The nil is the entire point of this method's signature. See `IntentsFocusStatus`.
    func isFocused() -> Bool?

    /// Raise the system's Focus request. The only call in this file that can put a dialog on screen,
    /// and it must be reached from a moment the user initiated (§10).
    func requestAuthorization() async
}

public extension FocusStatusReading {
    /// A reader that cannot ask has nothing to do here — the stubs and the unavailable conformance
    /// inherit this rather than each writing an empty method.
    func requestAuthorization() async {}
}

/// `INFocusStatusCenter`, read defensively.
///
/// # The value lies, and it lies confidently
///
/// Reproduced on this machine while writing this file: with `authorizationStatus` reporting
/// **`.notDetermined` (0)**, `focusStatus.isFocused` answered **`Optional(false)`** — a definite
/// `false`, not the `nil` an unanswerable question deserves. The same `Optional(false)` comes back
/// after authorization when no Focus is on. So the two states are indistinguishable from the value,
/// and any code that reads `isFocused` without first checking the status will tell a user sitting in
/// Do Not Disturb, with total confidence, that no Focus is active.
///
/// That is why `isFocused()` here returns nil unless the status is `.authorized`, and why the
/// property is never read anywhere else in the package.
///
/// # Nothing is touched without the usage string
///
/// The class is not so much as named unless `NSFocusStatusUsageDescription` is in the running
/// bundle's Info.plist. TCC judges an access request against the *responsible* process and answers a
/// missing usage string for some services by **aborting the process** —
/// `__TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION__`, which is what a missing
/// `NSBluetoothAlwaysUsageDescription` did to 1.3.0, 270 ms into every real launch, after every
/// shell-run check had passed. Whether `kTCCServiceFocusStatus` behaves that way for a *status read*
/// is not something this file needs to find out: checking one dictionary key first costs nothing and
/// removes the question.
///
/// # There is no change notification, anywhere
///
/// `INFocusStatusCenter.h` declares two properties and one method and no notification constant; a
/// string sweep of Intents finds no `DidChange` name; `DoNotDisturb`, `DoNotDisturbKit`,
/// `DoNotDisturbServer` and `Focus.framework` carry no Darwin names for state — only private XPC
/// (`DNDModeAssertionService.registerForAssertionUpdates`). So a live Focus indicator would need a
/// poll, and §9 forbids one. Focus is a **gate**, consulted when an activity is about to be
/// published, and it drives no activity of its own.
public struct IntentsFocusStatus: FocusStatusReading {

    /// The key that has to be in the Info.plist before any of this is touched.
    public static let usageDescriptionKey = "NSFocusStatusUsageDescription"

    private let hasUsageDescription: Bool

    public init(bundle: Bundle = .main) {
        self.hasUsageDescription = bundle.object(forInfoDictionaryKey: Self.usageDescriptionKey) != nil
    }

    public var authorization: FocusAuthorization {
        guard hasUsageDescription else { return .unavailable }
        return switch INFocusStatusCenter.default.authorizationStatus {
        case .authorized: .authorized
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }

    public func isFocused() -> Bool? {
        guard authorization == .authorized else { return nil }
        return INFocusStatusCenter.default.focusStatus.isFocused
    }

    /// The prompt. Measured at **8.42 s** from the call to `.authorized` — because that interval is
    /// a person reading a dialog, which is why it is `async` and why it is never on a launch path.
    ///
    /// A no-op unless the answer is genuinely unknown: macOS will not show the dialog a second time
    /// after a refusal, so asking again would be a button that visibly does nothing, which is the
    /// nagging §10 names.
    public func requestAuthorization() async {
        guard authorization == .notDetermined else { return }
        await withCheckedContinuation { continuation in
            INFocusStatusCenter.default.requestAuthorization { _ in continuation.resume() }
        }
    }
}

/// A reader for tests and for a build with no Focus at all.
public struct UnavailableFocusStatus: FocusStatusReading {
    public init() {}
    public var authorization: FocusAuthorization { .unavailable }
    public func isFocused() -> Bool? { nil }
}

/// Which kinds a Focus silences, and — the longer list — which it does not.
///
/// The rule is one sentence: **a Focus silences what arrives unasked and is not the user's own
/// doing.** Everything else stays, and each exclusion below is a case somebody would otherwise
/// "fix" into the suppressed list.
public enum FocusSuppression {

    public static func suppresses(_ kind: ActivityKind) -> Bool {
        switch kind {
        // An announcement about somebody else's claim on the user's attention, which is exactly
        // what a Focus is turned on to hold off. This is the *whole* mechanism for a calendar
        // alert, which EventKit raises whether or not anybody wants to be told.
        case .calendarAlert: true
        // A meeting is deliberately **not** suppressed, and it is the one judgement call here. It
        // is the only announcing kind that carries a button, a Work Focus is precisely when
        // meetings happen, and the cost of the two mistakes is not symmetric: an unwanted island
        // for four seconds against missing the meeting the Focus was turned on to concentrate for.
        case .meeting: false
        // Everything the user themselves just did. A volume key, a charger, AirPods going in, a
        // file dropped on the island, a timer they set — silencing the acknowledgement of an action
        // is not quiet, it is a broken app.
        case .systemHUD, .shelf, .deviceConnected, .fileAction, .timer,
             .welcomeBack, .glance: false
        // Conditions rather than announcements: true for as long as they are true, and drawn
        // because the user looked, not because Isleta spoke.
        case .nowPlaying, .screenSharing: false
        // A ringing or connected call outranks a Focus, which has its own allow-calls rules that
        // this app cannot see. A dying battery outranks everything.
        case .call, .power: false
        // The one kind that would suppress itself: a Focus turning *on* is announced at the instant
        // a Focus is on. It is also the explanation for the silence everything above causes.
        case .focusChanged: false
        }
    }
}

/// "A Focus is on, do not show this" — asked once, when an activity is about to be published.
///
/// # Why the answer is held for a moment
///
/// Measured on this machine: `INFocusStatusCenter.default.focusStatus.isFocused` costs **15 ms**,
/// and a second read immediately afterwards costs **15 ms** again — it is XPC and it does not warm
/// up. `authorizationStatus` costs **21 ms** the first time. Fifteen milliseconds on the main actor
/// is most of §9's 16 ms hover-to-frame budget, and a burst of three notifications would spend 45 ms
/// of it asking a question whose answer cannot have changed.
///
/// So the answer is reused for one second. That is **not** a poll and not a timer: nothing is
/// scheduled, nothing wakes, and an idle Mac never asks at all — the read happens only when
/// something is about to go on the island, and only for the two kinds a Focus can suppress.
@MainActor
public final class FocusGate {

    /// One second. Long enough to cover a burst of notifications arriving together, short enough
    /// that turning Do Not Disturb off and immediately expecting your messages works.
    static let answerLifetime: TimeInterval = 1

    private let reader: any FocusStatusReading
    private let now: () -> Date

    private var lastAnswer: Bool?
    private var lastAsked: Date?

    /// How many activities have been withheld this launch. A count, which is the one thing a bug
    /// report saying "Isleta stopped showing my notifications" actually needs.
    public private(set) var suppressedCount = 0

    /// Whether the user wants a Focus to quiet the island.
    ///
    /// **This is `SourceToggles.respectsFocus`, and it is what that flag became.** It shipped as
    /// `focusChanges` — a switch for *announcing* a Focus turning on, which nothing can do, because
    /// macOS has no change notification for Focus anywhere (see `IntentsFocusStatus`). A switch that
    /// can never move is the `suppressSystemHUDs` mistake, and CLAUDE.md records the answer to that
    /// one: it was removed rather than grayed. This is the other answer — the slot held a live
    /// question all along, just not the one it was named for.
    ///
    /// On by default, because that is what every build before it did: the gate has always
    /// suppressed a notification while a Focus is on, with no way to say otherwise. Turning it off
    /// is the user saying they want the island to speak through a Focus, which is a real preference
    /// and not one this app should decide for them.
    ///
    /// Checked **before** the reader, so a user who has switched this off pays no XPC round trip at
    /// all — the 15 ms read is skipped rather than made and discarded.
    public var isEnabled = true

    public init(
        reader: any FocusStatusReading = IntentsFocusStatus(),
        now: @escaping () -> Date = Date.init
    ) {
        self.reader = reader
        self.now = now
    }

    public var authorization: FocusAuthorization { reader.authorization }

    /// Whether this kind may go on the island right now.
    ///
    /// Answers true for everything when Focus cannot be read — which is the state of every build
    /// until the user has granted it, and the reason the gate cannot make the app quieter than it
    /// was: an unknown Focus is treated as no Focus, always.
    public func allows(_ kind: ActivityKind) -> Bool {
        guard isEnabled else { return true }
        guard FocusSuppression.suppresses(kind) else { return true }
        guard isFocused() else { return true }
        suppressedCount += 1
        // The kind, never the activity. What was withheld is the user's own mail, and this line is
        // in the file people are asked to attach to a bug report.
        IslandLog.system.info("focus: withheld a \(kind.rawValue) — a Focus is on")
        return false
    }

    /// Ask the user for permission to read their Focus, from a moment they initiated.
    ///
    /// Kept on the gate rather than on the reader's caller so there is exactly one path to the
    /// dialog, and so the held answer is thrown away the instant the answer could have changed.
    public func requestAuthorizationFromUserInitiatedMoment() async {
        await reader.requestAuthorization()
        refresh()
    }

    /// Forget the held answer, for the moment the user comes back from System Settings.
    public func refresh() {
        lastAsked = nil
        lastAnswer = nil
    }

    private func isFocused() -> Bool {
        let instant = now()
        if let lastAsked, let lastAnswer, instant.timeIntervalSince(lastAsked) < Self.answerLifetime {
            return lastAnswer
        }
        // nil — not authorized, or no usage string — is "no Focus", never "quiet". The island
        // failing open is the only safe direction: a gate that guessed "focused" would silently
        // stop showing notifications on every machine that never granted it.
        let answer = reader.isFocused() ?? false
        lastAsked = instant
        lastAnswer = answer
        return answer
    }
}


/// Deep link to the Focus row of System Settings ▸ Privacy & Security.
///
/// Beside the three that already exist (`AudioBadgeAccessibility`, `BluetoothPrivacySettings`,
/// `GlancePrivacySettings`) rather than in the settings module, for their reason: a URL that names a
/// pane of System Settings is a fact about macOS, and it belongs with the code that knows why it is
/// needed. `kTCCServiceFocusStatus` is a real TCC service — unlike location, which is not — so this
/// one is an ordinary privacy pane.
public enum FocusPrivacySettings {

    public static let settingsURLString =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Focus"
}
