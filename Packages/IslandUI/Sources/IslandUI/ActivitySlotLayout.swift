import CoreGraphics
import IslandActivities
import IslandKit

/// Where each of an activity's four slots can be drawn inside the island body.
///
/// ## The problem this exists to solve
///
/// On a Mac with a real notch the island body is not all screen. The physical cutout is a hole in
/// the panel: it has no pixels, it cannot be lit, and anything positioned there is simply not
/// there. So the island's drawable area is the body **minus** the cutout, and that is two slivers
/// of lit pixels either side of the hole plus whatever hangs below it. `leading` and `trailing` are
/// those slivers — they sit *beside* the notch, never inside it — and the expanded body content
/// lives underneath.
///
/// That geometry is why the four slots are not four styles of the same thing. Which slots exist at
/// all is a property of the island's size relative to the cutout:
///
/// | State (14" MacBook Pro) | body | flank each side | below the cutout |
/// |---|---|---|---|
/// | rest | 185x32 | 0 | 0 |
/// | peek | 197x40 | 6 | 8 |
/// | **flanked rest** | **265x32** | **40** | **0** |
/// | **flanked peek** | **277x40** | **46** | **8** |
/// | **wide flanked rest** | **401x32** | **108** | **0** |
/// | **wide flanked peek** | **413x40** | **114** | **8** |
/// | expanded | 380x140 | 97.5 | 108 |
///
/// **With nothing on stage the island is the cutout, so nothing can be drawn at all** — which is
/// the same fact that makes the island invisible at rest, seen from the content's side. Peek adds
/// 6pt of flank and 8pt of body, neither of which fits a glyph.
///
/// That is why the *flanked* rows exist. `IslandLayout.flankedWidthGrowth` widens the resting body
/// by a constant 80pt whenever the presented activity has something to say in a flank, which buys
/// two 40pt slivers of real screen and makes a track change visible with no click. It is extra
/// constant shapes, not sizing from content: `islandPath` has to track a settled shape for hit
/// testing to stay exact.
///
/// The *wide flanked* rows are the same move again for an activity that says what it is in a word
/// rather than a glyph — `ActivityKind.flankSpan`, which is the system HUDs and power and nothing
/// else. 108pt each side holds a HUD's glyph, 4pt of spacing and the longest noun the shipped
/// languages produce; the *wider* rows hold 137, which is what power's phrases need beside a battery
/// glyph 3pt wider than any HUD's. Which of the four spans is in force is `ActivityStage.flanks`,
/// asked of the *pair*, and of the sliver that actually carries the word.
///
/// The body region below the cutout stays unafforded in every collapsed state on purpose —
/// `flankedHeightGrowth` is zero at every span, so a strip of text can never hang under the notch
/// at rest.
///
/// A synthesized island (a notchless display, §4.3) has no hole, so `cutoutSize` is `.zero`, there
/// are no flanks to speak of, and the whole body is drawable. That is the case `compact` is for:
/// one badge, because there is nothing to flank.
///
/// ## Computed from the *content's* metrics, not the target's
///
/// `IslandScreenModel.contentMetrics` is the size the content is laid out for, which lags the
/// container by `Motion.contentFollowDelay` (§6.2). Resolving against the container's target size
/// instead would move the compact badge into the expanded body's position 40ms before it became
/// the expanded badge — the content would arrive before the container, which is the exact ordering
/// §6.2 forbids.
public struct ActivitySlotLayout: Equatable, Sendable {

    /// Narrowest flank worth drawing into: a 13pt SF Symbol is about 15pt wide, and
    /// `ActivityContentView` insets a flank by 10pt at each end. Below this the glyph either clips
    /// against the cutout or touches the island's outer edge, and a glyph touching the edge of a
    /// black shape on a black bezel reads as a rendering fault rather than as content.
    ///
    /// Only ever evaluated at a settled size, never mid-morph: the layout resolves against
    /// `contentMetrics`, which steps between the five forms rather than sweeping through them, so
    /// no threshold here can pop while the island is moving.
    ///
    /// This is the number `IslandLayout.flankedWidthGrowth` was chosen to satisfy — it is the floor
    /// the flanked resting island has to clear for its slivers to be worth having.
    public static let minimumFlankWidth: CGFloat = 34

