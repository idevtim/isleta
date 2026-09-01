import Foundation
import IslandActivities
import Testing

@testable import IslandSources

@Suite("Now Playing — adapter line protocol")
struct NowPlayingAdapterStreamTests {

    /// A fixed stand-in for "when the line arrived", which the decoder uses as the anchor only when
    /// the payload carries no timestamp of its own. Injected so these stay pure functions.
    private static let instant = Date(timeIntervalSince1970: 1_700_000_000)

    private static let full = """
        {"type":"data","diff":false,"payload":{"bundleIdentifier":"com.apple.Music",\
        "playing":true,"title":"Alone","artist":"Prznt","album":"Alone - Single"}}
        """

    @Test("a full state becomes a snapshot")
    func fullState() {
        var decoder = NowPlayingAdapterDecoder(now: { Self.instant })
        let update = decoder.decode(line: Self.full)
        #expect(
            update
                == .snapshot(
                    NowPlayingSnapshot(
                        title: "Alone",
                        artist: "Prznt",
                        album: "Alone - Single",
                        isPlaying: true,
                        bundleIdentifier: "com.apple.Music",
                        // No time keys in this payload, but `playing` is true — a player that says
                        // it is playing and nothing about where it is still needs a timeline, or the
                        // equaliser has nothing to read and stands still on a track that is running.
                        timeline: ActivityTimeline(
                            elapsed: 0, duration: 0, anchor: Self.instant, rate: 1
                        ),
                        artworkIdentity: "Alone\u{1F}Prznt\u{1F}Alone - Single"
                    )
                )
        )
    }

    /// The bug this whole type exists to prevent. A `diff` payload carries only what changed, so a
    /// decoder that replaces its state on every line loses the artist and album the instant the user
    /// presses pause — and the first line of any session is a full state, so it never shows up in a
    /// quick manual check.
    @Test("a diff merges into the previous state instead of replacing it")
    func diffMerges() {
        var decoder = NowPlayingAdapterDecoder()
        _ = decoder.decode(line: Self.full)

        let update = decoder.decode(line: #"{"type":"data","diff":true,"payload":{"playing":false}}"#)
        guard case .snapshot(let snapshot) = update else {
            Issue.record("expected a snapshot, got \(String(describing: update))")
            return
        }
        #expect(snapshot.isPlaying == false)
        #expect(snapshot.title == "Alone")
        #expect(snapshot.artist == "Prznt")
        #expect(snapshot.album == "Alone - Single")
    }

    @Test("an explicit null in a diff clears just that field")
    func diffNullClearsField() {
        var decoder = NowPlayingAdapterDecoder()
        _ = decoder.decode(line: Self.full)

        let update = decoder.decode(line: #"{"type":"data","diff":true,"payload":{"album":null}}"#)
        guard case .snapshot(let snapshot) = update else {
            Issue.record("expected a snapshot, got \(String(describing: update))")
            return
        }
        #expect(snapshot.album == nil)
        #expect(snapshot.artist == "Prznt")
    }

    @Test("a full state replaces rather than merges")
    func fullStateReplaces() {
        var decoder = NowPlayingAdapterDecoder()
        _ = decoder.decode(line: Self.full)

        let update = decoder.decode(
            line: #"{"type":"data","diff":false,"payload":{"playing":true,"title":"Second"}}"#
        )
        guard case .snapshot(let snapshot) = update else {
            Issue.record("expected a snapshot, got \(String(describing: update))")
            return
        }
        #expect(snapshot.title == "Second")
        #expect(snapshot.artist == nil)
    }

    @Test("a null payload clears, and does not leak into the next diff")
    func nullPayloadClears() {
        var decoder = NowPlayingAdapterDecoder()
        _ = decoder.decode(line: Self.full)

        #expect(decoder.decode(line: #"{"type":"data","diff":false,"payload":null}"#) == .cleared)
        // Merging a later diff onto the state of a stopped player would resurrect its title.
        #expect(decoder.decode(line: #"{"type":"data","diff":true,"payload":{"playing":true}}"#) == .cleared)
    }

    @Test("a bare null line clears")
    func bareNullClears() {
        var decoder = NowPlayingAdapterDecoder()
        #expect(decoder.decode(line: "null") == .cleared)
    }

    /// `get` prints a bare payload with no envelope. The same decoder has to serve it, or the
    /// diagnostics path needs a second parser that can drift from this one.
    @Test("a bare get payload is accepted")
    func barePayload() {
        var decoder = NowPlayingAdapterDecoder(now: { Self.instant })
        let update = decoder.decode(line: #"{"playing":true,"title":"Alone"}"#)
        #expect(
            update
                == .snapshot(
                    NowPlayingSnapshot(
                        title: "Alone",
                        isPlaying: true,
                        timeline: ActivityTimeline(
                            elapsed: 0, duration: 0, anchor: Self.instant, rate: 1
                        ),
                        artworkIdentity: "Alone\u{1F}\u{1F}"
                    )
                )
        )
    }

    /// Malformed input must be *silence*, not a clear. Anything else lets a future adapter release
    /// blank a playing track by printing a line this version has not heard of.
    @Test(
        "malformed and unknown lines change nothing",
        arguments: [
            "",
            "   ",
            "not json at all",
            "{ this is not json",
            "[1, 2, 3]",
            #"{"type":"heartbeat"}"#,
            #"{"type":"error","message":"boom"}"#,
        ]
    )
    func malformedLinesAreSilent(line: String) {
        var decoder = NowPlayingAdapterDecoder()
        #expect(decoder.decode(line: Self.full) != nil)
        #expect(decoder.decode(line: line) == nil)

        // And the state it was holding survives.
        let after = decoder.decode(line: #"{"type":"data","diff":true,"payload":{"playing":false}}"#)
        guard case .snapshot(let snapshot) = after else {
            Issue.record("expected the previous state to survive")
            return
        }
        #expect(snapshot.title == "Alone")
    }

    @Test("a payload with no title is nothing to show, not a blank island")
    func titlelessPayloadClears() {
        var decoder = NowPlayingAdapterDecoder()
        #expect(decoder.decode(line: #"{"type":"data","diff":false,"payload":{"playing":true}}"#) == .cleared)
        #expect(
            decoder.decode(line: #"{"type":"data","diff":false,"payload":{"playing":true,"title":"   "}}"#)
                == .cleared
        )
    }

    @Test("empty artist and album become nil rather than a blank subtitle line")
    func emptyFieldsNormalize() {
        var decoder = NowPlayingAdapterDecoder()
        let update = decoder.decode(
            line: #"{"type":"data","diff":false,"payload":{"playing":true,"title":"Alone","artist":"","album":"  "}}"#
        )
        guard case .snapshot(let snapshot) = update else {
            Issue.record("expected a snapshot")
            return
        }
        #expect(snapshot.artist == nil)
        #expect(snapshot.album == nil)
    }

    /// A missing `playing` flag must read as paused. The other way round, the island tells the user
    /// a track is playing while their speakers are silent.
    @Test("a missing playing flag reads as paused")
    func missingPlayingFlag() {
        var decoder = NowPlayingAdapterDecoder(now: { Self.instant })
        let update = decoder.decode(line: #"{"type":"data","diff":false,"payload":{"title":"Alone"}}"#)
        // And with nothing playing and no position reported there is nothing to anchor, so no
        // timeline either — a bar stuck at zero would invite a drag the route cannot honor.
        #expect(
            update
                == .snapshot(
                    NowPlayingSnapshot(
                        title: "Alone",
                        isPlaying: false,
                        artworkIdentity: "Alone\u{1F}\u{1F}"
                    )
                )
        )
    }

    @Test("reset forgets the merged state")
    func resetForgets() {
        var decoder = NowPlayingAdapterDecoder()
        _ = decoder.decode(line: Self.full)
        decoder.reset()
        #expect(decoder.decode(line: #"{"type":"data","diff":true,"payload":{"playing":false}}"#) == .cleared)
    }
}

@Suite("Now Playing — adapter location")
struct NowPlayingAdapterLocationTests {

    /// Not configurable, and the test is here so that making it configurable fails loudly. The
    /// capability belongs to Apple's Perl at Apple's path — `mediaremoted` grants MediaRemote access
    /// on a `com.apple.` code-signing identifier, and `/usr/bin/perl` reports `com.apple.perl`. A
    /// copied or re-signed Perl is a working interpreter that gets refused.
    @Test("the interpreter is Apple's own perl")
    func perlPathIsFixed() {
        #expect(NowPlayingAdapterLocation.perlExecutable.path == "/usr/bin/perl")
    }

    @Test("a location with a missing script or framework is not present")
    func missingPartsAreAbsent() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let script = root.appendingPathComponent("mediaremote-adapter.pl")
        let framework = root.appendingPathComponent("MediaRemoteAdapter.framework")

        let location = NowPlayingAdapterLocation(scriptURL: script, frameworkURL: framework)
        #expect(location.isPresent() == false)

        try Data().write(to: script)
        // Half-resolved is still absent: a script with no framework spawns a process that exits
        // immediately, once per launch, and looks like a broken feature rather than an absent one.
        #expect(location.isPresent() == false)

        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        #expect(location.isPresent() == true)
    }

    /// A `check.sh` build carries no adapter. That has to be an ordinary answer, not a failure —
    /// every developer run is in this state.
    @Test("a bundle with no vendored adapter resolves to nil")
    func developerBundleHasNoAdapter() {
        #expect(NowPlayingAdapterLocation.inBundle(Bundle.main) == nil)
    }

    /// `--no-artwork` is the memory budget, not a nicety: the adapter base64-encodes cover art into
    /// every payload, and §9 allows 60 MB resident for the whole app. `--no-diff` is deliberately
    /// absent — full states on every scrub is the other way to blow the same budget. `--queue` is
    /// the Up Next sneak peek folded into the helper that is already running, rather than a
    /// 60-360 ms process spawn per track change.
    @Test("the stream invocation asks for no artwork, a small queue window, and keeps diffs")
    func streamArguments() {
        let location = NowPlayingAdapterLocation(
            scriptURL: URL(fileURLWithPath: "/a/adapter.pl"),
            frameworkURL: URL(fileURLWithPath: "/a/MediaRemoteAdapter.framework")
        )
        #expect(
            location.streamArguments == [
                "/a/adapter.pl", "/a/MediaRemoteAdapter.framework", "stream", "--no-artwork",
                "--micros", "--queue", "--length=5",
            ]
        )
        #expect(location.streamArguments.contains("--no-diff") == false)
    }
}


