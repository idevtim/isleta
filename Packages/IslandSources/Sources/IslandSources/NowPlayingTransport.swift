import Darwin
import Foundation

/// Sending a command *to* the player, as opposed to hearing about it.
///
/// A separate protocol from `NowPlayingProvider` rather than three more methods on it, because the
/// two capabilities do not travel together. The scripting fallback reads a player perfectly well
/// through distributed notifications it needs no permission for, and can control nothing without an
/// Automation grant the user may never give; the adapter reads *and* writes with neither. Folding
/// control into the read protocol would force every conformer to answer for a capability it may not
/// have, and the honest answer — a `send` that silently does nothing — is exactly the transport
/// button that looks enabled and isn't.
///
/// So `isAvailable` is the whole reason this type exists: the island asks before it draws.
@MainActor
public protocol NowPlayingTransport: AnyObject {

    /// Whether pressing a control would actually do something. Read on every render, never cached
    /// by the caller: the route can retire mid-session when its helper dies.
    var isAvailable: Bool { get }

    func send(_ command: NowPlayingCommand)

    /// Moves the playhead. Seconds at this boundary, microseconds on the wire — the conversion is
    /// `NowPlayingAdapterLocation.seekArguments`, where the unit is documented.
    func seek(toSeconds seconds: TimeInterval)

    /// Jumps to an entry of the playback queue.
    ///
    /// Its own method rather than a `NowPlayingCommand` case, because it is the one command that
    /// cannot be expressed as an id: `PlayItemInPlaybackQueue` needs a userInfo dictionary, and
    /// `send(_:)`'s whole vocabulary is "an id with nil options". Routing it through `send` would
    /// mean the enum carried a case that silently did nothing — which is precisely what the two
    /// *other* queue commands do when they are sent that way.
    ///
    /// - Parameters:
    ///   - offset: the entry's position in the window the player vended, from zero. **Zero is the
    ///     track already playing**, so a caller asking for it is asking to restart, not to skip.
    ///   - contentItemIdentifier: the entry's own id where the player supplied one.
    func playQueueItem(atOffset offset: Int, contentItemIdentifier: String?)

    /// Likes or un-likes what is playing.
    ///
    /// Only ever called for a player that reports `supportsIsLiked` — see
    /// `NowPlayingSnapshot.canFavorite`. A transport cannot check that for itself: the capability is a
    /// property of the *track*, and this object only knows about the route.
    func setFavorite(_ favorite: Bool)
}

/// The transport that is honest about having none.
///
/// What ships when the adapter is not vendored or has retired, and what the scripting route gets.
/// `isAvailable` is false, so the island draws no transport row at all — not a grayed one. A grayed
/// row is right when a *capability* is missing from an otherwise working control set (`prohibitsSkip`
/// on a radio station); it is wrong when there is no control set, because it advertises a feature
/// this build does not have and invites the user to go looking for the switch that turns it on.
@MainActor
public final class NowPlayingUnavailableTransport: NowPlayingTransport {

    public init() {}

    public var isAvailable: Bool { false }

    public func send(_ command: NowPlayingCommand) {}

    public func seek(toSeconds seconds: TimeInterval) {}

    public func playQueueItem(atOffset offset: Int, contentItemIdentifier: String?) {}

    public func setFavorite(_ favorite: Bool) {}
}

/// Transport through the vendored `mediaremote-adapter`.
///
/// One short-lived `/usr/bin/perl` per command. That looks profligate next to keeping the streaming
/// helper open and writing to its stdin, and it is the right shape anyway: the adapter's `stream`
/// command reads nothing from stdin, so there is no channel to write to, and inventing one would
/// mean forking the vendored script. A `send` process loads the framework, makes one XPC call and
/// exits — measured in tens of milliseconds — and it happens when a human presses a button, not on
/// a timer. §9's idle path never sees one.
///
/// The same rule as everywhere else in this route applies to the interpreter: it is `/usr/bin/perl`
/// because `mediaremoted` answers on code-signing identifier, and no copy, re-signing or Homebrew
/// build of Perl is answered. See `NowPlayingAdapterLocation`.
@MainActor
public final class NowPlayingAdapterTransport: NowPlayingTransport {

    /// How many commands may be in flight at once.
    ///
    /// Not a performance tuning knob — a bound on what a stuck helper can cost. A user holding Next
    /// down, or a player that has wedged `mediaremoted`, would otherwise spawn a process per press
    /// with nothing reaping them, and the failure presents as a machine that gets slower the more
    /// the user tries to fix it. Four is comfortably more than a human can press deliberately and
    /// small enough that the worst case is four idle interpreters.
    private static let maximumConcurrentCommands = 4

