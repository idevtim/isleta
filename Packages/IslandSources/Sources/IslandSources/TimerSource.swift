import AppKit
import Foundation
import IslandActivities
import IslandKit

/// Apple's Clock timers, on the island.
///
/// ## Where the state comes from, and why the obvious signal is the wrong one
///
/// `MobileTimerState` records the store and its shapes. What this type owns is the harder half:
/// **there is no push signal at all.** Measured on macOS 27.0 against one real timer start, with a
/// Darwin observer, a cfprefsd read and a vnode watch running side by side:
///
/// | Signal | Latency after the click |
/// |---|---|
/// | the value, via `CFPreferencesCopyAppValue` | **151 ms** |
/// | the plist **file** written (vnode) | **8.9 s** |
/// | `NSDistributedNotificationCenter`, any name | never |
/// | Darwin `notify`, on 15 `MTTimerManager*` names from the dyld shared cache | never |
///
/// So the `DispatchSource` vnode watch — push, permission-free, no timer, and the mechanism this
/// codebase reaches for by reflex — is **nine seconds behind the user**, because cfprefsd batches
/// the flush to disk. The 15 names are in the shared cache because `MTTimerManager` posts them to
/// its own in-process `NSNotificationCenter`; they are not a bus we can join.
///
/// Something has to ask. So:
///
/// - **Idle: nothing.** No timer running and Clock not in front means no poll, no display link, and
///   two free `NSWorkspace` observers. §9's idle budget is untouched, which is the whole reason this
///   shape was chosen over polling outright.
/// - **Clock is frontmost:** poll at `activeInterval`. A timer started by hand is on the island in
///   well under a second, and Clock is not running on an idle Mac so this costs nothing the rest of
///   the time.
/// - **A timer is live:** poll at `liveInterval`, which is what notices a pause or a cancel made
///   somewhere else. CLAUDE.md permits exactly this — "a provider that must poll polls only while
///   its activity is presented". The countdown itself still polls nothing: the fire date is
///   absolute and the island counts against its own clock.
/// - **Otherwise:** the vnode watch, as the late backstop for Siri, Shortcuts and Control Center.
///   Free, and correct if slow.
public final class TimerSource: ActivitySource {

    public static let sourceName = "timer"

    /// While Clock is frontmost. Fast enough that starting a timer feels immediate.
    static let activeInterval: TimeInterval = 0.5

    /// While a timer is live but Clock is not in front — enough to notice a pause or a cancel.
    static let liveInterval: TimeInterval = 5

    public var onActivity: ((any IslandActivity) -> Void)?
    public var onDismiss: ((ActivityID) -> Void)?

    /// Reading another application's preferences domain needs nothing at all — no entitlement, no
    /// TCC prompt, no Full Disk Access. The Core Data store behind it *is* walled; we never touch it.
    public var authorization: SourceAuthorization { .notRequired }

    private let domain: String
    private let now: () -> Date
    private var isRunning = false

    /// What was last published, so a poll that changes nothing publishes nothing.
    private var published: [ActivityID: MobileTimerState] = [:]

    private var poll: DispatchSourceTimer?
    private var pollInterval: TimeInterval?
    private var watchFD: Int32 = -1
    private var watch: DispatchSourceFileSystemObject?
    private var workspaceObservers: [any NSObjectProtocol] = []

    public init(
        domain: String = "com.apple.mobiletimerd",
        now: @escaping () -> Date = { Date() }
    ) {
        self.domain = domain
        self.now = now
    }

    // MARK: - Lifecycle

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        observeClock()
        startWatchingFile()
        refresh()
        retune()
        IslandLog.sources.info("timer source started")
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false

        poll?.cancel()
        poll = nil
        pollInterval = nil

        watch?.cancel()
        watch = nil
        if watchFD >= 0 { close(watchFD); watchFD = -1 }

        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()

