import IslandActivities
import IslandKit
import Observation
import SwiftUI

/// Diagnostics surfaced by the debug overlay. Plain data so IslandUI never has to reach into
/// AppKit or into the app shell to render them.
public struct Diagnostics: Equatable, Sendable {
    /// Kernel process start to first island frame on screen (§9: budget 300ms).
    public var launchSeconds: TimeInterval?
    public var idleCPUPercent: Double?

    /// How long the idle sample actually ran, in seconds.
    ///
    /// Reported rather than assumed, because the window does not start when the app does: it opens
    /// once the sources have started and settled, so it is shorter than the duration asked for and
    /// begins later. A report that printed the *requested* figure would name a window nobody
    /// measured, which is how a one-off startup cost came to be read as a steady-state overshoot.
    public var idleWindowSeconds: TimeInterval?
    public var memoryBytes: UInt64?
    /// Result of the click pass-through self-test, phrased as it will be reported.
    public var passThrough: String?
    /// Whether the panels live in the private overlay space, phrased for the report. A host that
    /// silently did nothing is indistinguishable from one that worked, and the symptom — the island
    /// riding along with a space slide — reads as several other bugs first.
    public var overlaySpace: String?
    /// Last manual hit probe: mouse location, whether it hit the island, and who owns that pixel.
    public var probe: String?
    /// Whether haptics were suppressed, and why, at the last peek.
    public var haptics: String?

    public init() {}
}

/// Per-screen render state. One instance per panel; the app shell keeps them in step.
@MainActor
@Observable
public final class IslandScreenModel {

    public var notchKind: NotchGeometry.Kind
    public var debugVisible: Bool = false
    public var debugInfo: IslandDebugInfo?
    public var diagnostics = Diagnostics()

    /// The physical cutout's size, or `.zero` on a synthesized island where there is no hole.
    ///
    /// Kept beside `notchKind` rather than derived from it because only the app shell knows the
    /// screen. `ActivitySlotLayout.cutoutSize(for:)` is the one conversion; both are set together
    /// by the shell so they cannot disagree about whether this display has a notch.
    public var cutoutSize: CGSize

    /// §6.3, and a correctness requirement rather than polish: it decides both the tints and
    /// whether the island is allowed to express hierarchy through opacity at all. Pushed in by the
    /// app shell, which owns `AccessibilityPreferences`.
    /// The user's opacity for a *synthesized* island (`IsletaConfiguration.synthesizedIslandOpacity`).
    ///
    /// Read only by the `.synthesized` branch of `IslandRootView.island`. On a hardware notch it is
    /// ignored outright rather than merely defaulting to 1 — §6.4's pure black is a correctness
    /// requirement there, not a style, and a setting that could dim it would be a setting that lifts
    /// the island off the bezel.
    public var synthesizedOpacity: Double = 1

    public var increaseContrast: Bool = false

    /// §6.3's third setting, and the one this milestone gave a job to.
    ///
    /// It reached the settings window long before it reached the island, because until Stage 7 the
    /// only translucent surface Isleta drew was a notchless Mac's floating pill. Now that a user can
    /// ask for glass in a real cutout, "do not make me read things through other things" applies to
    /// the island itself: both glass styles resolve to the opaque one under it. Pushed in by the app
    /// shell, like `increaseContrast`, from the same `NSWorkspace` notification.
    public var reduceTransparency: Bool = false

    /// What the island is made of. See `IslandStyle`.
    ///
    /// `.automatic` is what shipped before this was a setting — black in a cutout, Liquid Glass
    /// where the island floats — so a model built by a preview or a test looks exactly as it always
    /// did.
    public var style: IslandStyle = .automatic

    /// Whether the **open** island casts a shadow onto the screen below it.
    ///
    /// A closed island casts none whatever this says — see `IslandMaterialView.shadowPresence`,
    /// which rides the same ramp the glass arrives on.
    ///
    /// Off by default, and that is not only conservatism about an upgrade: the shadow paints alpha
    /// outside `islandPath`, and the window server derives the panel's event shape from alpha. See
    /// `IslandMaterialView.shadowRadius`.
    public var showsShadow: Bool = false

    /// Whether a **synthesized** island is allowed to be invisible when it has nothing to say.
    ///
    /// The external-display minimal mode. On a Mac with no notch the island is a floating pill that
    /// is on screen all day whether or not anything is happening, which is the one way the notchless
    /// build differs from the notched one in kind rather than in degree — a real cutout at rest is
    /// invisible because it *is* the cutout. This makes the floating island behave the same: nothing
    /// drawn until something is on stage, or until the pointer arrives.
    ///
    /// It stays reachable, which is the part that has to be got right. The window server routes
    /// clicks by alpha, so an island drawing nothing takes no clicks — but an `NSTrackingArea` is not
    /// alpha-aware, so the pointer arriving still peeks, and the peeked island is solid and
    /// clickable. That is exactly the sequence a hardware notch already has, which is the point.
    public var minimalWhenSynthesized: Bool = false

    /// The material this island actually paints, once its display's kind and the user's
    /// accessibility settings have had their say. Derived, never stored — see `IslandPresentation`.
    public var material: IslandMaterial {
        IslandStyle.material(for: style, notch: notchKind, reduceTransparency: reduceTransparency)
    }

    /// Whether the island paints anything at all.
    ///
    /// False in exactly one situation: minimal mode, on a synthesized island, at rest, with nothing
    /// on stage or with what is on stage swiped away. Everything else — a hardware notch, a peek, an
    /// open island, an activity — draws.
    public var drawsMaterial: Bool {
        guard minimalWhenSynthesized, notchKind == .synthesized, presentation == .rest else {
            return true
        }
        return stage != nil && !isStowed
    }

    /// §6.3 again, but for *rendering* only — the one thing on the island that moves without a
    /// state change behind it is the indeterminate spinner, and this is what replaces it with a
    /// static glyph.
    ///
    /// Deliberately not the value the animations use. Every method that starts a transition takes
    /// `reduceMotion` as a parameter instead, so a transition can never animate against a copy that
    /// the app shell has not got around to refreshing yet; this one only has to be right by the
    /// next frame, which observation guarantees.
    public var reduceMotion: Bool = false

    /// Geometry for each of the island's five shapes, supplied by the app shell from `IslandLayout`.
    ///
    /// Keyed by `IslandForm` rather than by `IslandPresentation` because the resting and peeking
    /// island have two sizes each: the bare cutout, and a wider one with room for the flank slots.
    /// The key is the pair, resolved from inputs — see `IslandForm` for why that is not two more
    /// enum cases.
    public var metricsByForm: [IslandForm: IslandShapeMetrics]

    /// How settled the island's *content* is after the window server hands it back, 0 → 1.
    ///
    /// Switching to or from a fullscreen space covers the panel for about a second and then returns
    /// it. Nothing is destroyed — the geometry never changes and the panel never stops being visible
    /// — so without this the content simply reappears, which reads as a jump rather than as the
    /// island coming back.
    ///
    /// Deliberately applied to the **content, inside the mask**, never to the outline: `islandPath`
    /// has to keep tracking the drawn shape for hit testing to stay exact, so animating the body
    /// would put the clickable region and the visible one out of step for the length of the
    /// animation. On a hardware notch the body is black on a black bezel anyway — the content *is*
    /// what the user sees returning.
    public private(set) var reentry: Double = 1

    /// The **horizontal** scale the island is drawn at partway through a re-entry. The vertical
    /// never moves — see `IslandRootView` for why.
    ///
    /// Shared by the outline and its content so the two cannot drift: the whole point is that the
    /// island comes back as one object growing out of the notch, and two multipliers a refactor
    /// apart is how that becomes a shape and its contents arriving on slightly different curves.
    public static func reentryScale(_ reentry: Double) -> CGFloat {
        // From a third of its size, not from 86%. The first version traveled 14% and read as a
        // twitch rather than as an arrival — "it half bounces". A spring needs distance to be a
        // spring, and starting small is also what makes the island look like it comes *out of* the
        // notch rather than fading up where it already was.
        0.32 + 0.68 * max(0, min(1, reentry))
    }

    /// How the stowed content is scaled partway through.
    ///
    /// The same shape as `reentryScale` but **deliberately not clamped to 0…1**, because the spring
    /// that drives it overshoots at both ends and that overshoot is the bounce. Clamping at 1 threw
    /// away the swell on the way out, and clamping at 0 threw away the squash on the way in — the
    /// stow settled flat while the unstow sprang, which is why only one direction looked alive.
    ///
    /// The bounds that remain are there to stop a spring that has gone badly wrong from inverting
    /// the content or throwing it across the screen, not to shape the motion.
    public static func stowScale(_ reveal: Double) -> CGFloat {
        let bounded = max(-0.2, min(1.18, reveal))
        return 0.32 + 0.68 * bounded
    }

    /// The scale for the island's **outline**, which is the same motion with the overshoot taken
    /// off the top.
    ///
    /// The border has to spring with the content or the widgets look like they are moving inside a
    /// box that is not — but it may never scale *above* 1, and that is a correctness limit rather
    /// than a taste. `islandPath` does not follow this scale, so an outline drawn larger than the
    /// path paints island the app then refuses: a click there reaches us, gets dropped, and never
    /// falls through to whatever is underneath. Drawn smaller is harmless — a ring of pixels we
    /// accept and do not paint, which the window server never routes to us anyway.
    public static func stowOutlineScale(_ reveal: Double) -> CGFloat {
        min(1, stowScale(reveal))
    }

    /// How visible the stowed content is. Clamped, unlike the scale: an opacity outside 0…1 is not
    /// an overshoot, it is a value SwiftUI has to discard anyway.
    ///
    /// Asymmetric on purpose. Going *away*, the widgets clear out well before the island has
    /// finished shrinking — content riding a bounce all the way down reads as debris being sucked
    /// into the notch rather than as the island putting it away. Coming back they simply track the
    /// reveal, which is the arrival that already looked right.
    public static func stowOpacity(_ reveal: Double, isStowed: Bool) -> Double {
        guard isStowed else { return max(0, min(1, reveal)) }
        // Reaches zero at the halfway point, so the fade is over while the spring is still running.
        return max(0, min(1, reveal * 2 - 1))
    }

    /// How much of a re-entry's travel the opacity spends going from absent to solid.
    ///
    /// Short enough that no part of it reads as a fade, and not zero: the springs that drive
    /// `reentry` overshoot both ends of their travel, and a hard cut would flicker on the way out.
    public static let reentryFadeSpan: Double = 0.15

    /// How visible the island is partway through a re-entry.
    ///
    /// **It is not a fade, and since 2026-08-26 it is not one at any moment a person can see it.**
    /// A re-entry is one shape growing sideways out of the cutout; opacity traveling alongside the
    /// scale turns that into a dissolve. It was most obvious across the lock and the unlock, which
    /// ride `Motion.lockHandover` — the slowest curve in the app, so the fade had the longest
    /// possible time to be looked at — and the owner's verdict on hardware was that the handover
    /// should not fade at all. Ramping at twice the rate of the scale was the earlier attempt at the
    /// same idea and was still plainly a fade: it left the island translucent for the whole first
    /// half of the spring.
    ///
    /// So it is solid by `reentryFadeSpan`, where the shape is 42% of its width and still inside the
    /// cutout on a notched display, and everything the user actually watches is `reentryScale` and
    /// nothing else.
    ///
    /// It cannot simply be 1. `reentry` rests at **zero** for as long as the island is away — the
    /// whole of a lock — and the content there is clipped to the island's outline rather than hidden
    /// by it: a Now Playing glyph in the flank would sit lit in the notch, squashed to a third of its
    /// width, until the unlock. Zero is what makes the island absent rather than small.
    public static func reentryOpacity(_ reentry: Double) -> Double {
        min(1, max(0, reentry) / reentryFadeSpan)
    }

