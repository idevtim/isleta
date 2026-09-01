import AppKit
import Foundation

/// Now Playing without the adapter: the per-app fallback of §2.4.
///
/// Two mechanisms, and the split between them is what makes this route survive a refused permission.
///
/// 1. **Live updates ride distributed notifications the players post themselves.** Music posts
///    `com.apple.Music.playerInfo` (and, for compatibility, `com.apple.iTunes.playerInfo`) on every
///    play, pause and track change, carrying name, artist, album and state in the `userInfo`.
///    Verified on macOS 27.0. This needs **no permission at all** — a distributed notification is
///    broadcast, not requested — and it needs no polling, which is the §9 requirement that would
///    otherwise sink this whole approach. AppleScript is what people reach for here, and an
///    AppleScript that has to be re-run to notice a change is a timer by another name.
///
/// 2. **The initial read is one AppleScript.** The notification fires on *change*, so a user who
///    was already listening when Isleta launched has generated no event. This is the only part that
///    touches Automation, and therefore the only part that a refusal takes away.
///
/// That is why `authorization` is `.notRequired` even when Automation is refused, and why the
/// refusal is reported separately through `initialReadAuthorization`. Folding them together would be
/// the obvious thing and would be a real bug: `SourceAuthorization.isUsable` is false for `.denied`,
/// so a caller checking it before starting sources would skip a route that works — trading a small
/// degradation (the island catches up at the next track change) for a total one (no Now Playing at
/// all), on the strength of a permission that governs a tenth of what the route does.
@MainActor
public final class NowPlayingScriptProvider: NowPlayingProvider {

    public static let providerName = "Player scripting"

    public var onUpdate: ((NowPlayingUpdate) -> Void)?

    private let players: [NowPlayingPlayer]
    private let environment: any NowPlayingScriptEnvironment
    private let distributedCenter: NotificationCenter
    private let workspaceCenter: NotificationCenter

    private var state = NowPlayingScriptState()
    private var observers: [any NSObjectProtocol] = []
    private var isRunning = false

    /// - Parameters:
    ///   - distributedCenter: `DistributedNotificationCenter.default()` in production. Typed as the
    ///     superclass so tests can drive the provider through a private `NotificationCenter` —
    ///     posting a fake `com.apple.Music.playerInfo` system-wide would be a broadcast to every
    ///     other app on the machine that listens for it.
    ///   - workspaceCenter: `NSWorkspace.shared.notificationCenter`, which is *not*
    ///     `NotificationCenter.default` — workspace notifications are posted only on the workspace's
    ///     own center, and observing the default one is a mistake that produces no error and no
    ///     events.
    public init(
        players: [NowPlayingPlayer] = NowPlayingPlayer.all,
        environment: any NowPlayingScriptEnvironment = NowPlayingSystemScriptEnvironment(),
        distributedCenter: NotificationCenter = DistributedNotificationCenter.default(),
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.players = players
        self.environment = environment
        self.distributedCenter = distributedCenter
        self.workspaceCenter = workspaceCenter
    }

    /// Always `.notRequired`: the live half of this route asks nobody for anything. See the type's
    /// documentation for why the Automation refusal is reported separately instead.
    public var authorization: SourceAuthorization { .notRequired }

    /// What Automation would add, aggregated over the players that are actually running.
    ///
    /// Read by IslandSettings to decide whether there is anything to offer. Only running players
    /// count, because a permission for an app the user does not have open is not a thing to nag
    /// about — §10's "no nagging" is mostly a question of *when* you mention a permission, and the
    /// answer is "while it would be doing something".
    public var initialReadAuthorization: SourceAuthorization {
        let statuses = players
            .filter { environment.isRunning($0) }
            .map { environment.automationStatus(for: $0) }

        if statuses.isEmpty { return .notRequired }
        if statuses.contains(.granted) { return .granted }
        if statuses.contains(.undetermined) { return .undetermined }
        return statuses.first { if case .denied = $0 { true } else { false } } ?? .notRequired
    }

