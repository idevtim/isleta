import CoreGraphics
import IslandActivities
import IslandKit
import Testing

@testable import IslandUI

/// The lip that says what is playing, from the two ends IslandKit's `TrackLipTests` cannot reach:
/// whether the rows fit in the strip the shape grows, and whether the model puts one out for the
/// right island.
@Suite("The track lip")
@MainActor
struct TrackLipLayoutTests {

    private let cutout = CGSize(width: 185, height: 32)

    private func makeModel(flanked: Bool = true) -> IslandScreenModel {
        let model = IslandScreenModel(
            metricsByForm: [
                .rest: IslandShapeMetrics(bodySize: CGSize(width: 185, height: 32), topCornerRadius: 0, bottomCornerRadius: 12),
                .peek: IslandShapeMetrics(bodySize: CGSize(width: 197, height: 40), topCornerRadius: 0, bottomCornerRadius: 12),
                .flankedRest: IslandShapeMetrics(bodySize: CGSize(width: 265, height: 32), topCornerRadius: 0, bottomCornerRadius: 12),
                .flankedPeek: IslandShapeMetrics(bodySize: CGSize(width: 277, height: 40), topCornerRadius: 0, bottomCornerRadius: 12),
                .flankedPeekWithLip: IslandShapeMetrics(
                    bodySize: CGSize(width: 277, height: 40 + IslandLayout.trackLipHeight),
                    topCornerRadius: 0,
                    bottomCornerRadius: 18
                ),
                .expanded: IslandShapeMetrics(bodySize: CGSize(width: 380, height: 140), topCornerRadius: 0, bottomCornerRadius: 22),
            ],
            notchKind: .hardware,
            cutoutSize: cutout
        )
        if flanked {
            model.setActivity(
                BuiltInActivity.nowPlaying(title: "A Song", artist: "A Band").presentations,
                kind: .nowPlaying,
                change: .presented("stub"),
                reduceMotion: true
            )
        }
        return model
    }

    private func settle(_ body: (@escaping @MainActor () -> Void) -> Void) async {
        await withCheckedContinuation { continuation in
            body { continuation.resume() }
        }
    }

    /// The height the *shape* grows by and the height the *rows* take are two numbers that have to
    /// agree, in two packages that cannot see each other's constants. A strip a point short clips
    /// the artist's descenders, which reads as a rendering fault rather than as a sizing decision.
    @Test("the two lines fit the height the island grows by")
    func rowsFitTheStrip() {
        #expect(NowPlayingTrackLipLayout.contentHeight <= IslandLayout.trackLipHeight)
        // And not wastefully short either: a strip with 10pt of dead island under two lines of text
        // is a peek pretending to be an open island.
        #expect(IslandLayout.trackLipHeight - NowPlayingTrackLipLayout.contentHeight <= 4)
    }

    /// Growing the island is not the same as having somewhere to draw. `ActivitySlotLayout` is what
    /// decides the second, and it has a floor the lip has to clear or the strip is grown and left
    /// empty.
    @Test("the lip makes the body region drawable")
    func lipAffordsTheBody() {
        let withoutLip = ActivitySlotLayout.resolve(
            bodySize: CGSize(width: 277, height: 40), cutoutSize: cutout
        )
        let withLip = ActivitySlotLayout.resolve(
            bodySize: CGSize(width: 277, height: 40 + IslandLayout.trackLipHeight), cutoutSize: cutout
        )

        #expect(!withoutLip.affordsBody)
        #expect(withLip.affordsBody)
        // The flanks are untouched — the cover the pointer is on must not move under it.
        #expect(withLip.leading == withoutLip.leading)
        #expect(withLip.trailing == withoutLip.trailing)
    }

