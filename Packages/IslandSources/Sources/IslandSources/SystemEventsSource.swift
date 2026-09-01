import IslandKit
import AppKit
import Foundation
import IslandActivities

/// §2.5. Greets the user when they come back to the Mac.
///
/// This is the wake/unlock moment, and the distinction is load-bearing rather than pedantic:
/// `loginwindow` runs in a separate secure context that no third party can draw into, so nothing
/// Isleta does is ever on a lock screen. What this source produces is an ordinary activity on the
/// user's own desktop, after they are already in, saying hello. Nothing in this file — or in its
/// tests, or in the copy it produces — should describe it any other way.
///
/// It is also the only source in the package that needs nothing granted (`SourceAuthorization`
/// `.notRequired`): every notification it listens to is public API or is posted openly by
/// `loginwindow` to the distributed center. That makes it the one source guaranteed to work on a
/// machine where the user has denied everything, and therefore the one worth wiring up first to
/// prove the source → coordinator → island path end to end.
///
/// **No timers, anywhere.** The events are all pushed; the absence is arithmetic on two instants;
/// the greeting's four-second dwell belongs to `ActivityKind.welcomeBack`'s expiry and is the
/// coordinator's single scheduled sleep, not ours. A delay of our own would have been the obvious
/// way to wait out a wake before deciding, and it is a trap: a `Task.sleep` outstanding when the
/// machine sleeps resumes on a clock that may or may not have counted the sleep, so the wait is
/// either instant or eight hours long depending on which clock the executor picked, and on a
/// machine that never sleeps neither branch is ever exercised.
///
/// ### The lock that arrives after the wake
///
/// "Require password *after 5 minutes*" is a real setting — `loginwindow` carries a
/// `_preferredScreenLockDelay` — and a machine that sleeps before that delay elapses has to lock at
/// some point on the way back up. So `com.apple.screenIsLocked` is not guaranteed to precede
/// `willSleep`; it can land after `didWake`, which means the conjunction in `WelcomeBackPolicy` can
/// briefly read as present between the wake and the lock, greet, and then greet again at the unlock.
///
/// That is left alone rather than defended against, because the first of those two greetings is
/// posted while `loginwindow` owns the screen. It is drawn on the user's desktop underneath a secure
/// context they cannot see past, and it expires four seconds later, unseen. The user sees exactly
/// one greeting — the one at the unlock, which is the correct one. Suppressing the duplicate with a
/// cooldown would suppress the *second* of the two, which is the visible one, and turn a harmless
/// invisible extra into a missing feature. Costing one discarded activity to keep that from
/// happening is the right trade.
@MainActor
public final class SystemEventsSource: ActivitySource {

    public static let sourceName = "SystemEvents"

    /// Nothing to ask for. Wake and display notifications are AppKit API and the lock/unlock pair
    /// is broadcast to every listener on the distributed center.
    public var authorization: SourceAuthorization { .notRequired }

    public var onActivity: ((any IslandActivity) -> Void)?

    /// Never called. The greeting is true for as long as it is on screen and then simply stops
    /// being interesting, which is `ActivityExpiry` — not a source knowing something changed. Set
    /// by the protocol, deliberately unused, and saying so here is cheaper than the next reader
    /// wondering what dismisses a welcome.
    public var onDismiss: ((ActivityID) -> Void)?

    /// `loginwindow` posts both of these on the distributed center. They are not declared in any
    /// SDK header — there is no public constant for them — so they are string literals, spelled
    /// once, next to the note of where they were verified: both appear in
    /// `/System/Library/CoreServices/loginwindow.app`, alongside its "Sending com.apple.screenIsUnlocked
    /// with uid:" log format and its use of `CFNotificationCenterGetDistributedCenter`.
    ///
    /// Public because the app shell listens to the same two, and for something this source knows
    /// nothing about: an island that is open when the screen locks has to be back in the notch
    /// before the fade (see `IslandScreenModel.collapseIntoNotch()`). That is a property of the
    /// island rather than of an activity, so it cannot ride in on `onActivity` — and it has to hold
    /// on a machine where this source is switched off, which is the other reason the shell
    /// registers its own observer rather than being handed these events. Spelled once, here, so the
    /// two registrations cannot drift onto different strings.
    public static let sessionDidLockName = Notification.Name("com.apple.screenIsLocked")
    public static let sessionDidUnlockName = Notification.Name("com.apple.screenIsUnlocked")

    private var policy: WelcomeBackPolicy
    private let now: @Sendable () -> Date
    private let elapsed: @Sendable () -> ContinuousClock.Instant

    /// Each observer paired with **the center it was registered on**.
    ///
    /// This source registers on two different notification centers, and a token is only meaningful
    /// to the one that issued it: handing a `DistributedNotificationCenter` token to
    /// `NotificationCenter.default` — or to `NSWorkspace.shared.notificationCenter`, which is also
    /// not the default center — removes nothing, raises nothing, and logs nothing. The observer
    /// stays live for the life of the process and the block keeps this object alive with it. Storing
    /// the pair is what makes `stop()` unable to get that wrong; a bare `[NSObjectProtocol]` plus
    /// two hardcoded removal calls is the version that leaks the moment somebody adds a third
    /// notification to the wrong loop.
    private var registrations: [(center: NotificationCenter, token: any NSObjectProtocol)] = []

    /// - Parameters:
    ///   - minimumAbsence: How long the user has to have been gone. See `WelcomeBackPolicy`.
    ///   - now: Wall clock, for the time of day the greeting is phrased in.
    ///   - elapsed: Continuous clock, for how long the absence lasted. Two clocks because neither
    ///     can do the other's job: wall clock is adjusted on wake and by the user, and the
    ///     continuous clock has no idea what "morning" is.
    public init(
        minimumAbsence: Duration = WelcomeBackPolicy.defaultMinimumAbsence,
        now: @escaping @Sendable () -> Date = Date.init,
        elapsed: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.policy = WelcomeBackPolicy(minimumAbsence: minimumAbsence)
        self.now = now
        self.elapsed = elapsed
    }

