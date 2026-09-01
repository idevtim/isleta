import CoreGraphics
import IslandActivities
import IslandKit
import Testing

@testable import IslandUI

/// The home page's two columns: how the width is split, and how tall the page asks the island to be.
@Suite("The home page's layout")
struct HomeLayoutTests {

    private let bodyWidth = IslandLayout.expandedBodySize.width

    // MARK: - The split

    /// Everything the two columns and the rule between them take has to add back up to the body,
    /// or one column is drawn over the island's edge.
    @Test("the columns, the rule and the padding account for the whole body")
    func theSplitAddsUp() {
        let music = IslandHomeLayout.musicColumnWidth(bodyWidth: bodyWidth)
        let calendar = IslandHomeLayout.calendarColumnWidth(bodyWidth: bodyWidth)
        let chrome = 2 * IslandHomeLayout.horizontalPadding
            + IslandHomeLayout.dividerWidth
            + 2 * IslandHomeLayout.dividerSpacing
        #expect(music + calendar + chrome == bodyWidth)
    }

    /// The calendar column carries three rows of text and has to be the wider of the two; the music
    /// column carries a fixed-size cover and three fixed-size buttons and gets nothing from more room.
    @Test("the calendar column is the wider of the two")
    func calendarIsWider() {
        #expect(IslandHomeLayout.calendarColumnWidth(bodyWidth: bodyWidth)
                > IslandHomeLayout.musicColumnWidth(bodyWidth: bodyWidth))
    }

    /// A fraction rather than a constant, so the split survives `expandedBodySize.width` changing —
    /// which it has, and which is exactly the change that leaves a hard-coded column mis-centred.
    @Test("the split follows the body width rather than a fixed number", arguments: [280.0, 368.0, 460.0, 560.0])
    func splitFollowsTheWidth(width: CGFloat) {
        let music = IslandHomeLayout.musicColumnWidth(bodyWidth: width)
        let calendar = IslandHomeLayout.calendarColumnWidth(bodyWidth: width)
        #expect(music > 0)
        #expect(calendar > 0)
        #expect(music + calendar == IslandHomeLayout.columnsWidth(bodyWidth: width))
    }

    /// A panel narrower than its own chrome must produce zero columns rather than a negative width,
    /// which SwiftUI turns into a runtime complaint rather than a layout.
    @Test("an impossibly narrow island yields no columns rather than a negative one")
    func noNegativeColumns() {
        #expect(IslandHomeLayout.columnsWidth(bodyWidth: 0) == 0)
        #expect(IslandHomeLayout.musicColumnWidth(bodyWidth: 0) == 0)
        #expect(IslandHomeLayout.calendarColumnWidth(bodyWidth: 0) == 0)
    }

    // MARK: - The transport row

    /// **The row is centred, so one too wide does not overflow visibly** — it silently stops being
    /// centred, drifts off the leading edge, and the last button loses part of its target. Pinned
    /// here rather than checked by eye.
    @Test("the three transport buttons and their gaps fit the music column")
    func transportRowFitsTheColumn() {
        #expect(IslandHomeLayout.transportRowWidth
                <= IslandHomeLayout.musicColumnWidth(bodyWidth: bodyWidth))
    }

    /// **The width above is the only one that matters, and this is why.** The open island is always
    /// `IslandLayout.expandedBodySize.width` — `IslandLayout.metrics` varies an expanded island's
    /// *height* and takes its width from that constant — so the row has one column width to fit and
    /// not a range of them.
    ///
    /// Pinned rather than left as a comment: the day the open island's width becomes a function of
    /// anything, `transportRowWidth` is over the column at some of those widths and the row stops
    /// being centred instead of overflowing, which is the failure the test above cannot see. This is
    /// what points at it.
    @Test("the open island has one width, which is what the row is fitted to")
    func openIslandWidthIsConstant() {
        let screen = IslandScreen(
            id: 1, name: "Built-in Retina Display",
            frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            backingScaleFactor: 2,
            notch: NotchGeometry(
                kind: .hardware, rect: CGRect(x: 771.5, y: 1085, width: 185, height: 32)
            )
        )
        let narrow = IslandLayout.expandedMetrics(for: screen)
        let tall = IslandLayout.expandedMetrics(
            for: screen,
            expandedContentHeight: 320,
            pageIndicatorHeight: IslandPageIndicatorLayout.height
        )
        #expect(narrow.bodySize.width == IslandLayout.expandedBodySize.width)
        #expect(tall.bodySize.width == IslandLayout.expandedBodySize.width)
        #expect(tall.bodySize.height > narrow.bodySize.height)
    }

    /// The same control as the player's, so it lights up in the same shape. A different radius on
    /// the wash would read as a different control rather than the same one at a different size.
    @Test("the hover wash matches the player's corner")
    func hoverWashMatchesThePlayer() {
        #expect(IslandHomeLayout.transportHoverCornerRadius
                == NowPlayingExpandedLayout.transportHoverCornerRadius)
    }

    /// The buttons are the height of the player's, so the two rows read as one control at two
    /// widths rather than as a control and a lesser copy of it.
    @Test("the buttons are as tall as the player's and no wider")
    func buttonsMatchThePlayersHeight() {
        #expect(IslandHomeLayout.transportButtonSize.height
                == NowPlayingExpandedLayout.transportButtonSize.height)
        #expect(IslandHomeLayout.transportButtonSize.width
                <= NowPlayingExpandedLayout.transportButtonSize.width)
        // Past the size a pointer that has travelled into the notch can be aimed at.
        #expect(IslandHomeLayout.transportButtonSize.width >= 30)
    }

    // MARK: - The height

    /// The page is as tall as its **taller** column, which is what makes the rule between them run
    /// the full height of the content rather than stopping short of one side.
    @Test("the page is as tall as its taller column")
    func heightIsTheTallerColumn() {
        // Nothing on today: the music column is the floor.
        #expect(IslandHomeLayout.contentHeight(eventCount: 0, hasOverflow: false)
                == IslandHomeLayout.topPadding
                + IslandHomeLayout.musicColumnHeight()
                + IslandHomeLayout.bottomPadding)

        // A full day: the calendar column wins.
        let full = IslandHomeLayout.calendarColumnHeight(eventCount: 3, hasOverflow: true)
        #expect(full > IslandHomeLayout.musicColumnHeight())
        #expect(IslandHomeLayout.contentHeight(eventCount: 3, hasOverflow: true)
                == IslandHomeLayout.topPadding + full + IslandHomeLayout.bottomPadding)
    }

    @Test("the height never shrinks as the day fills up")
    func heightIsMonotonic() {
        var previous = IslandHomeLayout.contentHeight(eventCount: 0, hasOverflow: false)
        for count in 1...IslandHomeLayout.maximumEvents {
            let height = IslandHomeLayout.contentHeight(eventCount: count, hasOverflow: false)
            #expect(height >= previous)
            previous = height
        }
        #expect(IslandHomeLayout.contentHeight(eventCount: 3, hasOverflow: true) >= previous)
    }

    /// The column caps at `maximumEvents` and says "and N more" instead — so a day with forty
    /// meetings in it must not ask for forty rows of island.
    @Test("a day past the cap asks for no more island than a full one")
    func pastTheCapTheHeightHolds() {
        let atCap = IslandHomeLayout.contentHeight(eventCount: IslandHomeLayout.maximumEvents, hasOverflow: true)
        for count in [10, 40, 400] {
            #expect(IslandHomeLayout.contentHeight(eventCount: count, hasOverflow: true) == atCap)
        }
    }

    /// It has to fit the panel, which is built once at `maxExpandedBodySize` and never resized (§4.2).
    @Test("the tallest home page plus the cutout and the strip fits inside the panel")
    func tallestHomeFitsThePanel() {
        let tallest = IslandHomeLayout.contentHeight(
            eventCount: IslandHomeLayout.maximumEvents, hasOverflow: true
        )
        let height = IslandLayout.expandedHeight(
            contentHeight: tallest,
            cutoutHeight: 32,
            pageIndicatorHeight: IslandPageIndicatorLayout.height
        )
        #expect(height <= IslandLayout.maxExpandedBodySize.height)
    }

    // MARK: - Agreeing with the shell

    /// **The shell and the page must ask one function**, or the island is sized for one arrangement
    /// and drawing another. `IslandPageHeight` is that function; these pin the two spellings of it
    /// against each other.
    @MainActor
    @Test("the layout height resolves the shell's answer rather than inventing one")
    func layoutHeightMatchesTheShell() {
        for page in IslandPage.allCases {
            let shell = IslandPageHeight.contentHeight(for: page, glance: nil)
            let laidOut = IslandPageHeight.layoutHeight(for: page, glance: nil, cutoutHeight: 32)
            if let shell {
                #expect(laidOut == shell)
            } else {
                // Nil means the island's default, which is what `IslandLayout.expandedHeight` spells
                // it as — the page draws in that, less the hole it cannot draw in.
                #expect(laidOut == IslandLayout.expandedBodySize.height - 32)
            }
        }
    }

    /// The player is a fixed layout the island sizes, not one that sizes the island — so it asks for
    /// the default. This is the regression guard: it was briefly computed through
    /// `ActivityExpandedHeight`, which answers nil for `.nowPlaying`, so the music page was sized to
    /// the *home* page's empty height.
    @MainActor
    @Test("the music page takes the island's default height, not the home page's")
    func musicTakesTheDefault() {
        #expect(IslandPageHeight.contentHeight(for: .music, glance: nil) == nil)
        #expect(IslandPageHeight.layoutHeight(for: .music, glance: nil, cutoutHeight: 32)
                != IslandHomeLayout.emptyContentHeight)
    }

    /// The home page is the one the island opens on, so it must not be the tallest thing it can be —
    /// an island that opened to its ceiling every time would have nowhere to grow for the surface
    /// its date drills into.
    @Test("home opens shorter than the schedule it drills into")
    func homeIsShorterThanTheSchedule() {
        let full = IslandHomeLayout.contentHeight(
            eventCount: IslandHomeLayout.maximumEvents, hasOverflow: true
        )
        #expect(full < GlanceScheduleLayout.contentHeight)
    }

    /// **The badge's row is counted, not reserved** — no badge, no row, no gap under the artist.
    ///
    /// It is the same rule the open player follows, and it has the same cost stated plainly: the
    /// column is 20pt taller for a track whose format is known, so the page can be too. The
    /// alternative was reserving the row always, which leaves an empty strip under the artist and
    /// pushes the transport down for a line that never arrives.
    @Test("the audio badge's row is counted only when there is a badge")
    func theBadgeRowIsCountedNotReserved() {
        let bare = IslandHomeLayout.musicColumnHeight()
        let badged = IslandHomeLayout.musicColumnHeight(hasAudioFormat: true)
        #expect(badged - bare
                == IslandHomeLayout.formatLineHeight + IslandHomeLayout.formatLineSpacing)

        // And it reaches the page, or the island would be sized for one arrangement and drawing
        // another — the failure `AppDelegate.expandedContentHeightForStage` is careful about.
        #expect(IslandHomeLayout.contentHeight(eventCount: 0, hasOverflow: false, hasAudioFormat: true)
                > IslandHomeLayout.contentHeight(eventCount: 0, hasOverflow: false))
    }

    /// The row has to hold Apple's badge without resizing it — they are 18pt tall and a trademark
    /// is not ours to shrink. See `AudioFormatBadge`.
    @Test("the badge row is tall enough for Apple's badge")
    func badgeRowHoldsTheBadge() {
        #expect(IslandHomeLayout.formatLineHeight >= 18)
    }

    // MARK: - When there is no calendar to read

    /// **A refused calendar and a clear afternoon are the same `eventCount`.** The notice is what
    /// tells them apart, so the height has to come from the *access* and not from the count — the
    /// bug this guards is a column that reserves nothing, draws the sentence anyway, and runs it
    /// past the island's bottom edge.
    @Test("only a calendar that cannot be read reserves room for the notice")
    func noticeIsReservedOnlyWhenItDraws() {
        #expect(IslandHomeLayout.accessNoticeHeight(for: .granted) == 0)
        #expect(IslandHomeLayout.contentHeight(eventCount: 0, hasOverflow: false, access: .granted)
                == IslandHomeLayout.emptyContentHeight)

        for access in [CalendarAccess.notDetermined, .denied, .restricted, .writeOnly] {
            #expect(IslandHomeLayout.accessNoticeHeight(for: access) > 0)
            #expect(IslandHomeLayout.calendarColumnHeight(
                eventCount: 0, hasOverflow: false, access: access
            ) > IslandHomeLayout.calendarColumnHeight(eventCount: 0, hasOverflow: false))
        }
    }

    /// The two states with a control reserve room for it; the two without do not.
    ///
    /// §10: macOS raises the permission dialog once, so "Allow…" after a refusal is a control that
    /// visibly does nothing, and a managed Mac's pane has no switch the user owns. Reserving the
    /// button everywhere would leave 27pt of nothing under the sentence in exactly the configuration
    /// where the user can do least about it — which is where a gap reads most like a bug.
    @Test("the notice reserves a button only in the two states that have one")
    func theButtonIsReservedOnlyWhereItExists() {
        let withButton = IslandHomeLayout.accessButtonSpacing + IslandHomeLayout.accessButtonHeight
        let bare = IslandHomeLayout.dateSpacing + IslandHomeLayout.accessMessageHeight

        #expect(IslandHomeLayout.accessNoticeHeight(for: .notDetermined) == bare + withButton)
        #expect(IslandHomeLayout.accessNoticeHeight(for: .denied) == bare + withButton)
        #expect(IslandHomeLayout.accessNoticeHeight(for: .restricted) == bare)
        #expect(IslandHomeLayout.accessNoticeHeight(for: .writeOnly) == bare)
    }

    /// A managed Mac is the one refusal with nowhere to send the user, which is why the button's
    /// discriminator is not simply `!isReadable`.
    @Test("only a plain refusal has a System Settings switch behind it")
    func onlyDenialPointsAtSettings() {
        #expect(CalendarAccess.denied.canBeGrantedInSettings)
        #expect(!CalendarAccess.restricted.canBeGrantedInSettings)
        #expect(!CalendarAccess.granted.canBeGrantedInSettings)
        #expect(!CalendarAccess.notDetermined.canBeGrantedInSettings)
        #expect(!CalendarAccess.writeOnly.canBeGrantedInSettings)
    }

    // MARK: - The event pill

    /// The disc sits on the capsule's vertical centre, which is arithmetic rather than a chosen
    /// number — and it has to fit inside the capsule with something left over, or the pill is a
    /// disc with a hairline of colour around it.
    @Test("the badge is centred in the pill and smaller than it")
    func badgeFitsThePill() {
        #expect(IslandHomeLayout.eventBadgeSide < IslandHomeLayout.eventHeight)
        #expect(IslandHomeLayout.eventBadgeInset
                == (IslandHomeLayout.eventHeight - IslandHomeLayout.eventBadgeSide) / 2)
        #expect(IslandHomeLayout.eventBadgeGlyphSize < IslandHomeLayout.eventBadgeSide)
    }
}