        // Withdraw what is on the island. A source that stops without retracting leaves a countdown
        // that will never move again, which reads as the island having frozen.
        for id in published.keys { onDismiss?(id) }
        published.removeAll()
        IslandLog.sources.info("timer source stopped")
    }

    // MARK: - Watching

    /// Clock launching, quitting or coming to the front. All three are free — `NSWorkspace` posts
    /// them whether or not anybody is listening — and they are what turns the poll on and off.
    ///
    /// Registered on **`NSWorkspace`'s** notification center, not `NotificationCenter.default`: a
    /// token from one removes nothing when handed to the other, which CLAUDE.md records against the
    /// space-transition handler.
    private func observeClock() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didDeactivateApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ] {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.clockActivityChanged() }
            }
            workspaceObservers.append(observer)
        }
    }

    private func clockActivityChanged() {
        guard isRunning else { return }
        refresh()
        retune()
    }

    /// Whether Clock is frontmost, which is the one moment a timer is most likely to be started.
    private var isClockActive: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.clock"
    }

    /// The plist, watched by vnode. The late backstop, and the only thing running while the Mac is
    /// idle — it costs one file descriptor and no CPU.
    private func startWatchingFile() {
        let path = NSHomeDirectory() + "/Library/Preferences/\(domain).plist"
        watch?.cancel()
        watch = nil
        if watchFD >= 0 { close(watchFD); watchFD = -1 }

        watchFD = open(path, O_EVTONLY)
        guard watchFD >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: watchFD, eventMask: [.write, .delete, .rename, .extend], queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                self.refresh()
                self.retune()
                // cfprefsd replaces the file rather than rewriting it, so the descriptor we were
                // watching now points at an unlinked inode. Re-arm on the new one, or the backstop
                // fires exactly once per launch.
                self.startWatchingFile()
            }
        }
        source.resume()
        watch = source
    }

    // MARK: - Polling, at the rate the moment deserves

    /// The interval this instant calls for, or nil for "do not poll".
    private var wantedInterval: TimeInterval? {
        if isClockActive { return Self.activeInterval }
        if !published.isEmpty { return Self.liveInterval }
        return nil
    }

    /// Starts, restarts or stops the poll so it matches `wantedInterval`.
    ///
    /// Compares against the interval already running rather than rebuilding unconditionally: this
    /// is called from four notification handlers and from every poll tick, and tearing a
    /// `DispatchSourceTimer` down and building a new one on each of those would spend more on the
    /// bookkeeping than on the reads.
    private func retune() {
        let wanted = wantedInterval
        guard wanted != pollInterval else { return }
        pollInterval = wanted

        poll?.cancel()
        poll = nil
        guard let wanted else { return }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + wanted, repeating: wanted)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                self.refresh()
                self.retune()
            }
        }
        timer.resume()
        poll = timer
    }

    /// How many timers are on the island. Counts only — a timer's name is the user's own words,
    /// and this is read by the diagnostics report that gets emailed.
    public var liveCount: Int { published.count }

    // MARK: - Reading

    /// Reads the store and publishes the difference.
    func refresh() {
        let instant = now()
        let live = MobileTimerState.timers(from: readTimers(), now: instant)
        let byID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for (id, state) in byID where published[id] != state {
            onActivity?(
                BuiltInActivity.timer(
                    id: id,
                    title: state.title,
                    state: state.state,
                    totalDuration: state.totalDuration,
                    now: instant
                )
            )
        }
        for id in published.keys where byID[id] == nil {
            onDismiss?(id)
        }
        published = byID
    }

    /// The raw `MTTimers` value, straight from cfprefsd.
    ///
    /// `CFPreferencesAppSynchronize` first, and it is not superstition: without it this process
    /// keeps serving its own cached copy of another application's domain, and the value never
    /// changes no matter how many times it is read.
    private func readTimers() -> Any? {
        CFPreferencesAppSynchronize(domain as CFString)
        return CFPreferencesCopyAppValue("MTTimers" as CFString, domain as CFString)
    }
}
