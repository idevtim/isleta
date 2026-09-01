import Foundation

/// One thing the system told us about whether the user can see the screen.
///
/// Deliberately *not* the notification names. The names are AppKit and `loginwindow` vocabulary and
/// they arrive on two different notification centers; this enum is the vocabulary the decision is
/// made in, so `WelcomeBackPolicy` is a pure value type that a test can drive through an eight-hour
/// absence in microseconds. Every awkward case in §2.5 — a wake with no unlock, an unlock with no
/// wake, both in either order, a five-second screensaver blip — is an ordering of these six values,
/// and an ordering is something you can write down in a test rather than reproduce by closing a lid.
public enum SystemEvent: String, CaseIterable, Sendable, Equatable {

    /// `NSWorkspace.willSleepNotification`. The system is going to sleep; the displays go dark with
    /// it, which is why this marks both the system and the displays as asleep.
    case systemWillSleep

    /// `NSWorkspace.didWakeNotification`. The system has power again — and *only* that. See
    /// `WelcomeBackPolicy` for why this on its own is not a person.
    case systemDidWake

    /// `NSWorkspace.screensDidSleepNotification`. The displays went dark without the system
    /// sleeping: the idle display timer, or the user pressing the sleep-display key.
    case displaysDidSleep

    /// `NSWorkspace.screensDidWakeNotification`. The displays are lit again.
    case displaysDidWake

    /// `com.apple.screenIsLocked`, posted by `loginwindow` on the distributed center.
    case sessionDidLock

    /// `com.apple.screenIsUnlocked`, posted by `loginwindow` on the distributed center. The only
    /// event in this list that a machine cannot generate by itself — somebody authenticated.
    case sessionDidUnlock
}

/// Decides when a return is worth greeting, from nothing but a stream of `SystemEvent`s and a clock.
///
/// The naive version of this — "greet on `didWake`, and also on `screenIsUnlocked`" — is wrong in
/// both directions at once. It greets twice for one lid-open on any Mac that asks for a password
/// (wake and unlock are both delivered, in that order, for a single physical return), and it greets
/// at all for a thirty-second lock the user did on their way past the desk. Neither is fixable by
/// debouncing, because the two failures want opposite fixes.
///
/// So presence is modelled instead of return events, and it is a **conjunction**: the user is here
/// when the system is awake *and* the displays are lit *and* the session is unlocked. Each event
/// sets only the flags it actually proves. An absence begins at the first event that breaks the
/// conjunction and ends at the first event that restores it, which makes "one welcome back per
/// absence" fall out of the structure rather than out of a suppression window — there is only ever
/// one absence outstanding, and greeting it clears it.
///
/// Two consequences worth stating, because they are the reason for the shape:
///
/// - **A dark wake is not a return.** Power Nap and network wakes reach `didWake` with the displays
///   still dark. `systemDidWake` therefore clears only `systemIsAwake`, never `displaysAreAwake`,
///   so the conjunction stays false and the absence survives to be greeted when the user really
///   does open the lid. Had `didWake` been treated as a return, the greeting would have been spent
///   on a maintenance wake at 3am — expiring unseen four seconds later — and the user would open
///   the lid in the morning to nothing at all, with no error anywhere to explain it.
/// - **An unlock proves the displays are lit.** Nobody types a password into a dark screen, so
///   `sessionDidUnlock` clears `displaysAreAwake` as well. That is not an optimisation; it is the
///   safety net for a `screensDidWake` that never arrives, and without it a single missed display
///   notification would silence the greeting permanently rather than once.
public struct WelcomeBackPolicy: Sendable, Equatable {

    /// How long the user has to have been gone for coming back to be an event.
    ///
    /// Five minutes. The number has to sit above the two things that are not absences — locking the
    /// screen to fetch something from the next room, and a screensaver that catches you mid-read —
    /// and below the shortest thing that is: a meeting, a lunch, a commute. Anything under about a
    /// minute would greet the user for turning around; anything over about fifteen would stay silent
    /// for a genuine walk round the block. It is a stored constant rather than a literal at the use
    /// site because IslandSettings wants it — it is the default behind
    /// `IsletaConfiguration.welcomeBackMinimumAbsence` — and because a threshold spelled once is a
    /// threshold the tests and the shipping default cannot disagree about. It is a *default* and
    /// not the value: the user's is read from the settings store and written to `minimumAbsence`.
    public static let defaultMinimumAbsence: Duration = .seconds(300)