    public private(set) var isHovering = false
    public private(set) var isExpanded = false

    /// How far a swipe in progress has displaced the content (§5). Its own object, deliberately —
    /// see `IslandSwipeModel` for why it is not an input like the two above.
    public let swipe = IslandSwipeModel()

    /// What the island is currently saying, as data. `nil` is the normal state of this app.
    ///
    /// The `ActivityPresentations` of whatever the coordinator has on stage, not the activity
    /// itself. The view has no business with priorities, expiry or identity; it needs the four
    /// slots, and holding only those means a redraw cannot depend on anything the model layer
    /// considers private.
    /// The pair on stage: a primary that owns the body and one sliver, and an optional companion
    /// that owns the other. Nil is the normal state of this app.
    ///
    /// **Stored as the stage rather than as loose presentations plus a kind**, which is what it was
    /// before the pair. Two parallel spellings of what is on the island would agree right up until
    /// a companion arrived and one of them had never heard of it — the failure this codebase
    /// documents at `SourceToggles` and again at `IslandPresentation`. Everything the view needs is
    /// derived from this one value.
    public private(set) var stage: ActivityStage?

    /// The primary's four slots. Read by everything that predates the pair.
    ///
    /// Deliberately **not** the answer to "what is drawn in the flanks" — that is `stage`'s
    /// `content(for:)`, because with a companion the two slivers come from different activities.
    /// Anything reaching for this to draw a flank is reaching for the wrong thing.
    public var presentations: ActivityPresentations? { stage?.primary.presentations }

    /// Which kind owns the **body**, or nil when nothing is on stage.
    ///
    /// It exists for exactly one purpose: `ActivityKind.nowPlaying` gets a bespoke slot renderer
    /// (`NowPlayingSlotView`), which is the escape hatch IslandActivities' README sanctions. Every
    /// other kind renders through `ActivityContentView` and this is unread.
    ///
    /// **The flanks do not ask this**, and that is the whole of step 3: they ask
    /// `ActivityStage.kind(for:)`, which resolves per slot. A timer sharing the island with music
    /// would otherwise be handed to `NowPlayingSlotView` and drawn as a cover and an equaliser.
    ///
    /// A second kind wanting bespoke drawing adds a case to one `switch` in `ActivityLayerView`. A
    /// *third* is the point at which this should stop being an enum tag and become something the
    /// activity supplies — but not before, because the alternative today is a protocol requirement
    /// that four of the five kinds implement as "the default", which is a seam with nothing behind
    /// it.
    public var presentedKind: ActivityKind? { stage?.primary.kind }

    /// Everything outstanding, as switcher chips. Drawn only while the island is open.
    ///
    /// Held separately from `stage` rather than derived from it, because the stage is the *pair* —
    /// two activities at most — and the roster is all of them. They come from the same
    /// `ActivityStack` in the same update, so they cannot disagree.
    public var chips: [ActivityChip] = []

    /// Puts the Up Next surface up or takes it away.
    ///
    /// It carries the metrics because the surface is taller than the player's own body, so the
    /// height and the content have to move on one spring or the island jumps a frame ahead of what
    /// is inside it (§6.1).
    ///
    /// **The flag itself lives on `NowPlayingController`, not here**, because there is one user
    /// deciding what to listen to next and this class is per screen — the same reason the
    /// controller owns the scrub state. Setting it inside this transaction is what puts it on the
    /// island's spring rather than a frame ahead of it; setting it from the shell instead swapped
    /// the body before the island had grown to hold it.
    ///
    /// A model with no Now Playing controller — a preview, a build with the source switched off —
    /// still animates its metrics and simply has no flag to set. That is the §3 layering test: this
    /// package must work with nothing injected.
    public func setShowingNowPlayingQueue(
        _ showing: Bool,
        reduceMotion: Bool,
        metricsByForm: [IslandForm: IslandShapeMetrics]? = nil,
        completion: @escaping @MainActor () -> Void = {}
    ) {
        guard let animation = Motion.respectingReduceMotion(Motion.nudge, reduceMotion: reduceMotion) as Animation? else {
            if let metricsByForm { self.metricsByForm = metricsByForm }
            nowPlaying?.isShowingQueue = showing
            completion()
            return
        }
        withAnimation(animation) {
            if let metricsByForm { self.metricsByForm = metricsByForm }
            nowPlaying?.isShowingQueue = showing
        } completion: {
            completion()
        }
        followWithContent(to: form, reduceMotion: reduceMotion)
    }

    /// Whether the open island is showing the Up Next surface. Derived from the controller, never
    /// stored here — two spellings of one state is the bug this codebase refuses everywhere else.
    public var isShowingNowPlayingQueue: Bool { nowPlaying?.isShowingQueue ?? false }

    /// Whether the open island is showing today and tomorrow in place of the day.
    ///
    /// Derived from the glance model, never stored here — two spellings of one state is the bug
    /// this codebase refuses everywhere else.
    public var isShowingGlanceSchedule: Bool { glance?.isShowingSchedule ?? false }

    /// Puts the schedule surface up or takes it away.
    ///
    /// `setShowingNowPlayingQueue`'s shape, and the flag lives on `GlanceModel` for that method's
    /// reason: there is one user looking at one day and this class is per screen. Setting it
    /// inside this transaction is what puts the surface and the island's outline on one spring
    /// rather than swapping the body a frame ahead of the shape.
    public func setShowingGlanceSchedule(
        _ showing: Bool,
        reduceMotion: Bool,
        metricsByForm: [IslandForm: IslandShapeMetrics]? = nil,
        completion: @escaping @MainActor () -> Void = {}
    ) {
        guard let animation = Motion.respectingReduceMotion(Motion.nudge, reduceMotion: reduceMotion) as Animation? else {
            if let metricsByForm { self.metricsByForm = metricsByForm }
            glance?.isShowingSchedule = showing
            completion()
            return
        }
        withAnimation(animation) {
            if let metricsByForm { self.metricsByForm = metricsByForm }
            glance?.isShowingSchedule = showing
        } completion: {
            completion()
        }
        followWithContent(to: form, reduceMotion: reduceMotion)
    }

    /// Moves the island to fit the page that has just been turned to.
    ///
    /// **It carries only the metrics**, and that is the difference between this and every other
    /// `set…` on this class. Those flip a flag *and* resize; the page itself lives on
    /// `IslandPageModel`, which is app-wide and is written by the shell before this is called — so
    /// what is left for the transaction is the shape. Writing the page in here instead would put an
    /// app-wide value inside a per-screen animation, and on a two-display Mac the second panel's
    /// transaction would set it again.
    ///
    /// `Motion.pageTurn`, which is the same spring the swipe's own tail lands on, and it was
    /// `Motion.nudge` until 2026-08-28. The argument for the bounce was that a page turn should read
    /// as a page turn rather than as a resize — and it does, but a page is a detent, and a bottom
    /// edge that goes a few points past the height it is arriving at and comes back reads as the
    /// island missing its mark. §6.1's rule settles the rest: a dot and a swipe land the same page,
    /// so they land it on the same curve.
    ///
    /// The metrics ride inside the transaction rather than being assigned before it, for the reason
    /// every other surface here does: the pages are different heights, so the outline and the
    /// content have to travel on one spring or the island jumps a frame ahead of what is inside it
    /// (§6.1).
    public func setPageMetrics(
        _ metricsByForm: [IslandForm: IslandShapeMetrics],
        reduceMotion: Bool,
        completion: @escaping @MainActor () -> Void = {}
    ) {
        guard let animation = Motion.respectingReduceMotion(Motion.pageTurn, reduceMotion: reduceMotion) as Animation? else {
            self.metricsByForm = metricsByForm
            completion()
            return
        }
        withAnimation(animation) {
            self.metricsByForm = metricsByForm
        } completion: {
            completion()
        }
        followWithContent(to: form, reduceMotion: reduceMotion)
    }

    /// Takes a page's shape table with **no animation of any kind**.
    ///
    /// For the instant a dragged page lands, and for nothing else. At that moment the outline is
    /// already at the incoming page's height — `metrics` interpolated it there as the finger and
    /// then the completion spring carried `progress` to 1 — so the swap from "this page's table,
    /// fully interpolated toward the next" to "the next page's table, not interpolated at all" is
    /// the same number written a different way. Animating it would spring from a value to itself,
    /// which is a frame of stillness the eye reads as a hitch at the end of an otherwise continuous
    /// gesture.
    ///
    /// Deliberately not `setPageMetrics(_:reduceMotion: true)`, which happens to do this today:
    /// that spelling says "the user asked for less motion" about a call that has nothing to do with
    /// the setting, and it would silently start animating the day that branch grows a fade.
    public func setPageMetricsWithoutAnimation(_ metricsByForm: [IslandForm: IslandShapeMetrics]) {
        self.metricsByForm = metricsByForm
    }

    /// The drop history, app-wide. Optional for the reason `nowPlaying` is: this package must build
    /// and preview with nothing injected (§3), and a model with no history draws no layer.
    public var dropHistory: DropHistoryModel?

    /// Whether the open island is showing the drop history. Derived from the model, never stored
    /// here — two spellings of one state is the bug this codebase refuses everywhere else.
    public var isShowingDropHistory: Bool { dropHistory?.isShowing ?? false }

    /// Puts the drop history up or takes it away.
    ///
    /// `setShowingNowPlayingQueue`'s shape exactly, and the flag lives on `DropHistoryModel` for
    /// that method's reason: there is one user reading one list and this class is per screen.
    /// Setting it inside this transaction is what puts it on the island's spring rather than a
    /// frame ahead of it.
    public func setShowingDropHistory(
        _ showing: Bool,
        reduceMotion: Bool,
        metricsByForm: [IslandForm: IslandShapeMetrics]? = nil,
        completion: @escaping @MainActor () -> Void = {}
    ) {
        guard let animation = Motion.respectingReduceMotion(Motion.nudge, reduceMotion: reduceMotion) as Animation? else {
            if let metricsByForm { self.metricsByForm = metricsByForm }
            dropHistory?.isShowing = showing
            completion()
            return
        }
        withAnimation(animation) {
            if let metricsByForm { self.metricsByForm = metricsByForm }
            dropHistory?.isShowing = showing
        } completion: {
            completion()
        }
        followWithContent(to: form, reduceMotion: reduceMotion)
    }

    /// Bring a chip's activity to the stage. Set by the app shell; the row calls it.
    public var onSelectChip: ((ActivityID) -> Void)?

    /// Go to a page directly. Set by the app shell; a dot in the page indicator calls it.
    ///
    /// Through the shell rather than straight to `IslandPageModel`, because turning a page resizes
    /// the island — and resizing has to travel `AppDelegate.transition(on:_:)` so the hit region
    /// widens before the animation and tightens after it. A model writing its own page would move
    /// the island's outline with `islandPath` a frame behind.
    public var onSelectPage: ((IslandPage) -> Void)?

    /// Open Isleta's settings. The only route to them on a machine whose menu bar icon is hidden.
    public var onOpenSettings: (() -> Void)?