    /// Shortest below-the-cutout strip worth drawing into: a 12pt line plus 5pt above and below.
    public static let minimumBodyHeight: CGFloat = 22

    public let bodySize: CGSize

    /// The cutout in the body's own y-down space, top-centerd. `nil` when there is no hole —
    /// a synthesized island, where every pixel of the body is real.
    public let cutout: CGRect?

    /// The lit sliver left of the cutout, or `nil` when it is too narrow to draw into.
    public let leading: CGRect?

    /// The lit sliver right of the cutout, or `nil` when it is too narrow to draw into.
    public let trailing: CGRect?

    /// Everything below the cutout — or the whole body when there is no cutout. `nil` when it is
    /// too short to draw into.
    public let body: CGRect?

    /// Both flanks are drawable. Deliberately all-or-nothing: one flank without the other is a
    /// lopsided island, and the slivers are symmetric by construction anyway.
    public var affordsFlanks: Bool { leading != nil && trailing != nil }

    public var affordsBody: Bool { body != nil }

    /// Nothing can be drawn at this size. The island is the cutout, or close enough to it.
    ///
    /// True of every collapsed *unflanked* state and of nothing else, which is now a statement
    /// about an island with nothing to say rather than about the island in general: an activity
    /// with flank content puts the island in a flanked form, where this is false.
    public var isBlind: Bool { !affordsFlanks && !affordsBody }

    /// - Parameters:
    ///   - bodySize: the island body, from the metrics the *content* is laid out for.
    ///   - cutoutSize: the physical hole, or `.zero` on a synthesized island.
    public static func resolve(bodySize: CGSize, cutoutSize: CGSize) -> Self {
        let width = max(0, bodySize.width)
        let height = max(0, bodySize.height)

        // The body is centerd on the cutout by construction: `IslandLayout.panelFrame` centers the
        // panel on the notch and `IslandLayout.bodyOrigin` centers the body in the panel. Clamped
        // rather than trusted, because a notch near a display edge would clamp the panel and leave
        // the two off-center, and a negative flank width would silently invert the rects.
        let cutoutWidth = min(max(0, cutoutSize.width), width)
        let cutoutHeight = min(max(0, cutoutSize.height), height)

        let cutout: CGRect? = (cutoutWidth > 0 && cutoutHeight > 0)
            ? CGRect(x: (width - cutoutWidth) / 2, y: 0, width: cutoutWidth, height: cutoutHeight)
            : nil

        let flankWidth = ((cutout?.minX) ?? 0)
        let flankHeight = cutout?.height ?? 0
        let hasFlanks = cutout != nil && flankWidth >= minimumFlankWidth && flankHeight > 0

        let bodyTop = cutout?.maxY ?? 0
        let bodyHeight = height - bodyTop
        let hasBody = bodyHeight >= minimumBodyHeight && width > 0

        return Self(
            bodySize: CGSize(width: width, height: height),
            cutout: cutout,
            leading: hasFlanks ? CGRect(x: 0, y: 0, width: flankWidth, height: flankHeight) : nil,
            trailing: hasFlanks
                ? CGRect(x: width - flankWidth, y: 0, width: flankWidth, height: flankHeight)
                : nil,
            body: hasBody ? CGRect(x: 0, y: bodyTop, width: width, height: bodyHeight) : nil
        )
    }

    /// The cutout to resolve against, for a screen's notch.
    ///
    /// Forwards to `NotchGeometry.cutoutSize`, which is where the rule lives now: the open island's
    /// *height* has to subtract the same hole this layout does, and that arithmetic is in IslandKit.
    /// Kept as a name here because it is the one this package's call sites read by.
    public static func cutoutSize(for notch: NotchGeometry) -> CGSize {
        notch.cutoutSize
    }

