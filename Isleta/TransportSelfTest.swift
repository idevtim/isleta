import AppKit
import IslandActivities
import IslandKit
import IslandUI

/// Presses the transport buttons and drags the scrubber, and reports whether anything happened.
///
/// ## The question it exists to answer
///
/// §4.1 says `IslandPanel` never becomes key or main — clicking the island must not take focus from
/// whatever the user is typing in. Every AppKit control and every SwiftUI control is written against
/// the assumption that a window *can* become key, so "does a SwiftUI `Button` fire in a window that
/// never will" is a genuine open question rather than a formality, and the codebase's own history
/// points the wrong way: `IslandHitTestView` handles the island's click in `mouseDown` precisely
/// because routing it through SwiftUI's gesture system "is asking for trouble that only shows up as
/// *the first click sometimes does nothing*".
///
/// This answers it by synthesising the press and asking the controller whether the command went out.
/// It covers four things a human cannot check by looking:
///
/// 1. **The play button fires.** A press at `NowPlayingExpandedLayout.playButtonCenter` produces a
///    `togglePlayPause`.
/// 2. **The drag works.** Down at 20% of the scrub bar, moved to 75%, up — and the seek that comes
///    out is for 75% of the track, not 20% and not nothing.
/// 3. **The rest of the island still responds to a click.** This is the regression the transport
///    controls could plausibly cause, and the interesting thing measured here is *why it does not*.
///    `NSHostingView` claims the whole island from `hitTest` — it has since Milestone 0, with no
///    interactive content in it at all — so every click on the island is delivered to SwiftUI first.
///    Clicks that land on nothing SwiftUI wants travel back up the **responder chain** to
///    `IslandHitTestView.mouseDown`, which is what has always expanded and collapsed the island. The
///    transport controls do not break that; they intercept the presses that land on *them* and leave
///    the rest to fall through, which is exactly the arrangement wanted.
///
///    So this asserts the *behavior* rather than the identity `hitTest` returns. Asserting the
///    latter fails on a build that works perfectly, which is how a correct implementation gets
///    "fixed" into a broken one.
///
///    **It used to assert that the click *collapsed* the island, and that had been stale since
///    2026-08-26**, when the click stopped being a toggle — "a click on the island only ever opens
///    it", because the second half of a toggle means aiming at the body of an open panel, which is
///    where all of its content is. So the assertion was asking for behaviour the app had
///    deliberately removed, and the run reported `islandStillCollapses=false` against a build that
///    was working exactly as designed. The property it was reaching for is intact and is now tested
///    the way the current policy allows: close the island, press a plain point on it, and it opens.
/// 4. **A disabled control stays disabled.** With `prohibitsSkip` set, a press on Next must produce
///    nothing — a grayed button that still fires is worse than no graying.
///
/// Like `ClickSelfTest`, the events go through `NSApp.sendEvent` rather than `CGEventPost`, which
/// would need the Accessibility permission Isleta does not ask for. So this covers everything from
/// `NSWindow.sendEvent` inward — hit testing, `acceptsFirstMouse`, the responder chain and surviving
/// `NSHostingView` — and `PassThroughSelfTest` covers the window server's half.
@MainActor
enum TransportSelfTest {

    static func isRequested() -> Bool {
        ProcessInfo.processInfo.arguments.contains("--transport-test")
    }

    /// A track that is definitely playing, definitely three minutes long, and definitely not the
    /// user's. Synthetic rather than "play something first", because the test has to be runnable on
    /// a silent machine and because a real track's duration would make the seek assertion unstable.
    static func demoActivity(
        durationSeconds: TimeInterval = 180,
        at now: Date = Date()
    ) -> BuiltInActivity {
        BuiltInActivity.nowPlaying(
            title: "Transport Self-Test",
            artist: "Isleta",
            album: "Milestone 10",
            isPlaying: true,
            timeline: ActivityTimeline(elapsed: 30, duration: durationSeconds, anchor: now, rate: 1)
        )
    }

