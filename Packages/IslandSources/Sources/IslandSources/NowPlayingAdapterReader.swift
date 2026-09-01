import IslandKit
import Darwin
import Foundation

/// Owns the spawned helper: launch, line reading, and — the part that matters — teardown.
///
/// Everything mutable here is touched only on `queue`. The class is `@unchecked Sendable` on that
/// basis and on no other: `Process`, `Pipe` and `FileHandle` all predate `Sendable`, so the compiler
/// cannot check the confinement and the confinement is the whole argument. `readabilityHandler`
/// fires on a queue Foundation owns, so its body does nothing but hand the bytes to `queue` — the
/// alternative, parsing inside the handler, would put the decoder's merge state on a thread that
/// `stop()` cannot fence against.
///
/// ## Teardown must not be asynchronous on the way out
///
/// `stop()` sends SIGTERM **synchronously**, and `stopAndWait()` does not return until the child is
/// actually gone. Both matter, and the reason is measured rather than theoretical.
///
/// This class used to do all of its teardown inside `queue.async`, so `stop()` returned having
/// merely *scheduled* the signal. On every path but one that is fine. The exception is
/// `applicationWillTerminate`, which returns straight into `exit()` — the block never ran, SIGTERM
/// was never sent, and **an ordinary Quit orphaned the helper every time.** Measured on macOS 27.0
/// by quitting from the status menu and watching the child reparent to launchd: one stranded `perl`
/// per launch, accumulating for as long as the user never reboots. Nineteen of them were found alive
/// on a development machine, the oldest twelve hours old.
///
/// The bug was invisible from inside the app, which is why it lasted: `stop()` is correct, it was
/// called, and it logged nothing wrong. Only the process table shows it. Note also that the SIGKILL
/// escalation could never fire on that path either — it waits two seconds to check on a process that
/// has been gone for 1999 milliseconds — so a wedged helper was stranded whether or not it honored
/// the signal it was never sent.
///
/// **The residual risk `stop()` still cannot cover: if Isleta is *killed* rather than quit, the
/// helper survives it.** macOS does not kill a child when its parent dies, and there is no
/// documented way to ask the adapter to watch for our exit — it stops on SIGTERM, which a
/// SIGKILLed process cannot send. The exposure is now one idle `perl` per *crash* rather than per
/// quit: blocked in a MediaRemote callback, costing nothing until the user reboots or notices it.
/// Worth knowing about before someone "fixes" it by having the app kill every `perl` it finds at
/// launch, which would reach into processes Isleta does not own.
final class NowPlayingAdapterReader: @unchecked Sendable {

    /// Why the helper stopped. The distinction decides whether the route is still worth having.
    enum Ending: Equatable, Sendable {

        /// It could not be launched at all — a missing script, a Perl that is no longer there.
        case launchFailed(String)

        /// It exited on its own. The adapter documents non-zero as fatal and explicitly says not to
        /// reinvoke, so this retires the route rather than restarting it.
        case exited(status: Int32, stderr: String)
    }

    /// One serial queue for the process, the buffer and the decoder.
    ///
    /// `.utility` rather than `.userInitiated`: this thread wakes on track changes, not on frames,
    /// and telling the scheduler otherwise is how a background helper starts showing up in Energy
    /// impact for work that could have waited a few milliseconds.
    private let queue = DispatchQueue(
        label: "com.tryisleta.isleta.nowplaying.adapter",
        qos: .utility
    )

    /// Where SIGKILL escalation waits. Separate from `queue` because it blocks in `waitUntilExit()`,
    /// and blocking `queue` during teardown would deadlock a `start()` that arrives right behind a
    /// `stop()` — which is exactly what a display-change rebuild does.
    private let reapQueue = DispatchQueue(
        label: "com.tryisleta.isleta.nowplaying.adapter.reap",
        qos: .utility
    )

    private let onUpdate: @Sendable (NowPlayingUpdate) -> Void

    /// The queue window, forwarded only when it changes.
    ///
    /// A second callback rather than a field of `NowPlayingUpdate`, because the queue arrives on
    /// its own line at its own cadence — see `NowPlayingAdapterDecoder.queueItems`. Optional
    /// because the queue is a garnish: a build that does not want it passes nothing and the decoder
    /// still parses the line, which costs one array nobody reads.
    private let onQueue: (@Sendable ([NowPlayingQueueItem]) -> Void)?

    private let onEnd: @Sendable (Ending) -> Void

    private var process: Process?
    private var outHandle: FileHandle?
    private var errHandle: FileHandle?

