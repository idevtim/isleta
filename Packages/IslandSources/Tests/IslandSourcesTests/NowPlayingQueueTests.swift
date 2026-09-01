import Foundation
import Testing

@testable import IslandSources

/// The full queue window, the paging that asks for it, and the capability flags the payload carries.
///
/// Everything here runs with no helper, no player and no music — which is the point. The half that
/// cannot be tested this way is that MediaRemote answers at all, and that is a
/// code-signing-identifier gate no test bundle will ever clear. What *can* be tested is every rule
/// that has silently been got wrong once: the positional index, the capability that is read from the
/// wrong field, and the ask that is repeated sixty times a flick.
@Suite("Now Playing — the queue window, paging and capabilities")
struct NowPlayingQueueTests {

    private static func item(
        _ title: String,
        artist: String? = nil,
        album: String? = nil,
        id: String? = nil,
        duration: Double? = nil,
        storeIdentifier: Int64? = nil
    ) -> [String: Any] {
        var fields: [String: Any] = ["title": title]
        if let artist { fields["artist"] = artist }
        if let album { fields["album"] = album }
        if let id { fields["contentItemIdentifier"] = id }
        if let duration { fields["duration"] = duration }
        if let storeIdentifier { fields["iTunesStoreIdentifier"] = storeIdentifier }
        // Written into every fixture, always false, exactly as the real payload reports it. A parser
        // that ever started reading this would be caught by `currentIsIndexZeroNotTheFlag` below.
        fields["isCurrentlyPlaying"] = false
        return fields
    }

    // MARK: - Rows

    @Test("index 0 is the current track, and the flag named for it says nothing")
    func currentIsIndexZeroNotTheFlag() {
        let rows = NowPlayingQueueWindow.rows(fromQueueItems: [
            Self.item("Playing now", id: "a"),
            Self.item("Next", id: "b"),
            Self.item("After that", id: "c"),
        ])
        #expect(rows.count == 3)
        #expect(rows[0].isCurrent)
        #expect(!rows[1].isCurrent)
        #expect(!rows[2].isCurrent)
        // The discrimination is positional and nothing else. Every fixture carries
        // `isCurrentlyPlaying = false`, including index 0 — which is what the real payload does —
        // so a parser keyed on that field would report no current track at all.
        #expect(rows.map(\.index) == [0, 1, 2])
    }

    @Test("indices are assigned after unreadable entries are dropped")
    func indicesFollowTheDrop() {
        // An entry with no title cannot be drawn and cannot be named, so it is dropped — and the
        // index has to close up behind it. Left in place as a gap, every row after it would name
        // the wrong track *and* a double-click would jump to the wrong one, because the index is
        // the offset the command is sent with.
        let rows = NowPlayingQueueWindow.rows(fromQueueItems: [
            Self.item("Playing now", id: "a"),
            ["artist": "No title here"] as [String: Any],
            Self.item("Really next", id: "c"),
        ])
        #expect(rows.map(\.title) == ["Playing now", "Really next"])
        #expect(rows.map(\.index) == [0, 1])
        #expect(rows[1].title == "Really next")
    }

    @Test("a row carries everything a double-click needs and nothing it does not")
    func rowFields() throws {
        let rows = NowPlayingQueueWindow.rows(fromQueueItems: [
            Self.item("One", artist: " Someone ", album: "An Album", id: "a", duration: 290.6, storeIdentifier: 1_814_812_223)
        ])
        let row = try #require(rows.first)
        #expect(row.title == "One")
        // Trimmed at the boundary, like every other string this source reads: the adapter's JSON
        // can carry padding as easily as an absence.
        #expect(row.artist == "Someone")
        #expect(row.album == "An Album")
        #expect(row.duration == 290.6)
        #expect(row.contentItemIdentifier == "a")
        #expect(row.iTunesStoreIdentifier == 1_814_812_223)
    }

    @Test("a row's id is the player's, so a growing window does not re-use views")
    func rowIdentity() {
        let rows = NowPlayingQueueWindow.rows(fromQueueItems: [
            Self.item("One", id: "a"),
            Self.item("Two", id: "b"),
        ])
        #expect(rows[0].id == "a")
        #expect(rows[1].id == "b")
        // Only where the player supplies none does the position stand in — and it is spelled so it
        // cannot collide with an identifier that happens to be a number.
        let anonymous = NowPlayingQueueWindow.rows(fromQueueItems: [Self.item("One")])
        #expect(anonymous[0].id == "index-0")
    }

    @Test("an empty window is an answer, not a failure")
    func emptyWindow() {
        #expect(NowPlayingQueueWindow.rows(fromQueueItems: []).isEmpty)
        #expect(NowPlayingQueueWindow.rows(fromQueueItems: ["not a dictionary"]).isEmpty)
    }

    // MARK: - Paging

