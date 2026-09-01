import Foundation
import IslandActivities
import Testing

@testable import IslandSources

/// The queue window, read with no helper, no player and no music.
///
/// Everything here is the pure half of the sneak peek: which entry is the next song, and when the
/// decoder is allowed to believe it. The half that cannot be tested this way — that the adapter is
/// permitted to ask MediaRemote at all — is a code-signing-identifier gate that only Apple's Perl
/// clears, and no test bundle will ever be `com.apple.perl`.
@Suite("Now Playing — the Up Next queue window")
struct NowPlayingUpNextTests {

    private static func item(
        _ title: String,
        artist: String? = nil,
        album: String? = nil,
        id: String? = nil,
        currentlyPlaying: Bool = false
    ) -> [String: Any] {
        var fields: [String: Any] = ["title": title]
        if let artist { fields["artist"] = artist }
        if let album { fields["album"] = album }
        if let id { fields["contentItemIdentifier"] = id }
        // Written into every fixture on purpose. The adapter does not emit this key — the whole
        // point is that MediaRemote's own `isCurrentlyPlaying` is 0 on every item — and a parser
        // that ever started reading one would be caught by the `currentlyPlaying: true` fixture
        // below sitting at the wrong index.
        fields["isCurrentlyPlaying"] = currentlyPlaying
        return fields
    }

    @Test("index 1 is the next song, because index 0 is the one playing")
    func nextIsIndexOne() {
        let items: [Any] = [
            Self.item("SICKO MODE", artist: "Travis Scott", album: "ASTROWORLD", id: "a"),
            Self.item("Maybach", artist: "SEV", album: "Maybach - Single", id: "b"),
            Self.item("Alone", artist: "Prznt", id: "c"),
        ]
        #expect(
            NowPlayingQueueWindow.next(fromQueueItems: items)
                == NowPlayingUpNext(
                    title: "Maybach",
                    artist: "SEV",
                    album: "Maybach - Single",
                    contentItemIdentifier: "b"
                )
        )
        #expect(NowPlayingQueueWindow.currentIdentifier(fromQueueItems: items) == "a")
    }

    /// The trap, stated as a test. `isCurrentlyPlaying` answers 0 on every item including the one
    /// that is playing, so a parser keyed on it finds nothing — and here it is deliberately set on
    /// the *second* item, so a parser that started trusting it would return the third.
    @Test("isCurrentlyPlaying is ignored — the discrimination is positional")
    func ignoresIsCurrentlyPlaying() {
        let items: [Any] = [
            Self.item("Playing now", id: "a"),
            Self.item("Next", id: "b", currentlyPlaying: true),
            Self.item("After that", id: "c"),
        ]
        #expect(NowPlayingQueueWindow.next(fromQueueItems: items)?.title == "Next")
    }

    @Test("a queue with only the current track has no next song")
    func lastTrackOfAPlaylist() {
        #expect(NowPlayingQueueWindow.next(fromQueueItems: [Self.item("The last one")]) == nil)
        #expect(NowPlayingQueueWindow.next(fromQueueItems: []) == nil)
    }

    /// An entry with no title is dropped in the adapter rather than kept as a placeholder, and this
    /// pins the reason: the discrimination is positional, so a blank keeping its slot would make the
    /// track after the next one read as the next one.
    @Test("an untitled entry is not a next song")
    func untitledEntry() {
        let items: [Any] = [Self.item("Playing now"), ["artist": "Nobody"]]
        #expect(NowPlayingQueueWindow.next(fromQueueItems: items) == nil)
    }

    @Test("empty strings are absences, as everywhere else in this package")
    func trimsBlanks() {
        let items: [Any] = [
            Self.item("Playing now"),
            ["title": "  Maybach  ", "artist": "   ", "album": ""],
        ]
        let next = NowPlayingQueueWindow.next(fromQueueItems: items)
        #expect(next?.title == "Maybach")
        #expect(next?.artist == nil)
        #expect(next?.album == nil)
    }

    @Test("an envelope with no queueItems array says nothing")
    func envelopeWithoutItems() {
        #expect(NowPlayingQueueWindow.items(fromQueueEnvelope: ["type": "queue"]) == nil)
        // Empty is different from absent, and the decoder relies on that: an empty array is the
        // player saying there is nothing queued.
        #expect(NowPlayingQueueWindow.items(fromQueueEnvelope: ["queueItems": []])?.isEmpty == true)
    }
}

/// The queue as it arrives: a second line type on the adapter's stream, interleaved with the state
/// lines and ordered by nothing.
@Suite("Now Playing — the queue line")
struct NowPlayingQueueLineTests {

    private static let track = """
        {"type":"data","diff":false,"payload":{"bundleIdentifier":"com.apple.Music",\
        "playing":true,"title":"SICKO MODE","artist":"Travis Scott",\
        "contentItemIdentifier":"a"}}
        """

    private static let queue = """
        {"type":"queue","queueItems":[\
        {"title":"SICKO MODE","contentItemIdentifier":"a"},\
        {"title":"Maybach","artist":"SEV","contentItemIdentifier":"b"}]}
        """

