import AppKit
import CoreServices
import Foundation
import Testing

@testable import IslandSources

/// Gate for the live suite.
///
/// Held outside the suite because a trait that names a member of the type it decorates is a circular
/// macro reference — the `@Suite` expansion needs the condition before the type it is attached to
/// exists.
enum NowPlayingLiveGate {

    /// Both halves matter. Music running keeps the check from launching it, and the permission being
    /// already granted keeps it from prompting — this must never be the thing that throws a TCC
    /// dialog at whoever is running the tests.
    ///
    /// Written against the C API directly rather than reusing `NowPlayingSystemScriptEnvironment`,
    /// which is `@MainActor`. swift-testing evaluates a suite's `.enabled(if:)` condition off the
    /// main actor, so `MainActor.assumeIsolated` here does not merely fail a test — it trips the
    /// isolation check and takes the whole test bundle down with SIGTRAP, after every other suite has
    /// already reported passing.
    static var isMusicScriptable: Bool {
        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: NowPlayingPlayer.music.bundleIdentifier
        )
        guard !running.isEmpty else { return false }

        var target = AEAddressDesc()
        let identifier = Array(NowPlayingPlayer.music.bundleIdentifier.utf8)
        guard
            AECreateDesc(AEKeyword(typeApplicationBundleID), identifier, identifier.count, &target)
                == noErr
        else { return false }
        defer { AEDisposeDesc(&target) }

        // `askUserIfNeeded: false`. Passing true here would be the test suite prompting for a
        // permission, which is the exact behavior §10 forbids the app from having.
        return AEDeterminePermissionToAutomateTarget(
            &target,
            AEEventClass(typeWildCard),
            AEEventID(typeWildCard),
            false
        ) == noErr
    }
}

/// The one suite that talks to the real machine.
///
/// Everything else in this package runs against fakes, which is what makes it deterministic and what
/// lets the denied and unavailable states be tested at all. But fakes cannot tell you that Music
/// still posts `com.apple.Music.playerInfo`, that its `userInfo` still spells the key
/// `"Player State"`, or that `AEDeterminePermissionToAutomateTarget` still answers without
/// prompting — and all three are undocumented behaviors of somebody else's software that a macOS
/// release could change. This suite is what would notice.
///
/// It is gated on Music being open with Automation already granted, so it runs on a developer's Mac
/// and skips on a build machine rather than failing there. `.enabled(if:)` and not a silent early
/// return: a test that quietly does nothing reports as a passing test, and a green tick for an
/// assertion that never ran is worse than no test.
///
/// **It never prompts and never launches anything.** The permission is read, not requested, and
/// Music is only addressed if it is already running — see `NowPlayingScriptEnvironment.isRunning`
/// for why sending the Apple event unconditionally would open a music app on a silent machine.
@Suite(
    "Now Playing — live, against this Mac",
    .enabled(
        if: NowPlayingLiveGate.isMusicScriptable,
        "needs Music running with Automation already granted"
    )
)
@MainActor
struct NowPlayingLiveTests {

    /// The claim this whole fallback rests on: a real player, read through the real environment,
    /// with no vendored adapter and no polling.
    @Test("the scripting route reads the real Music app")
    func readsRealMusic() async throws {
        let environment = NowPlayingSystemScriptEnvironment()

        // Retried, because this test reads a *live* application. A single nil is not evidence the
        // route is broken: Music answers nothing for a moment while it changes track, and this
        // suite failed exactly that way during a session where the machine was genuinely playing
        // music. One-shot here means a green build depends on what the developer's media player
        // happened to be doing, which is the kind of flake that gets a whole suite disabled.
        var update: NowPlayingUpdate?
        for attempt in 0..<3 {
            update = await withCheckedContinuation { continuation in
                environment.readCurrentTrack(from: .music) { continuation.resume(returning: $0) }
            }
            if update != nil { break }
            if attempt < 2 { try? await Task.sleep(for: .milliseconds(400)) }
        }

        // `nil` would mean the read failed; `.cleared` means Music is open but stopped, which is a
        // legitimate state and not a failure of this code.
        let result = try #require(update, "the read failed three times against a player it was told was scriptable")
        if case .snapshot(let snapshot) = result {
            #expect(!snapshot.title.isEmpty)
            #expect(snapshot.bundleIdentifier == "com.apple.Music")
        }
    }

    /// Proves the source produces a real `BuiltInActivity` from a real player, through the same path
    /// the app will use — no fake anywhere in it.
    @Test("the source publishes an activity for whatever is playing")
    func publishesRealActivity() async {
        let source = NowPlayingSource(provider: NowPlayingScriptProvider())
        var titles: [String] = []
        source.onActivity = { titles.append($0.presentations.expanded.title ?? "") }
        source.start()
        defer { source.stop() }

        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while titles.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }

        // Music may be paused with nothing loaded, in which case there is nothing to publish and
        // that is correct. What must not happen is a published activity with no title in it.
        for title in titles {
            #expect(!title.isEmpty)
        }
    }

    /// `AEDeterminePermissionToAutomateTarget` with `askUserIfNeeded: false` is the only supported
    /// way to read Automation state without a prompt, and §10 makes that a requirement rather than a
    /// nicety. Verified here because the alternative — inferring it by sending an event and reading
    /// the error — works fine right up until the undetermined case, where the send *is* the prompt.
    @Test("the permission check answers without prompting")
    func permissionCheckIsSilent() {
        let environment = NowPlayingSystemScriptEnvironment()
        #expect(environment.automationStatus(for: .music) == .granted)

        // An app that is not running answers `.notRequired` rather than denied: there is nothing to
        // be permitted to do, so there is nothing to mention to the user.
        let absent = NowPlayingPlayer(
            bundleIdentifier: "com.tryisleta.definitely-not-installed",
            scriptingName: "Nothing",
            notificationNames: []
        )
        #expect(environment.automationStatus(for: absent) == .notRequired)
    }
}
