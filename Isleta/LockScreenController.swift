import AppKit
import IslandActivities
import IslandKit
import IslandUI
import SwiftUI

/// Owns the lock-screen now-playing card: one panel per display, and the SkyLight space that is the
/// only reason any of it is visible.
///
/// The shape is `IslandController`'s — a window per `CGDirectDisplayID`, a debounced rebuild on
/// screen changes, content pushed in from `AppDelegate.activityChanged` — with two differences that
/// are specific to this surface.
///
/// ## The panels exist only while the screen is locked
///
/// An island panel is created once and left up. These are created on `com.apple.screenIsLocked`
/// and closed on `com.apple.screenIsUnlocked`, because a panel in the lock-screen space is a panel
/// at absolute level 400, and 400 sits **below** ordinary windows on an unlocked desktop. Left up,
/// the card would be an invisible rectangle behind the user's work — harmless to look at, and
/// exactly the sort of thing that turns out to have been eating clicks three releases later.
///
/// The space itself is also created at the lock and destroyed at the unlock rather than held for the
/// process lifetime. It costs a few window-server round trips twice per lock, against holding
/// server-side state that is unused for the overwhelming majority of a session — and it means a
/// crash while unlocked, which is nearly all of them, leaks nothing.
///
/// ## Nothing here handles input
///
/// There is no hit testing, no hover, no click routing, and no `IslandHitTestView`. loginwindow
/// captures every event on the locked screen; see `LockScreenPanel`. If a future change adds a
/// control here, the control will not work, and the place to start is the lock-screen section of
/// `docs/PLATFORM-CONSTRAINTS.md` rather than this file.
@MainActor
final class LockScreenController {

    /// What the cards draw from. One for the app: every display shows the same track.
    let model = LockScreenCardModel()

    private var windows: [CGDirectDisplayID: LockScreenPanel] = [:]

    /// The padlock at the notch. A second panel because it is placed against the hardware cutout
    /// rather than against the display, and because it is drawn whenever the Mac is locked — with or
    /// without music — where the card needs a track.
    private var notchWindows: [CGDirectDisplayID: LockScreenPanel] = [:]

    /// Created at the lock, destroyed at the unlock. Nil while unlocked, which is also what
    /// `isHosting` reports to diagnostics.
    private var space: (any LockScreenSpaceHost)?

    private var isEnabled = false

    /// Whether unlocking makes a sound. Independent of `isEnabled`: somebody can want the sound
    /// without the card, which is why they are two settings rather than one.
    private var playsSounds = false

    private let sound = LockScreenSound()

    /// The stack, so a lock can ask what is playing rather than trusting what it was last told.
    ///
    /// `adopt(from:)` runs on every `ActivityChange`, and between the last one and the lock there
    /// may be minutes: a track that started before the Mac was locked is a change that happened
    /// while this controller had no panels, and the content it pushed is still correct. Re-asking
    /// at the lock costs one walk of a stack that is at most a handful of entries, and it closes
    /// the case where the push was missed entirely — a launch that happens while the screen is
    /// already locked, where `screenDidLock` runs from `start()` before any activity has ever
    /// changed.
    private weak var activities: ActivityCoordinator?

    private var distributedObservers: [any NSObjectProtocol] = []
    private var screenObservation: (any NSObjectProtocol)?
    private var accessibilityObservation: (any NSObjectProtocol)?

    /// One clamshell open emits several `didChangeScreenParameters`; the island debounces for the
    /// same reason and by the same amount.
    private var pendingRebuild: DispatchWorkItem?

    /// When, after the lock, the padlock springs out of the notch.
    ///
    /// After the island has finished going in: `AppDelegate.takeIslandsAway` collapses whatever
    /// was on stage into the cutout on `Motion.lockHandover` (0.70s), and a padlock arriving on
    /// the same spring at the same moment would be two shapes crossing. One curve's length, so the
    /// cutout is empty when this starts. An empty island has nothing to collapse and the padlock
    /// waits for nothing — the shield's fade is happening either way.
    static let lockArrivalAt: TimeInterval = 0.70