    /// The lip owns the body region outright: `bodySlot` has to answer nil for it, or the activity
    /// draws its compact badge in the rectangle the lip is already using. Asked of the layout and
    /// not of the renderer, because `needsClock` asks the same question to decide whether a display
    /// link runs — one rule, one place.
    @Test("the lip takes the body slot rather than sharing it")
    func lipOwnsTheBodyRegion() {
        let layout = ActivitySlotLayout.resolve(
            bodySize: CGSize(width: 277, height: 40 + IslandLayout.trackLipHeight), cutoutSize: cutout
        )
        let presentations = BuiltInActivity.nowPlaying(title: "A Song", artist: "A Band").presentations

        #expect(layout.bodySlot(for: .peek, in: presentations) == .compact)
        #expect(layout.bodySlot(for: .peek, in: presentations, showsTrackLip: true) == nil)
        #expect(
            layout.visibleSlots(for: .peek, in: presentations, showsTrackLip: true)
                == [.leading, .trailing]
        )
    }

    /// The strip has room for a title that is not a stub. Not a rule about the font — a rule about
    /// the island: a lip 40pt wide would be a marquee even for "Help!".
    @Test("the strip is wide enough to be worth reading")
    func stripIsWideEnough() {
        #expect(NowPlayingTrackLipLayout.textWidth(bodyWidth: 277) >= 240)
    }

    /// The lip is read from further away than anything else the island draws — the pointer is on a
    /// 24pt sleeve in a notch, and the eye is on whatever the user was actually working in. So its
    /// title is *larger* than the open island's subtitle rather than smaller, and its two lines
    /// still carry the hierarchy the open island spends a cover and a transport row on.
    @Test("the lip's type is sized to be read at a glance")
    func typeIsSizedForAGlance() {
        #expect(NowPlayingTrackLipLayout.titleFontSize > NowPlayingTrackLipLayout.artistFontSize)
        #expect(NowPlayingTrackLipLayout.titleFontSize >= 14)
        #expect(NowPlayingTrackLipLayout.artistFontSize >= 12)
    }

    /// The pointer on the cover puts the lip out, and taking it off takes it back in — with the
    /// island's own hover unchanged either way. The two are separate inputs: the pointer is still
    /// on the island when it steps off the sleeve.
    @Test("the pointer on the cover grows the lip and leaving it takes the lip back")
    func hoveringTheCoverGrowsTheLip() async {
        let model = makeModel()
        await settle { model.setHovering(true, reduceMotion: true, completion: $0) }
        #expect(model.form == .flankedPeek)
        #expect(!model.showsTrackLip)

        await settle { model.setHoveringArtwork(true, reduceMotion: true, completion: $0) }
        #expect(model.form == .flankedPeekWithLip)
        #expect(model.showsTrackLip)
        #expect(model.metrics.bodySize.height == 40 + IslandLayout.trackLipHeight)

        await settle { model.setHoveringArtwork(false, reduceMotion: true, completion: $0) }
        #expect(model.form == .flankedPeek)
        #expect(model.isHovering)
    }

    /// The lip belongs to a peeking island and to nothing else. Opening one already draws the title
    /// in its header, and a pointer that leaves the island entirely has taken its question with it
    /// — in both cases the stored input survives and the *form* is what refuses it, which is the
    /// whole reason the form is derived.
    @Test("no island but a flanked peek wears the lip")
    func onlyAPeekWearsTheLip() async {
        let model = makeModel()
        await settle { model.setHovering(true, reduceMotion: true, completion: $0) }
        await settle { model.setHoveringArtwork(true, reduceMotion: true, completion: $0) }
        #expect(model.showsTrackLip)

        await settle { model.setExpanded(true, reduceMotion: true, completion: $0) }
        #expect(!model.showsTrackLip)
        // Open islands always wear the page indicator now — see `IslandScreenModel.hasPageIndicator`.
        #expect(model.form == .expandedWithPageIndicator)

        await settle { model.setExpanded(false, reduceMotion: true, completion: $0) }
        #expect(model.showsTrackLip)

        // The island being swiped away empties its flanks, and a lip with no cover above it is a
        // strip of text hanging under the notch — which is exactly what `flankedHeightGrowth` is
        // zero to prevent.
        await settle { model.setStowed(true, reduceMotion: true, completion: $0) }
        #expect(!model.showsTrackLip)
        #expect(model.form == .peek)
    }

    /// Now Playing spends much of its life as the *companion* to whatever else is on stage, and the
    /// cover is in the leading sliver either way — so the lip is gated on the sliver the pointer is
    /// actually on, not on the primary. Gated on the primary it would refuse to grow under a cover
    /// that is plainly there; gated on nothing it would grow an empty strip on a timer's island.
    @Test("the lip follows the cover, not the primary")
    func lipFollowsTheCover() async {
        let model = makeModel(flanked: false)
        // A timer alone: no cover anywhere, so nothing to say and no lip to grow.
        model.setActivity(
            ActivityPresentations(
                leading: ActivityContent(symbol: "timer"),
                trailing: ActivityContent(symbol: "timer"),
                compact: ActivityContent(symbol: "timer", title: "Timer"),
                expanded: ActivityContent(symbol: "timer", title: "Timer")
            ),
            kind: .timer,
            change: .presented("stub"),
            reduceMotion: true
        )
        await settle { model.setHovering(true, reduceMotion: true, completion: $0) }
        await settle { model.setHoveringArtwork(true, reduceMotion: true, completion: $0) }
        #expect(model.trackLipContent == nil)
        #expect(!model.showsTrackLip)

        // Music takes the leading sliver, and the pointer has not moved.
        model.setActivity(
            BuiltInActivity.nowPlaying(title: "A Song", artist: "A Band").presentations,
            kind: .nowPlaying,
            change: .swapped(from: "stub", to: "stub"),
            reduceMotion: true
        )
        #expect(model.trackLipContent?.title == "A Song")
        #expect(model.showsTrackLip)
    }

    /// **The bug that made this a position rather than a tracking area.**
    ///
    /// A nested `NSTrackingArea` over the artwork hears only about crossings of its own rect, so
    /// arriving on the cover from outside the island worked — the island grew rest→peek, relaid the
    /// view out and re-read the pointer as a side effect — while sliding to it from the middle of
    /// the notch produced no layout pass, no crossing, and no lip. Reported exactly that way.
    ///
    /// The replacement is geometry, which is the half a test can actually hold: given a point, is
    /// it on the album's sliver? Asked here at the peeked size, which is where the pointer is when
    /// the question arises.
    @Test("the cover is answered from where the pointer is, wherever it came from")
    func artworkIsAPosition() async {
        let model = makeModel()
        await settle { model.setHovering(true, reduceMotion: true, completion: $0) }
        let panel = CGSize(width: 416, height: 400)
        let metrics = model.metrics
        let origin = IslandLayout.bodyOrigin(for: metrics, in: panel)

        // The middle of the cutout — the pointer has arrived on the island and is not on the cover.
        let middle = CGPoint(x: origin.x + metrics.bodySize.width / 2, y: origin.y + 16)
        #expect(!model.isPointOnAlbumArtwork(middle, inPanelOfSize: panel))

        // And the same island, 120pt to the left: the album's sliver, reached sideways from inside.
        let onCover = CGPoint(x: origin.x + 20, y: origin.y + 16)
        #expect(model.isPointOnAlbumArtwork(onCover, inPanelOfSize: panel))

        // Outside the island entirely, which is what a `nil` report resolves to in the shell.
        #expect(!model.isPointOnAlbumArtwork(.zero, inPanelOfSize: panel))
    }

    /// Nothing to say, nothing to point at. The same gate the shape is on, so the two cannot
    /// disagree about whether a pointer on the sliver means anything.
    @Test("a sliver with no track in it is not an album cover")
    func noTrackNoTarget() {
        let model = makeModel(flanked: false)
        let panel = CGSize(width: 416, height: 400)
        let origin = IslandLayout.bodyOrigin(for: model.metrics, in: panel)

        #expect(!model.isPointOnAlbumArtwork(CGPoint(x: origin.x + 20, y: origin.y + 16), inPanelOfSize: panel))
    }

    /// Every downward move the island makes is one curve, and the selector is the direction its
    /// bottom edge travels rather than a list of the changes that happen to go that way. A list
    /// would be a second copy of the shape table — and this one has gained two forms this month.
    @Test("the island's downward moves are one curve, and it is not a sideways one")
    func downwardMovesShareOneCurve() {
        #expect(Motion.reveal != Motion.expand)
        // A step below `nudge`, which moves a surface inside an island that is standing still. The
        // outline carries everything drawn in it, and `lockHandover` records what a large shape
        // overshooting as hard as a small one reads as.
        #expect(Motion.reveal != Motion.nudge)
    }

    /// The peek is the smallest downward move the island makes — 8pt — and it is the same movement
    /// as the open and the lip, so it travels the same curve. It arrived last, on the owner's
    /// verdict that anything coming down out of the bezel should overshoot a little.
    @Test("the peek and the open come down on the same curve as the lip")
    func peekAndOpenSpringToo() async {
        let model = makeModel()
        let rest = model.metrics.bodySize.height

        await settle { model.setHovering(true, reduceMotion: true, completion: $0) }
        #expect(model.metrics.bodySize.height > rest)

        let peek = model.metrics.bodySize.height
        await settle { model.setExpanded(true, reduceMotion: true, completion: $0) }
        #expect(model.metrics.bodySize.height > peek)

        // And going back up is not the same curve: closing should feel decisive, not like the
        // island falling back into the bezel.
        await settle { model.setExpanded(false, reduceMotion: true, completion: $0) }
        #expect(model.metrics.bodySize.height == peek)
    }
}

