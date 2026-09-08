import Foundation
import Testing

@testable import IslandSources

/// When to ask for a format the stream could not carry.
///
/// Every answer is bound to a local before `#expect` sees it: `shouldAsk` is mutating, and the macro
/// captures its expression for the failure message, which it cannot do to a mutating call.
@Suite("Asking for a missing audio format")
struct NowPlayingFormatRefreshTests {

    private static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// A second past `minimumInterval`, so an ask is refused only when a test means it to be.
    private static func later(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    /// **The reported bug, as a test.** Quit the player and come back on the same track: the format
    /// was cleared on the way out, no queue line carries it on the way back in, and before this the
    /// badge stayed missing until the user hit next and then previous.
    @Test("a track that comes back after the player quit is asked about again")
    func aResumedTrackIsAskedAboutAgain() {
        var refresh = NowPlayingFormatRefresh()
        let first = refresh.shouldAsk(forTrack: "track-1", hasFormat: false, now: Self.start)
        #expect(first)

        // Answered, so nothing more is asked while it holds a format.
        let answered = refresh.shouldAsk(forTrack: "track-1", hasFormat: true, now: Self.later(2))
        #expect(!answered)

        refresh.playerWentAway()
        let afterQuit = refresh.shouldAsk(forTrack: "track-1", hasFormat: false, now: Self.later(4))
        #expect(afterQuit, "the same track, asked again")
    }

    /// **An ask that finds nothing must not burn the track's only chance**, which is the bug the
    /// first version of this shipped with: measured 2026-09-08, a player that has just been reopened
    /// answers an immediate read with nothing, 29 ms later, and one ask meant the badge never came.
    @Test("an ask that finds nothing is followed by more, up to the cap")
    func anEmptyAnswerIsRetried() {
        var refresh = NowPlayingFormatRefresh()
        var asks = 0
        // A snapshot arrives several times a second; the spacing is what turns that into three asks.
        for tick in 0..<40 where refresh.shouldAsk(
            forTrack: "track-1", hasFormat: false, now: Self.later(Double(tick) * 0.25)
        ) {
            asks += 1
        }
        #expect(asks == NowPlayingFormatRefresh.maximumAttempts)
    }

    /// The spacing itself: two asks in the same instant is one ask.
    @Test("asks are spaced, however often the snapshot arrives")
    func asksAreSpaced() {
        var refresh = NowPlayingFormatRefresh()
        let first = refresh.shouldAsk(forTrack: "track-1", hasFormat: false, now: Self.start)
        let immediately = refresh.shouldAsk(forTrack: "track-1", hasFormat: false, now: Self.start)
        let anInstantLater = refresh.shouldAsk(
            forTrack: "track-1", hasFormat: false, now: Self.later(0.1)
        )
        #expect(first)
        #expect(!immediately)
        #expect(!anInstantLater)
    }

    /// The bound that keeps a library where nothing reports a format from spawning per snapshot.
    @Test("a track that genuinely has no format stops being asked about")
    func aFormatlessTrackSettles() {
        var refresh = NowPlayingFormatRefresh()
        for tick in 0..<10 {
            _ = refresh.shouldAsk(forTrack: "podcast-1", hasFormat: false, now: Self.later(Double(tick) * 2))
        }
        let afterTheCap = refresh.shouldAsk(forTrack: "podcast-1", hasFormat: false, now: Self.later(60))
        #expect(!afterTheCap)
    }

    @Test("nothing playing is never asked about")
    func silenceIsNotAskedAbout() {
        var refresh = NowPlayingFormatRefresh()
        let asked = refresh.shouldAsk(forTrack: nil, hasFormat: false, now: Self.start)
        #expect(!asked)
    }

    @Test("a track that already has a format is not asked about")
    func aKnownFormatIsNotAskedAbout() {
        var refresh = NowPlayingFormatRefresh()
        let asked = refresh.shouldAsk(forTrack: "track-1", hasFormat: true, now: Self.start)
        #expect(!asked)
    }

    /// A new track starts with its own allowance, however much the last one spent.
    @Test("each new track earns a fresh allowance")
    func eachTrackEarnsItsOwn() {
        var refresh = NowPlayingFormatRefresh()
        for tick in 0..<6 {
            _ = refresh.shouldAsk(forTrack: "track-1", hasFormat: false, now: Self.later(Double(tick) * 2))
        }
        let spent = refresh.shouldAsk(forTrack: "track-1", hasFormat: false, now: Self.later(20))
        #expect(!spent)

        let nextTrack = refresh.shouldAsk(forTrack: "track-2", hasFormat: false, now: Self.later(21))
        #expect(nextTrack)
    }

    /// A push that takes a format away is circumstances changing rather than an answer.
    @Test("a format taken away starts the allowance again")
    func aFormatTakenAwayStartsAgain() {
        var refresh = NowPlayingFormatRefresh()
        for tick in 0..<6 {
            _ = refresh.shouldAsk(forTrack: "track-1", hasFormat: false, now: Self.later(Double(tick) * 2))
        }
        let spent = refresh.shouldAsk(forTrack: "track-1", hasFormat: false, now: Self.later(20))
        #expect(!spent)

        refresh.formatWasTakenAway()
        let afterwards = refresh.shouldAsk(forTrack: "track-1", hasFormat: false, now: Self.later(21))
        #expect(afterwards)
    }
}
