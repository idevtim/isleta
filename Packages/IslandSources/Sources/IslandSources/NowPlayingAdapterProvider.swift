import IslandKit
import Foundation

/// Now Playing through the vendored `ungive/mediaremote-adapter` (§2.4).
///
/// The primary route, and the only one that sees *every* player rather than the handful that expose
/// a scripting dictionary. Since macOS 15.4 `mediaremoted` refuses `MRMediaRemoteGetNowPlayingInfo`
/// to processes it does not recognize; what it recognizes is a code-signing identifier beginning
/// `com.apple.`, and `/usr/bin/perl` reports `com.apple.perl`. So Isleta never links MediaRemote,
/// never dlopens it, and holds no private entitlement — it runs Apple's Perl, which loads a small
/// vendored framework, which asks MediaRemote and prints JSON. That is why "no private frameworks
/// except the isolated `mediaremote-adapter` path, behind a protocol, with a working fallback" is
/// satisfiable at all: the private framework is loaded in someone else's address space.
///
/// **It follows that this is not a capability Isleta can grant itself.** Re-signing Perl, shipping
/// a copy, or pointing at a Homebrew Perl produces a working interpreter that `mediaremoted` will
/// not answer. There is no configuration, no entitlement request, and no user setting that fixes
/// that, and there is emphatically no supported way around it — which is the whole reason
/// `NowPlayingScriptProvider` and `NullNowPlayingProvider` exist.
@MainActor
public final class NowPlayingAdapterProvider: NowPlayingProvider {

    public static let providerName = "MediaRemote adapter"

    public var onUpdate: ((NowPlayingUpdate) -> Void)?

    /// The queue window, when it changes.
    ///
    /// **Not on `NowPlayingProvider`.** The queue is an adapter capability and neither of the other
    /// two routes has one — the scripting fallback can read `current playlist`, which is a
    /// different thing that does not move when shuffle does, and the null route reads nothing. A
    /// protocol requirement would oblige both to answer for something they cannot do, which is the
    /// same reasoning that keeps `NowPlayingTransport` a separate protocol from this one.
    public var onQueue: (([NowPlayingQueueItem]) -> Void)?

    /// The window most recently asked for, so an unchanged ask is not sent again.
    ///
    /// Held here rather than in the reader because it survives a helper restart in neither place
    /// and has to be reset in exactly one — see `start()`.
    private var requestedWindow = NowPlayingQueuePaging.restingWindow

    private let location: NowPlayingAdapterLocation?
    private let executable: URL
    private let arguments: [String]
    private var reader: NowPlayingAdapterReader?

    /// Set when the helper dies on its own. Once set, the route is retired for this launch.
    ///
    /// The adapter's own documentation is explicit — "you should not reinvoke the script when a
    /// fatal error occurs" — and the reason is worth stating rather than merely obeying. A helper
    /// that fails at startup fails identically every time, so an automatic relaunch is an
    /// unthrottled spawn loop: a process creation, a framework load and a crash, several times a
    /// second, for as long as Isleta runs. That is a §9 catastrophe (idle CPU is budgeted at 0.3 %)
    /// that presents to the user as a hot laptop with nothing on screen to explain it. Retiring the
    /// route instead costs one launch's worth of Now Playing and falls through to scripting.
    private var retirementReason: String?

    /// - Parameters:
    ///   - location: Where the adapter is vendored, or `nil` when this build does not carry it —
    ///     which is the normal state of a `check.sh` build and must not be treated as a failure.
    ///   - executable: Overridable **only** so tests can substitute a stub that speaks the same line
    ///     protocol. Production must leave this at `/usr/bin/perl`; see `NowPlayingAdapterLocation`.
    ///   - arguments: Defaults to the location's documented `stream` invocation. Overridable for the
    ///     same reason and no other — a stub helper needs a different argument vector to decide what
    ///     to print. There is no supported reason to pass this in production, and no setting exposes
    ///     it: the flags are chosen against §9's memory budget, not against taste.
    public init(
        location: NowPlayingAdapterLocation?,
        executable: URL = NowPlayingAdapterLocation.perlExecutable,
        arguments: [String]? = nil
    ) {
        self.location = location
        self.executable = executable
        self.arguments = arguments ?? location?.streamArguments ?? []
    }

    /// Convenience over the app bundle. `nil` location is expected in development.
    public convenience init(bundle: Bundle) {
        self.init(location: NowPlayingAdapterLocation.inBundle(bundle))
    }

    /// `.notRequired` or `.denied`, never `.undetermined`.
    ///
    /// There is no prompt to show. `.undetermined` means "the user has not been asked", and this
    /// route is gated on an Apple entitlement policy rather than on TCC, so asking is not among the
    /// available moves. Reporting `.undetermined` would put a "Grant Access" button in IslandSettings
    /// that cannot do anything when pressed.
    public var authorization: SourceAuthorization {
        if let retirementReason {
            return .denied(explanation: Self.unavailableExplanation(detail: retirementReason))
        }
        guard location != nil else {
            return .denied(explanation: Self.unavailableExplanation(detail: nil))
        }
        return .notRequired
    }