    /// Which slots this layout can actually show, for a given island presentation.
    ///
    /// The rule the four-slot vocabulary implies (see `ActivityPresentations`): the flanks are
    /// drawn whenever there are flanks to draw in, and the body region carries whichever of
    /// `compact` / `expanded` the presentation calls for. `compact` is therefore the single badge
    /// that appears when there are no flanks — a synthesized island, or one not yet wide enough to
    /// have slivers — rather than an alternative to them.
    ///
    /// Returns the slots in draw order, and only those with something in them: an empty
    /// `ActivityContent` draws as nothing at all, never as a reserved gap.
    public func visibleSlots(
        for presentation: IslandPresentation,
        in presentations: ActivityPresentations,
        showsTrackLip: Bool = false
    ) -> [ActivitySlot] {
        var slots: [ActivitySlot] = []
        let body = bodySlot(for: presentation, in: presentations, showsTrackLip: showsTrackLip)

        // The flanks are what the island says when it has no room to say more. Once it is open, the
        // body says all of it — so repeating the cover and the equaliser in the slivers beside the
        // cutout is the same content twice, 40pt apart, which reads as a rendering fault rather than
        // as emphasis. Collapsed, the flanks are the whole presentation and still carry it.
        //
        // **Asked of the presentation, not of the body slot.** It used to read `body != .expanded`,
        // and `bodySlot` answers nil when `presentations.expanded` is empty — which is the case for
        // every surface that draws its open body with a layer of its own rather than through
        // `ActivityContent`: the glance, Now Playing, the shelf, the switcher, the drop history.
        // For all of those the rule never fired, so an open island kept its slivers and said the
        // same thing twice: the glance drew "☀ 84°" in its header and again in the sliver a few
        // points above it. Reported from hardware.
        if affordsFlanks, presentation != .expanded {
            if !presentations.leading.isEmpty { slots.append(.leading) }
            if !presentations.trailing.isEmpty { slots.append(.trailing) }
        }
        if let body { slots.append(body) }
        return slots
    }

    /// The same question asked of a **pair**, where the two slivers can belong to different
    /// activities.
    ///
    /// Not an overload that forwards to the single-activity one with the primary's presentations:
    /// that is precisely the call that drops the companion, and it would compile and very nearly
    /// work — the flanks would draw the primary's content in both, which looks like the pair having
    /// silently not formed.
    public func visibleSlots(
        for presentation: IslandPresentation,
        in stage: ActivityStage,
        showsTrackLip: Bool = false
    ) -> [ActivitySlot] {
        var slots: [ActivitySlot] = []
        let body = bodySlot(
            for: presentation, in: stage.primary.presentations, showsTrackLip: showsTrackLip
        )

        if affordsFlanks, presentation != .expanded {
            for flank in [ActivitySlot.leading, .trailing] where !stage.content(for: flank).isEmpty {
                slots.append(flank)
            }
        }
        if let body { slots.append(body) }
        return slots
    }

    /// Which of `compact` and `expanded` the body region carries, or nil if there is no body region
    /// or nothing to put in it.
    ///
    /// Separate from `visibleSlots` because the renderer needs this one on its own: the two body
    /// slots are the branches of a single condition in `ActivityLayerView`, and that is what keeps
    /// the compact-to-expanded `matchedGeometryEffect` down to one claimant at a time.
    /// - Parameter showsTrackLip: whether the body region is the **track lip's** (see
    ///   `IslandForm.showsTrackLip`), in which case there is no body slot: the lip is the only
    ///   reason a collapsed island has a body region at all, and the region is already spoken for.
    ///
    ///   Its own parameter rather than being left to the renderer, because the renderer is not the
    ///   only caller — `needsClock` asks the same question to decide whether a display link runs,
    ///   and a second copy of the rule in one of them is a second place for it to be wrong. Without
    ///   this the answer is `.compact` the moment the lip clears `minimumBodyHeight`, and the
    ///   activity's badge is drawn in the rectangle the lip is already using.
    public func bodySlot(
        for presentation: IslandPresentation,
        in presentations: ActivityPresentations,
        showsTrackLip: Bool = false
    ) -> ActivitySlot? {
        guard affordsBody, !showsTrackLip else { return nil }
        let slot: ActivitySlot = presentation == .expanded ? .expanded : .compact
        return slot.content(of: presentations).isEmpty ? nil : slot
    }

