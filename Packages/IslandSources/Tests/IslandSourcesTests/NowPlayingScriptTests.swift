import AppKit
import Foundation
import Testing

@testable import IslandSources

@Suite("Now Playing — player payloads")
struct NowPlayingPlayerTests {

    /// The literal `userInfo` Music posted on macOS 27.0, captured from a live observer. Written out
    /// rather than paraphrased so that a future macOS renaming a key fails here with a readable
    /// diff, instead of in the field as an island that never appears.
    ///
    /// A function rather than a stored constant only because `[AnyHashable: Any]` is not `Sendable`
    /// and a static property of a non-`Sendable` type is a shared-mutable-state error under strict
    /// concurrency — which is the compiler making exactly the right point about foreign `userInfo`.
    private static func musicUserInfo() -> [AnyHashable: Any] {
        [
            "Player State": "Playing",
            "Name": "Alone",
            "Artist": "Prznt",
            "Album": "Alone - Single",
            "Total Time": 230_783,
            "Genre": "Hip Hop/Rap",
        ]
    }

    @Test("a playerInfo payload becomes a snapshot")
    func playerInfoParses() {
        let update = NowPlayingPlayer.music.update(fromPlayerInfo: Self.musicUserInfo())
        #expect(
            update
                == .snapshot(
                    NowPlayingSnapshot(
                        title: "Alone",
                        artist: "Prznt",
                        album: "Alone - Single",
                        isPlaying: true,
                        bundleIdentifier: "com.apple.Music",
                        // Derived from the three strings the user can see, because this route
                        // reports no `contentItemIdentifier`. It is the artwork *cache key*, and
                        // this route never fetches artwork — but a snapshot that carried one only
                        // sometimes would be two shapes of the same type.
                        artworkIdentity: "Alone\u{1F}Prznt\u{1F}Alone - Single"
                    )
                )
        )
    }

    /// Pause keeps the activity. Losing the island on every pause and regaining it on every resume
    /// would make the one ambient activity flicker in and out of a stack it is meant to sit quietly
    /// at the bottom of.
    @Test("paused is still a snapshot, with the flag flipped")
    func pausedIsNotCleared() {
        var info = Self.musicUserInfo()
        info["Player State"] = "Paused"
        guard case .snapshot(let snapshot) = NowPlayingPlayer.music.update(fromPlayerInfo: info) else {
            Issue.record("pause must not clear the island")
            return
        }
        #expect(snapshot.isPlaying == false)
        #expect(snapshot.title == "Alone")
    }

    @Test("stopped clears")
    func stoppedClears() {
        var info = Self.musicUserInfo()
        info["Player State"] = "Stopped"
        #expect(NowPlayingPlayer.music.update(fromPlayerInfo: info) == .cleared)
    }

    /// Another process's dictionary. Every read is a conditional cast because Isleta does not get to
    /// assume a third-party app posts what it posted last release.
    ///
    /// Written as a loop rather than as `@Test(arguments:)` because the cases are
    /// `[AnyHashable: Any]` and parameterised arguments must be `Sendable`. Wrapping them in a
    /// `Sendable` box to satisfy that would be dressing up the untyped payload as something safer
    /// than it is, which is the opposite of what this test is about.
    @Test("a payload with missing or wrongly typed fields clears rather than crashing")
    func hostileUserInfo() {
        let cleared: [[AnyHashable: Any]] = [
            [:],
            ["Player State": "Playing"],
            ["Player State": "Playing", "Name": 42],
            ["Name": ""],
        ]
        for info in cleared {
            #expect(NowPlayingPlayer.music.update(fromPlayerInfo: info) == .cleared)
        }

        // A usable name with a non-string state: not "Playing", so it must read as paused rather
        // than being assumed to be playing.
        let update = NowPlayingPlayer.music.update(fromPlayerInfo: ["Player State": 7, "Name": "Alone"])
        guard case .snapshot(let snapshot) = update else {
            Issue.record("a usable title should still produce a snapshot")
            return
        }
        #expect(snapshot.title == "Alone")
        #expect(snapshot.isPlaying == false)
    }

    /// Music posts every event under both its own name and iTunes'. Observing both is correct — an
    /// older system may only send one — so the duplication has to be absorbed downstream.
    @Test("Music is observed under both its own name and iTunes'")
    func musicPostsTwice() {
        #expect(NowPlayingPlayer.music.notificationNames.count == 2)
        #expect(NowPlayingPlayer.music.notificationNames.contains("com.apple.Music.playerInfo"))
        #expect(NowPlayingPlayer.music.notificationNames.contains("com.apple.iTunes.playerInfo"))
    }

    /// U+001F rather than a newline, because a newline in a track title does not garble the output —
    /// it shifts the field count, so the album is read as the artist and the island states something
    /// false with complete confidence.
    @Test("script output is split on the unit separator")
    func scriptOutputParses() {
        let output = ["playing", "Alone", "Prznt", "Alone - Single"].joined(separator: "\u{1F}")
        #expect(
            NowPlayingPlayer.music.update(fromScriptOutput: output)
                == .snapshot(
                    NowPlayingSnapshot(
                        title: "Alone",
                        artist: "Prznt",
                        album: "Alone - Single",
                        isPlaying: true,
                        bundleIdentifier: "com.apple.Music",
                        // Derived from the three strings the user can see, because this route
                        // reports no `contentItemIdentifier`. It is the artwork *cache key*, and
                        // this route never fetches artwork — but a snapshot that carried one only
                        // sometimes would be two shapes of the same type.
                        artworkIdentity: "Alone\u{1F}Prznt\u{1F}Alone - Single"
                    )
                )
        )
    }

    @Test("script output for a stopped player clears")
    func scriptOutputStopped() {
        #expect(NowPlayingPlayer.music.update(fromScriptOutput: "stopped\n") == .cleared)
    }

    @Test(
        "truncated or garbled script output clears rather than mis-assigning fields",
        arguments: ["", "playing", "playing\u{1F}Alone", "playing\u{1F}a\u{1F}b\u{1F}c\u{1F}d"]
    )
    func scriptOutputGarbled(output: String) {
        #expect(NowPlayingPlayer.music.update(fromScriptOutput: output) == .cleared)
    }

    /// The script must never be the thing that opens a music app on a silent machine. The guard is
    /// in `NowPlayingScriptEnvironment.isRunning`, but the script itself also has to survive being
    /// run against a player with nothing loaded, where `current track` raises.
    @Test("the script guards against a stopped player before touching current track")
    func scriptGuardsCurrentTrack() {
        let script = NowPlayingPlayer.music.currentTrackScript
        #expect(script.contains("if player state is stopped then return \"stopped\""))
        #expect(script.contains("tell application \"Music\""))
    }
}