    @Test("a closed surface always asks for the resting window")
    func closedAsksForResting() {
        // However far the reader had scrolled before closing it. A list nobody is looking at must
        // not hold a hundred rows because it was scrolled ten minutes ago — every one of them is
        // re-read on every track change.
        #expect(NowPlayingQueuePaging.window(lastVisibleRow: 90, isOpen: false)
            == NowPlayingQueuePaging.restingWindow)
        #expect(NowPlayingQueuePaging.window(lastVisibleRow: 0, isOpen: false)
            == NowPlayingQueuePaging.restingWindow)
    }

    @Test("an open surface asks for what is on screen plus a page")
    func openAsksForALookahead() {
        #expect(NowPlayingQueuePaging.window(lastVisibleRow: 3, isOpen: true)
            == 4 + NowPlayingQueuePaging.lookahead)
        #expect(NowPlayingQueuePaging.window(lastVisibleRow: 20, isOpen: true)
            == 21 + NowPlayingQueuePaging.lookahead)
    }

    @Test("the window never exceeds the adapter's own ceiling")
    func windowIsCapped() {
        // The ceiling is a hard stop rather than a tuning knob: without it a reader who kept
        // scrolling would walk the ask up to the size of their library, which is the exact thing
        // windowing exists to avoid.
        #expect(NowPlayingQueuePaging.window(lastVisibleRow: 10_000, isOpen: true)
            == NowPlayingQueuePaging.maximumWindow)
    }

    @Test("the window never drops below the resting one while open")
    func windowHasAFloor() {
        #expect(NowPlayingQueuePaging.window(lastVisibleRow: 0, isOpen: true)
            >= NowPlayingQueuePaging.restingWindow)
        #expect(NowPlayingQueuePaging.window(lastVisibleRow: -5, isOpen: true)
            >= NowPlayingQueuePaging.restingWindow)
    }

    @Test("an ask that is not wider is not sent")
    func requestOnlyGrows() {
        // The suppression is the whole point. A scroll produces a sample per frame and each one
        // resolves to a window, so without this a single flick writes sixty control lines and costs
        // sixty MediaRemote round trips inside the helper that is also delivering track changes.
        #expect(NowPlayingQueuePaging.shouldRequest(25, having: 15, isOpen: true))
        #expect(!NowPlayingQueuePaging.shouldRequest(15, having: 15, isOpen: true))
        #expect(!NowPlayingQueuePaging.shouldRequest(10, having: 15, isOpen: true))
    }

    @Test("closing gives the window back, and only when it is not already back")
    func closingShrinks() {
        // The one case that is allowed to shrink. `isOpen: false` is what *closing* the surface
        // means, and giving the window back is the point of it.
        #expect(NowPlayingQueuePaging.shouldRequest(
            NowPlayingQueuePaging.restingWindow, having: 40, isOpen: false
        ))
        #expect(!NowPlayingQueuePaging.shouldRequest(
            NowPlayingQueuePaging.restingWindow,
            having: NowPlayingQueuePaging.restingWindow,
            isOpen: false
        ))
    }

    // MARK: - Capabilities

    @Test("the heart is drawn from supportsIsLiked, never from isFavorite")
    func likeCapabilityComesFromTheRightField() {
        var decoder = NowPlayingAdapterDecoder()
        // A track that is likeable and not favorite. Reading the *state* as the capability would draw
        // a dead heart on it, which is the whole of this bug.
        let update = decoder.decode(
            line: #"{"title":"One","playing":true,"supportsIsLiked":true,"isLiked":false}"#
        )
        guard case .snapshot(let snapshot)? = update else {
            Issue.record("expected a snapshot")
            return
        }
        #expect(snapshot.canFavorite)
        #expect(!snapshot.isFavorite)
    }

    @Test("a payload that mentions neither like key has no like to offer")
    func likeAbsentMeansNoLike() {
        var decoder = NowPlayingAdapterDecoder()
        // Measured on macOS 27.0 against a local Music library track: neither key is in the payload
        // at all. The honest drawing is a heart that is dimmed and inert — which is why this
        // defaults false where `canSkip` defaults true.
        let update = decoder.decode(line: #"{"title":"One","playing":true}"#)
        guard case .snapshot(let snapshot)? = update else {
            Issue.record("expected a snapshot")
            return
        }
        #expect(!snapshot.canFavorite)
        #expect(!snapshot.isFavorite)
        // And the *other* three limits are unaffected by it, which is the point of keeping them
        // separate: a track with no like is perfectly skippable.
        #expect(snapshot.canSkip)
        #expect(!snapshot.isRadioStation)
    }

    @Test("the two fifteen-second capabilities are read separately")
    func fifteenSecondCapabilities() {
        var decoder = NowPlayingAdapterDecoder()
        let update = decoder.decode(
            line: #"{"title":"An Episode","playing":true,"supportsRewind15Seconds":true,"supportsFastForward15Seconds":false}"#
        )
        guard case .snapshot(let snapshot)? = update else {
            Issue.record("expected a snapshot")
            return
        }
        // Two fields because the player reports two, and there is no reason to assume a player that
        // offers one offers the other — the same mistake as answering `prohibitsSkip` and
        // `radioStationHash` with a single flag.
        #expect(snapshot.canSkipBackFifteen)
        #expect(!snapshot.canSkipForwardFifteen)
    }

    // MARK: - The queue line

    @Test("a queue line fills the window as well as the peek")
    func queueLineFillsTheWindow() {
        var decoder = NowPlayingAdapterDecoder()
        _ = decoder.decode(line: #"{"type":"data","diff":false,"payload":{"title":"One","playing":true}}"#)
        _ = decoder.decode(
            line: #"{"type":"queue","queueItems":[{"title":"One"},{"title":"Two"},{"title":"Three"}]}"#
        )
        #expect(decoder.queueItems.map(\.title) == ["One", "Two", "Three"])
        #expect(decoder.queueItems[0].isCurrent)
    }

    @Test("a stop empties the window")
    func stopEmptiesTheWindow() {
        var decoder = NowPlayingAdapterDecoder()
        _ = decoder.decode(line: #"{"type":"data","diff":false,"payload":{"title":"One","playing":true}}"#)
        _ = decoder.decode(line: #"{"type":"queue","queueItems":[{"title":"One"},{"title":"Two"}]}"#)
        #expect(!decoder.queueItems.isEmpty)
        // A list left on screen after the player stopped is rows the user can double-click, acting
        // on a player nothing is reading.
        _ = decoder.decode(line: "null")
        #expect(decoder.queueItems.isEmpty)
    }

    @Test("the window survives a full state line for the same track")
    func windowSurvivesARestate() {
        var decoder = NowPlayingAdapterDecoder()
        _ = decoder.decode(line: #"{"type":"queue","queueItems":[{"title":"One"},{"title":"Two"}]}"#)
        // A `diff: false` payload replaces the merged state wholesale. The queue is held beside it
        // rather than inside it precisely so that a player re-reporting the same track in full does
        // not take the list away.
        _ = decoder.decode(line: #"{"type":"data","diff":false,"payload":{"title":"One","playing":true}}"#)
        #expect(decoder.queueItems.count == 2)
    }

    // MARK: - The argument vectors

    @Test("playing a queue entry sends 131 with both options")
    func playQueueItemArguments() {
        let location = NowPlayingAdapterLocation(
            scriptURL: URL(fileURLWithPath: "/s.pl"),
            frameworkURL: URL(fileURLWithPath: "/F.framework")
        )
        let arguments = location.playQueueItemArguments(atOffset: 2, contentItemIdentifier: "24082::24098")
        // 131 and not 122 or 0. Measured on macOS 27.0: the other two return `1` and change
        // nothing, which is why the effect is what gets verified and never the return value.
        #expect(arguments.contains("131"))
        #expect(arguments.contains("--offset=2"))
        #expect(arguments.contains("--content-item-id=24082::24098"))
    }

    @Test("a player that reports no identifier still gets a jump")
    func playQueueItemWithoutIdentifier() {
        let location = NowPlayingAdapterLocation(
            scriptURL: URL(fileURLWithPath: "/s.pl"),
            frameworkURL: URL(fileURLWithPath: "/F.framework")
        )
        let arguments = location.playQueueItemArguments(atOffset: 3, contentItemIdentifier: nil)
        #expect(arguments.contains("--offset=3"))
        // Absent rather than present and empty. MediaRemote treats a key carrying an empty string
        // differently from a key that is not there, and only one of the two works.
        #expect(!arguments.contains(where: { $0.hasPrefix("--content-item-id") }))
    }

    @Test("a negative offset cannot be sent")
    func offsetIsClamped() {
        let location = NowPlayingAdapterLocation(
            scriptURL: URL(fileURLWithPath: "/s.pl"),
            frameworkURL: URL(fileURLWithPath: "/F.framework")
        )
        #expect(location.playQueueItemArguments(atOffset: -4, contentItemIdentifier: nil)
            .contains("--offset=0"))
    }

    @Test("like and ban are the two ids, and nothing else rides with them")
    func likeArguments() {
        let location = NowPlayingAdapterLocation(
            scriptURL: URL(fileURLWithPath: "/s.pl"),
            frameworkURL: URL(fileURLWithPath: "/F.framework")
        )
        #expect(location.likeArguments(true).contains("106"))
        #expect(location.likeArguments(false).contains("107"))
        // No options. MediaRemote documents a track/station/hash triple for these and the fork can
        // express all three — Isleta simply has none of them to pass, because the now-playing
        // payload carries `isFavorite` and `supportsIsLiked` and none of the ids.
        #expect(!location.likeArguments(true).contains(where: { $0.hasPrefix("--") }))
    }

    @Test("the stream still asks for the queue, and for the resting window")
    func streamArgumentsCarryTheQueue() {
        let location = NowPlayingAdapterLocation(
            scriptURL: URL(fileURLWithPath: "/s.pl"),
            frameworkURL: URL(fileURLWithPath: "/F.framework")
        )
        #expect(location.streamArguments.contains("--queue"))
        #expect(location.streamArguments.contains("--length=\(NowPlayingQueuePaging.restingWindow)"))
    }
}
