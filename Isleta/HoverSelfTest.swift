import AppKit
import IslandKit

/// Drives the pointer into the notch and out again, and reports whether hover tracking fired.
///
/// Hover is the one thing in Isleta that cannot be checked by reading state: it depends on the
/// window server delivering `mouseEntered` to a non-activating panel that is never frontmost, in a
/// region of the screen the pointer travels *behind*. `CGWarpMouseCursorPosition` moves the cursor
/// without posting events, so unlike `CGEventPost` it needs no Accessibility permission.
///
/// The pointer is returned to exactly where it started. Only ever runs under `--hover-test`.
@MainActor
enum HoverSelfTest {

    static func isRequested() -> Bool {
        ProcessInfo.processInfo.arguments.contains("--hover-test")
    }

    /// AppKit reports the pointer in y-up screen space; `CGWarpMouseCursorPosition` wants y-down
    /// global display space, whose origin is the top-left of the display at the coordinate origin.
    private static func toDisplaySpace(_ point: CGPoint) -> CGPoint {
        guard let main = NSScreen.screens.first(where: { $0.frame.origin == .zero })
                ?? NSScreen.screens.first else { return point }
        return CGPoint(x: point.x, y: main.frame.maxY - point.y)
    }

    static func run(controller: IslandController, completion: @escaping @MainActor (String) -> Void) {
        let origin = NSEvent.mouseLocation
        guard let target = controller.debugInfo().first(where: { $0.screen.notch.kind == .hardware })
                ?? controller.debugInfo().first else {
            completion("no screens")
            return
        }

        // Aim just inside the top edge rather than at the notch's center. That is where the
        // pointer ends up when a user shoves the mouse upward — macOS clamps it to the top of the
        // display — and warping into the middle of the notch is unreliable: the system sometimes
        // displaces the pointer above the screen entirely rather than let it rest there.
        let notchCenter = CGPoint(
            x: target.screen.notch.rect.midX,
            y: target.screen.frame.maxY - 2
        )
        var lines: [String] = []
        var grew = false
        var arrived = false
        var interfered = false

        func hovering() -> Bool {
            controller.debugInfo().first { $0.screen.id == target.screen.id }?.isHovering ?? false
        }

        lines.append("tracking areas: \(target.trackingAreas)")
        lines.append("panel frame: \(target.panelFrame)  notch: \(target.screen.notch.rect)")
        lines.append("before: hovering=\(hovering())  pointer=\(origin)")
        CGWarpMouseCursorPosition(toDisplaySpace(notchCenter))

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            MainActor.assumeIsolated {
                let entered = hovering()
                let landed = NSEvent.mouseLocation
                // The pointer does not always end up where it was sent. On a display arrangement
                // that stacks another screen directly above the laptop, the warp can carry straight
                // through the 32pt notch band and onto the screen above. That is a fact about the
                // arrangement, not a hover failure, so it is reported separately.
                arrived = target.screen.notch.rect.insetBy(dx: -2, dy: -2).contains(landed)
                lines.append("warped to \(notchCenter) → pointer actually at \(landed), in notch band=\(arrived), hovering=\(entered)")

                // Prove the island actually grew, rather than only that the state flipped. This
                // point sits below the resting island's bottom edge but inside the peek shape, so
                // the window server can only attribute it to us if the peek really rendered.
                let below = CGPoint(
                    x: target.screen.notch.rect.midX,
                    y: target.screen.notch.rect.minY - IslandLayout.peekHeightGrowth / 2
                )
                let owner = controller.windowNumberAtScreenPoint(below)
                grew = controller.ownsWindowNumber(owner)
                lines.append("point \(below), \(IslandLayout.peekHeightGrowth / 2)pt below the resting island → \(grew ? "is now Isleta (island grew)" : "not Isleta (island did NOT grow)")")

                CGWarpMouseCursorPosition(toDisplaySpace(origin))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    MainActor.assumeIsolated {
                        let exited = hovering()
                        let restored = NSEvent.mouseLocation
                        // If the pointer is not where we last put it, a human moved it and the
                        // result means nothing. This matters more than it sounds: the test is most
                        // likely to be run on a machine somebody is using, and a hand on the
                        // trackpad turns every reading into noise.
                        interfered = hypot(restored.x - origin.x, restored.y - origin.y) > 4
                        lines.append("pointer restored to \(origin), now at \(restored): hovering=\(exited)")
                        let verdict: String
                        if interfered {
                            verdict = "INCONCLUSIVE — the pointer was moved by hand during the test. Re-run when idle."
                        } else if !arrived {
                            verdict = "INCONCLUSIVE — the pointer never reached the notch band; "
                                + "the warp overshot onto an adjacent display. Re-run."
                        } else if entered, grew, !exited {
                            verdict = "PASS — entered, grew, and collapsed on \(target.screen.name)"
                        } else {
                            verdict = "FAIL — entered=\(entered) grew=\(grew) stillHovering=\(exited)"
                        }
                        completion(([verdict] + lines).joined(separator: "\n                  "))
                    }
                }
            }
        }
    }
}