@Suite("Now Playing — which player owns the island")
struct NowPlayingScriptStateTests {

    private static func snapshot(
        _ title: String,
        playing: Bool = true,
        from bundleIdentifier: String = "com.apple.Music"
    ) -> NowPlayingUpdate {
        .snapshot(
            NowPlayingSnapshot(title: title, isPlaying: playing, bundleIdentifier: bundleIdentifier)
        )
    }

    /// The direct consequence of Music double-posting. Without this every track change publishes
    /// twice and §6.2's `contentSwap` crossfade runs on content that did not change.
    @Test("the same event arriving twice publishes once")
    func duplicateSuppressed() {
        var state = NowPlayingScriptState()
        #expect(state.ingest(Self.snapshot("Alone"), from: "com.apple.Music") != nil)
        #expect(state.ingest(Self.snapshot("Alone"), from: "com.apple.Music") == nil)
    }

    @Test("a pause of the same track still gets through")
    func pauseOfSameTrackPublishes() {
        var state = NowPlayingScriptState()
        _ = state.ingest(Self.snapshot("Alone"), from: "com.apple.Music")
        // The words are identical and the glyph is not, so this is a real change.
        #expect(state.ingest(Self.snapshot("Alone", playing: false), from: "com.apple.Music") != nil)
    }

