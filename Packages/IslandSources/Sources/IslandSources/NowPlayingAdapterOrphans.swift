import Darwin
import Foundation

/// Clears `mediaremote-adapter` helpers stranded by a previous run of *this* app bundle.
///
/// `NowPlayingAdapterReader` closes the leak on every path it can reach: a quit tears the helper
/// down and waits for it. The path it cannot reach is a crash — macOS does not kill a child when its
/// parent dies, and a SIGKILLed process cannot send SIGTERM — so one `perl` per crash survives,
/// reparented to launchd, until the user next reboots. This is the other half: on the way up, look
/// for the ones a previous run left behind and end them.
///
/// ## The identification rules are the entire safety argument
///
/// `NowPlayingAdapterReader` carries a warning against "fixing" the leak by killing every `perl`
/// found at launch, and that warning still stands — this is not that. Four conditions must all hold
/// before a pid is signalled, and each rules out a specific way of killing something that is not
/// ours:
///
/// 1. **`argv` contains this bundle's own script path**, byte for byte. Not the file name, and not
///    the subpath. `ungive/mediaremote-adapter` is vendored by other notch apps too, so a match on
///    `mediaremote-adapter.pl` would reach into a competitor's helpers; a match on the *absolute
///    path inside our bundle* cannot, because no other app's helper is running our copy.
/// 2. **`argv[0]` is `/usr/bin/perl`**, the only interpreter this route ever spawns.
/// 3. **The parent is launchd.** This is the load-bearing one: a helper belonging to a *live*
///    Isleta has that instance's pid as its parent, never 1. So no arrangement of running
///    instances — a second copy, a development build beside the installed one, the user launching
///    while the old process is still quitting — can put a live helper in range. Only a process
///    whose owner is already gone qualifies.
/// 4. **Same uid.** Signalling across users would fail with EPERM anyway; refusing to try means the
///    sweep never depends on being denied to be correct.
///
/// Note what is deliberately *not* a condition: the `stream` subcommand. A stranded one-shot `get`
/// from the artwork loader is equally ours and equally dead, and exempting it would leave a class of
/// orphan uncollected for the sake of a tidier rule.
///
/// ## What it cannot do
///
/// It cannot reap. These processes are launchd's children now, so `waitpid` is not ours to call —
/// the sweep signals and confirms with `kill(pid, 0)`, and launchd collects the corpse. That is also
/// why the escalation here is a wall-clock wait rather than `Process.waitUntilExit()`.
public enum NowPlayingAdapterOrphans {

    /// One row of the process table, reduced to the four things the decision needs.
    ///
    /// A plain value so the rule below can be tested against a table nobody had to create by
    /// crashing an app. Every bug this code could have is in *which* pids it picks, and that
    /// question needs no running processes to answer — the same argument that keeps the island's
    /// geometry math AppKit-free.
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

    /// The pid launchd reparents an orphan to. Named rather than written as `1` at the comparison,
    /// because that comparison is the safety property and deserves to say so.
    static let launchdPID: Int32 = 1

    /// How long a stranded helper is given to honor SIGTERM before SIGKILL.
    ///
    /// Longer than the quit path's grace, because nobody is waiting on this one: it runs off the
    /// main thread while the app finishes launching, so the only cost of patience is a background
    /// thread sleeping.
    static let terminationGrace: TimeInterval = 1

    // MARK: - The rule

    /// Which of these processes are this bundle's stranded helpers.
    ///
    /// Pure, and the only place the four conditions are written down. See the type's documentation
    /// for why each one is there; the short version is that dropping any of them turns a sweep of
    /// our own leftovers into a sweep of somebody else's live process.
    public static func reapable(
        from table: [Entry],
        scriptPath: String,
        perlPath: String = NowPlayingAdapterLocation.perlExecutable.path,
        currentUID: uid_t,
        currentPID: Int32
    ) -> [Int32] {
        table.filter { entry in
            entry.pid != currentPID
                && entry.pid > launchdPID
                && entry.parentPID == launchdPID
                && entry.uid == currentUID
                && entry.arguments.first == perlPath
                && entry.arguments.dropFirst().contains(scriptPath)
        }
        .map(\.pid)
    }

    // MARK: - The sweep

    /// Finds and ends this bundle's stranded helpers. Returns the pids it signalled.
    ///
    /// **Call this off the main thread.** It sleeps for up to `terminationGrace` between SIGTERM and
    /// the escalation, and §9 budgets cold launch to visible at 300ms. Nothing depends on the
    /// result, so there is nothing to hop back for.
    @discardableResult
    public static func sweep(
        scriptPath: String,
        table: () -> [Entry] = processTable
    ) -> [Int32] {
        let targets = reapable(
            from: table(),
            scriptPath: scriptPath,
            currentUID: getuid(),
            currentPID: getpid()
        )
        guard !targets.isEmpty else { return [] }

        // SIGTERM first, and not as a courtesy: it is the signal the adapter documents as "stop
        // streaming", and one it honors. SIGKILL is the escalation for a helper wedged inside a
        // framework call, which is the state a crash is most likely to have left it in.
        for pid in targets { kill(pid, SIGTERM) }
        Thread.sleep(forTimeInterval: terminationGrace)
        for pid in targets where kill(pid, 0) == 0 { kill(pid, SIGKILL) }

        return targets
    }