    /// When, after the unlock, the open padlock starts collapsing back into the notch.
    ///
    /// The unlock is three beats on one spring: the shackle opens (symbol replace, ~0.3s) and is
    /// **held open** — this is most of the number; the owner wants it seen, so the user knows the
    /// unlock took — then the shape shrinks into the cutout (`playDeparture`, one
    /// `Motion.lockHandover`, 0.70s), and the island springs back out of the empty cutout at
    /// `AppDelegate.returnDelay`. This plus one `lockHandover` has to land inside `returnDelay` or
    /// the two shapes overlap; `returnDelay` is private to `AppDelegate`, so the two are a
    /// convention written down in both places rather than read from one.
    static let unlockCollapseAt: TimeInterval = 1.00

    /// How long the surface stays on screen after the unlock, in total. The windows go at the end
    /// of it whether or not anything is still moving — a *maximum*, not a wait — and by then the
    /// departure has taken the shape to zero, so there is nothing on them to cut off.
    static let unlockLinger: TimeInterval = 1.75

    /// Injected so tests can substitute a host that records rather than touching the window server.
    ///
    /// A `var` for one caller: `presentDemoIfRequested` swaps it for a host that hosts nothing, so
    /// the surfaces can be looked at on an unlocked desktop. See `DesktopLockScreenSpace`.
    private var makeSpace: () -> (any LockScreenSpaceHost)?

    init(makeSpace: @escaping () -> (any LockScreenSpaceHost)? = { SkyLightLockScreenSpace.make() }) {
        self.makeSpace = makeSpace
    }

    // MARK: - Lifecycle