    @Test("a playing player takes the stage from a paused one")
    func playingTakesStage() {
        var state = NowPlayingScriptState()
        _ = state.ingest(Self.snapshot("Alone", playing: false), from: "com.apple.Music")
        #expect(state.ingest(Self.snapshot("Other"), from: "com.spotify.client") != nil)
        #expect(state.owner == "com.spotify.client")
    }

    /// "Last event wins" is the naive rule and this is the case that breaks it: pausing Spotify in
    /// the background would replace the Music track the user is actually listening to.
    @Test("a paused background player does not displace a playing one")
    func pausedForeignPlayerIgnored() {
        var state = NowPlayingScriptState()
        _ = state.ingest(Self.snapshot("Alone"), from: "com.apple.Music")
        #expect(state.ingest(Self.snapshot("Other", playing: false), from: "com.spotify.client") == nil)
        #expect(state.owner == "com.apple.Music")
    }

    @Test("only the player holding the stage may clear it")
    func foreignClearIgnored() {
        var state = NowPlayingScriptState()
        _ = state.ingest(Self.snapshot("Alone"), from: "com.apple.Music")
        #expect(state.ingest(.cleared, from: "com.spotify.client") == nil)
        #expect(state.owner == "com.apple.Music")
        #expect(state.ingest(.cleared, from: "com.apple.Music") == .cleared)
        #expect(state.owner == nil)
    }

    /// Quitting a player posts no final `playerInfo` — the process is gone before it would have — so
    /// the workspace notification is the only thing that ever says so. Without it the track stays
    /// pinned to the island until something unrelated happens to arrive.
    @Test("a player that quits mid-track clears the island")
    func playerQuitsMidTrack() {
        var state = NowPlayingScriptState()
        _ = state.ingest(Self.snapshot("Alone"), from: "com.apple.Music")
        #expect(state.playerDidQuit("com.apple.Music") == .cleared)
        #expect(state.owner == nil)
        // And a second quit notification for the same app is not a second dismissal.
        #expect(state.playerDidQuit("com.apple.Music") == nil)
    }

    @Test("an unrelated app quitting changes nothing")
    func unrelatedQuitIgnored() {
        var state = NowPlayingScriptState()
        _ = state.ingest(Self.snapshot("Alone"), from: "com.apple.Music")
        #expect(state.playerDidQuit("com.apple.Safari") == nil)
        #expect(state.owner == "com.apple.Music")
    }

    @Test("after a clear the same track is news again")
    func clearResetsDeduplication() {
        var state = NowPlayingScriptState()
        _ = state.ingest(Self.snapshot("Alone"), from: "com.apple.Music")
        _ = state.ingest(.cleared, from: "com.apple.Music")
        #expect(state.ingest(Self.snapshot("Alone"), from: "com.apple.Music") != nil)
    }
}

@Suite("Now Playing — scripting provider")
@MainActor
struct NowPlayingScriptProviderTests {

    /// A private center, never the real distributed one. Posting a fake `com.apple.Music.playerInfo`
    /// system-wide would broadcast to every other app on the machine that listens for it.
    private static func makeProvider(
        environment: FakeScriptEnvironment,
        center: NotificationCenter,
        workspace: NotificationCenter
    ) -> NowPlayingScriptProvider {
        NowPlayingScriptProvider(
            players: [.music, .spotify],
            environment: environment,
            distributedCenter: center,
            workspaceCenter: workspace
        )
    }

    private static func post(
        _ center: NotificationCenter,
        name: String,
        state: String = "Playing",
        title: String = "Alone"
    ) {
        center.post(
            name: Notification.Name(name),
            object: nil,
            userInfo: [
                "Player State": state,
                "Name": title,
                "Artist": "Prznt",
                "Album": "Alone - Single",
            ]
        )
    }