    /// Long enough for the framework load plus one XPC round trip on a busy machine, short enough
    /// that a wedged `mediaremoted` cannot leave a process behind for the session. §9's "no child
    /// process left behind" is not satisfied by a process that merely *usually* exits.
    private static let commandTimeout: TimeInterval = 5

    private let location: NowPlayingAdapterLocation?
    private let executable: URL

    /// Live children, so `stop()` and the concurrency cap have something to count. Main-actor
    /// confined; every mutation is either from a call the user made or from a termination handler
    /// that hops back here first.
    private var running: [Process] = []

    private var isRetired = false

    /// - Parameter executable: overridable **only** so tests can substitute a stub. Production must
    ///   leave this at `/usr/bin/perl`; see `NowPlayingAdapterLocation` for why that is a mechanism
    ///   and not a setting.
    public init(
        location: NowPlayingAdapterLocation?,
        executable: URL = NowPlayingAdapterLocation.perlExecutable
    ) {
        self.location = location
        self.executable = executable
    }

    public convenience init(bundle: Bundle) {
        self.init(location: NowPlayingAdapterLocation.inBundle(bundle))
    }

    public var isAvailable: Bool { location != nil && !isRetired }

    public func send(_ command: NowPlayingCommand) {
        guard let location else { return }
        run(location.sendArguments(command))
    }

    public func seek(toSeconds seconds: TimeInterval) {
        guard let location else { return }
        run(location.seekArguments(toSeconds: seconds))
    }

    /// One `send 131` with the offset and the id. A one-shot spawn, like every other command, and
    /// for the same reason: this happens when a person double-clicks a row, not on a clock.
    ///
    /// The *reads* are the ones that may never be one-shots — a `queue` spawn costs 60-360 ms
    /// against a 15-30 ms read, so the window is asked for down the streaming helper's stdin
    /// instead. See `NowPlayingAdapterProvider.requestQueueWindow(length:)`.
    public func playQueueItem(atOffset offset: Int, contentItemIdentifier: String?) {
        guard let location else { return }
        run(
            location.playQueueItemArguments(
                atOffset: offset,
                contentItemIdentifier: contentItemIdentifier
            )
        )
    }

    public func setFavorite(_ favorite: Bool) {
        guard let location else { return }
        run(location.likeArguments(favorite))
    }

    /// Kills anything still running. Called from the source's `stop()`.
    public func stop() {
        for process in running where process.isRunning {
            process.terminate()
        }
        running.removeAll()
    }

    private func run(_ arguments: [String]) {
        guard !isRetired, running.count < Self.maximumConcurrentCommands else { return }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // Everything to /dev/null, including stdout. A command's output is a single line nobody
        // reads, and an *unread* pipe is worse than no pipe: it fills its 64 KB buffer and blocks
        // the writer, so the helper would hang instead of exiting and the concurrency cap above
        // would fill up with processes that are never coming back.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        process.terminationHandler = { finished in
            let identifier = finished.processIdentifier
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Compared by pid rather than by identity: `Process` is not `Hashable` and
                    // `===` on a captured reference would keep the process alive until the handler
                    // ran, which is precisely the retain cycle this is trying not to have.
                    self.running.removeAll { $0.processIdentifier == identifier }
                }
            }
        }

        do {
            try process.run()
        } catch {
            // A launch failure here is the same failure `NowPlayingAdapterProvider` retires the
            // read route for: a missing script or a Perl that is no longer at its documented path.
            // It fails identically every time, so retrying on the next button press would be an
            // unthrottled spawn loop driven by a user who can see nothing happening and is pressing
            // harder. Retire, and let `isAvailable` take the buttons away.
            isRetired = true
            return
        }

        running.append(process)

        // The escalation exists for a Perl blocked inside a framework call, which ignores SIGTERM.
        // `process` is captured here and only here; the closure runs once and releases it.
        let boxed = UncheckedBox(process)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.commandTimeout) {
            MainActor.assumeIsolated {
                guard boxed.value.isRunning else { return }
                kill(boxed.value.processIdentifier, SIGKILL)
            }
        }
    }
}

/// Carries a non-`Sendable` reference across a boundary the compiler cannot reason about.
///
/// Used for `Process` only, and only for `isRunning` / `processIdentifier` / `terminate()`, which
/// are thin wrappers over `kill` and `waitpid` and are safe to call from another thread. `Process`
/// predates `Sendable` and will not gain it. Deliberately `internal` and named for what it is, so
/// it cannot quietly become a general-purpose way of silencing the checker.
struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
