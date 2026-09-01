import AppKit
import IslandActivities
import IslandKit
import IslandUI

/// Swipes the island and reports what happened (§5).
///
/// The question this exists to answer is the one that cannot be settled by reading: **which event
/// actually reaches a non-key, non-activating `NSPanel` for a trackpad swipe?** AppKit's own header
/// says scroll gestures go "to the view under the cursor", which would make key status irrelevant —
/// but this codebase has a whole section of CLAUDE.md about things that look correct and are not,
/// and every one of them was found by running something rather than by reading a header.
///
/// Two honest limits, the same ones `ClickSelfTest` carries:
///
/// - The event is synthesised and handed to `NSWindow.sendEvent`, not posted with `CGEventPost`,
///   which would need the Accessibility permission Isleta deliberately does not ask for. So this
///   exercises everything from `NSWindow.sendEvent` inward — routing to a view by hit test, the
///   panel's key status, `IslandHitTestView.scrollWheel`, `SwipeTracker`, the pin — and not the
///   window server's own routing over transparent pixels. `PassThroughSelfTest` covers that half,
///   and it covers it for scroll events too: the window server derives one event shape from the
///   backing store's alpha and uses it for every kind of mouse event.
/// - It cannot prove a *real* trackpad's phases arrive, only that the phases it constructs are read
///   correctly. The construction goes through `CGEvent` and `NSEvent(cgEvent:)` rather than a
///   hand-built NSEvent so that at least the phase fields travel the same path a real event's do.
@MainActor
enum SwipeSelfTest {

    static func isRequested() -> Bool {
        ProcessInfo.processInfo.arguments.contains("--swipe-test")
    }

    /// Two activities that exist only for the length of the test, so the queue has something to
    /// cycle *to*. Deliberately not a `BuiltInActivity`: a self-test that depends on the built-in
    /// vocabulary's current priorities would start failing when one of those is retuned.
    /// Internal rather than private so `ClickSelfTest` can present one too. Both tests need an
    /// activity that exists only for their own duration — a self-test that depends on whatever the
    /// machine happens to be playing is not a test, it is a reading.
    struct ProbeActivity: IslandActivity {
        let id: ActivityID
        /// Deliberately **not** `.notification`, which is what this was until notifications started
        /// opening the island by themselves (`ActivityKind.opensIsland`). A probe that arrives with
        /// the island already open tests something else: the click test's first click then closes
        /// rather than opens, and the stow test's swipe is ignored outright, because
        /// `IslandStowGesture` leaves an open island alone. `.systemHUD` is the nearest kind that
        /// opens nothing and has no bespoke renderer — the probe supplies its own presentations, so
        /// the kind is only ever read for those two decisions.
        let kind = ActivityKind.systemHUD
        let priority: ActivityPriority
        let expiry = ActivityExpiry.never
        let presentations: ActivityPresentations

        init(_ id: ActivityID, priority: ActivityPriority, title: String) {
            self.id = id
            self.priority = priority
            presentations = ActivityPresentations(
                compact: ActivityContent(title: title),
                expanded: ActivityContent(title: title)
            )
        }
    }