    /// The write end of the helper's stdin, which is the control channel.
    ///
    /// **A pipe, where this used to be `/dev/null`.** The reason it was `/dev/null` is untouched
    /// and worth restating, because it reads like the thing being undone: an *inherited* stdin
    /// means the helper shares Isleta's controlling terminal in a development run, and a Perl that
    /// reads from a terminal it does not own takes SIGTTIN and stops — a stream that goes quiet
    /// with the process still alive. A pipe is not a terminal and cannot raise SIGTTIN, so the
    /// hazard that rule exists for is not reachable through one.
    ///
    /// What it buys is the queue window. A scrollable Up Next has to ask for more rows as the
    /// reader scrolls, and the alternative to a channel is a `perl … queue --length=N` per flick —
    /// 60-360 ms of process spawn to cover a 15-30 ms read.
    private var controlHandle: FileHandle?

    private var decoder = NowPlayingAdapterDecoder()
    private var buffer = Data()
    private var errorText = Data()

    /// What was last handed to `onQueue`, so an unchanged window is not republished.
    ///
    /// The helper dedupes its own queue lines, but only against the *previous* one: a window that
    /// goes 5 → 12 → 5 emits three lines and the first and third are identical. Comparing here as
    /// well is one `Equatable` check on a track change.
    private var publishedQueue: [NowPlayingQueueItem] = []

    /// How long to wait for SIGTERM to be honored before SIGKILL.
    ///
    /// The helper's documented stop signal is SIGTERM and it does honor it, so this deadline is
    /// only reached when Perl is wedged inside a framework call. Long enough that a healthy helper
    /// always exits cleanly first; short enough that quitting Isleta does not leave a `perl` in the
    /// user's process list for them to find later and wonder about.
    private static let terminationGrace: TimeInterval = 2

    /// How long `stopAndWait()` gives SIGTERM before SIGKILL.
    ///
    /// Two orders of magnitude shorter than `terminationGrace`, and for a different question. That
    /// one asks "has this helper wedged?" with all the time in the world; this one asks "can I quit
    /// yet?" while the user waits. A healthy helper exits well inside it — measured at under 5ms —
    /// and a wedged one is killed rather than allowed to hold the quit open.
    private static let quitGrace: TimeInterval = 0.25

    /// Cap on retained stderr. The adapter documents every stderr line as an error message and most
    /// of them as non-fatal, so a chatty build could produce them steadily; this is a diagnostic
    /// tail, and an unbounded one would be a slow leak on the idle path.
    private static let maxErrorBytes = 4096

    init(
        onUpdate: @escaping @Sendable (NowPlayingUpdate) -> Void,
        onQueue: (@Sendable ([NowPlayingQueueItem]) -> Void)? = nil,
        onEnd: @escaping @Sendable (Ending) -> Void
    ) {
        self.onUpdate = onUpdate
        self.onQueue = onQueue
        self.onEnd = onEnd
    }

    /// Launches the helper. Safe to call when one is already running: it is a no-op, which is what
    /// makes `NowPlayingAdapterProvider.start()` idempotent per the `ActivitySource` contract.
    ///
    /// `executable` is separate from `arguments` so tests can point this at a stub that speaks the
    /// same line protocol. That seam is the only way to exercise spawn, framing, diff merging and
    /// teardown on a machine where the real framework is not vendored — and those four are where the
    /// bugs are, not in the framework call itself.
    func start(executable: URL, arguments: [String]) {
        queue.async { [self] in
            guard process == nil else { return }

            let task = Process()
            task.executableURL = executable
            task.arguments = arguments

            let out = Pipe()
            let err = Pipe()
            task.standardOutput = out
            task.standardError = err

            // stdin is a pipe rather than inherited — see `controlHandle`. It is emphatically not
            // the *inherited* stdin the original rule warns about: that one hands the helper
            // Isleta's controlling terminal in a development run, and a Perl reading from a
            // terminal it does not own takes SIGTTIN and stops, which looks exactly like a player
            // that stopped reporting. A pipe cannot do that.
            let control = Pipe()
            task.standardInput = control

            decoder.reset()
            buffer.removeAll(keepingCapacity: false)
            errorText.removeAll(keepingCapacity: false)
            publishedQueue.removeAll(keepingCapacity: false)

            let outReader = out.fileHandleForReading
            let errReader = err.fileHandleForReading

            outReader.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty {
                    // EOF. Clearing the handler here is not tidiness — it is the difference between
                    // an idle helper and a spinning one. At end of file `availableData` returns
                    // empty immediately and Foundation re-arms the handler, so leaving it installed
                    // turns the pipe into a busy loop that burns a core for as long as the app runs.
                    // It produces no error, no log line, and no visible symptom other than the fan.
                    handle.readabilityHandler = nil
                    return
                }
                guard let self else { return }
                queue.async { self.ingest(data) }
            }

            errReader.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                // stderr is drained even though nothing displays it. An unread pipe fills its 64 KB
                // buffer and then blocks the *writer* — the helper would stop emitting track changes
                // while still appearing perfectly healthy, and the island would freeze on whatever
                // was playing when the buffer filled.
                guard let self else { return }
                queue.async { self.absorbError(data) }
            }

