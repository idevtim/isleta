import AppKit
import Foundation
import IslandKit
import IslandSettings
import IslandUI

/// CPU/memory sampling against the §9 budget.
///
/// The idle budget is 0.3% CPU, and the whole design rule behind it is "no polling when idle" — so
/// the sampler must not itself be a timer. In normal operation a baseline is taken once, shortly
/// after launch, and a delta is computed only when someone opens the debug overlay. The single
/// timer in this file exists solely under `--perf-report`, which is a measurement run, not the app.
@MainActor
final class PerformanceProbe {

    private var baselineCPU: TimeInterval?
    private var baselineWall: Date?

    func markBaseline() {
        baselineCPU = ProcessMetrics.cpuTime()
        baselineWall = Date()
    }

    /// How long to wait after the sources start before the idle window opens.
    ///
    /// **The baseline used to be taken at the first frame, and everything the app does next was
    /// charged to a budget that is about steady state.** `recordLaunch()` marks the frame and then,
    /// in the same breath, runs the pass-through self-test, calls `startSources()` and starts
    /// Sparkle — so a `--perf-report` window contained the `perl` helper being spawned, the first
    /// Now Playing snapshot and its artwork decode, the accessibility attach, CoreAudio's first HAL
    /// call and, in whichever runs the interval had elapsed, an update check that touches the
    /// network. One-off work, divided by the window and printed as though the app spent it idling.
    ///
    /// Measured on macOS 27.0 before this existed: the same build reported 3.34 % over an 8s window,
    /// 0.37-0.41 % over 30s and 0.23 % over 50s — a 14× spread in the *percentage* that resolves to
    /// a nearly constant 115-140 ms of CPU once warm. Two independent instruments agreed the process
    /// was idle throughout: `top` read 0.0 % with seven context switches per ten seconds, and 40s of
    /// 1ms sampling caught no user-code stack at all. The startup cost was the whole reading.
    ///
    /// Two seconds because that is what covers the asynchronous tail rather than only the calls that
    /// return: the adapter answers its first `get` in about 135 ms and the artwork re-ask that
    /// follows a skip lands ~130 ms after that, the accessibility attach retries at 500 ms, and the
    /// orphan sweep sleeps a second between SIGTERM and its escalation. It is deliberately not
    /// longer — the window that follows is the measurement, and time spent settling is time the
    /// report is not looking at the app.
    static let settleSeconds: TimeInterval = 2.0

    /// CPU usage since the baseline. Nil until a baseline exists or if the window is too short to
    /// mean anything.
    func sample() -> CPUSample? {
        guard let baselineCPU, let baselineWall,
              let now = ProcessMetrics.cpuTime() else { return nil }
        let wall = Date().timeIntervalSince(baselineWall)
        guard wall > 0.5 else { return nil }
        return CPUSample(cpuSeconds: now - baselineCPU, wallSeconds: wall)
    }

    /// `--perf-report <seconds>`: idle for the given window, print a report, exit. Used to produce
    /// the numbers in PERF.md without leaving a sampler in the shipping path.
    static func reportModeDuration() -> TimeInterval? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--perf-report"),
              index + 1 < arguments.count,
              let seconds = TimeInterval(arguments[index + 1]) else { return nil }
        return seconds
    }

}

/// What the sources were doing when the report was taken.
///
/// A value rather than a live read, so the report cannot be a different snapshot from the CPU sample
/// beside it. Safe to print by construction: `SourceStatus` carries an authorization, two flags and
/// a `detail` built from counts and supported-feature sets, none of which has a field any of the
/// user's own words could reach.
struct SourceReport: Sendable {
    let statuses: [SourceStatus]

    /// True when `--no-sources` was passed, or before the first frame has built them. Reported
    /// explicitly, because an empty list and "sources are off" are the same output otherwise, and
    /// a §9 idle figure means the opposite thing in each case.
    let isDisabled: Bool

    static let none = SourceReport(statuses: [], isDisabled: true)
}

/// Plain-text diagnostics, shared by "Export Logs…", `--perf-report`, and Debug's "Copy Diagnostics".
@MainActor
enum DiagnosticsReport {