    // MARK: - The denied state (§10)

    /// The heart of the denied-state requirement, and the reason this route is worth having at all.
    /// With Automation refused, the initial read is skipped — no `osascript`, no prompt, no error —
    /// and the *live* half keeps working, because a distributed notification is a broadcast that
    /// nobody has to be permitted to hear.
    @Test("with Automation denied, live updates still arrive")
    func deniedAutomationStillStreams() async {
        let environment = FakeScriptEnvironment()
        environment.running = ["com.apple.Music"]
        environment.statuses = ["com.apple.Music": .denied(explanation: "no")]
        environment.currentTrack = ["com.apple.Music": .snapshot(.init(title: "Should not appear", isPlaying: true))]

        let center = NotificationCenter()
        let provider = Self.makeProvider(
            environment: environment,
            center: center,
            workspace: NotificationCenter()
        )
        let recorder = NowPlayingRecorder()
        provider.onUpdate = { recorder.record($0) }

        provider.start()
        defer { provider.stop() }

        await recorder.settle()
        #expect(recorder.updates.isEmpty, "a refused permission must not yield a track anyway")

        Self.post(center, name: "com.apple.Music.playerInfo")
        #expect(await recorder.wait(forAtLeast: 1))
        #expect(recorder.titles == ["Alone"])
    }

    /// `.notRequired`, not `.denied`. `SourceAuthorization.isUsable` is false for `.denied`, so
    /// reporting the Automation refusal here would invite a caller to skip a source that works —
    /// trading the whole feature for the tenth of it the permission actually governs.
    @Test("a refused permission does not make the route unusable")
    func authorizationStaysUsable() {
        let environment = FakeScriptEnvironment()
        environment.running = ["com.apple.Music"]
        environment.statuses = ["com.apple.Music": .denied(explanation: "refused")]

        let provider = Self.makeProvider(
            environment: environment,
            center: NotificationCenter(),
            workspace: NotificationCenter()
        )
        #expect(provider.authorization == .notRequired)
        #expect(provider.authorization.isUsable)

        // …and the refusal is still reportable, so IslandSettings has something to explain.
        guard case .denied(let explanation) = provider.initialReadAuthorization else {
            Issue.record("expected the refusal to be visible separately")
            return
        }
        #expect(!explanation.isEmpty)
    }

    /// §10: the prompt belongs to a moment the user initiated, so an undecided permission is
    /// reported as undecided and nothing is asked at launch.
    @Test("an undetermined permission is reported, not acted on")
    func undeterminedIsReportedNotPrompted() async {
        let environment = FakeScriptEnvironment()
        environment.running = ["com.apple.Music"]
        environment.statuses = ["com.apple.Music": .undetermined]

        let provider = Self.makeProvider(
            environment: environment,
            center: NotificationCenter(),
            workspace: NotificationCenter()
        )
        #expect(provider.initialReadAuthorization == .undetermined)

        provider.start()
        defer { provider.stop() }
        await Task.yield()
        // The read was attempted and refused itself; what matters is that nothing was published from
        // a permission that was never granted.
        #expect(environment.readCount <= 1)
    }

    /// No nagging: a permission for an app the user does not have open is not something to mention.
    @Test("with no player running there is nothing to ask for")
    func nothingRunningNeedsNothing() {
        let provider = Self.makeProvider(
            environment: FakeScriptEnvironment(),
            center: NotificationCenter(),
            workspace: NotificationCenter()
        )
        #expect(provider.initialReadAuthorization == .notRequired)
    }

    // MARK: - Granted

