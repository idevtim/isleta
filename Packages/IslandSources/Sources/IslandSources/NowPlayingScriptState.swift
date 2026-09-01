import Foundation

/// Decides which of several talking players the island is currently about.
///
/// Pulled out of `NowPlayingScriptProvider` as a value type with no dependencies because every rule
/// in it is a judgement call that will be argued with later, and arguing with it should mean editing
/// a test rather than reproducing a two-player race by hand. It also happens to be where the three
/// bugs of this route live: the same event arriving twice, a second player clearing the first
/// player's island, and a player quitting without saying goodbye.
public struct NowPlayingScriptState: Equatable, Sendable {

    /// Whose activity is on the island. `nil` means the island is not showing Now Playing.
    public private(set) var owner: String?

    /// The last snapshot actually handed on, for de-duplication.
    public private(set) var published: NowPlayingSnapshot?

    public init() {}

    /// Folds one update in and returns what — if anything — should be published.
    ///
    /// `nil` means "nothing changed", which is a different answer from every other one here and the
    /// reason this returns an optional rather than a `NowPlayingUpdate`. Publishing an unchanged
    /// value is not harmless: `ActivityCoordinator` treats a re-presented id as a content update, so
    /// a duplicate runs §6.2's `contentSwap` crossfade on content that is identical, and the user
    /// sees the island flicker for no reason they caused.
    public mutating func ingest(
        _ update: NowPlayingUpdate,
        from bundleIdentifier: String
    ) -> NowPlayingUpdate? {
        switch update {
        case .snapshot(let snapshot):
            // A player that is actually playing always takes the stage. A player that is merely
            // paused takes it only if nobody is playing — otherwise pausing Spotify would replace a
            // playing Music track with a paused Spotify one, which is the exact opposite of what the
            // user just did. "Last event wins" is the naive rule and this is the case that breaks it.
            let incumbentIsPlaying = published?.isPlaying == true
            let isForeign = owner != nil && owner != bundleIdentifier
            guard snapshot.isPlaying || !isForeign || !incumbentIsPlaying else { return nil }

            // The de-duplication that pays for Music posting every event under two names. Compares
            // the whole snapshot rather than the title, so a pause of the same track still gets
            // through — the glyph changes even when the words do not.
            guard published != snapshot else { return nil }

            owner = bundleIdentifier
            published = snapshot
            return .snapshot(snapshot)

        case .cleared:
            // Only the player holding the stage may take it away. Spotify being stopped in the
            // background is not news about the album Music is playing, and treating it as news is
            // how the island blanks itself at the moment an unrelated app is quit.
            guard owner == bundleIdentifier else { return nil }
            owner = nil
            published = nil
            return .cleared
        }
    }

    /// A player disappeared without reporting a stop.
    ///
    /// It always does. Quitting a player posts no final `playerInfo` — the process is gone before it
    /// would have — so `NSWorkspace.didTerminateApplicationNotification` is the only thing that ever
    /// tells us, and without it a track stays pinned to the island until something else happens to
    /// arrive. That is the "player quits mid-track" case, and it is indistinguishable from a working
    /// island right up until the user notices they are being shown a song from an app they closed.
    public mutating func playerDidQuit(_ bundleIdentifier: String) -> NowPlayingUpdate? {
        ingest(.cleared, from: bundleIdentifier)
    }

    /// Forgets everything, without publishing. Used by `stop()`, where the source is going away and
    /// there is nobody left to publish to.
    public mutating func reset() {
        owner = nil
        published = nil
    }
}
