import Darwin
import Foundation
import IslandKit

/// Freezes `OSDUIHelper` so Apple's volume HUD cannot draw, and thaws it again.
///
/// # Why this exists when consuming the key was supposed to be enough
///
/// Consuming a volume key at `.cghidEventTap` **does** stop the key reaching the system — measured
/// 2026-08-30, five presses moving nothing with no HUD. That measurement was correct and the
/// conclusion drawn from it was not, because the feature has a step the measurement did not: once
/// Isleta swallows the key it has to *write* the level itself, and **the CoreAudio write is what
/// wakes the helper**. The HUD follows the level change, not the keypress.
///
/// The obvious escape is a write that does not wake it. There is none on this hardware: the default
/// output publishes `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` and **no per-channel
/// `VolumeScalar` at all** (measured — `ch1 present: false`, `ch2 present: false`), so there is
/// exactly one writable level property and it is the one that draws.
///
/// So the helper itself has to be stopped. `SIGSTOP` freezes it in place: it cannot draw, it keeps
/// its process and its ports, and `SIGCONT` puts it back exactly as it was. That is the mechanism
/// the reference implementation in `~/Sites/Atoll` uses, and it is better than the four
/// `SystemHUDSuppression` rejected — no flicker, no launchd override database write, no
/// `defaults write`.
///
/// # What it costs, stated plainly because it is a rule this repository otherwise holds
///
/// **A `SIGSTOP` outlives the process that sent it.** CLAUDE.md requires suppression to be restored
/// on quit *and on crash and uninstall*, and this cannot meet the second half: a force-quit or a
/// panic leaves the helper frozen, and the user has no volume HUD with nothing on screen naming the
/// app that took it. The owner accepted that trade knowingly on 2026-08-30; it is written down here
/// rather than smoothed over, because the next person to read this file should be able to reverse
/// the decision without rediscovering the reason for it.
///
/// Three things narrow the exposure as far as it can be narrowed:
///
/// - **`repairAtLaunch()` runs unconditionally, before anything decides whether to suppress.** Every
///   launch thaws the helper first. A crash therefore costs the user their HUD only until Isleta
///   next starts, rather than until they log out.
/// - **`resume()` is synchronous.** Atoll records the trap and it is a real one: a detached `Task`
///   never runs to completion when the process is already terminating, so an asynchronous thaw in a
///   termination handler leaves the helper frozen forever. Nothing here is asynchronous.
/// - **Nothing polls.** Atoll re-freezes respawns from a 150 ms–1 s watcher, which is precisely the
///   idle-path cost §9 forbids. Isleta checks instead at the one moment it already knows a HUD is
///   about to be wanted — the key press it is handling — which is a user action rather than a clock.
///   See `ensureSuspended()`.
///
/// # No subprocesses
///
/// Atoll shells out to `killall`, and its own comment measures the alternative it settled on for
/// *reading* the PID: `pgrep` costs 67 ms of wall time and ~5 ms of CPU per call against 0.6 ms for
/// `proc_listpids`. The same argument applies to the signal — `kill(2)` is a syscall, and forking a
/// process to send a signal on the path of a keypress would put a fork on the volume key.
@MainActor
public enum SystemOSDSuppressor {

    /// The helper's process name, as `proc_name` reports it.
    private static let helperName = "OSDUIHelper"

    /// The PID this process most recently froze, so a respawn is recognisable.
    ///
    /// macOS jetsam-exits the helper when it has been idle (`JETSAM_REASON_MEMORY_IDLE_EXIT`) and
    /// launchd spawns a **fresh** one on the next level change. A frozen PID that no longer exists
    /// tells us nothing about the new one, which is why this is compared rather than trusted.
    private static var frozenPID: pid_t?

    /// Whether Isleta currently intends the helper to be frozen. Read by `ensureSuspended`, which is
    /// otherwise a no-op — it must never freeze the helper for a user who did not ask.
    public private(set) static var isSuppressing = false

    /// Whether the screen is locked, in which case the helper is thawed regardless of `isSuppressing`.
    private static var isScreenLocked = false

    // MARK: - The three entry points

    /// Thaw whatever a previous run may have left frozen. **Call unconditionally at launch**, before
    /// reading any setting.
    ///
    /// This is the whole of the crash mitigation. It is deliberately not conditional on the user's
    /// setting: somebody who turned suppression on, crashed, and then turned it *off* still needs
    /// their HUD back, and a repair that only runs when the feature is enabled would never reach
    /// them.
    public static func repairAtLaunch() {
        guard let pid = helperPID() else { return }
        // No state to consult and nothing to report: SIGCONT to a process that was never stopped is
        // a no-op, so this is safe to run on every launch on every Mac.
        if kill(pid, SIGCONT) == 0 {
            IslandLog.system.info("osd helper thawed at launch (repair)")
        }
    }

    /// Freeze the helper and remember that we mean it to stay frozen.
    public static func suspend() {
        isSuppressing = true
        // Not if the screen is locked — the unlock will freeze it. A user who turns the switch on
        // from a settings window they cannot see is not a real case, but the guard costs a branch
        // and keeps `isScreenLocked` the single answer to "may the helper be frozen right now".
        guard !isScreenLocked else { return }
        freezeIfNeeded(reason: "suppression enabled")
    }

    /// Thaw the helper and stop meaning it.
    ///
    /// **Synchronous, and it must stay synchronous.** This runs from `applicationWillTerminate`,
    /// where a `Task` would be scheduled onto a run loop that never turns again. Idempotent, so a
    /// termination path that calls it twice — or one that calls it having never suspended — is fine.
    public static func resume() {
        isSuppressing = false
        thaw(reason: "suppression ended")
    }