/// The lip's rows, and the two things about them that are not free to change.
@Suite("The track lip's rows")
struct TrackLipRowTests {

    /// **The lip is one height for every track**, which is the whole reason the audio badge shares
    /// the artist's row rather than taking one of its own.
    ///
    /// This strip is on screen because a pointer is resting on the album cover. A row that appeared
    /// only when the format happened to be known would make the lip 40pt for one track and 60 for
    /// the next — the island's bottom edge, and the region clicks are accepted in, moving under a
    /// stationary pointer once per song. `islandPath` tracks a settled shape, and a shape that
    /// settles somewhere different per track is not one.
    /// The fit against `IslandLayout.trackLipHeight` is already pinned above — this is the
    /// breakdown, so a row that grows has to be accounted for rather than absorbed into the slack.
    @Test("the drawn rows still add up to what the lip claims to be")
    func rowsMatchTheIslandGrowth() {
        #expect(
            NowPlayingTrackLipLayout.contentHeight
                == NowPlayingTrackLipLayout.topPadding
                + NowPlayingTrackLipLayout.titleLineHeight
                + NowPlayingTrackLipLayout.lineSpacing
                + NowPlayingTrackLipLayout.artistLineHeight
                + NowPlayingTrackLipLayout.bottomPadding
        )
    }

    /// The artist row has to hold Apple's badge without resizing it — the badges are 18pt tall and a
    /// trademark is not ours to shrink. See `AudioFormatBadge`.
    @Test("the artist row is tall enough for Apple's badge")
    func artistRowHoldsTheBadge() {
        #expect(NowPlayingTrackLipLayout.artistLineHeight >= 18)
    }

    /// **A scrolling line starts clear of the fade it scrolls through.**
    ///
    /// The fade is not decoration and is not going away: the line travels, and text arriving at a
    /// hard cut reads as clipped. What was wrong is that a travelling line started at x=0 — the
    /// bottom of the ramp — so the first character of a long artist was drawn at partial opacity
    /// and read as missing. The leading edge is the one a reader starts at.
    @Test("a travelling line begins past the fade rather than underneath it")
    func theInsetClearsTheFade() {
        #expect(NowPlayingTrackLipLayout.marqueeInset > NowPlayingTrackLipLayout.edgeFadeWidth)
        // And the fade is stated in points, because an inset cannot be stated against a fraction of
        // a width that changes with the island.
        #expect(NowPlayingTrackLipLayout.edgeFadeWidth > 0)
        // Both ends still fade. The inset moved where the line starts, not whether it fades on the
        // way past — a one-sided fade would pop the line out at the trailing edge.
        #expect(NowPlayingTrackLipLayout.marqueeInset * 2
                < NowPlayingTrackLipLayout.textWidth(bodyWidth: IslandLayout.expandedBodySize.width))
    }
}
