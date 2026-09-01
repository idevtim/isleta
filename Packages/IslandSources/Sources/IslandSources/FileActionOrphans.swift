import Darwin
import Foundation

/// Clears conversion workers stranded by a previous run of *this* app bundle.
///
/// `FileActionRunner.stopAndWait()` closes the leak on every path it can reach. The path it cannot
/// reach is a crash: macOS has no `PROC_PDEATHSIG`, and a SIGKILLed process cannot send SIGTERM, so
/// a worker survives its parent, reparented to launchd, until the user reboots. That matters more
/// here than it does for the Now Playing helper — an idle `perl` costs nothing, while a worker
/// stranded mid-export is holding a fixed ~450 MB allocation in the H.264 scaler.
///
/// This is `NowPlayingAdapterOrphans`'s sibling, which CLAUDE.md says the transcription work owes.
/// It is a sibling rather than a shared implementation because that file belongs to another feature
/// and its process-table read is filtered on `p_comm == "perl"` at the point where it is cheapest to
/// filter — generalising it would mean editing it.
///
/// ## The identification rule, and the one condition that is different here
///
/// Four conditions, three of them the same as the adapter's: the parent is **launchd**, the uid is
/// **ours**, and the pid is not us. The fourth is where this differs, and it is the whole safety
/// argument:
///
/// **`argv` must be exactly this executable followed by the worker flag.** For `perl` the flag was
/// optional color; here it is load-bearing, because a *live, ordinary Isleta* — the user's other
/// copy, or the installed one running beside a development build — has the same executable name, the
/// same uid, and launchd as its parent. Without the flag this sweep would quit the user's app. A
/// worker is the only Isleta process that carries `--file-worker`, and a worker belonging to a live
/// parent has that parent's pid rather than 1, so no arrangement of running copies can put a live
/// worker or a live app in range.
///
/// It cannot reap: these are launchd's children now, so `waitpid` is not ours to call. The sweep
/// signals, waits, escalates, and confirms with `kill(pid, 0)`.
public enum FileActionOrphans {

    /// One row of the process table, reduced to what the decision needs. A plain value so the rule
    /// can be tested against a table nobody had to create by crashing an app.
    public struct Entry: Equatable, Sendable {
        public let pid: Int32
        public let parentPID: Int32
        public let uid: uid_t
        public let arguments: [String]

        public init(pid: Int32, parentPID: Int32, uid: uid_t, arguments: [String]) {
            self.pid = pid
            self.parentPID = parentPID
            self.uid = uid
            self.arguments = arguments
        }
    }

    static let launchdPID: Int32 = 1

    /// How long a stranded worker is given to honor SIGTERM. Longer than the quit path's grace,
    /// because nobody is waiting on this one — it runs off the main thread while the app finishes
    /// launching, and the only cost of patience is a background thread sleeping.
    static let terminationGrace: TimeInterval = 1

    // MARK: - The rule

    /// Which of these processes are this bundle's stranded workers.
    ///
    /// Pure, and the only place the four conditions are written down. See the type's documentation
    /// for why the flag check is the one that cannot be dropped.
    public static func reapable(
        from table: [Entry],
        executablePath: String,
        currentUID: uid_t,
        currentPID: Int32
    ) -> [Int32] {
        table.filter { entry in
            entry.pid != currentPID
                && entry.pid > launchdPID
                && entry.parentPID == launchdPID
                && entry.uid == currentUID
                && entry.arguments.first == executablePath
                && entry.arguments.dropFirst().contains(FileActionWorker.flag)
        }
        .map(\.pid)
    }

    // MARK: - The sweep

    /// Finds and ends this bundle's stranded workers. Returns the pids it signalled.
    ///
    /// **Call this off the main thread**: it sleeps for up to `terminationGrace`, and §9 budgets
    /// cold launch to visible at 300 ms. Nothing depends on the result.
    @discardableResult
    public static func sweep(
        executablePath: String,
        table: () -> [Entry] = processTable
    ) -> [Int32] {
        let targets = reapable(
            from: table(),
            executablePath: executablePath,
            currentUID: getuid(),
            currentPID: getpid()
        )
        guard !targets.isEmpty else { return [] }

        for pid in targets { kill(pid, SIGTERM) }
        Thread.sleep(forTimeInterval: terminationGrace)
        for pid in targets where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        return targets
    }

    /// Convenience over this bundle's own executable.
    @discardableResult
    public static func sweep() -> [Int32] {
        guard let executable = Bundle.main.executableURL else { return [] }
        return sweep(executablePath: executable.resolvingSymlinksInPath().path)
    }

    // MARK: - Reading the process table

    /// Every process this sweep might care about.
    ///
    /// Two-stage for the reason the adapter's is: `KERN_PROC_ALL` is one call for the whole table,
    /// and `KERN_PROCARGS2` is a syscall *per pid*. The cheap fields filter first — parent, uid,
    /// and the accounting name, which is `MAXCOMLEN + 1` bytes and truncates harmlessly.
    public static func processTable() -> [Entry] {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var length = 0
        guard sysctl(&name, 4, nil, &length, nil, 0) == 0, length > 0 else { return [] }

        // Over-allocated: the table can grow between sizing and reading, and the kernel answers a
        // buffer that has become too small with ENOMEM rather than a partial read — so a sweep on a
        // busy machine would silently do nothing at all.
        var buffer = [UInt8](repeating: 0, count: length + length / 4)
        var read = buffer.count
        let status = buffer.withUnsafeMutableBytes { raw in
            sysctl(&name, 4, raw.baseAddress, &read, nil, 0)
        }
        guard status == 0 else { return [] }

        let stride = MemoryLayout<kinfo_proc>.stride
        let count = read / stride
        guard count > 0 else { return [] }

        let ourUID = getuid()
        let ourCommand = Bundle.main.executableURL?.lastPathComponent ?? ""
        // The accounting name is truncated to 16 bytes, so compare on the same prefix rather than
        // on the whole leaf — an executable with a longer name would never match itself.
        let truncated = String(ourCommand.prefix(16))
        var entries: [Entry] = []
        buffer.withUnsafeBytes { raw in
            for index in 0..<count {
                // `loadUnaligned` because a byte buffer carries no guarantee of `kinfo_proc`'s
                // alignment; `load` would trap.
                let process = raw.loadUnaligned(fromByteOffset: index * stride, as: kinfo_proc.self)
                let pid = process.kp_proc.p_pid
                let parent = process.kp_eproc.e_ppid
                let uid = process.kp_eproc.e_ucred.cr_uid

                guard parent == launchdPID, uid == ourUID, pid > launchdPID, pid != getpid() else { continue }
                guard command(of: process) == truncated else { continue }
                guard let arguments = NowPlayingAdapterOrphans.arguments(ofPID: pid) else { continue }

                entries.append(Entry(pid: pid, parentPID: parent, uid: uid, arguments: arguments))
            }
        }
        return entries
    }

    private static func command(of process: kinfo_proc) -> String {
        withUnsafeBytes(of: process.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}