@Suite("The progress bar does not snap to the start")
struct NowPlayingTimingCarryTests {

    private func line(_ payload: String, diff: Bool = false) -> String {
        "{\"type\":\"data\",\"diff\":\(diff),\"payload\":\(payload)}"
    }

    private let full = """
        {"title":"Destiny","artist":"NEFFEX","playing":false,"bundleIdentifier":"com.apple.Music",\
        "contentItemIdentifier":"24067::24075","durationMicros":206769251,\
        "elapsedTimeMicros":51436672,"playbackRate":0}
        """

    private func timeline(_ update: NowPlayingUpdate?) -> ActivityTimeline? {
        guard case .snapshot(let snapshot)? = update else { return nil }
        return snapshot.timeline
    }

    @Test("pressing play does not drop the duration and snap the bar to zero")
    func playKeepsTheDuration() {
        // The reported behavior: the bar goes all the way back to 0% and then returns, and only on
        // the first press. The payload that arrives on play is a *full* one that reports what
        // changed and omits the timing keys — replacing wholesale zeroed the duration.
        var decoder = NowPlayingAdapterDecoder()
        _ = decoder.decode(line: line(full))

        let onPlay = line("""
            {"title":"Destiny","playing":true,"bundleIdentifier":"com.apple.Music",\
            "contentItemIdentifier":"24067::24075","playbackRate":1}
            """)
        let after = timeline(decoder.decode(line: onPlay))

        let resolved = try! #require(after)
        #expect(resolved.duration > 200, "the duration was dropped, so the bar reads 0%")
        #expect(resolved.rate == 1, "the one thing that did change must still be taken")
    }

