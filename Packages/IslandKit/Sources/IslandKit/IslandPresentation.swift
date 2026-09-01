import CoreGraphics

/// What the island is currently showing.
///
/// Deliberately *derived* rather than stored. Hovering and being open are independent facts — the
/// pointer can arrive and leave while the island is expanded, and the island can be opened by a
/// keyboard shortcut with the pointer nowhere near it. Storing a single state and mutating it from
/// both sources is how you end up expanded-but-considered-resting, or collapsing an open island
/// because the pointer wandered off. `IslandScreenModel` keeps the two inputs and computes this.
public enum IslandPresentation: Equatable, Sendable, CaseIterable {

    /// Flush with the notch. On a notched Mac this is invisible by design.
    case rest

    /// The pointer has arrived. The island swells just past the notch to say it is there and
    /// clickable — an invitation, not the result of a click.
    case peek

    /// Opened. This is the click's result.
    case expanded

    /// The presentation implied by the two inputs that drive it.
    ///
    /// Expansion wins: an open island does not shrink back to a peek because the pointer left, and
    /// it does not grow when the pointer returns.
    public static func resolve(isHovering: Bool, isExpanded: Bool) -> Self {
        if isExpanded { return .expanded }
        return isHovering ? .peek : .rest
    }
}

/// How much lit island there is either side of the cutout.
///
/// A *span*, not a flag, and it is the flank axis of `IslandForm` rather than a second axis beside
/// it — `.wide` is what `.standard` is, further out. Written as three cases and not two booleans
/// because "wide but not flanked" is not a shape the island has any way to be in, and a pair of
/// booleans is exactly the encoding that lets a table say so.
///
/// Ordered, and the ordering is load-bearing: `IslandLayout.metrics` is monotone in this input, so
/// `IslandShapeMetrics.union` of any two forms still contains every shape between them. That is the
/// property the widen-then-tighten protocol rests on (see `IslandController.widenHitRegionForTransition`).
public enum IslandFlanks: String, Hashable, Sendable, CaseIterable, Comparable {

    /// The island is the cutout. Nothing is drawn beside the hole because there is nothing there.
    case none

    /// A sliver each side, wide enough for one glyph: `IslandLayout.flankedWidthGrowth`.
    case standard

    /// A sliver each side wide enough for a glyph **and the word beside it** —
    /// `IslandLayout.wideFlankedWidthGrowth`. For the activities that say what they are in the
    /// slivers rather than only showing it: see `ActivityKind.flankSpan`.
    case wide

    /// The same, for the kinds whose word is a **phrase** rather than a noun —
    /// `IslandLayout.widerFlankedWidthGrowth`. Power, and nothing else: "On Battery" and
    /// "Sparmodus aus" are the sentences the machine has about its own charge, and there is no
    /// shorter honest spelling of them.
    ///
    /// **A fourth span rather than one shared wide one**, because the two are sized to different
    /// words and a shape carrying "Volume" has no business being as wide as one carrying
    /// "Batteriebetrieb". Sharing the constant would have grown the HUD island by 29pt a side to
    /// hold a word 43pt long, which is the "black bar that happens to contain the notch" failure
    /// `IslandLayout.flankedWidthGrowth` names, paid for by the kind that does not need it. Four
    /// discrete shapes on this axis is still a table and not a continuum — `islandPath` settles on
    /// one of them exactly as it settled on one of three (§4.2).
    case wider

