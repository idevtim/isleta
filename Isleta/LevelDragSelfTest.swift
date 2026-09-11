import AppKit
import IslandActivities
import IslandKit
import IslandUI

/// Drags the bar in a HUD's sliver, and presses the island beside it, and reports whether either
/// did anything.
///
/// ## The question it exists to answer
///
/// The bar is 76pt of a **collapsed** island — a sliver 108pt wide with a hole in the middle of the
/// panel beside it — and it is a control in a window that never becomes key (§4.1). Two things about
/// that are genuinely open rather than formalities, and neither can be checked by looking:
///
/// 1. **Does the drag arrive at all?** `NowPlayingScrubberView` established that a `DragGesture`
///    works inside the island, but it did so in the *open* island's body, laid out by a view that
///    fills it. This is a zero-sized overlay in a sliver, and `IslandHitTestView.hitTest` has to
///    return the hosting view for a point on it before SwiftUI is ever asked.
/// 2. **Does everything else still fall through?** A press on the island away from the bar has to
///    reach `IslandHitTestView.mouseDown` exactly as it always did — which is what puts the HUD away
///    and opens the island. A grab region that claimed the whole sliver, or the whole island, would
///    break that and look entirely correct on screen.
///
/// Nothing here touches the user's volume or their screen brightness: `IslandScreenModel.onAdjustLevel`
/// is replaced for the length of the run, so what is measured is the fraction the island *asked*
/// for. Where that fraction then goes is `LevelWriteTests`, which is a unit test because it has no
/// window in it.
///
/// Events go through `NSApp.sendEvent` rather than `CGEventPost`, like `ClickSelfTest` and
/// `TransportSelfTest`: that needs no Accessibility grant, and it covers everything from
/// `NSWindow.sendEvent` inward. `PassThroughSelfTest` covers the window server's half.
@MainActor
enum LevelDragSelfTest {

    static func isRequested() -> Bool {
        ProcessInfo.processInfo.arguments.contains("--level-drag-test")
    }

    /// Where along the bar the drag starts, passes through, and ends.
    ///
    /// Three points rather than two, and the middle one is not decoration: a press that has not
    /// moved and a drag are different branches of the same gesture, and a single move would only
    /// ever exercise one of them.
    private static let start = 0.2
    private static let middle = 0.5
    private static let end = 0.8

    /// A volume at neither end of its range, so nothing here can be confused for a rebound.
    private static let restingLevel = 0.5

    static func run(
        controller: IslandController,
        coordinator: ActivityCoordinator,
        model: IslandScreenModel,
        /// Closes every island, by the route Escape and a click elsewhere take.
        collapse: @escaping @MainActor () -> Void,
        presentation: @escaping @MainActor (CGDirectDisplayID) -> String,
        completion: @escaping @MainActor (String) -> Void
    ) {
        guard let target = controller.debugInfo().first,
              let screen = controller.screens.first(where: { $0.id == target.screen.id })
        else {
            completion("no screens")
            return
        }
        guard let window = NSApp.window(withWindowNumber: target.windowNumber) else {
            completion("FAIL — could not find our own panel by window number \(target.windowNumber)")
            return
        }

        var lines: [String] = []
        var asked: [(SystemHUD, Double)] = []

        // Replaced rather than observed alongside the real one: proving a bar works by turning
        // somebody's music up is not an acceptable test.
        let realAdjust = model.onAdjustLevel
        model.onAdjustLevel = { hud, fraction in asked.append((hud, fraction)) }

        func restore() {
            model.onAdjustLevel = realAdjust
        }

        func post(_ type: NSEvent.EventType, at point: CGPoint) {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1
            ) else { return }
            NSApp.sendEvent(event)
        }

