import IslandKit
import Foundation
import IslandActivities

/// The Now Playing source (§2.4): owns whichever `NowPlayingProvider` this machine can support and
/// republishes it as a `BuiltInActivity.nowPlaying`.
///
/// Thin on purpose. Everything that can go wrong with reading a player is in the providers, and
/// everything that can go wrong with *presenting* one is here: the activity's identity, when it
/// arrives, and when it goes away. Keeping the second set free of process handling is what lets it
/// be tested exhaustively against a fake provider, in a suite that runs with no music playing.
@MainActor
public final class NowPlayingSource: ActivitySource {

    public static let sourceName = "Now Playing"

    /// The one id every Now Playing activity carries. See `ActivityID`: a track change is an update
    /// of one logical activity, not a new one.
    public static let activityID: ActivityID =
        ActivityKind.nowPlaying.singletonID ?? ActivityID("builtin.nowPlaying")

    public let provider: any NowPlayingProvider

    /// Sending commands *to* the player. Separate from the provider because reading and controlling
    /// are separate capabilities on the same machine — see `NowPlayingTransport`.
    public let transport: any NowPlayingTransport

    /// Cover art for whatever is playing, or `nil` on a build with no adapter to ask.
    ///
    /// Owned here rather than by the provider because it is not part of reading the player's state:
    /// it is a second, much more expensive question asked at a completely different cadence — once
    /// per track, against the provider's once per pause, seek and rate change — and putting it
    /// behind `NowPlayingProvider` would oblige the scripting and null routes to answer it.
    public let artwork: NowPlayingArtworkLoader?

    public var onActivity: ((any IslandActivity) -> Void)?
    public var onDismiss: ((ActivityID) -> Void)?

    /// The raw snapshot behind the activity, for the app shell.
    ///
    /// Everything the island *draws* travels as `ActivityContent`, which is where it belongs. This
    /// carries the two things that are not drawn but decide what is: `canSkip`, which grays the Next
    /// button honestly rather than guessing, and `isPlaying`, which chooses the play/pause glyph.
    /// Routing them through `ActivityContent` would mean inventing vocabulary for "a control's
    /// enabled state", which is a view concern that the one package with no views in it must not
    /// learn (see IslandActivities' README).
    ///
    /// `nil` means playback stopped, arriving in step with `onDismiss`.
    public var onSnapshot: ((NowPlayingSnapshot?) -> Void)?

    /// The playback queue window, when it changes — the list the open island can scroll.
    ///
    /// A third channel beside `onActivity` and `onSnapshot`, and it earns one. It is not content
    /// (`ActivityContent` has no vocabulary for a list, and inventing one would give every other
    /// activity a field it has no use for) and it is not snapshot state (`NowPlayingSnapshot` is
    /// `Equatable` and compared on every pause and scrub, so forty rows in it is forty comparisons
    /// per seek). It also arrives on its own cadence: the queue line lands a beat either side of
    /// the state line it belongs to.
    ///
    /// Empty is a real answer and means "there is nothing queued" — a radio station, a live stream,
    /// the last track of a playlist, and every route that is not the adapter.
    public var onQueue: (([NowPlayingQueueItem]) -> Void)? {
        didSet { adapterProvider?.onQueue = onQueue }
    }

    /// Whether this build can read a queue at all. False draws no Up Next surface — not an empty
    /// one, for the reason `NowPlayingUnavailableTransport` draws no transport row.
    public var canReadQueue: Bool { adapterProvider != nil }

    /// The adapter route, when that is the one that is running.
    ///
    /// A cast rather than a protocol requirement, matching `(transport as? NowPlayingAdapterTransport)`
    /// in `tearDown`: the queue is one route's capability, and a requirement on `NowPlayingProvider`
    /// would oblige the scripting and null routes to answer for something neither can do.
    private var adapterProvider: NowPlayingAdapterProvider? {
        provider as? NowPlayingAdapterProvider
    }

    /// Asks for a wider window of the queue as the reader scrolls.
    ///
    /// Folded into the streaming helper that is already alive, never a one-shot: `perl … queue`
    /// costs 60-360 ms of process spawn to cover a 15-30 ms read, so a spawn per scroll would be a
    /// process per flick of a trackpad. See `NowPlayingQueuePaging` for what to ask for, and
    /// `NowPlayingAdapterReader.requestQueueWindow(length:)` for how it gets there.
    public func requestQueueWindow(length: Int, isOpen: Bool) {
        adapterProvider?.requestQueueWindow(length: length, isOpen: isOpen)
    }

    private var isRunning = false

    /// Whether an activity is currently on the island because of us.
    ///
    /// Tracked rather than inferred so `stop()` knows whether it owes a dismissal. Without it,
    /// turning Now Playing off in IslandSettings would tear the provider down and leave the track
    /// sitting on the stack with nothing alive to remove it — an ambient activity that outlives its
    /// source is one the island can never get back to `.rest` from.
    private var hasPresented = false

