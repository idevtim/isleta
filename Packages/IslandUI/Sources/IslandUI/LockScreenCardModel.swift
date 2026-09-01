import CoreGraphics
import Foundation
import IslandActivities
import IslandKit
import Observation
import SwiftUI

/// Something on the lock screen the pointer can be on.
///
/// One type for the three, because they are answering one question — "what is under the pointer
/// right now" — and the answer is exactly one of them. Three independent booleans would be three
/// ways for two to be true at once, which is `NowPlayingTransportView.hovered`'s reasoning; here it
/// is also what lets a single crossing be reported for a haptic, whichever region was entered.
/// What the lock-screen card is showing, and whether it should be on screen at all.
///
/// One per screen, the way `IslandScreenModel` is, and for the same reason: two displays lock
/// together but are not the same size, and a model shared between them would have to hold two
/// frames and pick.
///
/// ## Why this is not `IslandScreenModel`
///
/// The card outlives nothing and owns nothing that the island owns. It has no presentation states,
/// no hover, no gestures, no activity stack — because the lock screen takes no input, all of that
/// machinery would be dead weight carried into the one place it can never run. What is left is a
/// projection of Now Playing onto a fixed layout, and this type is that projection.
///
/// Text and playhead arrive as `ActivityContent`, pushed in on activity changes, so the card draws
/// the same content the island does rather than becoming a second reader of the player's state. **Artwork is the exception**, and it is held rather than pushed for a reason that
/// is specific to it — see `nowPlaying`.
@MainActor
@Observable
public final class LockScreenCardModel {

    /// The track, as the rest of the app already models it. Nil hides the card — there is nothing
    /// to say, and a lock screen carrying an empty music panel is worse than one carrying none.
    public var content: ActivityContent?

    /// Where the playhead is. Nil for anything with no notion of position, which is most system
    /// audio and every live stream.
    public var timeline: ActivityTimeline?

    /// The player, read for its cover.
    ///
    /// Held rather than pushed, and for a reason specific to artwork: it arrives **after** the
    /// track does. `NowPlayingArtworkLoader` fetches and decodes
    /// asynchronously, so a snapshot taken when the activity changed would be the previous track's
    /// cover, or none — and there is no second activity change to correct it. `NowPlayingController`
    /// is `@Observable`, so reading through it means the card redraws when the image lands and at no
    /// other time.
    public var nowPlaying: NowPlayingController?

    /// The cover, or nil while the loader is still working.
    public var artwork: CGImage? { nowPlaying?.artwork }

    /// Whether the screen is locked. The card draws only while this is true; the panel is ordered
    /// out as well, and this exists so the *content* can cross-fade rather than appearing fully
    /// formed at whatever the window server's first composited frame happens to be.
    public var isLocked = false

    /// Whether the padlock is drawn open — the first beat of the unlock.
    ///
    /// Separate from `isLocked` rather than derived from it, because the two have different lives:
    /// the surface has to outlive the unlock notification for the shackle to swing and then for
    /// the shape to collapse into the notch (`playDeparture`), so the controller sets this at the
    /// unlock and tears the panel down after both have played.
    public var isUnlocking = false

    /// How far the surface has arrived, 0 → 1 — `IslandScreenModel.reentry`, on this surface.
    ///
    /// The padlock arrives the way the island itself comes back after the lock: on
    /// `Motion.lockHandover`, growing out of the notch from `IslandScreenModel.reentryScale`'s third
    /// of its size. The same two functions map it to a scale and an opacity so the two surfaces cannot
    /// arrive on different curves. `playArrival` drives it; nothing else writes it.
    public private(set) var reentry: Double = 1

    /// Whether the card has been let on screen yet.
    ///
    /// The padlock's `reentry` and this answer the same question for the two surfaces, and they are
    /// two properties rather than one because the surfaces move differently: the padlock grows out
    /// of the cutout, and the card — which is nowhere near the cutout — comes up in place. What they
    /// share is the beat they arrive on, which is why one `playArrival` sets both.
    ///
    /// **Defaults to true**, like `reentry` defaults to 1: settled, so a model nobody has played an
    /// arrival on draws its card rather than hiding it forever.
    public private(set) var isCardPresented = true

