import AppKit
import IslandActivities
import IslandKit
import IslandUI

/// Clicks the island and reports what happened.
///
/// Synthesises the event and hands it to `NSApp.sendEvent` rather than posting it with
/// `CGEventPost`, which would need the Accessibility permission Milestone 0 deliberately does not
/// ask for. That means this exercises everything from `NSWindow.sendEvent` inward — hit testing,
/// the responder chain, and whether the click survives passing through `NSHostingView` — but not
/// the window server's routing. `PassThroughSelfTest` covers that half.
@MainActor
enum ClickSelfTest {

    static func isRequested() -> Bool {
        ProcessInfo.processInfo.arguments.contains("--click-test")
    }

    static func run(
        controller: IslandController,
        activities: ActivityCoordinator,
        presentation: @escaping @MainActor (CGDirectDisplayID) -> String,
        completion: @escaping @MainActor (String) -> Void
    ) {
        guard let target = controller.debugInfo().first else {
            completion("no screens")
            return
        }
        guard let window = NSApp.window(withWindowNumber: target.windowNumber) else {
            completion("FAIL — could not find our own panel by window number \(target.windowNumber)")
            return
        }

        let notch = target.screen.notch.rect
        // NSEvent locations for a window event are in that window's own y-up space.
        let inWindow = CGPoint(x: notch.midX - target.panelFrame.minX, y: notch.midY - target.panelFrame.minY)
        // A probe of its own, rather than whatever the machine happens to be playing.
        //
        // This test used to click an island whose contents were ambient: if Music was open it had
        // something to show, and if it was not it did not. That was always non-determinism — the
        // island a cold start opens onto is the quiet menu, and the one this test is written for
        // has an activity in it. The click mechanism is what is under test here, not the state of
        // anyone's Mac.
        activities.dismissAll()
        activities.present(SwipeSelfTest.ProbeActivity("click.probe", priority: .prominent, title: "Click Probe"))

        var lines = ["before: \(presentation(target.screen.id))"]
        var renderedExpanded = false
        // A hand on the trackpad turns every reading into noise: hovering changes which state a
        // collapse lands in, and a real click lands on top of the synthesised one.
        let hoveringAtStart = controller.debugInfo().first?.isHovering ?? false
        let hit = window.contentView?.hitTest(inWindow)
        lines.append("hitTest(\(inWindow)) → \(hit.map { String(describing: type(of: $0)) } ?? "nil")")
        lines.append("contentView → \(window.contentView.map { String(describing: type(of: $0)) } ?? "nil"), subviews: \(window.contentView?.subviews.map { String(describing: type(of: $0)) } ?? [])")

        func click(
            _ label: String,
            at location: CGPoint = inWindow,
            then next: @escaping @MainActor () -> Void
        ) {
            guard let event = NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: location,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            ) else {
                lines.append("\(label): could not construct the event")
                next()
                return
            }
            NSApp.sendEvent(event)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                MainActor.assumeIsolated {
                    lines.append("\(label): \(presentation(target.screen.id))")
                    next()
                }
            }
        }

        // The flank is where a hit region that is a *subset* of what is drawn shows itself. When
        // the island is flanked it paints 40pt of black either side of the cutout; those pixels are
        // opaque, so the window server routes clicks on them to us, and if `islandPath` were still
        // the bare cutout our own `hitTest` would reject them — the click would neither open the
        // island nor reach the app underneath. Both halves have to agree, which is why this asks
        // the window server *and* our own hit testing about the same pixel.
        let flankWidth = (target.metrics.bodySize.width - notch.width) / 2
        var flankAccepted = true
        var indicatorAccepted = true
        if flankWidth <= 0 {
            lines.append("flank: island is not flanked — run with --activity-demo to exercise it")
        } else {
            let flankPoint = CGPoint(x: notch.maxX + flankWidth / 2, y: notch.midY)
            let painted = controller.ownsWindowNumber(controller.windowNumberAtScreenPoint(flankPoint))
            let flankInWindow = CGPoint(
                x: flankPoint.x - target.panelFrame.minX,
                y: flankPoint.y - target.panelFrame.minY
            )
            let accepted = window.contentView?.hitTest(flankInWindow) != nil
            // `painted` is the window server's answer, and a locked screen makes it always "no".
            // Our own hit testing is still worth asserting, so only the half that cannot be measured
            // is dropped — the run stays honest rather than failing for an unrelated reason.
            flankAccepted = ScreenLock.isLocked ? accepted : (painted && accepted)
            let serverVerdict = ScreenLock.isLocked
                ? "window server not asked (screen locked)"
                : "window server says \(painted ? "Isleta" : "NOT Isleta")"
            lines.append(
                "flank: \(Int(flankWidth))pt sliver at \(flankPoint) → \(serverVerdict), hitTest \(accepted ? "accepts" : "REJECTS")"
            )
        }

        click("after first click") {
            let expanded = lines.last?.contains("expanded") == true

            // Prove the island actually grew rather than only that the state flipped. This point is
            // far below the resting island but well inside the expanded body, so the window server
            // can only attribute it to us if the expansion really rendered.
            // Measured against the height the island *actually* opens to, not the default: the
            // open island now takes its height from its content
            // (`ActivityExpandedHeight`), and this probe's own activity is a title with no
            // message, which opens at the floor rather than at the player's 176pt. Reading the
            // constant here would put the probe point 4pt inside a 76pt body on this activity and
            // outside it on the next one somebody writes.
            let expandedHeight = IslandLayout.expandedMetrics(
                for: target.screen,
                expandedContentHeight: controller.expandedContentHeight,
                pageIndicatorHeight: controller.pageIndicatorHeight
            ).bodySize.height
            let deep = CGPoint(
                x: notch.midX,
                y: notch.minY - (expandedHeight - notch.height) / 2
            )
            // Also a window-server question, so also unanswerable behind the lock shield. Treated as
            // satisfied rather than failed: the alternative is a red line that means "cannot
            // measure", which is the confusion this guard exists to remove.
            let grew = ScreenLock.isLocked
                ? true
                : controller.ownsWindowNumber(controller.windowNumberAtScreenPoint(deep))
            let renderNote = ScreenLock.isLocked
                ? "render not checked (screen locked)"
                : (grew ? "is Isleta (expansion rendered)" : "not Isleta (did NOT render)")
            lines.append("point \(deep), \(Int((expandedHeight - notch.height) / 2))pt below the notch → \(renderNote)")
            renderedExpanded = grew

            // The page indicator is the thing most easily drawn outside the region we accept. It
            // sits in the bottom strip of the open island — the part `maxExpandedBodySize` was
            // raised for — so it is exactly where a hit region built from the old height would stop
            // short. `PassThroughSelfTest` cannot see this: the window server is behaving correctly
            // throughout, and it is `hitTest` that would be rejecting the clicks.
            //
            // Unconditional now. It probed the switcher row before, and that row was only drawn
            // when something was on stage — so the check silently passed on a quiet Mac. The dots
            // are on every open island, which means this can no longer be skipped by accident.
            do {
                let rowCenter = CGPoint(
                    x: notch.midX,
                    y: notch.minY - (expandedHeight - notch.height)
                        + IslandPageIndicatorLayout.bottomPadding
                        + IslandPageIndicatorLayout.dotSide / 2
                )
                let rowPainted = ScreenLock.isLocked
                    ? true
                    : controller.ownsWindowNumber(controller.windowNumberAtScreenPoint(rowCenter))
                let rowInWindow = CGPoint(
                    x: rowCenter.x - target.panelFrame.minX,
                    y: rowCenter.y - target.panelFrame.minY
                )
                let rowAccepted = window.contentView?.hitTest(rowInWindow) != nil
                indicatorAccepted = rowPainted && rowAccepted
                lines.append(
                    "page indicator at \(rowCenter) → \(rowPainted ? "window server says Isleta" : "NOT Isleta"), "
                    + "hitTest \(rowAccepted ? "accepts" : "REJECTS")"
                )
            }
            // **A second click on the island must change nothing.** Since 2026-08-26 the click
            // only ever opens: the body of an open island is where all of its content is, so a
            // click there is a click on the content and cannot also mean "close". The ways out are
            // all outside the island, and the next step exercises the nearest one.
            click("after second click") {
                let stillExpanded = lines.last?.contains("expanded") == true

                // **The blur must pass clicks straight through.** It is drawn in `IslandBlurPanel`,
                // a window that ignores mouse events, precisely so that a click in the band reaches
                // the app underneath instead of being eaten by an island that merely draws near it.
                // Both halves have to hold: the window server must not attribute the point to
                // Isleta, and our own `hitTest` must refuse it. If the first fails the blur has
                // drifted back into the island's panel; if the second fails the island accepts a
                // click on a pixel it does not draw.
                //
                // Halfway into the ring beside the island's left wall, level with the deep probe
                // above: far enough out to be clear of the body, far enough in to be well inside
                // the blur rather than in its last faint pixels.
                let expandedWidth = IslandLayout.expandedMetrics(
                    for: target.screen,
                    expandedContentHeight: controller.expandedContentHeight,
                    pageIndicatorHeight: controller.pageIndicatorHeight
                ).bodySize.width
                let blurPoint = CGPoint(
                    x: notch.midX - expandedWidth / 2 - IslandLayout.blurSpread / 2,
                    y: notch.minY - (expandedHeight - notch.height) / 2
                )
                let blurInWindow = CGPoint(
                    x: blurPoint.x - target.panelFrame.minX,
                    y: blurPoint.y - target.panelFrame.minY
                )
                let blurRefused = window.contentView?.hitTest(blurInWindow) == nil
                // A locked screen makes the window server's answer always "no", which would read as
                // a pass here for the wrong reason — so it is dropped rather than counted, exactly
                // as the flank probe drops it.
                let blurIsOurs = ScreenLock.isLocked
                    ? false
                    : controller.ownsWindowNumber(controller.windowNumberAtScreenPoint(blurPoint))
                lines.append(
                    "blur at \(blurPoint), \(Int(IslandLayout.blurSpread / 2))pt outside the body → "
                    + (ScreenLock.isLocked
                        ? "window server not asked (screen locked)"
                        : "window server says \(blurIsOurs ? "Isleta — CLAIMED" : "NOT Isleta")")
                    + ", hitTest \(blurRefused ? "refuses" : "ACCEPTS")"
                )

                // **And a point in the panel that the blur does not reach.** An
                // `NSVisualEffectView` is a real surface, and the question its mask cannot answer is
                // whether the window server sees the *mask* or the view's whole frame. If it sees
                // the frame, an open island claims clicks across the entire 608x400 panel — far
                // outside anything `blurRegion` accepts — and every one of them is dropped on the
                // floor. Probed at the panel's bottom-left corner, which is transparent in every
                // state the island has.
                let farPoint = CGPoint(
                    x: target.panelFrame.minX + 8,
                    y: target.panelFrame.minY + 8
                )
                let farIsOurs = ScreenLock.isLocked
                    ? false
                    : controller.ownsWindowNumber(controller.windowNumberAtScreenPoint(farPoint))
                lines.append(
                    "panel corner at \(farPoint), far outside the blur → "
                    + (ScreenLock.isLocked
                        ? "window server not asked (screen locked)"
                        : "window server says \(farIsOurs ? "Isleta — CLAIMED" : "NOT Isleta")")
                )

                let hoveringNow = controller.debugInfo().first?.isHovering ?? false
                let verdict: String
                if hoveringAtStart || hoveringNow {
                    verdict = "INCONCLUSIVE — the pointer was on the island during the test. Re-run when idle."
                } else if !flankAccepted {
                    verdict = "FAIL — the island paints a flank it will not accept a click on"
                } else if !indicatorAccepted {
                    verdict = "FAIL — the page indicator is drawn outside the region clicks are accepted in"
                } else if farIsOurs {
                    verdict = "FAIL — the open island claims clicks across the whole panel"
                } else if blurIsOurs {
                    verdict = "FAIL — the blur claims clicks; it is back in the island's own panel, "
                        + "and a click in the band no longer reaches the app underneath"
                } else if !blurRefused {
                    verdict = "FAIL — the island accepts a click on a pixel it does not draw"
                } else if !stillExpanded {
                    verdict = "FAIL — a second click on the open island closed it"
                } else if expanded, renderedExpanded {
                    verdict = "PASS — click expands and renders, clicking again holds, "
                        + "and the blur passes clicks through"
                } else {
                    verdict = "FAIL — expanded=\(expanded) rendered=\(renderedExpanded) held=\(stillExpanded)"
                }
                activities.dismissAll()
                completion(([verdict] + lines).joined(separator: "\n                  "))
            }
        }
    }
}