/// A calendar's colour used as **text**, which is not the job it was picked for.
@Suite("A calendar colour that has to be read")
struct GlanceTintLabelTests {

    private func luminance(_ tint: GlanceTint) -> Double {
        0.2126 * tint.red + 0.7152 * tint.green + 0.0722 * tint.blue
    }

    /// Half of macOS's own set is dark enough to disappear into the pill it sits on. The floor is
    /// what stops that, and it is a floor rather than a brightening: a colour already above it is
    /// returned untouched, or every calendar would drift toward white together.
    @Test("a dark calendar is lifted to the floor and a bright one is left alone")
    func darkColoursAreLifted() {
        // Graphite, and a deep blue somebody chose themselves.
        for dark in [GlanceTint(red: 0.28, green: 0.28, blue: 0.30),
                     GlanceTint(red: 0.05, green: 0.10, blue: 0.55)] {
            #expect(luminance(dark) < 0.62)
            let lifted = lift(dark)
            #expect(abs(luminance(lifted) - 0.62) < 0.001)
            // The hue survives: the channel order is what tells two dark calendars apart, and a
            // lift that reordered them would make them the same colour at the floor.
            #expect((lifted.red < lifted.blue) == (dark.red < dark.blue))
        }

        let bright = GlanceTint(red: 1, green: 0.72, blue: 0.30)
        #expect(luminance(bright) >= 0.62)
        #expect(lift(bright) == bright)
    }