    /// Whether the open island wears the page indicator.
    ///
    /// **True for any open island that is not stowed and is not showing the schedule.** The switcher
    /// row this replaced was conditional on what was on stage — no activities, no row — and that
    /// condition was a standing hazard: `AppDelegate.pageIndicatorHeight` had to answer the same
    /// question the same way, because a strip the island grew for but reserved no height for is
    /// drawn over the last thing in the body, and a reserve with no strip in it is dead island.
    ///
    /// The month is not that condition coming back, and the hazard is not back with it. It reaches
    /// the *form* — `IslandForm.showsPageIndicator` — and `IslandLayout.metrics` adds the strip's
    /// height only to forms that wear it, so the shape the island is drawn at and the room reserved
    /// inside it are two readings of this one property. The shell's constant stays a constant and
    /// has nothing to keep in step.
    ///
    /// **Why the schedule, and only the schedule.** The dots say which of three pages you are on
    /// and turn to another when tapped. The schedule is not one of the three: it is a drill-down
    /// from home that takes the body outright, `AppDelegate` refuses a page turn while it is up
    /// (`IslandPageModel.canTurn`), and the surface has its own way out. So the row would be three
    /// dots that answer a question about somewhere the user is not, and a control that does nothing
    /// when pressed. The 28pt it costs goes back to the two columns.
    ///
    /// It stays a computed property rather than becoming `isExpanded` at the call sites, because it
    /// is the *question* — "does this island reserve room at its bottom" — and the day a fourth page
    /// or a build without them arrives, this is the one line that changes.
    public var hasPageIndicator: Bool { !isStowed && !isShowingGlanceSchedule }

    /// Whether the island has nothing on stage.
    ///
    /// Derived from the stage and never stored, like every other answer about what the island is
    /// showing.
    public var isQuiet: Bool { stage == nil }

    /// Whether the island is currently grown for the row. Derived from `form`, never stored.
    public var showsPageIndicator: Bool { form.showsPageIndicator }

    /// The same question asked of the form the *content* is laid out for, which lags by 40ms (§6.2).
    /// The row and the room reserved for it have to answer from the same clock, or the chips arrive
    /// before the island has grown and are clipped by the mask for the length of the morph.
    public var contentShowsPageIndicator: Bool { contentForm.showsPageIndicator }

    /// Transport, scrub state and cover art for the Now Playing activity.
    ///
    /// One instance for the whole app, pushed into every model by the shell — there is one user
    /// listening to one thing, and a controller per panel would let a drag started on the laptop
    /// leave the external display showing the old position. Nil on a build with no Now Playing
    /// source running at all.
    public var nowPlaying: NowPlayingController?

    /// Which page the open island is on. One instance for the whole app, pushed in by the shell —
    /// see `IslandPageModel`, which says why it is not a stored property here.
    ///
    /// Optional so IslandUI keeps building and previewing with nothing injected (§3's layering
    /// test); a model with no page model draws the home page and cannot be turned.
    public var page: IslandPageModel?

    /// Which page to draw, defaulting to home where no page model was injected.
    public var currentPage: IslandPage { page?.current ?? .home }

    /// Whether a page — or the schedule drilled into from one — is drawing in the island's body.
    ///
    /// **The one answer to "who owns the body right now", asked by both the thing that draws a page
    /// and the thing that draws an activity's own slot.** `IslandRootView` uses it to decide whether
    /// to draw a page at all, and `ActivityLayerView` uses it to stand down — because without that
    /// second half both draw, and two views in one rectangle is not a layered effect, it is text on
    /// text.
    ///
    /// That is not hypothetical: it shipped for one build. The glance and the shelf publish an
    /// **empty** `expanded` slot, so `ActivitySlotLayout.bodySlot` returns nil for them and the
    /// activity layer leaves the body alone on its own — which is why the calendar looked right.
    /// Now Playing does not: its expanded slot is the full player, drawn across the whole body. So
    /// the music page and the player were composited on top of each other, the home page with a
    /// scrubber through the middle of it. Reported from use, with a screenshot.
    ///
    /// The condition mirrors the block in `IslandRootView` exactly — expanded, not stowed, a glance
    /// to draw from, and then one of the three surfaces that block can produce.
    public var pagesOwnBody: Bool {
        guard contentPresentation == .expanded, !isStowed, let glance else { return false }
        // **The surfaces the user drilled into own the body outright while they are up**, and a page
        // drawn underneath one is the same two-views-in-one-rectangle failure this property exists
        // to prevent — reported again with Up Next's queue rows written straight through the
        // player's artwork and scrubber. Each of these carries its own way out and takes the
        // vertical axis in `SwipeController`, so they cannot be paged out from under either.
        //
        // First, so they win over the schedule as well: the two cannot be up together today, and an
        // order that relies on that is an order that breaks the day they can be.
        if isShowingNowPlayingQueue || isShowingDropHistory { return false }
        // The schedule is a drill-down from home rather than a page, and it covers the body.
        if glance.isShowingSchedule { return true }
        // A meeting keeps its own body wherever the user is — and draws it through
        // `GlanceLayerView` rather than through the slot machinery, so it owns the body too.
        if presentedKind == .meeting { return true }
        return drawsPages
    }

    /// Whether the open island is showing a **page** rather than an activity's own body.
    ///
    /// The pages are what the island shows when nobody has interrupted it. An activity that
    /// *arrived* — a volume HUD, a call, a timer, a device connecting, a battery warning — brought a
    /// body with it and has a few seconds to say its piece, and turning that into the calendar
    /// because the user was on the home page would be the island swallowing the thing it exists to
    /// show.
    ///
    /// So the pages draw for exactly the kinds they are *about*, plus nothing at all on stage:
    ///
    /// - `nil` — nothing on stage at all, which is now the **ordinary** case rather than a rare
    ///   one. The calendar stood on the stack as an ambient activity through 2.0 and was withdrawn
    ///   (see `ActivityKind.glance`), so an island nobody has interrupted holds nothing.
    /// - `.nowPlaying` — a condition rather than an event, and the subject of the music page.
    /// - `.glance` — kept in the list and never matched: the kind is no longer presented. Removing
    ///   it would be indistinguishable from having forgotten it, and the day it comes back this
    ///   line is what says the pages already expect it.
    ///
    /// Every other kind keeps its body, and the page comes back when it expires. `.meeting` is
    /// handled separately in `IslandRootView` because it draws through `GlanceLayerView` rather than
    /// through the slot machinery.
    public var drawsPages: Bool {
        switch presentedKind {
        case nil, .glance, .nowPlaying: true
        default: false
        }
    }

    /// What the home page's music column says, or nil when nothing is playing.
    ///
    /// A snapshot pushed in by the app shell, like `chips`, and **not** derived from `stage`: the
    /// home page draws the player whether or not Now Playing is on the stage at all, and the stage
    /// holds at most two activities. Deriving it would make the music column go blank the moment a
    /// timer and the calendar were the pair, which is exactly when somebody is looking at it.
    public var nowPlayingContent: ActivityContent?

    /// The day and the weather, for `GlanceLayerView`.
    ///
    /// One instance for the whole app, pushed into every model by the shell — for the reason
    /// `nowPlaying` is: there is one day and one sky, and a model per panel would let the laptop and
    /// an external display disagree about what is next. Nil on a build with no calendar source
    /// running at all, which is what keeps IslandUI previewable with nothing injected (§3).
    ///
    /// **Appended, never inserted.** This is a stored property on an `@Observable` class rather than
    /// a field in a shared struct, so it does not carry the cross-package memory-layout trap
    /// CLAUDE.md documents for `ActivityContent` — but the habit is cheap and the failure it
    /// prevents costs a session.
    public var glance: GlanceModel?

    /// The icons of the apps whose notifications the island has shown.
    ///
    /// Shared across panels by default, for the reason `nowPlaying` is pushed into all of them: an
    /// app's icon is a fact about the machine, and a store per screen would pay the catalog scan
    /// once per display for the same bitmap. Assignable so a test or a preview can hand over one
    /// that resolves from a dictionary and never reads the disk.
    public var applicationIcons: ApplicationIconStore = .shared

    /// The form the *content* is laid out for.
    ///
    /// Lags `form` by `Motion.contentFollowDelay` during a morph — this is §6.2's "container leads,
    /// content follows", stored rather than expressed as a per-view delay because every slot has to
    /// follow by the same 40ms or the island's contents arrive in pieces.
    ///
    /// It is a second piece of state describing the same thing as `form`, which is normally exactly
    /// what this codebase refuses (see `IslandPresentation`). The distinction that makes it safe:
    /// this one is never an *input*. Nothing sets it, nothing reads it to decide anything, and it
    /// always converges on `form` — it is a delayed copy for layout, not a second opinion about
    /// what the island is doing.
    ///
    /// One delayed copy, carrying both the presentation and the flank input, rather than one each.
    /// Two would be two clocks: an activity arriving while the pointer is on the island would grow
    /// the container once and let the content catch up in two steps, 40ms apart, which is §6.2's
    /// single event rendered as two.
    public private(set) var contentForm: IslandForm = .rest

    /// The presentation the content is laid out for, which is the container's 40ms ago.
    public var contentPresentation: IslandPresentation { contentForm.presentation }

    /// Whether the user has swiped the island's content away.
    ///
    /// A fourth input to the island's shape, alongside hovering, expansion and flank content — and
    /// stored rather than derived, because unlike the other three nothing else in the system knows
    /// it. It is the user's own answer to "not now", and there is nothing to infer it from.
    ///
    /// Stowing hides *content*, not activities: the coordinator's stack is untouched, so what is
    /// playing keeps playing and a HUD arriving during a stow still takes the stage when the island
    /// comes back. Dismissing the activity instead would make the gesture destructive, and a swipe
    /// that silently ends a notification is not a gesture anyone can afford to make by accident.
    public private(set) var isStowed = false

    /// How much of the stowed content is showing, 0 → 1.
    ///
    /// **Separate from `reentry`, and that separation is the bug fix.** `reentry` scales and fades
    /// the island *itself* — outline included — which is right when the whole thing is coming back
    /// from behind a space transition. Driving a stow with it made a stowed island invisible rather
    /// than empty: the notch stopped peeking on hover, because there was nothing left to peek.
    ///
    /// A stow hides the *content*. The island stays exactly where it is, narrows to the bare cutout
    /// because its flanks are empty, and goes on hovering and clicking like any other island with
    /// nothing to show.
    public private(set) var stowReveal: Double = 1

    /// How far the island is currently leaning, in points. **A magnitude**: never negative, and
    /// zero almost always. Which edge it moves is `limitLeansTrailing`.
    ///
    /// **The end of a range, answered.** A level the user is driving — the volume and the display —
    /// arriving at its top or bottom sets `ActivityLimit` on the activity, and the island springs a
    /// few points that way and back. It is the rubber-band at the end of a scroll, and it says the
    /// one thing the bar cannot: that there is no more.
    ///
    /// **One edge, not the whole island.** The side that reached its end stretches out and comes
    /// back; the other side, the content, and the cutout the island is drawn around all stay exactly
    /// where they were. Sliding the whole shape was the first version and it was wrong on a notched
    /// Mac in a way a synthesized island hides: the physical hole does not move, so a translated
    /// island reads as sitting crooked on its notch rather than as springing. The owner's verdict,
    /// 2026-08-29: "we don't move the whole notch just that side."
    ///
    /// Handed to `IslandShape.lean` and nowhere else. `metrics` is untouched, so the ten-row shape
    /// table, `IslandShapeMetrics.union`, the widen-then-tighten protocol and every form-keyed
    /// lookup go on knowing nothing about it. The one thing that cannot ignore it is the hit
    /// region, because the window server derives the panel's event shape from the alpha of what we
    /// draw: see `hitRegionMetrics`.
    ///
    /// **A magnitude and a direction rather than one signed number**, which is the third and last
    /// attempt at "do not move the other end". A signed value is one animatable channel that has to
    /// pass through zero to change sides, and a spring interpolating toward zero from a bouncy one
    /// does not stop there — so the shape leaned the *other* way for a frame or two at the end of
    /// every rebound. Split, the sign lives in `limitLeansTrailing`, which does not animate at all,
    /// and the travel is clamped at zero where it is drawn. The other edge is then not a value that
    /// happens to stay put; it is not a value at all.
    public private(set) var limitLean: CGFloat = 0

