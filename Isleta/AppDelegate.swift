import AppKit
import Carbon.HIToolbox
import IslandActivities
import IslandKit
import IslandSettings
import IslandSources
import IslandUI
import QuartzCore
import SwiftUI

/// The app shell. Its whole job is wiring: it owns the `IslandController`, one view model per
/// screen, the debug hot keys and the status item — and nothing else. All the real behavior lives
/// in the packages, which is the check that the layering in §3 is honest.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var controller: IslandController?
    private var models: [CGDirectDisplayID: IslandScreenModel] = [:]

    /// One coordinator for the whole app, not one per screen.
    ///
    /// Every island shows the same thing, because there is only one user and one thing they are
    /// doing. A coordinator per screen would give each display its own stack, its own expiry clock
    /// and its own idea of what is presented — so a volume HUD would preempt Now Playing on the
    /// laptop and not on the external, and the two would drift further apart with every change. The
    /// per-screen state that genuinely differs is geometry, and that is what `IslandScreenModel` is.
    private let activities = ActivityCoordinator()

    /// The swipe (§5). One for the app, for the same reason the coordinator is — see its own note.
    private lazy var swipes = SwipeController(
        activities: activities,
        swipeModels: { [weak self] in self?.models.values.map(\.swipe) ?? [] },
        reduceMotion: { [weak self] in self?.accessibility.reduceMotion ?? false },
        isStowed: { [weak self] in self?.models.values.first?.isStowed ?? false },
        isExpanded: { [weak self] in self?.models.values.contains(where: \.isExpanded) ?? false },
        setStowed: { [weak self] stowed in self?.setStowedEverywhere(stowed) },
        collapse: { [weak self] in self?.collapseAll() },
        // The shelf takes the vertical axis **only when it has somewhere to scroll to**, which is
        // the difference between it and the surfaces below: those carry their own exits and can
        // afford to own the axis unconditionally, and a shelf that fits on screen has to leave the
        // close gesture reachable. `ShelfController.canScroll` is where that is decided.
        canScrollShelf: { [weak self] in self?.shelf.canScroll ?? false },
        scrollShelf: { [weak self] sample in self?.shelf.scroll(sample) },
        // The Up Next surface owns the vertical axis unconditionally while it is up, unlike the
        // shelf. It can afford to because it carries its own exit — the ✕ in its header, which is
        // also the Up Next button in the transport row underneath it — so a flick that scrolls
        // rather than closes never leaves the user stuck in it.
        isShowingNowPlayingQueue: { [weak self] in self?.isShowingNowPlayingQueue ?? false },
        scrollNowPlayingQueue: { [weak self] sample in self?.scrollNowPlayingQueue(sample) },
        isShowingDropHistory: { [weak self] in self?.dropHistoryModel.isShowing ?? false },
        // The month grid is a drill-down over the home page rather than a page of its own, so it
        // takes the horizontal axis while it is up: a swipe there is a gesture with nowhere to go.
        canTurnPage: { [weak self] in
            guard let self else { return false }
            return self.pages.canTurn && !self.glance.isShowingSchedule
        },
        beginPageDrag: { [weak self] step in self?.beginPageDrag(step: step) },
        commitPageDrag: { [weak self] steps in self?.commitPageDrag(by: steps) },
        settlePageDrag: { [weak self] in self?.settlePageDrag() },
        setTurnDirection: { [weak self] direction in self?.pages.setTurnDirection(direction) },
        scrollDropHistory: { [weak self] sample in self?.dropHistory.scroll(sample) }
    )

    private let hotKeys = HotKeyMonitor()
    private let performance = PerformanceProbe()
    private let accessibility = AccessibilityPreferences()
    private let settings = SettingsStore.shared
    /// Concrete rather than `any SoftwareUpdater`, so the shell can call `start()` on it. Everything
    /// downstream still sees only the protocol — `SettingsWindowController` takes `any
    /// SoftwareUpdater` and IslandSettings never learns that Sparkle exists.
    private let updater = SparkleUpdater()

    /// The six sources, built after the first frame — see `startSources()`. Optional rather than
    /// `lazy`, because "not built yet" is a state the settings change handler has to be able to see:
    /// a configuration applied before the hub exists is applied to it at construction instead, which
    /// is one code path rather than a launch branch and a change branch that have to agree.
    private var sources: SourceHub?

    /// How far down the Up Next list the user has scrolled. One for the app, for the same reason
    /// `NowPlayingController` is one instance: two islands showing one queue have to be showing the same part of
    /// it.
    private var nowPlayingQueueScroll = NowPlayingQueueScroll()

    /// Whether the open island is showing the Up Next surface.
    ///
    /// Read from `NowPlayingController` rather than stored here, because that object is already
    /// app-wide for exactly this reason — and a second copy would be a
    /// second answer to a question that has one, which is the failure `IslandPresentation` is
    /// written around.
    private var isShowingNowPlayingQueue: Bool {
        nowPlaying?.controller.isShowingQueue ?? false
    }

    /// How much drawable height the open island needs for whatever is on stage, or nil for the
    /// default size (`ActivityExpandedHeight.contentHeight(for:kind:)`).
    ///
    /// Held here because three separate paths have to agree about it: the shape table each model is
    /// drawn from, `IslandController`'s idea of the clickable and hovered island, and the panels
    /// rebuilt when a display is connected. A value passed at only the first of those would revert
    /// to the default the next time somebody plugged in a monitor — the same failure
    /// `IslandController` documents for `peekScale`.
    private var expandedContentHeight: CGFloat?

    /// How wide the open island currently is, or nil for `IslandLayout.expandedBodySize.width`.
    ///
    /// `expandedContentHeight`'s twin, held here for its reason and kept in step with it at every
    /// site that sets one — the shape table, `IslandController.expandedContentWidth`, and the
    /// panels rebuilt when a display is connected all have to agree. The month grid is the one
    /// surface that asks for more than the default; see `expandedContentWidthForStage`.
    private var expandedContentWidth: CGFloat?

    /// How long a chip picked from the switcher row holds the stage.
    ///
    /// Longer than `ActivityStack.defaultPinHold`'s eight seconds, which was tuned for a *swipe* —
    /// a gesture made in passing, on an island the user may not even have opened. Clicking a chip
    /// is a deliberate statement about what they want to look at, and having it lapse while they
    /// are still reading would be the island overruling them.
    private static let pinHoldForClick: Duration = .seconds(30)

    // MARK: - Shelf (§5, Milestone 3)
    //
    // One model and one store for the whole app, for the same reason there is one
    // `ActivityCoordinator`: there is one user holding one thing. `ShelfController` is the wiring,
    // and everything it needs from this class is passed in as a closure so that the shelf can be
    // read as one file rather than as edits scattered through this one.

    private let shelfModel = ShelfModel()
    private let shelfStore = ShelfStore()

    /// The iCloud link provider, resolved at runtime with a real fallback — see
    /// `ShareLinkProviding`. `UnavailableShareLinkProvider` is not an error path: every file
    /// reports `.airDropInstead`, so the menu draws AirDrop where it would have drawn Copy link.
    private let shareLink: any ShareLinkProviding = {
        let provider = CloudDriveShareLinkProvider()
        return provider.isAvailable ? provider : UnavailableShareLinkProvider()
    }()

    /// What Isleta has done with the files it was given. App-wide for `shelfModel`'s reason: there
    /// is one user who did one set of things.
    private let dropHistoryModel = DropHistoryModel()

    private lazy var dropHistory = DropHistoryController(
        model: dropHistoryModel,
        reduceMotion: { [weak self] in self?.accessibility.reduceMotion ?? false }
    )

    private lazy var shelf = ShelfController(
        shelf: shelfModel,
        store: shelfStore,
        activities: activities,
        reduceMotion: { [weak self] in self?.accessibility.reduceMotion ?? false },
        // Routed through the same `transition(on:_:)` a click goes through, which is what gives the
        // drag the widen-then-tighten hit region protocol for free — a drop arriving while the
        // island is still growing cannot fall into a gap between what is drawn and what we accept.
        setExpanded: { [weak self] screen, expanded in
            self?.transition(on: screen) { model, reduceMotion, completion in
                model.setExpanded(expanded, reduceMotion: reduceMotion, completion: completion)
            }
        },
        screenModel: { [weak self] id in self?.models[id] },
        screens: { [weak self] in self?.controller?.screens ?? [] },
        // The keyboard, through here rather than straight to `IslandController`, because there is
        // one of it and the reply composer wants it too — `keyboardScreen` is the single answer to
        // "which panel has key, and why", and a second feature reaching past it is how the island
        // ends up holding the keyboard after the surface that asked for it has gone.
        takeKeyboard: { [weak self] id in
            guard let self, let controller = self.controller else { return false }
            self.keyboardScreen = id
            return controller.setAcceptingKeyboardInput(true, forScreen: id)
        },
        releaseKeyboard: { [weak self] in self?.handBackKeyboard() }
    )

    /// Built alongside the hub, and torn down with it. Nil until then, and nil for the whole of a
    /// `--no-sources` run: the island then has no Now Playing controller and `ActivityLayerView`
    /// falls back to the generic renderer, which is the correct behavior rather than a degraded one
    /// — there is no cover, no transport and no scrub state to draw.
    private var nowPlaying: NowPlayingBridge?

    /// The lock-screen card. Nil on a build with no sources, exactly as `nowPlaying` is.
    private var lockScreen: LockScreenController?

    /// The day and the weather, for `GlanceLayerView`.
    ///
    /// One instance for the whole app, pushed into every screen model — the same arrangement
    /// `NowPlayingController` has, and for the same reason: there is one day and one sky, and a
    /// model per panel would let the laptop and an external display disagree about what is next.
    ///
    /// Built here rather than by `CalendarSource`, because IslandSources contains no SwiftUI and
    /// this is `@Observable` state a view reads. The source publishes values into it.
    private let glance = GlanceModel()

    /// Which page the open island is on. One for the whole app — see `IslandPageModel`, which says
    /// why two displays must not be able to disagree about it.
    private let pages = IslandPageModel()

    private lazy var settingsWindow = SettingsWindowController(
        store: settings,
        updater: updater,
        // A closure, evaluated when the window appears and whenever Isleta comes back to the front.
        // Every authorization behind these rows is read live from the system, and the user changes
        // them by leaving for System Settings and coming back.
        sourceRows: { [weak self] in
            self?.sources?.refreshAuthorizations()
            return self?.sources?.settingsRows ?? []
        },
        // Asked of the controller rather than of `NSScreen`, because the question is not "does any
        // display lack a notch" but "is Isleta drawing an island that has no cutout under it" —
        // `IslandPlacement` gives an island only to notched displays, except on a Mac with none at
        // all, where the primary display gets a synthesized one so the app has any UI.
        hasSynthesizedIsland: { [weak self] in
            self?.controller?.screens.contains { $0.notch.kind == .synthesized } ?? false
        },
        // The same call the status menu's "Export Logs…" makes. In the window as well as in the
        // menu because the menu is now something a user can hide, and this is the one thing a
        // person is asked for when they report a bug — see `SettingsView.diagnosticsCard`. The
        // report is assembled here, at the moment of the click, for the same reason `sourceRows`
        // is a closure: it describes what Isleta can see *now*.
        exportLogs: { [weak self] in self?.runLogExport(to: nil) },
        // A closure for the same reason `sourceRows` is: the calendar's authorization, the user's
        // calendar list and the location status all change while the user is away in System
        // Settings, and every one of them is a live system query too expensive to make from `body`.
        glanceState: { [weak self] in self?.sources?.glanceSettingsState() ?? GlanceSettingsState() },
        // And a closure for the same reason again. The notification roster grows while the window
        // is shut, Focus is granted in System Settings rather than here, and
        // `INFocusStatusCenter.authorizationStatus` is a 21 ms live read that `body` would make
        // once per keystroke.
        sourcesState: { [weak self] in self?.sources?.sourcesPaneState() ?? SourcesPaneState() },
        // The two things that were reachable only from the status-item menu, which
        // `showMenuBarIcon` can switch off. Quit is the serious one: a user who hid the icon had no
        // way to stop Isleta short of Activity Monitor. See `SettingsView.reopenAndQuitCard`.
        openSetupGuide: { [weak self] in self?.openOnboarding() },
        quit: { [weak self] in self?.quit() }
    )
    /// The first-run flow. Built lazily like the settings window, so a Mac that has already been
    /// through it never constructs one.
    ///
    /// The state is a closure for `glanceState`'s reason and one more: the flow's five permission
    /// pages are read *between* pages and again whenever Isleta comes back to the front, because
    /// the Accessibility page's expected path is the user leaving for System Settings and returning.
    /// A value captured at construction would be the answers as they stood before the user was
    /// asked anything.
    private lazy var onboardingWindow = OnboardingWindowController(
        store: settings,
        state: { [weak self] in self?.sources?.onboardingState() ?? OnboardingState() }
    )

    private var statusItem: NSStatusItem?
    private var escapeHotKey: UInt32?

    /// Watches for a click anywhere else while an island is open, so the island closes the way every
    /// transient surface on the Mac does.
    ///
    /// A **global** monitor, which means it sees only events delivered to *other* applications —
    /// clicks on the island itself are delivered to us and never reach it, so "this monitor fired"
    /// and "the user clicked away" are the same statement and there is no coordinate test to get
    /// wrong. Held only while an island is expanded, exactly like the Escape hot key: §9 forbids
    /// standing machinery on the idle path, and a monitor watching every click on the machine is
    /// precisely that.
    ///
    /// Mouse-down monitors need no Accessibility grant; the keyboard ones do. That is why this can
    /// exist at all while Isleta still asks for nothing at launch (§10).
    private var outsideClickMonitor: Any?

    #if DEBUG
    /// Frame intervals for the island's window, behind `--hitch-probe`. See `AnimationHitchProbe`.
    private let hitchProbe = AnimationHitchProbe()
    #endif
    /// Every hot key currently held, so the whole set can be released before the next install.
    private var registeredShortcuts: [(id: UInt32, action: ShortcutAction)] = []

    /// The shortcut record the registrations above were built from, so an unrelated settings change
    /// does not tear down and rebuild every hot key on the machine.
    private var installedShortcuts: Shortcuts?
    private var diagnostics = Diagnostics()
    /// Held so they can be released on quit, the same way `IslandController` releases its own.
    /// A block-based observer left registered outlives whatever it closed over.
    private var workspaceObservers: [any NSObjectProtocol] = []

    /// Whether the screen is currently somebody else's — locked, asleep, or dark.
    ///
    /// Read by the occlusion path, which must not bounce the island back while the lock shield is
    /// dissolving; see `installScreenLockObservers`. Stored rather than asked of `ScreenLock`
    /// because the two are not the same question: a display asleep on its own timer is away and is
    /// not locked, and the interval between the unlock and the island's return is locked by nobody
    /// and still away.
    private var isScreenAway = false

    /// The outstanding return, if the screen has come back and the island has not yet. At most one,
    /// canceled by anything that makes it wrong.
    private var pendingReturn: Task<Void, Never>?

    /// How long the island waits after the screen comes back before springing out of the notch.
    ///
    /// Long enough to let loginwindow finish dissolving its shield, so the island arrives *onto* the
    /// user's desktop rather than through the system's own animation. There is no notification for
    /// the end of that dissolve — `com.apple.screenIsUnlocked` marks its beginning — so this is a
    /// constant judged by eye and it is the whole of the fix in either direction.
    /// **`LockScreenController.unlockCollapseAt` plus one `Motion.lockHandover` must land inside
    /// this.** The padlock opens and is held open, then collapses into the notch, and the island
    /// springs out of the empty cutout at this delay; if the collapse is still running the two
    /// overlap and it reads as two shapes. 1.00s + 0.70s, and a frame or two of slack.
    /// `unlockLinger` is the padlock window's teardown and must stay past this.
    ///
    /// It was 650ms — loginwindow's dissolve alone — before the padlock had an unlock sequence of
    /// its own; the dissolve is long over by now, which is fine: the island arrives onto a desktop
    /// either way.
    private static let returnDelay = Duration.milliseconds(1750)

    // MARK: - Islands Isleta opened itself (§2.5)

    /// Screens whose island *Isleta* opened, for an activity that asked to be read rather than
    /// glanced at (`ActivityKind.opensIsland`).
    ///
    /// The same rule the shelf keeps, and for the same reason: **the island only closes itself if it
    /// opened itself.** An island the user clicked open is theirs until they close it, and a
    /// greeting expiring underneath it must not take away their decision. A screen leaves this set
    /// the moment the user takes the island over — a click on it, Escape, the close gesture — so
    /// what happens next happens to an island nobody is claiming to have opened.
    ///
    /// **A click somewhere else is not one of those**, and that asymmetry is the point. Every entry
    /// here got in because Isleta interrupted somebody; the click that follows is them carrying on
    /// with what they were doing, not answering. See `collapseUserOpenedIslands`.
    private var autoOpened: Set<CGDirectDisplayID> = []

    /// Whether the islands are stowed because *Isleta* stowed them, at a space change, on a player
    /// that was paused.
    ///
    /// `autoOpened`'s counterpart, and it exists for exactly the same reason: a stow is normally
    /// the user's own answer to "not now", and `IslandScreenModel.isStowed` cannot tell whose
    /// answer it was. Without this the auto-stow would be indistinguishable from a swipe — so the
    /// island would stay put away when the music started again, and a notification arriving an hour
    /// later would land in an island the user never swiped and has no reason to expect to be empty.
    ///
    /// Cleared by anything that takes the question over: a swipe either way, a click, an activity
    /// that is not music taking the stage, and the music starting again. See `spaceChanged`.
    private var autoStowed = false

    /// The one outstanding close-behind-the-pointer per screen — see `pointerExitChanged`.
    ///
    /// At most one each, replaced by the next crossing, so a pointer sweeping in and out across the
    /// island cannot leave a queue of closes behind it. Nothing is held while the pointer is on the
    /// island or away from it: the only timer this can create lives for `pointerExitGrace`, which is
    /// what keeps §9's "no polling when idle" true.
    private var pointerExitTimers: [CGDirectDisplayID: Timer] = [:]

    /// The islands the pointer is on. Almost always empty or one.
    ///
    /// A set rather than a `Bool` because hover is reported per screen and the two callbacks can
    /// cross: the pointer leaving one island and arriving on the next produces an exit and an
    /// enter, in an order nothing guarantees, and a `Bool` assigned from each in turn would read
    /// "off the island" for the gap in between — long enough for the coordinator to let go of what
    /// the pointer is moving *towards*. What the coordinator is told is whether this is empty; see
    /// `ActivityCoordinator.setPointerOverIsland`.
    private var hoveredScreens: Set<CGDirectDisplayID> = []

    /// Held for their lifetime: a `DispatchSourceSignal` stops delivering the moment it is
    /// deallocated. See `installTerminationSignals`.
    private var terminationSignals: [DispatchSourceSignal] = []

    /// The open that is waiting for the islands to come back.
    ///
    /// The greeting is presented at the unlock, which is `returnDelay` before the island is on
    /// screen at all — so opening when it arrives would open an island collapsed into the notch
    /// behind loginwindow's shield, and the user would be let in to an island already sitting
    /// flatly open with no animation left to watch. `bringIslandsBack` owns the open instead.
    private var pendingAutoOpen = false

    /// The outstanding open, if one is waiting out the island's return. At most one, and none at any
    /// other time (§9).
    private var autoOpenTask: Task<Void, Never>?

    /// How long the island waits after springing out of the notch before opening itself.
    ///
    /// `Motion.nudge` is 0.30s and this is a beat longer, so the two springs read as a sequence —
    /// the island arrives, and *then* it has something to say. Overlapped they are two curves on one
    /// object at once, which is the same defect §6.2's container-leads-content ordering exists to
    /// avoid; the island would appear to bloom out of the notch already open, and the return and the
    /// greeting would stop being two separate events. Four seconds of dwell (`ActivityKind`'s
    /// `defaultExpiry`) comfortably absorbs it.
    private static let autoOpenDelay = Duration.milliseconds(350)

    /// The same, for `DistributedNotificationCenter` — kept apart rather than pooled with the list
    /// above because a token is only meaningful to the center that issued it. Handing a distributed
    /// token to `NSWorkspace`'s center removes nothing, raises nothing and logs nothing; the
    /// observer simply stays live for the life of the process. `SystemEventsSource` carries the
    /// same note over the same trap.
    private var distributedObservers: [any NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // stdout is a pipe when run headlessly for measurement; without this the report never
        // reaches the caller.
        setvbuf(stdout, nil, _IOLBF, 0)
        installTerminationSignals()
        // Agent app (§3, LSUIElement). Set in code as well as in Info.plist so a debug build run
        // straight out of the build directory behaves the same as an installed one.
        NSApp.setActivationPolicy(.accessory)

        // The session header. Everything a bug report's first question would ask, on one line, and
        // the UTC offset once so the local timestamps below it can be placed. `argv[0]` is dropped:
        // it is a path into the user's disk, and the flags after it are the only part that varies.
        let flags = ProcessInfo.processInfo.arguments.dropFirst().joined(separator: " ")
        IslandLog.app.info(
            "\(AppVersion.nameAndVersion) (\(AppVersion.build ?? "—")) launching — macOS \(HostDescription.macOSVersion), "
            + "\(HostDescription.hardwareModel) \(HostDescription.architecture), pid \(ProcessInfo.processInfo.processIdentifier), "
            + "UTC\(LogLine.utcOffset(Date()))\(flags.isEmpty ? "" : ", flags: \(flags)")"
        )

        // Before anything can produce a haptic or read a shortcut. `SettingsStore` reads its blob
        // synchronously in its initializer — see the module README for why that is a `UserDefaults`
        // read and not a SwiftData stack.
        apply(settings.configuration)
        settings.addChangeHandler { [weak self] configuration in
            self?.apply(configuration)
        }

        let controller = IslandController(
            contentFactory: { [weak self] screen in
                self?.makeContentView(for: screen) ?? NSView()
            },
            blurContentFactory: { [weak self] screen in
                self?.makeBlurContentView(for: screen) ?? NSView()
            }
        )
        // Before `start()`, and deliberately not left to the `apply` above: that ran while
        // `controller` was still nil, so its `controller?.` lines did nothing. Seeding here rather
        // than moving `apply` down keeps the ordering the comment above it asks for — the hot-key
        // settings have to land before anything can fire one.
        //
        // `IslandSizing.standard` and not a reading of the user's record: schema 18 removed the
        // peek, width, height and compact controls, so there is one geometry and this is it. The
        // accessor stays because the drawn shape and the hit region must be built from one value —
        // see `islandSizing`.
        controller.sizing = islandSizing
        self.controller = controller
        controller.onScreensChanged = { [weak self] screens in
            self?.pruneModels(keeping: screens)
            self?.refreshDebugInfo()
        }
        controller.onHoverChanged = { [weak self] screen, hovering in
            // A pin's eight seconds runs from the last interaction, not from the swipe (§5), and
            // the pointer arriving on the island is an interaction. Free when nothing is pinned.
            self?.activities.noteInteraction()
            // And the pointer holds what is on stage past its deadline for as long as it is there:
            // a notification whose dwell runs out under the pointer reading it leaves when the
            // pointer does, not before.
            self?.pointerHoverChanged(hovering, on: screen)
            // The one path that taps. Hover is the island arriving somewhere the user did not ask
            // to go — the pointer crosses the notch and something is there — which is what the tap
            // is for. A click is already its own answer, so it does not get one.
            self?.transition(on: screen, haptic: true) { model, reduceMotion, completion in
                model.setHovering(hovering, reduceMotion: reduceMotion, completion: completion)
            }
            // The shelf closes an island it opened itself when the pointer leaves it; a
            // click-opened island is untouched. See `ShelfController.hoverChanged`.
            self?.shelf.hoverChanged(hovering, on: screen)
            // And since 2026-08-26 the pointer leaving closes the island the user opened, too.
            self?.pointerExitChanged(hovering, on: screen)
        }
        // Where the pointer is on the island, as opposed to whether it is on it. Only the track
        // lip reads this today — see `IslandScreenModel.isPointOnAlbumArtwork`, and
        // `IslandHitTestView.onPointerMoved` for why a part of the island smaller than the island
        // cannot have a tracking area of its own.
        controller.onPointerMoved = { [weak self] screen, point in
            self?.pointerMoved(to: point, on: screen)
        }
        controller.onClick = { [weak self] screen, point in
            guard let self else { return }
            self.activities.noteInteraction()

            // **A click on the island's top strip backs out of whatever is open in it.** Reported
            // from use: the way out of the list was the ✕ in its header, and the obvious place to
            // aim — the black strip across the top, where the notch is — did nothing but close the
            // island. One level at a time, the same as Escape: a message goes back to the list, the
            // list goes back to whatever the island was showing underneath, which on a quiet Mac is
            // the notifications-and-Settings menu.
            //
            // Only these two surfaces. Everything else the island can draw either has its own way
            // out in the same place (the shelf, Up Next) or is the thing the island is *for*, and a
            // top strip that meant something different on each of them would be a gesture nobody
            // could learn.
            // **A click in the switcher row that missed a chip is not a click on the island.**
            // `IslandHitTestView.hitTest` hands SwiftUI any point that lands on a `Button`, and
            // everything else falls through to here, which toggles. In the body that is right — a
            // click on an activity's text is a click on the island. In the *row* it is not: the
            // row is chrome, the chips are 30pt wide with gaps between them, and the gaps were
            // closing the island under somebody aiming at Settings. Reported as pages sometimes
            // closing the app when clicking between them.
            if self.isPageIndicatorStrip(point, on: screen) { return }

            // **Every click opens, including on an island with nothing on stage.**
            //
            // It used to refuse and pulse, on the reasoning that opening onto a 368x176 panel of
            // nothing reads as the app being broken. That was the right answer to the wrong
            // question: the island is never actually empty. There is what the user missed while it
            // had nothing to say. The calendar is a standing activity, so in practice there is
            // always the day to open onto, and the void the refusal was protecting against does not
            // exist any more.

            // A stowed island unstows *and* opens on one click. Swiping it away is "not now", not
            // "never" — so the click that comes back to it should not have to be spent undoing the
            // swipe before it can do the thing the user actually asked for.
            if self.models[screen.id]?.isStowed == true {
                self.setStowedEverywhere(false)
            }
            // The island is the user's from here, however it came to be open. Without this, a
            // greeting the island opened itself and the user then closed — or closed and
            // reopened — would still be on Isleta's books, and its expiry a moment later would
            // close an island the user had just asked for.
            self.autoOpened.remove(screen.id)

            // **A click opens the island. It never closes it.**
            //
            // This was `toggleExpanded` until 2026-08-26, and the toggle was wrong in the way a
            // toggle usually is: the two halves of it are not the same gesture. Opening is aimed at
            // the island — the user crosses the notch, the island is there, they click it. Closing
            // by clicking it again means aiming at the *body* of an open panel, which is where all
            // of its content is, so the second click of a toggle is indistinguishable from a click
            // on whatever the island happens to be showing. Every surface that grew its own
            // controls made that worse; the switcher row's gaps were already carved out above for
            // exactly this reason, one report at a time.
            //
            // So the click means one thing, and there are four ways out, all of them saying "not
            // this" by pointing somewhere that is not the island: the pointer leaving it
            // (`closeOnPointerExit`), a click in the blur, a click anywhere else on the screen
            // (`updateOutsideClickMonitor`), Escape, and the swipe up (`IslandCloseGesture`).
            //
            // A click on an island that is already open is therefore not a no-op — it is a click on
            // the content, and the paths above have already had their say about what that means.
            // It simply does not change whether the island is open.
            guard self.models[screen.id]?.isExpanded != true else { return }
            self.transition(on: screen) { model, reduceMotion, completion in
                model.setExpanded(true, reduceMotion: reduceMotion, completion: completion)
            }
        }
        // A right-click anywhere on the island: Isleta's own menu, and the way into Settings now
        // that the switcher row's gear has gone with the row. The shelf's tile menu gets the point
        // first — see `IslandHitTestView.rightMouseDown`, where the order is argued.
        controller.onSecondaryClick = { [weak self] screen, event, view in
            self?.showIslandMenu(on: screen, event: event, in: view)
        }
        controller.onScroll = { [weak self] _, sample in
            self?.swipes.handle(sample)
        }
        // A fullscreen space switch covers the island for about a second and then hands it back.
        // Nothing was destroyed, so there is no presentation change to ride in on — this is the one
        // place the island animates without its state having changed.
        // Two halves, either side of the panel being raised: take the island off screen first so
        // the window server has nothing full-size to composite, then bounce it back afterwards.
        controller.onSpaceWillRestore = { [weak self] in
            guard let self else { return }
            let reduceMotion = self.accessibility.reduceMotion
            for model in self.models.values {
                model.hideForReentry(reduceMotion: reduceMotion)
            }
        }
        // Every space switch, hosted or not — see `IslandController.onActiveSpaceChanged`, which is
        // a different signal from `onSpaceChanged` below.
        controller.onActiveSpaceChanged = { [weak self] in
            self?.spaceChanged()
        }
        controller.onSpaceChanged = { [weak self] in
            guard let self else { return }
            // Not while the screen is away. The lock shield is a window like any other, so it
            // occludes the panel on the way in and un-occludes it on the way *out* — mid-unlock,
            // while loginwindow is still dissolving. Bouncing there is the one thing this path is
            // written to avoid: the island would spring out through the fade and then be finished
            // by the time the user is actually looking at their desktop. `pickHoverBackUp` owns the
            // return instead, on its own delay.
            guard !self.isScreenAway else { return }
            let reduceMotion = self.accessibility.reduceMotion
            for model in self.models.values {
                model.playReentry(reduceMotion: reduceMotion)
            }
        }
        // Drops are accepted on every island, now and after any rebuild. The types are
        // `ShelfStore.acceptedTypes`; the callbacks are per screen because the shelf is app-wide
        // but the island that opens to receive a drag is not.
        controller.acceptDrops(of: ShelfStore.acceptedTypes) { [weak self] screen in
            self?.shelf.handlers(for: screen)
        }

        activities.onChange = { [weak self] change in
            self?.activityChanged(change)
        }
        installActivityObservers()
        installAccessibilityObserver()
        installApplicationHidingObserver()
        installScreenLockObservers()

        // The height the first click will open onto, before any activity has ever existed to set
        // it. Nothing is on stage at launch and nothing may be for hours, so `activityChanged` —
        // which is where the height is normally decided — has not run and will not: a Mac that
        // plays no music and gets no notifications never produces a change. Left unset, the first
        // click on a silent island would open the default 176pt body with a 64pt menu at the top of
        // it, which is the void the quiet menu exists to avoid, arrived at by a different route.
        //
        // Before `controller.start()`, so the first panels this controller builds are already
        // carrying the right shape table rather than acquiring it one activity later.
        restateExpandedContentHeight()

        // Record the launch figure once the island's first frame has been committed to the render
        // server, rather than at the end of this method — the panels are ordered in during
        // `start()` but nothing is on screen until the transaction commits.
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated { self?.recordLaunch() }
        }
        controller.start()
        CATransaction.commit()

        #if DEBUG
        // `--hitch-probe` only; a display link that never stops is exactly what §9 forbids on the
        // idle path, which is why this is not wired to anything by default.
        hitchProbe.start(controller: controller)
        #endif

        setStatusItemVisible(settings.configuration.showMenuBarIcon)
        installHotKeys()


        // `--perf-report`'s window is scheduled from `openIdleWindow()`, once the sources have
        // settled, so the window the report prints is the window it actually measured.
        if ClickSelfTest.isRequested() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let controller = self.controller else { return }
                    ClickSelfTest.run(
                        controller: controller,
                        activities: self.activities,
                        presentation: { [weak self] id in
                            guard let model = self?.models[id] else { return "?" }
                            return "\(model.presentation)"
                        }
                    ) { result in
                        print("click self-test: \(result)")
                        if PerformanceProbe.reportModeDuration() == nil { NSApp.terminate(nil) }
                    }
                }
            }
        }
        if SwipeSelfTest.isRequested() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let controller = self.controller else { return }
                    SwipeSelfTest.run(
                        controller: controller,
                        activities: self.activities,
                        isStowed: { [weak self] in self?.models.values.first?.isStowed ?? false },
                        isExpanded: { [weak self] in self?.models.values.contains(where: \.isExpanded) ?? false },
                        expand: { [weak self] in
                            guard let self, let screen = self.controller?.screens.first else { return }
                            self.transition(on: screen) { model, reduceMotion, completion in
                                model.setExpanded(true, reduceMotion: reduceMotion, completion: completion)
                            }
                        },
                        currentPage: { [weak self] in self?.pages.current ?? .home }
                    ) { result in
                        print("swipe self-test: \(result)")
                        if PerformanceProbe.reportModeDuration() == nil { NSApp.terminate(nil) }
                    }
                }
            }
        }
        if TransportSelfTest.isRequested() {
            // Later than the other two: the transport controls do not exist until a Now Playing
            // activity is on stage *and* `startSources()` has built the bridge, and that happens
            // after the first frame composites (see `recordLaunch`).
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let controller = self.controller,
                          let bridge = self.nowPlaying
                    else {
                        print("transport self-test: no Now Playing bridge — run without --no-sources")
                        NSApp.terminate(nil)
                        return
                    }
                    TransportSelfTest.run(
                        controller: controller,
                        coordinator: self.activities,
                        nowPlaying: bridge.controller,
                        expand: { [weak self] screen in
                            self?.transition(on: screen) { model, reduceMotion, completion in
                                model.setExpanded(true, reduceMotion: reduceMotion, completion: completion)
                            }
                        },
                        collapse: { [weak self] in self?.collapseAll() },
                        showMusicPage: { [weak self] in self?.goToPage(.music) },
                        presentation: { [weak self] id in
                            guard let model = self?.models[id] else { return "?" }
                            return "\(model.presentation)"
                        }
                    ) { result in
                        print("transport self-test: \(result)")
                        if PerformanceProbe.reportModeDuration() == nil { NSApp.terminate(nil) }
                    }
                }
            }
        }
        // `--request-accessibility` (Debug only): show the system's own Accessibility prompt.
        //
        // **The one thing that reliably puts Isleta in that list.** Privacy & Security has been
        // reorganised more than once and the pane is not where a written instruction says it is —
        // reported 2026-08-29 as there being no Accessibility section at all on macOS 27. The
        // system prompt sidesteps the layout entirely: it names the app, adds it to the list, and
        // its button opens the exact pane.
        //
        // Debug only, and it stays that way. §10's rule is that the one button that asks is the one
        // the user clicks; a shipping build must not raise this on its own, and nothing in Isleta
        // does. This is a development tool for granting a permission on purpose, which is a
        // different act from an app deciding to demand one.
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--request-accessibility") {
            // The option key spelled literally rather than through `kAXTrustedCheckOptionPrompt`,
            // which is a `var` in the SDK and so not concurrency-safe to touch. The string is
            // ApplicationServices' own and has never changed.
            let trusted = AXIsProcessTrustedWithOptions(
                ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            )
            IslandLog.app.info("accessibility prompt shown — currently trusted: \(trusted)")
            print("accessibility: currently trusted = \(trusted). "
                  + "If a dialog appeared, grant it there; Isleta is now in the list either way.")
        }
        #endif
        if HUDConsumeSelfTest.isRequested() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                MainActor.assumeIsolated {
                    HUDConsumeSelfTest.run { result in
                        print("hud-consume self-test: \(result)")
                        if PerformanceProbe.reportModeDuration() == nil { NSApp.terminate(nil) }
                    }
                }
            }
        }
        if MediaKeySelfTest.isRequested() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                MainActor.assumeIsolated {
                    MediaKeySelfTest.run { result in
                        print("media key self-test: \(result)")
                        if PerformanceProbe.reportModeDuration() == nil { NSApp.terminate(nil) }
                    }
                }
            }
        }
        if HoverSelfTest.isRequested() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let controller = self.controller else { return }
                    HoverSelfTest.run(controller: controller) { result in
                        print("hover self-test: \(result)")
                        if PerformanceProbe.reportModeDuration() == nil { NSApp.terminate(nil) }
                    }
                }
            }
        }
        if PointerHoldSelfTest.isRequested() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let controller = self.controller else { return }
                    PointerHoldSelfTest.run(controller: controller, activities: self.activities) { result in
                        print("pointer-hold self-test: \(result)")
                        if PerformanceProbe.reportModeDuration() == nil { NSApp.terminate(nil) }
                    }
                }
            }
        }
        if ShelfDropSelfTest.isRequested() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let controller = self.controller else { return }
                    ShelfDropSelfTest.run(
                        controller: controller,
                        shelf: self.shelfModel,
                        screenModel: { [weak self] id in self?.models[id] }
                    ) { result in
                        print("shelf self-test: \(result)")
                        if PerformanceProbe.reportModeDuration() == nil { NSApp.terminate(nil) }
                    }
                }
            }
        }
        #if DEBUG
        runHitchTestIfRequested()
        #endif
    }

    /// Turn a SIGTERM into an ordinary quit, so the cleanup on the way out actually runs.
    ///
    /// **Isleta now changes something outside its own process, and that changes what a signal
    /// costs.** `applicationWillTerminate` releases the banners it is holding open and puts
    /// every observer's window back, and a default SIGTERM
    /// does not run it — measured, by killing a debug build and finding the window still at
    /// (-3808, -3406) with no Isleta running, which is a Mac that shows **no banners at all** until
    /// something restarts NotificationCenter. A banner left expanded does not even self-heal: an
    /// expanded banner never expires.
    ///
    /// `DispatchSource` rather than a C handler, because the work is main-actor work against another
    /// process's accessibility tree and a signal handler may do almost none of that safely. The
    /// default disposition is ignored first, or the process dies before the source is ever scheduled.
    ///
    /// SIGINT for the same reason and one more: a shell-launched build is how this app is measured,
    /// and ⌃C is how those runs end.
    ///
    /// **SIGKILL is not covered and cannot be.** That is the standing cost of holding a banner open,
    /// and it is bounded rather than fixed: at most three banners, and the window is adopted and
    /// restored by the next notification that arrives.
    private func installTerminationSignals() {
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                IslandLog.app.info("terminating on signal \(signalNumber)")
                NSApp.terminate(nil)
            }
            source.resume()
            terminationSignals.append(source)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        IslandLog.app.info("quitting")
        // **First, and synchronously.** Isleta may be holding `OSDUIHelper` frozen with a SIGSTOP,
        // and a frozen helper means the user has no volume HUD from anything — not just from
        // Isleta. Everything below this line is Isleta putting its own house in order; this line is
        // giving somebody else's back, so it goes before any of it and it never awaits.
        //
        // The signal sources above are what make this run for a SIGTERM or a ⌃C. A `Task` here
        // would be scheduled onto a run loop that never turns again, which is the trap Atoll
        // records having hit on exactly this path.
        SystemOSDSuppressor.resume()
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        hotKeys.unregisterAll()
        pendingReturn?.cancel()
        pendingReturn = nil
        autoOpenTask?.cancel()
        autoOpenTask = nil
        launchSelfTestTask?.cancel()
        launchSelfTestTask = nil
        // Before the controller, and unconditionally. A leaked `AXObserver` keeps a run-loop source
        // alive and an orphaned `perl` from the adapter route outlives the process that spawned it —
        // neither is cleaned up by the panels going away, and both are invisible until somebody
        // notices Isleta's children in Activity Monitor after quitting it.
        // Owns a SkyLight space, so this one is not merely tidy: a space that is abandoned rather
        // than destroyed outlives the process until logout. Same obligation as
        // `SkyLightOverlaySpace`, discharged on the same synchronous path.
        lockScreen?.stop()
        // Synchronous, like everything on this path: `applicationWillTerminate` returns into
        // `exit()`, so a save that is merely scheduled never happens. `clear()` flushes on its own
        // for the same reason plus a stronger one — clearing is a privacy act.
        dropHistory.flushPendingSave()
        sources?.stopAll()
        // The files Isleta writes that do not outlive it: the bytes of file promises dropped on the
        // shelf, all under one directory named for this process. See `ShelfStore.cleanUpSession`.
        // (The log under `~/Library/Logs/Isleta` is the other thing it writes, and that one is
        // meant to survive — it is the previous run a bug report is about.)
        // Before the session directory is deleted, and **synchronously**, for the reason everything
        // on this path is: `applicationWillTerminate` returns into `exit()`, so a write that is only
        // scheduled is a write that never happens — the user's last drop, reorder or removal would
        // be missing at the next launch, on every clean quit. This is the same lesson
        // `NowPlayingAdapterReader.stop()` cost a milestone to learn. See
        // `ShelfStore.flushPendingSave`.
        // Before the record is flushed, and synchronously through to the `waitpid`, for the reason
        // everything on this path is synchronous: this method returns into `exit()`. A worker whose
        // SIGTERM is only *scheduled* is a worker that becomes launchd's — holding, mid-export, a
        // fixed ~450 MB — until the next launch's sweep catches it. See `FileActionRunner`.
        shelf.stopAndWait()
        // The CoreAudio listeners go with the app. There is no child process here and nothing to
        // wait for — `AudioObjectRemovePropertyListenerBlock` is synchronous — but a listener block
        // the HAL is still holding when this process calls `exit()` is a callback into freed memory
        // if the HAL happens to fire in that window. Cheap, unconditional, and on the same path as
        // everything else that must not merely be *scheduled*.
        nowPlaying?.stopOutputRouting()
        shelfStore.flushPendingSave()
        shelfStore.cleanUpSession()
        controller?.stop()
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        for observer in distributedObservers {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        distributedObservers.removeAll()
        // Last, and synchronous, for the reason everything above it is: this returns into `exit()`,
        // and a line still queued on the sink's thread when that happens is a line that was never
        // written — the "quitting" above would be the file's last word on every clean quit, which
        // is exactly what a crash looks like.
        IslandLog.app.info("quit complete")
        IslandLog.drain()
    }

    // MARK: - Content

    private func makeContentView(for screen: IslandScreen) -> NSView {
        let model = IslandScreenModel(
            metricsByForm: Self.metrics(
                for: screen,
                sizing: islandSizing,
                expandedContentHeight: expandedContentHeight,
                expandedContentWidth: expandedContentWidth,
                pageIndicatorHeight: pageIndicatorHeight
            ),
            notchKind: screen.notch.kind,
            cutoutSize: ActivitySlotLayout.cutoutSize(for: screen.notch)
        )
        // A panel built while something is already on the stage — a display connected mid-session,
        // or a rebuild after a resolution change — has to arrive showing it. Without this the new
        // island is blank until the next `ActivityChange`, which for a Now Playing activity is the
        // next track. `.none` is the right change here in the literal sense: nothing happened to
        // the stage, this panel simply did not exist for it, so the content is adopted with no
        // animation rather than played in.
        // The whole stage, companion included: a display connected while music and a timer are
        // both up has to arrive showing both, not showing the primary and gaining the flank on the
        // next unrelated change.
        model.setActivity(activities.stage, change: .none, reduceMotion: true)
        model.chips = activities.chips
        // Picking a chip pins its activity, which is the same mechanism a swipe used and the same
        // one `ActivityStack.rank` already lets outrank priority. A click is a stronger statement
        // than a swipe, so it holds longer — see `AppDelegate.pinHoldForClick`.
        model.onSelectChip = { [weak self] id in
            guard let self else { return }
            self.activities.noteInteraction()
            _ = self.activities.pin(id, holding: Self.pinHoldForClick)
        }
        // Settings, and then the island goes. Opening a window is leaving the island, and the order
        // matters: the window is up before the island is taken away, so nothing flickers between
        // them. An island left open behind the settings window is a black bar over the thing the
        // user just asked to look at.
        model.onOpenSettings = { [weak self] in
            self?.settingsWindow.show()
            self?.collapseAll()
        }
        model.nowPlaying = nowPlaying?.controller
        model.glance = glance
        model.page = pages
        model.nowPlayingContent = nowPlayingContent
        model.onSelectPage = { [weak self] page in self?.goToPage(page) }
        // The history rides on the screen model the way `nowPlaying` does — one app-wide model,
        // every island reading it.
        model.dropHistory = dropHistoryModel
        applyAccessibility(to: model)
        applyAppearance(settings.configuration, to: model)
        models[screen.id] = model

        // The shelf is app-wide, so it goes in the environment rather than through the per-screen
        // model — `IslandRootView` reads it optionally, which is what keeps IslandUI previewable
        // with nothing injected (§3). The hosting view is `IslandHostingView` rather than a plain
        // `NSHostingView` because the panel is never key, so every click on the transport controls
        // is a first-mouse click forever.
        let hosting = IslandHostingView(rootView: IslandRootView(model: model).environment(shelfModel))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        // Let the panel's fixed frame drive the size; the island sizes itself inside it (§4.2).
        hosting.sizingOptions = []
        return hosting
    }

    /// What `IslandBlurPanel` draws on one screen — the blur, in its own window.
    ///
    /// A second hosting view over the **same** model the island's own content is built from, so the
    /// two windows cannot disagree about how open the island is or what shape it currently has.
    /// `makeContentView(for:)` has already put the model in `models`, and the controller builds the
    /// island's content first, so by the time this runs there is one to read.
    ///
    /// A plain `NSHostingView`, not `IslandHostingView`: that subclass exists to answer
    /// `acceptsFirstMouse` on a panel that is never key, and this panel takes no clicks at all.
    private func makeBlurContentView(for screen: IslandScreen) -> NSView {
        guard let model = models[screen.id] else { return NSView() }
        let hosting = NSHostingView(rootView: IslandBlurRootView(model: model))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        // Let the panel's fixed frame drive the size, exactly as the island's content does (§4.2).
        hosting.sizingOptions = []
        return hosting
    }

    /// Tells the coordinator whether the pointer is on any island at all.
    ///
    /// Every route the pointer can leave by comes through here, including the ones that are not a
    /// pointer movement: `takeIslandsAway` cancels hover explicitly, and that reports back through
    /// `onHoverChanged` like an ordinary exit. A display being unplugged does not, which is why
    /// `pruneModels` narrows this set to the screens that still exist.
    private func pointerHoverChanged(_ hovering: Bool, on screen: IslandScreen) {
        if hovering {
            hoveredScreens.insert(screen.id)
        } else {
            hoveredScreens.remove(screen.id)
        }
        activities.setPointerOverIsland(!hoveredScreens.isEmpty)
    }

    private func pruneModels(keeping screens: [IslandScreen]) {
        // A display reconfiguration under a live scrub abandons it rather than committing it. The
        // panel the drag started in may not exist any more, so no `onEnded` is coming — and
        // committing on the caller's behalf would move the user's music because they plugged in a
        // monitor. `cancelScrub` and `endScrub` differ by exactly this.
        nowPlaying?.controller.cancelScrub()

        let live = Set(screens.map(\.id))
        models = models.filter { live.contains($0.key) }
        // A display that has gone away sends no hover exit, and an id left in here would hold the
        // stage against a pointer that is demonstrably somewhere else.
        hoveredScreens.formIntersection(live)
        activities.setPointerOverIsland(!hoveredScreens.isEmpty)
        // A close armed against a display that has gone would fire at an island that no longer
        // exists. Harmless — `closeIsland` guards on the model — but a timer outliving its subject
        // is how a §9 claim about the idle path stops being true.
        for (id, timer) in pointerExitTimers where !live.contains(id) {
            timer.invalidate()
            pointerExitTimers.removeValue(forKey: id)
        }
        for screen in screens {
            guard let model = models[screen.id] else { continue }
            model.metricsByForm = Self.metrics(
                for: screen,
                sizing: islandSizing,
                expandedContentHeight: expandedContentHeight,
                expandedContentWidth: expandedContentWidth,
                pageIndicatorHeight: pageIndicatorHeight
            )
            model.notchKind = screen.notch.kind
            // Set together with `notchKind`, always. A model that thinks it is on a hardware notch
            // while carrying a zero cutout would draw the compact badge straight over the hole.
            model.cutoutSize = ActivitySlotLayout.cutoutSize(for: screen.notch)

        }
        syncRegions()
    }

    /// Re-states every island's clickable and hovered regions from its model.
    ///
    /// `IslandController` builds and repositions panels knowing only geometry, so it leaves every
    /// island at the unflanked resting shape — it cannot know what the coordinator has on stage
    /// without IslandKit depending on IslandActivities. This is the one place both facts are in
    /// hand.
    ///
    /// Skipping it is the `islandPath`-is-a-subset bug in its quietest form: a display connected
    /// while Now Playing is up would *draw* a 265pt flanked island and accept clicks on only the
    /// middle 185pt of it. The window server routes the clicks on the flanks to us because those
    /// pixels are opaque, and `hitTest` then drops them — they neither open the island nor reach the
    /// app underneath.
    ///
    /// Called from two places, and the second is why it is a function. A rebuild changes the
    /// *screens*; changing the peek amount changes the *shapes* on unchanged screens. Both leave the
    /// regions describing an island that is no longer the one being drawn, and both are fixed by
    /// restating them from the models — which is the only place the drawn shape actually lives.
    private func syncRegions() {
        for (id, model) in models {
            controller?.setHitRegion(to: model.hitRegionMetrics, forScreen: id)
            controller?.setHoverRegion(
                isExpanded: model.isExpanded,
                flanks: model.flanks,
                forScreen: id
            )
        }
    }

    /// `--perf-report <seconds>`: idle for the given window, print the numbers, exit. The launch
    /// figure comes from `recordLaunch` rather than being re-measured here, which would otherwise
    /// report the length of the idle window instead.
    private func scheduleReport(after seconds: TimeInterval, controller: IslandController) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let sample = self.performance.sample()
                self.diagnostics.idleCPUPercent = sample?.percent
                self.diagnostics.idleWindowSeconds = sample?.wallSeconds
                self.diagnostics.memoryBytes = ProcessMetrics.residentMemory()
                // The probe's expectations assume the island is at rest and the panel is otherwise
                // transparent. Both the debug overlay and a live hover break that, and reporting a
                // failure in either case would be a false alarm.
                if self.models.values.contains(where: \.debugVisible) {
                    self.diagnostics.passThrough = "not run — debug overlay is visible and paints over the panel"
                } else if self.models.values.contains(where: { $0.presentation != .rest }) {
                    self.diagnostics.passThrough = "not run — the island is hovered, so it is larger than at rest"
                } else {
                    self.diagnostics.passThrough = PassThroughSelfTest.run(controller: controller)
                }
                print(DiagnosticsReport.text(
                    controller: controller,
                    diagnostics: self.diagnostics,
                    sources: self.sourceReport,
                    window: seconds
                ))
                NSApp.terminate(nil)
            }
        }
    }

    /// The drawn shape for every form on one screen.
    ///
    /// `sizing` is passed through rather than read from the store inside, so that this stays a pure
    /// function of its arguments — and so the one thing that must not drift, the pairing of this
    /// table with `IslandController.sizing`, is visible at the call sites rather than implied. They
    /// are the drawn shape and the clickable shape; a dimension reaching one and not the other is
    /// the subset bug `IslandHitTestView` documents.
    private static func metrics(
        for screen: IslandScreen,
        sizing: IslandSizing,
        expandedContentHeight: CGFloat?,
        expandedContentWidth: CGFloat?,
        pageIndicatorHeight: CGFloat = 0
    ) -> [IslandForm: IslandShapeMetrics] {
        Dictionary(uniqueKeysWithValues: IslandForm.allCases.map {
            ($0, IslandLayout.metrics(
                for: $0,
                on: screen,
                sizing: sizing,
                expandedContentHeight: expandedContentHeight,
                expandedContentWidth: expandedContentWidth,
                pageIndicatorHeight: pageIndicatorHeight
            ))
        })
    }

    /// Everything the user has said about how big the island is, as one value.
    ///
    /// One accessor rather than an `IslandSizing(...)` at each of the seven places that build a
    /// shape table, and that is the whole point of the type: the drawn shape and the region
    /// `IslandHitTestView` accepts clicks in are this arithmetic evaluated twice, and a dimension
    /// that reaches one call site and not another is clicks landing on lit island pixels and being
    /// dropped.
    ///
    /// **`.standard`, because none of its four fields is a setting any more.** The peek amount, the
    /// width and height adjustments and the compact open island were sliders and a switch through
    /// 2.0, on the Island and Appearance panes, and schema 18 took all four out — a Mac user cannot
    /// tell the island from an Apple feature, and a size slider is the fastest way to lose that. The
    /// accessor stays rather than the call sites reaching for `.standard` themselves, so a future
    /// dimension is added in one place and cannot be half-applied.
    private var islandSizing: IslandSizing { .standard }

    /// How much height the page indicator is taking, app-wide.
    ///
    /// **A constant now, and it used to be conditional.** The switcher row this replaced was zero
    /// when nothing was on stage, and its own note said twice that it "has to agree with
    /// `IslandScreenModel.hasPageIndicator` exactly" — because a strip the island grew for but
    /// reserved no height for is drawn over the last thing in the body, and a reserve with no strip
    /// in it is dead island. The pages are fixed, so both answers are unconditional and there is
    /// nothing left to keep in step.
    ///
    /// Still a property rather than the constant inlined at each of its call sites, so a build that
    /// draws no indicator is one edit rather than fourteen.
    private var pageIndicatorHeight: CGFloat { IslandPageIndicatorLayout.height }


    /// How wide the open island needs to be for whatever it is showing.
    ///
    /// Nil — the default width — for everything except the schedule, which is two lists side by
    /// side rather than a column of rows and is the one surface with a reason to ask
    /// (`GlanceScheduleLayout.bodyWidth`). It is a function rather than a computed property for
    /// `expandedContentHeightForStage`'s reason, in the one case that needs it: `toggleGlanceSchedule`
    /// sets the flag *inside* the animated transaction, so at the moment the width is computed the
    /// live flag is still describing the state being left.
    /// - Parameter showingGlanceSchedule: the surface's state to answer for, or nil for the live one.
    private func expandedContentWidthForStage(showingGlanceSchedule: Bool? = nil) -> CGFloat? {
        (showingGlanceSchedule ?? glance.isShowingSchedule) ? GlanceScheduleLayout.bodyWidth : nil
    }

    /// How much drawable height the open island needs for whatever it is showing.
    /// - Parameter page: which page to answer for, or nil for the one that is current.
    ///   Every caller but one asks with nil. The exception is a page being *dragged toward*: the
    ///   carousel has to know how tall the island will be before the page has changed, because the
    ///   outline follows the finger there rather than jumping when it arrives.
    private func expandedContentHeightForStage(
        presentations: ActivityPresentations?,
        kind: ActivityKind?,
        showingNowPlayingQueue: Bool? = nil,
        showingDropHistory: Bool? = nil,
        showingGlanceSchedule: Bool? = nil,
        page: IslandPage? = nil
    ) -> CGFloat? {
        // The Up Next surface, above the activity: it wins over the player's own body because that
        // is what it replaces.
        //
        // A **constant**, unlike the list's: the queue window grows as the reader scrolls, and a
        // height derived from the row count would resize the island as a consequence of reading it
        // — moving its own bottom edge under a pointer that is on it. See `NowPlayingQueueLayout`.
        //
        // **The parameter is the fix for a real bug and is not defensive.** Every other caller wants
        // the live flag, and asks with nil. `toggleNowPlayingQueue` cannot: the flag lives on
        // `NowPlayingController` and is deliberately set *inside* the animated transaction, so that
        // the surface and the island's outline travel on one spring. That leaves it still reading
        // `true` at the moment the closing height is computed — so the close asked this function
        // "how tall should the island be", and this function answered with the height of the
        // surface being dismissed. The island grew for Up Next and never shrank back.
        //
        // The tell is that it was invisible in both directions of the *open* path, which is why it
        // survived: opening is correct because the flag agrees with the answer, and closing looks
        // like a missing animation rather than a wrong number.

        // The drop history, above Up Next — the order `IslandRootView` draws them in and
        // `SwipeController` routes them in. A **constant**, so it cannot resize while it is being
        // read, and the parameter is the `showingNowPlayingQueue` fix in a second place for the same
        // reason: the flag is set inside the animated transaction, so on the way *out* it is still
        // describing the state being left.
        if showingDropHistory ?? dropHistoryModel.isShowing {
            return DropHistoryLayout.contentHeight
        }
        if !(showingDropHistory ?? dropHistoryModel.isShowing),
           showingNowPlayingQueue ?? isShowingNowPlayingQueue {
            return NowPlayingQueueLayout.contentHeight
        }
        // The shelf sizes itself, and says so here rather than through `ActivityExpandedHeight` —
        // that answers for content, and the shelf's body is a grid whose height is a property of the
        // layout (`ShelfLayout.contentHeight`) rather than of what happens to be in it. A constant,
        // for the reason `NowPlayingExpandedLayout` keeps one: `islandPath` has to track a settled
        // shape, so the island must not grow with the sixth file or shrink when a search narrows the
        // grid to one.
        if kind == .shelf { return ShelfLayout.contentHeight }

        // **The schedule, and it is asked about a stage rather than *of* one.** A drill-down over
        // whichever page is current, so it takes the body while it is up and its height does not
        // depend on what is on stage — which is exactly how `IslandRootView` draws it and how
        // `IslandScreenModel.pagesOwnBody` answers for it, and the three have to agree or the
        // island is sized for one surface and drawing another.
        //
        // **It was gated on `kind == .glance || kind == .meeting`, and `.glance` is never on
        // stage** — the kind was withdrawn when the calendar stopped standing on the stack as an
        // ambient activity (see `IslandScreenModel.drawsPages`). So for the ordinary case — nothing
        // on stage, or a track playing — this branch could not answer, and the function fell
        // through to the *home page's* height. Opening was correct, because `toggleGlanceSchedule`
        // sets the height itself and never asks; the next stage change asked, was told home's
        // height, and shrank the island's bottom edge up through the schedule that was still drawn
        // in it. Reported from use, with a screenshot, as the bottom having moved up "even though
        // most of the time it's the right height" — the "most of the time" being every moment
        // between the click and the next track, HUD or activity.
        //
        // Below the drop history and Up Next for `pagesOwnBody`'s reason: the two cannot be up
        // together today, and an order that relies on that is an order that breaks the day they can
        // be.
        //
        // A **constant**, and one that does not depend on the day — `GlanceSchedulePlan` fits two
        // days into a fixed five rows precisely so this cannot change as somebody's afternoon
        // fills up.
        //
        // The parameter is the `showingNowPlayingQueue` fix in a second place, for the same reason:
        // the flag is set inside the animated transaction, so on the way *out* it is still
        // describing the state being left.
        if showingGlanceSchedule ?? glance.isShowingSchedule {
            return GlanceScheduleLayout.contentHeight
        }

        // A meeting keeps its own body wherever the user is, so it is asked before the pages —
        // `IslandRootView` draws it on the same terms, and the two have to agree or the island is
        // sized for one surface and drawing another.
        if kind == .meeting, let height = glance.contentHeight(for: kind) { return height }

        // **The pages.** Whichever one is current decides the height, and the three are mutually
        // exclusive by construction — which is what pages bought over the flags they replaced. This
        // used to be a chain of `isShowing…` tests that could be true together, so the order here,
        // in `IslandRootView` and in `SwipeController` all had to be kept in step by hand.
        if drawsPages(for: kind) {
            // **The same function the page lays itself out with** — see `IslandPageHeight`, which
            // says why the page cannot simply measure the box it is in. Two answers here would be
            // the island sized for one arrangement and drawing another, which is the failure this
            // whole file is careful about; there is one of them.
            //
            // Nil is a real answer and not a fall-through: `.music` wants the island's *default*
            // height, because the player is a fixed layout the island sizes rather than the other
            // way round. It was briefly `ActivityExpandedHeight.contentHeight(for:kind:)` with a
            // fallback, which answers nil for `.nowPlaying` — so the music page was being sized to
            // the *home* page's empty height.
            // The home page's music column gains a row when the track has a badge, so the shell has
            // to ask the same question the view will — see `IslandHomeLayout.formatLineHeight`. Two
            // answers here is the island sized for one arrangement and drawing another, which is
            // the failure this whole function is careful about.
            return IslandPageHeight.contentHeight(
                for: page ?? pages.current,
                glance: glance,
                hasAudioFormat: nowPlaying?.controller.audioFormat != nil
            )
        }

        // Anything else that arrived on its own keeps the body it brought with it.
        guard presentations != nil else { return nil }
        if let height = glance.contentHeight(for: kind) { return height }
        return ActivityExpandedHeight.contentHeight(for: presentations, kind: kind)
    }

    /// Whether the pages own the body for this stage — the shell's copy of
    /// `IslandScreenModel.drawsPages`, which is what the *view* branches on.
    ///
    /// Two copies of one rule, which this codebase normally refuses. The exception is the same one
    /// `contentForm` documents: the model answers for a screen and this answers for the app, they are
    /// asked at different moments — this one *before* the transition, so the hit region widens
    /// against where the island is going — and they converge on the same input. If they ever
    /// disagree the island is sized for one surface and drawing another, which is why the rule is
    /// stated once in prose on `drawsPages` and referenced here rather than re-argued.
    private func drawsPages(for kind: ActivityKind?) -> Bool {
        switch kind {
        case nil, .glance, .nowPlaying: true
        default: false
        }
    }

    /// Opens or closes the Up Next surface on every island, through the same widen-then-tighten
    /// path a content change takes — it moves the open island's outline exactly as an activity does.
    ///
    /// Modelled on `toggleRecents` line for line, and the two differences are both deliberate:
    /// the height is a constant rather than a function of the row count (see
    /// `NowPlayingQueueLayout`), and opening asks the helper for a wider window while closing gives
    /// it back — a list nobody is looking at must not go on holding a hundred entries because it
    /// was scrolled ten minutes ago.
    /// Opens or closes today and tomorrow, through the widen-then-tighten path every other height
    /// change takes.
    ///
    /// Both days are fetched **before** the transition, not after: a list that arrived a frame late
    /// would animate open empty and then fill, which reads as the island loading rather than
    /// opening. Two warm EventKit predicates — CLAUDE.md measures a one-day fetch at 2 ms — so this
    /// is affordable on the main actor at the moment of a click.
    ///
    /// **Pulled here rather than published by `CalendarSource`**, which is §9's rule and the one
    /// the month grid followed for the same reason: the snapshot is pushed on every calendar edit,
    /// and two days re-fetched on each of those to keep a surface nobody has open up to date would
    /// be work on the idle path. They are read when the surface opens and forgotten when it closes.
    private func toggleGlanceSchedule(_ showing: Bool) {
        guard let controller else { return }
        guard showing != glance.isShowingSchedule else { return }
        activities.noteInteraction()

        if showing {
            loadGlanceSchedule(at: Date())
        }

        let stage = activities.stage
        let newContentHeight = showing
            ? GlanceScheduleLayout.contentHeight
            : expandedContentHeightForStage(
                presentations: stage?.primary.presentations,
                kind: stage?.primary.kind,
                showingGlanceSchedule: false
            )
        // The schedule is also the one surface that is *wider* than the island's default, and the
        // width is asked for with the same pending flag the height is: the live one is still
        // describing the state being left. See `expandedContentWidthForStage`.
        let newContentWidth = expandedContentWidthForStage(showingGlanceSchedule: showing)
        // Before the transition, never after: `widenHitRegionForTransition` asks the controller
        // where the island is going, and the schedule is taller and wider than the day it replaces.
        expandedContentHeight = newContentHeight
        controller.expandedContentHeight = newContentHeight
        expandedContentWidth = newContentWidth
        controller.expandedContentWidth = newContentWidth

        IslandLog.calendar.info("schedule \(showing ? "opened" : "closed")")

        for screen in controller.screens {
            let metrics = Self.metrics(
                for: screen,
                sizing: islandSizing,
                expandedContentHeight: newContentHeight,
                expandedContentWidth: newContentWidth,
                pageIndicatorHeight: pageIndicatorHeight
            )
            transition(on: screen, widensHitRegion: true) { model, reduceMotion, completion in
                model.setShowingGlanceSchedule(
                    showing, reduceMotion: reduceMotion, metricsByForm: metrics, completion: completion
                )
            }
        }
    }

    /// Reads today and tomorrow, and hands both to the surface.
    ///
    /// Counts only in the log, never titles or times: what somebody has on is as much their business
    /// as who it is with, and the log file is what "Export Logs…" hands to strangers.
    ///
    /// `events(on:)` twice rather than one predicate across two days and a split here: EventKit
    /// decides what belongs to a day — an all-day event is a range in a calendar's own time zone,
    /// not midnight to midnight in ours — and splitting a merged fetch by hand is where that gets
    /// quietly wrong for anyone travelling.
    private func loadGlanceSchedule(at instant: Date) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: instant)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? instant
        glance.todayEvents = sources?.calendar.events(on: today) ?? []
        glance.tomorrowEvents = sources?.calendar.events(on: tomorrow) ?? []
        IslandLog.calendar.info(
            "schedule loaded — \(self.glance.todayEvents.count) today, \(self.glance.tomorrowEvents.count) tomorrow"
        )
    }

    /// Opens or closes the drop history on every island, through the widen-then-tighten path every
    /// other height change takes.
    ///
    /// `toggleNowPlayingQueue`'s shape, with the one difference that matters: the height is a
    /// constant on **both** branches, because `DropHistoryLayout.contentHeight` does not depend on
    /// the row count. So the closing height cannot be wrong the way the queue's was — there is no
    /// row count for a stale flag to answer about. The parameter is still passed, so both paths ask
    /// the same question of the same function rather than one of them knowing better.
    private func toggleDropHistory() {
        guard let controller else { return }
        let showing = !dropHistoryModel.isShowing
        // Always back to the newest, opening *and* closing, and the row notes are cleared on both
        // edges — a row that once said "that disk isn't connected" must stop saying it once it is.
        dropHistory.didToggle(isShowing: showing)
        activities.noteInteraction()

        let stage = activities.stage
        let newContentHeight = showing
            ? DropHistoryLayout.contentHeight
            : expandedContentHeightForStage(
                presentations: stage?.primary.presentations,
                kind: stage?.primary.kind,
                showingDropHistory: false
            )
        let newContentWidth = expandedContentWidthForStage()
        // Before the transition, never after: `widenHitRegionForTransition` asks the controller
        // where the island is going, and a height set afterwards is a union taken against the shape
        // the island is leaving.
        expandedContentHeight = newContentHeight
        controller.expandedContentHeight = newContentHeight
        expandedContentWidth = newContentWidth
        controller.expandedContentWidth = newContentWidth

        for screen in controller.screens {
            let metrics = Self.metrics(
                for: screen,
                sizing: islandSizing,
                expandedContentHeight: newContentHeight,
                expandedContentWidth: newContentWidth,
                pageIndicatorHeight: pageIndicatorHeight
            )
            transition(on: screen, widensHitRegion: true) { model, reduceMotion, completion in
                model.setShowingDropHistory(
                    showing, reduceMotion: reduceMotion, metricsByForm: metrics, completion: completion
                )
            }
        }
    }

    private func toggleNowPlayingQueue() {
        guard let controller, let bridge = nowPlaying else { return }
        let showing = !bridge.controller.isShowingQueue
        // Always back to the current track, opening *and* closing. A surface reopened where it was
        // left opens on rows that are no longer next.
        nowPlayingQueueScroll.reset()
        bridge.controller.queueScrollTarget = bridge.controller.queueScrollTarget.dragged(to: 0)
        // Opening asks for the first page; closing gives the window back to the resting five, which
        // is what the sneak peek reads and all the sneak peek needs.
        bridge.requestQueueWindow(
            lastVisibleRow: NowPlayingQueueLayout.visibleRows - 1,
            isOpen: showing
        )
        activities.noteInteraction()
        // Counts, never contents. A queue line carries titles and artists and none of them may
        // reach a log that is emailed to strangers.
        IslandLog.nowPlaying.info(
            "up next \(showing ? "opened" : "closed") — \(bridge.controller.queue.count) held"
        )

        let stage = activities.stage
        // Computed *after* the flag would flip but *before* the transition, which is why the flag is
        // set inside the animated transaction below and the height is read from `showing` here.
        // `widenHitRegionForTransition` asks the controller where the island is going, so a height
        // set afterwards is a union taken against the shape the island is leaving — and the surface
        // spends the whole animation painting island we reject clicks on.
        // `showingNowPlayingQueue: showing` rather than the live flag, which is still describing the
        // state being left — see the note on that parameter. Passed on both branches rather than
        // only the closing one, so the two paths ask the same question of the same function.
        let newContentHeight = showing
            ? NowPlayingQueueLayout.contentHeight
            : expandedContentHeightForStage(
                presentations: stage?.primary.presentations,
                kind: stage?.primary.kind,
                showingNowPlayingQueue: false
            )
        let newContentWidth = expandedContentWidthForStage()
        expandedContentHeight = newContentHeight
        controller.expandedContentHeight = newContentHeight
        expandedContentWidth = newContentWidth
        controller.expandedContentWidth = newContentWidth

        for screen in controller.screens {
            let metrics = Self.metrics(
                for: screen,
                sizing: islandSizing,
                expandedContentHeight: newContentHeight,
                expandedContentWidth: newContentWidth,
                pageIndicatorHeight: pageIndicatorHeight
            )
            transition(on: screen, widensHitRegion: true) { model, reduceMotion, completion in
                model.setShowingNowPlayingQueue(
                    showing,
                    reduceMotion: reduceMotion,
                    metricsByForm: metrics,
                    completion: completion
                )
            }
        }
    }

    /// One scroll sample, while the Up Next surface has the vertical axis (`SwipeController`).
    ///
    /// Two things happen per sample and only one of them is the scroll. The other is the paging:
    /// reaching the bottom of what we hold is what asks the helper for another page, and that ask
    /// is suppressed unless it is genuinely wider than the last one — otherwise a single flick
    /// would write sixty control lines and cost sixty MediaRemote round trips inside the helper
    /// that is also delivering track changes.
    ///
    /// The island's *outline* cannot move as a result, so this takes none of the
    /// widen-then-tighten path: the viewport is a fixed rectangle the island was already sized for,
    /// and only what is drawn inside it changes. That is the whole reason the surface's height is a
    /// constant.
    private func scrollNowPlayingQueue(_ sample: IslandScrollSample) {
        guard let bridge = nowPlaying else { return }
        let rows = bridge.controller.queue.count
        let offset = nowPlayingQueueScroll.consume(
            sample,
            extent: NowPlayingQueueLayout.scrollExtent(rowCount: rows)
        )
        bridge.controller.queueScrollTarget = bridge.controller.queueScrollTarget.dragged(to: offset)
        bridge.requestQueueWindow(
            lastVisibleRow: NowPlayingQueueLayout.lastVisibleRow(offset: offset, rowCount: rows),
            isOpen: true
        )
    }

    /// Re-clamps the Up Next scroll against a window that has changed size.
    ///
    /// Called whenever the queue arrives. The direction that matters is the one the drop history
    /// never sees: a track change re-vends the window from the *new* current track, so the rows the
    /// reader was looking at now mean something else — which is why that case travels to the top on
    /// `Motion.nudge` rather than merely being clamped.
    private func applyNowPlayingQueue(_ rows: [NowPlayingQueueRow]) {
        guard let bridge = nowPlaying else { return }
        let offset = nowPlayingQueueScroll.clamped(
            to: NowPlayingQueueLayout.scrollExtent(rowCount: rows.count)
        )
        // A window that got shorter than where the reader was standing is the queue having been
        // re-vended around a different track. Travel back to it, so what they see is the list
        // moving rather than the rows silently meaning something else.
        if offset == 0, nowPlayingQueueScroll.offset == 0, bridge.controller.queueScrollOffset > 0 {
            bridge.controller.queueScrollTarget =
                bridge.controller.queueScrollTarget.revealingCurrent()
        } else {
            bridge.controller.queueScrollTarget =
                bridge.controller.queueScrollTarget.dragged(to: offset)
        }
    }

    /// Restates how tall the open island should be, from what is on stage right now.
    ///
    /// The height normally travels with the thing that changed — an activity arriving, the list
    /// opening — because both of those are animated and the height has to ride the same spring
    /// (§6.1). This is the third case: the list going away as a *side effect* of the island
    /// closing, where the height would otherwise be left describing a surface that is no longer on
    /// screen.
    ///
    /// `controller.expandedContentHeight` moves with it, and that pairing is not optional:
    /// `widenHitRegionForTransition` asks the controller where the island is going, so a table and a
    /// controller that disagree produce a widened region that is a *subset* of the island being
    /// drawn — clicks landing on lit pixels, reaching us, and being dropped.
    private func restateExpandedContentHeight() {
        guard let controller else { return }
        let stage = activities.stage
        let newContentHeight = expandedContentHeightForStage(
            presentations: stage?.primary.presentations,
            kind: stage?.primary.kind
        )
        let newContentWidth = expandedContentWidthForStage()
        guard newContentHeight != expandedContentHeight || newContentWidth != expandedContentWidth
        else { return }
        expandedContentHeight = newContentHeight
        controller.expandedContentHeight = newContentHeight
        expandedContentWidth = newContentWidth
        controller.expandedContentWidth = newContentWidth
        for screen in controller.screens {
            models[screen.id]?.metricsByForm = Self.metrics(
                for: screen,
                sizing: islandSizing,
                expandedContentHeight: newContentHeight,
                expandedContentWidth: newContentWidth,
                pageIndicatorHeight: pageIndicatorHeight
            )
        }
    }

    /// Whether a click landed on the island's top strip — the band across the top where the notch
    /// is, above anything drawn in the body.
    ///
    /// **The cutout's height, with a floor.** On a notched Mac the strip is exactly the hole, which
    /// is the part of the island a user reads as "the bar itself" rather than as its contents. On a
    /// notchless display the cutout is zero and the strip would not exist at all, so it floors at a
    /// height a pointer can hit — the same reasoning `DropHistoryLayout.indicatorMinimumLength` uses for
    /// a thumb that would otherwise be a speck.
    ///
    /// Deliberately not "the top half": the body starts immediately under the cutout, and a strip
    /// that reached into it would swallow clicks meant for the first row of a list.
    private func isTopStrip(_ point: CGPoint, on screen: IslandScreen) -> Bool {
        guard point.y >= 0 else { return false }
        let cutout = models[screen.id]?.cutoutSize.height ?? 0
        return point.y <= max(cutout, Self.minimumTopStripHeight)
    }

    /// The shortest top strip that is still a target. See `isTopStrip`.
    private static let minimumTopStripHeight: CGFloat = 24

    /// Whether a click landed in the band the switcher row occupies, along the island's bottom.
    ///
    /// Only while the row is actually drawn — `showsPageIndicator` is the same flag the row is drawn on,
    /// so a band reserved for a row that is not there cannot swallow a click meant for the body.
    ///
    /// The island's own height rather than the body's: the row is drawn against the bottom edge of
    /// the shape (`ActivitySwitcherLayerView` anchors it there), and the point is in the shape's
    /// coordinates.
    private func isPageIndicatorStrip(_ point: CGPoint, on screen: IslandScreen) -> Bool {
        guard let model = models[screen.id], model.showsPageIndicator else { return false }
        // `bodySize` is the island's whole rectangle — "its bounding box and its body are the same
        // thing" (`IslandShapeMetrics`) — so the cutout is already inside it and adding it again
        // would put the band a notch's height below the island.
        return point.y >= model.metrics.bodySize.height - IslandPageIndicatorLayout.height
    }

    // MARK: - Dismissing, muting and searching the list

    /// A click on a row's link chip: open it and close the island.
    ///
    /// The same three steps `openRecent` takes and in the same order — the island has to be gone by
    /// the time the browser is in front of the user. **The row is not removed**, unlike a click on
    /// the row itself: opening a link in a message is not dealing with the message.
    ///
    /// This is the *only* place a URL out of a notification is used, and it is used on an explicit
    /// click. Nothing resolves one in the background — see `NotificationLinkPreview` for why that is
    /// a read receipt rather than a feature.
    private func openLink(_ url: URL) {
        activities.noteInteraction()
        NSWorkspace.shared.open(url)
        // The scheme, which is one of two values, and never the address — a URL out of somebody's
        // message is their business and the log is emailed to strangers.
        IslandLog.notifications.info("opened a link from a notification (\(url.scheme ?? "?"))")
        collapseAll()
    }

    // MARK: - The keyboard

    /// Which screen's panel is currently allowed to take key, so it can be handed back.
    ///
    /// Held rather than derived from whatever asked, because the panel that has key may have been
    /// destroyed by a display change while the surface was live — the id says which one was asked,
    /// and `IslandController.setAcceptingKeyboardInput` puts every other panel back regardless.
    ///
    /// **The one caller is the shelf's search field.** This used to be shared with the notification
    /// reply, and `IslandPanel.acceptsKeyboardInput` is documented as the single scoped exception to
    /// "the panel never becomes key" that the reply bought and the shelf reused. The reply is gone;
    /// the exception stays, because the search field still needs it and the measurement behind it is
    /// unchanged. Do not widen it to a third caller without measuring it again.
    private var keyboardScreen: CGDirectDisplayID?

    /// Hands key back to whatever had it. See `IslandPanel.acceptsKeyboardInput`: this is
    /// `acceptsKeyboardInput = false` then `resignKey()`, and `NSApp.hide` — which reads as the
    /// tidy thing to do — was measured unnecessary *and* takes the island off screen with
    /// everything else.
    private func handBackKeyboard() {
        guard keyboardScreen != nil else { return }
        keyboardScreen = nil
        controller?.setAcceptingKeyboardInput(false, forScreen: nil)
    }

    /// How long a reply holds the stage.
    ///
    /// Far longer than `pinHoldForClick`'s thirty seconds, because this is not a statement about
    /// what to look at — it is a message being written, and having the island retract mid-sentence
    /// would lose it. Ten minutes rather than no expiry at all: an abandoned compose (the user walks
    /// away, the machine sleeps) has to end up somewhere, and the alternative is an island pinned
    /// until quit.
    private static let pinHoldForReply: Duration = .seconds(600)

    /// How long "Sent" stays on screen. Long enough to read, short enough that the island is not
    /// still showing it when the user looks back.
    private static let replySentDwell: Duration = .seconds(1.2)

    /// How long a failure sentence stays. Longer than a success — it is the one the user has to
    /// actually read, and it is the only place they are told the notification had no reply in it.
    private static let replyFailureDwell: Duration = .seconds(2.4)

    // MARK: - Presentation changes

    /// Every change to what the island is showing goes through here.
    ///
    /// The ordering is what makes it feel like one event rather than three, and it is the same for
    /// hover and for a click:
    ///
    /// 1. **Widen the hit region first**, before the animation starts, so a click arriving mid-morph
    ///    cannot fall into a gap between what is drawn and what we accept (see `IslandHitTestView`).
    /// 2. **Request the haptic as the animation is committed**, so AppKit lands the tap on the frame
    ///    that draws the change rather than a frame or two ahead of it.
    /// 3. **Tighten the hit region only on completion**, from the animation's own completion handler.
    ///
    /// The hover tracking region and the Escape key follow the *resulting* state, so they are set
    /// after the model has been asked to change and before waiting for it to settle.
    /// - Parameter widensHitRegion: whether the island's *outline* can move during this change.
    ///   True for hover and clicks, where it always does. For a change of content it depends: an
    ///   activity arriving or leaving with flank content moves the outline between the cutout and
    ///   the flanked resting size, and an activity merely saying something new does not. Widening
    ///   on the second kind would rebuild `islandPath` twice for every Now Playing update, which
    ///   arrives on every scrub, to end up at the shape it started from.
    private func transition(
        on screen: IslandScreen,
        widensHitRegion: Bool = true,
        haptic: Bool = false,
        _ change: (IslandScreenModel, Bool, @escaping @MainActor () -> Void) -> Void
    ) {
        guard let model = models[screen.id], let controller else { return }

        let before = model.presentation
        if widensHitRegion {
            // Always the expanded form, whatever this particular change is heading for. It is the
            // largest shape the island has, so the union with wherever the island is now covers
            // every intermediate; and a superset costs nothing, because the window server has
            // already routed the clicks over transparent pixels elsewhere.
            controller.widenHitRegionForTransition(to: .expanded, forScreen: screen.id)
            // **And the track lip, because the open island does not always contain it.** Each call
            // is a union with what is already there, so this accumulates rather than replaces.
            //
            // At default sizes the lip is 80pt against an open island of 176 and this adds nothing
            // at all. It stops being nothing at the ceiling of the size settings: 32pt of cutout
            // plus the 24pt height adjustment plus a peek at 2× plus the lip's 40 is 112, while an
            // open island showing a short content-sized activity is `minimumExpandedHeight`'s 108.
            // Those four points are drawn island that would reject clicks for the length of the
            // morph — the subset `IslandHitTestView` is written around, reached by the one
            // combination of settings nobody will have and everybody's Mac has to survive.
            // `TrackLipTests` pins the arithmetic that makes this necessary.
            controller.widenHitRegionForTransition(to: .flankedPeekWithLip, forScreen: screen.id)
            // **And the widest flanked peek, which the open island does not contain either** — this
            // time in width rather than height. `IslandLayout.widerFlankedWidthGrowth` is 274
            // against an open island of 368, so a power activity's resting island is 91pt wider
            // than the shape it opens into on a 185pt notch, and more than that on a wider one or
            // with the size settings up. Same accommodation as the lip above, same reason, other
            // dimension.
            //
            // **The widest span and not the wide one**, since power reaches past a HUD: this form
            // contains `.wideFlankedPeekWithLip` outright, so naming both would be a union with a
            // subset — the same union, computed twice, on every transition the island makes.
            //
            // **Plus the bounce allowance**, which is why this one is handed a shape rather than a
            // form: the lean at the end of a range (`IslandScreenModel.limitBounce`) is a position
            // and no form carries it, so widening to the form alone leaves the region 2pt short of
            // a wide island at the far end of its travel — for the length of the morph, which is
            // exactly the interval this whole protocol exists to cover. `hitRegionMetrics` applies
            // the same allowance at the *tighten*; this is its other half, and the two have to be
            // the same number or the region narrows under a moving island the moment the change
            // settles.
            //
            // The content height, the content width and the row height are deliberately not passed:
            // only `.expanded` reads any of them, and this is a collapsed form.
            var bounced = IslandLayout.metrics(
                for: .widerFlankedPeekWithLip, on: screen, sizing: islandSizing
            )
            bounced.bodySize.width += 2 * IslandLayout.limitBounceDistance
            controller.widenHitRegion(toContain: bounced, forScreen: screen.id)
        }

        change(model, accessibility.reduceMotion) { [weak self] in
            guard let self, let model = self.models[screen.id] else { return }
            self.controller?.setHitRegion(to: model.hitRegionMetrics, forScreen: screen.id)
            self.refreshDebugInfo()
        }

        let after = model.presentation
        if haptic, after != before {
            // **Hover only.** The tap is for arriving somewhere the user did not ask to go: the
            // pointer crosses the notch and something is there. A click is already an answer to
            // itself — the island visibly opens under the finger that asked for it — and tapping
            // then is the app repeating back what the user just did.
            Haptics.peek()
            diagnostics.haptics = "tap requested for \(before) → \(after) (suppressed unless a finger is on the trackpad)"
        }

        controller.setHoverRegion(
            isExpanded: model.isExpanded,
            flanks: model.flanks,
            forScreen: screen.id
        )
        updateEscapeHotKey(expanded: model.isExpanded)
        refreshWeatherPolling()
        refreshDebugInfo()
    }

    /// Arms the weather refresh while the surface that draws it is on screen, and disarms it the
    /// rest of the time.
    ///
    /// §9 permits a provider to poll **only while what it feeds is presented**, and weather is the
    /// one thing in Isleta with no push signal of any kind — no notification, no callback, no bus.
    /// So the refresh timer is armed from here and nowhere else.
    ///
    /// **The question used to be "is the glance activity on the stage", and that stopped being a
    /// question when the glance became a page.** The calendar published a standing ambient activity
    /// through 2.0 and this read its presence; with the activity withdrawn (see
    /// `ActivityKind.glance`) the same test answers false forever, which would leave the weather
    /// page permanently empty and nothing polling to fill it.
    ///
    /// Three conditions, and each rules out a way of polling for nobody:
    ///
    /// - **An island is open.** A closed island draws no weather at all, on any page.
    /// - **The pages own the body.** An activity that *arrived* keeps the body it brought with it
    ///   (`IslandScreenModel.drawsPages`), so a volume HUD over the weather page is the weather page
    ///   not being on screen.
    /// - **The current page draws a reading.** `.home` carries the temperature beside the day and
    ///   `.weather` is the forecast; `.music` carries neither.
    ///
    /// Called from `transition(on:_:)`, which is the one funnel every open, close and page turn goes
    /// through, and from `activityChanged` for the second condition. `WeatherSource.setPresented`
    /// early-returns when the answer has not moved, so asking often is free.
    /// The user's glance record reaching both the sources and the island.
    ///
    /// **One path, called from the launch apply and from every change**, for the reason the change
    /// handler already gives: a separate "at launch" branch is how the two drift until one is
    /// missing a field. It was `sources?.apply(glance:)` at both call sites, and the second line is
    /// why it is a method — the weather page has to know the difference between a forecast that
    /// failed and a place nobody has picked, and that is a fact about the *record*, not about the
    /// source.
    ///
    /// **Gated on the provider, so the offer is never a lie.** A build with no WeatherKit
    /// entitlement — every Debug build, since an ad-hoc signature cannot carry one — has no weather
    /// a setting could turn on, and pointing that user at Settings would be a control that visibly
    /// does nothing. §10's rule, and the same one the empty day applies to its "Allow…" button.
    private func applyGlanceSettings(_ settings: GlanceSettings) {
        sources?.apply(glance: settings)
        glance.weatherNeedsPlace = (sources?.weather.isAvailable ?? false) && !settings.hasPlace
    }

    private func refreshWeatherPolling() {
        let drawsAPage = models.values.contains(where: \.isExpanded)
            && drawsPages(for: activities.stage?.primary.kind)
        let pageDrawsWeather = pages.current == .home || pages.current == .weather
        sources?.weather.setPresented(drawsAPage && pageDrawsWeather)
    }

    /// Escape is registered only while an island is open, and released the moment it closes.
    ///
    /// A system-wide hot key on Escape is not something to hold permanently — it would take the key
    /// away from every app on the machine. Scoped to the seconds an island is expanded, dismissing
    /// with Escape is what a user expects and the cost is bounded.
    /// What Escape does: it closes the island.
    ///
    /// **It is deliberately not "dismiss all", which the parity list asks for.** Escape is one of
    /// the documented ways out of an open island, and a key that also destroyed what was on it would
    /// be doing two things under one press. If dismiss-all wants a key, it wants a binding in
    /// `Shortcuts` that the user chose, not a reflex on the escape key.
    private func handleEscape() {
        collapseAll()
    }

    private func updateEscapeHotKey(expanded: Bool) {
        let anyExpanded = expanded || models.values.contains(where: \.isExpanded)
        if anyExpanded, escapeHotKey == nil {
            escapeHotKey = try? hotKeys.register(keyCode: kVK_Escape, modifiers: 0) { [weak self] in
                self?.handleEscape()
            }
        } else if !anyExpanded, let escapeHotKey {
            hotKeys.unregister(escapeHotKey)
            self.escapeHotKey = nil
        }
        updateOutsideClickMonitor(anyExpanded: anyExpanded)
    }

    /// Closes the island the user opened when they click anywhere else.
    ///
    /// Registered and torn down on the same edge as the Escape hot key, and for the same reason: an
    /// open island is a transient surface, and both are ways of saying "not this". Watching every
    /// click on the machine is not something to hold permanently.
    ///
    /// The monitor stays registered while an *auto-opened* island is up even though clicks no longer
    /// close it, because the edge it is tied to is "any island expanded" and the user may still open
    /// one of their own alongside. The cost is a closure that iterates and does nothing, for the few
    /// seconds an unread notification is on screen.
    private func updateOutsideClickMonitor(anyExpanded: Bool) {
        // Never while a self-test is driving the island. The tests synthesise their events into our
        // own window and then assert against an island they expect to stay open — but the human
        // whose Mac this is carries on clicking, and one real click elsewhere would collapse the
        // island mid-assertion and fail a test about drag-and-drop for reasons that have nothing to
        // do with it. Found exactly that way.
        guard !Self.isRunningSelfTest else { return }

        if anyExpanded, outsideClickMonitor == nil {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    // No hit test against the island's frame. A global monitor never sees clicks
                    // that were delivered to us, so anything arriving here is by definition
                    // somewhere else — and a coordinate check would additionally be wrong for a
                    // click on the island's *transparent* pixels, which the window server correctly
                    // routes to the app underneath even though they are inside our frame.
                    //
                    // **Except a click that passed through the blur.** The band around an open
                    // island is its grace region: the pointer may rest there without the island
                    // closing, and since 2026-08-26 a click there reaches the app underneath rather
                    // than being consumed — so it arrives here, at the one monitor that would
                    // otherwise undo the grace the band exists to give. A coordinate check is
                    // correct *here specifically*, and only because the blur is drawn in a window
                    // that ignores mouse events: everything else this monitor sees is genuinely
                    // somewhere else. See `IslandController.isPointInBlur`.
                    guard let self else { return }
                    let pointer = NSEvent.mouseLocation
                    if self.controller?.screens.contains(where: {
                        self.controller?.isPointInBlur(pointer, forScreen: $0.id) == true
                    }) == true { return }
                    // Only the user's own islands. A notification that opened itself is not dismissed
                    // by the click that carries on the work it interrupted — see
                    // `collapseUserOpenedIslands`.
                    self.collapseUserOpenedIslands()
                }
            }
        } else if !anyExpanded, let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    /// Whether any of the `--*-test` harnesses is driving this launch.
    private static var isRunningSelfTest: Bool {
        let arguments = Set(ProcessInfo.processInfo.arguments)
        return !arguments.isDisjoint(with: [
            "--click-test", "--hover-test", "--swipe-test", "--shelf-test", "--transport-test",
            "--media-key-test",
            "--hitch-test",
        ])
    }

    /// Stows or unstows every island at once.
    ///
    /// Routed through `transition(on:_:)` like a click, and for the same reason: stowing narrows the
    /// island back to the bare cutout, which moves the outline. The widen-then-tighten protocol has
    /// to cover that or a click arriving mid-animation falls into the gap between what is drawn and
    /// what is accepted.
    ///
    /// All screens together, because the gesture is about the *content*, not about the island the
    /// pointer happens to be over — leaving one display stowed and another not would be two answers
    /// to one question.
    /// - Parameter automatic: whether this is Isleta's own stow rather than the user's swipe. See
    ///   `autoStowed`, which is what a later unstow reads to know whose decision it is undoing.
    ///   Defaulted to false so every existing call site — all of which are the user — keeps saying
    ///   what it always said.
    private func setStowedEverywhere(_ stowed: Bool, automatic: Bool = false) {
        guard let controller else { return }
        // A swipe is the user's own answer about the island's content, so nothing Isleta opened is
        // still Isleta's to close afterwards — in either direction.
        autoOpened.removeAll()
        // Set for the stow and cleared for the unstow, in both directions and whoever asked: a user
        // who swipes the island away has taken the question over, and one who swipes it back has
        // answered it, so neither leaves anything for the resuming track to undo.
        autoStowed = stowed && automatic
        for screen in controller.screens {
            transition(on: screen) { model, reduceMotion, completion in
                model.setStowed(stowed, reduceMotion: reduceMotion, completion: completion)
            }
        }
    }

    /// The user is looking at a different desktop.
    ///
    /// **Paused music goes back into the notch.** A track that is playing is a live thing and
    /// belongs in the flanks wherever the user goes; a track that is *paused* is a record of what
    /// they were doing on the space they just left, and carrying it onto the next one is the island
    /// insisting on something they have finished with. So the island puts it away — the same stow
    /// the two-finger swipe performs, the same spring, the same shape: the flanks empty, the
    /// content retracts into the cutout, and the island narrows back to the bare notch.
    ///
    /// It is a stow and deliberately not a dismissal. The activity stays on the coordinator's
    /// stack, so pressing play brings it back with the position it had rather than as a new track,
    /// and `autoStowed` is what remembers that this was Isleta's decision and not the user's — see
    /// `playingChanged`, which undoes it.
    ///
    /// **An open island closes**, whatever is on stage and whoever opened it. An open island is a
    /// surface about the desktop it was opened on — a message, a forecast, a track's controls — and
    /// carrying it across to the next space is the island following the user around with something
    /// they have finished with. Leaving it open is worse than stale: it hangs a 176pt panel over
    /// the first thing they look at on the space they moved to.
    ///
    /// It is the same close Escape performs, and deliberately so — one way of closing that closed
    /// it differently would be a second state machine. It also stands in for the stow below rather
    /// than preceding it: the island has just made one large move, and following it with a second
    /// would read as two events for one switch.
    ///
    /// Three things stop the stow, and each is somebody having already answered the question:
    ///
    /// - **an island that is already stowed**, where there is nothing to do and a second transition
    ///   would rebuild every hit region for it.
    /// - **the screen being away** — locked, or asleep. `collapseIntoNotch` already owns the island
    ///   there, and a space change arriving mid-unlock is the window server's business, not the
    ///   user's.
    /// - **anything but music on stage.** A notification, a HUD or a timer is not a record of the
    ///   space being left, and a stow would put every one of them away as collateral. The primary
    ///   only: music with a timer beside it is still the timer's island too.
    private func spaceChanged() {
        guard !isScreenAway else { return }
        // **Any** island being open answers for all of them, not merely the one on the display the
        // pointer happens to be over: the space switch is app-wide, so leaving the second display's
        // island open would be two answers to one question. `collapseAll` and not
        // `collapseUserOpenedIslands` — a space switch is the user aiming away from every island on
        // the machine, including the ones Isleta opened for them.
        if models.values.contains(where: \.isExpanded) {
            IslandLog.space.info("space changed with an island open — closing")
            collapseAll()
            return
        }
        guard !autoStowed else { return }
        guard activities.stage?.primary.kind == .nowPlaying else { return }
        // The player's own answer, not an uninitialized `false`: `isTransportAvailable` is the
        // honest form of "there is a route to the player, so what it says about playing or paused
        // is a fact" — the same gate `NowPlayingSlotView.coverIsPaused` reads, and for the same
        // reason. A scripting-only route reports both; a build with no route at all reports
        // neither, and stowing on that would put the island away for a player nobody can ask.
        guard let player = nowPlaying?.controller, player.isTransportAvailable, !player.isPlaying
        else { return }
        // There has to be something to put away.
        guard models.values.contains(where: { !$0.isStowed }) else { return }
        IslandLog.space.info("space changed with the player paused — stowing")
        setStowedEverywhere(true, automatic: true)
    }

    /// The player started or stopped.
    ///
    /// The half of `spaceChanged` that gives the island back. Music starting again is the user
    /// asking for exactly the thing that was put away, and having to swipe for it would make the
    /// auto-stow a trap rather than a tidy-up.
    ///
    /// Only Isleta's own stow is undone. A user who swiped the island away and then pressed play in
    /// Music has said two separate things, and the second does not revoke the first.
    private func playingChanged(_ isPlaying: Bool) {
        guard isPlaying, autoStowed else { return }
        IslandLog.nowPlaying.info("playback resumed — unstowing")
        setStowedEverywhere(false)
    }

    /// Closes every island, whoever opened it.
    ///
    /// Escape, the close gesture, and opening the player app in its own application. Each of those
    /// is the user aiming at *this island, now*, which settles the question of whose island it is as
    /// firmly as a click on it does — so what Isleta opened is no longer Isleta's to expire.
    private func collapseAll() {
        autoOpened.removeAll()
        collapseIslands(Array(models.keys))
    }

    /// Closes only the islands the **user** opened. A click somewhere else on the machine.
    ///
    /// Clicking away dismisses a transient surface, and that is right for an island the user opened
    /// — but a notification or a greeting opened *itself*, in the middle of whatever they were
    /// already doing, and their next click is part of that work rather than an answer to it. The old
    /// behavior lost the message: a notification arrived, the user carried on typing, and the click
    /// that put the caret back in their editor took the island away before they had read it. macOS's
    /// own banners do not behave that way, and this island is the same surface.
    ///
    /// So an incidental click is not a dismissal. The deliberate ones still are, and since
    /// 2026-08-26 there are four — Escape, the pointer leaving the island, a click in its blur, and
    /// swiping it up — none of which can happen by accident while working in another app. A click on
    /// the island is no longer one of them: it only ever opens (`controller.onClick`). Anything left open expires on its own within seconds
    /// (`ActivityKind.defaultExpiry`), which is what makes leaving it alone safe rather than sticky.
    ///
    /// `autoOpened` is deliberately **not** cleared here, for the same reason: a click elsewhere is
    /// not the user taking ownership of an island they never asked for, so the ones still standing
    /// stay Isleta's to close when their activity goes.
    private func collapseUserOpenedIslands() {
        collapseIslands(models.keys.filter { !autoOpened.contains($0) })
    }

    /// Closes the island on one screen — the pointer left it, or its blur was clicked.
    ///
    /// Routed through `collapseIslands` like every other close, so a pointer leaving hands the
    /// island back in exactly the state Escape leaves it in: the reply abandoned, the shelf's search
    /// and the switcher's key registration given up, the hit region tightened. A second way of
    /// closing that closed it *differently* would be a second state machine — the same argument
    /// `IslandCloseGesture` makes for arriving here rather than doing its own thing.
    ///
    /// **Only the user's own island.** An island Isleta opened by itself — a notification, a
    /// greeting — is not dismissed by the pointer wandering off it, exactly as it is not dismissed
    /// by a click elsewhere (`collapseUserOpenedIslands`). It has a dwell of its own, and the
    /// pointer resting on it already holds that dwell open and releases it on leaving
    /// (`holdNotificationBanners`); closing here as well would take the banner away at the moment
    /// the grace period was meant to start.
    private func closeIsland(on screen: IslandScreen, reason: String) {
        guard models[screen.id]?.isExpanded == true, !autoOpened.contains(screen.id) else { return }
        IslandLog.panel.info("closing island on display \(screen.id) — \(reason)")
        collapseIslands([screen.id])
    }

    /// Closes the open island when the pointer leaves it — the other half of "a click opens it".
    ///
    /// ## Leaving means leaving the blur
    ///
    /// The region this is reported against is `IslandLayout.hoverRegion` for an open island, which
    /// is the island grown by `IslandLayout.blurSpread`. That is the whole reason the blur is drawn:
    /// an open island is a 368pt panel with controls near its rim, and a boundary the user cannot
    /// see is a boundary they cross by accident. The blur says where the island's authority ends.
    ///
    /// ## Why it is an edge and not a state
    ///
    /// It closes on the pointer **leaving**, never on the pointer merely being outside. An island
    /// opened by the global hot key with the pointer on the other display has no hover to lose, and
    /// treating "not hovering" as the trigger would close it in the same frame it opened. Only a
    /// reported exit closes, so an island the pointer never reached stays until the user says
    /// otherwise.
    ///
    /// ## Why there is a delay
    ///
    /// `mouseExited` is not guaranteed to be about the pointer having gone anywhere. It arrives from
    /// a tracking rect that is rebuilt whenever the island's size changes, and a rect rebuilt under
    /// a stationary pointer reports an exit and a fresh entry — so a content change that makes the
    /// open island taller would otherwise close it. Waiting `pointerExitGrace` and then asking the
    /// view where the pointer actually **is** costs one call and settles both: a real departure is
    /// still outside, a rebuild is not. `IslandHitTestView.refreshHover` makes the same call for the
    /// same reason on unlock.
    private func pointerExitChanged(_ hovering: Bool, on screen: IslandScreen) {
        pointerExitTimers.removeValue(forKey: screen.id)?.invalidate()
        guard !hovering, models[screen.id]?.isExpanded == true else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.pointerExitGrace, repeats: false) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pointerExitTimers.removeValue(forKey: screen.id)
                // **Where the pointer is, not where an event said it went.** Asked as a position
                // against the live hover region rather than as `isHovering`, because on an open
                // island a crossing is no longer evidence: the band the pointer is allowed to rest
                // in is drawn in `IslandBlurPanel`, a different window, so this panel stops hearing
                // about the pointer the moment it crosses the island's own edge and AppKit reads
                // that as leaving. `IslandHitTestView.mouseExited` makes the same check for the same
                // reason.
                guard self.controller?.isPointerInsideHoverRegion(forScreen: screen.id) != true else {
                    return
                }
                // The pointer is on Isleta's own menu, which is a window of ours over the island —
                // so it has not left in the sense that matters. `menuDidClose` asks again.
                guard !self.isShowingIslandMenu else { return }
                self.closeIsland(on: screen, reason: "pointer left the island")
            }
        }
        pointerExitTimers[screen.id] = timer
    }

    /// The pointer arriving on the album cover in the leading flank, or leaving it.
    ///
    /// **No haptic.** The tap is for the island arriving somewhere the user did not ask to go — the
    /// pointer crosses the notch and something is there — and it has already been spent on the peek
    /// this lip grows out of, one pointer movement earlier. A second tap for traveling 20pt across
    /// an island that is already under the hand is the app tapping for its own state changes.
    /// The pointer moved on one island, or left it (`nil`).
    ///
    /// One rect-contains test, on a stream that only flows while the pointer is on the island — see
    /// `IslandHitTestView.onPointerMoved` for the §9 argument and for the bug that made a position
    /// necessary where a tracking area looked sufficient.
    ///
    /// **Immediate, in both directions.** It shipped with a 180ms dwell on arrival, guarding
    /// against a pointer crossing the notch on its way to the menu bar flashing the strip in
    /// transit. The owner's verdict on hardware, 2026-08-27: coming to the cover from inside the
    /// notch, the lip has to be there *already* — and that is the movement this feature is for.
    ///
    /// The guard the dwell was doing is already paid for one step earlier. The lip is forced false
    /// unless the island is peeking (`IslandForm.showsTrackLip`), and peeking is itself behind the
    /// island's own `hoverDelay` — so a pointer merely passing through has not peeked, has no lip
    /// to flash, and the stored input is discarded by the form rather than drawn.
    private func pointerMoved(to point: CGPoint?, on screen: IslandScreen) {
        guard let model = models[screen.id] else { return }
        let onArtwork: Bool = if let point, let size = controller?.panelContentSize(forScreen: screen.id) {
            model.isPointOnAlbumArtwork(point, inPanelOfSize: size)
        } else {
            false
        }
        // Cheap and constant on the moves that change nothing, which is nearly all of them: a
        // transition that would assign the state the model already holds still rebuilds a hit
        // region, and this stream is every move event the island receives.
        guard onArtwork != model.isHoveringArtwork else { return }
        transition(on: screen) { model, reduceMotion, completion in
            model.setHoveringArtwork(onArtwork, reduceMotion: reduceMotion, completion: completion)
        }
    }

    /// How long the pointer has to be gone before the island closes behind it.
    ///
    /// Short enough that the island does not feel sticky and long enough to outlast a tracking-rect
    /// rebuild, which resolves inside one run-loop pass. It is deliberately **not** a
    /// `Motion` token: this is not a curve, it is a grace period, and scaling it with the user's
    /// animation speed would make a faster island a twitchier one.
    private static let pointerExitGrace: TimeInterval = 0.22

    /// Whether Isleta's own menu is up over the island.
    ///
    /// **The island closes when the pointer leaves it, and moving onto a menu is the pointer
    /// leaving.** Without this the menu would be raised over an island that was already collapsing:
    /// the menu itself is fine, and everything it was raised from is gone behind it. Set in
    /// `showIslandMenu`, cleared in `menuDidClose`, which then re-asks the question the grace period
    /// was in the middle of answering.
    private var isShowingIslandMenu = false

    /// The shared half. `isExpanded` is checked per island because assigning the state one already
    /// holds would still run a transition and rebuild its hit region for nothing.
    ///
    /// The ids are snapshotted by both callers rather than iterated out of `models`, since
    /// `transition(on:_:)` reaches back into the dictionary.
    private func collapseIslands(_ ids: some Sequence<CGDirectDisplayID>) {
        // A closing island abandons the shelf's search and any half-finished reorder, and the
        // search field holds the *keyboard*. Here rather than in `collapseAll`, so that every close
        // path is covered — an outside click, the shelf closing an island it opened, and the screen
        // being locked all reach this and none of them reaches `collapseAll`.
        shelf.islandsClosed()
        // A closed island forgets Up Next, for the same reason and with one of its own: the
        // surface holds a wider queue window than the sneak peek needs, and leaving it open would
        // leave the helper re-reading a hundred entries on every track change for a list nobody is
        // looking at.
        // A closed island forgets today and tomorrow, for the drop history's reason: reopening onto
        // the surface the user was reading three hours ago is the island deciding what they came
        // back for. The two lists go with it rather than being kept warm — they are somebody's
        // calendar, and holding one in memory for a surface nobody has open buys nothing.
        //
        // **The page is reset too, but not here — see `resetPageAfterClose`.** It used to be, and
        // that was visible: closing from the weather page swapped the body back to home and
        // restated the island's height *while the island was still on screen shutting*, so the last
        // thing the user saw was a page they had not asked for, half way into a collapse. The
        // reason to forget the page is about what the island reopens on, and nothing about that
        // requires it to happen before the island has finished closing.
        if glance.isShowingSchedule, ids.contains(where: { models[$0]?.isExpanded == true }) {
            glance.isShowingSchedule = false
            glance.todayEvents = []
            glance.tomorrowEvents = []
            restateExpandedContentHeight()
        }

        // A closed island forgets the history: reopening onto what
        // the user was reading three hours ago is the island deciding what they came back for.
        if dropHistoryModel.isShowing, ids.contains(where: { models[$0]?.isExpanded == true }) {
            dropHistory.didToggle(isShowing: false)
            for model in models.values { model.dropHistory?.isShowing = false }
            restateExpandedContentHeight()
        }

        if isShowingNowPlayingQueue, ids.contains(where: { models[$0]?.isExpanded == true }) {
            nowPlayingQueueScroll.reset()
            nowPlaying?.controller.isShowingQueue = false
            nowPlaying?.controller.queueScrollTarget =
                nowPlaying?.controller.queueScrollTarget.dragged(to: 0) ?? NowPlayingQueueScrollTarget()
            nowPlaying?.requestQueueWindow(lastVisibleRow: 0, isOpen: false)
            restateExpandedContentHeight()
        }
        // Once for the whole close, however many displays are shutting: the page is app-wide, and
        // whichever island lands first is late enough — they all animate on the same spring.
        var resetPage = pages.current != .home && ids.contains { models[$0]?.isExpanded == true }
        for id in ids {
            guard models[id]?.isExpanded == true,
                  let screen = controller?.screens.first(where: { $0.id == id })
            else { continue }
            transition(on: screen) { [weak self] model, reduceMotion, completion in
                model.setExpanded(false, reduceMotion: reduceMotion) {
                    if resetPage {
                        resetPage = false
                        self?.resetPageAfterClose()
                    }
                    completion()
                }
            }
        }
    }

    /// Puts the island back on the page it opens on, once it has finished closing.
    ///
    /// **Reopening onto the forecast somebody read three hours ago is the island deciding what they
    /// came back for**, which is the same argument that closes the month grid and the drop history
    /// on the way out. What changed on 2026-08-28 is *when*: this used to run at the top of
    /// `collapseIslands`, so the body swapped to home and the island restated its height while it
    /// was still visibly shutting. A close should look like the surface the user was reading going
    /// away, and nothing else.
    ///
    /// **Un-animated, and it has to be.** Nothing is drawn to animate — the island is closed — and
    /// this runs inside the collapse's own completion handler, where that animation is still
    /// ambient. A bare assignment would inherit the collapse spring and quietly animate a page
    /// change nobody can see, which is a transaction and a shape rebuild for no pixels.
    ///
    /// Silent if the island opened again in the meantime: the collapse is a third of a second long,
    /// and a user who reopened inside it has answered the question this was about to.
    private func resetPageAfterClose() {
        guard !models.values.contains(where: \.isExpanded) else { return }
        // A close can land on top of a turn whose tail is still travelling. Nothing is drawn to
        // finish it against, and a carousel left armed keeps two pages nobody is looking at alive
        // against §9's idle budget — so the swipe is put back at rest here rather than waiting for
        // a completion that has nothing left to complete.
        for model in models.values {
            model.swipe.clearOffsetWithoutAnimation()
            model.swipe.endPaging()
        }
        pageDragStep = 0
        // Before the guard, and unconditionally: a close from home turns no page, and a dwell left
        // armed would fire into an island that is not drawn — and, worse, leave the dots already
        // faded when the next open wants to show them.
        pages.hideIndicator()
        // **The page the island comes back to, which is not always home.** It remembers home and
        // music and deliberately does not remember the weather — see `IslandPageModel.rememberedPage`
        // — so this guard asks whether the reset would actually move anything rather than assuming
        // the destination. Asked against `.home` it skipped the reset for somebody closing on home
        // with music remembered, and the island reopened where it closed rather than where it was
        // told to.
        guard pages.current != pages.rememberedPage else { return }
        withTransaction(Transaction(animation: nil)) {
            pages.reset()
        }
        restateExpandedContentHeight()
    }

    /// Toggles the island on whichever screen the pointer is on, or the only one there is.
    private func toggleExpansionFromKeyboard() {
        guard let controller else { return }
        let pointer = NSEvent.mouseLocation
        let screen = controller.screens.first { $0.frame.contains(pointer) } ?? controller.screens.first
        guard let screen else { return }
        transition(on: screen) { model, reduceMotion, completion in
            model.toggleExpanded(reduceMotion: reduceMotion, completion: completion)
        }
    }

    // MARK: - Pages

    /// What the home page's music column and the music page draw, or nil when nothing is playing.
    ///
    /// Read from the **coordinator** rather than from the stage, and that is the whole reason it is
    /// here rather than derived on `IslandScreenModel`: the stage holds at most two activities, so a
    /// timer and the calendar sharing it would leave the music column blank while a track was
    /// playing — which is exactly the moment somebody is looking at it. The stack knows either way.
    private var nowPlayingContent: ActivityContent? {
        let outstanding = [activities.presented].compactMap { $0 } + activities.queued
        guard let playing = outstanding.first(where: { $0.kind == .nowPlaying }) else { return nil }
        let content = playing.presentations.expanded
        // A route that reports a player but no track has nothing to draw — and a music column with
        // an empty title beside an empty artist is worse than the "Not playing" placeholder, which
        // at least says what it means. `IslandScreenModel.trackLipContent` refuses on the same test.
        return content.title == nil ? nil : content
    }

    // MARK: - Dragging a page

    /// Which way the live page gesture is heading, or 0 when there is none.
    ///
    /// Held so `beginPageDrag` can tell a fresh direction from the ninety samples that follow it: a
    /// trackpad delivers ~120 a second, and re-arming every island on each one would rebuild two
    /// page views and a hit region a hundred times a second for a gesture that has not changed its
    /// mind.
    private var pageDragStep = 0

    /// The finger has picked a direction: put the page it is heading toward on screen, and let the
    /// island's outline start following the drag toward that page's height.
    ///
    /// **Called while the gesture is still tracking, repeatedly, and it must be cheap after the
    /// first.** See `pageDragStep`.
    ///
    /// The hit region is widened here and tightened when the offset lands — the widen-then-tighten
    /// protocol §6.2 asks of every moving outline, and the reason it is safe for the island's bottom
    /// edge to follow a finger at all. `widenHitRegion(toContain:)` rather than the form-taking
    /// widen: the shape being dragged toward is another *page's* height, and the controller's own
    /// `expandedContentHeight` is still the page being left.
    private func beginPageDrag(step: Int) {
        guard let controller, pages.canTurn, step != 0 else { return }
        // **The direction the content is displaced in, which is not always the direction the finger
        // is going.** A gesture that starts while the last turn is still easing home picks up that
        // tail, and the neighbour on screen is the one the tail is showing — so the island's outline
        // has to be heading for *that* page's height until the drag pulls the offset through zero,
        // at which point this re-arms with the other one. Reading the offset rather than the finger
        // is what keeps the two agreeing throughout; see `IslandSwipeModel.offset`.
        let displaced = controller.screens.lazy.compactMap { self.models[$0.id]?.swipe.offset }.first ?? 0
        let heading = displaced > 0 ? -1 : displaced < 0 ? 1 : step
        guard heading != pageDragStep else { return }
        pageDragStep = heading
        // The dots stay up for the whole gesture. They fade two seconds after a page settles
        // (`IslandPageModel.indicatorDwell`), and a carousel being dragged is the one moment they
        // are certainly being read — so the clock is stopped here and restarted where the gesture
        // ends, in `settlePageDrag` and in `commitPageDrag`'s landing.
        pages.holdIndicator()
        let destination = pages.current.stepped(by: heading)
        let stage = activities.stage
        let height = expandedContentHeightForStage(
            presentations: stage?.primary.presentations,
            kind: stage?.primary.kind,
            page: destination
        )
        let span = IslandLayout.expandedBodySize.width
        for screen in controller.screens {
            guard let model = models[screen.id] else { continue }
            let table = Self.metrics(
                for: screen,
                sizing: islandSizing,
                expandedContentHeight: height,
                expandedContentWidth: expandedContentWidth,
                pageIndicatorHeight: pageIndicatorHeight
            )
            // The **form the island is actually in**, not `.expanded` flat: a flanked island being
            // dragged is still flanked, and taking the unflanked shape would interpolate the
            // outline toward a narrower island for the length of the gesture.
            guard let incoming = table[model.form] ?? table[.expanded] else { continue }
            model.swipe.beginPaging(toward: incoming, span: span)
            controller.widenHitRegion(toContain: incoming, forScreen: screen.id)
        }
    }

    /// The gesture ended without carrying: the page goes back where it came from.
    ///
    /// The offset springs home and the outline follows it back, because `metrics` is interpolated
    /// against a `progress` that is on its way to zero. The neighbours come off screen and the hit
    /// region tightens only once that has landed — tightening at the release, against a shape the
    /// island is still travelling away from, is the subset `IslandHitTestView` is written to avoid.
    private func settlePageDrag() {
        guard let controller else { return }
        pageDragStep = 0
        for screen in controller.screens {
            guard let model = models[screen.id] else { continue }
            model.swipe.settle(reduceMotion: accessibility.reduceMotion) { [weak self] in
                model.swipe.endPaging()
                // Nothing turned, so nothing called `showIndicator`: the dots have been held since
                // `beginPageDrag` and this is what starts their dwell. Idempotent across screens.
                self?.pages.releaseIndicator()
                self?.controller?.setHitRegion(to: model.hitRegionMetrics, forScreen: screen.id)
            }
        }
    }

    /// The gesture carried: **the page swaps now**, and the content finishes crossing to it.
    ///
    /// ## The swap moves nothing, and it happens first
    ///
    /// It used to happen last — the offset travelled the remaining inches of the page and the
    /// identities swapped in the spring's completion, at the instant the incoming page was already
    /// drawn where the current one had been. That is invisible, and it was right for one swipe at a
    /// time. It was wrong for two: for the whole length of that spring `pages.current` still named
    /// the page being *left*, so a second swipe starting in the window computed its neighbours from
    /// the wrong page and was then overwritten by the first turn's completion, which zeroed a live
    /// finger offset and took the carousel down mid-gesture. What the user saw was the island
    /// stopping on the page it was animating into and refusing the next one.
    ///
    /// So the page changes here, synchronously, and `IslandSwipeModel.landTurn` re-expresses the
    /// offset against it rather than travelling toward it: the content was `offset` from the old
    /// page and is `offset - destination` from the new one, which is the same pixels described from
    /// the other end. The outline is continuous across the swap for the same reason — the shape
    /// table becomes the new page's and `incoming` becomes the page being left, and lerping the old
    /// height at `1 - progress` is arithmetically the height it was already at. Nothing on screen
    /// moves at the moment of the swap; what is left to travel is the tail, on `Motion.pageTurn`.
    ///
    /// The page turn a *dot* performs is still `applyPageChange` — it has no gesture behind it and
    /// so needs the travel a swipe has already done.
    private func commitPageDrag(by steps: Int) {
        guard let controller, pages.canTurn, steps != 0 else { return }
        let span = IslandLayout.expandedBodySize.width
        let step = steps > 0 ? 1 : -1
        // Negative offset is content pushed left, which is the next page arriving from the right.
        let destination = -CGFloat(step) * span
        pageDragStep = 0
        let stage = activities.stage
        let departing = pages.current
        let page = departing.stepped(by: step)
        let height = expandedContentHeightForStage(
            presentations: stage?.primary.presentations,
            kind: stage?.primary.kind,
            page: page
        )
        // The page being left, whose shape the outline has to keep lerping *from* while the tail
        // travels. Computed before the swap for the same reason the new one is: both are pure
        // functions of a page, and asking after the fact would ask about the wrong one.
        let departingHeight = expandedContentHeightForStage(
            presentations: stage?.primary.presentations,
            kind: stage?.primary.kind,
            page: departing
        )

        activities.noteInteraction()
        // Un-animated, and `withTransaction` rather than a bare assignment: `IslandRootView` gives
        // the page layer a directional slide keyed on its identity, and a swipe has already done
        // all the travelling there is to do.
        withTransaction(Transaction(animation: nil)) {
            _ = pages.go(to: page)
        }
        expandedContentHeight = height
        controller.expandedContentHeight = height
        // The dots' direction, kept honest for the *next* turn: a dot tapped straight afterwards
        // must not slide on whatever direction the last tapped dot left behind.
        pages.setTurnDirection(step)
        IslandLog.panel.debug("page dragged to \(page.rawValue)")

        for screen in controller.screens {
            guard let model = models[screen.id] else { continue }
            model.setPageMetricsWithoutAnimation(
                Self.metrics(
                    for: screen,
                    sizing: islandSizing,
                    expandedContentHeight: height,
                    expandedContentWidth: expandedContentWidth,
                    pageIndicatorHeight: pageIndicatorHeight
                )
            )
            let departingTable = Self.metrics(
                for: screen,
                sizing: islandSizing,
                expandedContentHeight: departingHeight,
                expandedContentWidth: expandedContentWidth,
                pageIndicatorHeight: pageIndicatorHeight
            )
            model.swipe.landTurn(
                by: destination,
                // The **form the island is actually in**, as `beginPageDrag` takes it: a flanked
                // island finishing a turn is still flanked.
                incoming: departingTable[model.form] ?? departingTable[.expanded],
                reduceMotion: accessibility.reduceMotion
            ) { [weak self] in
                guard let self else { return }
                model.swipe.endPaging()
                // `pages.go` above already lit the dots, but it did so at the *commit* — a third of
                // a second before the page finishes arriving. Restarted here so the two seconds are
                // measured from the page landing, which is when there is something to read.
                self.pages.releaseIndicator()
                self.controller?.setHitRegion(to: model.hitRegionMetrics, forScreen: screen.id)
            }
        }
    }

    /// Goes to a page directly — what a dot in the page indicator does.
    private func goToPage(_ page: IslandPage) {
        guard pages.canTurn else { return }
        // A dot has no direction of its own, so it takes the shorter way round — sliding the way the
        // row of dots is laid out rather than always from the same side.
        applyPageChange(direction: pages.current.steps(to: page) >= 0 ? 1 : -1) { [weak self] in
            self?.pages.go(to: page) ?? false
        }
    }

    /// The half both routes share: change the page, then move the island to fit it.
    ///
    /// - Parameter change: performs the page change and reports whether anything actually moved. A
    ///   dot tapped on the page already showing must not run the whole transition for no visible
    ///   difference — the island would widen its hit region, animate to the height it is already at,
    ///   and tighten again.
    private func applyPageChange(direction: Int, _ change: @escaping () -> Bool) {
        guard controller != nil else { return }
        // **The direction has to be on screen before the page changes.** SwiftUI builds a removal
        // transition from the departing view's *last* render, so a direction written in the same
        // breath as the page reaches the arriving half only — and on a reversal the two halves then
        // travel toward each other and collide. Reported as the views overlapping going one way and
        // never the other, which is precisely the asymmetry a stale direction produces.
        //
        // A swipe has normally published it already, from the finger (`SwipeController`), so this is
        // free and the turn happens in the same runloop turn the gesture committed in. It is only
        // the dot in the indicator — which has no tracking phase — that pays a frame, and only when
        // it reverses. `setTurnDirection` returning false is what distinguishes the two.
        guard pages.setTurnDirection(direction) else {
            performPageChange(change)
            return
        }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.performPageChange(change) }
        }
    }

    /// Turns the page and moves the island to fit it. The direction is already published.
    private func performPageChange(_ change: () -> Bool) {
        guard controller != nil else { return }
        // **Inside a transaction, or the page has nothing to animate.** `IslandRootView` gives the
        // page a directional slide, and a transition only runs when the change that inserted or
        // removed the view was itself animated. Turned outside one, the new page simply replaced the
        // old in a single frame while the island's *height* animated around it — reported as the
        // views appearing rather than sliding.
        //
        // `isTurning` is what tells the view this is a **turn** rather than the page layer arriving
        // with the island. Set before the transaction so the transition being built inside it can
        // already see it; cleared once the island has finished resizing, which is strictly after the
        // content transition it gates has run.
        //
        // `Motion.contentSwap` rather than the `Motion.nudge` the metrics travel on below, and the
        // pair is §6.2 exactly: the container leads and the content follows on its own curve. It is
        // The swipe does not come through here at all any more — a dragged page finishes its
        // crossing and swaps in place (`commitPageDrag`). This is the indicator's dots, which have
        // no gesture behind them and so need the travel.
        // Always animated, even under Reduce Motion: that setting substitutes a crossfade rather
        // than removing the change, and `IslandRootView.pageTransition` makes the same substitution
        // at the other end by giving the page `.opacity` instead of a slide. §6.3 asks for the state
        // to still be *shown*, by a fade rather than by travel.
        pages.isTurning = true
        var turned = false
        withAnimation(
            Motion.respectingReduceMotion(Motion.contentSwap, reduceMotion: accessibility.reduceMotion)
        ) {
            turned = change()
        }
        guard turned, let controller else {
            pages.isTurning = false
            return
        }
        activities.noteInteraction()
        IslandLog.panel.debug("page turned to \(self.pages.current.rawValue)")

        let stage = activities.stage
        let newContentHeight = expandedContentHeightForStage(
            presentations: stage?.primary.presentations,
            kind: stage?.primary.kind
        )
        let newContentWidth = expandedContentWidthForStage()
        // Before the transition, never after: `widenHitRegionForTransition` asks the controller
        // where the island is going, so a height set afterwards widens against the island being left.
        expandedContentHeight = newContentHeight
        controller.expandedContentHeight = newContentHeight
        expandedContentWidth = newContentWidth
        controller.expandedContentWidth = newContentWidth

        for screen in controller.screens {
            let metrics = Self.metrics(
                for: screen,
                sizing: islandSizing,
                expandedContentHeight: newContentHeight,
                expandedContentWidth: newContentWidth,
                pageIndicatorHeight: pageIndicatorHeight
            )
            transition(on: screen) { model, reduceMotion, completion in
                model.setPageMetrics(metrics, reduceMotion: reduceMotion) { [weak self] in
                    // Idempotent, and every screen animates on the same spring, so whichever lands
                    // first is late enough: the content transition this gates is shorter than the
                    // island's own resize.
                    self?.pages.isTurning = false
                    completion()
                }
            }
        }
    }

    /// Opens the island on a page — what both of the status menu's quick actions do.
    ///
    /// **A page, not an activity, and that is the change the pages made to this menu.** Both rows
    /// used to bring a kind the stack was already holding to the front, which worked only while the
    /// calendar stood on the stack as an ambient activity. It does not any more (see
    /// `ActivityKind.glance`), and "Show Now Playing" landing on whichever page the island happened
    /// to close on was never what the row said. The pages are a fixed enum, so this is total: there
    /// is always a page to turn to.
    ///
    /// - Parameter pinning: a kind to hold at the head of the stack first, or nil. Only the music
    ///   page has one, and it is not decoration: `IslandScreenModel.drawsPages` lets an activity
    ///   that *arrived* keep the body it brought with it, so opening the music page while a volume
    ///   HUD is up would draw the HUD. Pinning is the chip's own move — `onSelectChip` makes
    ///   exactly this call — so a quick action cannot open the island differently from a click on
    ///   the same activity. Silent when the kind is not on the stack, which is the honest answer:
    ///   `StatusMenuModel` has already disabled the row with a reason.
    ///
    ///   The glance pins nothing, because there is nothing to pin. An activity holding the body
    ///   keeps it for its few seconds and the page arrives when it expires, which is what
    ///   `drawsPages` documents rather than a special case for this caller.
    private func openIsland(on page: IslandPage, pinning kind: ActivityKind? = nil) {
        guard let controller else { return }
        if let kind, let chip = activities.chips.first(where: { $0.kind == kind }) {
            activities.noteInteraction()
            _ = activities.pin(chip.id, holding: Self.pinHoldForClick)
        }

        // **Un-animated while the island is closed, animated when it is open**, which is
        // `resetPageAfterClose`'s rule read the other way round. Nothing is drawn to slide, so a
        // turn here would be a transaction and a shape rebuild for no pixels — and the island is
        // about to animate to this page's height anyway, from `setExpanded`. Once something is
        // already open the user *can* see the turn, and hiding it would make the island change
        // surface with no motion to explain it.
        if models.values.contains(where: \.isExpanded) {
            goToPage(page)
        } else if pages.current != page {
            withTransaction(Transaction(animation: nil)) {
                _ = pages.go(to: page)
            }
            restateExpandedContentHeight()
        }

        for screen in controller.screens where models[screen.id]?.isExpanded != true {
            transition(on: screen) { model, reduceMotion, completion in
                model.setExpanded(true, reduceMotion: reduceMotion, completion: completion)
            }
        }
    }

    // MARK: - Activities

    /// What the coordinator changed, pushed to every island.
    ///
    /// Routed through the same `transition(on:_:)` every hover and click goes through, and that is
    /// the point of having one function: the hit region, the hover region, the Escape registration
    /// and the debug info are all refreshed in one documented order, and a content change cannot
    /// quietly skip a step that a click does not. The one thing it does *not* do falls out of
    /// that path for free: the haptic fires only when the presentation moved, so an activity
    /// arriving never taps the trackpad (nothing the user did caused it).
    ///
    /// The motion token comes from the change itself, in `Motion.animation(for:reduceMotion:)`. See
    /// there for why `contentChanged` must not be a morph.
    ///
    /// Whether the hit region is widened is decided per screen, by asking whether this change flips
    /// the island between its cutout-sized resting shape and its flanked one. Both wrong answers
    /// are bugs rather than inefficiencies: widening on every change would rebuild `islandPath`
    /// twice per scrub, and *not* widening on a flank change leaves the hit region a subset of the
    /// island being drawn for the length of the morph — clicks on the flanks reach us and get
    /// dropped on the floor, which is the failure `IslandHitTestView` is written around.
    private func activityChanged(_ change: ActivityChange) {
        guard let controller else { return }
        let stage = activities.stage
        let presentations = stage?.primary.presentations
        let kind = stage?.primary.kind
        // Read once for the loop below rather than per screen: it walks the stack, and every island
        // is showing the same track.
        let playingContent = nowPlayingContent
        // An auto-stow is about **music the user has finished with**, and about nothing else.
        // Anything else reaching the stage — a HUD, a timer, a call — is a thing the island
        // exists to show, and delivering it into an island Isleta had quietly put away would make a
        // tidy-up swallow somebody's message. First, so the content arrives into an island that is
        // already on its way back rather than one that unstows a beat behind it.
        if autoStowed, let kind, kind != .nowPlaying {
            IslandLog.space.info("\(kind) took the stage — unstowing")
            setStowedEverywhere(false)
        }
        // The shelf draws the open island's body itself, so it has to know when something else has
        // taken the stage from it — a volume HUD is `.interrupting` and preempts a `.standard`
        // shelf mid-drag.
        shelf.presentedKindChanged(to: kind)
        // An activity taking the stage can take the body from the pages — see `drawsPages` — so the
        // weather poll is re-asked here as well as on every transition.
        refreshWeatherPolling()
        // The **span**, not the flag. A HUD arriving over music leaves "has flank content" true on
        // both sides of the change while moving the outline by 112pt, so a boolean comparison here
        // decides the outline is not moving and skips the widen — drawn island that rejects clicks
        // for the length of the morph, which is the subset `IslandHitTestView` is written around.
        let incomingFlanks = IslandScreenModel.flanks(in: stage)

        // How tall the open island has to be for this activity, decided once for the app and
        // applied everywhere before anything moves.
        //
        // **Before**, and that ordering is the same rule the widen-then-tighten protocol follows:
        // `transition` widens to the *expanded* form, and it asks `IslandController` what that
        // shape is. Set afterwards, the union would be taken against the height the island is
        // leaving, and an activity that opens taller than the last one would spend the whole morph
        // painting island that we reject clicks on — the subset `IslandHitTestView` is written
        // around.
        let newContentHeight = expandedContentHeightForStage(presentations: presentations, kind: kind)
        // The row appears the moment anything is on stage and leaves when the stage empties, so it
        // moves the open island's outline exactly as a content height does — and through the same
        // widen-then-tighten protocol, for the same reason.
        let newPageIndicatorHeight = pageIndicatorHeight
        // The width moves with the same protocol, and for the same reason. Nothing an activity does
        // changes it today — only the month asks for more than the default — but a table built with
        // one width and a controller holding another is the subset bug in its other dimension.
        let newContentWidth = expandedContentWidthForStage()
        let heightChanged = newContentHeight != expandedContentHeight
            || newContentWidth != expandedContentWidth
            || newPageIndicatorHeight != controller.pageIndicatorHeight
        expandedContentHeight = newContentHeight
        controller.expandedContentHeight = newContentHeight
        expandedContentWidth = newContentWidth
        controller.expandedContentWidth = newContentWidth
        controller.pageIndicatorHeight = newPageIndicatorHeight

        let chips = activities.chips

        // **The surface that is not an island, on every change.** It draws what is playing whether
        // or not Now Playing is the activity on stage — a volume HUD is `.interrupting` and
        // preempts the music for four seconds, which is exactly the moment a lock screen must not
        // blank — so it reads the whole stack rather than the stage.
        //
        // This is the only feed that surface has. Dropped from this method by a refactor, it left
        // `LockScreenCardModel.content` at the nil it is constructed with, for the life of the
        // process: the lock screen drew the padlock alone, because that is the one part of the lock
        // surface not gated on there being a track. Reported as "the lock screen music player
        // doesn't reliably show up".
        lockScreen?.adopt(from: activities)

        for screen in controller.screens {
            let outlineMoves = models[screen.id]?.flanks != incomingFlanks
            // A height change moves the outline only for an island that is *open*. On a collapsed
            // one it changes a row of the shape table nobody is currently drawing from, and
            // widening for it would rebuild `islandPath` twice for a track title moving on.
            let openIslandResizes = heightChanged && models[screen.id]?.isExpanded == true
            let metrics = Self.metrics(
                for: screen,
                sizing: islandSizing,
                expandedContentHeight: newContentHeight,
                expandedContentWidth: newContentWidth,
                pageIndicatorHeight: newPageIndicatorHeight
            )
            models[screen.id]?.chips = chips
            // **On every stack change, not once when the panel was built.** Now Playing re-presents
            // on each track, so a value pushed only at construction is whatever was playing the
            // moment the panel appeared — which on a normal launch is nothing, so the home page's
            // music column said "Not playing" through an entire album. Reported from use, with the
            // artwork and the pause button visible beside the words.
            models[screen.id]?.nowPlayingContent = playingContent
            transition(on: screen, widensHitRegion: outlineMoves || openIslandResizes) { model, reduceMotion, completion in
                model.setActivity(
                    stage,
                    change: change,
                    reduceMotion: reduceMotion,
                    metricsByForm: metrics,
                    completion: completion
                )
            }
        }

        // After the content, never before: the island opens onto the greeting, so the thing it is
        // opening for has to be on stage by the time the shape starts moving. Ordered this way the
        // expansion is one animation carrying content that is already there, rather than an empty
        // island growing and being filled in a frame later.
        updateAutoOpen(for: kind)
    }

    /// Opens or closes the islands *Isleta* opened, for the one kind of activity that asks for it.
    ///
    /// Called from `activityChanged` and from nowhere else, so the decision is made once per change
    /// to what is on stage rather than being scattered over the paths that produce those changes.
    /// It reads the presented kind rather than the `ActivityChange`: `.presented`, `.swapped` and
    /// `.contentChanged` can all leave a greeting on stage, and the question here is only ever what
    /// the island is showing now.
    private func updateAutoOpen(for kind: ActivityKind?) {
        guard kind?.opensIsland == true else {
            // Whatever was asking for the island is gone — expired, dismissed, or preempted by
            // something louder. An island still open on it is open on nothing.
            pendingAutoOpen = false
            autoOpenTask?.cancel()
            autoOpenTask = nil
            closeAutoOpenedIslands()
            return
        }
        guard !isScreenAway else {
            pendingAutoOpen = true
            return
        }
        openIslandsForActivity()
    }

    /// Opens every island that is not already the user's.
    ///
    /// Two islands are left alone, and both are the user having already answered this question.
    /// **Expanded** is an island they opened themselves; opening it again would do nothing and
    /// closing it later would be taking their island away. **Stowed** is a swipe that said "not
    /// now" — the greeting is exactly the kind of thing that swipe was aimed at, and unstowing to
    /// deliver it would be Isleta overruling the gesture within seconds of it being made.
    private func openIslandsForActivity() {
        guard let controller else { return }
        for screen in controller.screens {
            guard let model = models[screen.id], !model.isExpanded, !model.isStowed else { continue }
            autoOpened.insert(screen.id)
            transition(on: screen) { model, reduceMotion, completion in
                model.setExpanded(true, reduceMotion: reduceMotion, completion: completion)
            }
        }
    }

    /// Closes the islands this class opened, and forgets them.
    ///
    /// Anything the user has since done to one of these — closed it and opened it again, stowed it —
    /// has already taken it out of `autoOpened`, so everything left here is still Isleta's to close.
    /// The `isExpanded` check is for the island closed by some other route in between, where
    /// assigning the state it already holds would still run a transition and a hit-region rebuild.
    private func closeAutoOpenedIslands() {
        guard !autoOpened.isEmpty else { return }
        let closing = autoOpened
        autoOpened.removeAll()
        for id in closing {
            guard let screen = controller?.screens.first(where: { $0.id == id }),
                  models[id]?.isExpanded == true
            else { continue }
            transition(on: screen) { model, reduceMotion, completion in
                model.setExpanded(false, reduceMotion: reduceMotion, completion: completion)
            }
        }
    }

    private func installActivityObservers() {
        // Waking is the one moment the coordinator's own scheduling cannot be trusted on its own.
        // `Task.sleep` runs on the continuous clock, so a Mac that slept through a deadline does
        // resume with the sleep already elapsed — but "does" is a property of the current runtime,
        // and a HUD still on screen from before the lid closed is exactly the kind of thing that
        // gets reported and never reproduces. Expiring explicitly on wake costs one call.
        let observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.activities.refresh()
                return
            }
        }
        workspaceObservers.append(observer)
    }

    /// Pushes the accessibility settings the *renderer* needs into every model.
    ///
    /// Read straight from `NSWorkspace` rather than from `AccessibilityPreferences`, which observes
    /// the same notification: two observers on one notification have no ordering between them, so
    /// going through the other one would read whatever it happened to hold when this fired. The
    /// animation curves still come from `AccessibilityPreferences`, which is read at the moment a
    /// transition starts and so cannot be stale in the same way.
    private func installAccessibilityObserver() {
        let observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for model in self.models.values { self.applyAccessibility(to: model) }
            }
        }
        workspaceObservers.append(observer)
    }

    private func applyAccessibility(to model: IslandScreenModel) {
        let workspace = NSWorkspace.shared
        model.increaseContrast = workspace.accessibilityDisplayShouldIncreaseContrast
        model.reduceMotion = workspace.accessibilityDisplayShouldReduceMotion
        // §6.3's third setting, and the one Stage 7 gave a job to: with a glass style chosen it is
        // what puts the island back to solid. Read from `NSWorkspace` here rather than from
        // `AccessibilityPreferences` for the reason the two above are — two observers on one
        // notification have no ordering between them, so going through the other one would read
        // whatever it happened to hold when this fired.
        model.reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
    }

    // MARK: - Appearance

    /// Pushes how the island looks onto one model.
    ///
    /// Called from `makeContentView` as well as from `apply(_:)`, so a panel built after the user
    /// has changed something arrives wearing it rather than acquiring it one settings change later —
    /// the same reason `applyAccessibility` is called from both.
    ///
    /// **One of these three is a setting now.** Schema 18 took the style picker and the shadow
    /// switch out: `IslandStyle.automatic` is what the island has always drawn — pure `#000000` in a
    /// real cutout so it is optically part of the bezel, Liquid Glass where it floats below the menu
    /// bar — and the other three cases only ever let a user pick the wrong one for their display. The
    /// shadow shipped off and stayed off for a reason nothing in a picker could have carried: macOS
    /// derives a window's event shape from its alpha, so the shadow's own footprint is a band Isleta
    /// is handed clicks in and does not act on.
    ///
    /// `--style-demo` still overrides the style, because looking at the other three in a real cutout
    /// is exactly the job that flag exists for.
    ///
    /// The **sizes** are deliberately not here. They reach the model as `metricsByForm`, which is
    /// built alongside `IslandController.sizing` so the drawn shape and the clickable one cannot be
    /// built from two different readings; putting a width here as well would be a third reading.
    private func applyAppearance(_ configuration: IsletaConfiguration, to model: IslandScreenModel) {
        var style = IslandStyle.automatic
        // The call site is inside the `#if`, not merely the flag it reads. A Debug-only value read
        // into a `let` that a Release build can see makes the branch below unreachable, and
        // `-warnings-as-errors` fails Release on "will never be executed" — where `check.sh`, which
        // builds Debug, cannot see it.
        #if DEBUG
        if let override = Self.demandedIslandStyle() { style = override }
        #endif
        model.style = style
        model.showsShadow = false
        model.minimalWhenSynthesized = configuration.minimalOnSynthesizedDisplays
    }

    #if DEBUG
    /// `--style-demo [style]`: force a material for the run, whatever is stored.
    ///
    /// Worth a flag for the reason every other demo has one: three of the four styles have never
    /// been drawn in a real cutout, two of them cannot be told apart in a screenshot of an *empty*
    /// island — at rest on a notched Mac there is nothing but a hole to draw on — and changing the
    /// setting to look at one means opening Settings, which takes activation and repaints the
    /// screen behind the thing being judged.
    ///
    /// It does not write anything: the stored style is untouched, so the run ends and the user's
    /// choice is still theirs. With no argument it lists what it accepts rather than picking one,
    /// because a typo silently falling back to `.automatic` is a demo of the default.
    ///
    /// Debug only, like the overlay and the hot keys.
    private static func demandedIslandStyle() -> IslandStyle? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--style-demo") else { return nil }
        let named = arguments.count > flag + 1 ? arguments[flag + 1] : ""
        guard let style = IslandStyle(rawValue: named) else {
            IslandLog.app.info(
                "--style-demo: unknown style; expected one of "
                    + IslandStyle.allCases.map(\.rawValue).joined(separator: ", ")
            )
            return nil
        }
        IslandLog.app.info("--style-demo: drawing every island as \(style.rawValue)")
        return style
    }
    #endif

    /// Hides every island while an app on the user's list is in front, and puts them back after.
    ///
    /// `didActivateApplicationNotification` — push, free, and posted once per switch. No timer, and
    /// nothing at all runs while the list is empty, which is every install until somebody adds to it.
    ///
    /// Registered once and left alone; the *list* is what changes, and it is read at the moment the
    /// notification fires rather than captured, so adding an app takes effect on the next switch
    /// without re-registering. `refreshApplicationHiding()` covers the case the notification cannot:
    /// adding the app you are currently switched away from.
    private func installApplicationHidingObserver() {
        let observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshApplicationHiding() }
        }
        workspaceObservers.append(observer)
    }

    /// Asks whether the frontmost app is on the list, and tells the controller.
    ///
    /// Isleta itself is never on it, whatever the user put there. An `.accessory` app takes
    /// activation for a save panel and for the settings window — see `IslandPanel`'s own note on
    /// what taking key costs — so a user who added Isleta would hide the island the moment they
    /// opened Settings and never get it back from inside the app.
    private func refreshApplicationHiding() {
        let hidden = settings.configuration.hiddenApplications
        guard !hidden.isEmpty else {
            controller?.setSuppressed(false)
            return
        }
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard let frontmost, frontmost != Bundle.main.bundleIdentifier else {
            controller?.setSuppressed(false)
            return
        }
        controller?.setSuppressed(hidden.contains(frontmost))
    }

    // MARK: - The screen stopping being the user's

    /// Takes every island off screen when the screen locks or goes dark, and springs it back out of
    /// the notch once the way back in has finished playing.
    ///
    /// An island left open across a lock is faded out by the window server along with the desktop,
    /// at whatever size it happened to be — which reads as Isleta being caught mid-thought rather
    /// than as Isleta standing down. There is no way to make that fade look right from inside it:
    /// it belongs to the window server and it does not wait for us. The island has to be *finished*
    /// going before the first faded frame, which is why `collapseIntoNotch()` does not animate at
    /// all.
    ///
    /// The return is the opposite instruction. loginwindow dissolves its shield over the desktop,
    /// and an island that springs out during that dissolve arrives while the user is still watching
    /// the system's own animation — two animations over each other, and ours finished before they
    /// have looked at it. So the island waits out `returnDelay` and *then* plays
    /// `IslandScreenModel.playReentry`, which is the same spring the island comes back from another
    /// space on. One mechanism, so the two cannot drift apart.
    ///
    /// Five notifications, on two centers. Away:
    ///
    /// - `com.apple.screenIsLocked` — ⌃⌘Q, the menu, a hot corner, the screensaver with a password.
    /// - `NSWorkspace.willSleepNotification` — the lid, or the system sleeping on idle.
    /// - `NSWorkspace.screensDidSleepNotification` — the displays going dark on their own timer with
    ///   the system still awake, which posts neither of the other two.
    ///
    /// Back:
    ///
    /// - `com.apple.screenIsUnlocked` — somebody authenticated.
    /// - `NSWorkspace.screensDidWakeNotification` — the displays are lit again, which on a Mac with
    ///   no password is the whole of the return and on one with a password is the *lock screen*
    ///   appearing. `scheduleReturn` asks `ScreenLock` which of the two this is.
    ///
    /// None of them subsumes the others, and each arrives without the screen being lost or regained
    /// by any of the other routes, so all five are registered. Collapsing an island that is already
    /// away costs an assignment of a value to itself.
    ///
    /// Registered here rather than fed in from `SystemEventsSource`, even though that source
    /// listens to the same events, because this has to hold on a machine where the user has that
    /// source switched off — and because getting out of the way of a lock is a property of the
    /// island, not an activity anyone is being shown.
    private func installScreenLockObservers() {
        let distributed = DistributedNotificationCenter.default()
        distributedObservers.append(
            distributed.addObserver(
                forName: SystemEventsSource.sessionDidLockName,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    // Apple's HUD comes back for the length of the lock. On the login screen
                    // `loginwindow` captures every event, so Isleta can neither replace a level key
                    // nor draw for one — leaving the helper frozen would mean no HUD at all from
                    // either app. See `SystemOSDSuppressor.screenLockDidChange`.
                    SystemOSDSuppressor.screenLockDidChange(locked: true)
                    self?.takeIslandsAway(animated: true)
                }
            }
        )
        distributedObservers.append(
            distributed.addObserver(
                forName: SystemEventsSource.sessionDidUnlockName,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    SystemOSDSuppressor.screenLockDidChange(locked: false)
                    self?.scheduleReturn()
                }
            }
        )

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            workspaceObservers.append(
                workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.takeIslandsAway() }
                }
            )
        }
        workspaceObservers.append(
            workspace.addObserver(
                forName: NSWorkspace.screensDidWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleReturn() }
            }
        )
    }

    /// Takes every island off screen at once, without animating any of it.
    ///
    /// Routed through `transition(on:)` like every other change of shape, so the hit region is
    /// widened before the outline moves and tightened after, the hover region follows the resulting
    /// state, and the Escape hot key and the outside-click monitor are released. With no animation
    /// the completion fires inline, so the widen and the tighten land in the same turn of the run
    /// loop — which is correct rather than wasteful: a superset held for zero frames is still a
    /// superset, and skipping the widen would need a proof that nothing can arrive in between.
    ///
    /// **The models first, the tracking view second.** `cancelHover` reports back through
    /// `onHoverChanged`, and the shelf closes an island *it* opened on that callback — with an
    /// animation. Doing it first would start a spring collapse that this method's instant one could
    /// not then stop, because assigning `isExpanded` a value it already holds does not cancel the
    /// animation already driving it. In this order the callback finds the island at rest and does
    /// nothing.
    private func takeIslandsAway(animated: Bool = false) {
        guard let controller else { return }
        IslandLog.system.info("screen is away (lock, sleep or dark) — islands taken off screen")
        // A return scheduled by an earlier wake is now wrong — the displays waking and the machine
        // sleeping again ten seconds later is one lid, opened and closed. Without this the island
        // would spring out of the notch behind a screen that is already dark.
        pendingReturn?.cancel()
        pendingReturn = nil
        // Same for an open waiting on that return, and for the record of islands opened before it:
        // every island is going into the notch on the next line, so there is nothing left to close
        // and nothing to open onto.
        autoOpenTask?.cancel()
        autoOpenTask = nil
        pendingAutoOpen = false
        autoOpened.removeAll()
        isScreenAway = true
        // The shelf's search field is holding the *keyboard*, and this path does not go through
        // `collapseIslands` — the island is going into the notch rather than being closed. A field
        // left armed across a lock would be a panel that says it wants key on a machine where the
        // shield owns every event, and the first thing the user types at the unlock is a file
        // search.
        shelf.islandsClosed()

        // Animated on the lock only — the caller says which. A sleep or the displays going dark is
        // a screen that is about to be black, and a spring nobody can see is a spring for nothing.
        let reduceMotion = accessibility.reduceMotion
        for screen in controller.screens {
            transition(on: screen) { model, _, completion in
                model.collapseIntoNotch(
                    animated: animated,
                    reduceMotion: reduceMotion,
                    completion: completion
                )
            }
            controller.cancelHover(forScreen: screen.id)
        }
    }

    /// Waits out the way back in, then brings the island back out of the notch.
    ///
    /// The delay is the one number on this path that cannot be derived. `com.apple.screenIsUnlocked`
    /// is posted when the authentication succeeds, which is when loginwindow *starts* dissolving its
    /// shield — there is no notification for the end of that dissolve, and no window of ours to
    /// watch, because the shield is not in our space and our own occlusion state clears as soon as
    /// it turns translucent rather than when it goes. So this is a measured-by-eye constant and is
    /// the whole of the fix if the island arrives early or late; see `returnDelay`.
    ///
    /// **A wake is not necessarily a return.** On a Mac that asks for a password, the displays
    /// lighting up reveals the lock screen, not the desktop; the return is the unlock that follows,
    /// possibly minutes later. `ScreenLock.isLocked` is what separates the two, and getting it wrong
    /// costs the whole animation — the island would spring out of the notch under the shield, unseen,
    /// and be sitting there flatly by the time the user was actually let in.
    private func scheduleReturn() {
        guard isScreenAway else { return }
        guard !ScreenLock.isLocked else { return }

        pendingReturn?.cancel()
        // A one-shot `Task.sleep`, not a `Timer` and not a poll (§9): one exists for the length of
        // the unlock animation and none at any other time. Safe on the continuous clock in a way the
        // sleep-side ones are not, because this is only ever started on a machine that is awake —
        // see `SystemEventsSource`'s note on why a delay spanning a sleep is a trap.
        pendingReturn = Task { [weak self] in
            try? await Task.sleep(for: Self.returnDelay)
            guard !Task.isCancelled, let self else { return }
            self.pendingReturn = nil
            self.bringIslandsBack()
        }
    }

    /// Springs every island back out of the notch, and picks the hover back up with it.
    ///
    /// `playReentry` is the same spring the island returns from another space on — `Motion.nudge`,
    /// from `IslandScreenModel.reentryScale`'s third of full size — and it is deliberately the same
    /// one: both are the island coming back from behind something else with nothing about its state
    /// having changed, and two springs for one idea is how they end up subtly different.
    ///
    /// Hover is asked for rather than waited on. Going away clears it on both sides, and it has to:
    /// no `mouseExited` is coming once the shield owns the pointer's events. But a pointer that was
    /// in the notch when the Mac locked is still in the notch at the unlock, and `mouseEntered`
    /// fires on a crossing — so without asking, the island would ignore a pointer resting on it
    /// until the user moved out of the tracking rect and back in. The answer comes back through the
    /// ordinary `onHoverChanged` path, so the peek it produces is the same peek any other arrival
    /// gets. After the bounce, so the island is on screen to be peeked.
    private func bringIslandsBack() {
        guard let controller else { return }
        isScreenAway = false
        IslandLog.system.info("screen is back — islands returning")

        // By now the lock-screen padlock has opened and collapsed back into the notch
        // (`LockScreenController.unlockCollapseAt` + its spring lands inside `returnDelay`), so
        // this bounce comes out of an empty cutout — the same arrival the padlock made at the lock,
        // on the same token, so the whole lock is one curve played both ways.
        let reduceMotion = accessibility.reduceMotion
        for model in models.values {
            model.playReentry(reduceMotion: reduceMotion, animation: Motion.lockHandover)
        }
        for screen in controller.screens {
            controller.refreshHover(forScreen: screen.id)
        }
        openIslandsAfterReturn()
    }

    /// Opens the islands for a greeting that arrived while the screen was still somebody else's.
    ///
    /// This is the whole of §2.5's "the message should be *read*". The greeting is presented at the
    /// unlock, `returnDelay` before the island is on screen, so `updateAutoOpen` could only record
    /// the intention; the open belongs here, after the island has sprung out of the notch, and
    /// `autoOpenDelay` later so the return and the opening are two events rather than one blurred
    /// one.
    ///
    /// **The presented kind is asked again when the task fires, not remembered.** Four seconds of
    /// dwell is long enough for the greeting to have expired, been dismissed, or been preempted by
    /// something louder in the meantime — a volume key pressed on the way back in is `.interrupting`
    /// and takes the stage. Opening on a remembered answer would open the island onto whatever
    /// happened to be there instead — and an island Isleta opens by itself, onto the quiet menu the
    /// user did not ask for, is the app talking to itself.
    private func openIslandsAfterReturn() {
        guard pendingAutoOpen else { return }
        pendingAutoOpen = false

        autoOpenTask?.cancel()
        // A one-shot `Task.sleep`, like the return it follows: one exists for the length of one
        // greeting and none at any other time (§9). Started only on a machine that is already awake,
        // so the continuous clock cannot carry it across a sleep.
        autoOpenTask = Task { [weak self] in
            try? await Task.sleep(for: Self.autoOpenDelay)
            guard !Task.isCancelled, let self else { return }
            self.autoOpenTask = nil
            guard self.activities.presented?.kind.opensIsland == true else { return }
            self.openIslandsForActivity()
        }
    }

    // MARK: - Diagnostics

    /// How long the launch-time pass-through run will wait for the island to be composited before
    /// reporting whatever it sees.
    ///
    /// Forty looks at 50 ms — two seconds.
    ///
    /// **It was eight, and eight was measured on a warm launch.** The panel is composited inside the
    /// first look when the binary is already in the page cache, which is every launch during a
    /// working session and none of the launches that matter: the first run after an install, after
    /// an update, or after a restart reliably needed longer than 400 ms and reported four failed
    /// probes for it. That is the *first* thing a new user's log says about the app.
    ///
    /// The bound is generous because being late costs nothing here — nobody is waiting on this line
    /// — while being early costs a false failure in the file people attach to bug reports. It stays
    /// bounded so this can never become a loop.
    private static let launchSelfTestAttempts = 40
    private static let launchSelfTestInterval = Duration.milliseconds(50)

    /// How long `launchSelfTestAttempts` at `launchSelfTestInterval` actually waits, for the line
    /// that has to say so in milliseconds rather than in looks — "after 8 looks" tells a reader
    /// nothing they can act on.
    private static var launchSelfTestBudgetMilliseconds: Int {
        launchSelfTestAttempts * 50
    }

    /// The launch-time pass-through run, held so quitting cancels it.
    private var launchSelfTestTask: Task<Void, Never>?

    /// Runs the pass-through self-test once the island actually has pixels.
    ///
    /// **This was a standing false alarm, and it is worth saying what kind.** The test ran at first
    /// frame, when the window server has not composited the panel yet — so the five `inside-*`
    /// probes, which ask "is this pixel of the island ours", were correctly answered *no*, because
    /// nothing was there. Every launch from 2026-08-21 wrote
    /// `pass-through: 7 ok, 5 FAILED: …/inside-*` into `isleta.log`, and the same test a moment
    /// later reported 12/12. That is the file people are asked to attach to a bug report, and a red
    /// line in it that is always there is worse than no line at all — it trains the reader to scroll
    /// past the one that matters.
    ///
    /// The fix waits for the precondition rather than for an interval:
    /// `PassThroughSelfTest.hasComposited` asks the window server whether the island's own center is
    /// ours yet, which is true exactly when the pixels exist. Bounded, so a display that never
    /// composites gets a late and honest answer rather than a loop — and this is the launch path,
    /// not the idle one, so §9's no-timer rule is not in question.
    private func startLaunchPassThroughSelfTest() {
        guard controller != nil else {
            diagnostics.passThrough = "unavailable"
            return
        }
        diagnostics.passThrough = "waiting for the island's first composite"
        launchSelfTestTask?.cancel()
        launchSelfTestTask = Task { [weak self] in
            for attempt in 0..<Self.launchSelfTestAttempts {
                if attempt > 0 { try? await Task.sleep(for: Self.launchSelfTestInterval) }
                guard !Task.isCancelled, let self, let controller = self.controller else { return }
                guard PassThroughSelfTest.hasComposited(controller: controller) else { continue }
                let result = PassThroughSelfTest.run(controller: controller)
                self.diagnostics.passThrough = result
                self.launchSelfTestTask = nil
                IslandLog.app.info("pass-through: \(result)")
                return
            }
            guard !Task.isCancelled, let self else { return }
            // Out of attempts with nothing composited. Reported as **not run**, and the probe is not
            // run at all.
            //
            // It used to run anyway and report whatever came back, on the reasoning that an island
            // with no pixels is itself a fault worth surfacing. The reasoning was sound and the
            // output was not: every `inside-*` probe fails against an island that has not
            // composited, so the line read "4 FAILED" — the vocabulary this app uses for *clicks
            // landing in the wrong place* — to describe a question that could not be asked yet. A
            // reader cannot tell that from the real thing, which is the whole reason the real thing
            // is worth logging.
            //
            // "not run — <reason>" is the phrasing already used when the screen is locked, and it is
            // the honest shape: the test has one more outcome than pass and fail.
            self.diagnostics.passThrough = "not run — the island had not composited after "
                + "\(Self.launchSelfTestBudgetMilliseconds) ms"
            self.launchSelfTestTask = nil
            IslandLog.app.info("pass-through: \(self.diagnostics.passThrough ?? "—")")
        }
    }

    private func recordLaunch() {
        guard diagnostics.launchSeconds == nil else { return }
        diagnostics.launchSeconds = ProcessMetrics.timeSinceProcessStart()
        startLaunchPassThroughSelfTest()
        diagnostics.overlaySpace = controller.map {
            $0.isHostedInOverlaySpace
                ? "private SkyLight space — the island is in no desktop's picture"
                : "unavailable — falling back to hiding on occlusion"
        }
        IslandLog.app.info(
            "first frame at \(diagnostics.launchSeconds.map { String(format: "%.1f", $0 * 1000) } ?? "?") ms"
        )
        refreshDebugInfo()

        // `--debug-overlay` starts with the overlay up, for iterating on geometry. It has to wait
        // until here: toggling it inside `applicationDidFinishLaunching`, before the first frame is
        // committed, left the hosting view rendering nothing at all — island included.
        if ProcessInfo.processInfo.arguments.contains("--debug-overlay") {
            toggleDebugOverlay()
        }

        // `--settings [pane]` opens the settings window at launch, on a named pane, for iterating on
        // it without hunting for the status item and clicking through the sidebar. Same reason
        // `--debug-overlay` waits until here: before the first frame is committed, presenting a
        // window from an accessory app leaves it drawn but unfocused.
        if let pane = Self.settingsPaneArgument {
            settingsWindow.show(section: pane)
        }

        // Sources first, then the flow. The Accessibility page reads the notification source's
        // authorization, and a hub that does not exist yet reports nothing — the page would open
        // saying Isleta will ask later, on a machine where it could have offered the button.
        startSources()
        presentOnboardingIfNeeded()
        // After the first frame, for the same reason the sources are — see `SparkleUpdater.start()`.
        // `apply(_:)` has already pushed the user's `automaticUpdateChecks` into it by now, so the
        // first update cycle runs on their answer rather than on the Info.plist default.
        updater.start()
        openIdleWindow()

        // `--export-logs <path>` writes the "Export Logs…" bundle there without the save panel and
        // exits — the only way to check the file a user would send without a hand on the mouse.
        // A second later, so the sources' first lines are in it.
        if let path = Self.exportLogsArgument {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                MainActor.assumeIsolated {
                    self?.runLogExport(to: URL(fileURLWithPath: path))
                    if PerformanceProbe.reportModeDuration() == nil { NSApp.terminate(nil) }
                }
            }
        }
    }

    /// Puts the first-run flow up, on the launches that want it.
    ///
    /// After the first frame, alongside the sources and the updater, for the reason `--settings`
    /// waits here too: presenting a window from an accessory app before the frame is committed
    /// leaves it drawn and unfocused. It costs nothing on the launches that skip it — the controller
    /// is `lazy`, so a Mac that has been onboarded never builds the window at all, and §9's launch
    /// budget is measured to the frame this runs after.
    ///
    /// **Nothing on this path prompts.** The window renders each permission's *state* and a
    /// button; only the button asks.
    ///
    /// **This claim lost its runtime check when notifications went.** `SourceHub` carried a
    /// `didPromptDuringLaunch` flag, and it worked because the Accessibility prompt wrote a ledger
    /// before it asked — so a prompt reached from the launch path would flip a bit that
    /// `--perf-report` printed. No remaining permission keeps such a ledger, so the flag could only
    /// ever have answered "no", which is the failure this codebase calls measuring the return value
    /// instead of the effect. It was removed rather than left saying nothing. §10 is now structural
    /// here — see `SourceHub`'s own note — and a replacement check needs a ledger of its own.
    ///
    /// `--onboarding` forces it for iterating on the flow, and `--onboarding-reset` puts the ledger
    /// back to never-onboarded so the real first-launch path can be walked again — the flow is
    /// otherwise a thing you get one look at per machine.
    private func presentOnboardingIfNeeded() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--onboarding-reset") {
            OnboardingLedger().reset()
        }
        guard let index = arguments.firstIndex(of: "--onboarding") else {
            guard onboardingWindow.shouldPresentAtLaunch else { return }
            IslandLog.app.info("presenting the first-run flow")
            onboardingWindow.show()
            return
        }
        // `--onboarding [page]`, exactly as `--settings [pane]` works, down to the guard: a
        // following argument that is another flag is not a page name, so `--onboarding --no-sources`
        // opens on Welcome rather than looking up a page called "--no-sources", finding nothing and
        // quietly opening on Welcome anyway — the right window with the wrong explanation for it.
        let next = arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
        let page = next.flatMap { $0.hasPrefix("--") ? nil : OnboardingStep(name: $0) } ?? .welcome
        IslandLog.app.info("presenting the first-run flow")
        onboardingWindow.show(step: page)
    }

    @objc private func openOnboarding() {
        onboardingWindow.show()
    }

    private static var exportLogsArgument: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--export-logs"),
              arguments.indices.contains(index + 1), !arguments[index + 1].hasPrefix("--")
        else { return nil }
        return arguments[index + 1]
    }

    /// Start the §9 idle measurement, once the startup above has stopped costing anything.
    ///
    /// Everything in `recordLaunch` up to this line is one-off work — the pass-through self-test,
    /// six sources starting, Sparkle's first check — and none of it is what "idle CPU" is asking
    /// about. The baseline is taken after `PerformanceProbe.settleSeconds` so the sample covers an
    /// app that has finished starting; see that constant for what the old placement measured.
    ///
    /// `--perf-report`'s window is scheduled from here rather than from
    /// `applicationDidFinishLaunching` for the same reason. Scheduled there it began before the
    /// baseline existed, so the report fired early and the app spent part of its window still
    /// starting up — the requested duration and the measured one were never the same interval.
    ///
    /// The one-shot delay is not a §9 violation: it fires once at launch and leaves nothing behind.
    /// `PerformanceProbe`'s only repeating timer still lives under `--perf-report`.
    private func openIdleWindow() {
        DispatchQueue.main.asyncAfter(deadline: .now() + PerformanceProbe.settleSeconds) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.performance.markBaseline()
                guard let seconds = PerformanceProbe.reportModeDuration(),
                      let controller = self.controller else { return }
                self.scheduleReport(after: seconds, controller: controller)
            }
        }
    }

    /// Builds the six sources and starts the ones the user has switched on.
    ///
    /// **After the first frame, not during `applicationDidFinishLaunching`.** §9's 300 ms cold-launch
    /// budget is build-failing and is measured to the frame the island appears on; starting sources
    /// before that puts CoreAudio's first HAL call, an accessibility attach and an `osascript` fork
    /// inside it, none of which the user is waiting for. There is nothing for a source to publish
    /// onto before an island exists — `IslandScreenModel` has not been built yet — so the ordering
    /// costs nothing and removes three machine-dependent variables from a threshold that fails the
    /// build.
    ///
    /// `--no-sources` runs the app with none of them, which is how the §9 delta for "with four
    /// sources running" is measured: the same `--perf-report` window, twice, with one flag between
    /// them. Without it the only comparison available is against a number from a previous milestone
    /// measured on a differently loaded machine.
    private func startSources() {
        guard sources == nil else { return }
        // **Unconditional, and before any setting is read.** If a previous run was force-quit or
        // crashed while holding `OSDUIHelper` frozen, this is what gives the user their volume HUD
        // back — so it must not be gated on suppression still being switched on. Somebody who
        // crashed and *then* turned the feature off needs the repair most of all.
        //
        // A `SIGCONT` to a process that was never stopped is a no-op, so this costs one `proc_listpids`
        // scan on a path that already reads the shelf back off disk.
        SystemOSDSuppressor.repairAtLaunch()
        // Before the `--no-sources` guard, so the demo is available with the sources off — which is
        // the combination that makes it a *check* rather than a race: nothing else can take the
        // stage from it a moment later.
        presentActivityDemoIfRequested()
        presentDeviceDemoIfRequested()
        presentHUDDemoIfRequested()
        presentPowerDemoIfRequested()
        presentGlanceDemoIfRequested()
        // Reads last session's shelf back and splices QuickLook into the responder chain. Here
        // rather than at the first frame because it resolves a bookmark per held file, and the
        // launch budget (§9: 300 ms to visible) is spent before this runs — the same reasoning that
        // put the sources here. Before the demo below, so `--shelf-demo` lands on top of a real
        // shelf rather than racing it.
        shelf.start()
        // Before anything can record into it, and it costs one JSON decode: nothing is resolved
        // until a row is clicked, unlike the shelf, which resolves every bookmark at launch because
        // its claim is that what it shows is *there*. This list's claim is only that the act
        // happened, which stays true whatever the disk says.
        dropHistory.restore()
        // The three moments a drop action finishes. A closure rather than a reference, so a build
        // with no history is a build where this is nil and `ShelfActionController` knows nothing
        // about it.
        // Copy link. The provider decides both halves — whether the row is offered at all, and what
        // to do instead when it is not — so nothing here has to make that judgement twice. See
        // `ShareLinkAffordance`, and `docs/PLATFORM-CONSTRAINTS.md` for why this works when the
        // note it replaced said it could not.
        shelf.canCopyLink = { [weak self] url in
            guard let self else { return false }
            if case .copyLink = self.shareLink.affordance(for: url) { return true }
            return false
        }
        shelf.copyLink = { [weak self] url in
            guard let self else { return }
            self.shareLink.copyLink(for: url) { outcome in
                // Counts and enum values. A share URL identifies the user's document, and this log
                // is emailed to strangers.
                switch outcome {
                case .copied(let link):
                    IslandLog.shelf.info("share link copied")
                    self.dropHistory.recordLink(link.absoluteString, for: [url])
                case .notEligible(let reason):
                    IslandLog.shelf.info("share link not eligible — \(reason)")
                case .refused(let domain, let code):
                    IslandLog.shelf.warning("share link refused — \(domain) \(code)")
                default:
                    IslandLog.shelf.warning("share link produced nothing")
                }
            }
        }
        shelf.onDidWork = { [weak self] action, sources, produced, failure in
            self?.dropHistory.record(action, sources: sources, produced: produced, failure: failure)
        }
        dropHistory.onRunAgain = { [weak self] action, urls in
            self?.shelf.runAgain(action, on: urls)
        }
        #if DEBUG
        dropHistory.presentDemoIfRequested()
        #endif

        // The conversion worker's own sweep, and it runs whether or not the sources do: a worker
        // stranded by a crash is holding hundreds of megabytes, which is worth collecting even on a
        // `--no-sources` run. Off the main thread for the reason the adapter's is — it sleeps a
        // second between SIGTERM and the escalation, against a 300 ms launch budget — and it
        // signals only processes running *this* executable **with the worker flag**, which is the
        // condition that stops it quitting the user's other copy of Isleta. See `FileActionOrphans`.
        DispatchQueue.global(qos: .utility).async {
            let reaped = FileActionOrphans.sweep()
            guard !reaped.isEmpty else { return }
            IslandLog.shelf.warning("cleared \(reaped.count) stranded file worker(s) left by an earlier run")
        }

        presentShelfDemoIfRequested()
        presentConvertDemoIfRequested()
        guard !ProcessInfo.processInfo.arguments.contains("--no-sources") else {
            IslandLog.sources.info("not started — --no-sources")
            return
        }

        // Before the hub, so a previous run's stranded helper is on its way out before this one
        // spawns its replacement — otherwise a crash-loop leaves two `perl` processes reading the
        // same player until the sweep on the *next* launch happens to catch up.
        //
        // Off the main thread and unwaited: it sleeps a second between SIGTERM and the escalation,
        // and §9 budgets cold launch to visible at 300ms. Nothing here depends on the result, so
        // there is nothing to come back for. The sweep only ever signals processes running *this
        // bundle's own* adapter script whose parent is launchd — see `NowPlayingAdapterOrphans` for
        // why each half of that sentence is load-bearing.
        let location = NowPlayingAdapterLocation.inBundle(.main)
        DispatchQueue.global(qos: .utility).async {
            let reaped = NowPlayingAdapterOrphans.sweep(location: location)
            guard !reaped.isEmpty else { return }
            IslandLog.nowPlaying.warning("cleared \(reaped.count) stranded helper(s) left by an earlier run")
        }
        let hub = SourceHub(coordinator: activities)
        sources = hub

        // **The rebound the user pushes out of a level that is already at its end.** Not an
        // activity and not routed through the coordinator — nothing on the stack changes, because
        // nothing about the level changed. See `SourceHub.onLimitPushed`.
        //
        // Wired here rather than in `SourceHub` because the models live on this side: the hub knows
        // sources, this knows islands.
        hub.onLimitPushed = { [weak self] limit in
            guard let self else { return }
            for model in self.models.values {
                model.bounce(toward: limit, reduceMotion: self.accessibility.reduceMotion)
            }
        }

        // The glance's **only** channel, and the reason `CalendarSource` has one at all: a day's
        // worth of events with join links in them is not sayable in `ActivityContent`'s vocabulary
        // of symbols and strings. It was the second of two — a standing ambient activity carried
        // the day to the stack alongside it — and that activity is withdrawn (see
        // `ActivityKind.glance`), so this is what the open island draws and nothing else.
        //
        // Wired before `apply` starts the sources, for the reason the Now Playing bridge is: the
        // first thing `CalendarSource.start()` does is publish, and a listener attached afterwards
        // would miss the day until the user next edited a calendar.
        hub.calendar.onSnapshot = { [weak self] snapshot in
            guard let self else { return }
            self.glance.snapshot = snapshot
            // **The home page's height follows the day, so a new day is a resize.** The stack does
            // not change when the calendar answers — the day never reaches it — so
            // `activityChanged` never runs and nothing else would restate the height. Granting
            // calendar access for the first time therefore drew three events into an island still
            // sized for none, and it stayed that way until a page turn happened to recompute it.
            // Reported from use, with the events overflowing the island's foot.
            //
            // Cheap on every other snapshot: `restateExpandedContentHeight` returns at its own guard
            // unless the number actually moved, so an unchanged day costs one comparison.
            self.restateExpandedContentHeight()
        }
        hub.calendar.onJoinableMeeting = { [weak self] event in
            self?.glance.joinableMeeting = event
        }
        hub.weather.onReading = { [weak self] reading in
            guard let self else { return }
            self.glance.temperatureUnit = self.sources?.weather.temperatureUnit ?? .fromLocale()
            // Folded into the calendar source rather than into the model directly, so the snapshot
            // the island draws and the activity on the stack come from one publisher and one
            // height. See `WeatherSource` for why weather is not an `ActivitySource`.
            self.sources?.calendar.setWeather(reading)
        }
        // **The only place a meeting URL is ever handed to the system, and it is never logged.**
        // Opening it closes the island, for the same reason opening the player app does: the island
        // would otherwise sit over the window it had just brought forward.
        glance.onJoin = { [weak self] link in
            NSWorkspace.shared.open(link.url)
            IslandLog.calendar.info("joined a meeting — provider \(link.provider.rawValue)")
            self?.collapseAll()
        }
        // Nil unless a prompt would actually show. §10: after a refusal macOS will not raise the
        // dialog again, so a button there would be a control that visibly does nothing — the empty
        // glance draws only the sentence instead.
        // The schedule surface: open and close, and nothing else. It was four closures while the
        // surface was a month grid — open, close, step, choose — and the two that went are the two
        // the grid needed. There is no month to step and no day to pick: the surface is today and
        // tomorrow, which are decided by the clock rather than by the user.
        glance.onOpenSchedule = { [weak self] in self?.toggleGlanceSchedule(true) }
        glance.onCloseSchedule = { [weak self] in self?.toggleGlanceSchedule(false) }

        // The weather page. Two closures rather than four: there is nothing to step and nothing to
        // choose — the surface is one reading drawn two ways, and everything on it arrived with the
        // temperature the chip is already showing.
        // The weather is a page now, so its chip is a page change — and there is nothing to close
        // it with, because a page is left by turning to another one. See `GlanceModel.onOpenWeather`.
        glance.onOpenWeather = { [weak self] in self?.goToPage(.weather) }

        glance.onRequestCalendarAccess = { [weak self] in
            guard self?.sources?.calendar.authorization == .undetermined else { return }
            self?.sources?.calendar.requestAccessFromUserInitiatedMoment()
        }
        // The other half, for after a refusal: macOS raises the permission dialog exactly once, so
        // the pane is the only thing left that changes anything. The URL is `GlancePrivacySettings`'
        // rather than a literal here, for the reason that type states — a deep link invented at the
        // call site is a string nobody re-checks when Apple renames a pane.
        glance.onOpenCalendarSettings = {
            guard let url = URL(string: GlancePrivacySettings.calendarsURLString) else { return }
            NSWorkspace.shared.open(url)
        }
        // A click on an event opens it in Calendar. The island stays where it is: this is the same
        // shape as the Join button, which has never closed it — the user asked for the event to be
        // *somewhere else*, not for the surface they asked from to be taken away.
        //
        // Falls back to Calendar itself rather than to nothing, for the reason `GlanceEventLink`
        // states: the link is an undocumented scheme, and the honest failure is the app open on
        // today rather than a click that does nothing at all.
        glance.onOpenEvent = { event in
            // **Which of the two ran is the only thing worth logging, and it is the thing that
            // tells the two failures apart.** "Calendar opened but not on the event" has two causes
            // that look identical from outside: EventKit handed us no identifier for the event, so
            // there was never a link to follow; or there was one and Calendar made nothing of it.
            // Nothing about the event itself goes in the line — an event identifier is a serial
            // number for something the user wrote, and this file is emailed to strangers.
            guard let string = GlanceEventLink.urlString(for: event) else {
                IslandLog.calendar.info("event has no identifier — opening Calendar itself")
                if let url = URL(string: GlanceEventLink.bareCalendar) {
                    NSWorkspace.shared.open(url)
                }
                return
            }
            guard let url = URL(string: string) else {
                IslandLog.calendar.info("event link would not parse as a URL — opening Calendar itself")
                if let url = URL(string: GlanceEventLink.bareCalendar) {
                    NSWorkspace.shared.open(url)
                }
                return
            }
            IslandLog.calendar.info("opening an event in Calendar by its identifier")
            NSWorkspace.shared.open(url)
        }
        // The user's record is applied on every change, from the same path as the launch apply —
        // a separate "at launch" branch is how the two drift until one is missing a field. It rides
        // `SettingsStore` like every other setting since schema 8; it had its own record and its own
        // change handler for one release, which is what kept "Reset to Defaults" from reaching it.
        settings.addChangeHandler { [weak self] configuration in
            self?.applyGlanceSettings(configuration.glance)
        }
        // The Mac's own region setting, not Isleta's — see `SourceHub.apply(glance:)`.
        glance.temperatureUnit = .fromLocale()

        // Before `apply`, because `apply` starts the sources and the very first thing the adapter
        // reports is the track that was already playing. A bridge built afterwards would miss that
        // snapshot, and with it the play/pause glyph and the transport row, until the user next
        // touched their music.
        let bridge = NowPlayingBridge(
            source: hub.nowPlaying,
            reduceMotion: { [weak self] in self?.accessibility.reduceMotion ?? false }
        )
        bridge.onOpenedPlayer = { [weak self] in self?.collapseAll() }
        bridge.onToggleQueue = { [weak self] in self?.toggleNowPlayingQueue() }
        bridge.onQueueChanged = { [weak self] rows in self?.applyNowPlayingQueue(rows) }
        bridge.onPlayingChanged = { [weak self] isPlaying in
            self?.playingChanged(isPlaying)
        }
        // Started here rather than inside `SourceHub.apply`, because the output device list is not
        // a *source* in that sense: it is a fact about the machine, it needs no permission and no
        // helper, and it stays true when Now Playing is switched off. It is also the one thing on
        // this surface that is still worth drawing on a build where the adapter never loaded.
        bridge.startOutputRouting()
        nowPlaying = bridge

        // The lock-screen card. After the bridge because it draws from that bridge's controller,
        // and before anything reaches the stage, so the first activity arrives through
        // `activityChanged` like every other one. It builds no window and creates no SkyLight space until the screen is
        // actually locked, and none at all while the setting is off — which is the default.
        let lockScreen = LockScreenController()
        lockScreen.attach(nowPlaying: bridge.controller)
        // The stack, so a lock re-asks what is playing rather than trusting the last push — which
        // on a Mac that woke straight to a lock screen never happened. See
        // `LockScreenController.activities`.
        lockScreen.attach(activities: activities)
        lockScreen.start()
        lockScreen.apply(isEnabled: settings.configuration.showsNowPlayingOnLockScreen)
        // The sounds follow the card since schema 18 — see
        // `IsletaConfiguration.showsNowPlayingOnLockScreen`, which is where the fold is argued.
        lockScreen.apply(playsSounds: settings.configuration.showsNowPlayingOnLockScreen)
        self.lockScreen = lockScreen
        // After `apply(isEnabled:)`, which the demo overrides: a run with the setting off would
        // otherwise turn the surfaces on and then immediately tear them down.
        lockScreen.presentDemoIfRequested()
        for model in models.values { model.nowPlaying = bridge.controller }
        // `--nowplaying-demo` puts a synthetic *playing* track on the stage so the equaliser runs for
        // the whole of a `--perf-report` window.
        //
        // It exists because the §9 number that matters for this milestone cannot otherwise be
        // measured deliberately: the bars run only while music is playing, so a measurement taken on
        // a silent machine reports the old idle profile and one taken with Music open depends on
        // whatever the user happened to be listening to and how long it was. The synthetic track is
        // an hour long, so the position never reaches its end and the bars never clamp.
        //
        // **The real Now Playing source is stopped for the duration, and that is not tidiness.**
        // Every Now Playing activity shares one `ActivityID` — `ActivityKind.nowPlaying.singletonID`
        // — because a track change is an update of one logical activity rather than a new one. So
        // the first thing the live adapter reports *replaces* the synthetic track, and on a machine
        // where the last thing touched was paused (the normal case) the replacement has rate zero,
        // the clock stops and the run measures the idle path while appearing to measure the
        // animating one. Measured before this line existed: 0.1596 %, indistinguishable from the
        // baseline, for exactly that reason.
        //
        // The alternative — starting the user's music from the perf harness — was rejected outright.
        // A measurement tool must not press play on somebody's speakers.
        let isDemo = ProcessInfo.processInfo.arguments.contains("--nowplaying-demo")
        // Read behind the same `#if` the demo itself is behind, so a release build cannot be talked
        // into switching the user's Now Playing source off with a flag whose effect was compiled
        // out — the failure that would produce is "music stopped appearing", with nothing on screen
        // to connect it to what was typed.
        #if DEBUG
        let isUpNextDemo = ProcessInfo.processInfo.arguments.contains("--upnext-demo")
        let isQueueDemo = ProcessInfo.processInfo.arguments.contains("--queue-demo")
        #else
        let isUpNextDemo = false
        let isQueueDemo = false
        #endif
        var configuration = settings.configuration
        if isDemo || isUpNextDemo || isQueueDemo { configuration.sources.nowPlaying = false }
        hub.apply(configuration)
        applyGlanceSettings(settings.configuration.glance)
        if isDemo {
            activities.present(TransportSelfTest.demoActivity(durationSeconds: 3600))
            // The transport row is part of what the demo exists to put on screen: it animates with
            // everything else, and with no live source nothing would otherwise tell the controller
            // there is a player to talk to, so the row would be absent from both the measurement and
            // the screenshot. Stated here rather than faked in the controller — this is the one
            // caller that knows it is a demo.
            bridge.controller.apply(
                isPlaying: true,
                canSkip: true,
                isTransportAvailable: true,
                playerBundleIdentifier: Bundle.main.bundleIdentifier,
                reduceMotion: accessibility.reduceMotion
            )
        }
        // Behind the same `#if` as the flag it reads, and not only for symmetry: in a release build
        // `isUpNextDemo` is a `let … = false`, so the compiler proves this branch dead and
        // `SWIFT_TREAT_WARNINGS_AS_ERRORS` turns "will never be executed" into a build failure.
        // `Tools/check.sh` builds Debug, so nothing catches that until a release is cut.
        #if DEBUG
        if isUpNextDemo { presentUpNextDemo(bridge: bridge) }
        // Behind the same `#if` as the flag it reads, for the reason above and not for symmetry: in
        // a release build `isQueueDemo` is a `let … = false`, the compiler proves this branch dead,
        // and `SWIFT_TREAT_WARNINGS_AS_ERRORS` turns "will never be executed" into a build failure
        // — which `Tools/check.sh` cannot see, because it builds Debug.
        if isQueueDemo { presentQueueDemo(bridge: bridge) }
        #endif

        refreshDebugInfo()
    }

    /// `--upnext-demo`: a track a few seconds from its end with a queue behind it, so the Up Next
    /// sneak peek can be looked at without sitting through a song.
    ///
    /// Worth its own flag for the reason the other four have theirs, and more so than any of them:
    /// this is the only thing the island draws that is **triggered by the clock rather than by an
    /// event**, so there is no way to make it happen. Waiting for a real one means waiting for a
    /// real track to reach `NowPlayingUpNextPeek.leadTime` seconds from its end and having the
    /// island open at that moment — which is a check nobody performs twice, and therefore a feature
    /// that would be looked at once and never again.
    ///
    /// The synthetic track starts **four seconds outside** the window rather than inside it, so
    /// what is on screen is the *transition* — the artist line crossing over to the peek on
    /// `Motion.contentSwap`. Starting inside it would show the finished state, which is the half
    /// that was never in doubt.
    ///
    /// The live Now Playing source is switched off for the run, exactly as `--nowplaying-demo`
    /// switches it off and for the same reason: every Now Playing activity shares one `ActivityID`,
    /// so the first thing a real adapter reports would replace the synthetic track — and on a
    /// machine where the last thing touched was paused, replace it with one whose rate is zero,
    /// where the peek is correctly never due.
    ///
    /// Debug only, like the other four. It claims a next track that does not exist.
    private func presentUpNextDemo(bridge: NowPlayingBridge) {
        #if DEBUG
        let duration: TimeInterval = 214
        let lead = NowPlayingUpNextPeek.leadTime + 4
        activities.present(
            BuiltInActivity.nowPlaying(
                title: "Up Next Self-Test",
                artist: "Isleta",
                album: "Milestone 27",
                isPlaying: true,
                timeline: ActivityTimeline(
                    elapsed: duration - lead,
                    duration: duration,
                    anchor: Date(),
                    rate: 1
                )
            )
        )
        // Nothing tells the controller there is a player with no live source, and the peek shares
        // its row with the artist the transport row is drawn beneath — so both have to be stated
        // here or the demo shows the line arriving into an island missing everything around it.
        bridge.controller.apply(
            isPlaying: true,
            canSkip: true,
            isTransportAvailable: true,
            playerBundleIdentifier: Bundle.main.bundleIdentifier,
            reduceMotion: accessibility.reduceMotion
        )
        bridge.controller.setUpNext(title: "The Next One", artist: "Isleta")

        // Opened twice, and the second one is the one that matters.
        //
        // The first is at 0.4 s, for the reason `--recents-demo` waits: the panels have to exist
        // before there is an island to open. The second is a second and a half *after* the peek
        // becomes due, because the demo runs with every other source live — a real notification
        // arriving in those four seconds outranks an ambient track, takes the stage and closes the
        // island behind it, which is the island behaving exactly as designed and is also the only
        // thing that ever happened on the first run of this. Reopening costs nothing when nothing
        // preempted it; `openIslandsForActivity` on an island that is already open is a no-op.
        for delay in [0.4, lead - NowPlayingUpNextPeek.leadTime + 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    self?.openIslandsForActivity()
                }
            }
        }
        #endif
    }

    /// `--queue-demo`: a track with a long queue behind it, the surface already open, so the Up
    /// Next list can be scrolled and looked at without twenty songs in Music.
    ///
    /// It earns a flag for the reason the other five have theirs, and one more: what this surface
    /// exists to get right is the *scroll*, and a scroll needs more rows than fit — which on a real
    /// machine means a queue the developer has to build by hand before every look, and then rebuild
    /// after the first double-click reorders it.
    ///
    /// **Twenty-four rows, against a viewport of four.** More than a page, so the paging arithmetic
    /// is exercised rather than merely present, and more than the opening window of fifteen, so a
    /// reader who scrolls to the bottom finds the list is genuinely windowed.
    ///
    /// The live Now Playing source is switched off for the run, exactly as `--nowplaying-demo` and
    /// `--upnext-demo` switch it off and for the same reason: every Now Playing activity shares one
    /// `ActivityID`, so the first thing a real adapter reports would replace the synthetic track —
    /// and with it the synthetic queue, which is the entire demo.
    ///
    /// Debug only, like the other five. The rows name songs that do not exist and the double-click
    /// on them can reach no player.
    private func presentQueueDemo(bridge: NowPlayingBridge) {
        #if DEBUG
        let duration: TimeInterval = 214
        activities.present(
            BuiltInActivity.nowPlaying(
                title: "Queue Self-Test",
                artist: "Isleta",
                album: "Stage 8",
                isPlaying: true,
                timeline: ActivityTimeline(
                    elapsed: 42,
                    duration: duration,
                    anchor: Date(),
                    rate: 1
                )
            )
        )
        // Nothing tells the controller there is a player with no live source, so everything the
        // surface is drawn against has to be stated here — including `canReadQueue`, without which
        // the Up Next button in the transport row is correctly absent and the demo shows a surface
        // with no way to reach it.
        bridge.controller.apply(
            isPlaying: true,
            canSkip: true,
            isTransportAvailable: true,
            playerBundleIdentifier: Bundle.main.bundleIdentifier,
            canFavorite: true,
            isFavorite: false,
            reduceMotion: accessibility.reduceMotion
        )
        bridge.controller.canReadQueue = true
        // Index 0 is the track that is playing, which is the whole rule this list is drawn by — so
        // the demo's row 0 is the same title as the activity above, and the ones after it are the
        // ones the eye should read as "next".
        let titles = [
            "Queue Self-Test", "Second Verse", "Interlude", "The Long One", "Bridge",
            "Reprise", "B-Side", "Outro", "Hidden Track", "Encore",
            "Soundcheck", "Rehearsal", "Demo Take", "Alternate Mix", "Radio Edit",
            "Extended Cut", "Instrumental", "Live at the Notch", "Acoustic", "Remix",
            "Coda", "Afterthought", "One More", "The Last One",
        ]
        bridge.controller.setQueue(
            titles.enumerated().map { index, title in
                NowPlayingQueueRow(
                    index: index,
                    title: title,
                    artist: "Isleta",
                    duration: 150 + Double(index) * 7,
                    contentItemIdentifier: "demo-\(index)"
                )
            }
        )
        bridge.controller.setUpNext(title: titles[1], artist: "Isleta")

        // Opened at 0.4 s for the reason `--recents-demo` waits — the panels have to exist before
        // there is an island to open — and the surface is toggled a beat after that, so what is on
        // screen is the *transition* into it rather than an island that was always this shape.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                self?.openIslandsForActivity()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
            MainActor.assumeIsolated {
                self?.toggleNowPlayingQueue()
            }
        }
        #endif
    }

    /// `--activity-demo`: a notification and a greeting, so the two content-sized shapes can be
    /// looked at without waiting for a real one.
    ///
    /// The open island's height follows its content, and the only way to check that is to see it —
    /// a notification with a real paragraph in it, and a greeting with one line. Waiting for the
    /// system to produce either is not a check: the greeting needs a wake, and a notification needs
    /// an app to send one, Accessibility granted, and no Focus on. This is what `ClickSelfTest`
    /// already tells people to run.
    ///
    /// Debug only, like the overlay and the hot keys. It presents activities the user did not
    /// receive, which is not something a shipping build should be able to do at all.
    private func presentActivityDemoIfRequested() {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--activity-demo") else { return }
        activities.present(
            BuiltInActivity(
                kind: .calendarAlert,
                presentations: ActivityPresentations(
                    leading: ActivityContent(symbol: "calendar.badge.clock"),
                    compact: ActivityContent(
                        symbol: "calendar.badge.clock",
                        title: "Quarterly review"
                    ),
                    expanded: ActivityContent(
                        symbol: "calendar.badge.clock",
                        title: "Quarterly review",
                        subtitle: "Starts in 5 minutes — Europe line worth calling out"
                    )
                )
            )
        )
        // The greeting after it, and *scheduled* rather than queued behind it. `ActivityExpiry`
        // runs from the moment an activity is handed to the coordinator rather than from the moment
        // it reaches the stage, so a greeting presented now would expire in its four seconds while
        // still waiting behind a notification that has five — it would never be seen at all. Six
        // seconds puts it on an empty stage, which is also the only way to see the island resize
        // between two content-sized shapes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            MainActor.assumeIsolated {
                _ = self?.activities.present(
                    BuiltInActivity.welcomeBack(greeting: "Welcome back", subtitle: "Good afternoon, Tim")
                )
            }
        }
        #endif
    }

    /// `--device-demo`: a device connecting, so the flanked island can be looked at without
    /// putting AirPods in and out of their case.
    ///
    /// Worth its own flag rather than folding into `--activity-demo` for the reason that one exists:
    /// this is the only kind whose whole content is a picture and an arc, and the two are drawn in
    /// the 40pt slivers, where nothing else this app draws has to fit. The battery is stepped down
    /// across three presentations so the ring's green-to-amber threshold is visible in one run —
    /// waiting for real AirPods to reach 15% is not a check anybody performs.
    ///
    /// Debug only, like the overlay and the hot keys: it announces a device that did not connect.
    private func presentDeviceDemoIfRequested() {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--device-demo") else { return }
        let steps: [(BluetoothDeviceKind, String, Int)] = [
            (.airPodsPro, "AirPods Pro", 100),
            (.airPods, "Tim's AirPods", 64),
            // Below `DeviceConnectSlotView.lowBatteryThreshold`, so the ring turns amber.
            (.beats, "Powerbeats Pro", 12),
        ]
        for (index, step) in steps.enumerated() {
            // Spaced past `ActivityKind.deviceConnected.defaultExpiry`, so each lands on an empty
            // stage rather than queueing behind one that has not retired — the same reason
            // `--activity-demo` schedules its greeting instead of presenting it.
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 6) { [weak self] in
                MainActor.assumeIsolated {
                    _ = self?.activities.present(BuiltInActivity.deviceConnected(
                        BluetoothDeviceConnection(
                            // A different address per step, so they are three announcements rather
                            // than one activity updated twice.
                            name: step.1, address: "de-mo-00-00-00-0\(index)", kind: step.0,
                            battery: BluetoothDeviceBattery(left: step.2, right: step.2, single: 0)
                        )
                    ))
                }
            }
        }
        #endif
    }

    /// `--hud-demo`: the three system HUDs in turn, without touching the volume or the brightness of
    /// the machine this is being looked at on.
    ///
    /// Worth its own flag for `--device-demo`'s reason, in a new place: this is one of the two kinds
    /// that draw a **word** in a sliver, and it is what `IslandFlanks.wide` exists for. The other is
    /// power, which reaches one span further — `--power-demo`.
    ///
    /// The three steps are the three labels, and their widths are what settles whether
    /// `IslandLayout.wideFlankedWidthGrowth` is right — `WideFlankLayoutTests` measures the
    /// arithmetic, and no test can say whether the result reads well in a notch from a meter away.
    ///
    /// Levels chosen so the bar is plainly a bar: a third, silent, and near the top.
    ///
    /// Debug only, like the other demos: it reports levels the user did not change.
    private func presentHUDDemoIfRequested() {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--hud-demo") else { return }
        // **Timed, not evenly spaced**, and the timings are the point. The first three land on an
        // empty stage, four seconds apart, so each is watched *arriving* — that is what shows the
        // wide island, the label and the volume glyph's three variable-value states.
        //
        // The rebound needs the opposite: an island that is **already up**. A limit reached on an
        // arriving island is 8pt of edge inside a 108pt-per-side expansion, which is no more visible
        // than it sounds — so each pair below walks the level to just short of its end and lands on
        // it 700ms later, inside the HUD's own dwell, where the only thing moving is the edge.
        let arrivals: [(TimeInterval, SystemHUD, Double, ActivityLimit?)] = [
            (0, .volume, 0.2, nil),
            (4, .mute, 0, nil),
            (8, .brightness, 0.8, nil),
            // To the top: up to 0.9, then the last notch.
            (12, .volume, 0.9, nil),
            (12.7, .volume, 1, .maximum),
            // And to the bottom.
            (17, .volume, 0.1, nil),
            (17.7, .volume, 0, .minimum),
        ]
        for step in arrivals {
            DispatchQueue.main.asyncAfter(deadline: .now() + step.0) { [weak self] in
                MainActor.assumeIsolated {
                    _ = self?.activities.present(
                        BuiltInActivity.systemHUD(step.1, level: step.2, limit: step.3)
                    )
                }
            }
        }

        // **The repeats**, which no activity can carry: pushing a level that is already at its end
        // produces no reading at all, so they arrive as events. This is the same call
        // `SourceHub.onLimitPushed` makes, driven here at roughly the rate macOS repeats a held key,
        // so the flutter can be seen without holding a key against a real volume.
        let pushes: [(TimeInterval, ActivityLimit)] = [
            (13.2, .maximum), (13.5, .maximum), (13.8, .maximum), (14.1, .maximum),
            (18.2, .minimum), (18.5, .minimum), (18.8, .minimum), (19.1, .minimum),
        ]
        for push in pushes {
            DispatchQueue.main.asyncAfter(deadline: .now() + push.0) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // The HUD is re-presented too, exactly as the source does it, so its dwell
                    // restarts and the island is still there to rebound.
                    _ = self.activities.present(BuiltInActivity.systemHUD(
                        .volume,
                        level: push.1 == .maximum ? 1 : 0,
                        limit: push.1
                    ))
                    for model in self.models.values {
                        model.bounce(toward: push.1, reduceMotion: self.accessibility.reduceMotion)
                    }
                }
            }
        }
        #endif
    }

    /// `--power-demo`: the charger, a battery running down, and Low Power Mode, without unplugging
    /// anything or waiting for a laptop to reach 5 %.
    ///
    /// Worth its own flag for the reason `--device-demo` has one: the only way to see the low
    /// thresholds is to actually cross them, and getting a real battery from 100 % to 5 % takes most
    /// of a working day — during which nothing else about the feature can be checked. The steps below
    /// are every `PowerAnnouncement` case, in the order a laptop produces them, so one run shows
    /// every glyph, every tint and the two content-sized shapes this kind draws.
    ///
    /// **Seven steps for five cases, since 2026-09-01**: the two the list used to skip are the two
    /// halves of Low Power Mode turning off and a battery reaching full, and each of those is now a
    /// *word* in the sliver — `power.flank.lowPowerModeOff` and `power.flank.charged`. A label that
    /// no demo shows is a label whose width nobody has looked at, which is what
    /// `IslandLayout.widerFlankedWidthGrowth` is sized against.
    ///
    /// Debug only, like the other demos: it announces power events that did not happen.
    private func presentPowerDemoIfRequested() {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--power-demo") else { return }
        let steps: [(PowerAnnouncement, PowerState)] = [
            (.unplugged, PowerState(isPresent: true, percent: 96, estimate: .remaining(5 * 3600))),
            (.low(percent: 20), PowerState(isPresent: true, percent: 20, estimate: .remaining(48 * 60))),
            // Below five per cent, where the tint turns critical — the one step of this feature
            // nobody reaches by waiting.
            (.low(percent: 4), PowerState(isPresent: true, percent: 4, estimate: .remaining(7 * 60))),
            (.lowPowerMode(isOn: true), PowerState(isPresent: true, percent: 4, estimate: .remaining(7 * 60), isLowPowerMode: true)),
            (
                .pluggedIn,
                PowerState(
                    isPresent: true, isPluggedIn: true, isCharging: true, percent: 6,
                    estimate: .remaining(2 * 3600 + 20 * 60), isLowPowerMode: true
                )
            ),
            (
                .lowPowerMode(isOn: false),
                PowerState(
                    isPresent: true, isPluggedIn: true, isCharging: true, percent: 41,
                    estimate: .remaining(1 * 3600 + 5 * 60)
                )
            ),
            (
                .charged,
                PowerState(
                    isPresent: true, isPluggedIn: true, isCharged: true, percent: 100,
                    estimate: .notApplicable
                )
            ),
        ]
        for (index, step) in steps.enumerated() {
            // Spaced past `ActivityKind.power.defaultExpiry`, so each lands on an empty stage rather
            // than queueing behind one that has not retired — the same reason `--device-demo` spaces
            // its three.
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 6) { [weak self] in
                MainActor.assumeIsolated {
                    _ = self?.activities.present(BuiltInActivity.power(step.0, state: step.1))
                }
            }
        }
        #endif
    }

    /// `--shelf-demo [count]`: a full shelf, open, so the grid, the scrolling, the search field and
    /// the reorder can be looked at without dragging twenty files onto the notch.
    ///
    /// Worth its own flag for the same reason `--recents-demo` has one: everything interesting about
    /// this surface only exists past the count where it stops fitting, and getting there by hand
    /// means twenty separate drags, each of which opens and closes the island. Thirty by default,
    /// which is `ShelfContents.capacity` and therefore the deepest, most scrollable grid the app can
    /// ever show.
    ///
    /// **The files are real ones**, taken from `/System/Library` and the user's own home, and that
    /// is deliberate rather than lazy: half of what is being looked at is whether the glyphs resolve
    /// by type and whether QuickLook can actually open what the tile claims, and a shelf of
    /// non-existent paths would be thirty tiles marked missing — a demo of the dead-entry state
    /// instead of the live one. Nothing is copied, moved or written; the shelf holds references
    /// (`ShelfItem`).
    ///
    /// Debug only, like the other four. It puts files on a shelf the user did not drop them on, and
    /// — because the shelf is the one activity that persists — it would otherwise still be there
    /// tomorrow. It deliberately does **not** persist for that reason: the demo is presented, and
    /// nothing calls `persist`.
    private func presentShelfDemoIfRequested() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--shelf-demo") else { return }
        let requested = arguments.indices.contains(flag + 1) ? Int(arguments[flag + 1]) : nil
        let count = min(max(1, requested ?? ShelfContents.capacity), ShelfContents.capacity)

        // Real files, listed from directories that exist on every Mac, rather than a made-up list.
        // Two reasons and both are about what is being looked at: the glyph table in
        // `ShelfItem.symbolName(for:)` is exercised rather than described, and QuickLook can
        // actually open what a tile claims — a demo of invented paths would be a demo of the
        // dead-entry state. Distinct by construction, because `ShelfContents.insert` refuses a file
        // it already holds and a demo that offered the same path twice would show one tile fewer
        // than asked for and read as the capacity being broken.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let directories = [
            URL(fileURLWithPath: "/System/Library/CoreServices"),
            URL(fileURLWithPath: "/System/Library/Desktop Pictures"),
            URL(fileURLWithPath: "/usr/share/dict"),
            home.appendingPathComponent("Downloads"),
            home.appendingPathComponent("Documents"),
        ]
        var urls: [URL] = []
        for directory in directories where urls.count < count {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )) ?? []
            urls.append(contentsOf: contents.prefix(count - urls.count))
        }
        guard !urls.isEmpty else {
            IslandLog.shelf.info("shelf demo found no readable files to hold")
            return
        }
        shelf.addForDemo(urls)

        // After the first frame: the panels have to exist before there is an island to open, and the
        // shelf's own opener reads `controller.screens`.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated { self?.shelf.openFromShortcut() }
        }
        #endif
    }

    /// `--convert-demo`: a shelf of files that can actually be converted, with the actions menu
    /// already open on one of them.
    ///
    /// Worth its own flag rather than folding into `--shelf-demo` for a reason that is specific to
    /// this feature: **`--shelf-demo`'s files are in `/System/Library`, and a conversion writes its
    /// output beside the source.** So every row of the menu on that shelf fails with "that folder
    /// cannot be written to", which is correct behavior and a completely useless demonstration.
    /// This one writes its own samples into a writable scratch directory first.
    ///
    /// Three files, one per family that has a distinct route: an image (ImageIO, and images→PDF), an
    /// RTF (the TextKit chain), and a CSV (the `qlmanage` chain, which is the one with a subprocess
    /// and a timeout in it). Real bytes, because the whole point is that the conversion runs — a
    /// demo of invented paths would be a demo of the error path.
    ///
    /// The menu is opened over the **first** item, which is what a right click does. Opening it over
    /// all three would show the four fixed actions and no conversions at all, because the rows are
    /// the intersection (see `DropAction.menu(for:)`) and these three files have nothing in common —
    /// which is honest, and is not the thing this flag exists to show.
    ///
    /// Debug only, like the others. The scratch directory is under the temporary directory and is
    /// named for this process; nothing is written into the user's own folders and nothing is
    /// persisted to the shelf record.
    private func presentConvertDemoIfRequested() {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--convert-demo") else { return }

        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("com.tryisleta.isleta", isDirectory: true)
            .appendingPathComponent("convert-demo-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )) != nil else {
            IslandLog.shelf.warning("convert demo could not make a scratch directory")
            return
        }

        var urls: [URL] = []
        // An image, copied rather than generated: the ImageIO routes are the ones where a real
        // photograph's size and color space matter, and every Mac has these.
        let pictures = URL(fileURLWithPath: "/System/Library/Desktop Pictures")
        if let source = (try? FileManager.default.contentsOfDirectory(
            at: pictures, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ))?.first(where: { ["heic", "jpg", "png"].contains($0.pathExtension.lowercased()) }) {
            let copy = directory.appendingPathComponent("Sample.\(source.pathExtension)")
            try? FileManager.default.copyItem(at: source, to: copy)
            if FileManager.default.fileExists(atPath: copy.path) { urls.append(copy) }
        }

        let rtf = directory.appendingPathComponent("Sample.rtf")
        let rtfSource = "{\\rtf1\\ansi\\deff0 {\\fonttbl{\\f0 Helvetica;}}\\f0\\fs28 "
            + String(repeating: "Isleta converts this to a PDF without a single NSTextView. ", count: 80)
            + "}"
        if (try? rtfSource.write(to: rtf, atomically: true, encoding: .utf8)) != nil { urls.append(rtf) }

        let csv = directory.appendingPathComponent("Sample.csv")
        let rows = (1...40).map { "Row \($0),\($0 * 7),\($0 % 2 == 0 ? "even" : "odd")" }
        let csvSource = (["Name,Value,Parity"] + rows).joined(separator: "\n")
        if (try? csvSource.write(to: csv, atomically: true, encoding: .utf8)) != nil { urls.append(csv) }

        guard !urls.isEmpty else {
            IslandLog.shelf.warning("convert demo could not write any samples")
            return
        }
        shelf.addForDemo(urls)

        // After the first frame, for the reason `--shelf-demo` waits: the panels have to exist
        // before there is an island to open, and the menu is drawn inside one.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.shelf.openFromShortcut()
                self.shelf.openActionsForDemo(count: 1)
            }
        }
        #endif
    }

    /// `--glance-demo`: a day and a sky, so the calendar surface can be looked at with no calendar
    /// granted, no events in it and no network.
    ///
    /// Worth its own flag for the reason the other three have theirs, and more so: **this is the
    /// only way to see the weather half from a Debug build.** A Debug build is ad-hoc signed and an
    /// ad-hoc signature cannot carry `com.apple.developer.weatherkit` at all, so
    /// `WeatherKitProvider.resolve()` hands back the unavailable provider under `Tools/check.sh` and
    /// under anything launched from `.build/xcode`. The demo supplies a reading directly. A *real*
    /// one needs a signed Release build — `./Tools/release.sh --build-only`, then `open -a Isleta` —
    /// which is what `WeatherKitProvider` argues out at length.
    ///
    /// The calendar half is nearly as hard to see on demand: it needs Calendar granted, events in
    /// the next 36 hours, and — for the Join button — one of them starting within the minute.
    /// Waiting for that is not a check anybody performs.
    ///
    /// Three things are staged, spaced so each lands on its own:
    ///
    /// 1. The **day**, at once: three events with a color each, a weather card, and one meeting
    ///    close enough to carry a Join button.
    /// 2. The **meeting**, six seconds later, which is the surface that opens the island unasked.
    /// 3. The **empty state**, twelve seconds in, drawn from `.denied` — because the sentence a
    ///    refused calendar shows is chosen from the authorization and can be got wrong in a way no
    ///    test can see. See `CalendarAccess`.
    ///
    /// Debug only, like the overlay and the hot keys: it presents a calendar the user does not have
    /// and weather nobody measured.
    private func presentGlanceDemoIfRequested() {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--glance-demo") else { return }
        let now = Date()
        // `--glance-demo --schedule` opens today and tomorrow on fabricated days — enough events to
        // fill both columns and overflow them, without pretending to be somebody's real diary.
        //
        // The flag is read into a `let` **inside** this `#if`, and its only call site is inside it
        // too. A `#if DEBUG` value read into a `let` whose call site is outside the same `#if`
        // makes the branch provably dead in Release, which `SWIFT_TREAT_WARNINGS_AS_ERRORS` fails —
        // it escaped a green check once already.
        let opensSchedule = ProcessInfo.processInfo.arguments.contains("--schedule")
        // Read into a `let` inside this `#if DEBUG` and used only inside it, for the reason spelled
        // out above `opensSchedule`: a `#if DEBUG` value whose call site is outside the same `#if`
        // makes the branch provably dead in Release, which `SWIFT_TREAT_WARNINGS_AS_ERRORS` fails.
        let opensWeather = ProcessInfo.processInfo.arguments.contains("--weather")
        // Read into a `let` inside this `#if DEBUG` and used only inside it, for the reason spelled
        // out above `opensSchedule`.
        let emptyDemo = ProcessInfo.processInfo.arguments.contains("--empty")
        if opensSchedule {
            // `--glance-demo --schedule` opens today and tomorrow on fabricated days, so both
            // columns, the all-day pills, the summary row and the overflow line can be looked at
            // with no calendar granted.
            let calendar = Calendar.current
            let startOfToday = calendar.startOfDay(for: now)
            let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now
            func demoEvent(
                _ id: String, _ title: String, day: Date, hour: Int, minutes: Int = 60,
                allDay: Bool = false, tint: GlanceTint
            ) -> GlanceEvent {
                let start = calendar.date(byAdding: .hour, value: hour, to: day) ?? day
                return GlanceEvent(
                    id: id, title: title, start: start,
                    end: start.addingTimeInterval(Double(minutes) * 60),
                    isAllDay: allDay, calendarTitle: "Demo", calendarTint: tint
                )
            }
            let work = GlanceTint(red: 0.29, green: 0.56, blue: 0.98)
            let home = GlanceTint(red: 0.95, green: 0.45, blue: 0.28)
            let todayDemo = [
                demoEvent("d.allday1", "Bills ($80.40)", day: startOfToday, hour: 0, allDay: true, tint: home),
                demoEvent("d.allday2", "Estimated payday", day: startOfToday, hour: 0, allDay: true, tint: work),
                demoEvent("d.allday3", "Hailee K — unpaid time off", day: startOfToday, hour: 0, allDay: true, tint: home),
                demoEvent("d.allday4", "Recycling", day: startOfToday, hour: 0, allDay: true, tint: work),
                demoEvent("d.allday5", "Library books due", day: startOfToday, hour: 0, allDay: true, tint: home),
                demoEvent("d.dinner", "Antojitos", day: startOfToday, hour: 18, minutes: 90, tint: work),
            ]
            let tomorrowDemo = [
                demoEvent("d.t.allday1", "Ben out of office", day: startOfTomorrow, hour: 0, allDay: true, tint: work),
                demoEvent("d.t.allday2", "Bin day", day: startOfTomorrow, hour: 0, allDay: true, tint: home),
                demoEvent("d.t.guests", "Eltina/Ben be our guests", day: startOfTomorrow, hour: 17, minutes: 240, tint: home),
                demoEvent("d.t.standup", "Design standup", day: startOfTomorrow, hour: 9, minutes: 30, tint: work),
            ]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self else { return }
                self.toggleGlanceSchedule(true)
                // **After** the toggle, not before. Opening reads the real days, which on a machine
                // with no calendar granted are empty — so a demo that seeded them first had its
                // events overwritten by the thing it exists to stand in for.
                //
                // `--empty` is the other half of the surface and needs its own flag for the reason
                // the rest of this demo does: a free day and a granted-but-quiet calendar are not
                // states anybody can arrange on demand, and the empty lines were reported missing
                // precisely because nobody had looked at the surface on a day that had nothing on
                // it. Granted, with two days that are genuinely empty.
                self.glance.todayEvents = emptyDemo ? [] : todayDemo
                self.glance.tomorrowEvents = emptyDemo ? [] : tomorrowDemo
                // And the access to go with them. The live `CalendarSource` publishes over the
                // demo's own snapshot on a machine where the calendar was never granted, which
                // leaves the left column drawing the "not asked" notice beside a right column full
                // of fabricated events — the two halves of one surface disagreeing about whether
                // there is a calendar at all.
                self.glance.snapshot.access = .granted
            }
        }
        let zoom = MeetingLink(
            provider: .zoom,
            url: URL(string: "https://us02web.zoom.us/j/1234567890?pwd=demo")!
        )
        let events = [
            GlanceEvent(
                id: "demo.standup", title: "Design standup",
                start: now.addingTimeInterval(40), end: now.addingTimeInterval(40 + 1800),
                calendarTitle: "Work",
                calendarTint: GlanceTint(red: 0.29, green: 0.56, blue: 0.98),
                meeting: zoom
            ),
            GlanceEvent(
                id: "demo.review", title: "1.5.0 release review",
                start: now.addingTimeInterval(5400), end: now.addingTimeInterval(9000),
                calendarTitle: "Work",
                calendarTint: GlanceTint(red: 0.29, green: 0.56, blue: 0.98)
            ),
            GlanceEvent(
                id: "demo.dentist", title: "Dentist",
                start: now.addingTimeInterval(20_000), end: now.addingTimeInterval(23_600),
                calendarTitle: "Personal",
                calendarTint: GlanceTint(red: 0.95, green: 0.45, blue: 0.28)
            ),
        ]
        // `--glance-demo --rain` (or `--snow`) supplies a sky that is actually doing something, so
        // the precipitation behind the glance can be looked at without waiting for weather. It maps
        // through `Precipitation.matching` like any real reading — the demo changes the *symbol*
        // rather than reaching past the mapping, so what is drawn is what a real rainy day draws.
        //
        // Both flags are read into `let`s inside this `#if DEBUG`, and their only call site is here
        // too: a `#if DEBUG` value whose call site is outside the same `#if` makes the branch
        // provably dead in Release, which `SWIFT_TREAT_WARNINGS_AS_ERRORS` fails.
        let arguments = ProcessInfo.processInfo.arguments
        let symbol: String
        let condition: String
        if arguments.contains("--snow") {
            symbol = "cloud.snow.fill"
            condition = "Snow"
        } else if arguments.contains("--rain") {
            symbol = "cloud.heavyrain.fill"
            condition = "Heavy Rain"
        } else {
            symbol = "cloud.sun.fill"
            condition = "Mostly Cloudy"
        }
        // `--glance-demo --weather` opens the weather page on this reading, so the current block,
        // the four readings and the five forecast rows can all be looked at with no entitlement.
        // The forecast is fabricated here rather than reached past the view, so what is drawn is
        // what a real one draws: five days, a spread of temperatures wide enough for the range bars
        // to differ, and one dry day so the blank in the chance column can be seen beside the others.
        let forecastDay = Calendar.current.startOfDay(for: now)
        let forecast = [
            (0, 8.0, 1.0, 0.4, "cloud.sun.fill", "Mostly Cloudy"),
            (1, 6.0, -1.0, 0.7, "cloud.heavyrain.fill", "Heavy Rain"),
            (2, 3.0, -3.0, 0.9, "cloud.snow.fill", "Snow"),
            (3, 9.0, 2.0, 0.05, "sun.max.fill", "Clear"),
            (4, 12.0, 5.0, 0.25, "cloud.sun.fill", "Partly Cloudy"),
        ].compactMap { offset, high, low, chance, glyph, description -> WeatherDay? in
            guard let date = Calendar.current.date(byAdding: .day, value: offset, to: forecastDay) else {
                return nil
            }
            return WeatherDay(
                date: date,
                highCelsius: high,
                lowCelsius: low,
                precipitationChance: chance,
                symbolName: glyph,
                conditionDescription: description
            )
        }
        let weather = WeatherReading(
            temperatureCelsius: 4,
            highCelsius: 8, lowCelsius: 1, humidity: 0.72,
            conditionDescription: condition,
            symbolName: symbol,
            placeName: "London",
            readAt: now,
            apparentTemperatureCelsius: 1,
            precipitationChance: 0.4,
            windSpeedKPH: 14,
            days: forecast
        )
        let snapshot = GlanceSnapshot(access: .granted, events: events, weather: weather, asOf: now)
        glance.snapshot = snapshot
        glance.onJoin = { link in NSWorkspace.shared.open(link.url) }
        // The island is opened directly rather than by staging an activity to open it. There is no
        // glance activity any more — the day and the sky are the snapshot above, which the pages
        // read — so the demo asks for the page it exists to show.
        openIsland(on: opensWeather ? .weather : .home)

        // The meeting, on its own. Spaced past the glance's arrival rather than queued behind it,
        // for the same reason `--activity-demo` schedules its greeting: an activity's expiry runs
        // from the moment it is handed to the coordinator, not from the moment it reaches the stage.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let event = events.first else { return }
                self.glance.joinableMeeting = event
                _ = self.activities.present(
                    CalendarSource.meetingActivity(for: event, id: CalendarSource.meetingID(for: event))
                )
            }
        }

        // And the state that has to be checked by eye, because nothing else can see it: a refused
        // calendar and an empty one return byte-identical results from every EventKit call there is,
        // so the only thing that puts the right sentence on the island is `access`.
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.glance.joinableMeeting = nil
                // The snapshot alone. The pages read it directly, so there is nothing to stage —
                // and the refused-calendar sentence is drawn from `access`, not from an activity.
                self.glance.snapshot = GlanceSnapshot(
                    access: .denied, events: [], weather: weather, asOf: Date()
                )
            }
        }
        #endif
    }

    /// How many rows `--hitch-test` fills the drop history with.
    ///
    /// `DropHistoryModel.capacity`, and here the worst case is a real one: the history *is* bounded,
    /// so a full one is the tallest list this app can ever draw. That is what a hitch probe wants —
    /// ten screenfuls at `DropHistoryLayout.visibleRows`, enough that the scroll and the icon
    /// resolution are both doing real work.
    private static let demoHistoryRows = DropHistoryModel.capacity

    /// The integer after a flag, or nil when the flag is absent or is the last argument.
    private static func intArgument(_ flag: String) -> Int? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return Int(arguments[index + 1])
    }

    /// `--hitch-test [cycles]`: drives every open and close the island has and reports the frames
    /// each one dropped. See `HitchSelfTest`.
    ///
    /// Three scenarios, because the island's open and close are not one animation: the day is what
    /// an island normally opens onto, a calendar alert is a content-sized body arriving unasked, and
    /// the drop history is the tallest and the only one whose body is a scrolling list of rows with
    /// app icons in it. A run that only opened the day would answer a question nobody asked.
    ///
    /// **The three used to be the quiet menu, a notification and the recents list.** All three went
    /// with notifications; these are the nearest surviving surfaces of each shape, which is what the
    /// measurement was ever about.
    ///
    /// Started late enough that the panels exist and the first frame has composited — the display
    /// link attaches to the island's own window, and there is no window to attach to before that.
    private func runHitchTestIfRequested() {
        #if DEBUG
        guard HitchSelfTest.isRequested() else { return }
        let cycles = HitchSelfTest.cycles

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.hitchProbe.isAttached else {
                    print("hitch self-test: the probe never attached — no island window")
                    NSApp.terminate(nil)
                    return
                }

                let expandEverywhere: @MainActor () -> Void = { [weak self] in
                    guard let self, let controller = self.controller else { return }
                    for screen in controller.screens {
                        self.transition(on: screen) { model, reduceMotion, completion in
                            model.setExpanded(true, reduceMotion: reduceMotion, completion: completion)
                        }
                    }
                }

                var steps: [HitchSelfTest.Step] = []

                // 1. Whatever is on stage at rest — normally the day. The cheapest body the island
                //    has, so anything dropped here is the island's own morph rather than the content
                //    inside it.
                for _ in 0..<cycles {
                    steps.append(.init("open  (stage)", action: expandEverywhere))
                    steps.append(.init("close (stage)") { self.collapseAll() })
                }

                // 2. An alert on stage, held rather than expiring: the arrival morph is the one
                //    animation the user did not ask for and therefore the one they are most likely to
                //    be watching. `.never` because the ten-second dwell would otherwise dismiss it
                //    mid-run and put a `dismissed` morph inside somebody else's measurement window.
                var held = BuiltInActivity(
                    id: ActivityID("hitch.alert"),
                    kind: .calendarAlert,
                    presentations: ActivityPresentations(
                        leading: ActivityContent(symbol: "calendar.badge.clock"),
                        compact: ActivityContent(
                            symbol: "calendar.badge.clock",
                            title: "Quarterly review"
                        ),
                        expanded: ActivityContent(
                            symbol: "calendar.badge.clock",
                            title: "Quarterly review",
                            subtitle: "Starts in 5 minutes — worth a look before the 3pm call."
                        )
                    )
                )
                held.expiry = .never
                steps.append(.init("arrive (alert)") { _ = self.activities.present(held) })
                for _ in 0..<cycles {
                    steps.append(.init("close (alert)") { self.collapseAll() })
                    steps.append(.init("open  (alert)", action: expandEverywhere))
                }
                steps.append(.init("dismiss (alert)") { self.activities.dismissAll() })

                // 3. The drop history — the tallest body the island has, and the one this run
                //    exists for: it grows to a full list of rows, each with an app icon resolved
                //    from disk the first time it is drawn.
                //
                // `--hitch-rows N` and `--hitch-no-icons` exist to answer *why* rather than
                // *whether*: the list's cost is either its rows or the icons in them, and the two
                // are only separable by varying one at a time.
                let rows = max(1, Self.intArgument("--hitch-rows") ?? Self.demoHistoryRows)
                let withoutIcons = ProcessInfo.processInfo.arguments.contains("--hitch-no-icons")
                steps.append(.init("record history", settle: 0.4) {
                    self.dropHistory.recordForHitchTest(rows: rows, withoutIcons: withoutIcons)
                })
                for _ in 0..<cycles {
                    steps.append(.init("open  (island, history to come)", action: expandEverywhere))
                    steps.append(.init("open  (drop history)") { self.toggleDropHistory() })
                    // A drag through the list, in the same window. Twelve samples 16 ms apart is a
                    // slow deliberate scroll rather than a flick, which is the one that has to stay
                    // smooth: a flick is over before anybody can see a dropped frame in it.
                    steps.append(.init("scroll (drop history)") {
                        for sample in 0..<12 {
                            DispatchQueue.main.asyncAfter(deadline: .now() + Double(sample) * 0.016) {
                                MainActor.assumeIsolated {
                                    self.dropHistory.scroll(IslandScrollSample(
                                        phase: sample == 0 ? .began : .changed,
                                        deltaX: 0,
                                        deltaY: -12,
                                        timestamp: Double(sample) * 0.016
                                    ))
                                }
                            }
                        }
                    })
                    steps.append(.init("close (drop history)") { self.toggleDropHistory() })
                    steps.append(.init("close (island)") { self.collapseAll() })
                }

                // 4. **The page carousel**, which is the one animation here a finger is on for its
                //    whole length. Everything above is a transition the user starts and then
                //    watches; a swipe is tracked, so a frame dropped in it is a frame the content
                //    did not follow the hand, which is the form of stutter people actually report.
                //
                //    Driven through `SwipeController` with real samples rather than by calling
                //    `commitPageDrag` — the gesture's own arithmetic, the neighbour pages being
                //    built at `beginPageDrag`, and the tail settling against the detent are all
                //    part of what is being measured, and a shortcut past the recognizer would skip
                //    the first two.
                //    **The day is staged here rather than taken from `--glance-demo`.** That flag
                //    also presents a meeting six seconds in and a refusal at twelve, both of which
                //    change the stage — and a stage change during a measurement window is somebody
                //    else's animation counted as this one's. What the swipe needs is a home page
                //    with rows in it and nothing arriving, which is what this is.
                steps.append(.init("fill  (the day)", settle: 0.3) {
                    // The reading is carried through rather than replaced: `--rain` and `--snow`
                    // put one there, and a staged day that dropped it would take the weather page's
                    // precipitation off the carousel the swipe is about to drag it through.
                    self.glance.snapshot = Self.hitchTestDay(
                        keeping: self.glance.snapshot.weather
                    )
                })
                steps.append(.init("open  (island, to swipe)", action: expandEverywhere))
                for _ in 0..<cycles {
                    steps.append(.init("swipe (page turn)", settle: 1.0) {
                        self.driveHitchSwipe(deltaX: -20, samples: 12)
                    })
                }
                steps.append(.init("close (island, swiped)") { self.collapseAll() })

                // 5. **The space transition.** Not a real one — there is no supported way to switch
                //    spaces from inside the process, and `--hitch-test` has to be reproducible — but
                //    the two calls the space handlers make are the whole of what the user watches:
                //    `hideForReentry` takes the island off screen and `playReentry` springs it back
                //    from a third of its width. See `IslandController.onSpaceWillRestore`.
                //
                //    Measured with something on stage, because an empty island returning is the
                //    cheap case: the re-entry scales and fades the *content* layer as well as the
                //    outline, so what it costs depends on what is in it.
                steps.append(.init("arrive (alert, to re-enter)") { _ = self.activities.present(held) })
                for _ in 0..<cycles {
                    steps.append(.init("hide  (space leaving)", settle: 0.4) {
                        let reduceMotion = self.accessibility.reduceMotion
                        for model in self.models.values { model.hideForReentry(reduceMotion: reduceMotion) }
                    })
                    steps.append(.init("re-enter (space arriving)") {
                        let reduceMotion = self.accessibility.reduceMotion
                        for model in self.models.values { model.playReentry(reduceMotion: reduceMotion) }
                    })
                }
                steps.append(.init("dismiss (alert, re-entered)") { self.activities.dismissAll() })

                HitchSelfTest.run(probe: self.hitchProbe, steps: steps) { measurements in
                    print(HitchSelfTest.report(measurements))
                    if PerformanceProbe.reportModeDuration() == nil { NSApp.terminate(nil) }
                }
            }
        }
        #endif
    }

    #if DEBUG
    /// A full home page for `--hitch-test`: as many rows as the page draws, with titles long enough
    /// to truncate, and nothing that expires.
    private static func hitchTestDay(keeping weather: WeatherReading?) -> GlanceSnapshot {
        let start = Date()
        var events: [GlanceEvent] = []
        for index in 0..<GlanceLayout.maximumRows {
            let begins = start.addingTimeInterval(Double(index + 1) * 3600)
            events.append(GlanceEvent(
                id: "hitch.event.\(index)",
                title: "Design review with the platform team",
                start: begins,
                end: begins.addingTimeInterval(1800),
                isAllDay: false,
                calendarTitle: "Work",
                calendarTint: GlanceTint(red: 0.29, green: 0.56, blue: 0.89)
            ))
        }
        return GlanceSnapshot(access: .granted, events: events, weather: weather, asOf: start)
    }

    /// One horizontal gesture over an open island, delivered a frame apart, for `--hitch-test`.
    ///
    /// `began` → *n* × `changed` → `ended`, through `SwipeController` exactly as
    /// `IslandController.onScroll` delivers a real trackpad's samples. 8 ms apart because that is
    /// what a trackpad does — ~120 a second — and a gesture compressed into one run loop turn would
    /// measure the arithmetic rather than the tracking.
    ///
    /// The travel clears `SwipeMetrics.commitThreshold` (half a page) on distance alone, so the turn
    /// does not depend on a synthesized velocity reaching `flickVelocity`.
    private func driveHitchSwipe(deltaX: CGFloat, samples: Int) {
        let interval = 0.008
        for index in 0...(samples + 1) {
            let phase: IslandScrollSample.Phase =
                index == 0 ? .began : (index > samples ? .ended : .changed)
            let moving = phase == .changed
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * interval) {
                MainActor.assumeIsolated {
                    self.swipes.handle(IslandScrollSample(
                        phase: phase,
                        deltaX: moving ? deltaX : 0,
                        deltaY: 0,
                        timestamp: Double(index) * interval
                    ))
                }
            }
        }
    }
    #endif

    private func refreshDebugInfo() {
        guard let controller else { return }
        diagnostics.memoryBytes = ProcessMetrics.residentMemory()
        for info in controller.debugInfo() {
            models[info.screen.id]?.debugInfo = info
            models[info.screen.id]?.diagnostics = diagnostics
        }
    }

    // MARK: - Debug affordances

    private func installHotKeys() {
        // Debug builds only. `RegisterEventHotKey` is system-wide and exclusive: whoever holds
        // ⌥⌘D holds it for every app on the machine, and the first one to ask wins. Two of those
        // spent on a geometry overlay and a hit-test probe is a real cost to a user who has some
        // other app bound to them, paid for features they cannot see. The menu items are gated in
        // the same build configuration, in `installStatusItem`.
        #if DEBUG
        do {
            // Carbon hot keys, so ⌥⌘D works with no Accessibility permission granted (§13).
            try hotKeys.register(keyCode: kVK_ANSI_D, modifiers: optionKey | cmdKey) { [weak self] in
                self?.toggleDebugOverlay()
            }
            try hotKeys.register(keyCode: kVK_ANSI_P, modifiers: optionKey | cmdKey) { [weak self] in
                self?.probeAtPointer()
            }
        } catch {
            IslandLog.hotKeys.error("debug hot key registration failed: \(error)")
        }
        #endif
        // The user's toggle shortcut is deliberately absent from here. It is the one hot key that
        // can change while the app runs (§5), so it is registered by `apply(_:)` — which runs once
        // at launch and again on every settings change, from the same code path. Registering it
        // here as well would mean two places that have to agree on what "the current shortcut" is.
    }

    /// What each shortcut action does.
    ///
    /// **Total, and no longer optional-returning by accident.** `ShortcutAction` was a vocabulary of
    /// eight that the 2.0 stages were meant to fill in, and two of them — `startTimer` and
    /// `dismissAll` — never were: the row in Settings recorded a keystroke and this function
    /// answered nil, so nothing claimed the key and nothing happened. Schema 18 removed both, along
    /// with three more whose feature is one click away on an island the user has just opened. Every
    /// case here now has a closure, which is the property worth keeping: a bindable action with no
    /// handler takes a combination away from every other app on the machine in exchange for nothing.
    private func handler(for action: ShortcutAction) -> (@MainActor @Sendable () -> Void) {
        switch action {
        case .toggleIsland: { [weak self] in self?.toggleExpansionFromKeyboard() }
        // The glance is `IslandPage.home` — the day beside what is playing. It pins nothing,
        // because it is a page rather than an activity; see `openIsland(on:pinning:)`.
        case .openGlance: { [weak self] in self?.openIsland(on: .home) }
        }
    }

    /// Registers every bound shortcut, releasing whatever was registered before.
    ///
    /// Unregister-then-register, all of them, in that order and unconditionally. `RegisterEventHotKey`
    /// will happily hold two hot keys on the same combination, and the leftover one keeps firing
    /// after the user rebinds — so the island would toggle twice on the new shortcut and once on
    /// the old. Doing it for the whole set rather than per action is what makes a *swap* work: a
    /// user who moves ⌥⌘G from the glance to the switcher passes through a moment where both want
    /// it, and a per-action install would register the second before releasing the first.
    private func installShortcuts(_ shortcuts: Shortcuts) {
        for (id, _) in registeredShortcuts { hotKeys.unregister(id) }
        registeredShortcuts = []

        for (action, binding) in shortcuts.active {
            do {
                let id = try hotKeys.register(
                    keyCode: binding.keyCode,
                    modifiers: binding.carbonModifiers,
                    handler: handler(for: action)
                )
                registeredShortcuts.append((id, action))
                IslandLog.hotKeys.info("\(action.rawValue) shortcut registered: \(binding.displayString)")
            } catch {
                // Almost always "another app already owns this combination". Reported rather than
                // swallowed: the shortcut the user just chose does nothing, and nothing else would
                // say so.
                IslandLog.hotKeys.error(
                    "could not register \(action.rawValue) shortcut \(binding.displayString): \(error)")
            }
        }
    }

    /// Pushes the user's configuration into the places that still hold it as a single global.
    ///
    /// Called once at launch and again on every change, from the same function — a separate
    /// "apply at launch" path is how the two drift until one of them is missing a setting.
    private func apply(_ configuration: IsletaConfiguration) {
        setStatusItemVisible(configuration.showMenuBarIcon)
        updater.setAutomaticallyChecksForUpdates(configuration.automaticUpdateChecks)

        // Rebuilt from the controller's screens rather than from the models, because a model does
        // not hold its own `IslandScreen` — the geometry lives in IslandKit and the model holds only
        // the table this produces. `screens` is keyed the same way `models` is, by display id.
        for screen in controller?.screens ?? [] {
            guard let model = models[screen.id] else { continue }
            model.metricsByForm = Self.metrics(
                for: screen,
                sizing: islandSizing,
                expandedContentHeight: expandedContentHeight,
                expandedContentWidth: expandedContentWidth,
                pageIndicatorHeight: pageIndicatorHeight
            )
            applyAppearance(configuration, to: model)
        }
        syncRegions()

        // The lock-screen card is not an island, so it is outside the loop above. The call guards
        // on equality internally: this function runs on *every* settings change, including the ones
        // about something else entirely.
        lockScreen?.apply(isEnabled: configuration.showsNowPlayingOnLockScreen)
        // The sounds follow the card since schema 18 — see
        // `IsletaConfiguration.showsNowPlayingOnLockScreen`, which is where the fold is argued.
        lockScreen?.apply(playsSounds: configuration.showsNowPlayingOnLockScreen)

        // The list is read at the moment the frontmost app changes rather than captured, so this
        // call is only for the case the notification cannot cover: adding, or removing, the app the
        // user has *already* switched away from.
        refreshApplicationHiding()

        // Nil until the first frame has composited. A configuration change arriving before then is
        // not lost: `startSources()` builds the hub with whatever the store currently holds.
        sources?.apply(configuration)

        // The drop actions are not a `SourceHub` entry either, and for the same reason: there is
        // nothing to observe and nothing to start — the menu exists only while somebody is looking
        // at the shelf. With the module off the wand is not drawn and the right click does nothing,
        // which is the honest shape of "off" for a control rather than a row that refuses.
        shelf.setDropActionsEnabled(configuration.sources.dropActions)

        // Only if it actually moved: re-registering an unchanged hot key would drop and reacquire
        // a system-wide registration on every unrelated settings change, and a key press landing in
        // that window would be swallowed.
        if installedShortcuts != configuration.shortcuts {
            installedShortcuts = configuration.shortcuts
            installShortcuts(configuration.shortcuts)
        }
    }

    @objc private func toggleDebugOverlay() {
        let showing = !(models.values.first?.debugVisible ?? false)
        // Sampling CPU only when the overlay is opened keeps the idle path free of timers (§9).
        if showing {
            let sample = performance.sample()
            diagnostics.idleCPUPercent = sample?.percent
            diagnostics.idleWindowSeconds = sample?.wallSeconds
        }
        refreshDebugInfo()
        for model in models.values {
            model.debugVisible = showing
        }
    }

    /// What the sources are doing, for both diagnostics paths.
    ///
    /// Nil-safe rather than force-unwrapped: `--no-sources` and the window between launch and the
    /// first frame are both states where there is genuinely nothing to report, and a report that
    /// said "0 sources" without saying why would be read as a bug.
    private var sourceReport: SourceReport {
        SourceReport(
            statuses: sources?.statuses ?? [],
            isDisabled: sources == nil
        )
    }

    @objc private func probeAtPointer() {
        guard let controller else { return }
        diagnostics.probe = PassThroughSelfTest.probe(at: NSEvent.mouseLocation, controller: controller)
        refreshDebugInfo()
    }

    #if DEBUG
    /// Debug only — see `installStatusItem`. The same report ships inside "Export Logs…".
    @objc private func copyDiagnostics() {
        guard let controller else { return }
        let text = DiagnosticsReport.text(
            controller: controller,
            diagnostics: diagnostics,
            sources: sourceReport
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        IslandLog.app.info("diagnostics copied to the pasteboard")
    }
    #endif

    /// "Export Logs…" — the history, in a file. See `LogExporter`.
    @objc private func exportLogs() {
        runLogExport(to: nil)
    }

    private func runLogExport(to destination: URL?) {
        let report = controller.map {
            DiagnosticsReport.text(controller: $0, diagnostics: diagnostics, sources: sourceReport)
        } ?? "no island controller"
        LogExporter.run(diagnostics: report, destination: destination)
    }

    /// The pane `--settings` asked for, or `.general` for a bare `--settings`. Nil when the flag is
    /// absent — which is the normal launch, and is why this is an `Optional` rather than a `Bool`
    /// and a pane read separately.
    private static var settingsPaneArgument: SettingsSection? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--settings") else { return nil }
        let next = arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
        // A following argument that is another flag is not a pane name. Without this,
        // `--settings --no-sources` would look up a pane called "--no-sources", find nothing, and
        // quietly open on General — which is the right window and the wrong explanation for it.
        guard let next, !next.hasPrefix("--") else { return .general }
        return SettingsSection(rawValue: next) ?? .general
    }

    @objc private func openSettings() {
        settingsWindow.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    /// Puts the status item in the menu bar, or takes it out — the whole of `showMenuBarIcon`.
    ///
    /// Idempotent in both directions, because it is called from `apply(_:)` on *every* configuration
    /// change. Without the two guards, moving an unrelated slider would tear the item down and build
    /// a new one on each drag sample: the glyph flickers, and the item loses its position in the
    /// menu bar because macOS gives a newly created status item the leftmost slot rather than the
    /// one the user dragged it to.
    ///
    /// `removeStatusItem` and not merely `isVisible = false`. An `NSStatusItem` left alive with
    /// `isVisible` false keeps its slot reserved and keeps `autosaveName` state, so the icon returns
    /// to a different place than it left — and the point of this setting is that the menu bar is the
    /// user's, not ours.
    private func setStatusItemVisible(_ visible: Bool) {
        if visible {
            guard statusItem == nil else { return }
            installStatusItem()
        } else {
            guard let item = statusItem else { return }
            // Ordered before the nil so a menu that is open at this instant is torn down with the
            // item that owns it rather than outliving it.
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
            IslandLog.settings.info("status item hidden — reachable via the toggle shortcut and --settings")
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // The product's own mark — the island above the ripples, the same composition as the app
        // icon — rather than a stand-in SF Symbol. Shipped as a vector asset carrying
        // `template-rendering-intent`, and marked template here as well because ICON-SPEC makes it
        // a rule rather than a default: AppKit then tints the glyph for light, dark, the menu bar's
        // own highlight and Reduce Transparency. A colored status item is never correct.
        let glyph = NSImage(named: "MenuBarGlyph")
        // Isleta's own name, which is the same in every language — but the *attribute* is spoken
        // aloud, so it goes through the table like every other accessibility label rather than
        // being the one that quietly does not.
        glyph?.accessibilityDescription = appText("menuBar.glyph.a11y", "Isleta")
        item.button?.image = glyph
        item.button?.image?.isTemplate = true

        // Five items at most, and no title row.
        //
        // A status menu is not an About box. The name is on the glyph the user just clicked, the
        // version is in Settings' About pane and in the diagnostics report, and a disabled row
        // repeating either is a line that can only ever go stale — which is exactly what happened to
        // its predecessor, "Isleta — Milestone 0", for four milestones.
        //
        // "Toggle Island" is gone for a different reason: it duplicated a global shortcut the user
        // chooses themselves (§5), and a menu item is the slowest possible way to reach something
        // whose whole point is being one keystroke away from anywhere. Reaching it through the menu
        // also meant clicking the status item first, which dismisses the menu over the notch the
        // island is about to appear in.
        // Every row, its order, its enablement and the reason for each is `StatusMenuModel` —
        // pure, in IslandSettings, and asked questions by tests rather than by a running
        // `NSStatusBar`. What stays here is the twenty lines that turn a `StatusMenuEntry` into an
        // `NSMenuItem`, which is the only part that needs AppKit.
        let menu = NSMenu()
        // **Load-bearing.** Left at its default, AppKit re-enables any item it can find a target
        // for — and every row the model deliberately disabled comes back live, with its reason
        // still printed underneath it.
        menu.autoenablesItems = false
        rebuildStatusMenu(menu)

        menu.delegate = self
        item.menu = menu
        statusItem = item
    }
}

extension AppDelegate: NSMenuDelegate {

    /// The status menu opening is a user-initiated moment — but not a *prompting* one. This only
    /// re-reads what the system already knows (§10 forbids asking here, and nothing on this path
    /// does): `refreshAuthorization()` attaches the accessibility observer if the permission has
    /// appeared since launch, and does nothing at all if it has not.
    /// Lets the island go once the menu it raised has gone.
    ///
    /// Both menus reach this — the status item's and the island's — and clearing the flag for a
    /// menu that never set it is harmless. Re-asking `pointerExitChanged` rather than assuming the
    /// pointer came back: the user may well have moved off the island entirely to dismiss the menu,
    /// and in that case the island should close exactly as it would have.
    func menuDidClose(_ menu: NSMenu) {
        guard isShowingIslandMenu else { return }
        isShowingIslandMenu = false
        // Ask again, rather than assuming the pointer came back: the user may well have moved off
        // the island entirely to dismiss the menu, and in that case it should close exactly as it
        // would have. `pointerExitChanged` re-arms the grace period and re-reads where the pointer
        // actually is, which is the whole of that method's contract.
        for screen in controller?.screens ?? [] where models[screen.id]?.isExpanded == true {
            pointerExitChanged(false, on: screen)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        sources?.refreshAuthorizations()
        // Rebuilt on every open rather than kept in step. Opening the menu is already a
        // user-initiated event, which is what makes reading the world here free of §9's idle
        // budget — a cached copy would need something to invalidate it, and that something would
        // be a timer.
        rebuildStatusMenu(menu)
    }

    /// What the menu is drawn from, at the instant it opens.
    private func statusMenuState() -> StatusMenuModel.State {
        // `showNowPlaying` and `showWeather` are unconditional: neither is a `ShortcutAction`, and
        // `openIsland(on:pinning:)` is implemented here whether or not anything is on stage. The
        // model decides whether there is anything to bring forward.
        // Every `ShortcutAction` is performable now. It was a filter on `handler(for:)` answering
        // nil, which is how "Start a Timer" was kept out of the menu while nothing could start one —
        // and that action has gone with schema 18, along with the only other handlerless case.
        var performable: Set<StatusMenuAction> = [.showNowPlaying, .showWeather]
        for action in ShortcutAction.allCases {
            performable.insert(.shortcut(action))
        }
        var includesDebugItems = false
        #if DEBUG
        includesDebugItems = true
        #endif
        return StatusMenuModel.State(
            sources: settings.configuration.sources,
            kindsOnIsland: Set(activities.chips.map(\.kind)),
            performableActions: performable,
            includesDebugItems: includesDebugItems
        )
    }

    private func rebuildStatusMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        for entry in StatusMenuModel.entries(for: statusMenuState()) {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case .item(let item):
                let row = NSMenuItem(
                    title: item.title,
                    action: #selector(statusMenuItemPicked(_:)),
                    keyEquivalent: item.keyEquivalent?.character ?? ""
                )
                if let modifiers = item.keyEquivalent?.modifiers {
                    var flags: NSEvent.ModifierFlags = []
                    if modifiers.contains(.command) { flags.insert(.command) }
                    if modifiers.contains(.option) { flags.insert(.option) }
                    if modifiers.contains(.control) { flags.insert(.control) }
                    if modifiers.contains(.shift) { flags.insert(.shift) }
                    row.keyEquivalentModifierMask = flags
                }
                row.subtitle = item.subtitle
                row.isEnabled = item.isEnabled
                row.target = self
                row.representedObject = item.action
                menu.addItem(row)
            }
        }
    }

    // MARK: - The island's own menu

    /// A right-click anywhere on the island puts up Isleta's own menu.
    ///
    /// **This is where Settings lives now.** It was a gear in the switcher row, and the row went
    /// with the pages — so the one route into Settings on a machine whose menu bar icon is hidden
    /// had to go somewhere that is always there. A right-click is: it costs no island height, it is
    /// what macOS already means by "what can I do with the thing under the pointer", and it cannot
    /// be crowded out by whatever the island happens to be showing.
    ///
    /// The rows are `StatusMenuModel`'s — the same pure model the status item is drawn from — so the
    /// two menus cannot drift apart, and adding a row is one edit rather than two.
    ///
    /// ## The island must not close underneath it
    ///
    /// The island closes when the pointer leaves it (`pointerExitChanged`), and moving onto a menu
    /// **is** the pointer leaving. Without `isShowingIslandMenu` the menu would appear over an
    /// island that was already collapsing — the menu itself is fine, but everything it was raised
    /// from vanishes behind it. The flag is cleared in `menuDidClose`, and the grace period is
    /// re-evaluated then rather than suppressed forever.
    ///
    /// `popUpContextMenu(_:with:for:)` rather than assigning `NSView.menu`: the AppKit paths that
    /// look for a view's menu also assume a key window and a first responder, and the panel is
    /// neither. This is the one route that is driven entirely by the event we were handed.
    private func showIslandMenu(on screen: IslandScreen, event: NSEvent, in view: NSView) {
        activities.noteInteraction()
        let menu = NSMenu()
        // **Load-bearing**, and the same line the status menu carries: left at its default, AppKit
        // re-enables any item it can find a target for, and every row the model deliberately
        // disabled comes back live with its reason still printed underneath it.
        menu.autoenablesItems = false
        menu.delegate = self
        rebuildStatusMenu(menu)

        isShowingIslandMenu = true
        IslandLog.panel.info("island menu opened on display \(screen.id)")
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    @objc private func statusMenuItemPicked(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? StatusMenuAction else { return }
        switch action {
        case .shortcut(let shortcut): handler(for: shortcut)()
        case .showNowPlaying: openIsland(on: .music, pinning: .nowPlaying)
        // Nothing to pin: the weather is not an activity and never was. `openIsland(on:)`'s
        // `pinning` exists for the one page whose surface an *arriving* activity can take over —
        // see `IslandScreenModel.drawsPages` — and the glance row passes nothing for the same
        // reason.
        case .showWeather: openIsland(on: .weather)
        case .openSettings: openSettings()
        case .openSetupGuide: openOnboarding()
        case .exportLogs: exportLogs()
        case .quit: quit()
        case .debugOverlay, .probeAtPointer, .copyDiagnostics:
            // The call sites are behind the same `#if DEBUG` as the declarations, which is the
            // Release-only dead-branch failure this project has already hit once: a flag read into
            // a `let` outside the `#if` makes the branch provably dead and
            // `SWIFT_TREAT_WARNINGS_AS_ERRORS` fails a build that `Tools/check.sh` passed.
            #if DEBUG
            switch action {
            case .debugOverlay: toggleDebugOverlay()
            case .probeAtPointer: probeAtPointer()
            default: copyDiagnostics()
            }
            #endif
        }
    }
}