    static func text(
        controller: IslandController,
        diagnostics: Diagnostics,
        sources: SourceReport = .none,
        window: TimeInterval? = nil
    ) -> String {
        // Version and build, read from the bundle rather than written here — this string said
        // "Milestone 0" for four milestones. The **build** number appears in this report and
        // nowhere in the interface, which is the whole argument for hiding it in Settings: it is
        // what tells two copies of one release apart, so it belongs where somebody is diagnosing a
        // difference between them rather than beside a version number a user cannot act on.
        var lines: [String] = [
            "\(AppVersion.nameAndVersion) (\(AppVersion.build ?? "—")) diagnostics"
        ]

        lines.append("")
        lines.append("Performance (§9 budgets in brackets)")
        lines.append("  cold launch     \(diagnostics.launchSeconds.map { String(format: "%.1f ms", $0 * 1000) } ?? "—")   [< 300 ms]")
        // The window printed is the one the sample actually ran over, taken from the sample itself.
        // It is shorter than `--perf-report`'s argument by the first frame plus
        // `PerformanceProbe.settleSeconds`, and saying so is the point: this line is the only place
        // a reader can tell whether the figure describes an idle app or an app still starting up.
        let measured = diagnostics.idleWindowSeconds ?? window
        if let measured {
            lines.append("  idle CPU        \(diagnostics.idleCPUPercent.map { String(format: "%.4f %%", $0) } ?? "—")   [< 0.3 %] over \(String(format: "%.0f", measured))s, after \(String(format: "%.0f", PerformanceProbe.settleSeconds))s settling")
        } else {
            lines.append("  idle CPU        \(diagnostics.idleCPUPercent.map { String(format: "%.4f %%", $0) } ?? "—")   [< 0.3 %]")
        }
        lines.append("  memory          \(diagnostics.memoryBytes.map { String(format: "%.1f MB", Double($0) / 1_048_576) } ?? "—")   [< 60 MB]")
        lines.append("  pass-through    \(diagnostics.passThrough ?? "—")")
        lines.append("  overlay space   \(diagnostics.overlaySpace ?? "—")")
        // Where the history is and whether it is being written — the answer to "can you send me
        // your logs" before the question is asked.
        lines.append("  log file        \(IslandLog.status), level \(IslandLog.minimumLevel.label.trimmingCharacters(in: .whitespaces).lowercased())")

        lines.append("")
        lines.append("Sources (§10: authorization is read live, never cached at launch)")
        if sources.isDisabled {
            lines.append("  not started — --no-sources, or the first frame has not composited yet")
        } else {
            // Sized to the longest name rather than a constant. `padding(toLength:)` *truncates*
            // as well as pads, so a hardcoded width silently clips: at 16 it turned "Bluetooth
            // devices" into "Bluetooth device", which reads as a different word, and "Volume, mute
            // and brightness" into "Volume, mute and", which reads as a broken sentence.
            let width = sources.statuses.map(\.name.count).max() ?? 0
            // Aligns the detail under the authorization column: two of leading indent, the name,
            // one space, "running"/"off     ", two more.
            let indent = String(repeating: " ", count: 2 + width + 1 + 7 + 2)
            for status in sources.statuses {
                lines.append("  \(status.name.padding(toLength: width, withPad: " ", startingAt: 0)) "
                    + "\(status.isEnabled ? "running" : "off     ")  \(status.authorizationDescription)")
                if let detail = status.detail {
                    lines.append("\(indent)\(detail)")
                }
            }
        }

        lines.append("")
        lines.append("Screens")
        for info in controller.debugInfo() {
            lines.append("  \(info.screen.name)  id \(info.screen.id)  @\(info.screen.backingScaleFactor)x")
            lines.append("    frame        \(fmt(info.screen.frame))")
            lines.append("    notch        \(info.screen.notch.kind == .hardware ? "hardware   " : "synthesized")  \(fmt(info.screen.notch.rect))")
            lines.append("    panel        \(fmt(info.panelFrame))  window #\(info.windowNumber)")
            lines.append("    body         \(fmt(info.metrics.bodySize.width)) x \(fmt(info.metrics.bodySize.height)) at \(fmt(info.bodyOrigin))")
            lines.append("    radii        top \(fmt(info.metrics.topCornerRadius)) (extent \(fmt(info.cornerExtents.x)))  bottom \(fmt(info.metrics.bottomCornerRadius)) (extent \(fmt(info.cornerExtents.y)))")
            lines.append("    shape bounds \(fmt(info.shapeBounds))")
        }
        return lines.joined(separator: "\n")
    }

    private static func fmt(_ value: CGFloat) -> String { String(format: "%.1f", value) }
    private static func fmt(_ point: CGPoint) -> String { "(\(fmt(point.x)), \(fmt(point.y)))" }
    private static func fmt(_ rect: CGRect) -> String {
        "(\(fmt(rect.minX)), \(fmt(rect.minY)), \(fmt(rect.width)), \(fmt(rect.height)))"
    }
}