    /// Which edge `limitLean` moves: the trailing one at the top of a range, the leading one at the
    /// bottom. **Never interpolated** — see `limitLean`, and `IslandShape.leansTrailing`, which is
    /// where it is spent.
    ///
    /// **Which end of the range means which way is decided here and nowhere else.** `ActivityLimit`
    /// says `.minimum` or `.maximum`; a level is drawn filling left to right, so the maximum is to
    /// the right — a fact about drawing, which is why IslandActivities does not carry it.
    public private(set) var limitLeansTrailing = true

    /// The lean as one signed number — positive right, negative left — for everything that wants to
    /// *read* it rather than draw it: the tests, and the badge translate on an island with no
    /// slivers to stretch instead.
    ///
    /// **Nothing that draws an edge may use this**, and that is the whole of `limitLean`'s
    /// docstring. A signed value crosses zero to change sides and a spring aimed at zero overshoots
    /// it; one that is drawn from a clamped magnitude and a static direction cannot.
    public var limitBounce: CGFloat { limitLeansTrailing ? limitLean : -limitLean }

    /// Whether what is on stage has anything to say in the slivers beside the cutout.
    ///
    /// Derived from `presentations` and not stored alongside it: an activity with flank content is
    /// the *only* thing that can make this true, so a stored copy could only ever be a second
    /// answer to a question that already has one — and the island would eventually be sitting wide
    /// with nothing in its flanks. Either flank counts, because either alone is a reason to have
    /// somewhere to draw it (`welcomeBack` fills only the leading one).
    ///
    /// False while stowed, which is what makes the island narrow back to the bare cutout: the flanks
    /// are the only reason it is wider than the hole, so taking their content away is the same thing
    /// as putting the island back.
    public var hasFlankContent: Bool { !isStowed && Self.hasFlankContent(in: stage) }

    /// How wide the slivers are — the flank axis of the island's shape.
    ///
    /// `.none` while stowed, for `hasFlankContent`'s reason: the flanks are the only thing making the
    /// island wider than the hole, so putting the content away is the same thing as putting the
    /// island back.
    public var flanks: IslandFlanks { isStowed ? .none : Self.flanks(in: stage) }

    /// The same question asked of a stage the model has not adopted yet, so the app shell can tell
    /// whether an incoming activity is about to move the island's outline — and therefore whether
    /// the hit region has to be widened before it does.
    ///
    /// **A span rather than a flag, and that matters here specifically.** A HUD arriving over music
    /// leaves `hasFlankContent` true either side of the change while moving the outline by 112pt;
    /// compared as a flag, the shell would decide the outline was not moving and skip the widen,
    /// which is the `islandPath`-is-a-subset failure `IslandHitTestView` is written around.
    public static func flanks(in stage: ActivityStage?) -> IslandFlanks {
        stage?.flanks ?? .none
    }

    /// The same question asked of presentations the model has not adopted yet, so the app shell can
    /// tell whether an incoming activity is about to move the island's outline — and therefore
    /// whether the hit region has to be widened before it does.
    /// Asked of the **pair**. Asked of the primary alone — which is what this did before a
    /// companion could exist — an island whose primary has empty flanks narrows back to the bare
    /// cutout while the companion still has something to say, and the companion is then drawn into
    /// a sliver that no longer exists.
    public static func hasFlankContent(in stage: ActivityStage?) -> Bool {
        stage?.hasFlankContent ?? false
    }

    /// Whether the pointer is on the album cover in the leading flank.
    ///
    /// Stored, for `isStowed`'s reason: nothing else in the system knows it. It is reported by
    /// `PointerPresence` from inside `NowPlayingSlotView` — not by `.onHover`, which never fires on
    /// a panel that is never key and never main, and not by `IslandHitTestView`, whose tracking
    /// rect is the whole island and cannot say *where* on it the pointer is.
    ///
    /// It is an input to the island's shape and never the shape itself: `form` decides whether the
    /// lip is actually drawn, and forces this off in every state that has no cover to hover — an
    /// open island, a stowed one, a resting one, and one with nothing in its flanks. So a stale
    /// `true` left behind by a pointer that vanished with the screen cannot put a lip on an island
    /// that has no business wearing one.
    public private(set) var isHoveringArtwork = false

    /// What the track lip would draw, or nil when there is nothing for it to say.
    ///
    /// **Asked of the sliver the cover is in, not of the primary.** Now Playing spends much of its
    /// life as the *companion* to whatever else is on stage — a timer, the glance — and the cover is
    /// in the leading sliver either way, so a lip gated on the primary would refuse to grow under a
    /// pointer resting on a cover that is plainly there. Gated the other way round, on the primary
    /// alone, an island showing a timer would grow a 34pt strip with nothing in it.
    ///
    /// The **expanded** presentation, because that is the one slot `BuiltInActivity.nowPlaying` puts
    /// both the title and the artist in — and the same pair of strings the open island's header
    /// draws, which is the point: the lip is that header, one click cheaper.
    public var trackLipContent: ActivityContent? {
        guard !isStowed, let stage, stage.kind(for: .leading) == .nowPlaying else { return nil }
        let content = stage.activity(on: .leading).presentations.expanded
        // A route that reports a player but no track has nothing to put in a strip, and an empty
        // lip is a shape change that says nothing — worse than no lip at all.
        return content.title == nil ? nil : content
    }

    /// Whether the island is actually wearing the track lip right now — the *container's* answer.
    ///
    /// Derived from `form`, so it is one question with one answer rather than a second copy of
    /// `isHoveringArtwork` that can disagree with the shape being drawn.
    public var showsTrackLip: Bool { form.showsTrackLip }

    /// The same question asked of the content, which is the container's 40ms ago (§6.2). This is
    /// the one the views branch on — the lip's text has to arrive with the strip it is drawn in,
    /// not with the outline that grew to hold it.
    public var contentShowsTrackLip: Bool { contentForm.showsTrackLip }

    /// Whether a point on the panel is on the album cover — the sliver that grows the track lip.
    ///
    /// **A position, asked on every move, rather than a tracking area over the cover.** The first
    /// version put an `NSTrackingArea` on the artwork view itself and it failed in a way that was
    /// reported before it was understood: approaching the cover from *outside* the island worked,
    /// and sliding to it from the middle of the notch did nothing at all. A nested tracking area
    /// hears only about crossings of its own rect, and the working case was not a crossing — it was
    /// the island growing rest→peek under the pointer, which relaid the view out and re-read the
    /// pointer's position as a side effect. The sideways move produces no layout pass and no
    /// crossing this window delivers, so nothing was left to notice it.
    ///
    /// `IslandHitTestView` had already learned exactly this one level up, and its note says so: the
    /// crossing happens at the outer edge, so everything *inside* the island has to be answered
    /// from where the pointer is. This is that answer, as a pure function of geometry the tests can
    /// ask without a window.
    ///
    /// **The whole sliver, not the 24pt sleeve drawn in it.** The flank is the album's side of the
    /// notch and reads as one target; a rect tighter than the thing it belongs to is a target whose
    /// edges the eye cannot find, which is the same argument `ActivityContentView` makes about the
    /// flank's own insets.
    ///
    /// Asked of `metrics` and not `contentMetrics`, matching `islandPath`: the region a pointer is
    /// judged against is the island's settled shape, not the one the content is 40ms behind. Stable
    /// under the lip itself, which is why this cannot oscillate — the lip changes the island's
    /// height and the flank's rect is a function of its width.
    public func isPointOnAlbumArtwork(_ point: CGPoint, inPanelOfSize size: CGSize) -> Bool {
        guard trackLipContent != nil else { return false }
        let metrics = metrics
        let layout = ActivitySlotLayout.resolve(
            bodySize: metrics.bodySize, cutoutSize: cutoutSize
        )
        guard let flank = layout.leading else { return false }
        let origin = IslandLayout.bodyOrigin(for: metrics, in: size)
        return flank.offsetBy(dx: origin.x, dy: origin.y).contains(point)
    }

    /// Derived, never stored — see `IslandPresentation`.
    public var presentation: IslandPresentation {
        IslandPresentation.resolve(isHovering: isHovering, isExpanded: isExpanded)
    }

    /// The island's shape key: the presentation plus whether it is carrying flank content. Derived
    /// from all three inputs at once, for the same reason `presentation` is derived from two.
    public var form: IslandForm {
        IslandForm.resolve(
            isHovering: isHovering,
            isExpanded: isExpanded,
            flanks: flanks,
            hasPageIndicator: hasPageIndicator,
            // Both halves, never just the pointer: the shape must not grow for a strip that would
            // be drawn empty. See `trackLipContent`.
            showsTrackLip: isHoveringArtwork && trackLipContent != nil
        )
    }

    /// The metrics the island should currently be drawn at.
    ///
    /// Derived from `form` so there is exactly one way for the island's size to change and it
    /// always travels through a single animated value (§6.1).
    ///
    /// ## The one thing that is not the form: a page being dragged
    ///
    /// The three pages are 144, 153–185 and 278pt tall, and a carousel that slides the *content* a
    /// full page across a stationary outline slides the weather through a music-shaped window. So
    /// while a page gesture is live the shape is the form's own, interpolated toward the page being
    /// dragged toward by how far the finger has gone — one `lerp`, the same one `union` reasons
    /// about, so width, height and both radii travel together exactly as §6.1 requires of every
    /// other morph in this island.
    ///
    /// **Zero when nothing is being dragged, which is almost always.** `progress` is zero unless a
    /// gesture is live, and `incoming` is nil unless the shell put one there, so this costs a
    /// branch and nothing else at rest. See `IslandSwipeModel` for why this is allowed to move the
    /// outline when nothing else here is.
    public var metrics: IslandShapeMetrics {
        metrics(for: form)
    }

    /// How far a given slot travels with the rebound.
    ///
    /// **The edge alone is invisible, and that is not a tuning problem.** On a hardware notch the
    /// island is pure black and it sits against a menu bar that is very often black too, so an edge
    /// moving 16pt moves nothing anybody can see — reported from hardware, 2026-08-29, as the bounce
    /// never happening at all. What is visible on that side of the cutout is the *content*: the bar
    /// at the top of a range, the glyph and its word at the bottom. So the sliver on the stretching
    /// side travels with the edge, by exactly the same distance, and keeps its margin from it.
    ///
    /// Only that sliver. The other one holds still, which is what keeps this a stretch rather than
    /// the island sliding — the same thing the outline does, said in the content's terms.
    ///
    /// The body slots move with it when there are no flanks at all: on a synthesized island the
    /// badge *is* the content, there is no hole for it to be misaligned with, and a badge that
    /// stayed put inside a stretching outline would be the one part of the island not answering.
    public func bounceOffset(for slot: ActivitySlot) -> CGFloat {
        guard limitBounce != 0 else { return 0 }
        switch slot {
        // Only where there are no slivers at all — a synthesized island, where the badge *is* the
        // content and there is no bar in a flank to stretch instead. The flanks themselves never
        // travel: the bar answers both ends now, and a sliver that moved as well would be a second
        // thing happening for one keypress. See `bounceStretch(for:)`.
        case .compact, .expanded: return slotLayout.affordsFlanks ? 0 : limitBounce
        default: return 0
        }
    }