    /// Convenience over a resolved adapter location. Nil location — a build with no adapter
    /// vendored, which is every `check.sh` build — has no helpers to have stranded.
    @discardableResult
    public static func sweep(location: NowPlayingAdapterLocation?) -> [Int32] {
        guard let location else { return [] }
        return sweep(scriptPath: location.scriptURL.path)
    }

    // MARK: - Reading the process table

    /// Every process this sweep might care about, as `Entry` values.
    ///
    /// Two-stage on purpose. `KERN_PROC_ALL` returns the whole table in one call — some hundreds of
    /// rows — and `KERN_PROCARGS2` is a separate syscall *per pid*. Asking every process for its
    /// argument vector at launch would be hundreds of syscalls against a 300ms budget, so the cheap
    /// fields filter first and only the survivors are asked the expensive question. On a normal Mac
    /// that is nought or one process.
    ///
    /// `p_comm` is `MAXCOMLEN + 1` bytes and truncates, which is harmless here: "perl" is four.
    public static func processTable() -> [Entry] {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var length = 0
        guard sysctl(&name, 4, nil, &length, nil, 0) == 0, length > 0 else { return [] }

        // Over-allocate. The table can grow between sizing it and reading it, and the kernel answers
        // a buffer that has become too small with ENOMEM rather than a partial read — so a sweep on
        // a busy machine would silently do nothing at all.
        let slack = length / 4
        var buffer = [UInt8](repeating: 0, count: length + slack)
        var read = buffer.count
        let status = buffer.withUnsafeMutableBytes { raw in
            sysctl(&name, 4, raw.baseAddress, &read, nil, 0)
        }
        guard status == 0 else { return [] }

        let stride = MemoryLayout<kinfo_proc>.stride
        let count = read / stride
        guard count > 0 else { return [] }

        let ourUID = getuid()
        var entries: [Entry] = []
        buffer.withUnsafeBytes { raw in
            for index in 0..<count {
                // `loadUnaligned` because the byte buffer carries no guarantee of `kinfo_proc`'s
                // alignment; `load` would trap.
                let process = raw.loadUnaligned(fromByteOffset: index * stride, as: kinfo_proc.self)
                let pid = process.kp_proc.p_pid
                let parent = process.kp_eproc.e_ppid
                let uid = process.kp_eproc.e_ucred.cr_uid

                // The cheap filter. Everything here is already in hand; only what survives costs a
                // second syscall.
                guard parent == launchdPID, uid == ourUID, pid > launchdPID else { continue }
                guard command(of: process) == perlCommand else { continue }
                guard let arguments = self.arguments(ofPID: pid) else { continue }

                entries.append(
                    Entry(pid: pid, parentPID: parent, uid: uid, arguments: arguments)
                )
            }
        }
        return entries
    }

    /// `p_comm` for `/usr/bin/perl`. The accounting name, which is the executable's leaf.
    private static let perlCommand = "perl"

    private static func command(of process: kinfo_proc) -> String {
        withUnsafeBytes(of: process.kp_proc.p_comm) { raw in
            let bytes = raw.prefix(while: { $0 != 0 })
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    /// One process's argument vector, or nil if the kernel will not say.
    ///
    /// A refusal is completely normal — the process may have exited between the table read and this
    /// call — and is not an error worth reporting. It simply means that pid is not a candidate.
    static func arguments(ofPID pid: Int32) -> [String]? {
        var name: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var length = 0
        guard sysctl(&name, 3, nil, &length, nil, 0) == 0, length > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: length)
        var read = length
        let status = buffer.withUnsafeMutableBytes { raw in
            sysctl(&name, 3, raw.baseAddress, &read, nil, 0)
        }
        guard status == 0 else { return nil }

        return parseProcArgs(Array(buffer.prefix(read)))
    }

    /// Decodes the `KERN_PROCARGS2` blob.
    ///
    /// Pure, because the layout is fiddly enough to get wrong and nothing about verifying it needs a
    /// running process. The shape is: a 32-bit `argc`, then the executable path, then **padding of
    /// an unspecified number of NUL bytes**, then `argc` NUL-terminated arguments. The padding is
    /// the part that catches people — splitting on NUL and taking the first `argc` fields yields a
    /// vector of empty strings on some processes and the right answer on others, depending on how
    /// the kernel happened to align that executable's path.
    static func parseProcArgs(_ bytes: [UInt8]) -> [String]? {
        let headerSize = MemoryLayout<Int32>.size
        guard bytes.count > headerSize else { return nil }

        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0 else { return nil }

        var index = headerSize
        // Step over the executable path, which is not part of argv.
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        // Then over the alignment padding, however much of it there is.
        while index < bytes.count, bytes[index] == 0 { index += 1 }

        var arguments: [String] = []
        arguments.reserveCapacity(Int(argc))
        var start = index
        while index < bytes.count, arguments.count < Int(argc) {
            if bytes[index] == 0 {
                arguments.append(String(decoding: bytes[start..<index], as: UTF8.self))
                start = index + 1
            }
            index += 1
        }
        // A final argument the blob did not terminate — truncated output rather than a real vector.
        guard arguments.count == Int(argc) else { return nil }
        return arguments
    }
}