    /// `isolated deinit` (SE-0371), not a plain one.
    ///
    /// A plain `deinit` on a `@MainActor` class is nonisolated and cannot touch `registrations` at
    /// all — the compiler rejects it outright, because the tokens are not `Sendable`. The tempting
    /// way out is to keep the tokens in some nonisolated box so `deinit` can reach them, which trades
    /// a compile error for a second copy of the one piece of state whose whole job is to be
    /// authoritative. Isolating the deinit to the main actor instead keeps one list.
    ///
    /// Reaching here with a non-empty list means the source was dropped without `stop()`. The
    /// observers still go: a block observer left registered outlives the object it was registered
    /// for, and the center goes on delivering to it for the life of the process.
    isolated deinit {
        stop()
    }

    /// Whether the observers are registered. `start()` is idempotent on this.
    public var isObserving: Bool { !registrations.isEmpty }

    /// The user's threshold (`IsletaConfiguration.welcomeBackMinimumAbsence`), live.
    ///
    /// A pass-through to the one field on the policy rather than something this source stores, so
    /// there is no second copy to fall out of step — and an assignment rather than a rebuild, so a
    /// change of threshold does not reset an absence in progress. See `WelcomeBackPolicy`.
    ///
    /// Writable while the source is running and while it is stopped, because the app shell applies
    /// settings on a path that knows nothing about either: a source that had to be restarted to
    /// take a new threshold would silently discard an absence every time the slider moved.
    public var minimumAbsence: Duration {
        get { policy.minimumAbsence }
        set { policy.minimumAbsence = newValue }
    }

    /// Test seam: the centers the live observers sit on, in registration order.
    ///
    /// Exists because the distributed leak is invisible from outside. A token removed from the wrong
    /// center raises nothing and logs nothing, so "did `stop()` really unhook the `loginwindow`
    /// observers" is not a question any assertion about behavior can answer without broadcasting
    /// `com.apple.screenIsUnlocked` to every process on the machine.
    var observedCenters: [NotificationCenter] { registrations.map(\.center) }

    public func start() {
        // The controller rebuilds on every display change and a clamshell open emits several. A
        // second `start()` must not register a second set of observers, or one lid-open produces two
        // greetings — and the count would keep climbing for the life of the process.
        guard registrations.isEmpty else { return }

        let workspace = NSWorkspace.shared.notificationCenter
        observe(.systemWillSleep, named: NSWorkspace.willSleepNotification, on: workspace)
        observe(.systemDidWake, named: NSWorkspace.didWakeNotification, on: workspace)
        observe(.displaysDidSleep, named: NSWorkspace.screensDidSleepNotification, on: workspace)
        observe(.displaysDidWake, named: NSWorkspace.screensDidWakeNotification, on: workspace)

        let distributed = DistributedNotificationCenter.default()
        observe(.sessionDidLock, named: Self.sessionDidLockName, on: distributed)
        observe(.sessionDidUnlock, named: Self.sessionDidUnlockName, on: distributed)
    }

    public func stop() {
        for registration in registrations {
            registration.center.removeObserver(registration.token)
        }
        registrations.removeAll()

        // `policy` is deliberately left alone. It describes the machine, not this object: if Isleta
        // is stopped and restarted while the user is away — a settings toggle, a source being
        // re-wired — the absence that is genuinely in progress is still in progress, and resetting
        // to "present" here would swallow the greeting for it. Nothing false can be produced by
        // keeping it, because a greeting needs a departure this policy actually saw.
    }

    /// Register one notification and remember which center it came from.
    ///
    /// The event is resolved *here*, at registration, and captured by value. The block therefore
    /// never touches the `Notification` — which is not `Sendable` under strict concurrency, so
    /// reading even its name inside a `@MainActor` hop is a compile error rather than a subtle race.
    /// Nothing in this source needs the payload: which notification fired is the entire message.
    private func observe(_ event: SystemEvent, named name: Notification.Name, on center: NotificationCenter) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            // `queue: .main` puts this on the main thread, but the compiler cannot know that, and
            // `MainActor.assumeIsolated` is the assertion that says so. The alternative —
            // `Task { @MainActor in … }` — is wrong twice over: it defers the work past the current
            // run loop turn, so two notifications arriving together can be reordered, and wake
            // before unlock versus unlock before wake is the one ordering this whole source is
            // about; and a task already enqueued when `stop()` runs still fires afterwards, which
            // makes "stop leaves nothing behind" untrue in exactly the way that is hard to see.
            MainActor.assumeIsolated {
                self?.receive(event)
            }
        }
        registrations.append((center: center, token: token))
    }

    /// Fold in an event that really happened.
    private func receive(_ event: SystemEvent) {
        receive(event, at: elapsed())
    }

    /// Fold in an event at a given instant. The seam the tests drive: the whole matrix of §2.5 is
    /// reachable from here without sleeping a machine, and an eight-hour absence costs a
    /// `ContinuousClock.Instant.advanced(by:)`.
    func receive(_ event: SystemEvent, at instant: ContinuousClock.Instant) {
        let outcome = policy.handle(event, at: instant)
        // A handful of lines a day, and the only record of the order these arrived in — which is
        // the whole question when a greeting fails to appear after a lid open.
        IslandLog.system.info("\(event) → \(outcome)")
        guard case .welcomeBack = outcome else { return }
        onActivity?(WelcomeBackGreeting(at: now()).activity)
    }
}
