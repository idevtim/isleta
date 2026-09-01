import Foundation
import IslandActivities

@testable import IslandSources

/// Collects what a provider or source published, and lets a test wait for it.
///
/// Both real routes publish through `DispatchQueue.main.async` — deliberately, because the main
/// queue is FIFO and a diff stream applied out of order is wrong (see `NowPlayingAdapterProvider`).
/// That makes every end-to-end assertion here asynchronous, so the choice is between waiting for a
/// count and sprinkling fixed sleeps. A fixed sleep is either flaky or slow and usually both.
///
/// The wait loop polls, which is forbidden in the product by §9 and completely fine here: a test
/// harness has no idle path, and `Task.sleep` is what yields the main actor so the queued blocks it
/// is waiting for can actually run.
@MainActor
final class NowPlayingRecorder {

    private(set) var updates: [NowPlayingUpdate] = []

    func record(_ update: NowPlayingUpdate) {
        updates.append(update)
    }

    var snapshots: [NowPlayingSnapshot] {
        updates.compactMap { if case .snapshot(let snapshot) = $0 { snapshot } else { nil } }
    }

    var titles: [String] { snapshots.map(\.title) }

    /// Waits for at least `count` updates. Returns false on timeout so the caller can `#expect` it
    /// and get a named failure rather than a hung suite.
    @discardableResult
    func wait(forAtLeast count: Int, timeout: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while updates.count < count {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    /// Waits for an update that satisfies `condition`, rather than for a number of them.
    ///
    /// **A count is the wrong thing to wait on whenever the test cares about a particular update**,
    /// and `fatalExitRetiresRoute` is where that bit: it waited for two updates and then asserted
    /// that the *last* was `.cleared`. Two updates is not the same claim — a helper is entitled to
    /// publish more than one snapshot before it dies, and on a loaded machine it sometimes does, so
    /// the wait returned with the clear still in flight and the assertion read a snapshot. It failed
    /// perhaps one run in ten, which is the worst rate: often enough to erode trust in the suite,
    /// rarely enough to be dismissed as a fluke.
    ///
    /// Waiting for the condition removes the race rather than widening the window on it — there is
    /// no sleep long enough to make a count-based wait correct, only long enough to make it slow.
    @discardableResult
    func wait(
        forUpdateMatching condition: @escaping (NowPlayingUpdate) -> Bool,
        timeout: Duration = .seconds(10)
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !updates.contains(where: condition) {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    /// Yields the main actor a few times so anything already queued can run, without waiting for a
    /// particular outcome. Used to assert that nothing *was* published — the only assertion that
    /// cannot be made by waiting for a count.
    func settle(rounds: Int = 20) async {
        for _ in 0..<rounds {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// A provider whose behavior the test dictates. Stands in for all three real ones in the
/// `NowPlayingSource` suite, which is about identity and dismissal rather than about processes.
@MainActor
final class FakeNowPlayingProvider: NowPlayingProvider {

    static let providerName = "Fake"

    var authorization: SourceAuthorization = .notRequired
    var onUpdate: ((NowPlayingUpdate) -> Void)?

    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() { startCount += 1 }
    func stop() { stopCount += 1 }

    /// Publishes synchronously. The hop to the main actor belongs to the real providers; adding one
    /// here would test `DispatchQueue`, not `NowPlayingSource`.
    func emit(_ update: NowPlayingUpdate) { onUpdate?(update) }
}

/// A scripted stand-in for the machine: which players are running, what the Automation permission
/// says, and what the one-shot read returns.
@MainActor
final class FakeScriptEnvironment: NowPlayingScriptEnvironment {

    var running: Set<String> = []
    var statuses: [String: SourceAuthorization] = [:]
    var currentTrack: [String: NowPlayingUpdate] = [:]

    private(set) var readCount = 0

    func isRunning(_ player: NowPlayingPlayer) -> Bool {
        running.contains(player.bundleIdentifier)
    }

    func automationStatus(for player: NowPlayingPlayer) -> SourceAuthorization {
        statuses[player.bundleIdentifier] ?? .undetermined
    }

    /// What the user is scripted to answer when the dialog goes up, and how many times it went up.
    ///
    /// Nil means they left it alone — which is a real state rather than a gap in the fake, and the
    /// one the first-run flow has to handle without advancing: the dialog was dismissed, TCC still
    /// holds no answer, and the honest next move is to offer again.
    var automationAnswer: [String: SourceAuthorization] = [:]
    private(set) var automationPromptCount = 0

    func requestAutomation(
        for player: NowPlayingPlayer,
        completion: @escaping @MainActor (SourceAuthorization) -> Void
    ) {
        // The real one's first guard, mirrored for the same reason the read's two are: a player
        // that is not running, or a permission already decided, raises no dialog at all. A fake
        // that counted a prompt in those cases would let a test assert Isleta asks where it does
        // not.
        let current = automationStatus(for: player)
        guard current == .undetermined else {
            completion(current)
            return
        }
        automationPromptCount += 1
        if let answer = automationAnswer[player.bundleIdentifier] {
            statuses[player.bundleIdentifier] = answer
        }
        completion(automationStatus(for: player))
    }

    func readCurrentTrack(
        from player: NowPlayingPlayer,
        completion: @escaping @MainActor (NowPlayingUpdate?) -> Void
    ) {
        readCount += 1
        // Mirrors the real environment's two guards exactly: a refused or undecided permission
        // yields no answer rather than an error, and the caller must not treat that as "nothing is
        // playing". A fake that answered anyway would let the denied-state tests pass against a
        // provider that ignores the permission entirely.
        guard isRunning(player), automationStatus(for: player) == .granted else {
            completion(nil)
            return
        }
        completion(currentTrack[player.bundleIdentifier])
    }

    // MARK: - Favorite, and revealing

    /// What the player would report for the playing track, keyed by bundle identifier.
    var favorites: [String: Bool] = [:]

    /// Writes the fake accepted, in order — so a test can assert that a refused permission sent
    /// nothing rather than merely that nothing came back.
    private(set) var favoriteWrites: [Bool] = []
    private(set) var reveals: [String] = []

    func readFavorite(
        from player: NowPlayingPlayer,
        completion: @escaping @MainActor (Bool?) -> Void
    ) {
        guard canScript(player), player.supportsFavorite else {
            completion(nil)
            return
        }
        completion(favorites[player.bundleIdentifier])
    }

    func setFavorite(
        _ favorite: Bool,
        on player: NowPlayingPlayer,
        completion: @escaping @MainActor (Bool?) -> Void
    ) {
        guard canScript(player), player.supportsFavorite else {
            completion(nil)
            return
        }
        favoriteWrites.append(favorite)
        // The real environment reads back inside the same script, because `set favorited` returns
        // before Music agrees — so the fake answers with the settled value too.
        favorites[player.bundleIdentifier] = favorite
        completion(favorite)
    }

    func revealCurrentTrack(in player: NowPlayingPlayer) {
        // **Mirrors the real environment's `allowingPrompt: true`.** A reveal is a click, so it is
        // permitted while Automation is undetermined — sending the event is what raises the prompt.
        // The fake said `.granted` only, which made it agree with the bug rather than with the
        // intent, and a test written against it would have passed on the broken build.
        guard isRunning(player), player.supportsFavorite else { return }
        if case .denied = automationStatus(for: player) { return }
        reveals.append(player.bundleIdentifier)
    }

    /// The two guards the real environment applies before every script.
    private func canScript(_ player: NowPlayingPlayer) -> Bool {
        isRunning(player) && automationStatus(for: player) == .granted
    }
}

/// Builds a stub helper that speaks the adapter's documented line protocol.
///
/// `/bin/sh` rather than a compiled fixture so the test needs no build phase, and `exec sleep`
/// rather than a shell loop for a specific reason: `exec` replaces the shell, so the process
/// `NowPlayingAdapterReader` is tracking is the one that has to die. A `while :; do sleep 1; done`
/// loop would leave the shell as the tracked process and `sleep` as an orphaned grandchild, and the
/// teardown test would pass while leaking exactly the thing it exists to catch.
enum NowPlayingStubHelper {

    static let executable = URL(fileURLWithPath: "/bin/sh")

    /// Emits `lines`, then blocks until signalled.
    static func arguments(emitting lines: [String], thenSleep seconds: Int = 60) -> [String] {
        let prints = lines.map { "printf '%s\\n' \($0.shellQuoted)" }.joined(separator: "\n")
        return ["-c", "\(prints)\nexec sleep \(seconds)"]
    }

    /// Emits `lines`, then exits with `status`. Models the adapter dying on its own, which its
    /// README documents as a state you must not relaunch from.
    static func arguments(emitting lines: [String], thenExit status: Int) -> [String] {
        let prints = lines.map { "printf '%s\\n' \($0.shellQuoted)" }.joined(separator: "\n")
        return ["-c", "\(prints)\nexit \(status)"]
    }
}

private extension String {
    /// Single-quoted for `sh`. The payloads are JSON and full of double quotes, so the quoting has
    /// to be the kind that treats everything literally.
    var shellQuoted: String { "'" + replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