    /// How much **longer** a level in this slot is drawn while the island rebounds, in points.
    ///
    /// **A bar stretches; it does not slide.** Moving the whole bar takes its far end with it, and
    /// the far end is the one that is not being pushed — so both ends travel and the thing reads as
    /// the bar being shoved sideways rather than as it running out of room. Growing it from the
    /// fixed end is the rubber band: at the top of a range the fill is already full, the right end
    /// pushes past where it can go, and the left end stays exactly where the eye left it. The
    /// owner's verdict, 2026-08-29: "it should actually stretch the volume/brightness line vs moving
    /// it, and if it's bouncing right do not bounce the left side."
    ///
    /// **Both ends, and the bar is the only thing that moves.** The sign says which way it grows —
    /// positive at the top of a range, so it stretches right from a fixed left end; negative at the
    /// bottom, so it stretches left from a fixed right end.
    ///
    /// The first version only stretched at the maximum, on the reasoning that the *minimum* stretches
    /// the island's left edge, where the content is the glyph and its word rather than the bar — so
    /// that end translated the glyph instead. Each end animated the content that was on it, which
    /// was defensible and was not what was wanted: the bar is the thing that *is* the level, and a
    /// person watching a level run out watches the bar, not the word beside the cutout. The owner's
    /// verdict, 2026-08-29: "make the bar stretch at both ends".
    ///
    /// So at the bottom the bar grows toward the cutout. That is the direction the fill is
    /// disappearing in, and at zero what stretches is the *track* — the dim capsule is still drawn
    /// at full length whatever the fill is doing, so there is always something there to move.
    ///
    /// Zero for every slot that is not drawing a level, which is what keeps this and
    /// `bounceOffset(for:)` exclusive: nothing ever both grows and travels.
    /// **Keyed on the slot being a sliver, not on the layout affording slivers.** `slotLayout` is
    /// derived from `contentMetrics`, which lags the container by `Motion.contentFollowDelay` — so
    /// asking it whether there are flanks answers "not yet" for the first 40ms of an arrival, and
    /// the bar would sit still through the opening of its own rebound. `ActivitySlot.flank` is a
    /// fact about the slot and has no clock in it.
    public func bounceStretch(for slot: ActivitySlot) -> CGFloat {
        guard limitLean != 0, slot.flank != nil, drawsLevel(in: slot) else { return 0 }
        return limitLean
    }

    /// The end of the bar that stays put while it stretches: its left at the top of a range, its
    /// right at the bottom.
    ///
    /// **Separate from `bounceStretch(for:)` because it must not animate**, for the reason
    /// `limitLeansTrailing` gives: an anchor is which end is nailed down, and there is no such
    /// thing as being seven-tenths of the way between two of them. Interpolated, the bar would
    /// stretch from a point sliding along itself. The magnitude springs; this is a fact.
    public var bounceStretchAnchor: UnitPoint { limitLeansTrailing ? .leading : .trailing }

    /// Whether this slot draws its value as a bar rather than as numerals or a glyph — the one thing
    /// that can be stretched instead of moved.
    private func drawsLevel(in slot: ActivitySlot) -> Bool {
        stage?.content(for: slot).value?.normalized != nil
    }

    /// The shape the island accepts clicks in: `metrics`, widened to contain the bounce when there
    /// is a bounce to contain.
    ///
    /// **Not `metrics`, and the difference is the one failure `IslandHitTestView` is written
    /// around.** The bounce translates the drawn island by up to
    /// `IslandLayout.limitBounceDistance`, and the window server takes the panel's event shape from
    /// the alpha of our backing store — so those 8pt are opaque, the clicks on them reach us, and
    /// `islandPath` at the settled shape would drop them on the floor. Drawn pixels we refuse is
    /// precisely the dangerous direction; the re-entry scale is safe for the mirror-image reason,
    /// and says so in `IslandRootView`.
    ///
    /// Widened **symmetrically**, so one answer covers a stretch in either direction, and gated on
    /// the *kind* rather than on `limitBounce` being non-zero or on the activity carrying a limit.
    /// The region is set once, when a change settles, and by then the value may have sprung back —
    /// a gate on the live value would tighten the region under an island still travelling. The kind
    /// is true for as long as a HUD is on stage, which covers every rebound it can produce
    /// **including the ones the user pushes out of it with no reading behind them at all**. A
    /// superset over transparent pixels is one the window server never routes to us in the first
    /// place, so the cost of being generous here is nothing.
    public var hitRegionMetrics: IslandShapeMetrics {
        guard stage?.primary.kind.reboundsAtItsLimits == true else { return metrics }
        var widened = metrics
        widened.bodySize.width += 2 * IslandLayout.limitBounceDistance
        return widened
    }

    /// The metrics the *content* is laid out against, which is the container's size 40ms ago.
    ///
    /// The content must not be laid out against `metrics`. That value jumps to the target the
    /// instant a transition starts — SwiftUI interpolates it inside the shape, not in the model —
    /// so laying content out against it would move the compact badge into the expanded body's
    /// position before it became the expanded badge. The content would arrive ahead of the
    /// container, which is §6.2's ordering exactly backwards.
    public var contentMetrics: IslandShapeMetrics {
        metrics(for: contentForm)
    }

    /// How wide the content box is, **without the page drag's interpolation** — the one number a
    /// page needs from the island, answered so that reading it does not tie the page to the frame
    /// clock.
    ///
    /// ## Why this exists rather than `contentMetrics.bodySize.width`
    ///
    /// A page turn is the one animation in this app that a finger is on for its whole length, and
    /// the island's bottom edge follows that finger — `draggedTowardIncomingPage` lerps the outline
    /// between the page being left and the one arriving, on every tracked sample, about 120 times a
    /// second. Under Observation a body that reads `contentMetrics` takes a dependency on the swipe
    /// offset that feeds it, so **each of the three live pages re-evaluated its whole body on every
    /// sample of every drag** — the day's events, the player's rows, the forecast — for a width that
    /// had not changed. Measured with `--hitch-test 4`, Debug, 120 Hz panel, 2026-08-31: an empty
    /// island's swipe dropped 0 frames, the same swipe with `--glance-demo` dropped 10 in 8 stalls
    /// and with `--nowplaying-demo` 8 in 7. Content the page turn does not touch was deciding
    /// whether the page turn was smooth, which is the tell that the work was not the drawing.
    ///
    /// **The width genuinely cannot move under a drag**, which is what makes dropping the lerp
    /// correct rather than a shortcut: the three pages are all `IslandLayout.expandedBodySize.width`
    /// and only their heights differ, so the lerp's width term interpolates a value to itself. The
    /// surface that *is* wider — the schedule — is a drill-down rather than a page and takes the
    /// carousel down while it is up (`IslandRootView` draws no neighbours for it), so there is no
    /// drag for it to be wrong during. Anything that does change the width — the settings sizing,
    /// a HUD's flanks, the schedule opening — arrives by rewriting `metricsByForm`, which this reads
    /// and therefore still tracks.
    ///
    /// `IslandPageHeight` is the same argument for the other axis, and says why a page does not
    /// simply measure the box it is in.
    public var contentBodyWidth: CGFloat {
        #if DEBUG
        // The control arm, for the paired A/B this change was measured with — `--hitch-legacy-width`
        // puts the pages back on the dragged shape so the two can be interleaved in one binary,
        // which `docs/PERF.md` asks of every comparison here. Debug only, like `--hitch-no-icons`.
        if Self.usesLegacyContentWidth { return contentMetrics.bodySize.width }
        #endif
        return undraggedMetrics(for: contentForm).bodySize.width
    }

    #if DEBUG
    @ObservationIgnored
    static let usesLegacyContentWidth =
        ProcessInfo.processInfo.arguments.contains("--hitch-legacy-width")
    #endif

    /// Falls back through the unflanked form before the resting one. A missing flanked entry means
    /// the shell supplied an incomplete table, and the unflanked shape at the same presentation is
    /// the nearest honest answer — dropping straight to `.rest` would snap an open island shut.
    private func metrics(for form: IslandForm) -> IslandShapeMetrics {
        draggedTowardIncomingPage(from: undraggedMetrics(for: form))
    }

    /// The settled shape for a form, before a live page drag is applied to it. See
    /// `contentBodyWidth`, which is the only caller that wants the shape without the drag.
    private func undraggedMetrics(for form: IslandForm) -> IslandShapeMetrics {
        let base = metricsByForm[form]
            ?? metricsByForm[IslandForm(presentation: form.presentation)]
            ?? metricsByForm[.rest]
            ?? IslandShapeMetrics(bodySize: .zero, topCornerRadius: 0, bottomCornerRadius: 0)
        return base
    }

    /// The page a live swipe is heading toward, or nil when none is.
    ///
    /// **For the page indicator, which cannot wait for the turn to land.** `page.current` flips at
    /// the very end of a committed drag — that is what makes the swap invisible for the pages
    /// themselves — so a row of dots keyed on it alone sits still through the whole gesture and then
    /// snaps a highlight across at the finish. With this it can light the arriving dot as the finger
    /// moves, and by the time the swap happens the highlight is already where the swap would have
    /// put it.
    ///
    /// A negative offset is content pushed left, which is the *next* page arriving from the right —
    /// the same sign convention `SwipeController` publishes its turn direction with.
    public var pageBeingDraggedTo: IslandPage? {
        guard let page, swipe.isPaging, swipe.progress != 0 else { return nil }
        return page.current.stepped(by: swipe.progress < 0 ? 1 : -1)
    }

    /// How far through that drag the finger is, `0`…`1`. Unsigned: which page it is going to is
    /// `pageBeingDraggedTo`'s answer, and the indicator needs only the weight.
    public var pageDragProgress: CGFloat { abs(swipe.progress) }

    /// Whether the dots are drawn right now.
    ///
    /// **Not `contentShowsPageIndicator`, which is a different question.** That one says whether the
    /// island wears the strip at all, and it decides a *height* — the 28pt `IslandLayout` reserves
    /// for as long as the island is open, which cannot follow its contents without moving the
    /// island's bottom edge and the hit region pinned to it. This says whether anything is drawn in
    /// the room already set aside, so the dots can come and go for nothing.
    ///
    /// The or is the whole of it: `IslandPageModel` holds the answer for the moments that have a
    /// clock on them — a turn, a dot, the island opening — and a **live swipe** keeps them lit for
    /// as long as a finger is on the carousel, which is exactly when they are being read. The swipe
    /// is per-screen and the page model is app-wide, so this is asked of the screen the gesture is
    /// happening on and answered app-wide everywhere else.
    public var showsPageDots: Bool {
        guard let page else { return false }
        return page.isIndicatorVisible || swipe.isPaging
    }

    /// The one thing that is not the form: a page being dragged.
    ///
    /// **Applied here rather than in `metrics`, so `contentMetrics` gets it too**, and that is not a
    /// tidiness point — it is where the page indicator's dots live. They are anchored to the bottom
    /// of `contentMetrics.bodySize`, so an interpolation that reached only `metrics` grew the island
    /// under a row of dots that stayed where the old page had left them and then jumped to the new
    /// position when the shape table swapped. The outline and everything pinned to it have to be
    /// one number.
    ///
    /// One `lerp`, the same one `union` reasons about, so width, height and both radii travel
    /// together exactly as §6.1 requires of every other morph in this island.
    ///
    /// **Zero when nothing is being dragged, which is almost always.** `incoming` is nil unless the
    /// shell put one there and `progress` is zero until a finger moves, so this costs a branch and
    /// nothing else at rest. See `IslandSwipeModel` for why the pages are allowed to move the
    /// outline when nothing else here is.
    private func draggedTowardIncomingPage(from base: IslandShapeMetrics) -> IslandShapeMetrics {
        guard let incoming = swipe.incoming else { return base }
        let progress = abs(swipe.progress)
        guard progress > 0 else { return base }
        return IslandShapeMetrics.lerp(from: base, to: incoming, progress: progress)
    }

