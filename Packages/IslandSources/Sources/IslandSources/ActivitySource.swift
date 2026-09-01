import Foundation
import IslandActivities

/// Whether a source is allowed to do its job, and what to say when it is not.
///
/// Every source in this package is permission-gated or platform-gated in some way, and §10 requires
/// each one to be fully usable in the **denied** state with a clear explanation of what granting it
/// would unlock — and no nagging. Modeling that as a value rather than a `Bool` is what stops
/// "denied" and "not asked yet" collapsing into the same case: they read identically to code and
/// mean opposite things to a user, who should be offered a prompt in one and an explanation in the
/// other.
public enum SourceAuthorization: Equatable, Sendable {

    /// The source needs nothing granted. Wake and unlock notifications are public API.
    case notRequired

    /// Granted, or inferred to be working because the source produced data.
    case granted

    /// The user has not been asked. A source in this state must not ask on its own — §10 says the
    /// prompt belongs to a moment the user initiated, not to launch.
    case undetermined

    /// Refused, or unavailable for a reason the user cannot change (an entitlement we do not hold).
    /// The string is shown to the user, so it says what is lost, not what failed.
    case denied(explanation: String)

    /// Whether the source can be expected to produce anything.
    public var isUsable: Bool {
        switch self {
        case .notRequired, .granted: true
        case .undetermined, .denied: false
        }
    }
}

/// One route to system state, feeding the activity stack.
///
/// The shape is deliberately narrow, and it is a *push* interface rather than a pull one: §9 forbids
/// polling on the idle path, so a source that cannot be driven by a notification or a callback has
/// to say so by only running while its activity is presented. Nothing here returns "the current
/// value" on demand, because a getter is the thing a caller eventually puts in a timer.
///
/// `@MainActor` for the same reason `ActivityCoordinator` is: this is where a source hands its work
/// over, and one hop at the boundary is cheaper and easier to reason about than an `await` on every
/// read from a SwiftUI `body`. A source is free to do its real work — spawning a helper, watching an
/// AX observer, parsing output — off the main actor, and hop once to publish.
@MainActor
public protocol ActivitySource: AnyObject {

    /// Stable identity for diagnostics and for the per-source toggles IslandSettings will grow.
    static var sourceName: String { get }

    /// What this source is currently allowed to do. Read on demand — never cached at launch, because
    /// the user can change it in System Settings while Isleta is running.
    var authorization: SourceAuthorization { get }

    /// Begin observing. Must be idempotent: the controller rebuilds on display changes, and a source
    /// started twice must not double-publish.
    func start()

    /// Stop observing and release everything. Must leave no timer, no observer, and no child process
    /// behind — §9's idle budget is measured with sources running.
    func stop()

    /// `stop()`, with the additional promise that nothing is left for *after* it returns.
    ///
    /// Called only from `applicationWillTerminate`, which returns into `exit()`. Work a source
    /// defers to a queue, a timer or a completion handler does not merely run late there — it never
    /// runs, and anything that work was going to release stays leaked. `NowPlayingSource` learned
    /// this the expensive way; see `NowPlayingAdapterReader`.
    ///
    /// Defaulted to `stop()`, which is the honest answer for a source whose teardown is already
    /// synchronous. Override only when there is something the kernel still knows about.
    func stopAndWait()

    /// Called when the source has something for the island to say.
    var onActivity: ((any IslandActivity) -> Void)? { get set }

    /// Called when what the source was saying is no longer true — a track stopped, a notification
    /// was dismissed. Distinct from expiry, which the activity itself carries: this is the source
    /// knowing, rather than the clock assuming.
    var onDismiss: ((ActivityID) -> Void)? { get set }
}

public extension ActivitySource {
    var sourceName: String { Self.sourceName }

    /// Sources with nothing outliving the process inherit this.
    func stopAndWait() { stop() }
}