    static func run(
        controller: IslandController,
        coordinator: ActivityCoordinator,
        nowPlaying: NowPlayingController,
        expand: @escaping @MainActor (IslandScreen) -> Void,
        /// Closes every island, by the route Escape and a click elsewhere take. Needed because a
        /// click can no longer close one — see the note on step 3.
        collapse: @escaping @MainActor () -> Void,
        /// Puts the island on the page the player is drawn on.
        ///
        /// **The island no longer opens onto the player.** It opens onto `IslandPage.home`, where
        /// the music column is a cover, two lines and three buttons — so every point this test aims
        /// at, computed from `NowPlayingExpandedLayout` against the body, lands on the calendar
        /// instead. Without this the whole run failed with "commands []" and a `hitTest` that
        /// correctly reported the hosting view: the presses were real and there was simply nothing
        /// there to press.
        showMusicPage: @escaping @MainActor () -> Void,
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
        var commands: [NowPlayingControlCommand] = []
        var seeks: [TimeInterval] = []

        // The bridge's own handlers are replaced for the duration of the test rather than observed
        // alongside them: this must not actually send `MRCommand`s to whatever the user is playing.
        // Pressing "next" on someone's music to prove a button works is not an acceptable test.
        let realCommand = nowPlaying.onCommand
        let realSeek = nowPlaying.onSeek
        nowPlaying.onCommand = { commands.append($0) }
        nowPlaying.onSeek = { seeks.append($0) }
        nowPlaying.isTransportAvailable = true

        func restore() {
            nowPlaying.onCommand = realCommand
            nowPlaying.onSeek = realSeek
        }

        // The body slot in the island's own y-down space, then in the panel's y-up space, which is
        // what `NSEvent.mouseEvent` wants. Computed from the same `ActivitySlotLayout` the renderer
        // uses rather than from remembered numbers — a test that restates the view's arithmetic
        // passes when both are wrong.
        let metrics = IslandLayout.expandedMetrics(for: screen)
        let layout = ActivitySlotLayout.resolve(
            bodySize: metrics.bodySize,
            cutoutSize: ActivitySlotLayout.cutoutSize(for: screen.notch)
        )
        guard let body = layout.frame(for: .expanded) else {
            restore()
            completion("FAIL — the expanded island affords no body slot to draw controls in")
            return
        }
        guard NowPlayingExpandedLayout.fits(in: body) else {
            restore()
            completion("FAIL — the transport rows do not fit in a \(body.size) body")
            return
        }

        let origin = IslandLayout.bodyOrigin(for: metrics, in: target.panelFrame.size)

        /// Body-space (y-down) → panel-space (y-up), which is where `NSEvent` locations live.
        func inWindow(_ point: CGPoint) -> CGPoint {
            CGPoint(
                x: origin.x + point.x,
                y: target.panelFrame.height - (origin.y + point.y)
            )
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

        coordinator.present(demoActivity())
        expand(screen)
        // The player lives on the music page now — see `showMusicPage`. Turned in the same breath as
        // the open, so the settle below covers both movements rather than only the second.
        showMusicPage()

        // Long enough for `Motion.expand` (0.38s response) to settle *and* for the 40ms content
        // follow behind it, plus the page turn's own `Motion.contentSwap`. Pressing a button that is
        // still traveling would be a real test of something, but not of this.
        after(0.9) {
            let playPoint = inWindow(NowPlayingExpandedLayout.playButtonCenter(in: body))
            let hit = window.contentView?.hitTest(playPoint)
            lines.append("play button at \(playPoint) → hitTest \(hit.map { String(describing: type(of: $0)) } ?? "nil")")

            post(.leftMouseDown, at: playPoint)
            post(.leftMouseUp, at: playPoint)

            after(0.25) {
                let pressed = commands.contains(.togglePlayPause)
                lines.append("press on play/pause → commands \(commands)")

                // A drag: down at 20%, two moves, up at 75%. Two moves rather than one because the
                // scrubber distinguishes the first event of a gesture (translation zero) from the
                // rest, and a single move would only exercise the first branch.
                let down = inWindow(NowPlayingExpandedLayout.scrubberPoint(in: body, atFraction: 0.2))
                let mid = inWindow(NowPlayingExpandedLayout.scrubberPoint(in: body, atFraction: 0.5))
                let up = inWindow(NowPlayingExpandedLayout.scrubberPoint(in: body, atFraction: 0.75))
                lines.append("scrub bar at \(down) → hitTest \(window.contentView?.hitTest(down).map { String(describing: type(of: $0)) } ?? "nil")")

                post(.leftMouseDown, at: down)
                post(.leftMouseDragged, at: mid)
                post(.leftMouseDragged, at: up)
                post(.leftMouseUp, at: up)

                after(0.25) {
                    // 75% of a 180s track is 135s. The tolerance is a couple of seconds, which is
                    // about 2pt of a 344pt bar — tight enough that a seek to the *press* point
                    // (36s) or no seek at all fails, loose enough that it does not depend on the
                    // exact inset SwiftUI resolved the row to.
                    let seeked = seeks.last
                    let dragged = seeked.map { abs($0 - 135) < 6 } ?? false
                    lines.append("drag 20% → 75% of a 180s track → seeks \(seeks.map { Int($0) })")

                    // A disabled control must stay inert. Done before the collapse check, because
                    // collapsing takes the controls off screen.
                    nowPlaying.canSkip = false
                    let nextPoint = inWindow(NowPlayingExpandedLayout.skipButtonCenter(in: body, isNext: true))
                    let before = commands.count
                    post(.leftMouseDown, at: nextPoint)
                    post(.leftMouseUp, at: nextPoint)

                    after(0.25) {
                        let disabledStayedInert = commands.count == before
                        lines.append("press on next with prohibitsSkip → commands \(commands)")
                        lines.append("still open after two presses on controls: \(presentation(screen.id))")
                        let stayedOpen = presentation(screen.id) == "expanded"

                        // The regression check, asserted as behavior: a press on the island *away*
                        // from any control still collapses it. `hitTest` reports the hosting view
                        // for this point — it does for every point on the island, and always has —
                        // so what is being checked is that the press falls through SwiftUI and up
                        // the responder chain to `IslandHitTestView.mouseDown`.
                        //
                        // The point has to be genuinely inert, and the top of the body no longer is:
                        // the cover and the title are a target that opens the player, so a press
                        // there is *supposed* to be consumed. This is the transport row's left
                        // margin — the three controls are centerd as a group with ~33pt of clear
                        // island either side of them, so this is island and nothing else.
                        // **Closed first, because a click can no longer close.** The press below has
                        // to have something observable to do, and under the current policy that is
                        // opening. Aimed at the notch's own centre rather than at a point in the
                        // expanded body: the island is at rest by then, and the expanded body's
                        // coordinates are off it.
                        collapse()

                        after(0.5) {
                            let notch = target.screen.notch.rect
                            let plain = CGPoint(
                                x: notch.midX - target.panelFrame.minX,
                                y: notch.midY - target.panelFrame.minY
                            )
                            let wasClosed = presentation(screen.id) != "expanded"
                            lines.append("plain island point \(plain) → hitTest \(window.contentView?.hitTest(plain).map { String(describing: type(of: $0)) } ?? "nil")")
                            post(.leftMouseDown, at: plain)

                            after(0.7) {
                            let collapsed = wasClosed && presentation(screen.id) == "expanded"
                            lines.append("closed, then pressed a plain island point → \(presentation(screen.id))")

                            nowPlaying.canSkip = true
                            coordinator.dismiss(Self.demoActivity().id)
                            restore()

                            let verdict: String
                            if pressed && dragged && stayedOpen && collapsed && disabledStayedInert {
                                verdict = "PASS — SwiftUI buttons fire and the scrubber drags in a panel that never becomes key"
                            } else {
                                verdict = "FAIL — button=\(pressed) drag=\(dragged) stayedOpen=\(stayedOpen) "
                                    + "plainClickStillOpens=\(collapsed) disabledInert=\(disabledStayedInert)"
                            }
                            completion(([verdict] + lines).joined(separator: "\n                      "))
                            }
                        }
                    }
                }
            }
        }
    }
}
