import AppKit
import IslandKit

/// Programmatic evidence for §4.2 / §13.6: clicks outside the island reach the app underneath.
///
/// Rather than asserting that a transparent panel is click-through, this asks the window server the
/// same question the click itself asks — `NSWindow.windowNumber(at:belowWindowWithWindowNumber:)`
/// returns whichever window owns a given screen pixel. If a point outside the island resolves to
/// anything other than our panel, the click lands there instead of on Isleta.
///
/// The interesting points are not the far-field ones — they are the two rounded bottom corners,
/// which sit *inside* the shape's bounding box but outside the shape. A naive rectangular hit
/// region passes every far-field test and fails exactly there.
///
/// The probes assume the island is at rest. While it is hovered it is larger, so the "outside"
/// expectations no longer hold and the caller skips the run rather than reporting a false failure.
@MainActor
enum PassThroughSelfTest {

    private struct Probe {
        let label: String
        let screenPoint: CGPoint
        let expectedToBeOurs: Bool
    }

    static func run(controller: IslandController, verbose: Bool? = nil) -> String {
        // Every probe here asks the window server who owns a pixel, and while the screen is locked
        // the answer is always its own shield window. Reporting that as a failure is worse than
        // reporting nothing: it is indistinguishable from the real defect this test exists to catch,
        // and it has trained three separate sessions to scroll past a red line.
        guard !ScreenLock.isLocked else { return ScreenLock.explanation }

        let verbose = verbose ?? ProcessInfo.processInfo.arguments.contains("--probe-verbose")
        var passed = 0
        var failed = 0
        var failures: [String] = []

        for info in controller.debugInfo() {
            for probe in probes(for: info) {
                let owner = controller.windowNumberAtScreenPoint(probe.screenPoint)
                let isOurs = owner == info.windowNumber
                if verbose {
                    NSLog(String(format: "[probe] %@/%@ (%.1f, %.1f) → #%d ours=#%d %@",
                                 info.screen.name, probe.label,
                                 probe.screenPoint.x, probe.screenPoint.y,
                                 owner, info.windowNumber,
                                 (isOurs == probe.expectedToBeOurs ? "ok" : "MISMATCH")
                                    + (controller.ownsWindowNumber(owner) ? " [owner IS one of ours]" : "")))
                }
                if isOurs == probe.expectedToBeOurs {
                    passed += 1
                } else {
                    failed += 1
                    failures.append("\(info.screen.name)/\(probe.label)")
                }
            }
        }

        if failures.isEmpty {
            return "\(passed)/\(passed) probes correct — clicks outside the shape reach the app below"
        }
        NSLog("[Isleta] pass-through failures: \(failures.joined(separator: ", "))")
        return "\(passed) ok, \(failed) FAILED: \(failures.prefix(4).joined(separator: ", "))"
    }

    /// Whether the window server has the panel's backing store yet.
    ///
    /// **The precondition for the `inside-*` probes, and the thing that made the launch-time run a
    /// standing false alarm.** Every probe asks the window server who owns a pixel, and until the
    /// panel has been composited the answer for a pixel the island paints is *whatever is behind
    /// it* — correctly, because nothing is there yet. So a run at first frame reports
    /// `inside-quarter`, `inside-center`, `inside-three-quarter`, `inside-top` and `inside-bottom`
    /// as failures, writes them to `isleta.log`, and the same test a moment later reports 12/12.
    /// That line shipped in every launch from 2026-08-21, in the file people are asked to attach to
    /// a bug report.
    ///
    /// This asks the question directly rather than waiting out a guessed interval: the island's own
    /// center is ours exactly when the pixels exist. Note the *outside* probes have no such
    /// precondition — they are true from the moment the panel is ordered in — so nothing here
    /// weakens what the test is actually for.
    static func hasComposited(controller: IslandController) -> Bool {
        let panels = controller.debugInfo()
        guard !panels.isEmpty else { return false }
        return panels.allSatisfy { info in
            let center = screenPoint(
                CGPoint(
                    x: info.bodyOrigin.x + info.metrics.bodySize.width / 2,
                    y: info.metrics.bodySize.height / 2
                ),
                in: info.panelFrame
            )
            return controller.windowNumberAtScreenPoint(center) == info.windowNumber
        }
    }

    /// A one-shot probe at an arbitrary pointer location, for eyeballing the boundary by hand.
    static func probe(at screenPoint: CGPoint, controller: IslandController) -> String {
        let owner = controller.windowNumberAtScreenPoint(screenPoint)
        let ours = controller.ownsWindowNumber(owner)
        return String(
            format: "(%.1f, %.1f) → window #%d %@",
            screenPoint.x, screenPoint.y, owner, ours ? "= Isleta (would hit)" : "= not Isleta (passes through)"
        )
    }

    /// Converts a point in the panel's y-down content space into AppKit's y-up screen space.
    private static func screenPoint(_ local: CGPoint, in panelFrame: CGRect) -> CGPoint {
        CGPoint(x: panelFrame.minX + local.x, y: panelFrame.maxY - local.y)
    }

    private static func probes(for info: IslandDebugInfo) -> [Probe] {
        let body = info.metrics.bodySize
        let origin = info.bodyOrigin
        let corner = info.cornerExtents.y
        let panel = info.panelFrame
        var result: [Probe] = []

        func add(_ label: String, _ local: CGPoint, ours: Bool) {
            result.append(Probe(label: label, screenPoint: screenPoint(local, in: panel), expectedToBeOurs: ours))
        }

        // Solidly inside the island.
        for (fraction, name) in [(0.25, "quarter"), (0.5, "center"), (0.75, "three-quarter")] as [(CGFloat, String)] {
            add("inside-\(name)", CGPoint(x: origin.x + body.width * fraction, y: body.height * 0.5), ours: true)
        }
        add("inside-top", CGPoint(x: origin.x + body.width / 2, y: 2), ours: true)
        add("inside-bottom", CGPoint(x: origin.x + body.width / 2, y: body.height - 2), ours: true)

        // The rounded bottom corners: inside the bounding box, outside the shape. These are the
        // probes that matter — a rectangular hit region passes every far-field test and fails
        // exactly here.
        add("corner-left", CGPoint(x: origin.x + 0.04 * corner, y: body.height - 0.04 * corner), ours: false)
        add("corner-right", CGPoint(x: origin.x + body.width - 0.04 * corner, y: body.height - 0.04 * corner), ours: false)

        // Just past the body walls.
        add("outside-left", CGPoint(x: origin.x - 2, y: body.height / 2), ours: false)
        add("outside-right", CGPoint(x: origin.x + body.width + 2, y: body.height / 2), ours: false)

        // Just below the island, and out in the empty panel area.
        add("below", CGPoint(x: origin.x + body.width / 2, y: body.height + 2), ours: false)
        add("panel-far", CGPoint(x: 8, y: panel.height - 8), ours: false)
        add("beside-top", CGPoint(x: origin.x - 8, y: 2), ours: false)

        return result
    }
}
