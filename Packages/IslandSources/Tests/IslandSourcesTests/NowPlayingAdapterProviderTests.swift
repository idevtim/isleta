import Darwin
import Foundation
import Testing

@testable import IslandSources

/// The helper process, end to end.
///
/// The real `MediaRemoteAdapter.framework` is not vendored in this checkout, so what is exercised
/// here is everything *around* the framework call: spawning, newline framing across arbitrary pipe
/// reads, diff merging, the retirement rule the adapter's README states, and — the part with real
/// teeth — that `stop()` leaves no process behind. Those are where the bugs are. The framework call
/// itself is one line of Perl in someone else's repository.
///
/// The stub speaks the documented line protocol, so the day the adapter is vendored these tests keep
/// their meaning: if the real helper's output ever stops matching what is written here, the mismatch
/// is a change in the protocol, which is exactly the thing worth being told about.
@Suite("Now Playing — adapter provider")
@MainActor
struct NowPlayingAdapterProviderTests {

    private static let location = NowPlayingAdapterLocation(
        scriptURL: URL(fileURLWithPath: "/stub/adapter.pl"),
        frameworkURL: URL(fileURLWithPath: "/stub/MediaRemoteAdapter.framework")
    )

    private static let playing = """
        {"type":"data","diff":false,"payload":{"bundleIdentifier":"com.apple.Music",\
        "playing":true,"title":"Alone","artist":"Prznt","album":"Alone - Single"}}
        """

    private static func stubbed(_ arguments: [String]) -> NowPlayingAdapterProvider {
        NowPlayingAdapterProvider(
            location: location,
            executable: NowPlayingStubHelper.executable,
            arguments: arguments
        )
    }

    // MARK: - Unavailable

    /// The normal state of every developer build, and it must be an ordinary "no" rather than an
    /// error: `.denied` so IslandSettings has something to explain, never `.undetermined`, because
    /// `.undetermined` puts a "Grant Access" button on screen and there is no prompt that vendors a
    /// missing helper.
    @Test("with no adapter vendored the route is denied, with a user-readable reason")
    func unavailableWithoutAdapter() async {
        let provider = NowPlayingAdapterProvider(location: nil)
        let recorder = NowPlayingRecorder()
        provider.onUpdate = { recorder.record($0) }

        guard case .denied(let explanation) = provider.authorization else {
            Issue.record("expected .denied, got \(provider.authorization)")
            return
        }
        #expect(!explanation.isEmpty)
        // §10: says what the user gets, names no internals.
        #expect(!explanation.lowercased().contains("perl"))
        #expect(!explanation.lowercased().contains("entitle"))
        #expect(provider.authorization.isUsable == false)

        provider.start()
        await recorder.settle()
        #expect(recorder.updates.isEmpty)

        // And stopping something that never started is not a crash.
        provider.stop()
    }

    // MARK: - Streaming

    @Test("a stream of full state then a diff publishes both, in order")
    func streamsAndMerges() async {
        let provider = Self.stubbed(
            NowPlayingStubHelper.arguments(emitting: [
                Self.playing,
                #"{"type":"data","diff":true,"payload":{"playing":false}}"#,
            ])
        )
        let recorder = NowPlayingRecorder()
        provider.onUpdate = { recorder.record($0) }

        provider.start()
        defer { provider.stop() }

        #expect(await recorder.wait(forAtLeast: 2))
        #expect(recorder.titles == ["Alone", "Alone"])
        #expect(recorder.snapshots.map(\.isPlaying) == [true, false])
        // The merge survived the pipe: the diff carried only `playing`.
        #expect(recorder.snapshots[1].artist == "Prznt")
    }

    /// An adapter that starts and says nothing is a completely normal state — nothing is playing.
    /// It must not be mistaken for a failure and must not publish `.cleared`, which would mean
    /// "playback stopped" about a player that was never reported.
    @Test("an adapter that produces nothing publishes nothing")
    func silentAdapter() async {
        let provider = Self.stubbed(NowPlayingStubHelper.arguments(emitting: []))
        let recorder = NowPlayingRecorder()
        provider.onUpdate = { recorder.record($0) }

        provider.start()
        defer { provider.stop() }

        await recorder.settle()
        #expect(recorder.updates.isEmpty)
        #expect(provider.authorization == .notRequired)
    }

    @Test("malformed output is ignored and does not stop the good lines that follow")
    func malformedOutput() async {
        let provider = Self.stubbed(
            NowPlayingStubHelper.arguments(emitting: [
                "this is not json",
                "{ neither is this",
                Self.playing,
            ])
        )
        let recorder = NowPlayingRecorder()
        provider.onUpdate = { recorder.record($0) }

        provider.start()
        defer { provider.stop() }

        #expect(await recorder.wait(forAtLeast: 1))
        await recorder.settle()
        #expect(recorder.titles == ["Alone"])
    }

    // MARK: - Retirement

