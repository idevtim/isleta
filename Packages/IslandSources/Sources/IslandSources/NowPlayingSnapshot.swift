import Foundation
import IslandActivities

/// What is playing, reduced to the four things the island can actually say.
///
/// Deliberately much smaller than what either route can produce. The `mediaremote-adapter` payload
/// carries about forty keys — artwork, queue indices, shuffle and repeat modes, chapter counts — and
/// every one of them we keep is a field that has to be diffed, republished and re-rendered on every
/// scrub. The island's Now Playing presentation is a glyph, a title and a subtitle
/// (`BuiltInActivity.nowPlaying`), so this carries exactly that plus the identity of the app it came
/// from, and drops the rest at the parse boundary rather than at the render boundary. Anything the
/// UI later grows an appetite for is one field added here; anything carried "just in case" is a
/// republish nobody asked for.
///
/// There is no `elapsedTime` field here, and that absence is §9. A progress readout baked into a
/// snapshot is only true for the instant it was sampled, so keeping one current means re-asking on a
/// timer — polling, on the idle path, forever. What the island grew instead is `timeline`: an
/// `ActivityTimeline` carrying the position *and the instant it was true* plus the rate, which
/// IslandUI evaluates against the display link it is already running. A track playing for an hour
/// publishes one snapshot, not 3,600. When adding a field here, that is the test to apply: is it
/// true until something changes, or only true when it was read?
public struct NowPlayingSnapshot: Equatable, Sendable {

    /// Never empty. A player that reports a track with no title is reporting nothing a user could
    /// read, so it is modelled as `NowPlayingUpdate.cleared` rather than as a snapshot with a blank
    /// line in it — see `NowPlayingUpdate`.
    public let title: String

    /// `nil` rather than `""` when unknown. `BuiltInActivity` joins the non-nil parts and leaves the
    /// subtitle off entirely when there are none, so an empty string here would reserve a line of
    /// height for an unnamed artist and sit the island a few points taller than it should.
    public let artist: String?

    public let album: String?

    /// Paused is still a snapshot, not an absence. A paused track keeps the island's Now Playing
    /// activity on the stack with a `pause.fill` glyph; only stopping or quitting clears it. Losing
    /// the island every time the user pauses and regaining it when they resume would make the
    /// ambient activity flicker in and out of a stack it is supposed to sit quietly at the bottom of.
    public let isPlaying: Bool

    /// Which app this came from, when the route knows. Used to decide whose "stopped" counts: a
    /// second player stopping must not clear the island for the one actually playing.
    public let bundleIdentifier: String?

    /// Where the playhead is, as an anchor. `nil` for a route that cannot report position.
    public let timeline: ActivityTimeline?

    /// Whether the player says skipping forward is forbidden — a radio station, an advert.
    ///
    /// Carried rather than assumed, because the alternative is guessing, and a Next button that is
    /// drawn enabled and does nothing is worse than one drawn disabled. It comes straight from the
    /// payload's `prohibitsSkip`, inverted here so the field reads as a capability rather than as a
    /// prohibition — every consumer is asking "may I offer this", and a double negative at each call
    /// site is one `!` away from an advert the user can skip past on a stream that forbids it.
    public let canSkip: Bool

    /// Changes exactly when the artwork changes, and at no other time.
    ///
    /// The cache key, and the reason artwork is not fetched on every update. `stream` re-emits the
    /// **entire** base64 payload on every change it reports — 211,300 characters measured for one
    /// track — so artwork is streamed with `--no-artwork` and fetched by a separate `get` only when
    /// this token moves. Derived from the player's own `contentItemIdentifier` where it supplies
    /// one, and from title/artist/album where it does not: a hash of the strings the user can see is
    /// wrong only when two tracks agree on all three, which is a re-fetch avoided rather than a
    /// wrong image shown.
    public let artworkIdentity: String?

    /// Whether `artworkIdentity` is the **player's** own `contentItemIdentifier` or a hash we made
    /// up from the title, artist and album.
    ///
    /// It decides whether the artwork loader may check that a fetched cover describes the track it
    /// asked about. Against a player-reported id that check is exact; against our hash it can never
    /// match, and comparing anyway rejected every cover forever — the island kept showing the
    /// previous track's art indefinitely.
    public let artworkIdentityIsFromPlayer: Bool