    private var rank: Int {
        switch self {
        case .none: 0
        case .standard: 1
        case .wide: 2
        case .wider: 3
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

/// The full key to the island's geometry: what it is showing, plus whether it is carrying content
/// in the slivers beside the cutout.
///
/// ## Why this is not a fourth `IslandPresentation` case
///
/// Flanked-ness is an **input**, exactly like hovering and being expanded — it is a fact about what
/// the coordinator has on stage, not a state the island is put into. Adding `.flankedRest` and
/// `.flankedPeek` to `IslandPresentation` would make it one, and every `switch` on presentation
/// would then have to remember that two of its five cases mean "resting" — starting with
/// `ActivityPresentations.content(for:)`, which maps rest and peek to the same slot precisely
/// because they are the same presentation. So the enum keeps meaning one thing and this pairs it
/// with the second input, resolved the same way `IslandPresentation.resolve(isHovering:isExpanded:)`
/// resolves the first two: derived on demand, never stored.
///
/// ## Why the open island is never flanked
///
/// `flanks` is forced to `.none` at `.expanded`. The open island is 368pt wide against a 185pt
/// cutout, so it already has ~92pt of lit sliver either side — carrying the span through would give
/// one geometry three dictionary keys. Two keys for one shape is how a lookup starts silently
/// missing and the island snaps to its fallback mid-morph.
///
/// It stays true now that `.wide` is wider than the open island: the wide *collapsed* forms are real
/// shapes and are in `allCases`, but an island that has opened is one shape whatever is on stage.
public struct IslandForm: Hashable, Sendable, CaseIterable {

    public let presentation: IslandPresentation

    /// How far the resting island is widened to make room for the flank slots.
    ///
    /// On a Mac the cutout is a hole: at rest the island *is* the cutout, so a presented activity
    /// has no lit pixel to draw on and is invisible until someone clicks. Widening the resting body
    /// by a constant `IslandLayout.flankedWidthGrowth` buys two slivers of real screen either side
    /// of the hole — enough for one glyph each — which is what makes a track change visible without
    /// the user doing anything.
    ///
    /// **Three values and not two, since 2026-08-28.** A glyph says *that* something happened; a
    /// volume key says something the glyph alone cannot distinguish from a brightness key at a
    /// glance, so those activities spell it — and `IslandLayout.wideFlankedWidthGrowth` is the
    /// second constant that buys room for the word. Still constants, still not sizing from content:
    /// there are three shapes on this axis, not a continuum, which is what keeps `islandPath`
    /// settling on a shape hit testing can be exact about (§4.2).
    public let flanks: IslandFlanks

    /// Whether there are slivers at all — the question everything outside the shape table asks.
    public var isFlanked: Bool { flanks != .none }

    /// Whether the open island is grown to make room for the switcher row.
    ///
    /// True for the whole time the island is open and has anything to put in the row, and the
    /// island grows downward to fit it.
    ///
    /// **It used to be the pointer that revealed it**, on the argument that a permanent strip read
    /// as dead space under an island already as tall as the Now Playing player. That is the wrong
    /// trade, and it is the same one this row has already lost twice: the bell is drawn whether or
    /// not anything is in it, and the gear is drawn whether or not the roster overflows, both
    /// because *a control that is sometimes there is one a person cannot learn the position of*.
    /// A row gated on hover is every control in it sometimes there — and on the island the pointer
    /// is already resting on, which is the only island there is, the reveal was a strip appearing
    /// and vanishing under the hand rather than an affordance. The owner's verdict, 2026-08-27:
    /// it should always be there.
    ///
    /// Forced false unless the island is open, exactly as `isFlanked` is forced false when it *is*
    /// open: the two are the same kind of rule, and both exist so a form cannot describe a shape the
    /// island has no way to be in. Its own field rather than reusing the spare `isFlanked` axis —
    /// one field meaning two things depending on a third is how a shape table starts lying.
    public let showsPageIndicator: Bool

    /// Whether the peeked island is wearing the lip that says what is playing.
    ///
    /// The strip of island that springs out under the cutout while the pointer is on the album
    /// cover, carrying the track's title and its artist. A fourth input, and a fourth axis for the
    /// same reason `showsPageIndicator` is its own field rather than a second reading of `isFlanked`:
    /// one field meaning two things depending on a third is how a shape table starts lying.
    ///
    /// ## Why this is allowed to hang below the cutout when `flankedHeightGrowth` is not
    ///
    /// `IslandLayout.flankedHeightGrowth` is zero on purpose, and its note says why: a strip of
    /// text hanging under the notch *at rest* is a panel, not a notch. That objection is about
    /// rest, and it still stands. This is the opposite case — the island is under the pointer, it
    /// has already peeked, and the strip is the answer to a question the user asked by putting the
    /// pointer on the cover. It goes away the moment they take it off again.
    ///
    /// Forced false unless the island is **peeking and flanked**, exactly as `isFlanked` is forced
    /// false when the island is open. A resting island has not been asked anything, an open one is
    /// already drawing the title in its header, and an unflanked one has no cover to hover: none of
    /// the three is a shape the island has any way to be in, so none of them is representable.
    public let showsTrackLip: Bool

    public init(
        presentation: IslandPresentation,
        flanks: IslandFlanks = .none,
        showsPageIndicator: Bool = false,
        showsTrackLip: Bool = false
    ) {
        self.presentation = presentation
        self.flanks = presentation == .expanded ? .none : flanks
        self.showsPageIndicator = presentation == .expanded ? showsPageIndicator : false
        self.showsTrackLip = (presentation == .peek && flanks != .none) ? showsTrackLip : false
    }

    public static let rest = Self(presentation: .rest)
    public static let peek = Self(presentation: .peek)
    public static let expanded = Self(presentation: .expanded)
    public static let flankedRest = Self(presentation: .rest, flanks: .standard)
    public static let flankedPeek = Self(presentation: .peek, flanks: .standard)

    /// The resting and peeking island with room for a word beside the glyph. See `IslandFlanks.wide`.
    public static let wideFlankedRest = Self(presentation: .rest, flanks: .wide)
    public static let wideFlankedPeek = Self(presentation: .peek, flanks: .wide)

    /// The peeked island wearing the track lip — the pointer is on the album cover. See
    /// `showsTrackLip`.
    public static let flankedPeekWithLip = Self(
        presentation: .peek, flanks: .standard, showsTrackLip: true
    )

    /// The same, on a wide island.
    ///
    /// **Reachable only through a pair.** The lip is Now Playing's and the wide flanks belong to
    /// whatever names itself in a sliver, so this is music in one sliver and a HUD in the other with
    /// the pointer on the cover. Nothing in the vocabulary produces it today — a HUD outranks music,
    /// so it takes the *leading* sliver its kind prefers and the cover is not there to hover — and
    /// the row exists anyway, because a form that `resolve` can return and the shape table has no
    /// key for is an island that snaps to the unflanked fallback mid-morph.
    public static let wideFlankedPeekWithLip = Self(
        presentation: .peek, flanks: .wide, showsTrackLip: true
    )

    /// The three shapes of the widest island there is — power spelling what the charger just did.
    /// See `IslandFlanks.wider`.
    ///
    /// The lip form is here for `wideFlankedPeekWithLip`'s reason and is as unreachable: it is music
    /// in one sliver and power in the other with the pointer on the album cover, and power prefers
    /// the *trailing* sliver, so the word is not drawn and the island does not widen for it. A form
    /// `resolve` can return and the shape table has no key for is an island that snaps to the
    /// unflanked fallback mid-morph, so the row exists whether or not anything reaches it.
    public static let widerFlankedRest = Self(presentation: .rest, flanks: .wider)
    public static let widerFlankedPeek = Self(presentation: .peek, flanks: .wider)
    public static let widerFlankedPeekWithLip = Self(
        presentation: .peek, flanks: .wider, showsTrackLip: true
    )

    /// The open island wearing the switcher row. The shape of every open island with something to
    /// put in the row, which is nearly all of them — see `showsPageIndicator`.
    public static let expandedWithPageIndicator = Self(presentation: .expanded, showsPageIndicator: true)

    /// The thirteen distinct shapes the island has. Not every combination of the four inputs: the open
    /// island is never flanked, only the open island can wear the switcher row, and only a flanked
    /// peek can wear the track lip.
    ///
    /// **Every form `resolve` can return has to be in here**, because this is what the app shell
    /// builds its shape table from — a missing key falls back to the unflanked shape at the same
    /// presentation (`IslandScreenModel.metrics(for:)`), which is an island snapping narrow in the
    /// middle of a morph.
    public static let allCases: [Self] = [
        .rest, .flankedRest, .wideFlankedRest, .widerFlankedRest,
        .peek, .flankedPeek, .wideFlankedPeek, .widerFlankedPeek,
        .flankedPeekWithLip, .wideFlankedPeekWithLip, .widerFlankedPeekWithLip,
        .expanded, .expandedWithPageIndicator,
    ]

    /// The form implied by the four inputs that drive it.
    ///
    /// The same contract as `IslandPresentation.resolve`, extended rather than duplicated: nothing
    /// here is remembered, so there is no way for the island to be flanked while nothing is on
    /// stage, or to be holding a row open with the pointer somewhere else.
    ///
    /// - Parameter hasPageIndicator: whether there is anything to put in the row. With nothing to
    ///   put in it the island does not grow, because 42pt of empty strip is not a control set — it
    ///   is the dead space the hover reveal was invented to avoid, and the only case where that
    ///   objection was ever right.
    ///
    /// **`isHovering` reaches the presentation and stops there.** The row is not the pointer's to
    /// reveal; it belongs to the open island for as long as it is open. See `showsPageIndicator`.
    /// - Parameter showsTrackLip: whether the pointer is on the album cover and the island should
    ///   be carrying the track lip. Reaches the form and stops there, like `hasPageIndicator`:
    ///   the constructor discards it in every state that cannot draw one.
    public static func resolve(
        isHovering: Bool,
        isExpanded: Bool,
        flanks: IslandFlanks,
        hasPageIndicator: Bool = false,
        showsTrackLip: Bool = false
    ) -> Self {
        Self(
            presentation: IslandPresentation.resolve(isHovering: isHovering, isExpanded: isExpanded),
            flanks: flanks,
            showsPageIndicator: hasPageIndicator,
            showsTrackLip: showsTrackLip
        )
    }

    /// The same form at a different presentation, keeping the other two inputs. Used where the
    /// presentation changes on its own — the content-follow delay, and asking for "the peek this
    /// island would grow into".
    public func with(presentation: IslandPresentation) -> Self {
        Self(
            presentation: presentation,
            flanks: flanks,
            showsPageIndicator: showsPageIndicator,
            showsTrackLip: showsTrackLip
        )
    }
}
