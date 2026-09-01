import Foundation
import IslandActivities

/// One player Isleta knows how to ask directly, and how to ask it.
///
/// A closed table rather than discovery, because there is nothing to discover: a player is usable by
/// this route only if it both posts a distributed notification on state change *and* exposes
/// `player state` / `current track` in its scripting dictionary, and no API reports either. Every
/// entry here is a pair of facts that had to be verified by hand against a running copy.
///
/// This is the fallback's real cost, and it should be stated plainly rather than discovered later:
/// the adapter route sees whatever is playing, and this route sees the apps on this list. A user
/// playing audio in Safari or VLC gets nothing from it. That is the trade for a route that needs no
/// vendored helper.
public struct NowPlayingPlayer: Equatable, Sendable, Identifiable {

    public var id: String { bundleIdentifier }

    public let bundleIdentifier: String

    /// The name `tell application "…"` addresses. Not derived from the bundle identifier: Music's
    /// identifier is `com.apple.Music` and its scripting name is "Music", but Spotify's are
    /// `com.spotify.client` and "Spotify", and guessing gets one of the two wrong.
    public let scriptingName: String

    /// Distributed notification names to observe.
    ///
    /// Plural, and Music is why. Verified on macOS 27.0: Music posts **both**
    /// `com.apple.Music.playerInfo` and `com.apple.iTunes.playerInfo` for the same event, with
    /// byte-identical `userInfo`, presumably so clients written against iTunes keep working. An
    /// observer of both — which is what you want, because a user on an older system may only get the
    /// iTunes one — therefore sees every track change twice. The de-duplication in
    /// `NowPlayingScriptState` is not defensive tidiness; without it every track change publishes
    /// two identical activities and §6.2's `contentSwap` runs twice on the same content.
    public let notificationNames: [String]

    public init(bundleIdentifier: String, scriptingName: String, notificationNames: [String]) {
        self.bundleIdentifier = bundleIdentifier
        self.scriptingName = scriptingName
        self.notificationNames = notificationNames
    }

    public static let music = NowPlayingPlayer(
        bundleIdentifier: "com.apple.Music",
        scriptingName: "Music",
        notificationNames: ["com.apple.Music.playerInfo", "com.apple.iTunes.playerInfo"]
    )

    public static let spotify = NowPlayingPlayer(
        bundleIdentifier: "com.spotify.client",
        scriptingName: "Spotify",
        notificationNames: ["com.spotify.client.PlayerStateChanged"]
    )

    /// Music first, because it is the one that is always installed and the one whose behavior was
    /// verified end to end. Order matters only for the initial read at `start()`, where the first
    /// running player with something to say wins.
    public static let all: [NowPlayingPlayer] = [.music, .spotify]

    // MARK: - The notification payload

    /// Keys in the posted `userInfo`. Both players use the same spelling, which is not a coincidence
    /// — Spotify's dictionary was written to match iTunes'.
    private enum Key {
        static let playerState = "Player State"
        static let name = "Name"
        static let artist = "Artist"
        static let album = "Album"
    }

    /// Values of `Player State`.
    private enum State {
        static let playing = "Playing"
        static let stopped = "Stopped"
    }

    /// Reads one posted `playerInfo` notification.
    ///
    /// The dictionary is `[AnyHashable: Any]` from another process's `userInfo`, so every read is a
    /// conditional cast and a wrong type is a missing field rather than a crash. Isleta does not get
    /// to assume a third-party app posts what it posted last release.
    ///
    /// "Stopped" is the only state that clears. "Paused" deliberately keeps the activity — see
    /// `NowPlayingSnapshot.isPlaying`.
    public func update(fromPlayerInfo userInfo: [AnyHashable: Any]) -> NowPlayingUpdate {
        let state = userInfo[Key.playerState] as? String
        guard state != State.stopped else { return .cleared }

        return NowPlayingSnapshot.update(
            title: userInfo[Key.name] as? String,
            artist: userInfo[Key.artist] as? String,
            album: userInfo[Key.album] as? String,
            isPlaying: state == State.playing,
            bundleIdentifier: bundleIdentifier
        )
    }

    // MARK: - The one-shot read

    /// AppleScript that reports the current track, or `stopped`.
    ///
    /// Needed because the notification only fires on *change*: a user who has been listening for ten
    /// minutes before Isleta launches has generated no event, and without this the island would stay
    /// empty until they next touched the transport. This is the only part of the route that needs
    /// the Automation permission, and it is the only part that degrades when the permission is
    /// refused — the live updates keep working, which is why refusal is not fatal here.
    ///
    /// Fields are joined with U+001F (unit separator) rather than newlines. A track called
    /// "Untitled\n2" is unlikely but not impossible, and the failure mode of newline-joining is not
    /// a garbled title — it is a field count that shifts, so the album is read as the artist and the
    /// island confidently displays wrong information. U+001F cannot appear in a tag written by any
    /// tagging tool.
    ///
    /// The guard on `player state is stopped` is not an optimisation either: `current track` raises
    /// an AppleScript error when nothing is loaded, and an error here is indistinguishable at the
    /// exit code from the permission being denied.
    public var currentTrackScript: String {
        """
        set sep to (character id 31)
        tell application "\(scriptingName)"
            if player state is stopped then return "stopped"
            set t to current track
            return (player state as text) & sep & (name of t) & sep & (artist of t) & sep & (album of t)
        end tell
        """
    }