    /// Whether what is playing is a radio station rather than a queue.
    ///
    /// From the payload's `radioStationHash` (or `radioStationIdentifier`), and it is a *capability*
    /// fact in the same family as `canSkip`: there is no queue, so there is nothing to shuffle and
    /// nothing to repeat, and the player accepts neither command. Measured on Apple Music radio —
    /// the MRCommand toggles, the adapter's explicit mode calls and AppleScript's own setters all
    /// return successfully and change nothing. Without this the island draws two controls that look
    /// live, lights them when pressed, and asserts a state the player never entered.
    public let isRadioStation: Bool

    /// What plays after this, when the route can see a queue. Nil for a radio station, a live
    /// stream, the last track of a playlist, and every route that is not the adapter.
    ///
    /// **Declared last on purpose.** CLAUDE.md records what inserting a stored property into a
    /// shared struct costs — dependent packages keep the old layout and read every field at the
    /// wrong offset, with no compile error and a segfault three packages away. Appending cannot
    /// prevent that for anything reading *this* field, but it leaves the offsets of the ten fields
    /// above unmoved, which is the difference between one stale module misreading one new value and
    /// misreading all eleven. It is still a clean rebuild; it is just a cheaper one to get wrong.
    public let upNext: NowPlayingUpNext?

    /// Whether the player offers a like at all, from the payload's `supportsIsLiked`.
    ///
    /// **This is what the control is drawn from, and `isFavorite` is not.** The two are unrelated
    /// questions and answering both with one field grays the wrong thing in each direction: a track
    /// nobody has favorite yet reports `isFavorite = 0` and is perfectly likeable, and a track on a
    /// service with no such concept reports neither. Measured on macOS 27.0 against a local Music
    /// library track: **neither key is in the payload at all**, so the honest drawing there is a
    /// heart that is dimmed and inert — the same discipline `canSkip` uses for `prohibitsSkip` and
    /// `isRadioStation` uses for shuffle and repeat, and note those two are unrelated to each other
    /// as well.
    ///
    /// Defaults to **false**, unlike `canSkip`, and the asymmetry is deliberate. A player that says
    /// nothing about skipping is not forbidding it; a player that says nothing about liking has no
    /// like to offer, and drawing a live heart on it would be a control that does nothing when
    /// pressed.
    public let canFavorite: Bool

    /// Whether the player says this track is favorite, from `isFavorite`. Meaningless unless `canFavorite`.
    public let isFavorite: Bool

    /// Whether the player offers the two fifteen-second jumps, from `supportsRewind15Seconds` and
    /// `supportsFastForward15Seconds`.
    ///
    /// Spoken-word players set these and music players do not, so they are also the closest thing
    /// the payload has to "this is a podcast". They are carried as two fields rather than one
    /// because the player reports two and there is no reason to assume a player that offers one
    /// offers the other — the same mistake as answering `prohibitsSkip` and `radioStationHash` with
    /// a single flag.
    public let canSkipBackFifteen: Bool

    public let canSkipForwardFifteen: Bool

    public init(
        title: String,
        artist: String? = nil,
        album: String? = nil,
        isPlaying: Bool,
        bundleIdentifier: String? = nil,
        timeline: ActivityTimeline? = nil,
        canSkip: Bool = true,
        artworkIdentity: String? = nil,
        artworkIdentityIsFromPlayer: Bool = false,
        isRadioStation: Bool = false,
        upNext: NowPlayingUpNext? = nil,
        canFavorite: Bool = false,
        isFavorite: Bool = false,
        canSkipBackFifteen: Bool = false,
        canSkipForwardFifteen: Bool = false
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.isPlaying = isPlaying
        self.bundleIdentifier = bundleIdentifier
        self.timeline = timeline
        self.canSkip = canSkip
        self.artworkIdentity = artworkIdentity
        self.artworkIdentityIsFromPlayer = artworkIdentityIsFromPlayer
        self.isRadioStation = isRadioStation
        self.upNext = upNext
        self.canFavorite = canFavorite
        self.isFavorite = isFavorite
        self.canSkipBackFifteen = canSkipBackFifteen
        self.canSkipForwardFifteen = canSkipForwardFifteen
    }

