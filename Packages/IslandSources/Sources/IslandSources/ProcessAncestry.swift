import AppKit
import Darwin

/// Which application a process is running under — the terminal a command-line program was started
/// in.
///
/// Walks the parent chain with `sysctl(KERN_PROC_PID)` until it reaches a process that is a regular
/// application. Public and unprivileged for processes of the same user, and no Accessibility grant:
/// nothing here looks at a window. A `claude` in Terminal is `claude → zsh → login → Terminal`, and
/// the hook probe confirmed the first link (`docs/PLATFORM-CONSTRAINTS.md`).
///
/// **Under tmux the chain ends at the tmux server**, whose parent is launchd, so the answer is nil
/// and the island draws the generic terminal glyph and a click raises nothing. That is a known
/// limit rather than a bug: which client window is attached to the session is tmux's to know.
enum ProcessAncestry {

    /// How far up to look before giving up. A terminal is three or four links above a shell
    /// command; the cap only exists so a cycle in a corrupt answer cannot spin.
    static let maximumDepth = 16

    static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 1 ? parent : nil
    }

    /// The first regular application above `pid`, or nil.
    @MainActor
    static func owningApplication(of pid: pid_t) -> NSRunningApplication? {
        var current = pid
        for _ in 0..<maximumDepth {
            guard let next = parent(of: current) else { return nil }
            if let app = NSRunningApplication(processIdentifier: next), app.activationPolicy == .regular {
                return app
            }
            current = next
        }
        return nil
    }

    /// The executable `pid` is running, or nil if it has gone or is not the user's to ask about.
    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Whether `pid` is still running. `EPERM` counts — the process exists and belongs to somebody
    /// else, which for a recycled pid is exactly the case the caller also has to rule out by name.
    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
