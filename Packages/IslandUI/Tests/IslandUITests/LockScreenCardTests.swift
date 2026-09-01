import Foundation
import IslandActivities
import IslandKit
import Testing

@testable import IslandUI

/// The lock screen's two surfaces: the music card, and the padlock at the notch.
///
/// Neither can be checked by looking at it — they only exist while the screen is locked, and by
/// definition nobody is at the Mac then. So what would normally be caught by glancing at a build is
/// asserted here, and the rest by `LockGlyphRenderProbe`, which renders them to PNGs.
@Suite("Lock screen surfaces")
struct LockScreenSurfaceTests {

    /// A 14" MacBook Pro, with the cutout deliberately off-center by three points so nothing can
    /// pass by assuming the notch is in the middle of the display.
    private static let notched = IslandScreen(
        id: 1,
        name: "Built-in",
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        backingScaleFactor: 2,
        notch: NotchGeometry(kind: .hardware, rect: CGRect(x: 660, y: 950, width: 185, height: 32))
    )

    private static let external = IslandScreen(
        id: 2,
        name: "External",
        frame: CGRect(x: -2560, y: 0, width: 2560, height: 1440),
        backingScaleFactor: 2,
        notch: NotchResolver.resolve(
            screenFrame: CGRect(x: -2560, y: 0, width: 2560, height: 1440),
            safeAreaTop: 0,
            auxiliaryTopLeft: nil,
            auxiliaryTopRight: nil
        )
    )

    // MARK: - The card

    /// The rows must add up to exactly the card's height. The first version declared 104pt against
    /// rows totalling 120 and this caught it on its first run — a clipped cover that would otherwise
    /// have shipped, because nobody is at the Mac to see it.
    @Test("the card's rows add up to the card")
    func stackedHeightMatches() {
        #expect(LockScreenCardLayout.stackedHeight == LockScreenCardLayout.size.height)
    }

    /// **The floor came down from 240 to 200 when the lines started scrolling**, and the assertion
    /// changed meaning with it. It used to be the width a real title had to *fit* in, because a
    /// title that did not fit was truncated and gone. Now it is the width a title has to be
    /// *readable* in while it travels — a column narrow enough that the marquee never rests is a
    /// line nobody can read the beginning of, whatever its length. 200pt is about twenty-five
    /// characters at 17pt, which is most titles outright and a legible window into the rest.
    ///
    /// It is a floor and not an equality because the column is what everything else in the header
    /// leaves over: the cover, the bars, and two gaps. Any of those growing takes from this.
    @Test("the text column survives a real track title")
    func textColumnIsWideEnough() {
        #expect(LockScreenCardLayout.textColumnWidth >= 200)
    }

    /// The header's four children and three gaps have to come to exactly the content width.
    ///
    /// **This is the assertion that would have caught the equaliser being drawn outside the card.**
    /// The row was written as `HStack(spacing: artworkSpacing)`, which charges that gap between
    /// every adjacent pair rather than once, so it ran 28pt wider than the card and the overflow
    /// went off the trailing edge onto the wallpaper. Nothing showed it until something was placed
    /// at that edge — `clipShape` had been quietly cutting an empty `Spacer` for a fortnight.
    @Test("the header's columns and gaps come to the content width exactly")
    func headerRowAddsUp() {
        let content = LockScreenCardLayout.size.width - LockScreenCardLayout.horizontalPadding * 2
        let row = LockScreenCardLayout.artworkSide
            + LockScreenCardLayout.artworkSpacing
            + LockScreenCardLayout.textColumnWidth
            + LockScreenCardLayout.equaliserSpacing
            + LockScreenCardLayout.equaliserSize.width
        #expect(row == content)
    }

    /// The header's three lines have to fit beside the cover, which is what sets the row's height.
    ///
    /// Asserted rather than eyeballed because the card was tightened by taking points off *both*
    /// sides of this: the cover came down from 76 to 64 and the two text lines from 21 and 18 to 20
    /// and 17. Two edits in opposite directions on one inequality is exactly where a clipped format
    /// badge would have shipped, on a surface nobody is at the Mac to see.
    @Test("the title block fits beside the cover")
    func titleBlockFitsTheHeader() {
        let block = LockScreenCardLayout.titleLineHeight
            + LockScreenCardLayout.titleSpacing
            + LockScreenCardLayout.subtitleLineHeight
            + LockScreenCardLayout.titleSpacing
            + NowPlayingExpandedLayout.formatLineHeight
        #expect(block <= LockScreenCardLayout.headerRowHeight)
    }

    @Test("the progress line dominates its row")
    func progressLineIsWideEnough() {
        #expect(LockScreenCardLayout.progressLineWidth > LockScreenCardLayout.progressRowWidth / 2)
    }