    func start() {
        guard screenObservation == nil else { return }

        let distributed = DistributedNotificationCenter.default()
        distributedObservers.append(
            distributed.addObserver(
                forName: SystemEventsSourceNames.sessionDidLock,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.screenDidLock() }
            }
        )
        distributedObservers.append(
            distributed.addObserver(
                forName: SystemEventsSourceNames.sessionDidUnlock,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.screenDidUnlock() }
            }
        )

        screenObservation = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRebuild() }
        }

        // Read straight from `NSWorkspace` rather than through `AccessibilityPreferences`: two
        // observers on one notification have no ordering between them, so going through the other
        // one would read whatever it happened to hold.
        accessibilityObservation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyAccessibility() }
        }

        applyAccessibility()

        // A launch that happens while the screen is already locked is a real case — Isleta is a
        // login item, and a Mac that wakes to a lock screen starts us behind it. `ScreenLock` is the
        // only way to know, because the notification fired before we existed.
        if ScreenLock.isLocked { screenDidLock() }
    }

    /// Takes every card down and destroys the space.
    ///
    /// Called from `applicationWillTerminate`, which returns into `exit()` — so this is synchronous
    /// through to the window server. A space that is merely abandoned outlives the process until
    /// logout, which is the `applicationWillTerminate` trap in CLAUDE.md and the reason
    /// `SkyLightOverlaySpace.tearDown` is written the same way.
    func stop() {
        pendingRebuild?.cancel()
        pendingRebuild = nil
        teardownWindowsAndSpace()

        let distributed = DistributedNotificationCenter.default()
        for observer in distributedObservers { distributed.removeObserver(observer) }
        distributedObservers.removeAll()

        if let screenObservation {
            NotificationCenter.default.removeObserver(screenObservation)
            self.screenObservation = nil
        }
        // Removed from **`NSWorkspace`'s** center, not `NotificationCenter.default`'s: a token from
        // one center handed to the other removes nothing and reports nothing.
        if let accessibilityObservation {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObservation)
            self.accessibilityObservation = nil
        }
    }

    // MARK: - What the shell pushes in

    /// Whether unlocking makes a sound.
    func apply(playsSounds: Bool) {
        self.playsSounds = playsSounds
    }

    /// Whether the user wants the card at all.
    func apply(isEnabled: Bool) {
        guard isEnabled != self.isEnabled else { return }
        self.isEnabled = isEnabled
        if !isEnabled {
            teardownWindowsAndSpace()
        } else if ScreenLock.isLocked {
            screenDidLock()
        }
    }

    /// Adopts the Now Playing activity's content, wherever it is in the stack.
    ///
    /// Reads `presented` *and* `queued`, because a volume HUD or a device connecting preempts Now
    /// Playing on the island's stage and has nothing to do with what is playing. On a locked screen it is even clearer — none of those preempting
    /// activities would be drawn here at all.
    func adopt(from coordinator: ActivityCoordinator) {
        let wasPlaying = model.isPlaying
        let activity: (any IslandActivity)?
        if let presented = coordinator.presented, presented.kind == .nowPlaying {
            activity = presented
        } else {
            activity = coordinator.queued.first { $0.kind == .nowPlaying }
        }
        let content = activity?.presentations.expanded
        model.content = content
        // A playhead arrives as `ActivityValue.timeline`, which carries an anchor and a rate rather
        // than a sample — that is what lets the card evaluate it against its own display link
        // instead of the player being re-asked once a second. Any other value shape (a volume
        // fraction, a countdown) has no playhead, and the card draws no progress line at all.
        if case .timeline(let timeline)? = content?.value {
            model.timeline = timeline
        } else {
            model.timeline = nil
        }

        // The surface is two widths — the closed island, and the island plus its flanked growth
        // when there is a track. A track starting while the screen is already locked therefore has
        // to resize the *panel*, not just what is drawn in it: SwiftUI would happily lay the wider
        // content out inside the narrower window and clip it, which looks like a truncation bug
        // rather than a window that is the wrong size.
        if model.isLocked, wasPlaying != model.isPlaying { rebuild() }
    }

    /// Hands the controller the stack it re-reads at every lock. See `activities`.
    func attach(activities: ActivityCoordinator) {
        self.activities = activities
    }

    /// Hands the card the player it should read the cover from. Called once, at construction, for
    /// the reason `LockScreenCardModel.nowPlaying` records: artwork lands after the track does, so
    /// it has to be observed rather than snapshotted.
    func attach(nowPlaying: NowPlayingController) {
        model.nowPlaying = nowPlaying
    }

    /// `--lockscreen-demo`: put both lock surfaces on the **unlocked** desktop, with a synthetic
    /// track, and leave them there.
    ///
    /// This surface is the only one in Isleta that cannot be looked at during ordinary development,
    /// and that has been expensive twice over: the material was wrong for a release and the card's
    /// feed was severed for a day, both of them things a glance would have caught. Every question
    /// about it otherwise costs a lock, a look, and a login — which is a slow loop, and a lossy one,
    /// because "nothing showed up" is equally consistent with the space failing, the panels not
    /// being built, the panels being below the shield, and nothing being queued to play.
    ///
    /// **It is not a substitute for locking the screen**, and two things it cannot answer are the
    /// two the shield owns: whether the space still composites above it, and what Liquid Glass
    /// samples when what is behind it is loginwindow rather than a desktop. It answers layout,
    /// content, motion and material *on a desktop*, which is most of what changes.
    ///
    /// **The body is inside the `#if`, not merely the flag it reads.** A Debug-only value read
    /// into a `let` a Release build can see makes the branch below provably dead, and `-warnings-as-errors` fails Release on "will never be executed" where
    /// `Tools/check.sh`, which builds Debug, cannot see it.
    func presentDemoIfRequested() {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--lockscreen-demo") else { return }
        makeSpace = { DesktopLockScreenSpace() }
        isEnabled = true
        // Straight into the model rather than through the coordinator, so the demo works under
        // `--no-sources` and does not take the island's stage from whatever else is being looked at
        // in the same run. `screenDidLock` re-adopts from the stack when there is one, so this is
        // set after it rather than before.
        screenDidLock()
        let activity = BuiltInActivity.nowPlaying(
            title: "Lock Screen Demo",
            artist: "Isleta",
            album: "Stage 7.9",
            isPlaying: true,
            timeline: ActivityTimeline(elapsed: 42, duration: 214, anchor: Date(), rate: 1)
        )
        model.content = activity.presentations.expanded
        model.timeline = ActivityTimeline(elapsed: 42, duration: 214, anchor: Date(), rate: 1)
        IslandLog.space.info("--lockscreen-demo: the lock surfaces on an unlocked desktop")
        #endif
    }

    // MARK: - Lock and unlock

    private func screenDidLock() {
        model.isLocked = true
        // Before anything is built, so the panel this lock creates is sized for what is actually
        // playing rather than for what was playing at the last activity change. See `activities`.
        if let activities { adopt(from: activities) }
        // No sound at the lock — see `LockScreenSound`. The unlock's plays before the `isEnabled`
        // guard there because it is about the unlock, not the card.
        guard isEnabled else { return }

        if space == nil {
            space = makeSpace()
            IslandLog.space.info(
                space?.isHosting == true
                    ? "lock screen space created"
                    : "lock screen space unavailable — no card on the lock screen"
            )
        }
        // A space we could not create is the fallback engaging, not an error. Building panels
        // anyway would put them under the shield, where they are invisible and pointless.
        guard space?.isHosting == true else { return }

        model.isUnlocking = false
        rebuild()

        // The padlock springs out of the notch the way the island's own content comes back after
        // a lock — `Motion.lockHandover` from a third of its size — once the island has finished
        // going in (`lockArrivalAt`). Also necessarily after the panel has been ordered front: an
        // animation committed in the same transaction as the hosting view's first layout has no
        // on-screen frame to travel from, and arrives already finished. `reentry` is zeroed now so
        // the first composited frame is an empty cutout, not a padlock that then blinks and grows.
        model.hideForArrival(reduceMotion: model.reduceMotion)
        DispatchQueue.main.asyncAfter(deadline: .now() + LockScreenController.lockArrivalAt) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.model.isLocked else { return }
                self.model.playArrival(reduceMotion: self.model.reduceMotion)
            }
        }

        // A second in, so the shield has finished fading up and our backing stores exist. Asking
        // before compositing is `PassThroughSelfTest.hasComposited`'s trap: every question about
        // window order is answered by whatever was there first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.model.isLocked else { return }
                self.logCompositingPosition()
                self.measurePointerReadability()
            }
        }
    }

    /// The unlock is the half that cannot simply tear down.
    ///
    /// The padlock has to be **on screen while it opens and collapses**, so the windows outlive
    /// the notification by the length of those two beats. The card goes immediately — it is a
    /// readout of something the user is about to see on their own desktop, and holding it over the
    /// unlock would put it on top of the fading shield, which is the two-animations-at-once
    /// complaint `AppDelegate.returnDelay` already records for the island.
    private func screenDidUnlock() {
        model.isLocked = false
        sound.play(.unlocked, isEnabled: playsSounds)

        guard !windows.isEmpty || !notchWindows.isEmpty else {
            teardownWindowsAndSpace()
            return
        }
        model.isUnlocking = true
        // The surface goes away under a pointer that never moved, so no crossing is ever reported.
        // Without this the next lock starts already hovered — and, worse, silently, because the
        // haptic only fires on a crossing that now never happens.
        model.clearHover()
        // **Three beats, in order: open, collapse, and then the island.** `isUnlocking` above has
        // already started the shackle swinging. At `unlockCollapseAt` the open padlock goes back
        // into the notch on the arrival's own spring, reversed; `AppDelegate.returnDelay` then
        // brings the island out of the empty cutout. The windows go at `unlockLinger`, a maximum
        // rather than a wait on anything — by then the departure has ended at zero.
        //
        // Not derived: a spring has no duration, and `returnDelay` is loginwindow's dissolve
        // judged by eye. Written down in both places rather than read from one — see
        // `unlockCollapseAt`.
        DispatchQueue.main.asyncAfter(deadline: .now() + LockScreenController.unlockCollapseAt) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.model.isLocked else { return }
                self.model.playDeparture(reduceMotion: self.model.reduceMotion)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + LockScreenController.unlockLinger) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.model.isLocked else { return }
                self.model.isUnlocking = false
                self.teardownWindowsAndSpace()
            }
        }
    }

    private func teardownWindowsAndSpace() {
        model.isUnlocking = false
        model.clearHover()
        for window in Array(windows.values) + Array(notchWindows.values) {
            space?.release(window)
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
        notchWindows.removeAll()
        space?.tearDown()
        space = nil
    }

    // MARK: - Windows

    private func scheduleRebuild() {
        pendingRebuild?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.model.isLocked, self.isEnabled else { return }
                self.rebuild()
            }
        }
        pendingRebuild = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// The display the lock surface belongs on: **the one holding the menu bar**.
    ///
    /// `screen.frame.origin == .zero` rather than `NSScreen.main`, which follows keyboard focus and
    /// moves. "Primary" means the same thing everywhere in this codebase.
    ///
    /// One display, not all of them. The first build put an identical panel on every screen, which
    /// on a three-display desk is three copies of one fact, three sets of window-server state, and
    /// three things to tear down. macOS itself draws the lock screen's clock and password field on
    /// one display; this follows it.
    private func primaryScreen() -> (id: CGDirectDisplayID, screen: NSScreen)? {
        let candidates = NSScreen.screens
        let chosen = candidates.first { $0.frame.origin == .zero } ?? candidates.first
        guard let chosen,
              // `NSScreen.CGDirectDisplayID` is new in macOS 26 but is NS_REFINED_FOR_SWIFT and not
              // surfaced under an obvious Swift name in this SDK; the device description key is the
              // long-standing route and returns the same value.
              let number = chosen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? NSNumber
        else { return nil }
        return (CGDirectDisplayID(number.uint32Value), chosen)
    }

    /// Two panels, on the primary display, keyed by `CGDirectDisplayID` and **never** by index into
    /// `NSScreen.screens` — CLAUDE.md's rule: the array reorders when a display sleeps.
    private func rebuild() {
        guard let (id, screen) = primaryScreen() else { return }

        let island = IslandScreen(
            id: id,
            name: screen.localizedName,
            frame: screen.frame,
            backingScaleFactor: screen.backingScaleFactor,
            notch: NotchResolver.resolve(
                screenFrame: screen.frame,
                safeAreaTop: screen.safeAreaInsets.top,
                auxiliaryTopLeft: screen.auxiliaryTopLeftArea,
                auxiliaryTopRight: screen.auxiliaryTopRightArea
            )
        )
        // Handed to the model rather than read twice, because the size a surface draws at and the
        // size its panel is built at have to be the same number. Two readers of one screen is how a
        // panel ends up a few points smaller than its content and clips it.
        model.screen = island

        place(
            &windows,
            id: id,
            frame: LockScreenCardLayout.panelFrame(inScreenFrame: screen.frame),
            view: LockScreenCardView(model: model)
        )
        place(
            &notchWindows,
            id: id,
            frame: LockScreenNotchLayout.panelFrame(for: island),
            view: LockScreenNotchView(model: model)
        )
    }

    /// Builds or repositions one panel and hosts it in the lock-screen space.
    private func place(
        _ store: inout [CGDirectDisplayID: LockScreenPanel],
        id: CGDirectDisplayID,
        frame: NSRect,
        view: some View
    ) {
        let panel: LockScreenPanel
        if let existing = store[id] {
            panel = existing
            // Repositioned, never animated — `LockScreenPanel`'s rule.
            panel.setFrame(frame, display: true)
        } else {
            panel = LockScreenPanel(contentRect: frame)

            // **The hosting view goes inside a plain container, and that is load-bearing.**
            //
            // An `NSHostingView` set directly as `contentView` resizes the *window* to its own
            // fitting size. Both of these root views carry a fixed `.frame`, so the window collapsed
            // to exactly the content size while keeping an origin computed for content **plus**
            // shadow margin — putting each surface off-center by precisely one margin. Measured on
            // hardware: a notch panel logged as 265x32 at x=713 when the layout asked for 301x68 at
            // x=713, i.e. 18pt left of the cutout it is supposed to hang from.
            //
            // A container has no opinion about its own size, so the window keeps the frame it was
            // given.
            let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
            container.autoresizingMask = [.width, .height]

            // A plain `NSHostingView`, not `IslandHostingView`. That subclass exists to answer
            // `acceptsFirstMouse` so clicks reach a panel that never becomes key — and this panel
            // never receives a click at all, so using it would state an intention the window server
            // will not honor.
            let hosting = NSHostingView(rootView: view)
            hosting.frame = container.bounds
            hosting.autoresizingMask = [.width, .height]
            container.addSubview(hosting)

            panel.contentView = container
            store[id] = panel
        }

        // Hosted **before** ordering in. A window added to the space after it is already on screen
        // flickers through one composited frame at its own level — which on a locked screen means
        // one frame underneath the shield.
        space?.host(panel)
        panel.orderFrontRegardless()

        // Anything left from a previous arrangement: the primary display changed, or one was
        // unplugged.
        for (otherID, window) in store where otherID != id {
            space?.release(window)
            window.orderOut(nil)
            window.close()
            store.removeValue(forKey: otherID)
        }
    }

    /// Logs where our panels ended up relative to loginwindow's shield, once per lock.
    ///
    /// This surface cannot be checked by looking at it — it is only on screen while the Mac is
    /// locked, so every question about it otherwise has to be answered by asking the owner what they
    /// saw. That is a slow loop and a lossy one: "nothing showed up" is equally consistent with the
    /// space failing, the panels not being built, the panels being built below the shield, and
    /// nothing being queued to play.
    ///
    /// So the app answers it. `CGWindowListCopyWindowInfo` returns windows in front-to-back order,
    /// and **that ordering is the compositing order** — which is the measurement that matters here.
    /// It is emphatically *not* `NSWindow.windowNumber(at:)`: that answers "would a click land",
    /// loginwindow captures every event at the lock, and reading the second as the first is the
    /// mistake that cost thirteen probe runs.
    ///
    /// One line per lock, at `info`. That is a system event, not a hot path, and it needs no
    /// permission: `kCGWindowOwnerName` and `kCGWindowLayer` are readable without Screen Recording —
    /// only `kCGWindowName` and the image are gated, and neither is asked for.
    private func logCompositingPosition() {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return }

        let ours = Set(windows.values.map(\.windowNumber) + notchWindows.values.map(\.windowNumber))
        var aboveShield = 0
        var belowShield = 0
        var seenShield = false
        for entry in list {
            let owner = entry[kCGWindowOwnerName as String] as? String ?? ""
            let number = entry[kCGWindowNumber as String] as? Int ?? -1
            if owner == "loginwindow" { seenShield = true; continue }
            guard ours.contains(number) else { continue }
            if seenShield { belowShield += 1 } else { aboveShield += 1 }
        }

        IslandLog.space.info(
            "lock screen panels: \(aboveShield) above the shield, \(belowShield) below, "
                + "\(windows.count) cards + \(notchWindows.count) notch, playing=\(model.isPlaying), "
                + "card=\(windows.values.first.map { NSStringFromRect($0.frame) } ?? "none"), "
                + "notchPanel=\(notchWindows.values.first.map { NSStringFromRect($0.frame) } ?? "none"), "
                + "notch=\(model.screen.map { NSStringFromRect($0.notch.rect) } ?? "none"), "
                + "notchKind=\(model.screen.map { String(describing: $0.notch.kind) } ?? "none"), "
                + "screen=\(model.screen.map { NSStringFromRect($0.frame) } ?? "none")"
        )
    }

    /// Measures whether the pointer is readable while the screen is locked.
    ///
    /// The claim this settles: earlier in this work I said hover on the lock screen was
    /// "impossible". That was **wrong as stated**. What is measured is that loginwindow's shield
    /// wins `NSWindow.windowNumber(at:)` for every window including a competitor's, so *our window
    /// receives no events* — no `mouseEntered`, no `NSTrackingArea`, no clicks. It does **not**
    /// follow that the pointer's position is unreadable, because `NSEvent.mouseLocation` is a global
    /// query answered by the window server rather than an event delivered to us. `HoverSelfTest` and
    /// `AppDelegate` already read it.
    ///
    /// So this samples it a few times across a lock and logs whether it moves. If it does, hover —
    /// and the haptic that goes with it — is buildable on this surface, driven by a poll while
    /// locked rather than by a tracking area. If it never moves, the pointer is genuinely frozen
    /// behind the shield and the answer is the one I gave, for a better reason than I gave it.
    ///
    /// A one-shot measurement, not a feature: five samples, half a second apart, one log line, and
    /// nothing retained. §9's no-polling rule is about the idle path, and this runs only across a
    /// lock and only while the setting is on.
    private func measurePointerReadability() {
        var samples: [NSPoint] = []
        func sample(_ remaining: Int) {
            guard model.isLocked else { return }
            samples.append(NSEvent.mouseLocation)
            guard remaining > 0 else {
                let distinct = Set(samples.map { "\(Int($0.x)),\(Int($0.y))" })
                IslandLog.space.info(
                    "lock screen pointer: \(samples.count) samples, \(distinct.count) distinct — "
                        + "first=\(NSStringFromPoint(samples.first ?? .zero)) "
                        + "last=\(NSStringFromPoint(samples.last ?? .zero))"
                )
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated { sample(remaining - 1) }
            }
        }
        sample(5)
    }

    private func applyAccessibility() {
        let workspace = NSWorkspace.shared
        model.reduceMotion = workspace.accessibilityDisplayShouldReduceMotion
        model.reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
        model.increaseContrast = workspace.accessibilityDisplayShouldIncreaseContrast
    }
}

/// The two distributed notification names, spelled once.
///
/// `SystemEventsSource` already declares these as `public static let` and this could read them from
/// there — except that `IslandSources` is the package that spawns a Perl helper and asks for
/// Accessibility, and this controller has no other reason to import it. Re-declaring two strings is
/// cheaper than that dependency; they are asserted equal in `LockScreenControllerTests` so the two
/// spellings cannot drift.
enum SystemEventsSourceNames {
    static let sessionDidLock = Notification.Name("com.apple.screenIsLocked")
    static let sessionDidUnlock = Notification.Name("com.apple.screenIsUnlocked")
}