    public init(
        provider: any NowPlayingProvider,
        transport: any NowPlayingTransport = NowPlayingUnavailableTransport(),
        artwork: NowPlayingArtworkLoader? = nil
    ) {
        self.provider = provider
        self.transport = transport
        self.artwork = artwork
    }

    /// Picks the best route this build and machine can manage.
    ///
    /// Order is adapter, then scripting, and never a fallback *chain* at runtime. Running both at
    /// once looks like belt and braces and is a bug: the two routes report the same track through
    /// different mechanisms with different timing, so every play would publish twice and every
    /// disagreement between them — the adapter sees a browser, scripting does not — would show as
    /// the island flipping between two answers.
    ///
    /// `NullNowPlayingProvider` is not in this chain. It is what the caller substitutes when the
    /// user has switched Now Playing off, which is a decision, not a fallback.
    public convenience init(bundle: Bundle = .main) {
        let adapter = NowPlayingAdapterProvider(bundle: bundle)
        if adapter.authorization.isUsable {
            IslandLog.nowPlaying.info("route: mediaremote-adapter (transport and artwork live)")
            // The transport and the artwork loader are resolved from the same bundle and are live
            // only on this branch, which is the honest arrangement: the scripting route cannot seek
            // and cannot produce cover art, so giving it a transport that silently swallowed
            // commands would draw three buttons that do nothing.
            self.init(
                provider: adapter,
                transport: NowPlayingAdapterTransport(bundle: bundle),
                artwork: NowPlayingArtworkLoader(bundle: bundle)
            )
        } else {
            IslandLog.nowPlaying.info("route: AppleScript push fallback — adapter unavailable (\(adapter.authorization))")
            self.init(provider: NowPlayingScriptProvider())
        }
    }

    /// The provider's own answer, unmodified.
    ///
    /// Not aggregated or softened here. `SourceAuthorization` is what IslandSettings renders, and a
    /// source that rewrites its provider's verdict into something more comfortable is a source whose
    /// settings row cannot be trusted.
    public var authorization: SourceAuthorization { provider.authorization }

    public func start() {
        guard !isRunning else { return }
        isRunning = true

        provider.onUpdate = { [weak self] update in
            self?.handle(update)
        }
        // Set at `start()` as well as in the property's own `didSet`, because the shell may have
        // installed the callback before the route existed — and because `start()` is where a route
        // that has just been rebuilt gets its wiring back.
        adapterProvider?.onQueue = onQueue
        provider.start()
    }

    public func stop() {
        tearDown(waitingForChildren: false)
    }

    /// The quit path. Identical but for the one call that has to finish before we return — the
    /// adapter route's helper is a real child process, and `applicationWillTerminate` is followed by
    /// `exit()` rather than by another runloop pass.
    public func stopAndWait() {
        tearDown(waitingForChildren: true)
    }

    private func tearDown(waitingForChildren: Bool) {
        guard isRunning else { return }
        isRunning = false

        if waitingForChildren { provider.stopAndWait() } else { provider.stop() }
        // Cleared *after* `stop()`, so a provider that publishes something on its way down cannot
        // land in a callback that has already been detached — and cleared at all, because the
        // provider outlives this source and would otherwise hold a strong reference back to it.
        provider.onUpdate = nil

        // Both of these outlive the source's run, and both hold something worth releasing: the
        // transport can have children in flight, and the loader holds a quarter of a megabyte of
        // decoded album cover. Switching Now Playing off in Settings has to give that back.
        (transport as? NowPlayingAdapterTransport)?.stop()
        artwork?.reset()

        // The list goes with the route, whether or not anything was presented: a queue left in the
        // shell after the source stopped is rows the user can double-click, acting on a player
        // nothing is reading any more.
        onQueue?([])
        adapterProvider?.onQueue = nil

        if hasPresented {
            hasPresented = false
            onSnapshot?(nil)
            onDismiss?(Self.activityID)
        }
    }

    private func handle(_ update: NowPlayingUpdate) {
        switch update {
        case .snapshot(let snapshot):
            hasPresented = true
            // Before the activity, deliberately. The loader is idempotent per identity so this is a
            // no-op on all but the first update of a track, and going first means the app shell has
            // the fetch under way by the time it draws the new title — the artwork arrives a beat
            // later either way, but not a beat *plus* the render.
            artwork?.load(
                identity: snapshot.artworkIdentity,
                playerReported: snapshot.artworkIdentityIsFromPlayer
            )
            onSnapshot?(snapshot)
            onActivity?(snapshot.activity)

        case .cleared:
            // Only dismiss something that is actually there. A provider is free to report `.cleared`
            // for a player that was never presented — the scripting route does it whenever a
            // non-owning player stops — and forwarding that would call `onDismiss` for an id the
            // coordinator has never seen. Harmless today; the sort of harmless that becomes a
            // mystery once the coordinator grows logging.
            guard hasPresented else { return }
            hasPresented = false
            artwork?.load(identity: nil)
            onSnapshot?(nil)
            onDismiss?(Self.activityID)
        }
    }
}