    @Test("with Automation granted the current track appears without waiting for a change")
    func grantedReadsInitialState() async {
        let environment = FakeScriptEnvironment()
        environment.running = ["com.apple.Music"]
        environment.statuses = ["com.apple.Music": .granted]
        environment.currentTrack = [
            "com.apple.Music": .snapshot(
                .init(title: "Alone", isPlaying: true, bundleIdentifier: "com.apple.Music")
            )
        ]

        let provider = Self.makeProvider(
            environment: environment,
            center: NotificationCenter(),
            workspace: NotificationCenter()
        )
        let recorder = NowPlayingRecorder()
        provider.onUpdate = { recorder.record($0) }

        provider.start()
        defer { provider.stop() }

        #expect(await recorder.wait(forAtLeast: 1))
        #expect(recorder.titles == ["Alone"])
    }

    /// The initial read must never launch a player that is not running — `tell application "Music"`
    /// is launch-on-demand, and doing this at login would open a music app on a user working in
    /// silence.
    @Test("a player that is not running is never scripted")
    func notRunningIsNeverScripted() async {
        let environment = FakeScriptEnvironment()
        environment.statuses = ["com.apple.Music": .granted]

        let provider = Self.makeProvider(
            environment: environment,
            center: NotificationCenter(),
            workspace: NotificationCenter()
        )
        provider.start()
        defer { provider.stop() }
        await Task.yield()

        #expect(environment.readCount == 0)
    }

    // MARK: - Live behavior

    /// End to end through the provider: Music's double post must reach the island once.
    @Test("Music posting under both names publishes one activity")
    func doublePostPublishesOnce() async {
        let environment = FakeScriptEnvironment()
        let center = NotificationCenter()
        let provider = Self.makeProvider(
            environment: environment,
            center: center,
            workspace: NotificationCenter()
        )
        let recorder = NowPlayingRecorder()
        provider.onUpdate = { recorder.record($0) }

        provider.start()
        defer { provider.stop() }

        Self.post(center, name: "com.apple.Music.playerInfo")
        Self.post(center, name: "com.apple.iTunes.playerInfo")

        #expect(await recorder.wait(forAtLeast: 1))
        await recorder.settle()
        #expect(recorder.updates.count == 1)
    }

    @Test("a player quitting mid-track clears the island")
    func quitClears() async {
        let environment = FakeScriptEnvironment()
        let center = NotificationCenter()
        let workspace = NotificationCenter()
        let provider = Self.makeProvider(environment: environment, center: center, workspace: workspace)
        let recorder = NowPlayingRecorder()
        provider.onUpdate = { recorder.record($0) }

        provider.start()
        defer { provider.stop() }

        Self.post(center, name: "com.apple.Music.playerInfo")
        #expect(await recorder.wait(forAtLeast: 1))

        // `NSWorkspace` reports the app that went away in `applicationUserInfoKey`. There is no way
        // to build an `NSRunningApplication` for a process that has quit, so this posts the shape
        // the provider reads rather than a real one — the parse is what is under test.
        workspace.post(
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            userInfo: [
                NSWorkspace.applicationUserInfoKey: NSRunningApplication.current
            ]
        )
        await recorder.settle()

        // The current process is not a player, so nothing should have been cleared by that.
        #expect(recorder.updates.count == 1)
    }

    /// The single most consequential thing `stop()` does here: the block-based observer API
    /// registers an opaque token rather than `self`, so a `removeObserver(self)` would remove
    /// nothing and the blocks would keep firing into a provider the app believes is shut down.
    @Test("after stop, notifications are ignored")
    func stopDetachesObservers() async {
        let center = NotificationCenter()
        let provider = Self.makeProvider(
            environment: FakeScriptEnvironment(),
            center: center,
            workspace: NotificationCenter()
        )
        let recorder = NowPlayingRecorder()
        provider.onUpdate = { recorder.record($0) }

        provider.start()
        provider.stop()

        Self.post(center, name: "com.apple.Music.playerInfo")
        await recorder.settle()
        #expect(recorder.updates.isEmpty)
    }