            task.terminationHandler = { [weak self] finished in
                guard let self else { return }
                let status = finished.terminationStatus
                queue.async { self.finish(status: status) }
            }

            do {
                try task.run()
            } catch {
                outReader.readabilityHandler = nil
                errReader.readabilityHandler = nil
                onEnd(.launchFailed(error.localizedDescription))
                return
            }

            process = task
            outHandle = outReader
            errHandle = errReader
            controlHandle = control.fileHandleForWriting
            IslandLog.nowPlaying.info("helper started, pid \(task.processIdentifier)")
        }
    }

    /// The running helper's pid. `queue.sync` because the process is queue-confined and this is the
    /// one read that comes from outside; it is a diagnostics and test accessor, never on a hot path.
    var childProcessIdentifier: Int32? {
        queue.sync { process?.processIdentifier }
    }

    /// Asks the running helper for a queue window of `length`.
    ///
    /// One line down the control channel — see `controlHandle`. Nothing is asked of a helper that
    /// is not running, and a write that fails is dropped rather than retried: the failure mode is a
    /// helper that has died, which the termination handler is already reporting, and a retry loop
    /// on a dead pipe is the spawn loop this route retires itself to avoid.
    ///
    /// **On `queue`, asynchronously.** The write is a few bytes into a pipe with a 64 KB buffer, so
    /// it cannot block in practice — but it is a `write(2)` to a child process, and doing it
    /// synchronously from the main actor is exactly the shape of thing that stalls a frame on the
    /// one machine where it does block.
    func requestQueueWindow(length: Int) {
        queue.async { [self] in
            guard process != nil, let controlHandle else { return }
            let clamped = max(1, min(NowPlayingQueuePaging.maximumWindow, length))
            guard let data = "length \(clamped)\n".data(using: .utf8) else { return }
            // `try?` and not a `do`/`catch` with a log line: the only error this can raise is EPIPE
            // against a helper that has already gone, which `finish(status:)` is reporting on the
            // same queue a moment later. Logging it here would be the same death reported twice,
            // once as a warning about a route that is fine.
            try? controlHandle.write(contentsOf: data)
        }
    }

    /// Tears the helper down: no child process, no reader, no handler.
    ///
    /// **Synchronous through the signal.** `queue.sync` rather than `queue.async` so that SIGTERM
    /// has been *sent* by the time this returns — see the note on teardown above for what the async
    /// version cost. The wait for the child to actually die stays off this thread, because on every
    /// path but termination nobody is waiting for it and a healthy helper is gone in milliseconds.
    ///
    /// Safe to call from the main actor: `queue` only ever runs short units of work, and both
    /// callbacks out of this class hop with `DispatchQueue.main.async`, so nothing on `queue` can be
    /// blocked waiting for the thread calling in here.
    func stop() {
        guard let task = queue.sync(execute: tearDown) else { return }

        // SIGTERM is what the adapter documents as "stop streaming", and a healthy helper is gone
        // before this closure is even scheduled. The escalation exists for the case it is not: a
        // Perl blocked inside a framework call ignores SIGTERM indefinitely, and §9's "no child
        // process left behind" is not satisfied by a signal that was merely sent.
        let boxed = Unchecked(task)
        reapQueue.async { boxed.value.waitUntilExit() }
        reapQueue.asyncAfter(deadline: .now() + Self.terminationGrace) {
            guard boxed.value.isRunning else { return }
            kill(boxed.value.processIdentifier, SIGKILL)
        }
    }

    /// `stop()`, but does not return until the child is gone. For `applicationWillTerminate` only.
    ///
    /// The escalation here is synchronous and on a much shorter fuse than `stop()`'s, because the
    /// process this runs in is about to call `exit()` and every deadline it sets goes with it. A
    /// helper that has not honored SIGTERM within `quitGrace` is one that never will inside the
    /// time we have, so it is killed rather than waited for.
    ///
    /// Blocking the main thread on quit is the trade, deliberately: the alternative is the app
    /// exiting first, which is precisely the bug. In practice it costs a millisecond or two — the
    /// helper is normally gone on the first poll.
    func stopAndWait() {
        guard let task = queue.sync(execute: tearDown) else { return }

        let deadline = Date().addingTimeInterval(Self.quitGrace)
        while task.isRunning, Date() < deadline {
            // Polled rather than `waitUntilExit()` *here*, because that call cannot be given a
            // deadline: a helper wedged inside a framework call would park the quit indefinitely,
            // and an app that will not quit is worse than the leak this fixes.
            usleep(2000)
        }
        if task.isRunning { kill(task.processIdentifier, SIGKILL) }

        // Unconditional, and it is what makes the postcondition worth stating: on return the child
        // is not merely signalled but reaped. Immediate when the helper has already exited, and
        // prompt after SIGKILL, which cannot be caught or ignored. Without it the caller could still
        // see a zombie — `kill(pid, 0)` succeeds against one — and "no child process left behind"
        // would again be true only on paper.
        task.waitUntilExit()
    }

    /// Detaches everything and signals the child, returning the task that still needs reaping.
    ///
    /// **On `queue`, and the order within it is the point.** Handlers come off *before* the signal,
    /// because a handler that fires on the EOF caused by our own `terminate()` would re-enter a
    /// half-dismantled reader; and `terminationHandler` comes off before that, or the death we just
    /// caused is reported as the helper having failed and the provider retires a route that is
    /// working fine.
    ///
    /// Returns nil when there is nothing left to wait for — no child, or one that has already
    /// exited — so both callers can treat "nil" as "done".
    private func tearDown() -> Process? {
        outHandle?.readabilityHandler = nil
        errHandle?.readabilityHandler = nil
        outHandle = nil
        errHandle = nil

        // The control channel goes with them. Closing it gives the helper EOF on stdin, which the
        // fork treats as "no more control lines" and explicitly **not** as a reason to stop — the
        // SIGTERM below is what stops it. Closed here rather than left to ARC because a file
        // descriptor held open past teardown is a descriptor leaked per display reconfiguration.
        try? controlHandle?.close()
        controlHandle = nil

        guard let task = process else { return nil }
        process = nil
        task.terminationHandler = nil
        decoder.reset()
        buffer.removeAll(keepingCapacity: false)
        errorText.removeAll(keepingCapacity: false)
        publishedQueue.removeAll(keepingCapacity: false)

        guard task.isRunning else { return nil }
        task.terminate()
        return task
    }

    // MARK: - On `queue`

    private func ingest(_ data: Data) {
        buffer.append(data)

        // Newline framing, and a pipe read is not a line: a single `availableData` can hand back
        // three payloads and half of a fourth. Parsing whatever arrived would drop the half and, on
        // a diff stream, permanently desynchronize the merged state from the player.
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            let update = decoder.decode(line: line)
            // The queue is checked whatever the line said, and **before** the update is forwarded.
            //
            // Whatever the line said, because a `{"type":"queue"}` line with no track reported yet
            // decodes to nil — silence, not a verdict — and it still carries a window worth
            // publishing. Before, because the update is what puts the track on the island: pushing
            // the rows first means the surface that lists them is correct on the frame the title
            // changes rather than one hop behind it.
            publishQueueIfChanged()
            guard let update else { continue }
            onUpdate(update)
        }
    }

    private func publishQueueIfChanged() {
        guard let onQueue else { return }
        let items = decoder.queueItems
        guard items != publishedQueue else { return }
        publishedQueue = items
        onQueue(items)
    }

    private func absorbError(_ data: Data) {
        errorText.append(data)
        if errorText.count > Self.maxErrorBytes {
            errorText.removeFirst(errorText.count - Self.maxErrorBytes)
        }
    }

    private func finish(status: Int32) {
        // `process` is nil only when `stop()` got here first, in which case this death is ours and
        // the provider has already been told.
        guard process != nil else { return }
        process = nil
        outHandle?.readabilityHandler = nil
        errHandle?.readabilityHandler = nil
        outHandle = nil
        errHandle = nil
        try? controlHandle?.close()
        controlHandle = nil
        decoder.reset()
        // The list goes with the route. A queue left on screen after the helper died would be a
        // surface the user can scroll and double-click, acting on a player nothing is reading.
        publishedQueue.removeAll(keepingCapacity: false)
        onQueue?([])

        let text = String(data: errorText, encoding: .utf8) ?? ""
        onEnd(.exited(status: status, stderr: text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
}

/// Carries a reference across a `@Sendable` boundary the compiler cannot reason about.
///
/// Used for exactly one thing: handing a `Process` to the reaping closures. `Process` is not
/// `Sendable` and will not become so, but `terminate()`, `isRunning`, `processIdentifier` and
/// `waitUntilExit()` are safe to call from another thread — they are thin wrappers over `kill` and
/// `waitpid`. Confined to this file so it cannot become a general-purpose way of silencing the
/// checker.
private struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