    /// Centerd horizontally, and **below** the display's vertical center — the band macOS itself
    /// leaves empty under its own clock at every display size.
    @Test("the card sits centerd, below the middle of the display")
    func cardSitsBelowCenter() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let panel = LockScreenCardLayout.panelFrame(inScreenFrame: screen)
        #expect(panel.midX == screen.midX)
        #expect(panel.maxY < screen.midY, "clear of the clock above it")
        #expect(panel.minY > screen.minY, "and on the screen")
    }

    /// A display whose origin is not zero — a second monitor to the left. Keyed off that screen's
    /// own frame, or the card lands on the wrong monitor.
    @Test("the card follows a display that is not at the origin")
    func cardFollowsOffsetDisplays() {
        let screen = CGRect(x: -2560, y: 0, width: 2560, height: 1440)
        let panel = LockScreenCardLayout.panelFrame(inScreenFrame: screen)
        #expect(panel.midX == screen.midX)
        #expect(panel.minX < 0)
    }

    // MARK: - The notch surface

    /// It is the island wearing its flanks — the cutout plus `flankedWidthGrowth`, at exactly the
    /// cutout's height. Growing downward would afford a body slot and stop reading as a notch.
    @Test("the notch surface is the flanked island, flare and all")
    func notchSurfaceIsTheFlankedIsland() {
        let rest = IslandLayout.restMetrics(for: Self.notched)
        let flanked = LockScreenNotchLayout.metrics(for: Self.notched)
        #expect(flanked.bodySize.width == rest.bodySize.width + IslandLayout.flankedWidthGrowth)
        #expect(flanked.bodySize.height == rest.bodySize.height)
        // The whole reason this goes through `IslandForm.flankedRest`: the outward curve where the
        // island meets the bezel. Without it the surface is a pill stuck under the cutout.
        #expect(flanked.topFlareRadius == IslandLayout.flankedTopFlareRadius)
        #expect(flanked == IslandLayout.metrics(for: .flankedRest, on: Self.notched))
    }

    /// Anchored to the cutout's own x. The notch above is deliberately off-center: a shape centerd
    /// on the screen would sit beside the thing it is meant to be part of.
    @Test("the notch surface hangs from the notch, not the middle of the screen")
    func notchSurfaceFollowsTheNotch() {
        let panel = LockScreenNotchLayout.panelFrame(for: Self.notched)
        #expect(panel.midX == Self.notched.notch.rect.midX)
        #expect(panel.midX != Self.notched.frame.midX, "the cutout here is deliberately off-center")
    }

    /// **Hanging from the bezel, not floating below it.** The surface's own top edge is the screen's
    /// top edge — an earlier version left an 8pt gap under the cutout and it read as a separate
    /// object stuck to the wallpaper.
    @Test("the notch surface starts at the top of the screen")
    func notchSurfaceHangsFromTheBezel() {
        let panel = LockScreenNotchLayout.panelFrame(for: Self.notched)
        let top = panel.maxY - LockScreenNotchLayout.shadowMargin
        #expect(top == Self.notched.frame.maxY)
    }

    /// On a display with no cutout the resolver synthesizes one at the top center, and the surface
    /// lands there — which is where Isleta's island lives on those machines anyway.
    @Test("a notchless display still gets a surface at the top center")
    func notchlessDisplayIsHandled() {
        let panel = LockScreenNotchLayout.panelFrame(for: Self.external)
        #expect(panel.midX == Self.external.notch.rect.midX)
        #expect(panel.maxY - LockScreenNotchLayout.shadowMargin == Self.external.frame.maxY)
    }

    /// The padlock has to be big enough to read from across a room. 13pt was reported as "a tiny
    /// white square"; the floor is half the flank it sits in.
    @Test("the padlock is not a speck")
    func padlockIsLegible() {
        #expect(LockScreenNotchLayout.glyphPointSize >= IslandLayout.flankedFlankWidth / 3)
        #expect(LockScreenNotchLayout.glyphPointSize <= IslandLayout.flankedFlankWidth / 2)
    }

    // MARK: - The panel and its contents must agree

    /// **The bug this exists for.** Both surfaces were once positioned as if their panel included a
    /// shadow margin while the panel was actually the content size — because an `NSHostingView` set
    /// as `contentView` resizes its window to the root view's fitting size. Each surface ended up
    /// off-center by exactly one margin: 18pt for the notch, 28pt for the card.
    ///
    /// The fix is in `LockScreenController.place`, which wraps the hosting view in a plain container
    /// so the window keeps the frame it was given. What can be asserted *here* is the invariant that
    /// made the symptom diagnosable: **a panel frame is always the content plus twice its margin**,
    /// so any future disagreement between the two is arithmetic rather than a mystery on a screen
    /// nobody can see.
    @Test("the card's panel is the card plus twice its margin")
    func cardPanelIsContentPlusMargin() {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let panel = LockScreenCardLayout.panelFrame(inScreenFrame: screen)
        let margin = LockScreenCardLayout.panelMargin
        #expect(panel.width == LockScreenCardLayout.size.width + margin * 2)
        #expect(panel.height == LockScreenCardLayout.size.height + margin * 2)
        // And the *content* is centerd on the screen once the margin is accounted for, which is the
        // thing that was actually wrong on hardware.
        let content = panel.insetBy(dx: margin, dy: margin)
        #expect(content.midX == screen.midX)
        // `cardFrame` is the same inset, and the two must not be able to drift apart: everything
        // the pointer is tested against on this surface is measured off it.
        #expect(content == LockScreenCardLayout.cardFrame(inScreenFrame: screen))
    }

    /// **The margin must not move the card.** `centerOffset` measures the *card's* top edge, and the
    /// arithmetic that reads `midY - centerOffset - height` puts the card one margin low the moment
    /// the margin stops being zero — the same off-by-one-margin failure the test above exists for,
    /// arriving through the layout instead of through the hosting view. Written against the number
    /// rather than against `panelMargin` so retuning the margin cannot quietly retune the placement.
    @Test("the card sits at centerOffset whatever the panel adds around it")
    func cardTopIsIndependentOfTheMargin() {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let card = LockScreenCardLayout.cardFrame(inScreenFrame: screen)
        #expect(card.maxY == screen.midY - LockScreenCardLayout.centerOffset)
        #expect(card.size == LockScreenCardLayout.size)
    }

    /// The root view's size claim and the window's have to be the same number, because the card is
    /// centred by the *root* now (`LockScreenCardView.body`) rather than by whatever `NSHostingView`
    /// does with spare points. Two sizes that disagree put the card off-centre by half the
    /// difference, on a surface nobody can see.
    @Test("the root view fills the panel exactly")
    func panelSizeMatchesThePanelFrame() {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        #expect(LockScreenCardLayout.panelFrame(inScreenFrame: screen).size == LockScreenCardLayout.panelSize)
    }

    /// **Room for the bounce.** The card arrives on `Motion.reveal`, whose overshoot takes its scale
    /// past 1 — and a window clips its contents to its bounds whatever SwiftUI drew, so a panel
    /// sized to exactly the card would square its own corners off at the peak. `reveal` overshoots
    /// ~11% of the travel it is given and the arrival's travel is 10% of the card, so the peak is
    /// ~1.5% over on each axis; the margin has to clear half of that on each side.
    @Test("the panel leaves room for the arrival's overshoot")
    func panelClearsTheArrivalOvershoot() {
        let peak: CGFloat = 1.015
        let overshoot = LockScreenCardLayout.size.width * (peak - 1) / 2
        #expect(LockScreenCardLayout.overshootMargin > overshoot)
        // And it is real room, not a renamed zero — the notch surface's `shadowMargin` is the zero.
        #expect(LockScreenCardLayout.panelMargin > 0)
    }

    /// The same invariant for the notch surface, where the margin is zero — so the panel *is* the
    /// content and its center must land on the cutout's center, not one margin to the left.
    /// The panel is built for the **peeked** island — the largest shape it will hold — so the window
    /// never resizes when the pointer arrives. Both shapes are centerd on the cutout, which is the
    /// invariant that was actually wrong on hardware.
    @Test("the notch panel is the peeked island, centerd on the cutout")
    func notchContentIsCenterdOnCutout() {
        let panel = LockScreenNotchLayout.panelFrame(for: Self.notched)
        let peeked = LockScreenNotchLayout.panelSize(for: Self.notched)
        #expect(panel.width == peeked.width + LockScreenNotchLayout.shadowMargin * 2)

        let content = panel.insetBy(
            dx: LockScreenNotchLayout.shadowMargin,
            dy: LockScreenNotchLayout.shadowMargin
        )
        #expect(content.midX == Self.notched.notch.rect.midX)

        // And the resting shape, drawn inside that panel, is centerd on the same point — so growing
        // to the peek expands about the cutout rather than sliding sideways.
        let resting = LockScreenNotchLayout.metrics(for: Self.notched).bodySize
        #expect(content.midX - resting.width / 2 < content.midX)
        #expect(peeked.width >= resting.width)
    }

    /// A panel whose top edge is above the screen is one AppKit may move. The notch surface has to
    /// end exactly at the screen's top edge for that reason as well as for how it looks.
    @Test("the notch surface does not extend past the top of the screen")
    func notchSurfaceStaysOnScreen() {
        let panel = LockScreenNotchLayout.panelFrame(for: Self.notched)
        #expect(panel.maxY == Self.notched.frame.maxY)
    }

    // MARK: - Hover

    /// The pointer drives the shape, and it has to be the **resting** island that is tested against.
    /// The panel is peek-sized; using its frame would make the island react to a pointer beside it,
    /// and would latch — once peeked, the pointer would still be inside whatever made it peek.
    @MainActor
    @Test("the hover region is the resting island, not the panel")
    func hoverRegionIsTheRestingIsland() {
        let resting = LockScreenNotchLayout.metrics(for: Self.notched).bodySize
        let panel = LockScreenNotchLayout.panelSize(for: Self.notched)
        let region = LockScreenNotchLayout.hoverRegion(for: Self.notched)

        #expect(panel.width > resting.width, "the panel is built for the peeked island")
        #expect(region.width < panel.width, "but the pointer is tested against the resting one")
        #expect(region.midX == Self.notched.notch.rect.midX)
    }

    /// Slop on the sides and bottom, none at the top: there is nothing above the bezel to approach
    /// from, and a region extending past the screen would swallow pointer positions that do not
    /// exist.
    @Test("the hover region is forgiving sideways but not above the bezel")
    func hoverRegionDoesNotExceedTheBezel() {
        let region = LockScreenNotchLayout.hoverRegion(for: Self.notched)
        #expect(region.maxY == Self.notched.frame.maxY)
        let resting = LockScreenNotchLayout.metrics(for: Self.notched).bodySize
        #expect(region.width == resting.width + LockScreenNotchLayout.hoverSlop * 2)
    }

    /// Hover follows the pointer, in and out, and is idempotent while it rests inside.
    ///
    /// This asserted a *crossing* until the lock screen's haptics were removed — `updatePointer`
    /// answered the region entered, once per entry, so a buzz could not repeat thirty times a
    /// second. With no buzz to fire there is no edge to report, and what is left is the property
    /// the drawing reads.
    @MainActor
    @Test("hover follows the pointer in and out of the region")
    func hoverFollowsThePointer() {
        let model = LockScreenCardModel()
        model.screen = Self.notched
        model.isLocked = true

        let inside = CGPoint(x: Self.notched.notch.rect.midX, y: Self.notched.frame.maxY - 8)
        let outside = CGPoint(x: 10, y: 10)

        model.updatePointer(inside)
        #expect(model.isHovered, "entered")
        model.updatePointer(inside)
        #expect(model.isHovered, "still inside")
        model.updatePointer(outside)
        #expect(!model.isHovered, "and left")
    }

    /// An unlocked Mac has no surface, so a pointer sitting where the island would be must not
    /// register — otherwise the next lock starts with the padlock already peeked.
    @MainActor
    @Test("the pointer does nothing while the surface is off screen")
    func hoverNeedsTheSurfaceOnScreen() {
        let model = LockScreenCardModel()
        model.screen = Self.notched
        let inside = CGPoint(x: Self.notched.notch.rect.midX, y: Self.notched.frame.maxY - 8)

        model.updatePointer(inside)
        #expect(!model.isHovered, "not locked, so nothing is there to hover")

        model.isLocked = true
        model.updatePointer(inside)
        #expect(model.isHovered)

        model.clearHover()
        #expect(!model.isHovered, "and the unlock drops it")
    }

    /// Hovering grows the island to the peeked form — the island's own shape, so the user's peek
    /// scale carries through rather than this inventing a size.
    @MainActor
    @Test("hovering grows the island to its peeked form")
    func hoverGrowsToThePeek() {
        let model = LockScreenCardModel()
        model.screen = Self.notched
        model.isLocked = true
        let resting = model.notchSize

        model.updatePointer(CGPoint(x: Self.notched.notch.rect.midX, y: Self.notched.frame.maxY - 8))
        #expect(model.notchSize.width > resting.width)
        #expect(model.notchSize == LockScreenNotchLayout.metrics(for: Self.notched, hovered: true).bodySize)
    }

    /// §9's rule: no clock at all on an unlocked Mac. The pointer is sampled only while the surface
    /// is presented, which is the exception the rule actually allows.
    @MainActor
    @Test("the pointer is not sampled while unlocked")
    func pointerClockStopsWhenUnlocked() {
        let model = LockScreenCardModel()
        #expect(model.pointerRate == .stopped)

        model.isLocked = true
        #expect(model.pointerRate != .stopped)

        model.isLocked = false
        #expect(model.pointerRate == .stopped)
    }

    /// The press is held for as long as the button is down and drops on the release.
    ///
    /// It answered the *edge* while there was a haptic to fire on it. `isPressed` is what remains,
    /// and `pressScale` is its only reader.
    @MainActor
    @Test("a press on the island holds and releases")
    func pressHoldsAndReleases() {
        let model = LockScreenCardModel()
        model.screen = Self.notched
        model.isLocked = true
        model.updatePointer(CGPoint(x: Self.notched.notch.rect.midX, y: Self.notched.frame.maxY - 8))

        model.updatePressed(true)
        #expect(model.isPressed, "pressed")
        model.updatePressed(true)
        #expect(model.isPressed, "still held")
        model.updatePressed(false)
        #expect(!model.isPressed, "released")
    }

    /// A press that begins away from the island is ignored — which is what `mouseDown` would
    /// have done.
    @MainActor
    @Test("a press away from the island is ignored")
    func pressOutsideIsIgnored() {
        let model = LockScreenCardModel()
        model.screen = Self.notched
        model.isLocked = true

        model.updatePointer(CGPoint(x: 10, y: 10))
        model.updatePressed(true)
        #expect(!model.isPressed, "pointer is not on the island")

        model.updatePointer(CGPoint(x: Self.notched.notch.rect.midX, y: Self.notched.frame.maxY - 8))
        model.updatePressed(true)
        #expect(model.isPressed, "and on it, the button being down is a press")
    }

    /// The press is a flex, not a fourth size the island can be in. Small enough to read as the same
    /// shape acknowledging something — §7's rule that peek is the invitation and never the result.
    @MainActor
    @Test("the press swells the island slightly and releases it")
    func pressScaleIsSubtle() {
        let model = LockScreenCardModel()
        model.screen = Self.notched
        model.isLocked = true
        #expect(model.pressScale == 1)

        model.updatePointer(CGPoint(x: Self.notched.notch.rect.midX, y: Self.notched.frame.maxY - 8))
        model.updatePressed(true)
        #expect(model.pressScale > 1)
        #expect(model.pressScale < 1.1, "an acknowledgement, not a new size")

        model.updatePressed(false)
        #expect(model.pressScale == 1)
    }

    /// The unlock drops both, or the next lock starts latched — pressed *and* hovered, with neither
    /// haptic able to fire because neither can cross again.
    @MainActor
    @Test("unlocking clears the press as well as the hover")
    func unlockClearsPress() {
        let model = LockScreenCardModel()
        model.screen = Self.notched
        model.isLocked = true
        model.updatePointer(CGPoint(x: Self.notched.notch.rect.midX, y: Self.notched.frame.maxY - 8))
        model.updatePressed(true)

        model.clearHover()
        #expect(!model.isHovered)
        #expect(!model.isPressed)
    }

    /// **The bug this exists for.** The panel was sized to the peeked island exactly, so a press
    /// scaled the shape past the window's own bounds and it clipped — square corners appearing on a
    /// press, on the flare and the bottom corners, which are the two places the island's shape does
    /// all its work. The window can never grow (its frame must not animate), so it has to be built
    /// at the maximum from the start.
    @Test("the panel can contain the island pressed as well as peeked")
    func panelHoldsThePressedPeek() {
        for screen in [Self.notched, Self.external] {
            let panel = LockScreenNotchLayout.panelSize(for: screen)
            let peeked = LockScreenNotchLayout.metrics(for: screen, hovered: true)

            // Against the **bounding** size, which includes the flare's sideways reach. Asserting
            // against `bodySize` is what let the flare clip while the bottom looked correct.
            let bounding = IslandShapeGeometry.boundingSize(for: peeked)
            #expect(panel.width >= bounding.width * LockScreenNotchLayout.pressScale)
            #expect(panel.height >= bounding.height * LockScreenNotchLayout.pressScale)

            // And the flare genuinely does reach past the body on a shape that has one, so this
            // test is testing something.
            if peeked.topFlareRadius > 0 {
                #expect(bounding.width > peeked.bodySize.width)
            }
        }
    }

    /// The same headroom has to survive a user who has made their island bigger — the sizing feeds
    /// through `IslandLayout`, so the panel must be derived from it rather than from a constant.
    @Test("the headroom survives a user-widened island")
    func panelHoldsThePressedPeekWhenResized() {
        let bigger = IslandSizing(peekScale: 2, widthAdjustment: 60)
        let panel = LockScreenNotchLayout.panelSize(for: Self.notched, sizing: bigger)
        let peeked = LockScreenNotchLayout.metrics(for: Self.notched, sizing: bigger, hovered: true)
        let bounding = IslandShapeGeometry.boundingSize(for: peeked)

        #expect(panel.width >= bounding.width * LockScreenNotchLayout.pressScale)
        #expect(panel.height >= bounding.height * LockScreenNotchLayout.pressScale)
    }

    /// The press must stay an acknowledgement rather than becoming a third size — and the panel's
    /// headroom is only affordable because it is small.
    @Test("the press scale is a flex, not a size")
    func pressScaleIsModest() {
        #expect(LockScreenNotchLayout.pressScale > 1)
        #expect(LockScreenNotchLayout.pressScale <= 1.06)
    }

    // MARK: - Progress

    @Test("progress is a clamped fraction")
    func progressIsClamped() {
        #expect(LockScreenCardLayout.progressFraction(position: 30, duration: 120) == 0.25)
        #expect(LockScreenCardLayout.progressFraction(position: -5, duration: 120) == 0)
        #expect(LockScreenCardLayout.progressFraction(position: 500, duration: 120) == 1)
    }

    /// A live stream reports a duration of zero. Unclamped this divides by zero, and SwiftUI draws a
    /// `NaN` width as nothing at all — silently.
    @Test("a stream with no duration does not divide by zero")
    func progressHandlesLiveStreams() {
        #expect(LockScreenCardLayout.progressFraction(position: 90, duration: 0) == 0)
        #expect(LockScreenCardLayout.progressFraction(position: .infinity, duration: 120) == 0)
        #expect(LockScreenCardLayout.progressFraction(position: 10, duration: .nan) == 0)
    }

    // MARK: - What is shown

    /// **The padlock does not need music.** The first build gated everything on there being a track,
    /// so a silent locked Mac drew nothing — which is what "I only see it on my external displays"
    /// turned out to be.
    @MainActor
    @Test("the padlock shows with nothing playing; the card does not")
    func padlockDoesNotNeedATrack() {
        let model = LockScreenCardModel()
        #expect(!model.isOnScreen)

        model.isLocked = true
        #expect(model.isOnScreen, "the padlock is drawn")
        #expect(!model.isPlayingOnScreen, "but there is no card")

        model.content = ActivityContent(title: "Emagination (B - Side)", subtitle: "Miami Horror")
        #expect(model.isPlayingOnScreen)
    }

    /// The padlock has to outlive the unlock by two beats — the shackle opening and the shape
    /// collapsing into the notch — or neither is ever seen.
    @MainActor
    @Test("the surfaces stay on screen while unlocking")
    func staysOnScreenWhileUnlocking() {
        let model = LockScreenCardModel()
        model.isLocked = true
        model.isLocked = false
        model.isUnlocking = true
        #expect(model.isOnScreen, "still drawing, still opening")

        model.isUnlocking = false
        #expect(!model.isOnScreen)
    }

    /// The two surfaces part company at the unlock, and this is the assertion that says so.
    ///
    /// The padlock has two beats left to play — the shackle opening, then the collapse into the
    /// cutout — and the card has none: it is a readout of something the user is now looking at on
    /// their own desktop. Before this, the card read `isOnScreen` too, sat through the whole unlock
    /// and then vanished with its window at `unlockLinger`, which is a panel being closed out from
    /// under a fully drawn card rather than an animation.
    @MainActor
    @Test("the card leaves the moment the Mac is unlocked; the padlock does not")
    func cardLeavesAtTheUnlock() {
        let model = LockScreenCardModel()
        model.isLocked = true
        model.content = ActivityContent(title: "Emagination (B - Side)", subtitle: "Miami Horror")
        #expect(model.isPlayingOnScreen)

        model.isLocked = false
        model.isUnlocking = true
        #expect(model.isOnScreen, "the padlock still has an unlock to play")
        #expect(!model.isPlayingOnScreen, "and the card is already on its way out")
    }

    /// The card is not on screen on the lock's first composited frame — it comes up on the beat the
    /// padlock springs out of the cutout on, not at whatever the window server drew first.
    @MainActor
    @Test("the card arrives on the padlock's beat rather than being there already")
    func cardArrivesOnTheSameBeat() {
        let model = LockScreenCardModel()
        #expect(model.isCardPresented, "settled before any lock, like reentry")

        model.isLocked = true
        model.content = ActivityContent(title: "Emagination (B - Side)", subtitle: "Miami Horror")
        model.hideForArrival(reduceMotion: false)
        #expect(!model.isCardPresented)
        #expect(!model.isPlayingOnScreen, "the first frame carries no card")

        model.playArrival(reduceMotion: false)
        #expect(model.isCardPresented)
        #expect(model.isPlayingOnScreen)
    }

    /// Reduce motion: nothing travels, so there is nothing to hold the card back for.
    @MainActor
    @Test("the card is simply there under reduce motion")
    func cardIsThereUnderReduceMotion() {
        let model = LockScreenCardModel()
        model.isLocked = true
        model.reduceMotion = true
        model.content = ActivityContent(title: "Emagination (B - Side)", subtitle: "Miami Horror")
        model.hideForArrival(reduceMotion: true)
        #expect(model.isCardPresented, "nothing to travel from: simply there")
        #expect(model.isPlayingOnScreen)
    }

    // MARK: - The transport

    /// The five buttons sit on the card's bottom row, inside it, in order, and do not touch.
    ///
    /// AppKit's y is up, so the row a person sees at the *bottom* is measured from `minY`. Getting
    /// that inverted puts the hit regions over the title, and the symptom on a surface with no
    /// cursor feedback is "the buttons don't work" with nothing to look at.
    ///
    /// **Play is centred on the card, and that is not decoration.** The row is symmetric — two
    /// secondaries flanking two skips flanking play — so the middle button's centre is the card's
    /// only if the arithmetic in `transportRowWidth` matches the walk in `transportFrame`. Those
    /// are two pieces of code reading one list, and this is what says they agree.
    @MainActor
    @Test("the transport row is the card's bottom row, five targets in order that do not overlap")
    func transportRowSitsAtTheBottom() {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let card = LockScreenCardLayout.cardFrame(inScreenFrame: screen)
        let frames = LockScreenTransportControl.allCases.map {
            LockScreenCardLayout.transportFrame($0, inScreenFrame: screen)
        }
        for (control, frame) in zip(LockScreenTransportControl.allCases, frames) {
            #expect(card.contains(frame), "every target is inside the card")
            #expect(
                frame.minY == card.minY + LockScreenCardLayout.verticalPadding,
                "one row, one padding off the bottom edge"
            )
            #expect(frame.height == LockScreenCardLayout.transportButtonSize, "one height")
            #expect(frame.width == LockScreenCardLayout.transportWidth(of: control))
        }
        #expect(
            LockScreenCardLayout.transportFrame(.playPause, inScreenFrame: screen).midX == card.midX,
            "play is centred, which is what the four others are placed around"
        )
        for (left, right) in zip(frames, frames.dropFirst()) {
            #expect(
                right.minX - left.maxX == LockScreenCardLayout.transportButtonSpacing,
                "one gap between each pair, and nothing overlaps"
            )
        }
    }

    /// A control the route has refused is still the control under the pointer.
    ///
    /// A capability can flip while the pointer rests on a button — a track loads and skipping
    /// becomes possible — so `hoveredControl` is assigned whether or not the command would be
    /// accepted, and the wash is lit at that instant rather than waiting for the pointer to leave
    /// and come back. Whether it may *act* is `canOperate`'s answer, asked at the press.
    @MainActor
    @Test("a refused control is still the control under the pointer")
    func refusedControlsAreStillHovered() {
        let model = Self.playing()
        guard let player = model.nowPlaying else { return }
        player.apply(
            isPlaying: true, canSkip: false, isTransportAvailable: true,
            isRadioStation: true, reduceMotion: true
        )

        let shuffle = LockScreenCardLayout.transportFrame(.toggleShuffle, inScreenFrame: Self.screenFrame).middle
        model.updatePointer(shuffle)
        #expect(model.hoveredControl == .toggleShuffle, "the control under the pointer")
        #expect(!model.canOperate(.toggleShuffle), "but refused")

        let next = LockScreenCardLayout.transportFrame(.nextTrack, inScreenFrame: Self.screenFrame).middle
        model.updatePointer(next)
        #expect(model.hoveredControl == .nextTrack)
        #expect(!model.canOperate(.nextTrack), "this route refuses skips too")

        let play = LockScreenCardLayout.transportFrame(.playPause, inScreenFrame: Self.screenFrame).middle
        model.updatePointer(play)
        #expect(model.hoveredControl == .playPause)
        #expect(model.canOperate(.playPause), "and play always acts")
    }

    /// Two capabilities, each gating its own pair, and play/pause gated by neither.
    ///
    /// A radio station has no queue to shuffle or repeat and refuses both commands; a route that
    /// prohibits skipping still stops. Drawing either group as inert-but-present is the point —
    /// the *capability* is missing, not the control set.
    @MainActor
    @Test("shuffle and repeat follow the queue capability, not the skip one")
    func queueControlsFollowTheirOwnCapability() {
        let player = NowPlayingController()
        player.apply(
            isPlaying: true, canSkip: false, isTransportAvailable: true,
            isRadioStation: true, reduceMotion: true
        )
        let model = LockScreenCardModel()
        model.nowPlaying = player

        #expect(!model.canOperate(.toggleShuffle), "a station has no queue to shuffle")
        #expect(!model.canOperate(.toggleRepeat))
        #expect(!model.canOperate(.previousTrack), "and this station refuses skips as well")
        #expect(model.canOperate(.playPause), "but it still stops")
    }

    /// Shuffle and repeat are the only two controls with a state to light up, and repeat's is
    /// three-valued — the glyph itself changes at `.one`, which is why it is not a flag.
    @MainActor
    @Test("only the queue controls light up, and repeat's glyph carries its mode")
    func onlyQueueControlsAreActive() {
        let model = Self.playing()
        guard let player = model.nowPlaying else { return }
        for control in LockScreenTransportControl.allCases {
            #expect(!model.isActive(control), "nothing is on to begin with")
        }

        player.send(.toggleShuffle)
        #expect(model.isActive(.toggleShuffle))
        #expect(!model.isActive(.playPause), "play is a glyph, not a lit state")

        player.send(.toggleRepeat)
        #expect(model.isActive(.toggleRepeat))
        #expect(player.repeatMode == .all)
        player.send(.toggleRepeat)
        #expect(player.repeatMode == .one, "off → all → one")
        #expect(model.isActive(.toggleRepeat))
        player.send(.toggleRepeat)
        #expect(player.repeatMode == .off)
        #expect(!model.isActive(.toggleRepeat))
    }

    /// The pointer resolves to exactly one control, or to none in the gaps between them.
    @MainActor
    @Test("a point resolves to one button, and to none between them")
    func pointerResolvesOneControl() {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        for control in LockScreenTransportControl.allCases {
            let center = LockScreenCardLayout.transportFrame(control, inScreenFrame: screen).middle
            #expect(LockScreenCardLayout.transportControl(at: center, inScreenFrame: screen) == control)
        }
        let previous = LockScreenCardLayout.transportFrame(.previousTrack, inScreenFrame: screen)
        let play = LockScreenCardLayout.transportFrame(.playPause, inScreenFrame: screen)
        let gap = CGPoint(x: (previous.maxX + play.minX) / 2, y: play.midY)
        #expect(LockScreenCardLayout.transportControl(at: gap, inScreenFrame: screen) == nil)
        #expect(
            LockScreenCardLayout.transportControl(
                at: CGPoint(x: screen.midX, y: screen.midY), inScreenFrame: screen
            ) == nil,
            "and the middle of the display is not a button"
        )
    }

    /// A press sends **once** per press, not once per sample.
    ///
    /// The pointer is polled at 30Hz because no event is ever delivered to this panel, so a caller
    /// acting on the *state* rather than the edge would send thirty skips a second for as long as
    /// somebody leaned on the trackpad.
    @MainActor
    @Test("a press sends one command, however long it is held")
    func pressSendsOnce() {
        let player = NowPlayingController()
        player.apply(isPlaying: true, canSkip: true, isTransportAvailable: true, reduceMotion: true)
        var sent: [NowPlayingControlCommand] = []
        player.onCommand = { sent.append($0) }

        let model = LockScreenCardModel()
        model.nowPlaying = player
        model.isLocked = true
        model.content = ActivityContent(title: "Emagination (B - Side)", subtitle: "Miami Horror")
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        model.screen = IslandScreen(
            id: 0,
            name: "",
            frame: screen,
            backingScaleFactor: 2,
            notch: NotchResolver.resolve(
                screenFrame: screen, safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil
            )
        )

        let nextCentre = LockScreenCardLayout.transportFrame(.nextTrack, inScreenFrame: screen).middle
        model.updatePointer(nextCentre)
        #expect(model.hoveredControl == .nextTrack)

        model.press(true, at: nextCentre)
        model.press(true, at: nextCentre)
        model.press(true, at: nextCentre)
        model.press(false, at: nextCentre)
        #expect(sent == [.nextTrack], "held is one command, and the release sends nothing")

        model.press(true, at: nextCentre)
        #expect(sent == [.nextTrack, .nextTrack], "a second press is a second command")
    }

    /// A press away from every button sends nothing — which is most of the lock screen, including
    /// the password field.
    @MainActor
    @Test("a press away from the buttons sends nothing")
    func pressAwaySendsNothing() {
        let player = NowPlayingController()
        player.apply(isPlaying: true, canSkip: true, isTransportAvailable: true, reduceMotion: true)
        var sent: [NowPlayingControlCommand] = []
        player.onCommand = { sent.append($0) }

        let model = LockScreenCardModel()
        model.nowPlaying = player
        model.isLocked = true
        model.content = ActivityContent(title: "Emagination (B - Side)", subtitle: "Miami Horror")

        model.updatePointer(CGPoint(x: 10, y: 10))
        #expect(model.hoveredControl == nil)
        model.press(true, at: CGPoint(x: 10, y: 10))
        #expect(sent.isEmpty)
    }

    /// A route that prohibits skipping draws the two skips dimmed and refuses them. Play/pause is
    /// never gated by `canSkip` — a player that will not skip still stops.
    @MainActor
    @Test("a route that cannot skip refuses the skips and keeps play")
    func skipsFollowTheRoute() {
        let player = NowPlayingController()
        player.apply(isPlaying: true, canSkip: false, isTransportAvailable: true, reduceMotion: true)
        let model = LockScreenCardModel()
        model.nowPlaying = player
        #expect(!model.canOperate(.previousTrack))
        #expect(!model.canOperate(.nextTrack))
        #expect(model.canOperate(.playPause))
    }

    /// No transport at all is no row, not three dimmed buttons — and nothing the pointer can find.
    @MainActor
    @Test("no transport means no targets")
    func noTransportMeansNoTargets() {
        let model = LockScreenCardModel()
        model.isLocked = true
        model.content = ActivityContent(title: "Emagination (B - Side)", subtitle: "Miami Horror")
        #expect(!model.hasTransport, "no player attached at all")

        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let centre = LockScreenCardLayout.transportFrame(.playPause, inScreenFrame: screen).middle
        model.updatePointer(centre)
        #expect(model.hoveredControl == nil)
        model.press(true, at: centre)
    }

    // MARK: - The progress line

    /// The line sits above the transport row, inside the card, between the two time labels — and
    /// its hit region is generous vertically without ever reaching a button.
    @MainActor
    @Test("the progress line is above the transport row and its region clears the buttons")
    func progressLineSitsAboveTheTransport() {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let card = LockScreenCardLayout.cardFrame(inScreenFrame: screen)
        let line = LockScreenCardLayout.progressLineFrame(inScreenFrame: screen)
        let region = LockScreenCardLayout.progressFrame(inScreenFrame: screen)
        let play = LockScreenCardLayout.transportFrame(.playPause, inScreenFrame: screen)

        #expect(card.contains(line))
        #expect(card.contains(region))
        #expect(line.minY > play.maxY, "above the buttons, in AppKit's y-up")
        #expect(region.minY > play.maxY, "and so is every point that answers for it")
        #expect(line.width == LockScreenCardLayout.progressLineWidth)
        #expect(
            line.minX == card.minX + LockScreenCardLayout.horizontalPadding
                + LockScreenCardLayout.timeLabelWidth + LockScreenCardLayout.timeLabelSpacing,
            "it starts where the elapsed label ends"
        )
    }

    /// The progress region is generous, and it still cannot reach a button.
    ///
    /// `progressHitSlop` is bounded by `transportSpacing` and the two have been edited in the same
    /// afternoon — the gap came down from 16 to 10 and the slop from 8 to 6. This is the assertion
    /// that keeps them honest: a slop that outgrows the gap puts the line's hit region over the
    /// play button, where a press meant for one lands on the other and the symptom on a surface
    /// with no cursor is that the buttons "sometimes" do the wrong thing.
    @MainActor
    @Test("the progress region never reaches a transport button")
    func progressRegionClearsTheButtons() {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let region = LockScreenCardLayout.progressFrame(inScreenFrame: screen)
        for control in LockScreenTransportControl.allCases {
            let button = LockScreenCardLayout.transportFrame(control, inScreenFrame: screen)
            #expect(!region.intersects(button), "\(control) is clear of the line's region")
        }
        #expect(
            LockScreenCardLayout.progressHitSlop < LockScreenCardLayout.transportSpacing,
            "the slop lives inside the gap it grows into"
        )
    }

    /// A fraction is measured against the line, clamped at both ends — a press that begins on the
    /// line and is dragged past it is a real gesture, and the honest answer past the start is 0.
    @MainActor
    @Test("a pointer resolves to a fraction of the line, clamped")
    func pointerResolvesAFraction() {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let line = LockScreenCardLayout.progressLineFrame(inScreenFrame: screen)

        #expect(LockScreenCardLayout.progressFraction(atX: line.minX, inScreenFrame: screen) == 0)
        #expect(LockScreenCardLayout.progressFraction(atX: line.maxX, inScreenFrame: screen) == 1)
        let middle = LockScreenCardLayout.progressFraction(atX: line.midX, inScreenFrame: screen)
        #expect(abs(middle - 0.5) < 0.001)
        #expect(LockScreenCardLayout.progressFraction(atX: line.minX - 400, inScreenFrame: screen) == 0)
        #expect(LockScreenCardLayout.progressFraction(atX: line.maxX + 400, inScreenFrame: screen) == 1)
    }

    /// The line has its own hover, separate from the buttons and the padlock — it is what widens
    /// the bar and shows the numerals.
    @MainActor
    @Test("the progress line has its own hover")
    func progressHasItsOwnHover() {
        let model = Self.playing()
        let point = LockScreenCardLayout.progressLineFrame(inScreenFrame: Self.screenFrame).middle

        model.updatePointer(point)
        #expect(model.isProgressHovered, "entered")
        model.updatePointer(point)
        #expect(model.isProgressHovered, "still on it")
        model.updatePointer(CGPoint(x: 10, y: 10))
        #expect(!model.isProgressHovered, "and left")
    }

    /// A press on the line scrubs, and the **release** is what sends the seek — `endScrub`'s
    /// contract, and the reason a press-and-drag moves the playhead rather than seeking on every
    /// sample along the way.
    @MainActor
    @Test("a press on the line scrubs, and the release seeks")
    func pressOnTheLineSeeks() {
        let model = Self.playing()
        guard let player = model.nowPlaying else { return }
        var seeks: [TimeInterval] = []
        player.onSeek = { seeks.append($0) }

        let line = LockScreenCardLayout.progressLineFrame(inScreenFrame: Self.screenFrame)
        let quarter = CGPoint(x: line.minX + line.width / 4, y: line.midY)
        model.updatePointer(quarter)

        model.press(true, at: quarter)
        #expect(model.isScrubbing, "the press begins a scrub")
        #expect(seeks.isEmpty, "and sends nothing yet")

        // Dragged to the middle, still held: the playhead follows and the player is still silent.
        let middle = CGPoint(x: line.midX, y: line.midY)
        model.press(true, at: middle)
        #expect(model.isScrubbing)
        #expect(seeks.isEmpty)

        model.press(false, at: middle)
        #expect(!model.isScrubbing)
        #expect(seeks.count == 1, "one seek, on the release")
        #expect(abs((seeks.first ?? 0) - 107) < 2, "to the middle of a 214-second track")
    }

    /// A live stream has no end to seek to, so the line is not a control at all — no crossing, no
    /// scrub, nothing to buzz about.
    @MainActor
    @Test("a stream with no duration cannot be seeked")
    func streamCannotBeSeeked() {
        let model = Self.playing()
        model.timeline = nil
        #expect(!model.canSeek)

        let point = LockScreenCardLayout.progressLineFrame(inScreenFrame: Self.screenFrame).middle
        model.updatePointer(point)
        #expect(!model.isProgressHovered)
        model.press(true, at: point)
        #expect(!model.isScrubbing)
    }

    /// The surface going away mid-drag **abandons** the scrub. An unlock is not somebody letting go
    /// of the playhead, and committing one on the way out would move the user's music.
    @MainActor
    @Test("a scrub interrupted by the unlock is abandoned, not committed")
    func unlockAbandonsAScrub() {
        let model = Self.playing()
        guard let player = model.nowPlaying else { return }
        var seeks: [TimeInterval] = []
        player.onSeek = { seeks.append($0) }

        let line = LockScreenCardLayout.progressLineFrame(inScreenFrame: Self.screenFrame)
        let quarter = CGPoint(x: line.minX + line.width / 4, y: line.midY)
        model.updatePointer(quarter)
        model.press(true, at: quarter)
        #expect(model.isScrubbing)

        model.clearHover()
        #expect(!model.isScrubbing)
        #expect(seeks.isEmpty, "nothing was sent")
    }

    /// Unlocking drops the button under the pointer as well as the island's hover, so the next lock
    /// does not start with a control lit that nothing ever crossed into.
    @MainActor
    @Test("unlocking clears the button under the pointer")
    func unlockClearsTheControl() {
        let player = NowPlayingController()
        player.apply(isPlaying: true, canSkip: true, isTransportAvailable: true, reduceMotion: true)
        let model = LockScreenCardModel()
        model.nowPlaying = player
        model.isLocked = true
        model.content = ActivityContent(title: "Emagination (B - Side)", subtitle: "Miami Horror")
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let centre = LockScreenCardLayout.transportFrame(.playPause, inScreenFrame: screen).middle
        model.updatePointer(centre)
        model.press(true, at: centre)
        #expect(model.hoveredControl == .playPause)
        #expect(model.isControlPressed)

        model.clearHover()
        #expect(model.hoveredControl == nil)
        #expect(!model.isControlPressed)
    }

    /// The padlock arrives on the island's own re-entry: from a third of its size, anchored at the
    /// notch, and invisible on the first instant rather than dimmed. The same two functions map it
    /// so the two surfaces cannot drift onto different curves.
    @MainActor
    @Test("the padlock arrives the way the island comes back")
    func arrivalIsTheIslandsReentry() {
        let model = LockScreenCardModel()
        #expect(model.reentry == 1, "settled before any lock")
        #expect(model.arrivalScale == 1)
        #expect(model.arrivalOpacity == 1)

        #expect(IslandScreenModel.reentryScale(0) == 0.32, "starts at a third of full size")
        #expect(IslandScreenModel.reentryOpacity(0) == 0, "and absent, not dimmed")

        model.isLocked = true
        model.hideForArrival(reduceMotion: false)
        #expect(model.reentry == 0, "the first frame is an empty cutout")
        #expect(model.arrivalOpacity == 0)
        model.playArrival(reduceMotion: false)
        // The spring's target, not its progress: outside a hosted view the value lands at once.
        #expect(model.reentry == 1)
        #expect(model.arrivalScale == 1)
    }

    /// The way out is the way in, reversed: the departure ends at zero, where the shape is a third
    /// of its size and fully transparent, so the window can go with nothing on it to cut off.
    @MainActor
    @Test("the padlock collapses back into the notch on the way out")
    func departureIsTheArrivalReversed() {
        let model = LockScreenCardModel()
        model.isLocked = true
        model.playArrival(reduceMotion: false)
        model.isLocked = false
        model.isUnlocking = true
        model.playDeparture(reduceMotion: false)
        #expect(model.reentry == 0)
        #expect(model.arrivalScale == IslandScreenModel.reentryScale(0))
        #expect(model.arrivalOpacity == 0)
        #expect(model.isOnScreen, "the window stays until the controller tears it down")
    }

    /// Reduce motion is a correctness requirement: the surface is simply there, and on the way out
    /// only its opacity moves.
    @MainActor
    @Test("reduce motion arrives with no motion at all")
    func arrivalUnderReduceMotion() {
        let model = LockScreenCardModel()
        model.isLocked = true
        model.reduceMotion = true
        model.hideForArrival(reduceMotion: true)
        #expect(model.reentry == 1, "nothing to travel from: simply there")
        model.playArrival(reduceMotion: true)
        #expect(model.reentry == 1)
        #expect(model.arrivalScale == 1)
        #expect(model.arrivalOpacity == 1)

        model.playDeparture(reduceMotion: true)
        #expect(model.arrivalScale == 1, "no scale under reduce motion")
        #expect(model.arrivalOpacity == 0)
    }

    /// Every Now Playing content carries a fallback note glyph, so keying off `symbol` would treat
    /// any app that registered and said nothing as a track.
    @MainActor
    @Test("a symbol with no title is not a track")
    func aSymbolAloneIsNotATrack() {
        let model = LockScreenCardModel()
        model.isLocked = true
        model.content = ActivityContent(symbol: "music.note")
        #expect(!model.isPlaying)

        model.content = ActivityContent(symbol: "music.note", title: "Emagination")
        #expect(model.isPlaying)
    }

    // MARK: - The clock

    /// §9's rule, asserted rather than trusted: nothing here is a function of time unless a playhead
    /// is genuinely advancing. A padlock on a silent Mac must not run a display link.
    @MainActor
    @Test("no clock runs unless a playhead is advancing")
    func clockStopsWhenNothingMoves() {
        let model = LockScreenCardModel()
        model.isLocked = true
        #expect(model.clockRate == .stopped, "locked, nothing playing")

        model.content = ActivityContent(title: "Emagination")
        #expect(model.clockRate == .stopped, "playing, but no timeline")

        let anchor = Date(timeIntervalSince1970: 1_000)
        model.timeline = ActivityTimeline(elapsed: 30, duration: 200, anchor: anchor, rate: 0)
        #expect(model.clockRate == .stopped, "paused")

        model.timeline = ActivityTimeline(elapsed: 30, duration: 200, anchor: anchor, rate: 1)
        #expect(model.clockRate == .seconds, "playing")

        model.isLocked = false
        #expect(model.clockRate == .stopped, "unlocked, nothing on screen to drive")
    }

    /// The island's equaliser is deliberately absent here, so nothing ever asks for a frame rate.
    /// If this fails, something added continuous motion to a surface shown to an empty room.
    @MainActor
    @Test("nothing ever asks for a frame rate")
    func neverRunsAtFrameRate() {
        let model = LockScreenCardModel()
        model.isLocked = true
        model.content = ActivityContent(title: "Emagination")
        model.timeline = ActivityTimeline(
            elapsed: 0, duration: 200, anchor: Date(timeIntervalSince1970: 1_000), rate: 1.5
        )
        #expect(model.clockRate == .seconds)
    }

    // MARK: - Numerals

    @Test("durations print as m:ss, and past an hour as h:mm:ss")
    func clockTextFormatsDurations() {
        #expect(LockScreenCardModel.clockText(0) == "0:00")
        #expect(LockScreenCardModel.clockText(69) == "1:09")
        #expect(LockScreenCardModel.clockText(599) == "9:59")
        #expect(LockScreenCardModel.clockText(3661) == "1:01:01")
    }

    @Test("a nonsense duration prints a placeholder rather than a number")
    func clockTextRefusesNonsense() {
        #expect(LockScreenCardModel.clockText(-1) == "--:--")
        #expect(LockScreenCardModel.clockText(.nan) == "--:--")
        #expect(LockScreenCardModel.clockText(.infinity) == "--:--")
    }

    @MainActor
    @Test("elapsed and remaining read off the same anchored timeline")
    func numeralsFollowTheTimeline() {
        let model = LockScreenCardModel()
        let anchor = Date(timeIntervalSince1970: 1_000)
        model.timeline = ActivityTimeline(elapsed: 30, duration: 200, anchor: anchor, rate: 1)

        #expect(model.elapsedText(at: anchor) == "0:30")
        #expect(model.remainingText(at: anchor) == "-2:50")

        // Ten seconds later with no new activity published — the whole point of an anchored
        // timeline is that the card advances without the player being re-asked.
        let later = anchor.addingTimeInterval(10)
        #expect(model.elapsedText(at: later) == "0:40")
        #expect(model.remainingText(at: later) == "-2:40")
    }

    /// A live stream has no end, so there is nothing to count down to. "-0:00" would be a
    /// plausible-looking lie.
    @MainActor
    @Test("a live stream prints a placeholder rather than a fake remaining time")
    func liveStreamHasNoRemaining() {
        let model = LockScreenCardModel()
        let anchor = Date(timeIntervalSince1970: 1_000)
        model.timeline = ActivityTimeline(elapsed: 90, duration: 0, anchor: anchor, rate: 1)
        #expect(model.elapsedText(at: anchor) == "1:30")
        #expect(model.remainingText(at: anchor) == "--:--")
        #expect(model.progress(at: anchor) == nil, "no line is drawn at all")
    }

    /// With no screen yet, the notch geometry falls back to a synthesized island rather than to
    /// zero. A surface of size zero is indistinguishable on screen from one that failed to
    /// composite, and this project has already spent an afternoon on that distinction.
    @MainActor
    @Test("no screen yet still yields a real notch size")
    func fallbackSizeIsNotZero() {
        let model = LockScreenCardModel()
        #expect(model.notchSize.width > 0)
        #expect(model.notchSize.height > 0)
        #expect(model.notchCornerRadius > 0)
    }
}