    /// The one outstanding content-follow delay. At most one, canceled by the next transition —
    /// a hover that reverses inside 40ms must not leave a stale hop queued behind the new one.
    @ObservationIgnored
    private var contentFollow: Task<Void, Never>?

    /// The one outstanding return from a lean. At most one, cancelled by the next — see `comeHome`.
    @ObservationIgnored
    private var limitReturn: Task<Void, Never>?

    public init(
        metricsByForm: [IslandForm: IslandShapeMetrics],
        notchKind: NotchGeometry.Kind,
        cutoutSize: CGSize = .zero
    ) {
        self.metricsByForm = metricsByForm
        self.notchKind = notchKind
        self.cutoutSize = cutoutSize
    }

    /// Plays the content back in after the island has been covered and returned.
    ///
    /// Idempotent by construction: setting `reentry` to 0 outside an animation and then to 1 inside
    /// one restarts the travel rather than stacking a second animation on a value already moving.
    /// Takes the island off screen, without animating, before the panel is raised.
    ///
    /// Separate from `playReentry` because the two happen either side of the window being ordered
    /// front, and doing both afterwards is what made the island blink before it bounced.
    public func hideForReentry(reduceMotion: Bool) {
        // Nothing on stage, nothing to bring back. An empty island is the bare cutout, and bouncing
        // the cutout on every space change is the app announcing itself for no reason — motion that
        // says "look here" about a place where nothing has happened. The re-entry exists to cover
        // the window server handing the panel back mid-transition; with no content, there is nothing
        // for that to have interrupted.
        guard hasVisibleContent else {
            reentry = 1
            return
        }
        reentry = reduceMotion ? 1 : 0
    }

    /// Whether the island is currently showing anything of its own.
    ///
    /// Not the same question as "is an activity presented": a stowed island has one and is
    /// deliberately not drawing it, and the bare cutout should behave the same either way — while an
    /// **open** island with an empty stage has no activity and is drawing the quiet menu, which is
    /// as much a thing to bounce back after a space change as a track is.
    public var hasVisibleContent: Bool { !isStowed && (stage != nil || isExpanded) }

    /// Whether this change puts the island in one of its **widest** shapes — the arrivals slow
    /// enough to need their own token, see `Motion.widen`.
    ///
    /// `>=` rather than `==` since the fourth span exists: power reaches further sideways than a HUD
    /// does, so a test for `.wide` alone would give the longest travel the island makes the curve
    /// tuned for the shorter one.
    ///
    /// An *arrival*, not any change: a HUD whose level moves while it is already on stage is a
    /// content change and crossfades, and morphing the outline for it would be the whole island
    /// animating for a bar that grew four points. The same distinction `Motion.animation(for:)`
    /// makes, asked about the container instead of the content.
    nonisolated static func widensToTheWideForm(_ change: ActivityChange, stage: ActivityStage?) -> Bool {
        switch change {
        case .presented, .swapped: break
        case .none, .dismissed, .contentChanged, .companionChanged: return false
        }
        return (stage?.flanks ?? .none) >= .wide
    }

    /// Whether a change is an arrival that plays the unlock's sideways spring out of the cutout
    /// rather than `expand`. See `setActivity`.
    ///
    /// **Two kinds, and the test is what the arrival looks like rather than what it means.** A track
    /// starting and a device connecting draw the same picture on an empty closed island: a glyph in
    /// one sliver and a round thing in the other, with the cutout between them. Springing that out
    /// of the notch is the unlock's animation, and it is the one the owner asked for.
    ///
    /// `deviceConnected` was left out until 2026-08-29 and read exactly as reported — "it just
    /// appeared". Not because it had no animation: it had `expand`, morphing the resting cutout to
    /// the *standard* flanked width. That is a much shorter move than either of its neighbours —
    /// a HUD takes `Motion.widen` across 216pt, music springs out of the cutout on
    /// `Motion.lockHandover` — so beside them the same curve reads as arriving already finished.
    ///
    /// The other three kinds that can take an empty closed stage stay on `expand`, and the line is
    /// whether the sliver content is a *thing* or a *word*. A shelf, a file action and a welcome
    /// back are text arriving next to a symbol; springing text sideways out of a cutout smears it,
    /// which is the same reason `DeviceConnectSlotView` turns its glyph and does not turn a label.
    nonisolated static func arrivesLikeTheUnlock(_ change: ActivityChange, stage: ActivityStage?) -> Bool {
        guard case .presented = change, let stage else { return false }
        switch stage.primary.kind {
        case .nowPlaying, .deviceConnected: return true
        case .systemHUD, .welcomeBack, .shelf, .timer, .glance, .calendarAlert, .meeting,
             .power, .call, .fileAction, .focusChanged, .screenSharing:
            return false
        }
    }

    /// Puts the content away, or brings it back.
    ///
    /// Routed through the same completion-carrying shape as every other presentation change so the
    /// app shell can widen the hit region before the island narrows and tighten it after — a stow
    /// moves the outline, and an outline that moves without the region following is the failure
    /// `IslandShapeMetrics.union` exists to prevent.
    public func setStowed(
        _ stowed: Bool,
        reduceMotion: Bool,
        completion: @escaping @MainActor () -> Void = {}
    ) {
        guard stowed != isStowed else {
            completion()
            return
        }
        guard !reduceMotion else {
            isStowed = stowed
            stowReveal = stowed ? 0 : 1
            followWithContent(to: form, reduceMotion: true)
            completion()
            return
        }

        // `isStowed` is set **inside** the animation, and that is the whole of why the border now
        // springs.
        //
        // The outline is drawn from `metrics`, which derives from `form`, which derives from
        // `hasFlankContent` — and that is false the instant this flag flips. Setting it outside the
        // transaction left the width change with no animation attached, so the border snapped to the
        // bare cutout while the content sprang: the icons appeared to move inside a box that had
        // already finished. Inside, the same spring carries both.
        if stowed {
            // `nudge`, the same spring the return uses, so going away is the reverse of coming back
            // rather than a different gesture that happens to end up hidden. `collapse` settles
            // without overshooting, which made the stow read as the content being switched off while
            // the unstow read as it springing out.
            withAnimation(Motion.nudge) {
                isStowed = true
                stowReveal = 0
            } completion: {
                completion()
            }
            followWithContent(to: form, reduceMotion: reduceMotion)
        } else {
            // Starts part-open rather than at zero. At zero the content is invisible until the
            // spring has carried it far enough to see, which reads as the widgets arriving late —
            // and they are already being clipped by an outline that is itself still growing back
            // from the bare cutout. Beginning visible means they appear the moment the swipe lands
            // and the bounce is the flourish, not the entrance.
            stowReveal = 0.55
            withAnimation(Motion.nudge) {
                isStowed = false
                stowReveal = 1
            } completion: {
                completion()
            }
            // The content layout has to be told, and this was the bug: `slotLayout` is derived from
            // `contentForm`, which only ever moved on a hover, an expansion or a new activity. A
            // stow changes the island's form without touching any of those, so after unstowing the
            // border grew back while the layout was still the unflanked one — which affords no room
            // to draw in — and the widgets stayed invisible until an unrelated hover change happened
            // to refresh it.
            followWithContent(to: form, reduceMotion: reduceMotion)
        }
    }

    /// `animation` is `nudge` by default — this is the one animation on the island where nothing
    /// about the island's *state* changed; it is the same content, in the same shape, coming back
    /// from behind something else, and `nudge`'s extra bounce is what makes the return read as
    /// arriving from the center out rather than as a panel being switched back on. The return from
    /// a **lock** passes `Motion.lockHandover` instead, the slower curve the lock's collapse and the
    /// padlock both use, so that whole sequence is one curve. Never `expand`.
    public func playReentry(reduceMotion: Bool, animation: Animation? = nil) {
        guard hasVisibleContent, !reduceMotion else {
            reentry = 1
            return
        }
        withAnimation(animation ?? Motion.nudge) {
            reentry = 1
        }
    }

    public func setHovering(
        _ hovering: Bool,
        reduceMotion: Bool,
        completion: @escaping @MainActor () -> Void = {}
    ) {
        apply(hovering: hovering, reduceMotion: reduceMotion, completion: completion)
    }

    public func setExpanded(
        _ expanded: Bool,
        reduceMotion: Bool,
        completion: @escaping @MainActor () -> Void = {}
    ) {
        // **Opening is the island arriving on a page, so the dots say which one.** It is the one
        // appearance that is not a turn, and it is the only one a person who has never swiped will
        // ever see — without it the row exists solely as the answer to a gesture nobody has been
        // told about, and a pointer-only Mac has no way in at all. `showIndicator` starts the same
        // two-second dwell a turn does, so the island settles to a page with nothing under it.
        //
        // Guarded on the island not already being open, because every screen is set expanded on
        // every transition and a re-arm on each would keep the dots alive on an island standing
        // still. `IslandPageModel` is app-wide, so the several screens opening together all restart
        // one dwell.
        if expanded, !isExpanded { page?.showIndicator() }
        apply(expanded: expanded, reduceMotion: reduceMotion, completion: completion)
    }

    /// Puts the track lip out, or takes it back in.
    ///
    /// Through `apply` like every other input to the island's shape, which is what gets it the
    /// single spring, the 40ms content follow and the completion the hit region is tightened from.
    /// The lip does not change the *presentation* — the island is peeking either way — but it does
    /// move the island's bottom edge, so it travels `Motion.reveal` like every other downward move
    /// the island makes, in both directions: one gesture answered twice must not have two curves.
    public func setHoveringArtwork(
        _ hovering: Bool,
        reduceMotion: Bool,
        completion: @escaping @MainActor () -> Void = {}
    ) {
        apply(hoveringArtwork: hovering, reduceMotion: reduceMotion, completion: completion)
    }

    public func toggleExpanded(
        reduceMotion: Bool,
        completion: @escaping @MainActor () -> Void = {}
    ) {
        setExpanded(!isExpanded, reduceMotion: reduceMotion, completion: completion)
    }