    /// Settable, and settable *without* disturbing anything else in this value.
    ///
    /// The user can move this slider while an absence is being timed — they are, by definition, at
    /// the Mac, so the absence in question is one that has already ended, but the same is not true
    /// of a settings change applied at launch on a machine that woke to a login. Assigning the one
    /// field leaves `absenceBegan` and the three presence flags exactly as they were, so a threshold
    /// change costs the user nothing. Rebuilding the whole policy to change it would reset all four
    /// and swallow the greeting for an absence genuinely in progress.
    public var minimumAbsence: Duration

    /// The three halves of "the user can see the island". All three start true: the only way to be
    /// running this code at `start()` is for somebody to have logged in on a lit screen.
    private var systemIsAwake = true
    private var displaysAreAwake = true
    private var sessionIsUnlocked = true

    /// When the current absence began, or nil if the user is here. Measured on `ContinuousClock`
    /// rather than `Date` — see `handle(_:at:)`.
    private var absenceBegan: ContinuousClock.Instant?

    public init(minimumAbsence: Duration = Self.defaultMinimumAbsence) {
        self.minimumAbsence = minimumAbsence
    }

    /// Whether the user can currently see the screen, as far as the events say.
    public var userIsPresent: Bool { systemIsAwake && displaysAreAwake && sessionIsUnlocked }

    /// Whether an absence is being timed.
    public var isTrackingAbsence: Bool { absenceBegan != nil }

    /// What an event did. Every case except `welcomeBack` is inert at the call site; they exist so
    /// tests and the diagnostics dump can tell "we ignored that" from "we did not see that".
    public enum Outcome: Equatable, Sendable {

        /// The event changed nothing that matters — a duplicate unlock, a wake we were already
        /// awake for.
        case unchanged

        /// The user just left. Nothing is shown for this; it is the clock starting.
        case departed

        /// The user came back, but not from far enough away to be worth saying anything about.
        case returnedBriefly(absence: Duration)

        /// The user came back after a real absence. Show it.
        case welcomeBack(absence: Duration)
    }

    /// Fold one event into the model and say whether it completed a greetable return.
    ///
    /// `instant` is a `ContinuousClock` reading, and the choice matters more than it looks.
    /// `SuspendingClock` — which is what `mach_absolute_time` and therefore most "monotonic clock"
    /// advice gives you — *stops while the machine is asleep*, so an eight-hour lid-closed absence
    /// measures as the few milliseconds between `willSleep` and `didWake` and is discarded as too
    /// brief. `Date` advances across sleep but is wall clock: it is resynchronized on wake and moves
    /// when the user changes the time zone, so an absence can come back negative or wildly long from
    /// a clock correction rather than from anything the user did. `ContinuousClock` is the only one
    /// of the three that measures elapsed real time across sleep and ignores clock adjustments, and
    /// the greeting *text* takes the wall clock separately because time of day is exactly the thing
    /// `ContinuousClock` cannot tell you.
    @discardableResult
    public mutating func handle(_ event: SystemEvent, at instant: ContinuousClock.Instant) -> Outcome {
        let wasPresent = userIsPresent

        switch event {
        case .systemWillSleep:
            // The displays go dark as part of the system going down, and no `screensDidSleep` is
            // owed to us for it. Setting both here is what makes the dark-wake defense work: only
            // `displaysDidWake` or an unlock can light them again.
            systemIsAwake = false
            displaysAreAwake = false
        case .systemDidWake:
            systemIsAwake = true
        case .displaysDidSleep:
            displaysAreAwake = false
        case .displaysDidWake:
            displaysAreAwake = true
        case .sessionDidLock:
            sessionIsUnlocked = false
        case .sessionDidUnlock:
            sessionIsUnlocked = true
            displaysAreAwake = true
        }

        switch (wasPresent, userIsPresent) {
        case (true, false):
            // The absence is stamped at the *first* event that broke the conjunction and never
            // restamped, because a going-away sequence is several events a few milliseconds apart —
            // lock, then sleep, then displays off. Taking the latest would turn every overnight
            // absence into a twenty-millisecond one and nothing would ever be greeted.
            absenceBegan = instant
            return .departed

        case (false, true):
            guard let began = absenceBegan else { return .unchanged }
            absenceBegan = nil
            let absence = began.duration(to: instant)
            // `>=` so a policy constructed with `.zero` for a test greets rather than silently
            // never firing, which is the shape of threshold bug that survives review.
            return absence >= minimumAbsence
                ? .welcomeBack(absence: absence)
                : .returnedBriefly(absence: absence)

        default:
            // Already away, or never left. The second of two consecutive unlocks lands here — the
            // absence was consumed by the first, so there is nothing left to greet. That is why
            // this needs no cooldown timer, and why it must not have one: a cooldown would suppress
            // the *later* of two greetings, and where the two orderings differ the later one is the
            // one the user is actually in front of. See `SystemEventsSource` on the lock that
            // arrives after the wake.
            return .unchanged
        }
    }
}
