import CoreGraphics
import Foundation
import IslandActivities
import IslandKit
import Testing

@testable import IslandUI

/// The Up Next surface, tested where it can be: the geometry, the scroll, the capability gating and
/// the two formatters. No view is built and no music plays.
@Suite("Now Playing — the Up Next surface")
@MainActor
struct NowPlayingQueueSurfaceTests {

    // MARK: - Geometry

    @Test("the surface is one height whatever is in it")
    func heightIsConstant() {
        // The point of the constant, stated as a test because the obvious change is to make it a
        // function of the row count. It must not be: the queue window grows
        // as the reader scrolls, so a height derived from the count would move the island's own
        // bottom edge under a pointer that is on it, every time a page landed.
        let expected = NowPlayingQueueLayout.topPadding
            + NowPlayingQueueLayout.headerHeight
            + NowPlayingQueueLayout.headerSpacing
            + NowPlayingQueueLayout.viewportHeight
            + NowPlayingQueueLayout.bottomPadding
        #expect(NowPlayingQueueLayout.contentHeight == expected)
    }

    @Test("contentHeight and rowsHeight are each other's inverse")
    func heightsAgree() {
        // Where the two ever disagree, the drawn list is what has to give — the island has already
        // been sized and cannot grow to cover the difference. A list fails this way on
        // screen with every test still passing, so it is asserted here rather than assumed.
        #expect(
            NowPlayingQueueLayout.rowsHeight(inContentHeight: NowPlayingQueueLayout.contentHeight)
                == NowPlayingQueueLayout.viewportHeight
        )
    }

    @Test("a list that fits cannot scroll, and one that does not can")
    func scrollExtent() {
        #expect(NowPlayingQueueLayout.scrollExtent(rowCount: 0) == 0)
        #expect(NowPlayingQueueLayout.scrollExtent(rowCount: NowPlayingQueueLayout.visibleRows) == 0)
        #expect(NowPlayingQueueLayout.scrollExtent(rowCount: 20) > 0)
    }

    @Test("the indicator is absent on a short list and bounded on a long one")
    func indicator() {
        #expect(NowPlayingQueueLayout.indicator(offset: 0, rowCount: 2) == nil)
        let thumb = NowPlayingQueueLayout.indicator(offset: 0, rowCount: 40)
        #expect(thumb != nil)
        // Proportional with a floor: a forty-row list would otherwise draw a thumb a few points
        // long, which reads as a speck of dust on a black island rather than as a control.
        #expect((thumb?.length ?? 0) >= NowPlayingQueueLayout.indicatorMinimumLength)
        #expect((thumb?.length ?? 0) <= NowPlayingQueueLayout.viewportHeight)
        #expect((thumb?.top ?? -1) >= 0)
    }

    @Test("the indicator reaches the bottom of its track at the bottom of the list")
    func indicatorTravel() throws {
        let rows = 40
        let extent = NowPlayingQueueLayout.scrollExtent(rowCount: rows)
        let bottom = try #require(NowPlayingQueueLayout.indicator(offset: extent, rowCount: rows))
        #expect(abs(bottom.top + bottom.length - NowPlayingQueueLayout.viewportHeight) < 0.001)
    }

    // MARK: - Paging, from the geometry side

    @Test("a list at rest still counts the rows on screen")
    func lastVisibleRowAtRest() {
        // At the top, four rows are visible, so the deepest one is index 3 — not 0. Answering 0
        // would ask for a window of eleven when the surface opens and then ask again immediately,
        // which is a second MediaRemote round trip for a page we already knew we needed.
        #expect(
            NowPlayingQueueLayout.lastVisibleRow(offset: 0, rowCount: 40)
                >= NowPlayingQueueLayout.visibleRows - 1
        )
    }

    @Test("scrolling moves the deepest visible row down the list")
    func lastVisibleRowGrows() {
        let stride = NowPlayingQueueLayout.rowHeight + NowPlayingQueueLayout.rowSpacing
        let shallow = NowPlayingQueueLayout.lastVisibleRow(offset: 0, rowCount: 40)
        let deep = NowPlayingQueueLayout.lastVisibleRow(offset: stride * 10, rowCount: 40)
        #expect(deep > shallow)
        #expect(deep >= 10)
    }

    // MARK: - The scroll

    @Test("a scroll follows the fingers, and natural scrolling is obeyed")
    func scrollFollowsDelta() {
        // `deltaY`, never `upwardDeltaY`. This is a document moved under a window, which is exactly
        // what the user's setting is about — the three gestures undo it because a flick to put
        // something away is a direction in the world, and a list is not.
        var scroll = NowPlayingQueueScroll()
        let offset = scroll.consume(
            IslandScrollSample(phase: .changed, deltaX: 0, deltaY: -20, isPrecise: true, isDirectionInverted: false),
            extent: 200
        )
        #expect(offset == 20)
    }

    @Test("the offset is clamped to the list, in both directions")
    func scrollIsClamped() {
        var scroll = NowPlayingQueueScroll()
        _ = scroll.consume(
            IslandScrollSample(phase: .changed, deltaX: 0, deltaY: -5000, isPrecise: true, isDirectionInverted: false),
            extent: 120
        )
        #expect(scroll.offset == 120)
        _ = scroll.consume(
            IslandScrollSample(phase: .changed, deltaX: 0, deltaY: 5000, isPrecise: true, isDirectionInverted: false),
            extent: 120
        )
        #expect(scroll.offset == 0)
    }

    @Test("a window that got shorter pulls the reader back inside it")
    func clampAgainstAShrunkWindow() {
        // The case a static list never sees: a track change re-vends the window from the *new*
        // current track, so a queue that got shorter would otherwise leave the viewport on nothing.
        var scroll = NowPlayingQueueScroll()
        _ = scroll.consume(
            IslandScrollSample(phase: .changed, deltaX: 0, deltaY: -300, isPrecise: true, isDirectionInverted: false),
            extent: 400
        )
        #expect(scroll.offset == 300)
        #expect(scroll.clamped(to: 40) == 40)
    }

    @Test("momentum counts, and the gesture boundaries do not move the list")
    func momentumCounts() {
        // Momentum counts here and in no gesture in this package: there it is inertia arriving after
        // a verdict has been reached and refused, and here the verdict *is* the movement. A list
        // that stopped dead when the fingers lifted would be the only one on the machine that did.
        var scroll = NowPlayingQueueScroll()
        _ = scroll.consume(
            IslandScrollSample(phase: .momentum, deltaX: 0, deltaY: -30, isPrecise: true, isDirectionInverted: false),
            extent: 400
        )
        #expect(scroll.offset == 30)
        _ = scroll.consume(
            IslandScrollSample(phase: .ended, deltaX: 0, deltaY: -999, isPrecise: true, isDirectionInverted: false),
            extent: 400
        )
        #expect(scroll.offset == 30)
    }

    @Test("a repeat target still reaches the view")
    func scrollTargetSequence() {
        // Two track changes in a row both target zero, and an `onChange` watching the offset alone
        // would play nothing for the second.
        let first = NowPlayingQueueScrollTarget().revealingCurrent()
        let second = first.revealingCurrent()
        #expect(first.offset == second.offset)
        #expect(first != second)
        #expect(second.sequence == first.sequence + 1)
        #expect(second.isAnimated)
        #expect(!first.dragged(to: 0).isAnimated)
    }

    // MARK: - Capability gating

    @Test("each of the four limits grays its own control and nothing else")
    func permitsIsPerCommand() {
        // The rule this codebase keeps re-learning: `prohibitsSkip`, a radio station,
        // `supportsIsLiked` and "this route reads no queue" are mutually unrelated, and answering
        // any two of them with one flag grays the wrong control in each direction.
        let noSkip = NowPlayingController.permits(
            .nextTrack, canSkip: false, canChangeQueueBehavior: true, canFavorite: true, canReadQueue: true
        )
        #expect(!noSkip)
        // A stream that forbids skipping still has a queue to shuffle.
        #expect(NowPlayingController.permits(
            .toggleShuffle, canSkip: false, canChangeQueueBehavior: true, canFavorite: true, canReadQueue: true
        ))
        // A radio station usually allows skipping and has no queue at all.
        #expect(NowPlayingController.permits(
            .nextTrack, canSkip: true, canChangeQueueBehavior: false, canFavorite: true, canReadQueue: true
        ))
        #expect(!NowPlayingController.permits(
            .toggleRepeat, canSkip: true, canChangeQueueBehavior: false, canFavorite: true, canReadQueue: true
        ))
        // A local library track permits everything else and offers no like.
        #expect(!NowPlayingController.permits(
            .toggleFavorite, canSkip: true, canChangeQueueBehavior: true, canFavorite: false, canReadQueue: true
        ))
        #expect(NowPlayingController.permits(
            .togglePlayPause, canSkip: false, canChangeQueueBehavior: false, canFavorite: false, canReadQueue: false
        ))
    }

    @Test("the fifteen-second jumps are not gated on prohibitsSkip")
    func fifteenSecondJumpsAreNotSkips() {
        // They move the playhead *inside* the item rather than leaving it, so a stream that forbids
        // skipping to the next track may perfectly well permit going back fifteen seconds. Whether
        // they are drawn at all is the player's own support flags, which is a different question.
        #expect(NowPlayingController.permits(
            .skipBackFifteen, canSkip: false, canChangeQueueBehavior: false
        ))
        #expect(NowPlayingController.permits(
            .skipForwardFifteen, canSkip: false, canChangeQueueBehavior: false
        ))
    }

    @Test("a dead heart sends nothing, and does not flip")
    func likeIsInertWithoutTheCapability() {
        let controller = NowPlayingController()
        var sent: [NowPlayingControlCommand] = []
        controller.onCommand = { sent.append($0) }
        controller.apply(
            isPlaying: true, canSkip: true, isTransportAvailable: true,
            canFavorite: false, isFavorite: false, reduceMotion: true
        )
        controller.send(.toggleFavorite)
        #expect(sent.isEmpty)
        // And crucially the optimistic flip does not happen either. A heart that lit up and sent
        // nothing would be the worst of the three possible failures: it claims a state the player
        // never entered and there is nothing to correct it, because nothing reports the field.
        #expect(!controller.isFavorite)
    }

    @Test("a live heart flips optimistically and sends")
    func likeFlipsAndSends() {
        let controller = NowPlayingController()
        var sent: [NowPlayingControlCommand] = []
        controller.onCommand = { sent.append($0) }
        controller.apply(
            isPlaying: true, canSkip: true, isTransportAvailable: true,
            canFavorite: true, isFavorite: false, reduceMotion: true
        )
        controller.send(.toggleFavorite)
        #expect(controller.isFavorite)
        #expect(sent == [.toggleFavorite])
        // And the player overrules it on the next payload, which is the precedence shuffle and
        // repeat can never have because nothing reports them.
        controller.apply(
            isPlaying: true, canSkip: true, isTransportAvailable: true,
            canFavorite: true, isFavorite: false, reduceMotion: true
        )
        #expect(!controller.isFavorite)
    }

    @Test("Up Next is offered by the route, not by the transport")
    func queueToggleIsNotATransportCommand() {
        // Reading the queue and controlling the player are separate capabilities on the same
        // machine — which is why they are separate protocols in IslandSources. A build where one
        // retires and the other does not is exactly the case this ordering exists for.
        let controller = NowPlayingController()
        var sent: [NowPlayingControlCommand] = []
        controller.onCommand = { sent.append($0) }
        controller.canReadQueue = true
        controller.isTransportAvailable = false
        controller.send(.toggleQueue)
        #expect(sent == [.toggleQueue])

        sent.removeAll()
        controller.canReadQueue = false
        controller.send(.toggleQueue)
        #expect(sent.isEmpty)
    }

    // MARK: - Playing a row

    @Test("double-clicking the playing row does nothing")
    func playingRowIsInert() {
        // "Play what is playing" has no honest answer other than nothing. A restart nobody asked
        // for is the one outcome a user would call a bug.
        let controller = NowPlayingController()
        var played: [(Int, String?)] = []
        controller.onPlayQueueItem = { played.append(($0, $1)) }
        controller.setQueue([
            NowPlayingQueueRow(index: 0, title: "Playing", contentItemIdentifier: "a"),
            NowPlayingQueueRow(index: 1, title: "Next", contentItemIdentifier: "b"),
        ])
        controller.playQueueItem(at: 0)
        #expect(played.isEmpty)
        controller.playQueueItem(at: 1)
        #expect(played.count == 1)
        #expect(played[0].0 == 1)
        #expect(played[0].1 == "b")
    }

    @Test("a row that is not in the window cannot be played")
    func unknownRowIsInert() {
        let controller = NowPlayingController()
        var played = 0
        controller.onPlayQueueItem = { _, _ in played += 1 }
        controller.setQueue([NowPlayingQueueRow(index: 0, title: "Playing")])
        controller.playQueueItem(at: 7)
        #expect(played == 0)
    }

    @Test("a stop takes the list with it and leaves the output devices alone")
    func resetKeepsTheMachineAndDropsTheTrack() {
        let controller = NowPlayingController()
        controller.setQueue([NowPlayingQueueRow(index: 0, title: "Playing")])
        controller.setOutputDevices([
            NowPlayingOutputDeviceRow(id: 1, name: "Speakers", isSelected: true, symbolName: "laptopcomputer")
        ])
        controller.canFavorite = true
        controller.isFavorite = true
        controller.playbackRate = 1.5
        controller.reset()
        #expect(controller.queue.isEmpty)
        #expect(!controller.canFavorite)
        #expect(!controller.isFavorite)
        #expect(controller.playbackRate == nil)
        // The Mac still has speakers when the music stops. Clearing them would empty the Output tab
        // every time playback ended, which is the one thing on this surface that is not about the
        // track.
        #expect(controller.outputDevices.count == 1)
    }

    // MARK: - The transport row still fits

    @Test("seven controls fit the open island's content column")
    func transportRowFits() {
        // Not merely ugly if it does not: a row that overflows is clipped by the mask in
        // `IslandRootView`, so a button is visibly shaved *and* invisibly unhittable in the part
        // that was cut.
        let body = CGRect(origin: .zero, size: CGSize(width: 380, height: 140))
        #expect(NowPlayingExpandedLayout.fits(in: body))
        #expect(
            NowPlayingExpandedLayout.transportRowWidth
                <= body.width - NowPlayingExpandedLayout.horizontalPadding * 2
        )
    }

    /// The wash drawn under the pointer is a rounded rectangle, and the thing that decides whether
    /// it still *is* one is a single number. Past half the shorter side it is a capsule — a pill
    /// standing behind a 13pt glyph, which reads as a second object in the row rather than as the
    /// button lighting up.
    @Test("the hover wash stays a rounded rectangle on the narrowest control")
    func hoverWashIsNotACapsule() {
        let shortestSide = min(
            NowPlayingExpandedLayout.secondaryButtonWidth,
            NowPlayingExpandedLayout.transportButtonSize.height
        )
        #expect(NowPlayingExpandedLayout.transportHoverCornerRadius > 0)
        #expect(NowPlayingExpandedLayout.transportHoverCornerRadius < shortestSide / 2)
    }

    @Test("the play and skip centers are unchanged by the two new controls")
    func skipCentersAreSymmetric() {
        // The new controls are symmetric about the middle three, which is what leaves
        // `TransportSelfTest` — which synthesises a press at these exact points — describing the
        // same buttons it always did.
        let body = CGRect(origin: .zero, size: CGSize(width: 380, height: 140))
        let play = NowPlayingExpandedLayout.playButtonCenter(in: body)
        let previous = NowPlayingExpandedLayout.skipButtonCenter(in: body, isNext: false)
        let next = NowPlayingExpandedLayout.skipButtonCenter(in: body, isNext: true)
        #expect(play.x - previous.x == next.x - play.x)
        #expect(previous.y == play.y)
        #expect(next.y == play.y)
        // **50pt, across every version of this row.** The skip centers are one button plus one gap
        // from the middle, so a change to either constant moves two of the three points the
        // self-test presses unless the other gives back exactly what it took — which is what
        // happened when the buttons were widened for the hover wash (34+16 → 38+12).
        #expect(next.x - play.x == 50)
    }

    // MARK: - Formatters

    @Test("the rate chip is absent at 1x and at rest")
    func rateChipIsQuietOnTheCommonPath() {
        #expect(NowPlayingRateFormat.chip(for: nil) == nil)
        #expect(NowPlayingRateFormat.chip(for: 0) == nil)
        #expect(NowPlayingRateFormat.chip(for: 1) == nil)
        // Players report 1.0 as 0.9999998 often enough that an equality test leaves a "1.0×" chip
        // on a normal track, which is the one case this tolerance exists for.
        #expect(NowPlayingRateFormat.chip(for: 0.9999998) == nil)
        #expect(NowPlayingRateFormat.chip(for: 1.5) == 1.5)
    }

    @Test("the rate reads as a setting rather than a measurement")
    func rateText() {
        #expect(NowPlayingRateFormat.text(1.5) == "1.5×")
        #expect(NowPlayingRateFormat.text(2) == "2×")
        #expect(NowPlayingRateFormat.text(0.75) == "0.75×")
    }

    @Test("VoiceOver hears the position and the track, and hears the current one named")
    func accessibilityLabels() {
        let current = NowPlayingQueueRow(index: 0, title: "Playing", artist: "Someone")
        let later = NowPlayingQueueRow(index: 3, title: "Later", artist: "Someone")
        #expect(NowPlayingQueueFormat.accessibilityLabel(for: current) == "Now playing, Playing, Someone")
        #expect(NowPlayingQueueFormat.accessibilityLabel(for: later) == "3, Later, Someone")
    }
}
