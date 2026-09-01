import Foundation
import IslandActivities

/// The track that comes after this one.
///
/// One item, not the queue. The full queue is a later milestone with a scrolling surface to put it
/// on; what ships now is the sneak peek, which needs exactly one row and pays for exactly one row.
/// Carrying the array here instead would be forty strings held for the length of a song so that one
/// of them could be drawn — and `NowPlayingSnapshot` is `Equatable`, so it would also mean comparing
/// forty strings on every pause, seek and rate change to decide whether the island changed.
///
/// It passes `NowPlayingSnapshot`'s own test for a field: **is it true until something changes, or
/// only true when it was read?** The next track is true for the length of the song, and the player
/// posts a notification when it stops being true. Nothing here has to be re-asked on a clock.
public struct NowPlayingUpNext: Equatable, Sendable {

    /// Never empty — an entry with no title is dropped in the adapter, where dropping it is safe.
    /// See `NowPlayingQueueWindow`: the discrimination is positional, so a placeholder that kept its
    /// slot would make the track after the next one read as the next one.
    public let title: String

    public let artist: String?

    public let album: String?

    /// The player's own id for the item, when it supplies one.
    ///
    /// Not used to *find* the next track — that is the index — but it is what a later milestone
    /// needs to play it: `PlayItemInPlaybackQueue` takes the offset **and** this, and the two
    /// commands that take only an offset return success and do nothing.
    public let contentItemIdentifier: String?

    public init(
        title: String,
        artist: String? = nil,
        album: String? = nil,
        contentItemIdentifier: String? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.contentItemIdentifier = contentItemIdentifier
    }
}

/// One entry of the queue window, for the list the open island can scroll.
///
/// Separate from `NowPlayingUpNext`, which is deliberately one row held on the snapshot for the
/// length of a song. This is the *list*, and it is carried on its own channel rather than on
/// `NowPlayingSnapshot` for exactly the reason that type's own documentation gives: the snapshot is
/// `Equatable` and is compared on every pause, seek and rate change, and putting forty of these in
/// it would mean comparing forty rows to decide whether the island changed.
///
/// `index` is its position in the window as the player vended it, and it is the field that does the
/// work. **Index 0 is the track that is playing** — played entries are dropped from the queue, and
/// `isCurrentlyPlaying` answers 0 on every item including the one that is. It is also half of what
/// playing an entry needs: `PlayItemInPlaybackQueue` takes the offset *and* the content-item id.
public struct NowPlayingQueueItem: Equatable, Sendable, Identifiable {

    /// The window position, from zero. Not a queue index in the player's own numbering — see
    /// `NowPlayingQueueWindow` for why the player's `queueIndex` is not that either.
    public let index: Int

    /// Never empty; an entry with no title is dropped in the adapter, where dropping it is safe.
    public let title: String

    public let artist: String?

    public let album: String?

    public let duration: TimeInterval?

    /// The player's own id for the entry, when it supplies one.
    ///
    /// Sent beside the offset by `PlayItemInPlaybackQueue`. Measured on macOS 27.0 against a local
    /// Music queue, the offset alone *also* moved the queue — but the probe that established this
    /// command measured it needing both, so both are sent. Sending an id the player supplied costs
    /// nothing and the disagreement is not worth resolving by shipping the narrower call.
    public let contentItemIdentifier: String?

    /// The Apple Music catalog id, when the entry has one. Zero-valued ids are dropped in the
    /// adapter. Carried because it is the join key any future artwork or lyrics lookup would need,
    /// and because it costs one integer.
    public let iTunesStoreIdentifier: Int64?

    /// What this entry's audio actually is, where the player says.
    ///
    /// **Only ever the playing entry.** MediaRemote populates `activeFormat` on the current item and
    /// answers nil for every one after it, which is exactly the entry the badge is about — see
    /// `AudioFormat.init(mediaRemoteFields:)`.
    public let audioFormat: AudioFormat?

    /// Whether this is the entry that is playing. **Positional, always** — `index == 0`.
    public var isCurrent: Bool { index == NowPlayingQueueWindow.currentIndex }

    /// Stable across a window that grows: the identifier where the player gives one, and the
    /// position where it does not.
    ///
    /// Deliberately **not** the index alone. A `ForEach` keyed on position re-uses row 3's view for
    /// whatever ends up at position 3 after a skip, so the list appears to keep its rows and change
    /// their words — which is the animation a list gets wrong in the way nobody can describe.
    public var id: String { contentItemIdentifier ?? "index-\(index)" }

    public init(
        index: Int,
        title: String,
        artist: String? = nil,
        album: String? = nil,
        duration: TimeInterval? = nil,
        contentItemIdentifier: String? = nil,
        iTunesStoreIdentifier: Int64? = nil,
        audioFormat: AudioFormat? = nil
    ) {
        self.index = index
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.contentItemIdentifier = contentItemIdentifier
        self.iTunesStoreIdentifier = iTunesStoreIdentifier
        self.audioFormat = audioFormat
    }
}