    /// Takes the island off screen at once, with nothing animated: back into the notch, content and
    /// all.
    ///
    /// For the screen ceasing to be the user's — locking, or the displays going to sleep. Every
    /// other state change in this file goes through `apply`, which picks `Motion.expand` or
    /// `Motion.collapse` and is right to; here a spring is precisely wrong. The lock fade begins as
    /// the notification is posted, so a collapse animating through it gets captured part-way and
    /// faded out at whatever size that frame caught — the island appears to freeze mid-close and
    /// sink away with the desktop, which reads as Isleta being interrupted rather than as Isleta
    /// getting out of the way. There is no ordering fix for that, because the fade is the window
    /// server's and it does not wait for us; the only version that always looks deliberate is the
    /// one that has already finished before the first faded frame.
    ///
    /// **`reentry` goes to zero here rather than being left to the occlusion path.** The shape
    /// collapsing is not the same as the island being gone: on a synthesized island the resting pill
    /// is still drawn, and on a hardware notch a Now Playing glyph is still lit in the flank. Both
    /// would be caught by the fade. Zeroing it is also what makes the return a *return* — see
    /// `playReentry`, which springs from wherever this left it — so the two are one mechanism rather
    /// than a hide and an unrelated bounce. The occlusion path sets the same value for the same
    /// reason, which is why the app shell suppresses it between the lock and the return: the shield
    /// coming down would otherwise bounce the island back mid-unlock, which is the animation this
    /// whole path exists to avoid.
    ///
    /// `reduceMotion` is not a parameter, rather than being one and ignored: §6.3 asks for motion to
    /// be *substituted*, and there is nothing here to substitute for. The return is where reduce
    /// motion is honored, and `playReentry` already does it.
    ///
    /// **Hover is cleared alongside expansion** — and the album cover's hover with it, which would
    /// otherwise leave a 34pt strip of track title hanging under the notch for the whole fade.
    /// Leaving either would resolve the presentation to `.peek` and leave the island sitting proud
    /// of the notch, which is the same defect one size smaller. The view that tracks the pointer has to be told separately —
    /// `IslandController.cancelHover(forScreen:)` — because no `mouseExited` is coming once the
    /// shield owns the pointer's events, and a model that disagrees with it would refuse the next
    /// hover.
    ///
    /// What it deliberately leaves alone: `isStowed`, which is the user's own answer to "not now"
    /// and is not ours to revoke; and the coordinator's stack, so what was playing is still playing
    /// at the unlock.
    ///
    /// **`animated` is the owner's call, against the measurement above.** With it, an island that
    /// has something on stage goes into the notch on `Motion.lockHandover` — `reentry` 1 → 0,
    /// outline and content on one spring, anchored at the bezel — which is the exact reverse of
    /// the return `playReentry` plays on the same token, and the two-finger stow's shape at the
    /// lock's slower pace, so going away at the lock is the stow the user already knows. The shield's fade does not wait for it; if the
    /// tail of the spring is caught in that fade, this flag is the whole of the fix. An empty island
    /// has nothing to collapse and takes the instant path whatever the flag says, as does reduce
    /// motion. `isStowed` is still not touched: a stow is the user's answer, not the lock's.
    public func collapseIntoNotch(
        animated: Bool = false,
        reduceMotion: Bool = false,
        completion: @escaping @MainActor () -> Void = {}
    ) {
        // The content's 40ms follow (§6.2) has nothing to follow: the container is not traveling.
        // Left running it would land after this returns and lay the content out for a form the
        // island reached instantly, one frame into the fade.
        contentFollow?.cancel()
        contentFollow = nil

        if animated, !reduceMotion, hasVisibleContent {
            // One spring for everything that moves — an open island closing, a hovered one
            // settling, and the content shrinking into the cutout — so it reads as one object
            // going away (§6.1). `swipe` is a value an animation may be driving; it is reset
            // outside the transaction so the reset stops it rather than joining it.
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) { swipe.track(0) }
            withAnimation(Motion.lockHandover) {
                isHovering = false
                isHoveringArtwork = false
                isExpanded = false
                reentry = 0
                contentForm = form
            } completion: {
                completion()
            }
            return
        }