        func after(_ seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                MainActor.assumeIsolated(work)
            }
        }

        coordinator.dismissAll()
        coordinator.present(BuiltInActivity.systemHUD(.volume, level: restingLevel))

        // Long enough for the widen into the wide flanked form to settle *and* for the 40ms content
        // follow behind it (§6.2). Aiming at a sliver that is still growing would be a real test of
        // something, but not of this.
        after(0.9) {
            // **Asked of the model, not recomputed.** `slotLayout` is the layout the renderer drew
            // from, resolved against `contentMetrics` — so this cannot drift from where the sliver
            // actually is, whatever the user's notch, island size settings or hover state.
            let layout = model.slotLayout
            let content = coordinator.stage?.content(for: .trailing) ?? .empty
            guard let flank = layout.trailing else {
                restore()
                completion("FAIL — a HUD's island affords no trailing sliver to draw a bar in")
                return
            }
            let bar = ActivityContentView.levelBarFrame(for: content, in: flank)
            let grab = ActivityContentView.levelGrabFrame(for: content, in: flank)
            let origin = IslandLayout.bodyOrigin(
                bodyWidth: model.contentBodyWidth, in: target.panelFrame.size
            )

            /// Body-space (y-down) → panel-space (y-up), which is where `NSEvent` locations live.
            func inWindow(_ point: CGPoint) -> CGPoint {
                CGPoint(
                    x: origin.x + point.x,
                    y: target.panelFrame.height - (origin.y + point.y)
                )
            }

            /// A point a fraction along the bar — and deliberately **off its centre line**, near the
            /// top of the grab region. A press that only works dead on a 4pt bar is a press nobody
            /// can make; this is what asserts `levelGrabInset` is really there.
            func alongTheBar(_ fraction: Double) -> CGPoint {
                inWindow(CGPoint(x: bar.minX + bar.width * fraction, y: grab.minY + 2))
            }

            lines.append("sliver \(flank) → bar \(bar), grab \(grab)")
            let down = alongTheBar(start)
            lines.append("bar at \(down) → hitTest \(window.contentView?.hitTest(down).map { String(describing: type(of: $0)) } ?? "nil")")

            post(.leftMouseDown, at: down)
            post(.leftMouseDragged, at: alongTheBar(middle))
            post(.leftMouseDragged, at: alongTheBar(end))
            post(.leftMouseUp, at: alongTheBar(end))

            after(0.25) {
                lines.append("drag \(start) → \(end) asked for \(asked.map { "\($0.0.rawValue) \(String(format: "%.2f", $0.1))" })")
                // The press is a zero-distance drag, so the first event is an answer too: a bar that
                // only moved on the *second* event would be one a click could not set.
                let pressLanded = asked.first.map { $0.0 == .volume && abs($0.1 - start) < 0.05 } ?? false
                // A couple of points of a 76pt bar, which is tight enough that a drag landing on the
                // press point (0.2) or nowhere at all fails, and loose enough not to depend on the
                // exact inset SwiftUI resolved the sliver to.
                let dragLanded = asked.last.map { $0.0 == .volume && abs($0.1 - end) < 0.05 } ?? false

                // **The other half: everything that is not the bar still falls through.** The notch's
                // own centre is the furthest point on the island from either sliver, and a press
                // there has to put the HUD away and open the island.
                let notch = target.screen.notch.rect
                let plain = CGPoint(
                    x: notch.midX - target.panelFrame.minX,
                    y: notch.midY - target.panelFrame.minY
                )
                let hudWasUp = coordinator.stage?.primary.kind == .systemHUD
                post(.leftMouseDown, at: plain)

                after(0.9) {
                    let hudPutAway = hudWasUp && coordinator.stage?.primary.kind != .systemHUD
                    let opened = presentation(screen.id) == "expanded"
                    lines.append("press on the notch → stage \(coordinator.stage?.primary.kind.rawValue ?? "empty"), island \(presentation(screen.id))")

                    collapse()
                    coordinator.dismissAll()
                    restore()

                    let verdict: String
                    if pressLanded && dragLanded && hudPutAway && opened {
                        verdict = "PASS — the level drags in a collapsed island, and a press beside it puts the HUD away and opens"
                    } else {
                        verdict = "FAIL — press=\(pressLanded) drag=\(dragLanded) "
                            + "hudPutAway=\(hudPutAway) opened=\(opened)"
                    }
                    completion(([verdict] + lines).joined(separator: "\n                           "))
                }
            }
        }
    }
}