    public func start() {
        // `location != nil` rather than a binding: the argument vector was resolved in `init`, so
        // the location is only consulted here to answer "does this build carry an adapter at all".
        // A build without one must not spawn `/usr/bin/perl` with an empty argument list.
        guard location != nil, retirementReason == nil, reader == nil else { return }

        let reader = NowPlayingAdapterReader(
            onUpdate: { [weak self] update in
                // `DispatchQueue.main.async`, not `Task { @MainActor in }`, and the difference is
                // correctness rather than style. Tasks enqueued from a serial queue are not
                // guaranteed to run in the order they were created, and this is a *diff* stream —
                // applying "playing: false" before the track change it followed leaves the island
                // showing a paused new track that is actually playing. The main queue is FIFO, so
                // the pipe's ordering survives the hop.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.onUpdate?(update)
                    }
                }
            },
            onQueue: { [weak self] items in
                // The same hop, and the same reason: the main queue is FIFO, so a queue line and
                // the state line it arrived beside reach the shell in the order the helper wrote
                // them. A `Task { @MainActor in }` here would be free to reorder them, and the
                // visible result is a list that briefly names the previous track's successors.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.onQueue?(items)
                    }
                }
            },
            onEnd: { [weak self] ending in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.handle(ending)
                    }
                }
            }
        )
        self.reader = reader
        // A fresh helper opens on the resting window whatever the last one was asked for, because
        // the window lives in the helper's own process. Left stale, the first `requestQueueWindow`
        // after a restart would be judged against a number no process is holding and suppressed.
        requestedWindow = NowPlayingQueuePaging.restingWindow
        reader.start(executable: executable, arguments: arguments)
    }

    /// Asks for a wider window of the queue, if this is genuinely wider than the last ask.
    ///
    /// The suppression is the point: a scroll produces a sample per frame, and each one resolves to
    /// a window through `NowPlayingQueuePaging.window(lastVisibleRow:isOpen:)`. Without this, a
    /// single flick would write sixty control lines and cost sixty MediaRemote round trips inside
    /// the helper that is also delivering track changes.
    public func requestQueueWindow(length: Int, isOpen: Bool) {
        guard NowPlayingQueuePaging.shouldRequest(length, having: requestedWindow, isOpen: isOpen)
        else { return }
        requestedWindow = length
        // Counts only — the rule this whole source is written around. A queue line carries titles
        // and artists and none of them may reach the log, which is emailed to strangers.
        IslandLog.nowPlaying.debug("queue window -> \(length)")
        reader?.requestQueueWindow(length: length)
    }

    public func stop() {
        reader?.stop()
        reader = nil
    }

    /// The one route that has something to wait for. See `NowPlayingAdapterReader.stopAndWait()`.
    public func stopAndWait() {
        reader?.stopAndWait()
        reader = nil
    }

    /// The helper's pid, or nil when none is running.
    ///
    /// Internal rather than public: it is read by the teardown test, which asks the kernel whether
    /// the child is really gone rather than trusting that `terminate()` was called — §9 says no
    /// child process left behind, and a signal that was merely *sent* satisfies that only on paper.
    /// It is also what a "Copy Diagnostics" dump wants when a user reports that music never appears.
    var childProcessIdentifier: Int32? { reader?.childProcessIdentifier }

    private func handle(_ ending: NowPlayingAdapterReader.Ending) {
        switch ending {
        case .launchFailed(let message):
            retirementReason = message
            IslandLog.nowPlaying.error("helper could not be launched — route retired: \(message)")

        case .exited(let status, let stderr):
            // The helper's stderr is the adapter's own text, never the player's; capped so a Perl
            // stack trace does not become the whole file.
            IslandLog.nowPlaying.warning(
                "helper exited with status \(status) — route retired"
                + (stderr.isEmpty ? "" : ": \(stderr.prefix(400))")
            )
            // A zero exit is retired too, not just a failing one. `stream` is documented to run until
            // SIGTERM, so it reaching its own end while we still want it means it has decided there
            // is nothing to stream — and relaunching a process that exits cleanly and instantly is
            // the same spawn loop as relaunching one that crashes, with a friendlier exit code.
            retirementReason = stderr.isEmpty ? "the helper exited with status \(status)" : stderr
        }

        reader = nil

        // The island must not keep showing a track the retired helper reported. `.cleared` rather
        // than silence, because silence would leave a stale ambient activity pinned to the bottom of
        // the stack for the rest of the session with nothing left alive to ever remove it.
        onUpdate?(.cleared)
    }

    /// User-facing, so it says what is lost rather than what broke.
    ///
    /// §10 again: the person reading this has not heard of MediaRemote, entitlements, or Perl, and
    /// telling them "adapter exited with status 1" invites them to file a bug about a machine that
    /// is working exactly as Apple intended. The technical detail is appended for a diagnostics
    /// dump, where it belongs, and only when there is one.
    private static func unavailableExplanation(detail: String?) -> String {
        let base = sourceText("nowPlaying.unavailable.adapter", """
            This build of Isleta can’t read system-wide Now Playing information. \
            Isleta will show music from players it can ask directly, such as Music.
            """)
        guard let detail, !detail.isEmpty else { return base }
        return base + " (\(detail))"
    }
}