    /// Ask for Automation on every running player that has not been asked about, from a control the
    /// user clicked.
    ///
    /// **One button, up to two dialogs**, and the sequencing is the whole of why this is not a loop
    /// with a `DispatchGroup`. Automation is granted per target application, so somebody running
    /// both Music and Spotify has two permissions to give — and macOS will show the second dialog
    /// stacked on the first if both calls go out at once, which reads as the app having asked twice
    /// for the same thing. They are chained instead: ask, wait for the answer, then ask the next.
    ///
    /// - Parameter completion: the aggregate afterwards, phrased exactly as `initialReadAuthorization`
    ///   phrases it, so the caller compares like with like. `.notRequired` when no player was
    ///   running, which is a real answer rather than a failure — there was nothing to permit.
    public func requestAutomationFromUserInitiatedMoment(
        then completion: @escaping @MainActor (SourceAuthorization) -> Void
    ) {
        // Only running players, for `initialReadAuthorization`'s reason: a dialog about an app the
        // user does not have open is a dialog about nothing, and `AEDeterminePermissionToAutomateTarget`
        // answers `procNotFound` for it anyway.
        var pending = players.filter { environment.isRunning($0) && environment.automationStatus(for: $0) == .undetermined }

        func askNext() {
            guard let player = pending.first else {
                completion(initialReadAuthorization)
                return
            }
            pending.removeFirst()
            environment.requestAutomation(for: player) { _ in askNext() }
        }
        askNext()
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true

        for player in players {
            for name in player.notificationNames {
                // `object: nil`. The posted object is the sender's own string identifier
                // ("com.apple.Music.player"), which is not the notification name and not the bundle
                // identifier; matching on a guess there yields an observer that never fires.
                let token = distributedCenter.addObserver(
                    forName: Notification.Name(name),
                    object: nil,
                    queue: nil
                ) { [weak self] notification in
                    let update = player.update(fromPlayerInfo: notification.userInfo ?? [:])
                    // Parsed here, on whatever thread delivered, because the result is a `Sendable`
                    // value and the `userInfo` is not. Hopping first and parsing on the main actor
                    // would mean carrying a foreign `[AnyHashable: Any]` across isolation.
                    //
                    // `DistributedNotificationCenter` with a nil queue does in fact deliver on the
                    // main thread — verified on macOS 27.0 — but the hop below is not redundant.
                    // Nothing documents that guarantee, and the injected `NotificationCenter` the
                    // tests use delivers on the posting thread, whatever that is.
                    Self.onMain { self?.publish(update, from: player.bundleIdentifier) }
                }
                observers.append(token)
            }
        }

        observers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                guard let bundleIdentifier = Self.bundleIdentifier(in: notification) else { return }
                Self.onMain { self?.playerDidQuit(bundleIdentifier) }
            }
        )

        observers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                guard let bundleIdentifier = Self.bundleIdentifier(in: notification) else { return }
                Self.onMain { self?.playerDidLaunch(bundleIdentifier) }
            }
        )

        readInitialState()
    }

    public func stop() {
        // Tokens, not `removeObserver(self)`. The block-based API registers an opaque observer that
        // is not `self`, so removing `self` from these centers removes nothing at all — and the
        // blocks keep firing into a provider the app believes it has shut down, which is a §9
        // failure that shows up as work happening after `stop()` rather than as a crash.
        for token in observers {
            distributedCenter.removeObserver(token)
            workspaceCenter.removeObserver(token)
        }
        observers.removeAll()
        state.reset()
        isRunning = false
    }

    // MARK: - Private

    /// Asks every running player what it is playing, once.
    ///
    /// Not a poll: this runs at `start()` and when a player launches, both of which are events. The
    /// first player with something to say wins, and the rest are still asked because "playing" is
    /// what takes the stage in `NowPlayingScriptState`, not "asked first".
    private func readInitialState() {
        for player in players where environment.isRunning(player) {
            environment.readCurrentTrack(from: player) { [weak self] update in
                guard let self, let update else { return }
                publish(update, from: player.bundleIdentifier)
            }
        }
    }

    private func publish(_ update: NowPlayingUpdate, from bundleIdentifier: String) {
        guard isRunning, let resolved = state.ingest(update, from: bundleIdentifier) else { return }
        onUpdate?(resolved)
    }

    private func playerDidQuit(_ bundleIdentifier: String) {
        guard isRunning, let resolved = state.playerDidQuit(bundleIdentifier) else { return }
        onUpdate?(resolved)
    }

    private func playerDidLaunch(_ bundleIdentifier: String) {
        guard isRunning, let player = players.first(where: { $0.bundleIdentifier == bundleIdentifier })
        else { return }
        environment.readCurrentTrack(from: player) { [weak self] update in
            guard let self, let update else { return }
            publish(update, from: bundleIdentifier)
        }
    }

    private nonisolated static func bundleIdentifier(in notification: Notification) -> String? {
        let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
        return (application as? NSRunningApplication)?.bundleIdentifier
    }

    /// Hops to the main actor, preserving order.
    ///
    /// `DispatchQueue.main.async` rather than `Task { @MainActor in }`: tasks created from the same
    /// thread are not guaranteed to run in creation order, and these carry a sequence — a pause
    /// applied after the track change that followed it leaves the island lying about the state of
    /// the player. The main queue is FIFO. `assumeIsolated` is sound here because the main queue is
    /// the main actor's executor by definition.
    private nonisolated static func onMain(_ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated(body)
        }
    }
}