    static func run(
        controller: IslandController,
        activities: ActivityCoordinator,
        isStowed: @escaping @MainActor () -> Bool,
        isExpanded: @escaping @MainActor () -> Bool,
        expand: @escaping @MainActor () -> Void,
        currentPage: @escaping @MainActor () -> IslandPage,
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

        var lines: [String] = []
        let frontmostBefore = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
        lines.append("frontmost before: \(frontmostBefore), panel isKeyWindow: \(window.isKeyWindow)")
        lines.append("swipe tracking from scroll events enabled: \(NSEvent.isSwipeTrackingFromScrollEventsEnabled)")

        activities.dismissAll()
        activities.present(ProbeActivity("swipe.probe.a", priority: .prominent, title: "Probe A"))
        lines.append("presented \(activities.presented?.id.rawValue ?? "nil"), stowed \(isStowed())")

        let notch = target.screen.notch.rect
        // Window-local, y-up: the space `NSEvent.locationInWindow` is read in.
        let inWindow = CGPoint(x: notch.midX - target.panelFrame.minX, y: notch.midY - target.panelFrame.minY)
        let accepted = window.contentView?.hitTest(inWindow) != nil
        lines.append("hitTest(\(inWindow)) → \(accepted ? "accepted" : "REJECTED")")

        // Enough travel to clear `SwipeMetrics.commitDistance` without relying on the flick path.
        // One gesture each way: left puts the content into the notch, right brings it back.
        func gesture(deltaX: Int32 = 0, deltaY: Int32 = 0) -> Int {
            var delivered = 0
            for phase in [CGScrollPhase.began, .changed, .changed, .changed, .changed, .ended] {
                let moving = phase != .began && phase != .ended
                guard let event = scrollEvent(
                    deltaX: moving ? deltaX : 0,
                    deltaY: moving ? deltaY : 0,
                    phase: phase,
                    at: inWindow
                ) else { continue }
                window.sendEvent(event)
                delivered += 1
            }
            return delivered
        }

        /// Lets a committed page turn finish travelling before the next gesture is aimed at it.
        ///
        /// **Not for the page value, which is synchronous again.** A swipe commits by stepping
        /// `IslandPageModel.current` and then settling the tail against it
        /// (`AppDelegate.commitPageDrag`), so the page reads correctly the instant the gesture ends.
        /// What this waits for is the *tail*: the carousel is deliberately interruptible now, and a
        /// self-test that swiped again mid-flight would be measuring the interruption rather than
        /// the turn.
        ///
        /// A nested run loop rather than restructuring the whole self-test into an async chain: this
        /// is a diagnostic that runs behind a flag, the main thread has nothing else to do while it
        /// waits, and the alternative is five levels of `asyncAfter` around a verdict that has to
        /// see all of them. 0.7s clears `Motion.pageTurn`'s 0.30s response and its tail.
        func settle() {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.7))
        }

        let delivered = gesture(deltaX: -12)
        let stowedAfterLeft = isStowed()
        lines.append("swiped left through \(delivered) events → stowed \(stowedAfterLeft)")

        _ = gesture(deltaX: 12)
        let stowedAfterRight = isStowed()
        lines.append("swiped right → stowed \(stowedAfterRight)")

        // The vertical half: two fingers up on an *open* island closes it, as a click would.
        //
        // The synthesised event carries no inversion flag, so `isDirectionInvertedFromDevice` reads
        // false — the "natural scrolling off" spelling, where fingers moving up report a positive
        // delta. What a real trackpad reports on the other setting is the negative of it, and that
        // is what `IslandScrollSample.upwardDeltaY` exists to fold back together; the arithmetic is
        // pinned in `CloseGestureTests` because only one of the two spellings can be synthesised
        // here.
        expand()
        let expandedBeforeSwipe = isExpanded()
        _ = gesture(deltaY: 12)
        let expandedAfterUp = isExpanded()
        lines.append("opened → \(expandedBeforeSwipe), swiped up → expanded \(expandedAfterUp)")

        // And down does nothing: this is the one gesture in Isleta with a direction, so the
        // direction has to be worth something.
        expand()
        _ = gesture(deltaY: -12)
        let expandedAfterDown = isExpanded()
        lines.append("opened again, swiped down → expanded \(expandedAfterDown)")

        // **The horizontal axis on an *open* island turns pages** — the second half of the axis
        // matrix, and the one the stow half proves is disjoint from it. The same gesture that stows
        // a closed island must page an open one and stow nothing.
        //
        // Deliberately walked all the way round rather than one step: the pages wrap, and a
        // carousel that advanced twice and stopped would pass a one-step check.
        expand()
        let pageAtOpen = currentPage()
        var walked: [IslandPage] = []
        // **60 a sample, where the stow gestures above use 12.** A page is dragged rather than
        // triggered since 2026-08-28: it carries on distance past the middle of the page (184pt of
        // 368) or on a flick, and these synthesised events all share one timestamp, so there is no
        // velocity for a flick to be made of. Four samples of 60 is 240pt — a real swipe, and the
        // only kind that turns a page now. At the old 12 this walked three pages without moving,
        // which is what caught the change.
        for _ in 0..<IslandPage.allCases.count {
            _ = gesture(deltaX: -60)
            settle()
            walked.append(currentPage())
        }
        lines.append("opened on \(pageAtOpen.rawValue), swiped left ×\(IslandPage.allCases.count) → "
                     + walked.map(\.rawValue).joined(separator: " → "))
        let wrappedHome = walked.last == pageAtOpen
        let visitedAll = Set(walked).count == IslandPage.allCases.count
        // The open island must not have stowed on any of that — the two gestures share an axis and
        // are kept apart only by `IslandStowGesture` ignoring an open island.
        let stowedWhilePaging = isStowed()

        _ = gesture(deltaX: 60)
        settle()
        let steppedBack = currentPage()
        lines.append("swiped right → \(steppedBack.rawValue)")
        let wentBackwards = steppedBack == pageAtOpen.previous

        // **Two swipes with nothing between them**, and the `settle()` above is deliberately the
        // last one before them. This is the case the carousel was rebuilt for on 2026-08-28: a turn
        // used to swap its pages inside the settling spring's *completion*, so a second gesture
        // arriving in that window computed its neighbours from the page being left and was then
        // overwritten when the first one landed — the island stopped on the page it was animating
        // into and refused the next. It now steps the page at the commit and settles a tail against
        // it, which is what makes a turn interruptible.
        //
        // Two steps and not one: a chained swipe that lost exactly one turn is the whole symptom,
        // and a one-step check cannot tell "it turned twice" from "it turned once and stopped".
        let beforeChained = currentPage()
        _ = gesture(deltaX: -60)
        _ = gesture(deltaX: -60)
        settle()
        let afterChained = currentPage()
        lines.append("swiped left twice with no pause between → \(afterChained.rawValue)")
        let chainedBothTurns = afterChained == beforeChained.next.next

        let frontmostAfter = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
        lines.append("frontmost after: \(frontmostAfter), panel isKeyWindow: \(window.isKeyWindow), isMainWindow: \(window.isMainWindow)")

        let verdict: String
        if !accepted {
            verdict = "FAIL — the island rejected the point the swipe was aimed at"
        } else if !stowedAfterLeft {
            verdict = "FAIL — a swipe left over the island did not stow it (scrollWheel never reached us)"
        } else if stowedAfterRight {
            verdict = "FAIL — a swipe right did not bring the content back"
        } else if !expandedBeforeSwipe {
            verdict = "FAIL — the island would not open, so the close gesture could not be tested"
        } else if expandedAfterUp {
            verdict = "FAIL — two fingers up over an open island did not close it"
        } else if !expandedAfterDown {
            verdict = "FAIL — two fingers down closed the island, and only up should"
        } else if !visitedAll {
            verdict = "FAIL — swiping left over an open island did not reach every page"
        } else if !wrappedHome {
            verdict = "FAIL — the pages did not wrap back round to where they started"
        } else if stowedWhilePaging {
            verdict = "FAIL — paging an open island stowed it; the two gestures are sharing an axis"
        } else if !wentBackwards {
            verdict = "FAIL — swiping right over an open island did not step back a page"
        } else if !chainedBothTurns {
            verdict = "FAIL — a second swipe inside the first turn's settle was dropped; the carousel is not interruptible"
        } else if frontmostAfter != frontmostBefore || window.isKeyWindow || window.isMainWindow {
            verdict = "FAIL — swiping the island stole focus from the frontmost app"
        } else {
            verdict = "PASS — scrollWheel reaches a non-key panel, stows, unstows, closes on a swipe up, turns pages both ways on an open one, chains a swipe into a turn still settling, and steals no focus"
        }

        activities.dismissAll()
        completion(([verdict] + lines).joined(separator: "\n                  "))
    }

    /// Builds a gesture scroll event with a real phase on it.
    ///
    /// `wheel1` is the vertical axis and `wheel2` the horizontal. The phase has to be written as a
    /// field — `CGEvent` has no initializer that takes one — and `kCGScrollWheelEventIsContinuous`
    /// is what makes AppKit report `hasPreciseScrollingDeltas`, which is the difference between a
    /// trackpad's points and a wheel's lines. Without it the deltas would arrive multiplied by a
    /// line height.
    private static func scrollEvent(
        deltaX: Int32,
        deltaY: Int32 = 0,
        phase: CGScrollPhase,
        at location: CGPoint
    ) -> NSEvent? {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: deltaY,
            wheel2: deltaX,
            wheel3: 0
        ) else { return nil }

        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(deltaY))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(deltaX))

        // `NSEvent.locationInWindow` for an event with no window number is read as screen
        // coordinates, and `NSWindow.sendEvent` then treats it as window-local. `CGEvent.location`
        // is y-down from the top of the main display, so the y has to be flipped back through it.
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        event.location = CGPoint(x: location.x, y: mainHeight - location.y)

        return NSEvent(cgEvent: event)
    }
}