        // Explicit rather than relying on being outside `withAnimation`. Both of these values may
        // already be mid-flight — a swipe and a re-entry both animate — and assigning to a property
        // an animation is driving does not by itself stop the animation.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isHovering = false
            isHoveringArtwork = false
            isExpanded = false
            reentry = 0
            swipe.track(0)
            contentForm = form
        }
        completion()
    }

    /// Takes what the coordinator has on stage, and animates the swap with the curve the *change*
    /// implies rather than the curve the island's size implies.
    ///
    /// The curve comes from `Motion.animation(for:reduceMotion:)`: a crossfade for the same
    /// activity saying something new, a morph for a different activity taking the stage.
    ///
    /// The container *can* move here, which it could not before flanked metrics existed. An
    /// activity with something to say in the flanks widens the resting island from the cutout to
    /// the flanked size and back again when it leaves — so this is a real morph and the content has
    /// to follow it by `Motion.contentFollowDelay` like any other, or the glyphs would appear in
    /// slivers the island has not grown yet. Which it does only when flanked-ness actually flips:
    /// the far more common change, a track title moving on, leaves the outline exactly where it was
    /// and must not queue a hop.
    ///
    /// The completion always fires, including for `.none`, because the caller uses it to tighten
    /// the hit region back to the exact shape.
    /// - Parameter metricsByForm: the shape table the *incoming* activity is drawn against, or nil
    ///   to leave the current one alone.
    ///
    ///   It rides in here rather than being assigned by the caller because the open island's height
    ///   now follows its content (`ActivityExpandedHeight`), so an activity arriving on an island
    ///   that is already open changes the outline — and an assignment outside this transaction would
    ///   snap the island to the new height on the frame it landed and then crossfade the text inside
    ///   it, which is one event drawn as two. Inside, the height is just another dimension on the
    ///   same spring, which is what §6.1 asks for.
    public func setActivity(
        _ stage: ActivityStage?,
        change: ActivityChange,
        reduceMotion: Bool,
        metricsByForm: [IslandForm: IslandShapeMetrics]? = nil,
        completion: @escaping @MainActor () -> Void = {}
    ) {
        // A drag cannot survive the activity it was dragging going away, and the failure if it did
        // is not cosmetic: `endScrub` would seek whatever is playing *next* to a position taken from
        // the track that just ended. Only a genuine swap or dismissal counts — a track change
        // arrives as `.contentChanged` on the same activity, and canceling on that would drop a
        // drag every time the position updated underneath it.
        switch change {
        case .swapped, .dismissed: nowPlaying?.cancelScrub()
        // A companion arriving or leaving cannot touch the body, so a drag on the body survives it.
        case .none, .presented, .contentChanged, .companionChanged: break
        }

        // An arriving activity is always visible.
        //
        // `reentry` is left at zero by anything that took the island off screen and did not put it
        // back — `collapseIntoNotch` at the lock, or a space transition whose return was skipped
        // because there was nothing to bring back. That is correct while the island is empty and
        // wrong the moment something arrives: the content would be laid out, sized and masked
        // correctly, and drawn at a third of its size with no opacity. It looked exactly like the
        // island ignoring the new activity until something else — a click, a hover — happened to
        // restore it.
        //
        // Not animated: this is not a bounce, it is the island being *ready*. The arrival's own
        // animation is `change`'s, a few lines below.
        if stage != nil, reentry == 0 {
            reentry = 1
        }

        // **Music arrives the way the island comes back from a lock.** A track starting on an
        // empty, closed island is the same picture as the unlock — artwork and equaliser springing
        // sideways out of the cutout — and the owner asked for them to be one animation. So the
        // outline's widening and the content's `reentry` both ride `Motion.lockHandover` in one
        // transaction (§6.1: one spring), from a third of the width, rather than `expand` with the
        // flanks fading in. Only Now Playing, only onto an empty stage, and only closed: a HUD has
        // `Motion.widen` of its own now, and an open island has no cutout to spring out of.
        let springsSideways = Self.arrivesLikeTheUnlock(change, stage: stage) && !isExpanded
        let animation: Animation?
        if springsSideways, !reduceMotion {
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) { reentry = 0 }
            animation = Motion.lockHandover
        } else if Self.widensToTheWideForm(change, stage: stage), !isExpanded, !reduceMotion {
            // **The island's biggest sideways move gets its own curve.** See `Motion.widen`: a HUD
            // takes the body from 185pt to 401, and `expand` at that distance reads as the island
            // appearing rather than growing.
            animation = Motion.widen
        } else {
            animation = Motion.animation(for: change, reduceMotion: reduceMotion)
        }

        guard let animation else {
            if let metricsByForm { self.metricsByForm = metricsByForm }
            self.stage = stage
            // No transaction, so nothing for the content to lag behind: adopt the layout outright.
            contentFollow?.cancel()
            contentFollow = nil
            contentForm = form
            completion()
            return
        }
        withAnimation(animation) {
            if let metricsByForm { self.metricsByForm = metricsByForm }
            self.stage = stage
            // Only the sideways arrival travels `reentry` here. A dismissal into a hidden island
            // must leave it at zero — the hide is still meant to be in effect.
            if springsSideways { reentry = 1 }
        } completion: {
            completion()
        }
        followWithContent(to: form, reduceMotion: reduceMotion)
        bounceIfAtALimit(stage, change: change, reduceMotion: reduceMotion)
    }

    /// Leans the island toward the end of a range a level has just reached, and lets it back.
    ///
    /// Its own transaction rather than a value set inside the change's, and that is deliberate: the
    /// change is a morph on `expand` or a crossfade on `contentSwap`, and the bounce is neither —
    /// it is a *there and back* on `Motion.nudge`, which needs its own completion to come home from.
    /// §6.1 asks that one movement travel on one spring; this is a second movement, on top of a
    /// container that is arriving.
    ///
    /// **Only on a change that carries new content for the primary.** A companion arriving or the
    /// stage being re-adopted must not re-fire it: `reachedLimit` is a property of the activity, so
    /// it stays set for as long as that HUD is on stage, and anything that re-runs this would bounce
    /// the island a second and third time for one keypress.
    ///
    /// **Reduce Motion skips it entirely**, and that is the correct substitution rather than a
    /// crossfade (§6.3). Everything else in this file substitutes because the movement is *carrying*
    /// something — a size change, a slot arriving — and the information has to land either way.
    /// Nothing is carried here: the bar is already drawn full or empty, and the bounce is the
    /// flourish on top of it. There is nothing to crossfade to.
    private func bounceIfAtALimit(
        _ stage: ActivityStage?,
        change: ActivityChange,
        reduceMotion: Bool
    ) {
        guard let limit = stage?.primary.reachedLimit else { return }
        switch change {
        case .presented, .swapped, .contentChanged: break
        case .none, .dismissed, .companionChanged: return
        }
        bounce(toward: limit, reduceMotion: reduceMotion)
    }

    /// Rebounds the island's edge toward one end of a range.
    ///
    /// **The one entry point, with two callers**, which is the whole reason it is public. An
    /// activity *arriving* at a limit carries `ActivityLimit` and comes in through
    /// `bounceIfAtALimit` above; the user *pushing* against a limit already reached produces no
    /// reading at all — measured: CoreAudio fires no listener for a set that changes nothing — so it
    /// arrives as an event from `SystemHUDSource.onLimitPushed`. Two causes, one behaviour, one
    /// spelling of it.
    ///
    /// Safe to call twice in quick succession, and that is load-bearing rather than defensive: the
    /// keypress that arrives at a limit can produce both, racing, and the strike-from-zero below
    /// means the second replaces the first before it has travelled anywhere. Two requests a few
    /// milliseconds apart are one beat.
    public func bounce(toward limit: ActivityLimit, reduceMotion: Bool) {
        guard !reduceMotion else { return }
        // A level is drawn filling left to right, so its top is to the right. The one place that
        // fact is written down — see `limitLeansTrailing`.
        let leansTrailing = limit == .maximum
        // **Struck from zero every time, not eased toward a target it may already be at.** A key
        // the user is holding repeats about ten times a second; setting the same target again is a
        // no-op to a spring, so without this the edge would go out once and park there for as long
        // as the key was down. Reset without animation, then spring — one visible beat per press,
        // which is what "keep bouncing as the user continues to press" asks for.
        //
        // The direction is set inside the same silent transaction rather than alongside the spring:
        // it is the one property here that must never be caught mid-interpolation, and a lean that
        // is already out when the user runs a level the other way has to arrive at zero before it
        // can change sides.
        var strike = Transaction()
        strike.disablesAnimations = true
        withTransaction(strike) {
            limitLean = 0
            limitLeansTrailing = leansTrailing
        }
        withAnimation(Motion.rebound) { limitLean = IslandLayout.limitBounceDistance }
        comeHome(after: Motion.reboundDuration)
    }

    /// Brings the lean back to zero once it has been out for the length of the token that took it
    /// there.
    ///
    /// **A one-shot `Task`, not `withAnimation`'s completion and not a `Timer`** — the shape
    /// `followWithContent` already uses, for both of its reasons. §9 forbids a timer on the idle
    /// path, and one task exists for 0.30s per keypress and none at any other time; and a completion
    /// handler fires *immediately* where nothing is hosting the animation, which would make the lean
    /// unobservable off-screen. See `Motion.reboundDuration`, and `Motion.reboundReturn` for why
    /// the way home is critically damped where the way out is not.
    ///
    /// Cancelled by the next lean, which matters for the one gesture that produces two: running a
    /// level to the bottom and straight back up. Without the cancel the first return lands in the
    /// middle of the second lean and pulls the island home while it is still going out.
    private func comeHome(after delay: Duration) {
        limitReturn?.cancel()
        limitReturn = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            withAnimation(Motion.reboundReturn) { self.limitLean = 0 }
        }
    }

    // MARK: - Derived render state

    /// Where each slot can be drawn at the size the content is currently laid out for.
    public var slotLayout: ActivitySlotLayout {
        ActivitySlotLayout.resolve(bodySize: contentBodySize, cutoutSize: cutoutSize)
    }

    /// The body the island's **content** may draw in: the shape's body minus the switcher strip.
    ///
    /// The row is chrome the open island wears along its bottom edge, so everything that draws
    /// content has to be laid out against what is left. `NowPlayingExpandedLayout` and `ShelfLayout`
    /// both anchor their rows to the bottom of the body they are handed — that is stated in their
    /// own documentation as the reason those two kinds keep a constant height — so handing them the
    /// full body puts the transport controls underneath the chips. Which is exactly what it did the
    /// first time this was drawn on hardware.
    ///
    /// Gated on `contentPresentation`, the same value the row itself is gated on, so the body and
    /// the row cannot disagree about whether there is a strip to leave room for during a morph.
    ///
    /// **Not** used for `IslandLayout.bodyOrigin`, which places the body inside the panel and needs
    /// the real shape. Only the room *within* the body shrinks.
    public var contentBodySize: CGSize {
        var size = contentMetrics.bodySize
        if contentShowsPageIndicator {
            size.height = max(0, size.height - IslandPageIndicatorLayout.height)
        }
        return size
    }

    /// Whether anything actually on screen has to be redrawn as the clock moves (§9).
    public var needsClock: Bool {
        slotLayout.needsClock(
            for: contentPresentation, in: stage, showsTrackLip: contentShowsTrackLip
        )
    }

    /// How often the island has to redraw, if at all (§9).
    ///
    /// Three inputs, in order of how much they cost:
    ///
    /// - **Nothing time-dependent is visible** — the overwhelmingly common case — and there is no
    ///   display link at all. Unchanged from before Now Playing existed.
    /// - **A countdown or an elapsed time is visible.** Numerals have a resolution of one second and
    ///   there is nothing to gain by publishing faster.
    /// - **The Now Playing equaliser is visible and moving.** That is continuous motion and needs
    ///   frames, and it is the one deliberate departure from §9's idle profile in this milestone:
    ///   the owner's decision is that the bars run whenever music is playing, *including at rest*,
    ///   because a Mac user cannot tell a still equaliser from a broken one. `nowPlayingFrameRate`
    ///   is the lever that decision was accepted on.
    ///
    /// Note what makes the third case cheap when it should be: it asks the *visible* slots, so an
    /// activity carrying a timeline that nobody has opened costs nothing, and a paused track reports
    /// `rate` zero so `isTimeDependent` is false and the link stops dead. Pausing the music really
    /// does take Isleta back to its idle profile, rather than to a slower animation of a still
    /// picture.
    public var clockRate: ActivityClockRate {
        guard let stage else { return .stopped }
        let layout = slotLayout
        let slots = layout.visibleSlots(for: contentPresentation, in: stage)

        var rate = ActivityClockRate.stopped
        for slot in slots {
            // Per slot, so a companion's countdown raises the clock even though the body is a
            // still picture — which is the case a running timer beside a paused track produces.
            guard let value = stage.content(for: slot).value, value.isTimeDependent else {
                continue
            }
            // The equaliser used to raise the whole tree's clock to its own frame rate. It does
            // not run on any clock of ours now — it is six `CALayer`s animated by the render server
            // (`NowPlayingEqualiserView`), so this loop has nothing to raise for it at any Reduce
            // Motion setting. Two measurements got it there: ticking the shared clock at the bars'
            // rate invalidates every view on the island and cost 2.8% of a core, and redrawing it
            // alone through `Canvas`/`TimelineView` cost 17.7% and 279MB. What is left here is the
            // scrubber and the numerals, which change once a second.
            rate = rate.combined(with: .seconds)
        }
        return rate
    }

    /// Frames per second for the Now Playing equaliser.
    ///
    /// Retired twice, and the second time is the one to read. Sampling the bars off this shared
    /// clock cost 2.8% of a core with a track playing, because it invalidates the island's whole
    /// content tree at the bars' rate — so the equaliser was given a clock of its own. That clock
    /// then cost **17.7% and 279MB**, because per-frame drawing through SwiftUI's `Canvas`/
    /// `TimelineView` is expensive out of all proportion to the size of the thing drawn. It has no
    /// clock at all now: the bars are `CALayer`s and the render server animates them.
    ///
    /// Left as a note rather than deleted silently, because "raise the shared clock rate" is the
    /// obvious first idea for anything else that wants to move, and "give it its own display link"
    /// is the obvious second one. Both are wrong. See PERF.md's 9.6 correction.

    /// Applies a change to the inputs and animates whatever presentation change falls out of it.
    ///
    /// Growing and shrinking use different tokens on purpose (§6.1): `expand` is looser so the
    /// island arrives with a little life, `collapse` is snappier and better damped so closing feels
    /// decisive rather than like the island is falling back. Which one applies is decided by where
    /// the island *ends up*, not by which input changed — the pointer leaving an island that was
    /// never open should still feel like a collapse.
    ///
    /// An input can change without the presentation changing: the pointer arriving on an island
    /// that is already expanded records the hover, so a later collapse lands on `.peek` rather than
    /// `.rest`, but nothing moves and nothing is animated.
    ///
    /// The completion always fires, even when nothing changed, because the caller uses it to
    /// tighten the hit region back to the exact shape. Skipping it would leave the region widened.
    private func apply(
        hovering: Bool? = nil,
        expanded: Bool? = nil,
        hoveringArtwork: Bool? = nil,
        reduceMotion: Bool,
        completion: @escaping @MainActor () -> Void
    ) {
        let newHovering = hovering ?? isHovering
        let newExpanded = expanded ?? isExpanded
        let newHoveringArtwork = hoveringArtwork ?? isHoveringArtwork
        let before = presentation
        let after = IslandPresentation.resolve(isHovering: newHovering, isExpanded: newExpanded)

        // Compared as **forms**, not presentations.
        //
        // Both inputs this method changes reach the presentation, so today a form comparison and a
        // presentation comparison agree — the switcher row stopped moving with the pointer on
        // 2026-08-27 (`IslandForm.showsPageIndicator`) and the case that forced this no longer arises.
        // It stays a form comparison because the form is what the island's *geometry* is keyed on:
        // an input that moves the outline without moving the presentation is exactly what
        // `showsPageIndicator` was, it will not be the last one, and a presentation comparison takes the
        // early return on it — assigning the state outside any transaction, so the island snaps to
        // its new size with nothing to watch.
        let beforeForm = form
        let afterForm = IslandForm.resolve(
            isHovering: newHovering,
            isExpanded: newExpanded,
            flanks: flanks,
            hasPageIndicator: hasPageIndicator,
            showsTrackLip: newHoveringArtwork && trackLipContent != nil
        )

        guard beforeForm != afterForm else {
            isHovering = newHovering
            isExpanded = newExpanded
            isHoveringArtwork = newHoveringArtwork
            completion()
            return
        }

        // **Which token is decided by the direction the island's *edge* moves**, not by which input
        // changed — the rule this file already follows, taken one step further because the island
        // has more than one way to grow.
        //
        // Down is `Motion.reveal`: the peek, the open, and the track lip are all the notch dropping
        // out of the bezel, and they now overshoot slightly and settle rather than arriving flat.
        // Sideways is still `expand`, because that same bounce applied to a widen is a wobble.
        // Up is still `collapse`, which should feel decisive.
        //
        // Compared as *heights of the two forms* rather than as a list of the changes that happen
        // to grow downward today. A list would be a second copy of the shape table, and it would be
        // wrong the first time a form was added — which has happened twice this month.
        let growsDownward = metrics(for: afterForm).bodySize.height
            > metrics(for: beforeForm).bodySize.height

        let token: Animation
        if growsDownward {
            token = Motion.reveal
        } else if before == after {
            // The form moved while the presentation did not — an outline change that is not an
            // open, a close or a peek. `Motion.expand` in **both** directions: a change of this
            // kind is one gesture answered twice, and giving the retraction the tighter `collapse`
            // made it read as a different, brisker event than the thing it was undoing.
            token = Motion.expand
        } else {
            token = Self.isGrowing(from: before, to: after) ? Motion.expand : Motion.collapse
        }
        withAnimation(Motion.respectingReduceMotion(token, reduceMotion: reduceMotion)) {
            isHovering = newHovering
            isExpanded = newExpanded
            isHoveringArtwork = newHoveringArtwork
        } completion: {
            completion()
        }
        followWithContent(to: form, reduceMotion: reduceMotion)
    }

    /// §6.2: the container leads, the content follows by `Motion.contentFollowDelay`.
    ///
    /// Started *after* the container's animation is committed, so the 40ms is measured from the
    /// frame the container starts moving on rather than from an arbitrary point in this method.
    ///
    /// The delay is a one-shot `Task.sleep`, not a `Timer` and not a poll (§9): one exists for
    /// 40ms per transition and none at any other time. It is canceled by the next transition,
    /// which matters for a pointer that crosses the island and leaves again inside 40ms — without
    /// the cancel, the outgoing hop would land after the incoming one and leave the content laid
    /// out for a state the island is no longer in.
    ///
    /// Reduce motion skips the delay entirely. The substitution §6.3 asks for is a crossfade, and a
    /// crossfade that starts 40ms after the thing it is crossfading from has already changed size
    /// is a two-step animation — which is the thing being substituted *away* from.
    private func followWithContent(to target: IslandForm, reduceMotion: Bool) {
        contentFollow?.cancel()
        contentFollow = nil
        guard contentForm != target else { return }

        guard !reduceMotion else {
            withAnimation(Motion.respectingReduceMotion(Motion.contentSwap, reduceMotion: true)) {
                contentForm = target
            }
            return
        }

        contentFollow = Task { [weak self] in
            try? await Task.sleep(for: Motion.contentFollowDelay)
            guard !Task.isCancelled, let self else { return }
            withAnimation(Motion.contentSwap) {
                self.contentForm = target
            }
        }
    }

    static func isGrowing(from: IslandPresentation, to: IslandPresentation) -> Bool {
        func rank(_ presentation: IslandPresentation) -> Int {
            switch presentation {
            case .rest: 0
            case .peek: 1
            case .expanded: 2
            }
        }
        return rank(to) > rank(from)
    }
}
