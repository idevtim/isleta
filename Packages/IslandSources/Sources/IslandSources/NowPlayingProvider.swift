import Foundation

/// One route to what is playing.
///
/// Three conformances exist (§2.4): the vendored `mediaremote-adapter`, a per-app scripting
/// fallback, and `NullNowPlayingProvider`. They are behind a protocol because two of the three are
/// gated on things Isleta does not control — an Apple entitlement policy that changed under us in
/// macOS 15.4, and a TCC permission the user may refuse — and the app must be whole when both are
/// unavailable. §12.3's rule that no feature may require SIP to be disabled is the same rule stated
/// from the other end: if a capability can only be had by breaking the user's machine, the product
/// does without it, which means the seam for doing without it has to be load-bearing rather than
/// vestigial.
///
/// Push, never pull, for the same reason `ActivitySource` is: there is no `currentTrack` getter
/// here, because a getter is the thing a caller eventually puts in a timer and §9 forbids polling on
/// the idle path. Both real routes are genuinely event-driven — the adapter's `stream` command
/// blocks until MediaRemote says something changed, and the scripting fallback rides distributed
/// notifications the players post themselves — so no conformance has to poll at all.
///
/// `@MainActor` to match `ActivitySource`, which is where these hand their work over. A conformer
/// does its real work (spawning a helper, parsing a pipe) off the main actor and hops once to
/// publish; the hop is cheap because it happens on track changes, not on frames.
@MainActor
public protocol NowPlayingProvider: AnyObject {

    /// Shown in diagnostics and in the settings row that explains which route is live. Users who
    /// report "it doesn't show my music" need to be able to say *which* of the three was running.
    static var providerName: String { get }

    /// Read on demand, never cached: the user can grant or revoke in System Settings while Isleta
    /// runs, and a value captured at launch would still say "denied" an hour after they allowed it.
    var authorization: SourceAuthorization { get }

    /// Called on the main actor whenever the answer changes. Set before `start()`.
    var onUpdate: ((NowPlayingUpdate) -> Void)? { get set }

    /// Idempotent, per `ActivitySource.start()`. Starting twice must not spawn two helpers.
    func start()

    /// Must leave no child process, no pipe reader, and no observer behind. §9's idle budget is
    /// measured with sources running, and a leaked `readabilityHandler` at EOF is not a slow leak —
    /// it is a spin.
    func stop()

    /// `stop()`, but not permitted to finish the job after returning. For the quit path.
    ///
    /// The distinction exists because `applicationWillTerminate` returns into `exit()`: anything a
    /// route defers to a queue, a timer or a completion handler simply never happens, and a route
    /// that tears down asynchronously strands whatever it spawned. Defaulted to `stop()`, which is
    /// correct for every route that has nothing to wait for — only the adapter overrides it.
    func stopAndWait()
}

public extension NowPlayingProvider {
    var providerName: String { Self.providerName }

    /// Routes with no child process inherit this: there is nothing to outlive the app.
    func stopAndWait() { stop() }
}

/// The route that does nothing, on purpose.
///
/// Not a test double and not a placeholder — this is what ships when the adapter is not vendored and
/// the user has said no to automating their player, and §10 requires the app to be *fully*
/// functional in exactly that state. "Fully functional" here has a precise meaning that is easy to
/// get wrong: it is not that the island shows an empty Now Playing card, it is that Now Playing is
/// simply not among the activities on the stack, and every other activity — HUDs, notifications, the
/// shelf — behaves as though this milestone had never shipped. The island is not a music widget with
/// the music missing.
///
/// So `start()` is empty rather than publishing a "nothing playing" placeholder. Publishing one
/// would put an ambient activity on the stack forever, and because ambient is the level everything
/// else outranks, the stack would never be empty and the island would never be at rest. An island
/// that cannot reach `.rest` is an island that is always visible, which is the opposite of the
/// design.
///
/// The explanation string is the other half of §10. It says what the user gains, not what we failed
/// at: "no adapter found" is a developer's sentence and means nothing to the person reading it.
@MainActor
public final class NullNowPlayingProvider: NowPlayingProvider {

    public static let providerName = "None"

    /// Deliberately `.denied` rather than `.notRequired`. There *is* something the user could do —
    /// allow Isleta to read the player, or install a build with the adapter vendored — and
    /// `.notRequired` would hide that from the settings UI, which reads this value to decide whether
    /// there is anything to offer. `.undetermined` would be wrong for the opposite reason: it invites
    /// a prompt, and there is no prompt that fixes a missing helper.
    public let authorization: SourceAuthorization

    public var onUpdate: ((NowPlayingUpdate) -> Void)?

    /// The sentence a build with no route shows. A stored constant rather than the default argument
    /// itself, because a default argument on a `public` initializer may not call an internal
    /// function and `sourceText` is one.
    public static let defaultExplanation = sourceText("nowPlaying.unavailable.null", """
        Isleta can show what you’re listening to in the island. Allow it to read your music player \
        in System Settings › Privacy & Security › Automation.
        """)

    public init(
        explanation: String = NullNowPlayingProvider.defaultExplanation
    ) {
        self.authorization = .denied(explanation: explanation)
    }

    /// Nothing to start. Notably it does not call `onUpdate` — not even with `.cleared`, which would
    /// be a lie: `.cleared` means "playback stopped", and this provider has never known whether
    /// anything was playing. A source that has no opinion must not push one.
    public func start() {}

    public func stop() {}
}