    // MARK: - Favorite, and revealing the track

    /// Whether this player has a Favorite of its own, and a way to be shown the playing track.
    ///
    /// **Music alone**, and that is measured rather than assumed: `sdef /System/Applications/Music.app`
    /// carries `favorited` (code `pLov`, "is this track favorited?") on `track` and a `reveal`
    /// command ("reveal and select a track or playlist"); `sdef /Applications/Spotify.app` carries
    /// neither, nor any of `loved`, `starred` or `saved`. A player with no favorite of its own gets
    /// no star — see `NowPlayingSnapshot.canFavorite`, which is what §10's "no control that does
    /// nothing" means here.
    ///
    /// Left as a property on the player rather than a `== .music` test at each call site, so adding
    /// a third player is one entry rather than three comparisons that agree until somebody adds a
    /// fourth.
    public var supportsFavorite: Bool { bundleIdentifier == Self.music.bundleIdentifier }

    /// Reads the playing track's Favorite state. Prints `true`, `false`, or `unknown`.
    ///
    /// `unknown` rather than an error for "nothing is playing", because a stopped player and a
    /// failed script are different to the caller and only the second is worth a log line.
    ///
    /// **There is no track class this does not work for**, and an earlier version of this file
    /// claimed there was. A write to a `URL track` — what Apple Music reports for anything streamed
    /// rather than held in the library — appeared to be silently ignored, and the gate built on that
    /// kept the star dimmed for every track the owner actually plays. The write is **asynchronous**:
    /// re-read after 0.4s it reports the old value, and after 2s it reports the new one. The first
    /// measurement was a race with itself, not a capability. Measured against Music 1.5.4 on macOS
    /// 27.0, both directions, on a `URL track`.
    public var favoriteReadScript: String? {
        guard supportsFavorite else { return nil }
        return """
        tell application "\(scriptingName)"
            if player state is stopped then return "unknown"
            return (favorited of current track) as text
        end tell
        """
    }

    /// What `favoriteReadScript` said, or nil where it said nothing usable.
    public func favorite(fromScriptOutput output: String) -> Bool? {
        switch output.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    /// Sets it, waits for Music to agree, and reports what it settled on.
    ///
    /// **Polled rather than delayed, and that is a correction.** `set favorited` returns before the
    /// property agrees, so the read-back has to outlast the lag — but the lag is not a constant. A
    /// fixed `delay 2` was measured as enough and then observed failing on a first click: the write
    /// landed, the read at two seconds still said `false`, and the island dutifully put the star
    /// back out over a track Music had in fact favorited. The second click "worked", which is what a
    /// timing bug looks like from the outside.
    ///
    /// So it asks up to ten times at 300ms and stops the moment Music agrees — typically one or two
    /// turns, and it gives up at three seconds rather than hanging a child process on a player that
    /// is never going to answer. Returning the *last* read either way keeps the rule that the island
    /// shows what the player says rather than what it was asked for.
    public func favoriteWriteScript(_ favorite: Bool) -> String? {
        guard supportsFavorite else { return nil }
        return """
        tell application "\(scriptingName)"
            if player state is stopped then return "unknown"
            set favorited of current track to \(favorite)
            set answer to (favorited of current track)
            repeat 10 times
                if answer is \(favorite) then exit repeat
                delay 0.3
                set answer to (favorited of current track)
            end repeat
            return answer as text
        end tell
        """
    }

    /// Brings the player forward **at the playing track**, rather than merely to the front.
    ///
    /// `reveal` selects the track in the library; `activate` is what puts the window in front, and
    /// the order matters — revealing first means the window that comes forward is already showing
    /// the track rather than scrolling to it after the user is looking at it.
    public var revealCurrentTrackScript: String? {
        guard supportsFavorite else { return nil }
        return """
        tell application "\(scriptingName)"
            if player state is stopped then return
            reveal current track
            activate
        end tell
        """
    }

    /// Parses `currentTrackScript`'s stdout.
    public func update(fromScriptOutput output: String) -> NowPlayingUpdate {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != "stopped" else { return .cleared }

        let fields = trimmed.components(separatedBy: "\u{1F}")
        guard fields.count == 4 else { return .cleared }

        return NowPlayingSnapshot.update(
            title: fields[1],
            artist: fields[2],
            album: fields[3],
            isPlaying: fields[0] == "playing",
            bundleIdentifier: bundleIdentifier
        )
    }
}
