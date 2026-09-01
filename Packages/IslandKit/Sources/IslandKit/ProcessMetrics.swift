import Darwin
import Foundation

/// Self-measurement for the §9 performance budget.
///
/// Sampling our own task via Mach beats shelling out to `top`: `top`'s CPU column resolves to
/// roughly 0.1%, and the idle budget is 0.3%, so a `top` reading of "0.0%" cannot distinguish
/// compliance from a threefold overshoot. Mach thread times are microsecond-resolution, so a
/// 60-second window resolves to well under 0.001%.
public enum ProcessMetrics {

    /// Total CPU time consumed by this process, live and terminated threads combined.
    ///
    /// `TASK_BASIC_INFO` only accounts for threads that have already exited, so a long-lived agent
    /// app reads as zero unless `TASK_THREAD_TIMES_INFO` is added for the live ones.
    public static func cpuTime() -> TimeInterval? {
        var basicInfo = task_basic_info()
        var basicCount = mach_msg_type_number_t(MemoryLayout<task_basic_info>.size / MemoryLayout<natural_t>.size)
        let basicStatus = withUnsafeMutablePointer(to: &basicInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_BASIC_INFO), $0, &basicCount)
            }
        }
        guard basicStatus == KERN_SUCCESS else { return nil }

        var threadInfo = task_thread_times_info()
        var threadCount = mach_msg_type_number_t(MemoryLayout<task_thread_times_info>.size / MemoryLayout<natural_t>.size)
        let threadStatus = withUnsafeMutablePointer(to: &threadInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(threadCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), $0, &threadCount)
            }
        }
        guard threadStatus == KERN_SUCCESS else { return nil }

        func seconds(_ t: time_value_t) -> TimeInterval {
            TimeInterval(t.seconds) + TimeInterval(t.microseconds) / 1_000_000
        }
        return seconds(basicInfo.user_time) + seconds(basicInfo.system_time)
            + seconds(threadInfo.user_time) + seconds(threadInfo.system_time)
    }

    /// Physical footprint in bytes — the number Activity Monitor shows as "Memory".
    public static func residentMemory() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
    }

    /// Wall-clock time since the kernel created this process.
    ///
    /// Measured from `kp_proc.p_starttime` rather than from a timestamp taken in `main`, so the
    /// cold-launch figure includes dyld, framework loading and everything else that happens before
    /// any of our code runs — which is most of a Swift app's launch cost.
    public static func timeSinceProcessStart() -> TimeInterval? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let status = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard status == 0 else { return nil }

        let start = info.kp_proc.p_starttime
        let startSeconds = TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000
        return Date().timeIntervalSince1970 - startSeconds
    }
}

/// A CPU-usage sample taken across a window, for the debug overlay's live readout.
public struct CPUSample: Sendable {
    public let cpuSeconds: TimeInterval
    public let wallSeconds: TimeInterval

    public init(cpuSeconds: TimeInterval, wallSeconds: TimeInterval) {
        self.cpuSeconds = cpuSeconds
        self.wallSeconds = wallSeconds
    }
    public var percent: Double {
        wallSeconds > 0 ? (cpuSeconds / wallSeconds) * 100 : 0
    }
}
