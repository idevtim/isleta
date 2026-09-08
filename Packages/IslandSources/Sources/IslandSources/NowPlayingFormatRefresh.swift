import Foundation

/// Decides when to ask the helper to re-send the queue because the playing track has no format.
///
/// ## Why an ask is needed at all
///
/// The audio format — "Lossless", "Dolby Atmos" — arrives on exactly one line of the adapter's
/// stream: `{"type":"queue"}`, on the entry at index 0. Nothing else carries it, and the helper
/// emits that line **only when the player says the queue changed**. So there is a gap that no
/// amount of care on the receiving side closes: a player that quits and comes back playing the same
/// track publishes a track but not a queue, and the badge that was cleared when it went away never
/// returns. Reported 2026-09-08: *"quit the music app, open it back then hit play, not there until
/// I hit next and then previous"* — next and previous being the two events that do change a queue.
///
/// **The helper answers a control line by re-emitting the queue, even for a window it is already
/// on** — measured 2026-09-08 by writing `length 5` to a stream opened at `--length=5` and getting
/// a fresh queue line back within a second, then `length 6` and getting six entries. So the fix is
/// to ask, and this type is the rule for when.
///
/// ## Why it is a type rather than two lines in the bridge
///
/// Everything that can go wrong here is a question about *when* to ask, and none of it needs a
/// process: ask too eagerly and a track that genuinely has no format — a Spotify stream, a podcast
/// — draws one control line per snapshot, which is several a second down a pipe into the helper
/// that is also delivering track changes. Ask too shyly and the badge stays missing, which is the
/// bug. Both are decided here, against a track identity, and tested without an adapter.
public struct NowPlayingFormatRefresh: Equatable, Sendable {

    /// The track the asks are being made for, so a new one starts with a fresh allowance.
    ///
    /// `NowPlayingSnapshot.artworkIdentity` is what this holds: the player's own
    /// `contentItemIdentifier` where it gives one, and a hash of title/artist/album where it does
    /// not. It changes exactly when the track does, which is exactly the granularity an ask needs.
    private var track: String?

    /// How many asks this track has had. **The first version allowed one, and one was wrong** —
    /// measured 2026-09-08: a player that has just been reopened publishes its track before it can
    /// answer a queue read, so the single ask came back empty 29 ms later and nothing ever asked
    /// again. An ask that finds nothing must not burn the track's only chance.
    private var attempts = 0
    private var lastAskedAt: Date?

    /// Three, spread by `minimumInterval`, is enough for a player still coming up and few enough
    /// that a library where nothing reports a format costs three spawns per track rather than one
    /// per snapshot — snapshots arrive several times a second, which is what the spacing is for.
    static let maximumAttempts = 3

    /// Long enough that a player mid-launch has moved on between asks, short enough that the badge
    /// arrives while the user is still looking at the track that earned it.
    static let minimumInterval: TimeInterval = 1

    public init() {}

    /// Whether to ask now, given what is playing, whether a format is already in hand, and when the
    /// last ask went out.
    ///
    /// - Parameters:
    ///   - identity: the playing track's identity, or nil when nothing is playing.
    ///   - hasFormat: whether the controller already holds a format for it.
    ///   - now: injected rather than read, so the spacing is testable without waiting for it.
    public mutating func shouldAsk(forTrack identity: String?, hasFormat: Bool, now: Date) -> Bool {
        guard let identity, !hasFormat else { return false }
        if identity != track {
            track = identity
            attempts = 0
            lastAskedAt = nil
        }
        guard attempts < Self.maximumAttempts else { return false }
        if let lastAskedAt, now.timeIntervalSince(lastAskedAt) < Self.minimumInterval { return false }
        attempts += 1
        lastAskedAt = now
        return true
    }

    /// The player went away — forget everything, so the same track earns a fresh allowance when it
    /// comes back. This is the reported bug's own path.
    public mutating func playerWentAway() {
        track = nil
        attempts = 0
        lastAskedAt = nil
    }

    /// A queue push took the format away from a track that had one, which is circumstances changing
    /// rather than an answer: the allowance starts again.
    public mutating func formatWasTakenAway() {
        attempts = 0
        lastAskedAt = nil
    }
}
