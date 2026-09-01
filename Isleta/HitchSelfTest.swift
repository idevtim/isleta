#if DEBUG
import AppKit
import Foundation

/// Drives the island through its own open and close animations while `AnimationHitchProbe` counts
/// frames, so "does it stutter" is answered in dropped frames rather than in adjectives.
///
/// **Why a driver rather than a human with `--hitch-probe`.** The probe already reports a burst of
/// late frames as it happens, but reading it means sitting in front of the island opening it by
/// hand, and a hand on the trackpad is itself an input — hover changes which state a collapse lands
/// in, and no two runs open the same island twice. This runs the same transitions a click runs,
/// the same number of times, with nothing on stage that was not put there deliberately, so two runs
/// are comparable and a regression is a number that moved.
///
/// Each step opens a measurement window, performs one transition, and waits `settle` for the spring
/// to finish (`Motion.expand` is a 0.38s response, so 0.8s is well past the tail). Frames are
/// attributed to the step that was running, and steps with the same label are aggregated.
@MainActor
enum HitchSelfTest {

    static func isRequested() -> Bool {
        ProcessInfo.processInfo.arguments.contains("--hitch-test")
    }

    /// `--hitch-test [cycles]`. Three by default: enough that one unlucky window does not decide the
    /// answer, short enough that the whole run is under a minute.
    static var cycles: Int {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--hitch-test"),
              arguments.indices.contains(flag + 1),
              let requested = Int(arguments[flag + 1])
        else { return 3 }
        return min(max(1, requested), 20)
    }

    struct Step {
        let label: String
        let settle: TimeInterval
        let action: @MainActor () -> Void

        init(_ label: String, settle: TimeInterval = 0.8, action: @escaping @MainActor () -> Void) {
            self.label = label
            self.settle = settle
            self.action = action
        }
    }

    /// Runs the steps in order, one measurement window each.
    ///
    /// Serial and on the main queue by construction: two transitions overlapping would put one
    /// animation's frames in the other's window, which is the one thing this cannot be allowed to
    /// get wrong.
    static func run(
        probe: AnimationHitchProbe,
        steps: [Step],
        completion: @escaping @MainActor ([AnimationHitchProbe.Measurement]) -> Void
    ) {
        var results: [AnimationHitchProbe.Measurement] = []

        func next(_ index: Int) {
            guard index < steps.count else {
                completion(results)
                return
            }
            let step = steps[index]
            probe.beginWindow(step.label)
            step.action()
            DispatchQueue.main.asyncAfter(deadline: .now() + step.settle) {
                MainActor.assumeIsolated {
                    if let measurement = probe.endWindow() { results.append(measurement) }
                    next(index + 1)
                }
            }
        }

        next(0)
    }

    /// One line per label, in the order the labels were first measured.
    ///
    /// Aggregated rather than printed per run, because a single window is not evidence: the first
    /// expansion of any launch pays for whatever SwiftUI has not built yet, and reading that one as
    /// "the island drops frames" is the mistake this report exists to prevent. The first run of each
    /// label is therefore also called out separately.
    static func report(_ measurements: [AnimationHitchProbe.Measurement]) -> String {
        guard !measurements.isEmpty else { return "hitch self-test: nothing measured" }

        var order: [String] = []
        var byLabel: [String: [AnimationHitchProbe.Measurement]] = [:]
        for measurement in measurements {
            if byLabel[measurement.label] == nil { order.append(measurement.label) }
            byLabel[measurement.label, default: []].append(measurement)
        }

        let budget = measurements.map(\.budget).max() ?? 0
        let refresh = budget > 0 ? 1 / budget : 0
        var lines = [
            String(
                format: "hitch self-test — %d window(s), display running at %.0f Hz (%.1f ms budget)",
                measurements.count, refresh, budget * 1000
            )
        ]

        let width = (order.map(\.count).max() ?? 0)
        for label in order {
            let runs = byLabel[label] ?? []
            let dropped = runs.reduce(0) { $0 + $1.dropped }
            let frames = runs.reduce(0) { $0 + $1.frames }
            let worst = runs.map(\.worstGap).max() ?? 0
            let stalls = runs.reduce(0) { $0 + $1.lateEvents }
            let offsets = runs.map(\.firstLateOffset).filter { $0 >= 0 }
            let firstLate = offsets.isEmpty ? -1 : offsets.reduce(0, +) / Double(offsets.count)
            let first = runs[0].dropped
            lines.append(
                String(
                    format: "  %@  %2d run(s)  %5d frames  %3d dropped in %2d stall(s) (%d on the first)  worst gap %5.1f ms  first stall at %@",
                    label.padding(toLength: width, withPad: " ", startingAt: 0),
                    runs.count, frames, dropped, stalls, first, worst * 1000,
                    firstLate < 0 ? "—" : String(format: "%.0f ms", firstLate * 1000)
                )
            )
        }

        // A dropped frame in the *first* window of a label is startup cost — the view being built
        // for the first time — and is not what a user calls a stutter, because it happens once per
        // launch. What matters is whether the same animation keeps dropping frames on the runs after
        // it, which is what a person sees every time they open the island.
        let repeated = order.flatMap { label -> [AnimationHitchProbe.Measurement] in
            Array((byLabel[label] ?? []).dropFirst())
        }
        let repeatedDrops = repeated.reduce(0) { $0 + $1.dropped }
        let worstRepeated = repeated.map(\.worstGap).max() ?? 0
        // A display link that never fired is not a smooth run, and the difference is invisible in
        // every column: zero late frames out of zero frames reads as a perfect score. It happens for
        // an ordinary reason — the display slept part-way through a run that takes most of a minute
        // — and the tell is the refresh rate, which is derived from the callbacks there were.
        let totalFrames = measurements.reduce(0) { $0 + $1.frames }
        if totalFrames == 0 {
            lines.append("verdict: INCONCLUSIVE — the display link never fired. The display was asleep, or there was no island on it.")
            return lines.joined(separator: "\n")
        }

        if repeated.isEmpty {
            lines.append("verdict: INCONCLUSIVE — one run per animation, so first-frame cost cannot be told from a stutter. Re-run with more cycles.")
        } else if repeatedDrops == 0 {
            lines.append("verdict: CLEAN — no frame dropped on any repeat run")
        } else {
            lines.append(
                String(
                    format: "verdict: %d frame(s) dropped across %d repeat run(s), worst gap %.1f ms",
                    repeatedDrops, repeated.count, worstRepeated * 1000
                )
            )
        }
        return lines.joined(separator: "\n")
    }
}
#endif
