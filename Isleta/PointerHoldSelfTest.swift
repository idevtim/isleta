import AppKit
import IslandActivities
import IslandKit

/// Presents a notification, parks the pointer on the island, and reports whether the dwell ran out
/// under it.
///
/// The rule itself is proved in `PointerHoldTests` against a pure stack. What no unit test can
/// reach is the wiring between them: hover is delivered by the window server to a non-activating
/// panel, arrives as `IslandController.onHoverChanged`, and only then becomes
/// `ActivityCoordinator.setPointerOverIsland`. A break anywhere along that path leaves the suite
/// green and the notification vanishing under the pointer, which is the bug this exists for.
///
/// `CGWarpMouseCursorPosition` moves the cursor without posting events, so unlike `CGEventPost` it
/// needs no Accessibility permission. The pointer is returned to exactly where it started, and the
/// demo notification is dismissed either way. Only ever runs under `--pointer-hold-test`.
@MainActor
enum PointerHoldSelfTest {

    static func isRequested() -> Bool {
        ProcessInfo.processInfo.arguments.contains("--pointer-hold-test")
    }

    /// The margin either side of the dwell. Long enough that a slow frame cannot decide the
    /// verdict, short enough that the whole test is a few seconds.
    private static let margin: TimeInterval = 1.5

    /// AppKit reports the pointer in y-up screen space; `CGWarpMouseCursorPosition` wants y-down
    /// global display space, whose origin is the top-left of the display at the coordinate origin.
    private static func toDisplaySpace(_ point: CGPoint) -> CGPoint {
        guard let main = NSScreen.screens.first(where: { $0.frame.origin == .zero })
                ?? NSScreen.screens.first else { return point }
        return CGPoint(x: point.x, y: main.frame.maxY - point.y)
    }

    static func run(
        controller: IslandController,
        activities: ActivityCoordinator,
        completion: @escaping @MainActor (String) -> Void
    ) {
        let origin = NSEvent.mouseLocation
        guard let target = controller.debugInfo().first(where: { $0.screen.notch.kind == .hardware })
                ?? controller.debugInfo().first else {
            completion("no screens")
            return
        }

        let id = ActivityID("pointer-hold-self-test")
        var lines: [String] = []

        func hovering() -> Bool {
            controller.debugInfo().first { $0.screen.id == target.screen.id }?.isHovering ?? false
        }

        func finish(_ verdict: String) {
            activities.dismiss(id)
            CGWarpMouseCursorPosition(toDisplaySpace(origin))
            completion(([verdict] + lines).joined(separator: "\n                        "))
        }

        // Presented *before* the warp, so its deadline is still in the schedule and can be read.
        // The moment the pointer lands it drops out — that is the property under test.
        // Any *expiring* kind will do — what is under test is the pointer holding a deadline
        // open, not which kind owns it. `.calendarAlert` is the nearest thing to what this used to
        // present: prominent, plural, and expiring on its own after ten seconds. It must not be a
        // kind that opens the island by itself, for `SwipeSelfTest.ProbeActivity`'s reason — a
        // probe that arrives with the island already open is testing something else.
        activities.present(
            BuiltInActivity(
                id: id,
                kind: .calendarAlert,
                presentations: ActivityPresentations(
                    compact: ActivityContent(
                        symbol: "calendar.badge.clock",
                        title: "Pointer hold self-test"
                    ),
                    expanded: ActivityContent(
                        symbol: "calendar.badge.clock",
                        title: "Pointer hold self-test",
                        subtitle: "This island should stay while the pointer is on it."
                    )
                )
            )
        )
        guard let deadline = activities.nextExpiry else {
            finish("FAIL — the probe was presented with no deadline; nothing to hold")
            return
        }
        let dwell = deadline.timeIntervalSinceNow
        lines.append("presented \(id) on \(target.screen.name), dwell \(String(format: "%.1f", dwell))s")
        lines.append("notch: \(target.screen.notch.rect)  pointer: \(origin)")

        // Just inside the top edge rather than the notch's center, for the reason `HoverSelfTest`
        // spells out: macOS sometimes displaces a pointer warped into the middle of the notch above
        // the screen entirely.
        let notchCenter = CGPoint(x: target.screen.notch.rect.midX, y: target.screen.frame.maxY - 2)
        CGWarpMouseCursorPosition(toDisplaySpace(notchCenter))

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            MainActor.assumeIsolated {
                let entered = hovering()
                let landed = NSEvent.mouseLocation
                // A warp that carried through the notch band onto a display stacked above it is a
                // fact about the arrangement, not a hold failure. Reported separately.
                let arrived = target.screen.notch.rect.insetBy(dx: -2, dy: -2).contains(landed)
                lines.append("warped to \(notchCenter) → pointer at \(landed), in notch band=\(arrived), hovering=\(entered)")
                lines.append("scheduled expiry while held: \(activities.nextExpiry.map(String.init(describing:)) ?? "none")")

                guard entered, arrived else {
                    finish("INCONCLUSIVE — the pointer never reached the island (entered=\(entered) inBand=\(arrived)). Re-run when idle.")
                    return
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + dwell + margin) {
                    MainActor.assumeIsolated {
                        let held = activities.presented?.id == id
                        let stillThere = NSEvent.mouseLocation
                        let interfered = hypot(stillThere.x - notchCenter.x, stillThere.y - notchCenter.y) > 4
                        lines.append("\(String(format: "%.1f", dwell + margin))s later, pointer still on the island: presented=\(activities.presented?.id.rawValue ?? "nothing")")

                        guard !interfered else {
                            finish("INCONCLUSIVE — the pointer was moved by hand during the hold. Re-run when idle.")
                            return
                        }

                        CGWarpMouseCursorPosition(toDisplaySpace(origin))
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            MainActor.assumeIsolated {
                                let released = activities.presented?.id != id
                                let exited = !hovering()
                                lines.append("pointer returned to \(origin): hovering=\(!exited), presented=\(activities.presented?.id.rawValue ?? "nothing")")
                                if held, released, exited {
                                    finish("PASS — held past its dwell under the pointer, and left with it")
                                } else {
                                    finish("FAIL — heldWhileHovering=\(held) leftOnExit=\(released) hoverEnded=\(exited)")
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