    /// Takes the surface to nothing, without animating, ahead of `playArrival`.
    ///
    /// Two steps, the way `IslandScreenModel.hideForReentry` and `playReentry` are, because the
    /// two happen at different times: this before the panel is built, so its first composited
    /// frame is an empty cutout; the arrival a beat later, once the island has finished going in.
    /// Zeroed **outside** an animation so the spring travels from a third of full size rather
    /// than from wherever the previous lock left it. Reduce motion: the surface is simply there,
    /// which is what §6.3 asks for on an arrival that has nothing to cross-fade from.
    public func hideForArrival(reduceMotion: Bool) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            reentry = reduceMotion ? 1 : 0
            isCardPresented = reduceMotion
        }
    }

    /// Plays the surface out of the notch, from wherever `hideForArrival` left it.
    public func playArrival(reduceMotion: Bool) {
        // The card is animated by the view, on `Motion.expand`, rather than here: it is a plain
        // appearance of a subtree and SwiftUI's own transition machinery is what plays it. The
        // padlock cannot be, because its way in and its way out are one spring played in two
        // directions and a transition can only invent them separately — `LockScreenNotchView` says
        // so on `.transition(.identity)`.
        isCardPresented = true
        guard !reduceMotion else {
            reentry = 1
            return
        }
        withAnimation(Motion.lockHandover) { reentry = 1 }
    }

    /// Collapses the surface back into the notch — the arrival, reversed, on the same spring.
    ///
    /// The second beat of the unlock, after the shackle has opened. Ends at zero, where the shape is
    /// a third of its size and fully transparent, so the window can be torn down afterwards with
    /// nothing on it to cut off. Reduce motion substitutes the crossfade (§6.3): `contentSwap`,
    /// with `arrivalScale` pinned at 1 so nothing but opacity moves.
    public func playDeparture(reduceMotion: Bool) {
        withAnimation(reduceMotion ? Motion.contentSwap : Motion.lockHandover) { reentry = 0 }
    }

    /// Where the surface is drawn on its way in or out — from the notch outwards, anchored at the
    /// bezel. Under reduce motion the scale stays put and only `arrivalOpacity` travels.
    public var arrivalScale: CGFloat {
        reduceMotion ? 1 : IslandScreenModel.reentryScale(reentry)
    }
    public var arrivalOpacity: Double { IslandScreenModel.reentryOpacity(reentry) }

    /// Whether the pointer is on the island right now.
    ///
    /// **Not** driven by `mouseEntered` or an `NSTrackingArea`. Our panel receives no events on a
    /// locked screen — loginwindow captures every one, measured across fourteen probe runs — so
    /// there is nothing to attach a tracking area to. What *is* readable is the pointer's position:
    /// `NSEvent.mouseLocation` is a global query answered by the window server rather than an event
    /// delivered to us, and it was measured moving behind the shield (six samples, six distinct
    /// positions) before a line of this was written. `LockScreenNotchView` samples it on the display
    /// link it is already running.
    public private(set) var isHovered = false

    /// Whether a mouse button is down on the island right now.
    ///
    /// The same trick as `isHovered`, and worth stating because the obvious reading of the probe
    /// results forbids it: our panel receives no *events* on a locked screen, so there is no
    /// `mouseDown` and there never can be — but `NSEvent.pressedMouseButtons` is a **global query**
    /// answered by the window server, exactly like `NSEvent.mouseLocation`. Neither needs a
    /// permission and neither is an event delivered to us.
    ///
    /// So the island cannot *act* on a click — no button will ever work there — but it can
    /// acknowledge one, which is the whole point: a Mac that visibly responds to a press is a Mac
    /// telling the user it is locked rather than frozen.
    public private(set) var isPressed = false

    /// The screen the surface is on, which is where its size and shape come from.
    ///
    /// Nil until the controller has one. Everything geometric falls back to the synthesized island
    /// in that case rather than to zero — a surface of size zero is indistinguishable on screen from
    /// a surface that failed to composite, and this session has already spent an afternoon on that
    /// distinction.
    public var screen: IslandScreen?

    /// The user's island size adjustments, so the lock surface is the same size as their island
    /// rather than the same size as the default one.
    public var sizing: IslandSizing = .standard

    /// Accessibility, carried rather than read here so this type stays free of AppKit and previews
    /// with nothing granted — the `IslandUI` layering rule.
    public var reduceMotion = false
    public var reduceTransparency = false
    public var increaseContrast = false

    public init() {}

    /// Whether there is anything worth putting on the lock screen.
    ///
    /// A title is the bar, not a symbol: every Now Playing content carries a fallback note glyph, so
    /// keying on `symbol` would show a card with a music note and two empty lines for any app that
    /// registered with the system and then said nothing.
    public var hasSomethingToShow: Bool {
        guard let content else { return false }
        return !(content.title ?? "").isEmpty
    }

    /// Whether there is a track to draw.
    public var isPlaying: Bool { hasSomethingToShow }

    /// Whether the music card is drawn: **locked**, arrived, and something to say.
    ///
    /// `isLocked` rather than `isOnScreen`, and that is the difference between the two surfaces on
    /// the way out. The padlock has to outlive the unlock — it opens, and then it collapses into
    /// the cutout — so it reads `isOnScreen`, which stays true for both beats. The card has nothing
    /// to say once the Mac is unlocked: it is a readout of something the user is now looking at on
    /// their own desktop, and holding it over the shield's dissolve is the two-animations-at-once
    /// complaint `AppDelegate.returnDelay` already records for the island. So it leaves on the
    /// notification, on `Motion.collapse`, while the padlock is still opening above it.
    ///
    /// This used to read `isOnScreen`, which meant the card sat through the whole unlock and then
    /// vanished with its window at `LockScreenController.unlockLinger` — not an animation at all,
    /// but a panel being closed out from under a fully drawn card.
    public var isPlayingOnScreen: Bool { isLocked && isCardPresented && isPlaying }

    /// Whether the surface is drawn at all.
    ///
    /// **Not** gated on there being a track. The padlock alone is worth showing: it says the Mac is
    /// locked, which is true whether or not there is music, and it is the thing the owner asked for
    /// first. The old `isVisible` conflated the two and meant a silent Mac drew nothing at all.
    public var isOnScreen: Bool { isLocked || isUnlocking }

    /// The closed island's own metrics for this screen — the size and radius the surface takes.
    private var metrics: IslandShapeMetrics {
        LockScreenNotchLayout.metrics(
            for: screen ?? LockScreenCardModel.fallbackScreen,
            sizing: sizing,
            hovered: isHovered
        )
    }

    /// The flanked island the padlock hangs in — peeked while the pointer is on it.
    public var notchSize: CGSize { notchMetrics.bodySize }

    /// The size the *panel* was built at, which is the peeked island whatever is drawn. The content
    /// is laid out in this so growing does not resize the window. See `LockScreenNotchLayout`.
    public var notchPanelSize: CGSize {
        LockScreenNotchLayout.panelSize(
            for: screen ?? LockScreenCardModel.fallbackScreen, sizing: sizing
        )
    }

    /// The region the pointer must be inside, in global screen points.
    public var hoverRegion: CGRect {
        LockScreenNotchLayout.hoverRegion(
            for: screen ?? LockScreenCardModel.fallbackScreen, sizing: sizing
        )
    }

    /// Takes a pointer position and updates what the surface draws as hovered.
    ///
    /// **It used to return the region that was entered, and that return existed for a haptic.**
    /// Both are gone — see `LockScreenCardView.pointerClock` for why the lock screen no longer
    /// buzzes. What is left is the assignment, which is the half that was always doing the work:
    /// the lit button, the widened progress line and the peeked padlock all read from these three
    /// properties, and none of them cares whether this sample is the one that crossed.
    public func updatePointer(_ location: CGPoint) {
        // All three regions from one sample. One display link answers for both surfaces — they are
        // two panels but one model, and a second sampler running at 30Hz beside the first would be
        // a second clock on the idle path for a question already asked.
        let frame = (screen ?? LockScreenCardModel.fallbackScreen).frame
        let control = hasTransport
            ? LockScreenCardLayout.transportControl(at: location, inScreenFrame: frame)
            : nil
        let onProgress = canSeek
            && LockScreenCardLayout.progressFrame(inScreenFrame: frame).contains(location)
        let onIsland = isOnScreen && hoverRegion.contains(location)

        // **Three assignments, and no edge detection left.** Which region the pointer *crossed into*
        // mattered only to the haptic, which fired once per entry rather than thirty times a second
        // for as long as the pointer rested there; with the buzz gone the crossing has no reader,
        // and what the surface draws is a function of where the pointer is now.
        //
        // `hoveredControl` is assigned for a disabled control too, and that is deliberate: a
        // capability can flip while the pointer rests there — a track loads and skipping becomes
        // possible — and the button must be lit at that instant rather than waiting for the pointer
        // to leave and come back. Whether it may act is `canOperate`'s answer, asked at the press.
        hoveredControl = control
        isProgressHovered = onProgress
        isHovered = onIsland
    }

    /// Whether the pointer is on the progress line.
    public private(set) var isProgressHovered = false

    /// Whether a scrub is in progress — the pointer is down on the line and moving the playhead.
    public var isScrubbing: Bool { nowPlaying?.isScrubbing ?? false }

    /// Whether the line can be seeked at all.
    ///
    /// A duration is the bar, not a transport: a live stream reports no end, and a line with
    /// nothing to be along cannot be moved along. Gated on `hasTransport` as well because a route
    /// with no transport has no seek either — `NowPlayingBridge` wires `onSeek` to the same
    /// adapter the commands go through.
    public var canSeek: Bool {
        hasTransport && isPlayingOnScreen && (timeline?.duration ?? 0) > 0
    }

    /// Which transport button the pointer is on, or nil.
    ///
    /// One value for the row rather than a flag per button — `NowPlayingTransportView.hovered`'s
    /// reasoning, and here it is not even a choice: the pointer is one position, resolved once.
    public private(set) var hoveredControl: LockScreenTransportControl?

    /// Whether the mouse is down anywhere right now, as far as the card is concerned.
    ///
    /// One flag for the card rather than one per control: the press that matters is the one that
    /// began, and what it began on is `hoveredControl` at that instant. A flag per button would let
    /// a press that started on `next` and travelled to `play` release as though it had been a press
    /// on `play`.
    public private(set) var isCardPressed = false

    /// Whether a transport button is being held down right now, for the press swell.
    public var isControlPressed: Bool { isCardPressed && hoveredControl != nil }

    /// Whether a control's setting is currently on — shuffle, or repeat in either of its two modes.
    ///
    /// Nothing else can be "active": play/pause says which glyph it wears rather than lighting up,
    /// and a skip is an event with no state at all.
    public func isActive(_ control: LockScreenTransportControl) -> Bool {
        switch control {
        case .toggleShuffle: nowPlaying?.isShuffling ?? false
        case .toggleRepeat: nowPlaying?.repeatMode.isOn ?? false
        default: false
        }
    }

    /// Whether there is a transport to send anything through.
    ///
    /// False draws no row at all rather than three dimmed buttons. `NowPlayingController.canSkip`'s
    /// distinction: a missing *capability* is dimmed, a missing *control set* is absent — and on a
    /// surface where a control that does nothing teaches the user the whole app is broken, that is
    /// the difference between a card and a complaint.
    public var hasTransport: Bool { nowPlaying?.isTransportAvailable ?? false }

    /// Whether a particular button can act.
    ///
    /// Two capabilities, each gating its own pair, and play/pause gated by neither: a route that
    /// prohibits skipping still stops, and a radio station that has no queue to shuffle still plays
    /// and pauses. The island's row draws exactly these three groups for exactly this reason.
    public func canOperate(_ control: LockScreenTransportControl) -> Bool {
        guard hasTransport else { return false }
        if control.isSkip { return nowPlaying?.canSkip ?? false }
        if control.changesQueueBehavior { return nowPlaying?.canChangeQueueBehavior ?? false }
        return true
    }

    /// Takes the pressed-buttons mask and, on the press **edge** over a button, sends its command.
    ///
    /// **The edge is load-bearing and the return value was not.** Acting on the *state* would send
    /// a skip thirty times a second for as long as somebody leaned on the trackpad, so the guard
    /// below stays; what went with the haptics is the control this handed back, which had no other
    /// reader. That a held button sends exactly one command is observable in what the player
    /// receives, which is where the tests assert it.
    ///
    /// The command goes out from here rather than from the view because the model is what holds
    /// the player. Nothing is queued and nothing is retried: `NowPlayingController.send` is the
    /// island's own path, and a lock screen is not the place to invent a second one.
    public func updateCardPress(
        _ anyButtonDown: Bool,
        at location: CGPoint,
        now: Date
    ) {
        let frame = (screen ?? LockScreenCardModel.fallbackScreen).frame

        // **The middle of a drag, before either edge.** A scrub is the one gesture on this surface
        // that lasts longer than a sample: the pointer is down and moving, and the playhead has to
        // follow it. `updateScrub` is the island's own path, so the bar, the numerals and the
        // optimistic seek that outlives the release all behave the way they do in the open player.
        if isScrubbing, anyButtonDown {
            nowPlaying?.updateScrub(
                toFraction: LockScreenCardLayout.progressFraction(atX: location.x, inScreenFrame: frame)
            )
        }

        guard anyButtonDown != isCardPressed else { return }
        isCardPressed = anyButtonDown

        // The release. A scrub commits here and nowhere else — `endScrub` is what sends the seek,
        // and it takes the player's own rate back so a track that was playing does not stop dead at
        // the drop point. A release that is not a scrub is nothing at all: the buttons act on the
        // way down.
        guard anyButtonDown else {
            if isScrubbing { nowPlaying?.endScrub(reportedBy: timeline, at: now) }
            return
        }

        // The press. A button first: they do not overlap the line, so this is a tie-break that
        // cannot be needed, but the order says which one is the gesture.
        if let control = hoveredControl, canOperate(control) {
            nowPlaying?.send(control.command)
            return
        }
        if isProgressHovered, canSeek {
            nowPlaying?.beginScrub(
                from: timeline,
                toFraction: LockScreenCardLayout.progressFraction(
                    atX: location.x, inScreenFrame: frame
                ),
                at: now
            )
        }
    }

    /// Takes the pressed-buttons mask and records whether the island is being pressed.
    ///
    /// A press that begins *outside* the island is ignored entirely, and a press already in progress
    /// when the pointer arrives does not count — `isHovered` is required at the moment the button
    /// goes down, so dragging onto the island with a button already down does nothing. That is what
    /// `mouseDown` would have done.
    ///
    /// This answered the edge until the lock screen's haptics were removed, since a caller buzzing
    /// on every sample with the button held would have buzzed thirty times a second. `isPressed` is
    /// what remains, and `pressScale` is what reads it.
    public func updatePressed(_ anyButtonDown: Bool) {
        isPressed = anyButtonDown && isHovered
    }

    /// How much the island swells under a press. The constant lives in `LockScreenNotchLayout`
    /// because the panel is built from it — see `LockScreenNotchLayout.panelSize`.
    public var pressScale: CGFloat { isPressed ? LockScreenNotchLayout.pressScale : 1 }

    /// Drops hover without reporting a crossing. For the unlock, where the surface goes away under
    /// a pointer that never moved — otherwise the next lock would start out hovered.
    public func clearHover() {
        isHovered = false
        isPressed = false
        hoveredControl = nil
        isProgressHovered = false
        isCardPressed = false
        // **Abandoned, not committed.** The surface is going away under a pointer that never moved
        // — an unlock, or a display reconfiguration — and neither is somebody letting go of the
        // playhead. `cancelScrub` exists for exactly this distinction, and `endScrub` here would
        // move the user's music on its way out.
        nowPlaying?.cancelScrub()
    }

    public var notchCornerRadius: CGFloat { metrics.bottomCornerRadius }

    /// The full flanked-island metrics, for `IslandShape` — the path with the flare, rather than
    /// the corner radius alone.
    public var notchMetrics: IslandShapeMetrics { metrics }

    /// What VoiceOver says about the padlock. Localized because it is prose Isleta wrote for a
    /// person to read, which is exactly `docs/LOCALIZATION.md`'s line for what gets translated.
    public var lockedAccessibilityLabel: String {
        isUnlocking
            ? islandText("lockScreen.unlocked", "Unlocked")
            : islandText("lockScreen.locked", "Locked")
    }

    /// A notchless 16" stand-in, used only when no screen has been handed in yet. Its numbers do not
    /// matter — what matters is that they are not zero.
    private static let fallbackScreen = IslandScreen(
        id: 0,
        name: "",
        frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
        backingScaleFactor: 2,
        notch: NotchResolver.resolve(
            screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            safeAreaTop: 0,
            auxiliaryTopLeft: nil,
            auxiliaryTopRight: nil
        )
    )

    /// How fast anything on this card changes.
    ///
    /// `.seconds` only while a playhead is genuinely advancing, and `.stopped` otherwise — including
    /// while paused, where the numerals are correct and static. There is no continuous motion on
    /// this card at all: the equaliser the island draws is deliberately absent, because a lock
    /// screen animating at 60Hz to an empty room is the exact shape of the battery complaint §9
    /// exists to prevent.
    public var clockRate: ActivityClockRate {
        guard isPlayingOnScreen, let timeline, timeline.isAdvancing else { return .stopped }
        return .seconds
    }

    /// How often the pointer is sampled.
    ///
    /// `.frames(30)` while the surface is on screen, `.stopped` otherwise — so there is no clock at
    /// all on an unlocked Mac, which is §9's actual rule: no polling *when idle*, and a provider
    /// that must poll polls only while its surface is presented. It rides the existing display link
    /// rather than a `Timer`, which §9 forbids outright.
    ///
    /// 30 rather than 60: this drives a hit test, not motion. The spring that runs when the answer
    /// changes is SwiftUI's and is not gated by this, so halving the sample rate costs a frame of
    /// latency at the crossing and nothing at all afterwards.
    public var pointerRate: ActivityClockRate {
        isOnScreen ? .frames(30) : .stopped
    }

    /// What the card draws the playhead from: the player's report, resolved against a drag in
    /// progress and against a seek that has been sent but not yet acknowledged.
    ///
    /// `NowPlayingController.timeline(reportedBy:at:)` is the island's own single answer to "where
    /// is the playhead", and reading it here is what makes the bar follow the pointer during a
    /// scrub and stay where it was dropped afterwards, instead of snapping back for the second and
    /// a half the player takes to catch up.
    public func playhead(at now: Date) -> ActivityTimeline? {
        nowPlaying?.timeline(reportedBy: timeline, at: now) ?? timeline
    }

    /// Elapsed, as the card prints it.
    public func elapsedText(at now: Date) -> String {
        guard let timeline = playhead(at: now) else { return "--:--" }
        return LockScreenCardModel.clockText(timeline.position(at: now))
    }

    /// Remaining, printed as a negative — the convention every music player on this platform uses,
    /// and the one the reference the owner supplied uses.
    ///
    /// A live stream has no end, so there is nothing to count down to and this prints the same
    /// placeholder the elapsed side does rather than a plausible-looking zero.
    public func remainingText(at now: Date) -> String {
        guard let timeline = playhead(at: now), timeline.duration > 0 else { return "--:--" }
        let remaining = max(0, timeline.duration - timeline.position(at: now))
        return "-" + LockScreenCardModel.clockText(remaining)
    }

    /// How far along the line the playhead is, or nil when there is nothing to be along.
    public func progress(at now: Date) -> Double? {
        guard let timeline = playhead(at: now), timeline.duration > 0 else { return nil }
        return LockScreenCardLayout.progressFraction(
            position: timeline.position(at: now),
            duration: timeline.duration
        )
    }

    /// `m:ss`, or `h:mm:ss` past an hour.
    ///
    /// Hand-rolled rather than `DateComponentsFormatter` for the reason `docs/LOCALIZATION.md`
    /// gives: this is a duration in digits, not prose, and every locale that writes Arabic numerals
    /// writes it the same way. A formatter here would also allocate on every tick.
    /// `nonisolated` because it is a pure function of its argument and inherits the type's
    /// `@MainActor` for no reason. Without it every assertion about it has to be main-actor
    /// isolated, which makes the tests look as though formatting a duration touched the UI.
    nonisolated static func clockText(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded(.down))
        let s = total % 60
        let m = (total / 60) % 60
        let h = total / 3600
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