    @Test("start is idempotent — a second call does not double the observers")
    func startIsIdempotent() async {
        let center = NotificationCenter()
        let provider = Self.makeProvider(
            environment: FakeScriptEnvironment(),
            center: center,
            workspace: NotificationCenter()
        )
        let recorder = NowPlayingRecorder()
        provider.onUpdate = { recorder.record($0) }

        provider.start()
        provider.start()
        defer { provider.stop() }

        Self.post(center, name: "com.apple.Music.playerInfo")
        #expect(await recorder.wait(forAtLeast: 1))
        await recorder.settle()
        #expect(recorder.updates.count == 1)
    }

    @Test("stop then start works again")
    func restartWorks() async {
        let center = NotificationCenter()
        let provider = Self.makeProvider(
            environment: FakeScriptEnvironment(),
            center: center,
            workspace: NotificationCenter()
        )
        let recorder = NowPlayingRecorder()
        provider.onUpdate = { recorder.record($0) }

        provider.start()
        provider.stop()
        provider.start()
        defer { provider.stop() }

        Self.post(center, name: "com.apple.Music.playerInfo")
        #expect(await recorder.wait(forAtLeast: 1))
    }
}

// MARK: - Music's own Favorite, and revealing the track

/// The two things MediaRemote cannot do for Music, and the permission both of them cost.
///
/// Neither is a property of the Now Playing *route*: the adapter reads and controls playback with no
/// permission at all, and these ask the *application* a question it will only answer with an
/// Automation grant.
@MainActor
@Suite("Music Favorite and reveal")
struct MusicFavoriteScriptTests {

    private func environment(granted: Bool = true, running: Bool = true) -> FakeScriptEnvironment {
        let environment = FakeScriptEnvironment()
        if running { environment.running = [NowPlayingPlayer.music.bundleIdentifier] }
        environment.statuses[NowPlayingPlayer.music.bundleIdentifier] = granted ? .granted : .denied(explanation: "no")
        return environment
    }

    /// Music has a Favorite of its own; Spotify has none. Measured from the two dictionaries rather
    /// than assumed — `sdef` on Spotify carries no `favorited`, `loved`, `starred` or `saved`.
    @Test("only a player with a favorite of its own offers one")
    func onlyMusicSupportsFavorite() {
        #expect(NowPlayingPlayer.music.supportsFavorite)
        #expect(!NowPlayingPlayer.spotify.supportsFavorite)
        #expect(NowPlayingPlayer.spotify.favoriteReadScript == nil)
        #expect(NowPlayingPlayer.spotify.favoriteWriteScript(true) == nil)
        #expect(NowPlayingPlayer.spotify.revealCurrentTrackScript == nil)
    }

    /// **A correction, kept because the wrong version shipped a dimmed star.** This suite briefly
    /// asserted that a `URL track` — anything Apple Music streams rather than holds in the library —
    /// could be read but not written, on the strength of a write whose read-back reported the old
    /// value. The write is **asynchronous**: at 0.4s it reports the old value and at 2s the new one,
    /// so the measurement was a race with itself. There is no class gate, and building one kept the
    /// star dimmed for every track the owner actually plays.
    @Test("every track Music reports a state for can be written")
    func everyTrackIsWritable() {
        #expect(NowPlayingPlayer.music.favorite(fromScriptOutput: "true") == true)
        #expect(NowPlayingPlayer.music.favorite(fromScriptOutput: "false") == false)
        // The write script carries the settle *inside* it, which is what makes one fork enough —
        // and it **polls** rather than sleeping a fixed amount. A fixed `delay 2` was measured as
        // sufficient and then observed failing on a first click: the write landed, the read at two
        // seconds still said `false`, and the star was put back out over a track Music had in fact
        // favorited. The second click appeared to work, which is what a timing bug looks like.
        let write = NowPlayingPlayer.music.favoriteWriteScript(true)
        #expect(write?.contains("repeat 10 times") == true, "the read-back must outwait Music, not guess")
        #expect(write?.contains("exit repeat") == true, "and stop the moment it agrees")
        #expect(write?.contains("return answer as text") == true)
    }

