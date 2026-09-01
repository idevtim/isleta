import Foundation
import IslandActivities
import Testing

@testable import IslandSources

@Suite("Now Playing timeline, skip and artwork keys")
struct NowPlayingTimelineTests {

    private let fallback = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - The two spellings of the time keys

    /// `--micros` is what `streamArguments` asks for, and it is the spelling the scrub bar depends
    /// on: the plain form rounds `timestamp` to the whole second.
    @Test("microsecond keys give an exact anchor")
    func microseconds() throws {
        let fields: [String: Any] = [
            "elapsedTimeMicros": 42_500_000,
            "durationMicros": 210_000_000,
            "timestampEpochMicros": 1_700_000_123_456_789,
            "playbackRate": 1,
        ]
        let timeline = try #require(
            NowPlayingAdapterDecoder.timeline(from: fields, isPlaying: true, fallbackAnchor: fallback)
        )
        #expect(timeline.elapsed == 42.5)
        #expect(timeline.duration == 210)
        #expect(abs(timeline.anchor.timeIntervalSince1970 - 1_700_000_123.456789) < 0.000_01)
        #expect(timeline.rate == 1)
    }

    /// Still parsed, because `get` may be run without the flag and because an adapter release could
    /// change which spelling it defaults to.
    @Test("the plain keys parse, ISO timestamp and all")
    func plainKeys() throws {
        let fields: [String: Any] = [
            "elapsedTime": 61.0,
            "duration": 200.0,
            "timestamp": "2023-11-14T22:13:20Z",
            "playbackRate": 1,
        ]
        let timeline = try #require(
            NowPlayingAdapterDecoder.timeline(from: fields, isPlaying: true, fallbackAnchor: fallback)
        )
        #expect(timeline.elapsed == 61)
        #expect(timeline.duration == 200)
        #expect(timeline.anchor == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("a timestamp that is not a date falls back to the arrival instant")
    func unparseableTimestamp() throws {
        let fields: [String: Any] = ["elapsedTime": 5.0, "timestamp": "later", "playbackRate": 1]
        let timeline = try #require(
            NowPlayingAdapterDecoder.timeline(from: fields, isPlaying: true, fallbackAnchor: fallback)
        )
        #expect(timeline.anchor == fallback)
    }

    // MARK: - Rate

    /// A player that reports no rate at all leaves `playing` as the only thing to infer it from.
    @Test("a missing playback rate is inferred from whether it is playing")
    func inferredRate() throws {
        let playing = try #require(
            NowPlayingAdapterDecoder.timeline(
                from: ["elapsedTime": 5.0, "duration": 100.0],
                isPlaying: true,
                fallbackAnchor: fallback
            )
        )
        #expect(playing.rate == 1)

        let paused = try #require(
            NowPlayingAdapterDecoder.timeline(
                from: ["elapsedTime": 5.0, "duration": 100.0],
                isPlaying: false,
                fallbackAnchor: fallback
            )
        )
        #expect(paused.rate == 0)
        #expect(paused.isAdvancing == false)
    }

    /// The reported rate wins over the flag: a paused player that still reports rate zero and a
    /// podcast at 1.5x are the same code path.
    @Test("a reported rate is believed over the playing flag")
    func reportedRateWins() throws {
        let timeline = try #require(
            NowPlayingAdapterDecoder.timeline(
                from: ["elapsedTime": 5.0, "playbackRate": 1.5],
                isPlaying: true,
                fallbackAnchor: fallback
            )
        )
        #expect(timeline.rate == 1.5)
    }

    // MARK: - When there is no timeline at all

    /// A stopped player with nothing to say about position must not produce a bar stuck at zero,
    /// which would invite a drag it cannot honor.
    @Test("nothing to anchor produces no timeline")
    func noTimeline() {
        #expect(
            NowPlayingAdapterDecoder.timeline(
                from: ["title": "x"],
                isPlaying: false,
                fallbackAnchor: fallback
            ) == nil
        )
    }

    /// A radio station reports no position and no duration, and the equaliser still has to run —
    /// which is what the timeline in the trailing flank is read for.
    @Test("a playing stream with no position still gets a timeline")
    func playingStreamGetsTimeline() throws {
        let timeline = try #require(
            NowPlayingAdapterDecoder.timeline(
                from: [:],
                isPlaying: true,
                fallbackAnchor: fallback
            )
        )
        #expect(timeline.isAdvancing)
        #expect(timeline.fraction(at: fallback) == nil)
    }

    // MARK: - Through the decoder

    @Test("a full payload decodes to a snapshot carrying the timeline")
    func endToEnd() throws {
        var decoder = NowPlayingAdapterDecoder(now: { self.fallback })
        let line = """
        {"type":"data","diff":false,"payload":{"title":"Song","artist":"Band","playing":true,\
        "elapsedTimeMicros":10000000,"durationMicros":100000000,\
        "timestampEpochMicros":1700000000000000,"playbackRate":1,\
        "contentItemIdentifier":"abc-123","prohibitsSkip":false}}
        """
        guard case .snapshot(let snapshot)? = decoder.decode(line: line) else {
            Issue.record("expected a snapshot")
            return
        }
        #expect(snapshot.title == "Song")
        #expect(snapshot.canSkip)
        #expect(snapshot.artworkIdentity == "abc-123")
        let timeline = try #require(snapshot.timeline)
        #expect(timeline.duration == 100)
        #expect(timeline.position(at: fallback.addingTimeInterval(5)) == 15)
    }

    /// A player that forbids skipping must produce a Next button that is drawn dimmed *and* inert.
    /// Absent means the player did not say, which is not a prohibition.
    @Test("prohibitsSkip inverts to canSkip, and absent means allowed")
    func prohibitsSkip() {
        var decoder = NowPlayingAdapterDecoder(now: { self.fallback })
        guard case .snapshot(let forbidden)? = decoder.decode(
            line: #"{"title":"Ad","playing":true,"prohibitsSkip":true}"#
        ) else {
            Issue.record("expected a snapshot")
            return
        }
        #expect(forbidden.canSkip == false)

        var second = NowPlayingAdapterDecoder(now: { self.fallback })
        guard case .snapshot(let quiet)? = second.decode(line: #"{"title":"Song","playing":true}"#)
        else {
            Issue.record("expected a snapshot")
            return
        }
        #expect(quiet.canSkip)
    }

    /// The artwork key must not move when the track has not changed, or every pause re-fetches
    /// 155 KB of base64.
    @Test("the artwork key is stable across pause, seek and rate changes")
    func artworkIdentityIsStable() {
        var decoder = NowPlayingAdapterDecoder(now: { self.fallback })
        func identity(_ line: String) -> String? {
            guard case .snapshot(let snapshot)? = decoder.decode(line: line) else { return nil }
            return snapshot.artworkIdentity
        }
        let first = identity(#"{"type":"data","diff":false,"payload":{"title":"Song","artist":"Band","playing":true,"elapsedTime":0}}"#)
        let paused = identity(#"{"type":"data","diff":true,"payload":{"playing":false,"playbackRate":0}}"#)
        let seeked = identity(#"{"type":"data","diff":true,"payload":{"elapsedTime":90}}"#)
        #expect(first != nil)
        #expect(first == paused)
        #expect(first == seeked)

        let other = identity(#"{"type":"data","diff":true,"payload":{"title":"Another"}}"#)
        #expect(other != first)
    }

    // MARK: - Argument vectors

    /// `--no-artwork` is the memory budget and `--micros` is the scrub bar's precision. Pinned
    /// because both are one careless edit from being lost, and neither failure is visible until it
    /// is measured.
    @Test("the stream is asked for microseconds and no artwork")
    func streamArguments() {
        let location = NowPlayingAdapterLocation(
            scriptURL: URL(fileURLWithPath: "/tmp/a.pl"),
            frameworkURL: URL(fileURLWithPath: "/tmp/A.framework")
        )
        #expect(location.streamArguments.contains("--no-artwork"))
        #expect(location.streamArguments.contains("--micros"))
        #expect(location.streamArguments.contains("stream"))
    }

    /// The one invocation deliberately *without* `--no-artwork`, and the reason `stream` may never
    /// have it: `stream` re-emits the whole payload on every update.
    @Test("the artwork fetch is the only invocation that asks for artwork")
    func artworkArguments() {
        let location = NowPlayingAdapterLocation(
            scriptURL: URL(fileURLWithPath: "/tmp/a.pl"),
            frameworkURL: URL(fileURLWithPath: "/tmp/A.framework")
        )
        #expect(location.artworkArguments.contains("get"))
        #expect(!location.artworkArguments.contains("--no-artwork"))
    }

    /// Seconds at the API boundary, microseconds on the wire. The unit conversion is the one thing
    /// in the transport that can be silently wrong by six orders of magnitude.
    @Test("seek converts seconds to microseconds and never goes negative")
    func seekArguments() {
        let location = NowPlayingAdapterLocation(
            scriptURL: URL(fileURLWithPath: "/tmp/a.pl"),
            frameworkURL: URL(fileURLWithPath: "/tmp/A.framework")
        )
        #expect(location.seekArguments(toSeconds: 12.5).last == "12500000")
        #expect(location.seekArguments(toSeconds: -3).last == "0")
    }

    /// The ids are Apple's, read from the vendored `MediaRemote.h`. They are a wire format, so a
    /// typo is a button that does the wrong thing rather than one that fails to compile.
    @Test("the command ids match MRCommand")
    func commandIdentifiers() {
        #expect(NowPlayingCommand.previousTrack.rawValue == 5)
        #expect(NowPlayingCommand.togglePlayPause.rawValue == 2)
        #expect(NowPlayingCommand.nextTrack.rawValue == 4)
    }
}

// MARK: - The playhead across a play/pause edge

/// The adapter reports a play or a pause as **two lines**, and everything here follows from that.
///
/// Captured from Apple Music on macOS 27.0 by streaming the real adapter and pressing the real
/// buttons: `{"playing": true}` arrives first and the fresh position **87 ms** later; on the way
/// back, `{"playing": false}` arrives first and the fresh position **217 ms** later. In that window
/// the merged state holds a position measured before the press. Combining it with the new flag is
/// what made the bar move when the user had just asked it to stop — reported from use as "the
/// progress bar seems to move, please make sure it stays put".
///
/// The fixtures are the captured lines, trimmed to the keys that matter.
@Suite("The playhead across a play/pause edge")
struct NowPlayingPlayPauseEdgeTests {

    /// The player's own clock, as captured. The track is 228.518 s long.
    private static let paused = 1_787_858_074.713945
    private static let playing = 1_787_858_350.940159
    private static let pressedPause = 1_787_858_354.760000
    private static let settled = 1_787_858_354.975889

    private static func full(rate: Double?) -> String {
        let rateField = rate.map { "\"playbackRate\":\($0)," } ?? ""
        return """
        {"type":"data","diff":false,"payload":{\(rateField)\
        "timestampEpochMicros":1787858074713945,"elapsedTimeMicros":147251659,\
        "durationMicros":228518000,"contentItemIdentifier":"a","playing":false,\
        "title":"T","bundleIdentifier":"com.apple.Music"}}
        """
    }

    private static let flagPlaying = #"{"type":"data","diff":true,"payload":{"playing":true}}"#
    private static let flagPaused = #"{"type":"data","diff":true,"payload":{"playing":false}}"#

    private static func position(
        _ decoder: inout NowPlayingAdapterDecoder, _ line: String, at instant: Double
    ) -> Double? {
        guard case .snapshot(let snapshot)? = decoder.decode(line: line),
              let timeline = snapshot.timeline
        else { return nil }
        return timeline.position(at: Date(timeIntervalSince1970: instant))
    }

    /// **The one the user saw.** A player that does not report `playbackRate` — or one whose merged
    /// state has lost it, which is every track change, because `carriedTimingKeys` deliberately does
    /// not carry a rate forward — gets `rate` 1 from the `playing` flag alone. Applied to an anchor
    /// that is minutes old, `elapsed + (now - anchor)` runs past the end of the track and clamps
    /// there: **the bar slams to 100% and returns a frame later.**
    ///
    /// Measured at 1.00000 of the track before the fix, against 0.64438 either side of it.
    @Test("pressing play does not throw the playhead at the end of the track")
    func playDoesNotSlamToTheEnd() {
        nonisolated(unsafe) var clock = Date(timeIntervalSince1970: Self.paused)
        var decoder = NowPlayingAdapterDecoder(now: { clock })

        _ = Self.position(&decoder, Self.full(rate: nil), at: Self.paused)

        clock = Date(timeIntervalSince1970: Self.playing)
        let onPress = Self.position(&decoder, Self.flagPlaying, at: Self.playing)
        #expect(onPress != nil)
        // Where it already was, to the millisecond — not 228.518.
        #expect(abs((onPress ?? 0) - 147.251659) < 0.001)
    }

    /// The other half, and the one Apple Music actually shows: it leaves a *stale* `playbackRate` of
    /// 1 in the merged state, so the pause diff was read as "still playing at 1×" and the bar ran on
    /// for the whole 217 ms before the real position landed.
    ///
    /// A paused player does not advance, whatever the leftover rate says.
    @Test("pressing pause stops the playhead on the press, not on the line after it")
    func pauseStopsOnThePress() {
        nonisolated(unsafe) var clock = Date(timeIntervalSince1970: Self.paused)
        var decoder = NowPlayingAdapterDecoder(now: { clock })

        _ = Self.position(&decoder, Self.full(rate: 0), at: Self.paused)
        clock = Date(timeIntervalSince1970: Self.playing)
        _ = Self.position(&decoder, Self.flagPlaying, at: Self.playing)
        _ = Self.position(
            &decoder,
            #"{"type":"data","diff":true,"payload":{"playbackRate":1,"timestampEpochMicros":1787858350940159,"elapsedTimeMicros":147280823}}"#,
            at: Self.playing
        )

        clock = Date(timeIntervalSince1970: Self.pressedPause)
        let onPress = Self.position(&decoder, Self.flagPaused, at: Self.pressedPause)
        // Frozen where it was at the press.
        let expected = 147.280823 + (Self.pressedPause - Self.playing)
        #expect(abs((onPress ?? 0) - expected) < 0.01)

        // And it stays there while the corrective line is in flight.
        let stillThere = Self.position(&decoder, Self.flagPaused, at: Self.settled)
        #expect(abs((stillThere ?? 0) - expected) < 0.01)
    }

    /// What the player finally reports has to agree with what was drawn, or the fix has only moved
    /// the jump. On the captured edge the two differ by 0.13 s of a 228 s track — 0.11 pt of a
    /// 200 pt bar, which is the sub-pixel correction this is allowed to make.
    @Test("the player's own position agrees with the frozen one to within a pixel")
    func theCorrectionIsSubPixel() {
        nonisolated(unsafe) var clock = Date(timeIntervalSince1970: Self.paused)
        var decoder = NowPlayingAdapterDecoder(now: { clock })

        _ = Self.position(&decoder, Self.full(rate: 0), at: Self.paused)
        clock = Date(timeIntervalSince1970: Self.playing)
        _ = Self.position(&decoder, Self.flagPlaying, at: Self.playing)
        _ = Self.position(
            &decoder,
            #"{"type":"data","diff":true,"payload":{"playbackRate":1,"timestampEpochMicros":1787858350940159,"elapsedTimeMicros":147280823}}"#,
            at: Self.playing
        )
        clock = Date(timeIntervalSince1970: Self.pressedPause)
        let frozen = Self.position(&decoder, Self.flagPaused, at: Self.pressedPause) ?? 0

        clock = Date(timeIntervalSince1970: Self.settled)
        let reported = Self.position(
            &decoder,
            #"{"type":"data","diff":true,"payload":{"playbackRate":0,"timestampEpochMicros":1787858354975889,"elapsedTimeMicros":151227738}}"#,
            at: Self.settled
        ) ?? 0

        let drift = abs(reported - frozen)
        #expect(drift < 0.25, "the correction is \(drift)s")
        // A quarter of a second of a 228 s track in a 200 pt bar is a fifth of a point.
        #expect(drift / 228.518 * 200 < 1)
    }

    /// A line that restates the same motion must not nudge the playhead. Re-anchoring on every line
    /// would make the bar lag by the delivery latency of whatever arrived last — a queue line, an
    /// artwork line — which is the bug this fix could most easily have become.
    @Test("a line that does not change the rate leaves the playhead alone")
    func steadyLinesDoNotReAnchor() {
        nonisolated(unsafe) var clock = Date(timeIntervalSince1970: Self.playing)
        var decoder = NowPlayingAdapterDecoder(now: { clock })

        _ = Self.position(
            &decoder,
            #"{"type":"data","diff":false,"payload":{"playbackRate":1,"timestampEpochMicros":1787858350940159,"elapsedTimeMicros":147280823,"durationMicros":228518000,"contentItemIdentifier":"a","playing":true,"title":"T"}}"#,
            at: Self.playing
        )

        clock = Date(timeIntervalSince1970: Self.pressedPause)
        // Same rate, no fresh timing — a metadata-only diff.
        let after = Self.position(
            &decoder, #"{"type":"data","diff":true,"payload":{"album":"A"}}"#, at: Self.pressedPause
        )
        let expected = 147.280823 + (Self.pressedPause - Self.playing)
        #expect(abs((after ?? 0) - expected) < 0.001, "the playhead was re-anchored when it should not be")
    }
}

