import Darwin
import Foundation
import IslandActivities
import IslandKit

/// The parent's side of the conversion worker: spawn, read, and — the half that matters — reap.
///
/// ## Teardown is synchronous, and the reason is measured rather than theoretical
///
/// `applicationWillTerminate` returns straight into `exit()`, so teardown that is merely *scheduled*
/// never happens. `NowPlayingAdapterReader` cost a milestone to learn that: its `stop()` did all of
/// its work inside `queue.async`, which is correct on every path but that one — the block was still
/// queued when the process died, SIGTERM was never sent, and an ordinary Quit orphaned the helper
/// **every single time**, nineteen of them found alive on a development machine with the oldest
/// twelve hours old. Nothing inside the app can see that; only the process table shows it.
///
/// So `stopAndWait()` does not return until every worker is gone, and the SIGKILL escalation is a
/// wall-clock wait rather than something handed to a queue.
///
/// The residual risk is the same one, and it is closed on the way up rather than on the way down: if
/// Isleta is *killed* rather than quit, its workers survive — macOS has no `PROC_PDEATHSIG` and a
/// SIGKILLed process cannot send SIGTERM — so `FileActionOrphans.sweep` collects them at the next
/// launch. That matters more here than it does for `perl`: a stranded worker mid-H.264-export is
/// holding four hundred megabytes.
@MainActor
public final class FileActionRunner {

    /// What a job reports back, in the order it arrives.
    public enum Report: Sendable {
        case progress(Double)
        case produced(URL)
        case failed(String)

        /// The worker exited. `producedAnything` is the coarse backstop for a worker that died with
        /// nothing to say — a crash inside a framework, or a kill — which no event can describe.
        case ended(producedAnything: Bool)
    }

    private var jobs: [ActivityID: Job] = [:]

    public init() {}

    /// Whether anything is running. Read by the app shell before it decides a quit needs to wait.
    public var isBusy: Bool { !jobs.isEmpty }

    /// Spawns a worker for one request.
    ///
    /// - Parameter executable: this app's own binary — `Bundle.main.executableURL`. Passed in rather
    ///   than reached for so the seam exists: a test can point this at a stub that speaks the same
    ///   line protocol, which is the only way to exercise spawn, framing and teardown without doing
    ///   a real conversion.
    ///
    /// Returns false if the worker could not be launched at all, in which case nothing is reported
    /// and the caller owns the failure.
    @discardableResult
    public func start(
        id: ActivityID,
        request: FileConversionRequest,
        executable: URL,
        report: @escaping @MainActor (ActivityID, Report) -> Void
    ) -> Bool {
        guard jobs[id] == nil else { return false }
        guard let payload = try? JSONEncoder().encode(request) else { return false }

        let process = Process()
        process.executableURL = executable
        process.arguments = [FileActionWorker.flag]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        // Anything the frameworks decide to print goes nowhere. It is not a channel — the worker's
        // only channel is stdout — and an undrained pipe is a worker blocked on a write.
        process.standardError = FileHandle.nullDevice

        let job = Job(process: process, output: output)
        jobs[id] = job

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            // Foundation serializes this handler per file handle, so the buffer is confined to one
            // queue and the parsing happens here rather than on the main thread — the same division
            // `NowPlayingAdapterReader` keeps, and for the same reason: the decoder's partial-line
            // state must not live somewhere teardown cannot fence against.
            for event in job.consume(data) {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.jobs[id] != nil else { return }
                        switch event {
                        case .progress(let fraction): report(id, .progress(fraction))
                        case .produced(let path): report(id, .produced(URL(fileURLWithPath: path)))
                        case .failed(let reason): report(id, .failed(reason))
                        }
                    }
                }
            }
        }

        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let job = self.jobs[id] else { return }
                    self.jobs[id] = nil
                    job.close()
                    report(id, .ended(producedAnything: job.producedAnything))
                }
            }
        }

        do {
            try process.run()
        } catch {
            jobs[id] = nil
            job.close()
            return false
        }

        // The request, then EOF. The worker reads to the end before it does anything, so closing is
        // part of the request rather than tidiness.
        input.fileHandleForWriting.write(payload)
        try? input.fileHandleForWriting.close()
        return true
    }

    /// Ends one job early — the user closed the island on it, or asked again for something else.
    public func cancel(_ id: ActivityID) {
        guard let job = jobs[id] else { return }
        jobs[id] = nil
        job.end(grace: Self.quitGrace)
        job.close()
    }

    /// Ends every worker, **and does not return until they are gone**.
    ///
    /// Called from `applicationWillTerminate`. See the note on the type.
    public func stopAndWait() {
        let running = jobs
        jobs.removeAll()
        guard !running.isEmpty else { return }
        for (_, job) in running { job.end(grace: Self.quitGrace) }
        for (_, job) in running { job.close() }
        IslandLog.shelf.info("file worker(s) stopped on quit: \(running.count)")
    }

    /// How long SIGTERM is given before SIGKILL while the user waits on a quit.
    ///
    /// A quarter of a second, the same figure `NowPlayingAdapterReader.quitGrace` uses and for the
    /// same question — not "has this wedged" but "can I quit yet". A worker mid-export is killed
    /// rather than allowed to hold the quit open; the file it was writing is incomplete, and it is
    /// in the user's folder under a name nothing else has, which is the least bad of the three
    /// available outcomes.
    private static let quitGrace: TimeInterval = 0.25

    /// One running worker. `@unchecked Sendable` on the same basis as `NowPlayingAdapterReader`:
    /// `Process`, `Pipe` and `FileHandle` all predate `Sendable`, the buffer is touched only on the
    /// read handler's queue, and the lifecycle calls are all main-actor.
    private final class Job: @unchecked Sendable {

        let process: Process
        private let output: Pipe
        private var buffer = Data()
        private let lock = NSLock()
        private var produced = false

        init(process: Process, output: Pipe) {
            self.process = process
            self.output = output
        }

        var producedAnything: Bool {
            lock.lock()
            defer { lock.unlock() }
            return produced
        }

        /// Newline-delimited JSON, held until the newline arrives. A pipe splits wherever it likes,
        /// and a half-line parsed as a whole one is a dropped event at best.
        func consume(_ data: Data) -> [FileConversionEvent] {
            lock.lock()
            buffer.append(data)
            var lines: [Data] = []
            while let index = buffer.firstIndex(of: 0x0A) {
                lines.append(buffer[buffer.startIndex..<index])
                buffer.removeSubrange(buffer.startIndex...index)
            }
            lock.unlock()

            let decoder = JSONDecoder()
            var events: [FileConversionEvent] = []
            for line in lines where !line.isEmpty {
                guard let event = try? decoder.decode(FileConversionEvent.self, from: line) else {
                    // A line that does not parse is dropped rather than treated as a truncated
                    // success. Nothing downstream can act on half an event.
                    continue
                }
                if case .produced = event {
                    lock.lock()
                    produced = true
                    lock.unlock()
                }
                events.append(event)
            }
            return events
        }

        func end(grace: TimeInterval) {
            guard process.isRunning else { return }
            process.terminate()
            let deadline = Date().addingTimeInterval(grace)
            while process.isRunning, Date() < deadline { usleep(5_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            // Through to the reap. `kill(pid, 0)` succeeds against a zombie, so signalling is not
            // the same as collecting, and a test that only asserts the former passes over a process
            // table full of defunct children.
            process.waitUntilExit()
        }

        func close() {
            output.fileHandleForReading.readabilityHandler = nil
            try? output.fileHandleForReading.close()
        }
    }
}
