import Darwin
import Foundation

/// Running a system tool with a deadline, inside the conversion worker.
///
/// Small on purpose: this is not a general process abstraction, it is the two guarantees the
/// conversion routes need and nothing else.
///
/// **A hard deadline**, because `qlmanage -t` **never returns** — killed at 20 s and again at 30 s
/// on the same file — and a worker blocked forever is a worker the parent has to notice and kill,
/// which is a slower and less specific version of the same fix.
///
/// **No output is read**, and that is deliberate rather than lazy. `qlmanage -p` prints
/// `EXCEPTION TCMessageException: (null)` and "did not produce any preview" and then **exits 0**, so
/// neither its stderr nor its status says anything about whether it worked. Every caller here judges
/// the tool on whether a file appeared. Both streams go to `/dev/null` so a chatty tool cannot fill
/// a pipe nobody is draining and block on the write — which is the way this class of helper usually
/// hangs.
///
/// The wait is a poll, and that is allowed here for the reason §9's rule is written the way it is:
/// this runs in a short-lived child process that exists to do exactly this work and then exit.
/// Nothing in Isleta's own process is polling, and nothing here survives the job.
enum Subprocess {

    struct Result {

        /// The process exited on its own, inside the deadline. False means it was killed, which is
        /// the only answer that matters — the exit code is not evidence of anything (see above).
        let finished: Bool

        let status: Int32
    }

    static func run(_ executable: URL, arguments: [String], timeout: TimeInterval) -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return Result(finished: false, status: -1)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(20_000)
        }

        guard !process.isRunning else {
            process.terminate()
            // The same escalation `NowPlayingAdapterReader` uses and for the same reason: SIGTERM is
            // the polite ask, and a tool wedged inside a framework call will not honor it.
            let grace = Date().addingTimeInterval(0.25)
            while process.isRunning, Date() < grace { usleep(10_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            return Result(finished: false, status: process.terminationStatus)
        }

        process.waitUntilExit()
        return Result(finished: true, status: process.terminationStatus)
    }
}