    @Test("a different track replaces the timing rather than inheriting it")
    func newTrackDoesNotInherit() {
        // The failure that would be worse than the one being fixed: one track's duration leaking
        // into the next, so a three-minute song shows a five-minute bar.
        var decoder = NowPlayingAdapterDecoder()
        _ = decoder.decode(line: line(full))

        let next = line("""
            {"title":"Alone","playing":true,"bundleIdentifier":"com.apple.Music",\
            "contentItemIdentifier":"99::99","durationMicros":143293265,"elapsedTimeMicros":0,\
            "playbackRate":1}
            """)
        let resolved = try! #require(timeline(decoder.decode(line: next)))
        #expect(abs(resolved.duration - 143.293265) < 0.01)
    }

    @Test("a payload naming no track replaces, as it always did")
    func anonymousPayloadReplaces() {
        var decoder = NowPlayingAdapterDecoder()
        _ = decoder.decode(line: line(full))

        // No `contentItemIdentifier`: nothing says this is the same track, so nothing is carried.
        let anonymous = line("""
            {"title":"Something","playing":true,"bundleIdentifier":"com.apple.Music"}
            """)
        let resolved = timeline(decoder.decode(line: anonymous))
        #expect(resolved?.duration ?? 0 == 0)
    }

    @Test("a diff still merges, and still wins over what was carried")
    func diffStillMerges() {
        var decoder = NowPlayingAdapterDecoder()
        _ = decoder.decode(line: line(full))
        let moved = line("{\"elapsedTimeMicros\":90000000}", diff: true)
        let resolved = try! #require(timeline(decoder.decode(line: moved)))
        #expect(abs(resolved.elapsed - 90) < 0.01)
        #expect(resolved.duration > 200)
    }
}