    @Test("a stopped player answers nothing rather than false")
    func stoppedAnswersNothing() {
        #expect(NowPlayingPlayer.music.favorite(fromScriptOutput: "unknown") == nil)
        #expect(NowPlayingPlayer.music.favorite(fromScriptOutput: "") == nil)
        #expect(NowPlayingPlayer.music.favorite(fromScriptOutput: "yes please") == nil)
    }

    /// §10, and the reason `automationStatus` is asked before every script: a refused permission
    /// sends nothing at all rather than forking `osascript` for an error.
    @Test("a refused Automation grant reads nothing and writes nothing")
    func refusedPermissionIsSilent() async {
        let environment = environment(granted: false)
        environment.favorites[NowPlayingPlayer.music.bundleIdentifier] = false

        var read: Bool??
        environment.readFavorite(from: .music) { read = $0 }
        #expect(read ?? nil == nil)

        environment.setFavorite(true, on: .music) { _ in }
        #expect(environment.favoriteWrites.isEmpty, "a refusal must not reach the player")

        environment.revealCurrentTrack(in: .music)
        #expect(environment.reveals.isEmpty)
    }

    /// **An undetermined grant must still reveal, because sending the event is what asks.**
    ///
    /// This is the regression guard for a bug that shipped twice in the same file. Automation starts
    /// `.undetermined` and only moves when something sends an Apple event; macOS raises its prompt
    /// on that send. A reveal gated on `.granted` therefore never asks, never gets granted, and
    /// never reveals — so every click on a song opened Music at whatever it was last showing, and
    /// the feature looked implemented and was dead. The star had the identical bug before it.
    ///
    /// A click on a song is exactly the user-initiated moment §10 says a prompt belongs to.
    @Test("a click reveals while the grant is still undetermined, because the ask is the prompt")
    func undeterminedStillReveals() {
        let environment = FakeScriptEnvironment()
        environment.running = [NowPlayingPlayer.music.bundleIdentifier]
        environment.statuses[NowPlayingPlayer.music.bundleIdentifier] = .undetermined

        environment.revealCurrentTrack(in: .music)
        #expect(environment.reveals == [NowPlayingPlayer.music.bundleIdentifier])
    }

    /// The same guard for a player that is not running — `tell application "Music"` **launches
    /// Music**, which is the trap the whole environment is shaped around.
    @Test("a player that is not running is never told anything")
    func notRunningIsNeverAsked() {
        let environment = environment(running: false)
        environment.favorites[NowPlayingPlayer.music.bundleIdentifier] = true

        var read: Bool??
        environment.readFavorite(from: .music) { read = $0 }
        #expect(read ?? nil == nil)
        environment.revealCurrentTrack(in: .music)
        #expect(environment.reveals.isEmpty)
    }

    /// A write is followed by a read-back in the *same* script, and what comes back is what the
    /// island adopts rather than what was asked for.
    @Test("a write reports the state the player settled on")
    func writeReportsTheSettledState() {
        let environment = environment()
        environment.favorites[NowPlayingPlayer.music.bundleIdentifier] = false

        var answer: Bool?
        environment.setFavorite(true, on: .music) { answer = $0 }
        #expect(environment.favoriteWrites == [true])
        #expect(answer == true)
    }
}

/// Asking for Automation, which is the one permission in Isleta that can need two dialogs for one
/// button — it is granted per target application, and a user can be running both players.
///
/// Every case here is about *when a dialog goes up*, because that is what §10 governs and what the
/// first-run flow's Continue is now wired to. `FakeScriptEnvironment.automationPromptCount` is the
/// only assertion that matters in most of them.
@Suite("Now Playing — asking for Automation")
@MainActor
struct NowPlayingAutomationRequestTests {

    private func make(
        running: Set<String>,
        statuses: [String: SourceAuthorization] = [:],
        answers: [String: SourceAuthorization] = [:]
    ) -> (NowPlayingScriptProvider, FakeScriptEnvironment) {
        let environment = FakeScriptEnvironment()
        environment.running = running
        environment.statuses = statuses
        environment.automationAnswer = answers
        return (NowPlayingScriptProvider(environment: environment), environment)
    }