    /// The region a slot occupies, in the body's y-down space.
    public func frame(for slot: ActivitySlot) -> CGRect? {
        switch slot {
        case .leading: leading
        case .trailing: trailing
        case .compact, .expanded: body
        }
    }
}

/// Which of an activity's four presentations is being drawn, and therefore how.
///
/// `ActivityPresentations` stores the four as properties rather than as a keyed collection, which
/// is right for the model — they are not interchangeable — but the renderer does need to talk about
/// "the slot currently being drawn". This is that, and it lives here rather than in IslandActivities
/// because the *styling* differences between the four are entirely IslandUI's business.
public enum ActivitySlot: Hashable, Sendable, CaseIterable {
    case leading
    case trailing
    case compact
    case expanded

    public func content(of presentations: ActivityPresentations) -> ActivityContent {
        switch self {
        case .leading: presentations.leading
        case .trailing: presentations.trailing
        case .compact: presentations.compact
        case .expanded: presentations.expanded
        }
    }

    /// Which sliver this slot is, or nil for the two body slots.
    ///
    /// The bridge between IslandUI's four-case slot and IslandActivities' two-case
    /// `ActivityFlank` — which are deliberately different types (see `ActivityFlank`), and this is
    /// the one place they meet.
    public var flank: ActivityFlank? {
        switch self {
        case .leading: .leading
        case .trailing: .trailing
        case .compact, .expanded: nil
        }
    }
}

extension ActivityStage {

    /// What to draw in a slot: a flank from whoever owns it, the body always from the primary.
    ///
    /// This is the per-slot half of the pair. Everything before it asked one activity for all four
    /// slots, which is exactly the assumption a companion breaks.
    public func content(for slot: ActivitySlot) -> ActivityContent {
        guard let flank = slot.flank else { return slot.content(of: primary.presentations) }
        return content(on: flank)
    }

    /// Which kind draws a slot — the input to the one bespoke-renderer `if` in `ActivityLayerView`.
    ///
    /// **Asked per slot, never once per island.** Before the pair there was a single presented kind
    /// and every slot came from it; with a companion, a timer beside music would be handed to
    /// `NowPlayingSlotView` and drawn as a cover and an equaliser. That failure renders plausibly —
    /// a view appears, in the right sliver, in the right size — which is why it is worth its own
    /// method rather than an inline ternary.
    public func kind(for slot: ActivitySlot) -> ActivityKind {
        guard let flank = slot.flank else { return primary.kind }
        return activity(on: flank).kind
    }
}

extension ActivityValue {

    /// Whether drawing this value means redrawing it as the clock moves.
    ///
    /// The one input to whether a display link runs at all (§9). A fraction is a snapshot and an
    /// indeterminate value carries no number, so both are drawn once and left alone; only a
    /// countdown or an elapsed time is a function of `now`.
    public var isTimeDependent: Bool {
        switch self {
        case .countdown, .elapsed: true
        case .fraction, .indeterminate: false
        // A paused track is a still picture, and this is what makes it one for free. `rate` zero
        // means `position(at:)` returns the same number forever, so there is nothing for a display
        // link to redraw — the scrub bar holds, the numerals hold, and the equaliser freezes exactly
        // where it was. No case for pausing exists anywhere else in the render path because of it.
        case .timeline(let timeline): timeline.isAdvancing
        }
    }
}

extension ActivitySlotLayout {

    /// Whether anything currently on screen has to be redrawn as the clock moves.
    ///
    /// Asked of the *visible* slots rather than of the activity, because a countdown sitting in an
    /// `expanded` presentation that nobody has opened is not on screen and must not cost a display
    /// link. §9's rule is "no polling when idle", and an unopened island is idle.
    public func needsClock(
        for presentation: IslandPresentation,
        in stage: ActivityStage?,
        showsTrackLip: Bool = false
    ) -> Bool {
        guard let stage else { return false }
        return visibleSlots(
            for: presentation, in: stage, showsTrackLip: showsTrackLip
        ).contains { slot in
            stage.content(for: slot).value?.isTimeDependent == true
        }
    }
}