    /// The lift, done on the numbers rather than through SwiftUI — `Color` does not hand back the
    /// channels it was built from, so the arithmetic is restated here and the view's own copy is
    /// what `labelColor` runs. Same formula, and this is what pins it.
    private func lift(_ tint: GlanceTint) -> GlanceTint {
        let l = luminance(tint)
        guard l < 0.62 else { return tint }
        let mix = (0.62 - l) / (1 - l)
        return GlanceTint(
            red: tint.red + (1 - tint.red) * mix,
            green: tint.green + (1 - tint.green) * mix,
            blue: tint.blue + (1 - tint.blue) * mix
        )
    }
}

/// The row of dots at the foot of the open island, while a page is being dragged.
@Suite("The page indicator under a finger")
@MainActor
struct PageIndicatorDragTests {

    /// **The highlight has to move with the finger, because `current` does not.**
    ///
    /// A committed drag changes the page only when the turn lands — that is what makes the swap
    /// invisible for the pages themselves — so dots keyed on `current` alone stand still through the
    /// whole gesture and then move the white one across in a single frame. Reported as the dots
    /// jutting into place.
    ///
    /// Half way across, the two dots are equally lit. All the way, the arriving one is fully lit and
    /// the departing one is out — so the change of `current` that follows moves nothing at all.
    @Test("the two dots cross-fade as the page is dragged")
    func dotsCrossFade() {
        let model = IslandScreenModel(metricsByForm: [:], notchKind: .hardware)
        let pages = IslandPageModel()
        model.page = pages
        #expect(model.pageBeingDraggedTo == nil)
        #expect(model.pageDragProgress == 0)

        model.swipe.beginPaging(toward: nil, span: 368)

        // Content pushed left is the *next* page arriving from the right.
        model.swipe.track(-184)
        #expect(model.pageBeingDraggedTo == pages.current.next)
        #expect(abs(model.pageDragProgress - 0.5) < 0.001)

        model.swipe.track(-368)
        #expect(model.pageDragProgress == 1)

        // And the other way.
        model.swipe.track(184)
        #expect(model.pageBeingDraggedTo == pages.current.previous)

        model.swipe.endPaging()
        #expect(model.pageBeingDraggedTo == nil)
    }

    /// A drag past a whole page is deliberate — the band beyond the edge — and the indicator must
    /// not read a weight above 1 out of it, which would take a dot's fill past white.
    @Test("dragging past a page does not over-light the arriving dot")
    func progressIsClampedForTheDots() {
        let model = IslandScreenModel(metricsByForm: [:], notchKind: .hardware)
        model.page = IslandPageModel()
        model.swipe.beginPaging(toward: nil, span: 368)
        model.swipe.track(-440)
        #expect(model.pageDragProgress == 1)
    }
}