    /// SIGCONT and forget the PID. Shared by `resume()` and the lock path, which want the same
    /// action and mean different things by it — one ends the user's intent, the other suspends it.
    private static func thaw(reason: String) {
        guard let pid = helperPID() else {
            frozenPID = nil
            return
        }
        if kill(pid, SIGCONT) == 0 {
            IslandLog.system.info("osd helper thawed (\(reason))")
        }
        frozenPID = nil
    }

    /// Hand Apple its HUD back for as long as the screen is locked, and take it again on unlock.
    ///
    /// **Found on hardware, 2026-08-30, and it is the worst state this feature can produce.** On the
    /// lock screen `loginwindow` captures every event, so Isleta's tap receives nothing and cannot
    /// replace a key; its panels are off screen, so it cannot draw one either. With Apple's helper
    /// still frozen, a volume or brightness key at the login window would change the level and show
    /// **nothing at all** — no Isleta HUD and no Apple HUD, from a Mac that had both a minute
    /// earlier. That is worse than either alternative, and it is invisible from a running session
    /// because it only happens where Isleta cannot see.
    ///
    /// So suppression is suspended for the length of the lock. `isSuppressing` is deliberately left
    /// alone: the user's intent has not changed, only the screen, and conflating the two would make
    /// an unlock look like a fresh opt-in.
    public static func screenLockDidChange(locked: Bool) {
        guard locked != isScreenLocked else { return }
        isScreenLocked = locked
        guard isSuppressing else { return }
        if locked {
            thaw(reason: "screen locked")
        } else {
            freezeIfNeeded(reason: "screen unlocked")
        }
    }

    /// Re-freeze the helper if launchd has spawned a new one. **The event-driven replacement for
    /// Atoll's watcher.**
    ///
    /// Called from the volume-key handler *before* the CoreAudio write, which is the one moment that
    /// matters: the write is what would wake the helper, so a helper frozen a microsecond earlier
    /// cannot draw. There is no timer and nothing on the idle path, which is what §9 requires and
    /// what a 150 ms poll for the life of the app would violate.
    ///
    /// **The gap this leaves, stated so nobody has to find it:** a level change from somewhere other
    /// than a key — Control Center, a slider in Music, `osascript` — can draw Apple's HUD if the
    /// helper happened to respawn since the last key press. Suppression is therefore not absolute.
    /// It is complete for the case it was asked for, and the alternative is a poll.
    public static func ensureSuspended() {
        // Not while locked, for `screenLockDidChange`'s reason — though in practice the tap receives
        // nothing there, so this is belt and braces rather than the load-bearing guard.
        guard isSuppressing, !isScreenLocked else { return }
        freezeIfNeeded(reason: "respawn")
    }

    // MARK: -

    private static func freezeIfNeeded(reason: String) {
        guard let pid = helperPID() else {
            // Nothing running to freeze. **Not an error and not worth forcing one into existence**:
            // Atoll `launchctl kickstart`s a helper so there is something to stop, which spawns a
            // process in order to freeze it. The next level change will spawn one anyway, and
            // `ensureSuspended` runs before that change.
            frozenPID = nil
            return
        }
        guard pid != frozenPID else { return }
        guard kill(pid, SIGSTOP) == 0 else {
            IslandLog.system.info("osd helper could not be frozen: errno \(errno)")
            return
        }
        frozenPID = pid
        IslandLog.system.info("osd helper frozen (\(reason))")
    }

    /// The newest `OSDUIHelper` PID, or nil.
    ///
    /// `proc_listpids` rather than a `pgrep` subprocess, for the reason Atoll measured: a fork, an
    /// exec, a pipe and a reap cost ~67 ms of wall time against ~0.6 ms for the kernel answering
    /// directly. This runs on the path of a volume keypress, where 67 ms is a visible delay in the
    /// key itself.
    ///
    /// **Newest by start time, not by highest PID.** The two agree until PIDs wrap, and then they
    /// stop agreeing — a distinction inherited from Atoll's own note about `pgrep -n`.
    private static func helperPID() -> pid_t? {
        var byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(byteCount) / MemoryLayout<pid_t>.size)
        byteCount = proc_listpids(
            UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size)
        )
        guard byteCount > 0 else { return nil }

        var newest: pid_t?
        var newestStart: (sec: UInt64, usec: UInt64) = (0, 0)
        var name = [CChar](repeating: 0, count: Int(2 * MAXCOMLEN) + 1)

        for pid in pids.prefix(Int(byteCount) / MemoryLayout<pid_t>.size) where pid > 0 {
            // `String(cString:)` is deprecated and `Tools/check.sh` builds with
            // `-warnings-as-errors`, so the null terminator is trimmed by hand. `proc_name` writes a
            // C string into the buffer and leaves the tail as it found it, which is why the prefix
            // has to stop at the first zero rather than decoding the whole array.
            guard proc_name(pid, &name, UInt32(name.count)) > 0 else { continue }
            let processName = String(
                decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self
            )
            guard processName == helperName else { continue }
            var info = proc_bsdinfo()
            let size = proc_pidinfo(
                pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)
            )
            guard size == Int32(MemoryLayout<proc_bsdinfo>.size) else { continue }
            let start = (sec: UInt64(info.pbi_start_tvsec), usec: UInt64(info.pbi_start_tvusec))
            if newest == nil || start > newestStart {
                newest = pid
                newestStart = start
            }
        }
        return newest
    }
}