    private static func snapshot(_ update: NowPlayingUpdate?) -> NowPlayingSnapshot? {
        guard case .snapshot(let snapshot)? = update else { return nil }
        return snapshot
    }

    @Test("a queue line puts the next track on the snapshot")
    func queueLineCarriesUpNext() {
        var decoder = NowPlayingAdapterDecoder()
        _ = decoder.decode(line: Self.track)
        let update = decoder.decode(line: Self.queue)
        #expect(Self.snapshot(update)?.upNext?.title == "Maybach")
        #expect(Self.snapshot(update)?.upNext?.artist == "SEV")
        // And it is still there on the next ordinary state change, because the queue has not moved.
        let paused = decoder.decode(line: #"{"type":"data","diff":true,"payload":{"playing":false}}"#)
        #expect(Self.snapshot(paused)?.upNext?.title == "Maybach")
    }

    /// The ordering hazard. The queue read is issued alongside the first state request rather than
    /// after it, so a queue line genuinely can be the first thing on the pipe — and
    /// `update(from:)` on an empty state resolves to `.cleared`, which takes the island away.
    @Test("a queue line before any track is silence, never a clear")
    func queueLineBeforeAnyTrack() {
        var decoder = NowPlayingAdapterDecoder()
        #expect(decoder.decode(line: Self.queue) == nil)
        // And it is remembered, so the state line behind it arrives complete.
        #expect(Self.snapshot(decoder.decode(line: Self.track))?.upNext?.title == "Maybach")
    }

    /// The few milliseconds after a skip, where the two lines disagree about what is playing. The
    /// queue still names the old track at index 0, so its "next" is the track already playing —
    /// exactly the wrong thing to name, and the only case worth withholding for.
    @Test("a queue describing a different track than the payload is withheld")
    func staleQueueIsWithheld() {
        var decoder = NowPlayingAdapterDecoder()
        _ = decoder.decode(line: Self.track)
        _ = decoder.decode(line: Self.queue)

        let skipped = decoder.decode(
            line: """
                {"type":"data","diff":false,"payload":{"bundleIdentifier":"com.apple.Music",\
                "playing":true,"title":"Maybach","contentItemIdentifier":"b"}}
                """
        )
        #expect(Self.snapshot(skipped)?.title == "Maybach")
        #expect(Self.snapshot(skipped)?.upNext == nil)
    }

    /// The other side of the same rule. Most players report no `contentItemIdentifier` at all, so
    /// "withhold unless the ids match" would mean never showing the peek anywhere but Music.
    @Test("with no identifier on either side there is nothing to check, so the queue is believed")
    func unidentifiedTrackTrustsTheQueue() {
        var decoder = NowPlayingAdapterDecoder()
        _ = decoder.decode(
            line: #"{"type":"data","diff":false,"payload":{"playing":true,"title":"Alone"}}"#
        )
        let update = decoder.decode(
            line: #"{"type":"queue","queueItems":[{"title":"Alone"},{"title":"Maybach"}]}"#
        )
        #expect(Self.snapshot(update)?.upNext?.title == "Maybach")
    }

    @Test("stopping forgets the queue")
    func stopClearsUpNext() {
        var decoder = NowPlayingAdapterDecoder()
        _ = decoder.decode(line: Self.track)
        _ = decoder.decode(line: Self.queue)
        #expect(decoder.decode(line: "null") == .cleared)
        #expect(Self.snapshot(decoder.decode(line: Self.track))?.upNext == nil)
    }

    @Test("a helper restart forgets the queue")
    func resetClearsUpNext() {
        var decoder = NowPlayingAdapterDecoder()
        _ = decoder.decode(line: Self.track)
        _ = decoder.decode(line: Self.queue)
        decoder.reset()
        #expect(Self.snapshot(decoder.decode(line: Self.track))?.upNext == nil)
    }

    /// The reason `NowPlayingAdapterDecoder` returns nil rather than `.cleared` for an envelope it
    /// does not understand, restated for the line type that has just been added to it: a consumer
    /// built before this shipped drops the queue line and goes on working.
    @Test("an unknown line type still changes nothing")
    func unknownTypeIsSilence() {
        var decoder = NowPlayingAdapterDecoder()
        _ = decoder.decode(line: Self.track)
        #expect(decoder.decode(line: #"{"type":"heartbeat"}"#) == nil)
    }

    @Test("the stream is asked for the queue, and for a small window of it")
    func streamArgumentsAskForTheQueue() {
        let location = NowPlayingAdapterLocation(
            scriptURL: URL(fileURLWithPath: "/tmp/adapter.pl"),
            frameworkURL: URL(fileURLWithPath: "/tmp/MediaRemoteAdapter.framework")
        )
        #expect(location.streamArguments.contains("--queue"))
        #expect(location.streamArguments.contains("--length=5"))
        // A one-shot costs 60-360 ms in process spawn against 15-30 ms of actual read, which is why
        // it exists for a person checking by hand and is on no path the app runs.
        #expect(location.queueArguments(length: 3).contains("queue"))
        #expect(location.queueArguments(length: 3).contains("--length=3"))
        #expect(location.queueArguments(length: 0).contains("--length=1"))
    }
}