    /// The plain case, and the one the Music page is drawn for.
    @Test("one running player that has never been asked gets one dialog")
    func asksOnce() {
        let (provider, environment) = make(
            running: [NowPlayingPlayer.music.bundleIdentifier],
            answers: [NowPlayingPlayer.music.bundleIdentifier: .granted]
        )
        var answer: SourceAuthorization?
        provider.requestAutomationFromUserInitiatedMoment { answer = $0 }
        #expect(environment.automationPromptCount == 1)
        #expect(answer == .granted)
    }

    /// **The reason this is a chain and not a loop.** Two dialogs stacked on each other read as the
    /// app having asked twice for the same thing; asked in sequence they read as two questions,
    /// which is what they are.
    @Test("two running players get one dialog each, in order")
    func asksEachRunningPlayer() {
        let (provider, environment) = make(
            running: [NowPlayingPlayer.music.bundleIdentifier, NowPlayingPlayer.spotify.bundleIdentifier],
            answers: [
                NowPlayingPlayer.music.bundleIdentifier: .granted,
                NowPlayingPlayer.spotify.bundleIdentifier: .granted
            ]
        )
        provider.requestAutomationFromUserInitiatedMoment { _ in }
        #expect(environment.automationPromptCount == 2)
    }

    /// A permission for an app the user does not have open is a dialog about nothing, and
    /// `AEDeterminePermissionToAutomateTarget` answers `procNotFound` for it anyway. `.notRequired`
    /// is the honest report — the flow reads it as "nothing to do here" and Continue advances.
    @Test("a player that is not running is never asked about")
    func skipsQuitPlayers() {
        let (provider, environment) = make(running: [])
        var answer: SourceAuthorization?
        provider.requestAutomationFromUserInitiatedMoment { answer = $0 }
        #expect(environment.automationPromptCount == 0)
        #expect(answer == .notRequired)
    }

    /// The dead end. TCC holds an answer, so the call returns it with no dialog — which is why the
    /// flow's page offers System Settings here instead of a second ask.
    @Test("a refusal is not asked about again")
    func refusalIsNotReasked() {
        let identifier = NowPlayingPlayer.music.bundleIdentifier
        let (provider, environment) = make(
            running: [identifier],
            statuses: [identifier: .denied(explanation: "refused")]
        )
        var answer: SourceAuthorization?
        provider.requestAutomationFromUserInitiatedMoment { answer = $0 }
        #expect(environment.automationPromptCount == 0)
        if case .denied = answer {} else { Issue.record("expected the refusal to survive, got \(String(describing: answer))") }
    }

    @Test("a permission already granted raises nothing")
    func grantedIsNotReasked() {
        let identifier = NowPlayingPlayer.music.bundleIdentifier
        let (provider, environment) = make(running: [identifier], statuses: [identifier: .granted])
        var answer: SourceAuthorization?
        provider.requestAutomationFromUserInitiatedMoment { answer = $0 }
        #expect(environment.automationPromptCount == 0)
        #expect(answer == .granted)
    }

    /// **The state the first-run flow exists to handle**, and the one the owner asked for: the user
    /// closed the dialog without answering. TCC still holds nothing, so the answer is `.undetermined`
    /// — the page stays put and offers again rather than advancing on a press that changed nothing.
    @Test("a dialog dismissed without an answer leaves it undetermined")
    func dismissedDialogStaysUndetermined() {
        let identifier = NowPlayingPlayer.music.bundleIdentifier
        // No entry in `automationAnswer`: the prompt goes up and the stored status does not move,
        // which is exactly what a dismissed dialog does.
        let (provider, environment) = make(running: [identifier])
        var answer: SourceAuthorization?
        provider.requestAutomationFromUserInitiatedMoment { answer = $0 }
        #expect(environment.automationPromptCount == 1)
        #expect(answer == .undetermined)
    }
}