/// Reads the adapter's queue window. Pure, so the rule that matters is testable with no player,
/// no helper and no music.
///
/// ## The whole of the rule is the index
///
/// The queue MediaRemote vends **is** Up Next: played items are dropped from it, so index 0 is the
/// track that is playing and index 1 is the next one. Measured on macOS 27.0 against a 36-item
/// Music queue — after a skip it came back with 35 items and the *new* track at index 0 — and with
/// shuffle on the order changed completely at the same offsets while the playlist did not move,
/// which is exactly the case a sneak peek exists for.
///
/// **`isCurrentlyPlaying` is the field that reads like the discriminator and is not.** It answers 0
/// on every item including the one that is playing, with `includeMetadata` and `includeInfo` both
/// set. A parser keyed on it finds no current track at all and therefore no next one — silently,
/// because "the user is not listening to anything" is a completely ordinary answer.
public enum NowPlayingQueueWindow {

    /// Index 0. Named rather than written as a literal at the two call sites, because the entire
    /// correctness of this file is that these two numbers are what they are.
    static let currentIndex = 0

    static let nextIndex = 1

    /// The next track, or nil when the queue is too short to have one.
    ///
    /// A one-item window is the common case at the end of a playlist and is not a failure: there is
    /// no next track, so there is nothing to peek at.
    public static func next(fromQueueItems items: [Any]) -> NowPlayingUpNext? {
        guard items.indices.contains(nextIndex) else { return nil }
        return upNext(from: items[nextIndex])
    }

    /// What the queue says is playing right now.
    ///
    /// Only ever used to check the queue and the now-playing payload are describing the same track
    /// — see `NowPlayingAdapterDecoder`. Never used to *find* the current track, which is the index.
    public static func currentIdentifier(fromQueueItems items: [Any]) -> String? {
        guard items.indices.contains(currentIndex),
              let fields = items[currentIndex] as? [String: Any]
        else { return nil }
        return NowPlayingSnapshot.trimmedOrNil(fields["contentItemIdentifier"] as? String)
    }

    /// The array out of a `{"type":"queue"}` envelope, or nil if this is not one.
    ///
    /// Returns an empty array rather than nil for a queue that is genuinely empty, because the two
    /// mean different things downstream: an absent array is a line we could not read and must
    /// change nothing, and an empty one is the player saying there is nothing queued.
    public static func items(fromQueueEnvelope envelope: [String: Any]) -> [Any]? {
        envelope["queueItems"] as? [Any]
    }

    /// The whole window as rows, in the order the player vended them.
    ///
    /// Entries that carry nothing a user could read are dropped in the adapter rather than here,
    /// and that placement is load-bearing: the discrimination is **positional**, so a placeholder
    /// keeping its slot would make every row after it name the wrong track and every double-click
    /// jump to the wrong one. Anything that still fails to parse here is dropped too, and the
    /// indices are assigned after the drop for the same reason.
    ///
    /// How many rows to ask for is not decided here. A library queue on shuffle is tens of
    /// thousands of entries, so the caller asks for what is on screen plus a page and asks again
    /// when the reader reaches the end — see `NowPlayingQueuePaging`.
    public static func rows(fromQueueItems items: [Any]) -> [NowPlayingQueueItem] {
        var rows: [NowPlayingQueueItem] = []
        rows.reserveCapacity(items.count)
        for item in items {
            guard let fields = item as? [String: Any],
                  let title = NowPlayingSnapshot.trimmedOrNil(fields["title"] as? String)
            else { continue }
            rows.append(
                NowPlayingQueueItem(
                    index: rows.count,
                    title: title,
                    artist: NowPlayingSnapshot.trimmedOrNil(fields["artist"] as? String),
                    album: NowPlayingSnapshot.trimmedOrNil(fields["album"] as? String),
                    // Seconds. The adapter deliberately does not convert these under `--micros` —
                    // that flag exists because the *playhead* is anchored to a timestamp, and a
                    // queue entry's duration is a track length nothing is anchored to.
                    duration: (fields["duration"] as? NSNumber).map(\.doubleValue),
                    contentItemIdentifier: NowPlayingSnapshot.trimmedOrNil(
                        fields["contentItemIdentifier"] as? String
                    ),
                    iTunesStoreIdentifier: (fields["iTunesStoreIdentifier"] as? NSNumber)?.int64Value,
                    // Present on the playing entry alone, which is the only one it is asked of.
                    audioFormat: (fields["audioFormat"] as? [String: Any])
                        .flatMap(AudioFormat.init(mediaRemoteFields:))
                )
            )
        }
        return rows
    }

    private static func upNext(from item: Any) -> NowPlayingUpNext? {
        guard let fields = item as? [String: Any],
              let title = NowPlayingSnapshot.trimmedOrNil(fields["title"] as? String)
        else { return nil }
        return NowPlayingUpNext(
            title: title,
            artist: NowPlayingSnapshot.trimmedOrNil(fields["artist"] as? String),
            album: NowPlayingSnapshot.trimmedOrNil(fields["album"] as? String),
            contentItemIdentifier: NowPlayingSnapshot.trimmedOrNil(
                fields["contentItemIdentifier"] as? String
            )
        )
    }
}