    /// The activity handed to the coordinator.
    ///
    /// Always the same `ActivityID` — `ActivityKind.nowPlaying.singletonID` — because a track change
    /// is an *update of one logical activity*, not a new one. Under a fresh id per track the
    /// coordinator would see unrelated activities arriving and the island would re-enter from
    /// nothing on every skip, running §6.2's `expand` spring where it wants `contentSwap`.
    public var activity: BuiltInActivity {
        BuiltInActivity.nowPlaying(
            title: title,
            artist: artist,
            album: album,
            isPlaying: isPlaying,
            timeline: timeline
        )
    }
}

/// One verdict from a route: either this is playing, or nothing is.
///
/// Two cases rather than `NowPlayingSnapshot?`, because the optional reads as "no answer yet" at
/// every call site and this type has to distinguish that from "the answer is nothing". A route that
/// has not yet heard from a player returns `nil` *from the parse*; a route that has heard "stopped"
/// returns `.cleared`, and only the second one may take the island away from the user.
public enum NowPlayingUpdate: Equatable, Sendable {

    case snapshot(NowPlayingSnapshot)

    /// Playback stopped, or the player quit. Distinct from expiry — this is the source knowing
    /// rather than the clock assuming, which is exactly the split `ActivitySource.onDismiss`
    /// documents.
    case cleared
}

extension NowPlayingSnapshot {

    /// Builds a snapshot from fields of unknown cleanliness, or `.cleared` if there is nothing to
    /// say.
    ///
    /// One place for the normalization both routes need, because they get their strings from
    /// different worlds and both worlds lie in the same two ways: a missing value arrives as an
    /// empty string rather than as an absence (AppleScript returns `""` for a track with no artist,
    /// and the adapter's JSON can carry `""` just as easily as `null`), and values arrive padded.
    /// Normalizing in each route separately is how you end up with the adapter suppressing an empty
    /// subtitle and the scripting fallback drawing a blank line under the title on the same track.
    static func update(
        title: String?,
        artist: String?,
        album: String?,
        isPlaying: Bool,
        bundleIdentifier: String?,
        timeline: ActivityTimeline? = nil,
        canSkip: Bool = true,
        artworkIdentity: String? = nil,
        isRadioStation: Bool = false,
        upNext: NowPlayingUpNext? = nil,
        canFavorite: Bool = false,
        isFavorite: Bool = false,
        canSkipBackFifteen: Bool = false,
        canSkipForwardFifteen: Bool = false
    ) -> NowPlayingUpdate {
        guard let title = Self.trimmedOrNil(title) else { return .cleared }
        return .snapshot(
            NowPlayingSnapshot(
                title: title,
                artist: Self.trimmedOrNil(artist),
                album: Self.trimmedOrNil(album),
                isPlaying: isPlaying,
                bundleIdentifier: Self.trimmedOrNil(bundleIdentifier),
                timeline: timeline,
                canSkip: canSkip,
                artworkIdentity: Self.trimmedOrNil(artworkIdentity)
                    ?? Self.artworkIdentity(title: title, artist: artist, album: album),
                artworkIdentityIsFromPlayer: Self.trimmedOrNil(artworkIdentity) != nil,
                isRadioStation: isRadioStation,
                upNext: upNext,
                canFavorite: canFavorite,
                isFavorite: isFavorite,
                canSkipBackFifteen: canSkipBackFifteen,
                canSkipForwardFifteen: canSkipForwardFifteen
            )
        )
    }

    /// The fallback artwork key, for a player that reports no `contentItemIdentifier`.
    ///
    /// Deliberately *not* including whether the track is playing or where the playhead is: those
    /// change constantly and the artwork does not, and a key that moves with them would re-fetch
    /// 155 KB of base64 on every pause. It is only the three strings that name the recording.
    static func artworkIdentity(title: String, artist: String?, album: String?) -> String {
        [title, artist ?? "", album ?? ""].joined(separator: "\u{1F}")
    }

    static func trimmedOrNil(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