/// The middle of a rectangle. `CGRect.center` exists but is `package`-visible from SwiftUI, so it
/// is not reachable from a test target — spelled here rather than written out at six call sites.
extension CGRect {
    var middle: CGPoint { CGPoint(x: midX, y: midY) }
}

@MainActor
extension LockScreenSurfaceTests {

    /// The display every hit-test in this suite is measured against.
    static let screenFrame = CGRect(x: 0, y: 0, width: 1728, height: 1117)

    /// A locked card with a real track, a working transport and a 214-second playhead.
    static func playing() -> LockScreenCardModel {
        let player = NowPlayingController()
        player.apply(isPlaying: true, canSkip: true, isTransportAvailable: true, reduceMotion: true)
        let model = LockScreenCardModel()
        model.nowPlaying = player
        model.isLocked = true
        model.content = ActivityContent(title: "Emagination (B - Side)", subtitle: "Miami Horror")
        model.timeline = ActivityTimeline(elapsed: 0, duration: 214, anchor: Date(), rate: 1)
        model.screen = IslandScreen(
            id: 0,
            name: "",
            frame: screenFrame,
            backingScaleFactor: 2,
            notch: NotchResolver.resolve(
                screenFrame: screenFrame, safeAreaTop: 0,
                auxiliaryTopLeft: nil, auxiliaryTopRight: nil
            )
        )
        return model
    }
}

/// `updateCardPress` with the instant filled in.
///
/// Every one of these presses is a button rather than a scrub, and a button acts on the press edge
/// with no reference to the clock. Spelled once here rather than at a dozen call sites, where a
/// literal `Date()` would look like it mattered.
@MainActor
extension LockScreenCardModel {
    func press(_ isDown: Bool, at location: CGPoint) {
        updateCardPress(isDown, at: location, now: Date())
    }
}
