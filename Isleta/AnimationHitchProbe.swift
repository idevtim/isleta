#if DEBUG
import AppKit
import IslandKit
import QuartzCore

/// Frame intervals for the island's own window, so a stutter can be measured instead of described.
///
/// **Why this exists rather than Instruments.** The SwiftUI instrument reports 100 ms bursts of work
/// for every island transition, and almost all of it is the instrument: it takes a `backtrace()` per
/// attribute modify, and the same interaction profiled with the plain Time Profiler costs a few
/// milliseconds. The Time Profiler has the opposite blind spot — it samples the main thread only
/// while it is *on CPU*, so a stall spent waiting on the window server, a lock or a file write
/// produces no samples at all and reads as "nothing happened". Neither instrument answers the only
/// question that matters here, which is whether frames were delivered on time.
///
/// A display link does. It fires once per frame on the display the panel is on, so a missed frame is
/// a gap in its own callbacks — the same thing the user sees.
///
/// `#if DEBUG` and behind `--hitch-probe`, because it is a display link that never stops, which is
/// exactly what §9 forbids on the idle path.
@MainActor
final class AnimationHitchProbe {

    static let isRequested = ProcessInfo.processInfo.arguments.contains("--hitch-probe")
        || ProcessInfo.processInfo.arguments.contains("--hitch-test")

    private var link: CADisplayLink?
    private var last: CFTimeInterval?

    /// One report per burst of dropped frames, rather than one line per frame: a stutter is a run of
    /// late frames and the interesting numbers are how long the run was and how late the worst one.
    private var runStart: CFTimeInterval?
    private var runFrames = 0
    private var runWorst: Double = 0
    private var lastLate: CFTimeInterval?

    /// One measured stretch of frames, opened by `beginWindow` and closed by `endWindow`.
    ///
    /// The burst log above answers "did something stutter just now" for a human watching the island;
    /// this answers "how many frames did *this* animation drop", which is the only form the question
    /// can take when nobody is watching. `HitchSelfTest` opens one window per transition it drives.
    struct Measurement {
        let label: String
        /// Display-link callbacks seen while the window was open, late ones included.
        var frames = 0
        /// Frames the user did not get: for each late callback, how many whole intervals it swallowed.
        var dropped = 0
        /// How many *separate* late callbacks made up `dropped`. One long stall and a run of small
        /// ones drop the same number of frames and have entirely different causes.
        var lateEvents = 0
        /// The longest gap between two callbacks, in seconds.
        var worstGap: Double = 0
        /// How far into the window the first late callback arrived, in seconds. A stall in the first
        /// frame or two is the content being built; one in the middle is the animation itself.
        var firstLateOffset: Double = -1
        /// The frame budget the display was running at when the window closed, in seconds.
        var budget: Double = 0
        /// Wall-clock length of the window, in seconds.
        var elapsed: Double = 0
    }

    private var measurement: Measurement?
    private var measurementStart: CFTimeInterval?

    /// Whether the display link is running. False when the probe was not asked for, and when there
    /// was no island window to attach to — which a measurement of zero frames would otherwise look
    /// exactly like.
    var isAttached: Bool { link != nil }

    func start(controller: IslandController) {
        guard Self.isRequested, link == nil else { return }
        guard let info = controller.debugInfo().first,
              let window = NSApp.window(withWindowNumber: info.windowNumber),
              let view = window.contentView
        else {
            IslandLog.app.info("hitch probe: no island window to attach to")
            return
        }
        let link = view.displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
        IslandLog.app.info("hitch probe: attached to window #\(info.windowNumber)")
    }

    /// Starts counting frames against `label`. A window already open is discarded, so a driver that
    /// gives up on a step cannot leak its frames into the next one.
    func beginWindow(_ label: String) {
        measurement = Measurement(label: label)
        measurementStart = CACurrentMediaTime()
    }

    func endWindow() -> Measurement? {
        guard var measurement, let measurementStart else { return nil }
        measurement.elapsed = CACurrentMediaTime() - measurementStart
        self.measurement = nil
        self.measurementStart = nil
        return measurement
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        defer { last = now }
        guard let last else { return }

        let expected = max(1.0 / 240, link.targetTimestamp - link.timestamp)
        let interval = now - last
        // Half a frame of slack: a display link's own jitter is a fraction of a frame, and anything
        // past 1.5 intervals means a frame the user did not get.
        let isLate = interval > expected * 1.5

        // Copied out and put back rather than mutated in place: reading `measurement?.worstGap`
        // inside an assignment to it is an exclusivity violation, and one the compiler catches.
        if var open = measurement {
            open.frames += 1
            open.budget = expected
            if isLate {
                open.dropped += Int((interval / expected).rounded()) - 1
                open.lateEvents += 1
                if open.firstLateOffset < 0, let start = measurementStart {
                    open.firstLateOffset = now - start
                }
                open.worstGap = max(open.worstGap, interval)
            }
            measurement = open
        }

        guard isLate else {
            closeRun(expected: expected)
            return
        }

        if runStart == nil { runStart = now }
        runFrames += Int((interval / expected).rounded()) - 1
        runWorst = max(runWorst, interval)
        lastLate = now
    }

    /// A run ends once a quarter-second of on-time frames has gone by, so one stutter is reported
    /// once rather than per late frame.
    private func closeRun(expected: Double) {
        guard let runStart, let lastLate, CACurrentMediaTime() - lastLate > 0.25 else { return }
        IslandLog.app.info(
            "hitch: \(runFrames) frame(s) dropped over \(String(format: "%.0f", (lastLate - runStart) * 1000 + expected * 1000)) ms"
            + ", worst gap \(String(format: "%.1f", runWorst * 1000)) ms"
            + " (frame budget \(String(format: "%.1f", expected * 1000)) ms)"
        )
        self.runStart = nil
        self.lastLate = nil
        runFrames = 0
        runWorst = 0
    }

    func stop() {
        link?.invalidate()
        link = nil
    }
}
#endif