    /// The adapter's README is explicit: "you should not reinvoke the script when a fatal error
    /// occurs". The reason to obey rather than retry is §9 — a helper that fails at startup fails
    /// identically every time, so an automatic relaunch is an unthrottled spawn loop that pins a
    /// core with nothing on screen to explain it.
    @Test("a helper that exits fatally retires the route instead of respawning")
    func fatalExitRetiresRoute() async {
        let provider = Self.stubbed(
            NowPlayingStubHelper.arguments(emitting: [Self.playing], thenExit: 3)
        )
        let recorder = NowPlayingRecorder()
        provider.onUpdate = { recorder.record($0) }

        provider.start()
        defer { provider.stop() }

        // **Waited for by condition, not by count.** The claim is "a dead helper clears the
        // island", and `wait(forAtLeast: 2)` does not make it: a helper may publish more than one
        // snapshot before it exits, so on a loaded machine the second update was sometimes another
        // snapshot and the clear was still in flight. Flaked about one run in ten.
        #expect(await recorder.wait(forUpdateMatching: { $0 == .cleared }))
        // The track it reported, then a clear — the island must not keep showing a song whose only
        // source has died.
        #expect(recorder.updates.last == .cleared)

        guard case .denied = provider.authorization else {
            Issue.record("a dead helper must leave the route denied, got \(provider.authorization)")
            return
        }

        // Starting again is a no-op, not a second process. Compared against what was already
        // recorded rather than against a literal 2, for the reason above: the count is not the
        // thing under test, and pinning it re-introduces the assumption that just came out.
        let settled = recorder.updates.count
        provider.start()
        await recorder.settle()
        #expect(recorder.updates.count == settled)
    }

    @Test("a launch that fails retires the route without crashing")
    func launchFailureRetiresRoute() async {
        let provider = NowPlayingAdapterProvider(
            location: Self.location,
            executable: URL(fileURLWithPath: "/nonexistent/definitely-not-here")
        )
        let recorder = NowPlayingRecorder()
        provider.onUpdate = { recorder.record($0) }

        provider.start()
        #expect(await recorder.wait(forAtLeast: 1))
        #expect(recorder.updates == [.cleared])

        guard case .denied = provider.authorization else {
            Issue.record("expected .denied after a failed launch")
            return
        }
    }

    // MARK: - Teardown

    /// §9's "no child process behind" is not satisfied by a signal that was merely sent, so this
    /// asks the kernel. `kill(pid, 0)` keeps returning 0 for a zombie, so this also proves the
    /// reader actually reaps in `waitUntilExit()` rather than leaving a defunct entry behind.
    @Test("stop() leaves no child process")
    func stopLeavesNoChild() async throws {
        let provider = Self.stubbed(NowPlayingStubHelper.arguments(emitting: [Self.playing]))
        let recorder = NowPlayingRecorder()
        provider.onUpdate = { recorder.record($0) }

        provider.start()
        #expect(await recorder.wait(forAtLeast: 1))

        let pid = try #require(provider.childProcessIdentifier)
        #expect(kill(pid, 0) == 0)

        provider.stop()

        var alive = true
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if kill(pid, 0) != 0 {
                alive = false
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(alive == false, "the helper survived stop()")
    }

    /// The quit-path guarantee, and the one the test above cannot make.
    ///
    /// That test polls for ten seconds, so it passed throughout the period when teardown was
    /// scheduled on a queue rather than performed — the signal always landed long inside its window.
    /// `applicationWillTerminate` extends no such window: it returns into `exit()`, and anything not
    /// finished by then never happens. So this asks the kernel with **no polling at all**. It is the
    /// absence of a retry loop that is the test.
    ///
    /// `kill(pid, 0)` also succeeds against a zombie, so this pins the reaping too.
    @Test("stopAndWait() leaves no child process by the time it returns")
    func stopAndWaitLeavesNoChildOnReturn() async throws {
        let provider = Self.stubbed(NowPlayingStubHelper.arguments(emitting: [Self.playing]))
        let recorder = NowPlayingRecorder()
        provider.onUpdate = { recorder.record($0) }

        provider.start()
        #expect(await recorder.wait(forAtLeast: 1))

        let pid = try #require(provider.childProcessIdentifier)
        #expect(kill(pid, 0) == 0)

        provider.stopAndWait()

        #expect(kill(pid, 0) != 0, "the helper was still alive when stopAndWait() returned")
    }

    @Test("start is idempotent — a second call does not spawn a second helper")
    func startIsIdempotent() async throws {
        let provider = Self.stubbed(NowPlayingStubHelper.arguments(emitting: [Self.playing]))
        let recorder = NowPlayingRecorder()
        provider.onUpdate = { recorder.record($0) }

        provider.start()
        #expect(await recorder.wait(forAtLeast: 1))
        let first = try #require(provider.childProcessIdentifier)

        provider.start()
        await recorder.settle()

        #expect(provider.childProcessIdentifier == first)
        // One helper, so one report of the track — not two.
        #expect(recorder.updates.count == 1)

        provider.stop()
    }

    @Test("stop before start, and stop twice, are both no-ops")
    func stopIsSafeAnyTime() async {
        let provider = Self.stubbed(NowPlayingStubHelper.arguments(emitting: []))
        provider.stop()
        provider.start()
        provider.stop()
        provider.stop()
        await Task.yield()
    }
}
