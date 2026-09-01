import CoreGraphics
import Foundation
import IslandActivities
import IslandKit
import Testing

@testable import IslandUI

@Suite("Now Playing controller")
@MainActor
struct NowPlayingControllerTests {

    private let anchor = Date(timeIntervalSince1970: 1_700_000_000)

    private func timeline(elapsed: TimeInterval = 30, rate: Double = 1) -> ActivityTimeline {
        ActivityTimeline(elapsed: elapsed, duration: 200, anchor: anchor, rate: rate)
    }

    // MARK: - Precedence

    /// With nothing dragged and nothing pending, the player is the only opinion there is.
    @Test("the player's timeline is what shows")
    func passesThrough() {
        let controller = NowPlayingController()
        let base = timeline()
        #expect(controller.timeline(reportedBy: base, at: anchor) == base)
    }

    /// The playhead must not run under the pointer while the pointer is holding it still — the bar
    /// and the finger disagreeing reads as the control being laggy.
    @Test("a drag pins the playhead and stops it advancing")
    func dragPins() throws {
        let controller = NowPlayingController()
        controller.beginScrub(from: timeline(), toFraction: 0.25, at: anchor)
        let dragged = try #require(controller.timeline(reportedBy: timeline(), at: anchor))
        #expect(dragged.elapsed == 50)
        #expect(dragged.rate == 0)
        // Ten seconds later, still 50: the drag is where the user put it.
        #expect(dragged.position(at: anchor.addingTimeInterval(10)) == 50)
        #expect(controller.isScrubbing)
    }

    @Test("dragging moves the pinned position")
    func dragUpdates() throws {
        let controller = NowPlayingController()
        controller.beginScrub(from: timeline(), toFraction: 0.25, at: anchor)
        controller.updateScrub(toFraction: 0.75)
        let dragged = try #require(controller.timeline(reportedBy: timeline(), at: anchor))
        #expect(dragged.elapsed == 150)
    }

    /// Without the optimistic value the bar springs back to where it was for the length of the round
    /// trip, which reads as the drag having failed and invites the user to drag again.
    @Test("letting go seeks and holds the new position while the player catches up")
    func optimisticSeek() throws {
        let controller = NowPlayingController()
        var seeks: [TimeInterval] = []
        controller.onSeek = { seeks.append($0) }

        controller.beginScrub(from: timeline(), toFraction: 0.5, at: anchor)
        controller.endScrub(reportedBy: timeline(), at: anchor)

        #expect(seeks == [100])
        #expect(controller.isScrubbing == false)

        // The player has not answered yet, so it is still reporting the old position.
        let shown = try #require(controller.timeline(reportedBy: timeline(), at: anchor))
        #expect(shown.elapsed == 100)
        // And it keeps moving: a playhead that stood still for the settle window before lurching
        // forward is worse than no optimism at all.
        #expect(shown.rate == 1)
    }

    /// The player answering is what ends the optimism — comparing *positions* instead would be wrong
    /// in the case that matters, where a player refused the seek and reports the old position.
    @Test("a report anchored after the seek takes over immediately")
    func playerConfirms() throws {
        let controller = NowPlayingController()
        controller.beginScrub(from: timeline(), toFraction: 0.5, at: anchor)
        controller.endScrub(reportedBy: timeline(), at: anchor)

        let confirmation = ActivityTimeline(
            elapsed: 100, duration: 200, anchor: anchor.addingTimeInterval(0.3), rate: 1
        )
        let shown = try #require(
            controller.timeline(reportedBy: confirmation, at: anchor.addingTimeInterval(0.4))
        )
        #expect(shown.anchor == confirmation.anchor)
    }

    /// A refusal must be visible within a beat rather than looking like it worked forever. The
    /// deadline is checked against the `now` the display link already publishes, so it expires with
    /// no timer.
    @Test("an unanswered seek expires and the player wins again")
    func optimismExpires() throws {
        let controller = NowPlayingController()
        controller.beginScrub(from: timeline(), toFraction: 0.5, at: anchor)
        controller.endScrub(reportedBy: timeline(), at: anchor)

        let stale = timeline()
        let after = anchor.addingTimeInterval(NowPlayingController.seekSettleWindow + 0.1)
        let shown = try #require(controller.timeline(reportedBy: stale, at: after))
        #expect(shown == stale)
    }

    /// A display reconfiguration under a live drag must not move the user's music.
    @Test("canceling a drag does not seek")
    func cancelDoesNotSeek() {
        let controller = NowPlayingController()
        var seeks: [TimeInterval] = []
        controller.onSeek = { seeks.append($0) }
        controller.beginScrub(from: timeline(), toFraction: 0.9, at: anchor)
        controller.cancelScrub()
        #expect(seeks.isEmpty)
        #expect(controller.isScrubbing == false)
    }

    /// A live stream has no end to drag along.
    @Test("a track with no duration cannot be scrubbed")
    func noDurationNoScrub() {
        let controller = NowPlayingController()
        let stream = ActivityTimeline(elapsed: 5, duration: 0, anchor: anchor, rate: 1)
        controller.beginScrub(from: stream, toFraction: 0.5, at: anchor)
        #expect(controller.isScrubbing == false)
    }

    // MARK: - Transport

    /// A control drawn dimmed that still fires is worse than no dimming. `prohibitsSkip` is carried
    /// through the payload rather than guessed for exactly this.
    @Test("prohibitsSkip makes the skip buttons inert, and never the play button")
    func canSkipGates() {
        let controller = NowPlayingController()
        var sent: [NowPlayingControlCommand] = []
        controller.onCommand = { sent.append($0) }
        controller.isTransportAvailable = true
        controller.canSkip = false

        controller.send(.nextTrack)
        controller.send(.previousTrack)
        controller.send(.togglePlayPause)
        #expect(sent == [.togglePlayPause])
    }

    /// §10: a build with no route to the player draws no transport row at all, and nothing behind
    /// the row may fire either.
    @Test("no transport route means no commands go out")
    func unavailableTransport() {
        let controller = NowPlayingController()
        var sent: [NowPlayingControlCommand] = []
        controller.onCommand = { sent.append($0) }
        controller.isTransportAvailable = false
        controller.send(.togglePlayPause)
        #expect(sent.isEmpty)
    }

    /// The optimistic position belonged to a track that is no longer the one playing; leaving it
    /// would paint the new track's bar at the old one's offset for the settle window.
    @Test("skipping abandons a pending seek")
    func skipDropsOptimism() throws {
        let controller = NowPlayingController()
        controller.isTransportAvailable = true
        controller.beginScrub(from: timeline(), toFraction: 0.5, at: anchor)
        controller.endScrub(reportedBy: timeline(), at: anchor)
        controller.send(.nextTrack)

        let fresh = timeline(elapsed: 0)
        #expect(controller.timeline(reportedBy: fresh, at: anchor) == fresh)
    }
}

@Suite("Now Playing expanded layout")
struct NowPlayingLayoutTests {

    /// The 14" MacBook Pro's expanded island: 380x140 body with a 185x32 cutout out of the top,
    /// leaving 108pt to draw controls in.
    private var body: CGRect {
        let layout = ActivitySlotLayout.resolve(
            bodySize: IslandLayout.expandedBodySize,
            cutoutSize: CGSize(width: 185, height: 32)
        )
        return layout.frame(for: .expanded) ?? .zero
    }

    /// A control clipped by `IslandRootView`'s mask is visible as a button with its bottom shaved
    /// off and invisible as a hit region that no longer matches what the user can see.
    /// `IslandLayout.expandedBodySize` is a constant somebody may reasonably change; this is what
    /// fails when they do.
    @Test("the scrub bar and the transport row fit the expanded body")
    func fits() {
        #expect(NowPlayingExpandedLayout.fits(in: body))
    }

    @Test("both rows sit inside the body, in order, with no overlap")
    func rowsAreOrdered() {
        let scrubber = NowPlayingExpandedLayout.scrubberRect(in: body)
        let transport = NowPlayingExpandedLayout.transportRect(in: body)
        #expect(body.contains(scrubber))
        #expect(body.contains(transport))
        // Not adjacent any more: the bar is centerd in the gap between the header and the
        // transport row, so there is equal air above and below it. Ordering and non-overlap are what
        // matter, and they are what is asserted.
        #expect(scrubber.maxY <= transport.minY)
        #expect(transport.maxY <= body.maxY - NowPlayingExpandedLayout.bottomPadding)
    }

    /// Anchored to the bottom so a track with no artist tag does not move the transport row 15pt up
    /// under the pointer between songs.
    @Test("the rows are measured from the bottom, not the top")
    func anchoredToBottom() {
        let tall = CGRect(x: 0, y: 32, width: 380, height: 200)
        let short = CGRect(x: 0, y: 32, width: 380, height: 108)
        let fromBottom = { (rect: CGRect) in
            rect.maxY - NowPlayingExpandedLayout.transportRect(in: rect).minY
        }
        #expect(fromBottom(tall) == fromBottom(short))
    }

    /// What `TransportSelfTest` presses. If it is outside the body the press lands on the island and
    /// collapses it instead.
    @Test("the play button's center is inside the body")
    func playButtonIsReachable() {
        let center = NowPlayingExpandedLayout.playButtonCenter(in: body)
        #expect(body.contains(center))
        #expect(NowPlayingExpandedLayout.transportRect(in: body).contains(center))
    }

    @Test("the skip buttons flank the play button and stay inside the body")
    func skipButtonsAreReachable() {
        let previous = NowPlayingExpandedLayout.skipButtonCenter(in: body, isNext: false)
        let next = NowPlayingExpandedLayout.skipButtonCenter(in: body, isNext: true)
        let center = NowPlayingExpandedLayout.playButtonCenter(in: body)
        #expect(previous.x < center.x)
        #expect(next.x > center.x)
        #expect(body.contains(previous))
        #expect(body.contains(next))
    }

    @Test("the scrubber maps a fraction across its own width, clamped")
    func scrubberPoints() {
        let rect = NowPlayingExpandedLayout.scrubberRect(in: body)
        #expect(NowPlayingExpandedLayout.scrubberPoint(in: body, atFraction: 0).x == rect.minX)
        #expect(NowPlayingExpandedLayout.scrubberPoint(in: body, atFraction: 1).x == rect.maxX)
        #expect(NowPlayingExpandedLayout.scrubberPoint(in: body, atFraction: 2).x == rect.maxX)
        #expect(NowPlayingExpandedLayout.scrubberPoint(in: body, atFraction: -1).x == rect.minX)
    }
}

/// The two lines beside the cover, which are the one place in the open island where the text is
/// routinely wider than the room it has.
@Suite("The title block, and the marquee in it")
struct TitleBlockTests {

    /// The lines are layer-backed, so none of them sizes itself: the frames in `NowPlayingSlotView`
    /// are what reserve the room, and if they add up to more than the row they are centred in, a
    /// descender is clipped on somebody's Mac and nothing here would say so.
    ///
    @Test("the two lines fit the header row they are centred in")
    func titleBlockFitsTheHeader() {
        #expect(
            NowPlayingExpandedLayout.titleBlockHeight <= NowPlayingExpandedLayout.headerRowHeight
        )
        // And the arithmetic is the lines and the gap between them, not a number that happens
        // to be big enough — a spacing changed without the total moving is how these drift apart.
        #expect(
            NowPlayingExpandedLayout.titleBlockHeight
                == NowPlayingExpandedLayout.titleLineHeight
                + NowPlayingExpandedLayout.titleBlockSpacing
                + NowPlayingExpandedLayout.artistLineHeight
        )
    }

    /// **The badge takes room only when there is a badge**, and that is a correction rather than the
    /// first design. The line was reserved either way, so that a playlist crossing between a track
    /// whose format is known and one whose is not could not walk the two lines about — and on a
    /// library where the format is usually unknown that left 15pt of nothing under the artist and
    /// pushed the lines that are always there off the centre of the cover for one that never came.
    ///
    /// What still has to hold is that the badge, when it *is* there, stays inside the header row —
    /// that headroom is the whole reason it could be added without becoming a fourth row in the body
    /// and moving the island's bottom edge. See `NowPlayingSlotView.subtitleLine`.
    @Test("a block with a badge under it still fits the header row")
    func theFormatLineFitsWhenItIsThere() {
        #expect(NowPlayingExpandedLayout.formatLineHeight > 0)
        #expect(
            NowPlayingExpandedLayout.titleBlockHeightWithFormat
                == NowPlayingExpandedLayout.titleBlockHeight
                + NowPlayingExpandedLayout.formatLineSpacing
                + NowPlayingExpandedLayout.formatLineHeight
        )
        #expect(
            NowPlayingExpandedLayout.titleBlockHeightWithFormat
                <= NowPlayingExpandedLayout.headerRowHeight
        )
        // **The line has to hold Apple's tallest badge without resizing it**, which is what makes
        // 18 the number rather than a preference. `NowPlayingSlotView` draws these at their natural
        // size deliberately — see it — so a line shorter than the asset would clip a trademark
        // rather than shrink it.
        #expect(NowPlayingExpandedLayout.formatLineHeight >= 18)
        // **This line is now the tallest of the three, and that reverses what used to be asserted
        // here.** The old claim was that the format line is the least of them, because it is a fact
        // about the file rather than about the music — true while the line was Isleta's own 9pt
        // glyph and 11pt word. It stopped being true when the line started carrying *Apple's*
        // badge, which is a wordmark 18pt tall and not ours to shrink. What survives of the old
        // argument is in the type sizes rather than the box: the fallback still draws quieter than
        // the artist above it.
        #expect(NowPlayingExpandedLayout.formatLineHeight
                > NowPlayingExpandedLayout.artistLineHeight)
    }

    /// The title is meant to outrank the artist at a glance, which is a font-size claim the line
    /// heights have to keep up with — a title line shorter than the artist's would clip the very
    /// thing the hierarchy is for.
    @Test("the title's line is the taller of the two")
    func titleOutranksTheArtist() {
        #expect(
            NowPlayingExpandedLayout.titleLineHeight > NowPlayingExpandedLayout.artistLineHeight
        )
    }

    /// **A marquee that never stops is a line nobody reads the beginning of.** The hold is what
    /// makes it readable rather than merely complete, and it has to be a real share of the cycle
    /// rather than a token pause — so this pins it against the travel time of a title that is only
    /// modestly too long, which is the common case.
    @Test("the line stops long enough to be read between scrolls")
    func theHoldIsWorthHaving() {
        #expect(MarqueeMetrics.hold >= 1)

        // A title overrunning a 230pt column by 60pt: one cycle is that plus the gap, at `speed`.
        let travel = Double((60 + MarqueeMetrics.gap) / MarqueeMetrics.speed)
        let cycle = MarqueeMetrics.hold + travel
        // At least a quarter of the cycle is holding still. Below that the pause reads as a stutter
        // in a moving line rather than as the line stopping to be read.
        #expect(MarqueeMetrics.hold / cycle >= 0.25)
        // And not so much of it that the reader is left wondering whether it moves at all.
        #expect(MarqueeMetrics.hold / cycle <= 0.75)
    }
}

@Suite("Now Playing expanded rows")
struct NowPlayingExpandedRowsTests {

    typealias Layout = NowPlayingExpandedLayout

    /// The real thing, derived rather than pinned: the open island's own size, less the strip behind
    /// the cutout. Written this way because it was pinned once, and a later change to
    /// `expandedBodySize` failed these tests for saying 380 instead of for anything being wrong.
    private var body: CGRect {
        let size = IslandLayout.expandedBodySize
        let cutoutHeight: CGFloat = 32
        return CGRect(x: 0, y: cutoutHeight, width: size.width, height: size.height - cutoutHeight)
    }

    @Test("all three rows fit the body the island actually opens to")
    func rowsFit() {
        // A row that does not fit is not merely ugly. `IslandRootView` masks the content to the
        // island outline, so an overflowing transport row is drawn shaved *and* sits partly outside
        // the region a click is accepted in — visibly present, invisibly unhittable.
        #expect(Layout.fits(in: body))
        let needed = Layout.topPadding + Layout.bottomPadding
            + Layout.headerRowHeight + Layout.scrubberRowHeight + Layout.transportRowHeight
        #expect(needed <= body.height)
    }

    @Test("the rows stack without overlapping, in the reference's order")
    func rowsDoNotOverlap() {
        let header = Layout.headerRect(in: body)
        let scrubber = Layout.scrubberRowRect(in: body)
        let transport = Layout.transportRect(in: body)

        // Header above the bar above the buttons — the order the reference shows.
        #expect(header.maxY <= scrubber.minY)
        #expect(scrubber.maxY <= transport.minY)
        // And everything inside the content column.
        let content = Layout.contentRect(in: body)
        for rect in [header, scrubber, transport] {
            #expect(content.minY <= rect.minY)
            #expect(rect.maxY <= content.maxY + 0.001)
            #expect(content.minX <= rect.minX)
            #expect(rect.maxX <= content.maxX + 0.001)
        }
    }

    @Test("the artwork sits at the leading edge of the header and is square")
    func artworkIsSquareAndLeading() {
        let artwork = Layout.artworkRect(in: body)
        let header = Layout.headerRect(in: body)
        #expect(artwork.width == artwork.height)
        #expect(artwork.minX == header.minX)
        #expect(artwork.height <= header.height)
    }

    @Test("the bar grabs exactly what it draws, inset by the time labels")
    func barGrabsWhatItDraws() {
        // The view puts the times either side of the bar, so the bar is narrower than the row it
        // sits in. This rect is what a drag is measured against, and it has been wrong in both
        // directions during development — claiming the full column made a drag to 75% seek to 84%,
        // and claiming an inset the view did not draw made it seek to 67%.
        let row = Layout.scrubberRowRect(in: body)
        let bar = Layout.scrubberRect(in: body)
        let inset = Layout.timeLabelWidth + Layout.timeLabelSpacing
        #expect(bar.minX == row.minX + inset)
        #expect(bar.maxX == row.maxX - inset)
        #expect(bar.width > 0)
    }

    @Test("the bar has equal air above and below it")
    func barIsCenterdInItsGap() {
        // The reported fault: the bar crowded the controls with a gulf above it, because the rows
        // are bottom-anchored and all the slack collected in one place.
        let header = Layout.headerRect(in: body)
        let bar = Layout.scrubberRect(in: body)
        let transport = Layout.transportRect(in: body)
        let above = bar.minY - header.maxY
        let below = transport.minY - bar.maxY
        #expect(abs(above - below) < 0.51, "above \(above) below \(below)")
        #expect(above >= 0)
    }

    @Test("a fraction maps onto the bar, not onto the row the labels share")
    func scrubberPointTracksTheBar() {
        let bar = Layout.scrubberRect(in: body)
        #expect(Layout.scrubberPoint(in: body, atFraction: 0).x == bar.minX)
        #expect(Layout.scrubberPoint(in: body, atFraction: 1).x == bar.maxX)
        #expect(Layout.scrubberPoint(in: body, atFraction: 0.5).x == bar.midX)
        // Out-of-range fractions clamp rather than pointing off the island.
        #expect(Layout.scrubberPoint(in: body, atFraction: -3).x == bar.minX)
        #expect(Layout.scrubberPoint(in: body, atFraction: 9).x == bar.maxX)
    }

    @Test("the three transport buttons are centerd on the island and stay inside it")
    func transportIsCenterd() {
        // They used to center in the gap between two time labels on their own row. The labels moved
        // up to the bar, so the buttons center on the content column itself.
        let row = Layout.transportRect(in: body)
        let play = Layout.playButtonCenter(in: body)
        #expect(play.x == row.midX)

        let previous = Layout.skipButtonCenter(in: body, isNext: false)
        let next = Layout.skipButtonCenter(in: body, isNext: true)
        #expect(previous.x < play.x)
        #expect(next.x > play.x)
        // Symmetric about the play button, and both fully inside the row.
        #expect(abs((play.x - previous.x) - (next.x - play.x)) < 0.001)
        #expect(previous.x - Layout.transportButtonSize.width / 2 >= row.minX)
        #expect(next.x + Layout.transportButtonSize.width / 2 <= row.maxX)
    }

    @Test("a narrower island is reported as not fitting rather than drawn clipped")
    func narrowBodyDoesNotFit() {
        // `expandedBodySize` is a constant somebody may reasonably change; this is the assertion
        // that turns "the buttons look wrong" into a failing test.
        #expect(!Layout.fits(in: CGRect(x: 0, y: 0, width: 140, height: 108)))
        #expect(!Layout.fits(in: CGRect(x: 0, y: 0, width: 380, height: 60)))
    }
}

@Suite("The clock's rate")
@MainActor
struct ActivityClockRateTests {

    private let anchor = Date(timeIntervalSince1970: 1_700_000_000)

    private func model(cutout: CGSize = CGSize(width: 185, height: 32)) -> IslandScreenModel {
        IslandScreenModel(
            metricsByForm: [
                .rest: IslandShapeMetrics(bodySize: cutout, topCornerRadius: 0, bottomCornerRadius: 8),
                .flankedRest: IslandShapeMetrics(
                    bodySize: CGSize(width: cutout.width + 80, height: cutout.height),
                    topCornerRadius: 0,
                    bottomCornerRadius: 8
                ),
                .expanded: IslandShapeMetrics(
                    bodySize: IslandLayout.expandedBodySize,
                    topCornerRadius: 0,
                    bottomCornerRadius: 22
                ),
            ],
            notchKind: .hardware,
            cutoutSize: cutout
        )
    }

    private func playing(rate: Double) -> ActivityPresentations {
        BuiltInActivity.nowPlaying(
            title: "Song",
            artist: "Band",
            isPlaying: rate != 0,
            timeline: ActivityTimeline(elapsed: 10, duration: 200, anchor: anchor, rate: rate)
        ).presentations
    }

    /// The cost ordering, not the rate ordering. A second-gated numeral drawn at 10fps is still
    /// correct; a 10fps equaliser drawn once a second is a slideshow.
    @Test("frames beat seconds when both are on screen")
    func combining() {
        #expect(ActivityClockRate.stopped.combined(with: .seconds) == .seconds)
        #expect(ActivityClockRate.seconds.combined(with: .frames(10)) == .frames(10))
        #expect(ActivityClockRate.frames(10).combined(with: .seconds) == .frames(10))
        #expect(ActivityClockRate.frames(6).combined(with: .frames(10)) == .frames(10))
        #expect(ActivityClockRate.stopped.combined(with: .stopped) == .stopped)
    }

    /// The idle path, unchanged from before Now Playing existed.
    @Test("nothing on stage runs no clock")
    func emptyIsStopped() {
        #expect(model().clockRate == .stopped)
    }

    /// The equaliser no longer raises the shared clock — it drives itself, because ticking this
    /// clock invalidates every view on the island and measured 2.8% of a core with a track playing.
    /// What the shared clock still owes a playing track is the scrubber, once a second.
    @Test("a playing track runs the shared clock only as fast as the scrubber needs")
    func playingAtRest() {
        let model = model()
        model.setActivity(playing(rate: 1), kind: .nowPlaying, change: .none, reduceMotion: true)
        #expect(model.clockRate == .seconds)
    }

    /// Pausing really does take Isleta back to its idle profile, rather than to a slower animation
    /// of a still picture. This is the assertion §9 rests on.
    @Test("pausing stops the clock dead")
    func pausedIsStopped() {
        let model = model()
        model.setActivity(playing(rate: 0), kind: .nowPlaying, change: .none, reduceMotion: true)
        #expect(model.clockRate == .stopped)
    }

    /// §6.3 is a correctness requirement: the bars are drawn at fixed heights under Reduce Motion,
    /// so asking for frames would spend them redrawing an identical picture ten times a second.
    @Test("reduce motion drops the equaliser to the numerals' cadence")
    func reduceMotionDropsToSeconds() {
        let model = model()
        model.reduceMotion = true
        model.setActivity(playing(rate: 1), kind: .nowPlaying, change: .none, reduceMotion: true)
        #expect(model.clockRate == .seconds)
    }

    /// §9's rule is that the clock runs for what is *visible*. A synthesized island has no flanks,
    /// so the equaliser is not on screen at rest and must cost nothing.
    @Test("an island with no flanks runs no equaliser at rest")
    func noFlanksNoEqualiser() {
        let model = model(cutout: .zero)
        model.setActivity(playing(rate: 1), kind: .nowPlaying, change: .none, reduceMotion: true)
        // The compact badge carries no value, so there is nothing time-dependent on screen at all.
        #expect(model.clockRate == .stopped)
    }

    /// The bespoke renderer is keyed on the kind. An activity that merely carries a timeline is not
    /// a music player and gets numerals, not frames.
    @Test("another kind carrying a timeline gets seconds, not frames")
    func otherKindGetsSeconds() {
        let model = model()
        let presentations = ActivityPresentations(
            leading: ActivityContent(symbol: "bell.fill"),
            trailing: ActivityContent(
                value: .timeline(ActivityTimeline(elapsed: 0, duration: 60, anchor: anchor, rate: 1))
            )
        )
        model.setActivity(presentations, kind: .calendarAlert, change: .none, reduceMotion: true)
        #expect(model.clockRate == .seconds)
    }
}

@Suite("The Now Playing activity's slots")
struct NowPlayingActivityTests {

    private let anchor = Date(timeIntervalSince1970: 1_700_000_000)

    /// Putting the timeline in the trailing flank is what makes the equaliser run while playing and
    /// stop while paused, with no case for music anywhere in the clock.
    @Test("a timeline goes in the trailing flank so the clock can see it")
    func trailingCarriesTheTimeline() {
        let activity = BuiltInActivity.nowPlaying(
            title: "Song",
            isPlaying: true,
            timeline: ActivityTimeline(elapsed: 0, duration: 100, anchor: anchor, rate: 1)
        )
        guard case .timeline? = activity.presentations.trailing.value else {
            Issue.record("the trailing flank should carry the timeline")
            return
        }
        // And never both: the sliver is 40pt wide, and a glyph on top of the equaliser is what two
        // claimants on it looks like.
        #expect(activity.presentations.trailing.symbol == nil)
    }

    /// The scripting route knows only what is playing. An empty bar would be a promise it cannot
    /// keep, so it falls back to exactly what it produced before this milestone.
    @Test("a route with no position falls back to the glyph and no scrub bar")
    func noTimelineFallsBack() {
        let activity = BuiltInActivity.nowPlaying(title: "Song", isPlaying: true)
        #expect(activity.presentations.trailing.symbol == "waveform")
        #expect(activity.presentations.trailing.value == nil)
        #expect(activity.presentations.expanded.value == nil)
    }

    @Test("paused swaps the glyph without taking the activity away")
    func pausedKeepsTheActivity() {
        let activity = BuiltInActivity.nowPlaying(title: "Song", isPlaying: false)
        #expect(activity.presentations.trailing.symbol == "pause.fill")
        #expect(activity.presentations.compact.symbol == "pause.fill")
        #expect(activity.presentations.leading.isEmpty == false)
    }

    /// The leading flank is what makes the island widen to afford flanks at all — it is where the
    /// artwork goes, and it must never be empty or the island stays at cutout width with nothing
    /// visible until the user clicks.
    @Test("the leading flank always has something in it")
    func leadingIsNeverEmpty() {
        #expect(BuiltInActivity.nowPlaying(title: "Song").presentations.leading.isEmpty == false)
    }
}


@MainActor
@Suite("Now Playing equaliser")
struct NowPlayingEqualiserTests {

    typealias Bars = NowPlayingEqualiserView

    @Test("paused collapses every bar to the same line, whatever it was drawing")
    func pausedCollapsesToALine() {
        // The reported behavior was bars freezing mid-pattern. The reference shows a row of dots on
        // one line, so paused has to mean minimum height for every bar at every instant.
        for time in [0.0, 0.17, 3.4, 91.2, 10_000.5] {
            let heights = Bars.heights(at: time, playing: false, reduceMotion: false)
            #expect(heights.count == Bars.count)
            #expect(heights.allSatisfy { $0 == Bars.minimumHeight })
        }
    }

    @Test("every frame has specific highs and lows rather than a flat row")
    func framesHaveShape() {
        // The owner asked for specific highs and lows across the row. A frame whose bars are all
        // about the same height is a loading placeholder, not a level meter.
        for frame in Bars.frames {
            let spread = (frame.max() ?? 0) - (frame.min() ?? 0)
            #expect(spread > 0.3, "frame \(frame) is too flat to read as a level meter")
        }
    }

    @Test("no two adjacent bars peak together")
    func adjacentBarsDiffer() {
        // Bars rising and falling in step are the one thing that makes a synthesized equaliser look
        // synthesized.
        for frame in Bars.frames {
            for (left, right) in zip(frame, frame.dropFirst()) {
                #expect(abs(left - right) > 0.05, "adjacent bars \(left)/\(right) move together")
            }
        }
    }

    @Test("the bars glide between frames rather than snapping to them")
    func heightsAreContinuous() {
        // "Animate smoothly into their change" is the requirement. Sampling either side of a frame
        // boundary must not jump: the eased blend is what makes the motion continuous.
        var previous = Bars.heights(at: 0, playing: true, reduceMotion: false)
        for time in stride(from: 0.02, through: 4.0, by: 0.02) {
            let heights = Bars.heights(at: time, playing: true, reduceMotion: false)
            for index in 0..<Bars.count {
                #expect(abs(heights[index] - previous[index]) < 0.12,
                        "bar \(index) jumped at t=\(time)")
            }
            previous = heights
        }
    }

    @Test("the pattern cycles forever without indexing out of range")
    func patternCyclesSafely() {
        // A long track must wrap rather than crash a view that draws continuously.
        for time in stride(from: 0.0, through: 900.0, by: 0.31) {
            let heights = Bars.heights(at: time, playing: true, reduceMotion: false)
            #expect(heights.count == Bars.count)
            #expect(heights.allSatisfy { $0 >= Bars.minimumHeight && $0 <= 1.0 })
        }
        // Negative and non-finite inputs are clamped rather than trapped.
        #expect(Bars.heights(at: -12, playing: true, reduceMotion: false).count == Bars.count)
    }

    @Test("reduce motion holds one frame instead of animating")
    func reduceMotionIsStatic() {
        // A static silhouette below full height reads as a meter at rest; all-equal would read as a
        // loading placeholder (§6.3). It must also not vary with time, or the clock would still be
        // spending frames redrawing an identical picture.
        let a = Bars.heights(at: 1.0, playing: true, reduceMotion: true)
        let b = Bars.heights(at: 99.0, playing: true, reduceMotion: true)
        #expect(a == b)
        #expect(a == Bars.frames[0])
    }

    @Test("every frame declares a height for every bar")
    func framesMatchBarCount() {
        // An index out of a frame is a crash in a view that draws continuously; this is the cheapest
        // place to catch a mismatched edit.
        for frame in Bars.frames {
            #expect(frame.count == Bars.count)
            #expect(frame.allSatisfy { $0 > Bars.minimumHeight && $0 <= 1.0 })
        }
    }

    @Test("the pattern is slow enough to read as a glide, not a flicker")
    func patternCadenceIsLegible() {
        // The redraw rate is no longer capped — the view is display-linked, because capping it saved
        // 0.07 percentage points (0.42% against 0.49%) and looked stepped for it. What still has to
        // hold is the *pattern* cadence: frames far enough apart that the eased blend between them
        // is visible travel rather than a stutter.
        #expect(Bars.frameDuration >= 0.2)
        #expect(Bars.frameDuration <= 0.6)
    }

    @MainActor
    @Test("the equaliser does not drive the island's shared clock")
    func equaliserDoesNotRaiseTheSharedClock() {
        // This is the expensive lesson, kept as an assertion. Sampling the bars off
        // `IslandScreenModel`'s clock invalidates the island's whole content tree at the
        // equaliser's rate and measured 2.8% of a core against §9's 0.3% ceiling. A playing track
        // must leave the shared clock at the scrubber's pace.
        let model = IslandScreenModel(
            metricsByForm: [:],
            notchKind: .hardware,
            cutoutSize: CGSize(width: 185, height: 32)
        )
        let playing = BuiltInActivity.nowPlaying(
            title: "Avril 14th",
            artist: "Aphex Twin",
            isPlaying: true,
            timeline: ActivityTimeline(elapsed: 0, duration: 180, anchor: Date(), rate: 1)
        ).presentations
        model.setActivity(playing, kind: .nowPlaying, change: .none, reduceMotion: false)
        #expect(model.clockRate != .frames(Int(Bars.updatesPerSecond)))
    }
}

/// The CoreAnimation rewrite, and the three things the measured arm did not model.
///
/// `heights(at:playing:reduceMotion:)` above is the specification; these pin the keyframes the
/// render server is actually handed to it, so the two cannot drift apart silently. That matters more
/// than usual here: nothing draws from this process any more, so a wrong keyframe table is invisible
/// to every other check in the suite and visible only on screen.
/// The cover, worn by the six bars and by the cover itself.
///
/// Two features, one suite, because they are one behavior to the user: the collapsed island says
/// what is playing with a colored row and says whether it is playing by drawing the cover back.
/// Both are gated on the same accessibility switch, and a build where one of them honored
/// `albumColor` and the other did not would be the harder bug to see.
@Suite("The cover, worn")
@MainActor
struct NowPlayingCoverColorTests {

    private func controller() -> NowPlayingController { NowPlayingController() }

    private static func stripedCover() -> CGImage? {
        let width = 48
        let height = 32
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        for index in 0..<6 {
            context.setFillColor(
                red: Double(index) / 6, green: 1 - Double(index) / 6, blue: 0.5, alpha: 1
            )
            context.fill(CGRect(x: index * 8, y: 0, width: 8, height: height))
        }
        return context.makeImage()
    }

    @Test("a cover gives the bars one color each")
    func aCoverColorsTheBars() throws {
        let controller = controller()
        let cover = try #require(Self.stripedCover())
        controller.setArtwork(cover, reduceMotion: false)
        let bars = try #require(controller.barColors(increaseContrast: false))
        #expect(bars.count == NowPlayingEqualiserView.count)
    }

    /// The row and the scrub bar are the same color, which is the whole revision: the trailing bar
    /// is the accent itself and the rest are that accent, dimmer.
    @Test("the row is the scrub bar's own color, leaning")
    func theRowIsTheAccent() throws {
        let controller = controller()
        let cover = try #require(Self.stripedCover())
        controller.setArtwork(cover, reduceMotion: false)
        let bars = try #require(controller.barColors(increaseContrast: false))
        #expect(bars.last == controller.albumColor)
        let hues = bars.map { AlbumColor.hsb($0).hue }
        #expect(hues.allSatisfy { abs($0 - hues[0]) < 1e-9 })
    }

    /// The regression this suite now exists to catch, and it shipped in the settings cut: the accent
    /// was behind a `usesAlbumColor` flag whose two writers were deleted with the Appearance pane,
    /// so it defaulted to `false` and **no cover was ever worn** — reported from use, on a fresh
    /// launch, one commit later. There is no flag now; a controller straight out of `init` colors
    /// the row the moment it is handed a cover.
    @Test("a controller with nothing pushed into it still wears the cover")
    func aFreshControllerWearsTheCover() throws {
        let controller = NowPlayingController()
        let cover = try #require(Self.stripedCover())
        controller.setArtwork(cover, reduceMotion: false)
        #expect(controller.albumColor != nil)
        #expect(controller.barColors(increaseContrast: false) != nil)
        #expect(controller.accent(.white, increaseContrast: false) != .white)
    }

    /// No cover is the only "off" there is, and it has to answer exactly as the switch used to.
    @Test("no artwork is the whole of the gate")
    func noArtworkGatesTheRow() {
        let controller = controller()
        #expect(controller.albumColor == nil)
        #expect(controller.barColors(increaseContrast: false) == nil)
        #expect(controller.accent(.white, increaseContrast: false) == .white)
    }

    /// The same rule `accent(_:increaseContrast:)` follows: no color taken off an arbitrary image
    /// can be promised any contrast, and white is the answer the user has already given.
    @Test("increase contrast puts the bars back to white")
    func increaseContrastDropsTheRow() throws {
        let controller = controller()
        let cover = try #require(Self.stripedCover())
        controller.setArtwork(cover, reduceMotion: false)
        #expect(controller.barColors(increaseContrast: true) == nil)
    }

    /// A row outliving the track it was read from is the next song's equaliser wearing the last
    /// one's color — the same failure `albumColor` is cleared for, and it comes free here because
    /// the row is derived from the accent rather than stored beside it.
    @Test("the row goes with the track")
    func resetClearsTheRow() throws {
        let controller = controller()
        let cover = try #require(Self.stripedCover())
        controller.setArtwork(cover, reduceMotion: false)
        #expect(controller.barColors(increaseContrast: false) != nil)
        controller.reset()
        #expect(controller.barColors(increaseContrast: false) == nil)
    }

    @Test("a palette read for a different number of bars is refused, not padded")
    func aMismatchedRowIsRefused() {
        let short = Array(repeating: AlbumColor(red: 1, green: 0, blue: 0), count: 3)
        let view = NowPlayingEqualiserView(isPlaying: true, reduceMotion: false, colors: short)
        #expect(view.resolvedColorsForTesting == nil)
    }

    // MARK: - The cover drawing back

    /// The regression this suite is really for.
    ///
    /// The first version gated the cover on *this slot's* content carrying a timeline. Each sliver
    /// gets its own `ActivityContent`, and `BuiltInActivity.nowPlaying` puts the timeline in the
    /// trailing flank alone — so the gate was false on every collapsed island and the cover never
    /// drew back, while the equaliser in the next sliver sank to its dots correctly off the same
    /// `isPlaying`. Nothing about that looks broken; it looks like the feature was never built.
    @Test("the leading flank carries no timeline, so the cover cannot be gated on one")
    func theLeadingFlankHasNoTimeline() {
        let activity = BuiltInActivity.nowPlaying(
            title: "A song",
            isPlaying: false,
            timeline: ActivityTimeline(
                elapsed: 10, duration: 200,
                anchor: Date(timeIntervalSince1970: 1_700_000_000), rate: 0
            )
        )
        #expect(activity.presentations.content(for: .leading).value == nil)
        #expect(activity.presentations.content(for: .trailing).value != nil)
    }

    @Test("the cover draws back when there is a route and it says paused")
    func theCoverKnowsWhenItIsPaused() {
        typealias Slot = NowPlayingSlotView
        #expect(Slot.coverIsPaused(isTransportAvailable: true, isPlaying: false))
        #expect(!Slot.coverIsPaused(isTransportAvailable: true, isPlaying: true))
        // No route is not "paused": `isPlaying` is then a `false` nobody ever set, and a cover
        // permanently at 88 % is this feature failing in the one place nobody would look.
        #expect(!Slot.coverIsPaused(isTransportAvailable: false, isPlaying: false))
        #expect(!Slot.coverIsPaused(isTransportAvailable: false, isPlaying: true))
    }

    @Test("a paused cover is smaller and dimmer than a playing one")
    func pausedCoverDrawsBack() {
        #expect(NowPlayingArtworkView.pausedScale < 1)
        #expect(NowPlayingArtworkView.pausedOpacity < 1)
        // Small on purpose. Past this it stops reading as the same square, quieter, and starts
        // reading as the artwork being replaced.
        #expect(NowPlayingArtworkView.pausedScale > 0.8)
    }
}

@Suite("The equaliser's layers")
struct NowPlayingEqualiserLayerTests {

    typealias Bars = NowPlayingEqualiserView

    @Test("the keyframes handed to CoreAnimation are the designed frames, in points")
    func keyframesMatchTheDesignedFrames() {
        let track = 14.0
        let width = 2.25
        for bar in 0..<Bars.count {
            let values = Bars.keyframeHeights(forBar: bar, trackHeight: track, barWidth: width)
            // Seven values for six frames: the cycle closes on itself so `repeatCount = .infinity`
            // does not jump at the seam.
            #expect(values.count == Bars.frames.count + 1)
            #expect(values.first == values.last)
            for (index, frame) in Bars.frames.enumerated() {
                #expect(abs(values[index] - track * frame[bar]) < 0.0001)
            }
        }
    }

    @Test("a keyframe is what the pure function says at that instant")
    func keyframesAgreeWithTheSpecification() {
        // The one assertion that ties the two implementations together. If someone edits `frames`
        // and only one of them notices, this fails.
        let track = 14.0
        let width = 2.25
        for step in 0..<Bars.frames.count {
            let time = Double(step) * Bars.frameDuration
            let expected = Bars.heights(at: time, playing: true, reduceMotion: false)
            for bar in 0..<Bars.count {
                let keyframes = Bars.keyframeHeights(forBar: bar, trackHeight: track, barWidth: width)
                #expect(abs(keyframes[step] - max(width, track * expected[bar])) < 0.0001)
            }
        }
    }

    @Test("the cycle is one trip through the frames")
    func cycleDurationCoversEveryFrame() {
        // The repeating animation's duration and the pure function's phase have to be the same
        // number, or the wall-clock `timeOffset` that keeps two equalisers in step lands on the
        // wrong part of the pattern.
        #expect(Bars.cycleDuration == Bars.frameDuration * Double(Bars.frames.count))
    }

    @Test("a bar at rest is a circle, not a squashed capsule")
    func theDotIsRound() {
        // The measured arm animated `transform.scale.y`, which squashes the rounded caps with the
        // bar and leaves a flat sliver where the reference shows a dot. Animating the height instead
        // keeps `cornerRadius` alone — and the floor has to be the bar's own width, or a bar whose
        // width exceeds `minimumHeight × trackHeight` still collapses below its own cap radius.
        let width = 2.25
        let dot = Bars.dotHeight(trackHeight: 14, barWidth: width)
        #expect(dot >= width)
        // A narrow bar in a tall track takes the fractional floor instead.
        #expect(Bars.dotHeight(trackHeight: 40, barWidth: 1) == 40 * Bars.minimumHeight)
    }

    @Test("no keyframe collapses a bar below its own width")
    func noKeyframeIsThinnerThanItIsWide() {
        // A pattern value below the cap radius would draw a capsule that is wider than it is tall,
        // which reads as a lozenge on its side rather than as a bar.
        for bar in 0..<Bars.count {
            let values = Bars.keyframeHeights(forBar: bar, trackHeight: 14, barWidth: 2.25)
            #expect(values.allSatisfy { $0 >= 2.25 })
        }
    }

    // MARK: - Pixel snapping

    @Test("every bar edge lands on a device pixel at 1x and at 2x")
    func barsAreSnappedToTheGrid() {
        // A layer straddling a pixel boundary is drawn with a blurred edge on both sides, and six of
        // them side by side read as a smudge. `Canvas` hid this behind antialiasing over a shape
        // that was moving anyway; a layer holds still horizontally, so the softness is legible.
        for scale in [1.0, 2.0, 3.0] {
            let geometry = EqualiserBarGeometry.resolve(size: Bars.trackSize, scale: scale)
            #expect(geometry.bars.count == Bars.count)
            for bar in geometry.bars {
                #expect(abs((bar.x * scale).rounded() - bar.x * scale) < 0.0001)
                #expect(abs(((bar.x + bar.width) * scale).rounded() - (bar.x + bar.width) * scale) < 0.0001)
            }
            #expect(abs((geometry.centerY * scale).rounded() - geometry.centerY * scale) < 0.0001)
        }
    }

    @Test("snapping keeps the bars inside the track and apart from each other")
    func snappingDoesNotOverlapOrOverflow() {
        for scale in [1.0, 2.0] {
            let geometry = EqualiserBarGeometry.resolve(size: Bars.trackSize, scale: scale)
            #expect(geometry.bars[0].x >= 0)
            let last = geometry.bars[Bars.count - 1]
            #expect(last.x + last.width <= Bars.trackSize.width + 0.0001)
            for (left, right) in zip(geometry.bars, geometry.bars.dropFirst()) {
                #expect(right.x >= left.x + left.width, "bars overlap at \(scale)x")
            }
        }
    }

    @Test("widths differ by at most one pixel after snapping")
    func snappingDoesNotAccumulateError() {
        // Rounding the *width* and then laying the bars out is the version that looks right and is
        // wrong: the accumulated error walks the last bar off the grid. Snapping both edges bounds
        // the difference at one pixel.
        for scale in [1.0, 2.0, 3.0] {
            let widths = EqualiserBarGeometry.resolve(size: Bars.trackSize, scale: scale)
                .bars.map(\.width)
            let spread = (widths.max() ?? 0) - (widths.min() ?? 0)
            #expect(spread <= 1.0 / scale + 0.0001, "widths \(widths) at \(scale)x")
        }
    }

    @Test("a view with no window yet is treated as 1x rather than dividing by zero")
    func zeroScaleDegradesToOnePixel() {
        // `backingScaleFactor` is what a view reports before it has a window, and the geometry is
        // resolved once in `layout()` before `viewDidMoveToWindow` has run.
        let geometry = EqualiserBarGeometry.resolve(size: Bars.trackSize, scale: 0)
        #expect(geometry.bars.count == Bars.count)
        #expect(geometry.bars.allSatisfy { $0.width > 0 && $0.width.isFinite })
    }

    @Test("a degenerate track produces bars rather than negative widths")
    func aCollapsedTrackIsSafe() {
        // The island rebuilds panels on a display change, and SwiftUI lays a representable out at
        // zero before it has a size. A negative width would be a CoreAnimation exception.
        for size in [CGSize.zero, CGSize(width: 4, height: 14), CGSize(width: 21, height: 0)] {
            let geometry = EqualiserBarGeometry.resolve(size: size, scale: 2)
            #expect(geometry.bars.allSatisfy { $0.width > 0 })
            #expect(geometry.centerY >= 0)
        }
    }
}

@MainActor
@Suite("Opening the player")
struct OpenPlayerTests {

    @Test("tapping asks the app shell to open whatever is playing")
    func openAsksForTheBundle() {
        let controller = NowPlayingController()
        var opened: [String] = []
        controller.onOpenPlayer = { opened.append($0) }

        controller.apply(
            isPlaying: true,
            canSkip: true,
            isTransportAvailable: true,
            playerBundleIdentifier: "com.apple.Music",
            reduceMotion: true
        )
        controller.openPlayer()
        #expect(opened == ["com.apple.Music"])
    }

    @Test("with no player known, there is nothing to tap and nothing happens")
    func noPlayerNoTarget() {
        // A tap target that does nothing teaches the user the island is unresponsive, which is worse
        // than no target. The view reads `canOpenPlayer` to decide whether to attach one at all.
        let controller = NowPlayingController()
        var opened: [String] = []
        controller.onOpenPlayer = { opened.append($0) }

        #expect(!controller.canOpenPlayer)
        controller.openPlayer()
        #expect(opened.isEmpty)
    }

    @Test("the target appears and disappears with the player")
    func targetFollowsThePlayer() {
        let controller = NowPlayingController()
        controller.apply(
            isPlaying: true, canSkip: true, isTransportAvailable: true,
            playerBundleIdentifier: "com.spotify.client", reduceMotion: true
        )
        #expect(controller.canOpenPlayer)

        // A source that stops reporting a bundle — the scripting route on a player it cannot name —
        // takes the target away rather than leaving one pointing at the last app that played.
        controller.apply(
            isPlaying: true, canSkip: true, isTransportAvailable: true,
            playerBundleIdentifier: nil, reduceMotion: true
        )
        #expect(!controller.canOpenPlayer)
    }

    @Test("a changed player is noticed even when nothing else about the track is")
    func bundleChangeIsNotSwallowed() {
        // `apply` returns early when nothing changed, and the bundle has to be part of that
        // comparison — otherwise switching from Music to Spotify mid-session would leave the tap
        // opening the wrong app.
        let controller = NowPlayingController()
        controller.apply(
            isPlaying: true, canSkip: true, isTransportAvailable: true,
            playerBundleIdentifier: "com.apple.Music", reduceMotion: true
        )
        controller.apply(
            isPlaying: true, canSkip: true, isTransportAvailable: true,
            playerBundleIdentifier: "com.spotify.client", reduceMotion: true
        )
        #expect(controller.playerBundleIdentifier == "com.spotify.client")
    }
}

@Suite("Shuffle and repeat")
@MainActor
struct NowPlayingQueueSettingsTests {

    private func controller() -> NowPlayingController {
        let controller = NowPlayingController()
        controller.apply(
            isPlaying: true, canSkip: true, isTransportAvailable: true,
            playerBundleIdentifier: "com.apple.Music", reduceMotion: true
        )
        return controller
    }

    @Test("nothing is claimed before the user asks for anything")
    func startsOff() {
        // Music reports neither setting, so the opening claim has to be the one that asserts least.
        let controller = controller()
        #expect(!controller.isShuffling)
        #expect(controller.repeatMode == .off)
    }

    @Test("repeat cycles off, all, one, and back")
    func repeatCycles() {
        let controller = controller()
        controller.send(.toggleRepeat)
        #expect(controller.repeatMode == .all)
        controller.send(.toggleRepeat)
        #expect(controller.repeatMode == .one)
        controller.send(.toggleRepeat)
        #expect(controller.repeatMode == .off)
    }

    @Test("only repeating a single track shows the numeral")
    func onlyRepeatOneIsNumbered() {
        #expect(NowPlayingRepeatMode.off.symbol == "repeat")
        #expect(NowPlayingRepeatMode.all.symbol == "repeat")
        #expect(NowPlayingRepeatMode.one.symbol == "repeat.1")
    }

    @Test("both settings light up, and only when they are on")
    func lightsUpWhenOn() {
        #expect(!NowPlayingRepeatMode.off.isOn)
        #expect(NowPlayingRepeatMode.all.isOn)
        #expect(NowPlayingRepeatMode.one.isOn)
    }

    @Test("shuffle toggles")
    func shuffleToggles() {
        let controller = controller()
        controller.send(.toggleShuffle)
        #expect(controller.isShuffling)
        controller.send(.toggleShuffle)
        #expect(!controller.isShuffling)
    }

    @Test("a different player starts from nothing again")
    func changingPlayerClearsBoth() {
        // These describe one application's queue. Carrying Music's settings over to Spotify would
        // be the island asserting a state it has never been told anything about.
        let controller = controller()
        controller.send(.toggleShuffle)
        controller.send(.toggleRepeat)
        controller.apply(
            isPlaying: true, canSkip: true, isTransportAvailable: true,
            playerBundleIdentifier: "com.spotify.client", reduceMotion: true
        )
        #expect(!controller.isShuffling)
        #expect(controller.repeatMode == .off)
    }

    @Test("neither is adopted when there is no transport to send it through")
    func noTransportChangesNothing() {
        // The highlight says "you asked for this". With no route to the player, nothing was asked.
        let controller = NowPlayingController()
        controller.apply(
            isPlaying: true, canSkip: true, isTransportAvailable: false,
            playerBundleIdentifier: "com.apple.Music", reduceMotion: true
        )
        controller.send(.toggleShuffle)
        controller.send(.toggleRepeat)
        #expect(!controller.isShuffling)
        #expect(controller.repeatMode == .off)
    }

    @Test("toggling shuffle does not abandon a seek that is still settling")
    func shuffleLeavesAPendingSeekAlone() {
        // A skip does invalidate it — the position belonged to a track that is no longer playing.
        // Shuffle changes neither the track nor the playhead.
        let controller = controller()
        let now = Date()
        let base = ActivityTimeline(elapsed: 0, duration: 200, anchor: now, rate: 1)
        controller.beginScrub(from: base, toFraction: 0.5, at: now)
        controller.endScrub(reportedBy: base, at: now)
        let afterSeek = controller.timeline(reportedBy: base, at: now)?.elapsed
        controller.send(.toggleShuffle)
        #expect(controller.timeline(reportedBy: base, at: now)?.elapsed == afterSeek)
        #expect(afterSeek == 100)

        // ...and the skip beside it still does.
        controller.send(.nextTrack)
        #expect(controller.timeline(reportedBy: base, at: now)?.elapsed == 0)
    }
}

@Suite("A radio station has no queue")
@MainActor
struct NowPlayingRadioStationTests {

    private func controller(radio: Bool) -> NowPlayingController {
        let controller = NowPlayingController()
        controller.apply(
            isPlaying: true, canSkip: true, isTransportAvailable: true,
            playerBundleIdentifier: "com.apple.Music", isRadioStation: radio, reduceMotion: true
        )
        return controller
    }

    @Test("shuffle and repeat are unavailable on a station")
    func stationHasNoQueueBehavior() {
        #expect(!controller(radio: true).canChangeQueueBehavior)
        #expect(controller(radio: false).canChangeQueueBehavior)
    }

    @Test("pressing them on a station changes nothing")
    func stationRefusesTheCommands() {
        // Measured on Apple Music radio: the MRCommand toggles, the adapter's explicit mode calls
        // and AppleScript's own setters all return successfully and leave the player unchanged. A
        // highlight that lit anyway would be the island asserting a state nothing ever entered.
        let controller = controller(radio: true)
        var sent: [NowPlayingControlCommand] = []
        controller.onCommand = { sent.append($0) }
        controller.send(.toggleShuffle)
        controller.send(.toggleRepeat)
        #expect(sent.isEmpty)
        #expect(!controller.isShuffling)
        #expect(controller.repeatMode == .off)
    }

    @Test("skipping is still allowed on a station")
    func stationStillSkips() {
        // The two limits are unrelated: a station usually permits skipping and has no queue, and a
        // stream that forbids skipping still has one. Answering both with `canSkip` grayed the wrong
        // pair in each direction.
        let controller = controller(radio: true)
        var sent: [NowPlayingControlCommand] = []
        controller.onCommand = { sent.append($0) }
        controller.send(.nextTrack)
        #expect(sent == [.nextTrack])
    }

    @Test("a stream that forbids skipping can still be shuffled")
    func prohibitsSkipLeavesTheQueueAlone() {
        let controller = NowPlayingController()
        controller.apply(
            isPlaying: true, canSkip: false, isTransportAvailable: true,
            playerBundleIdentifier: "com.apple.Music", isRadioStation: false, reduceMotion: true
        )
        var sent: [NowPlayingControlCommand] = []
        controller.onCommand = { sent.append($0) }
        controller.send(.nextTrack)
        controller.send(.toggleShuffle)
        #expect(sent == [.toggleShuffle])
    }

    @Test("starting a station drops what was asked for on the queue that preceded it")
    func stationClearsWhatWasAsked() {
        let controller = controller(radio: false)
        controller.send(.toggleShuffle)
        controller.send(.toggleRepeat)
        controller.apply(
            isPlaying: true, canSkip: true, isTransportAvailable: true,
            playerBundleIdentifier: "com.apple.Music", isRadioStation: true, reduceMotion: true
        )
        #expect(!controller.isShuffling)
        #expect(controller.repeatMode == .off)
    }

    @Test("leaving a station is noticed even when nothing else about the track is")
    func leavingAStationIsNotSwallowed() {
        // `apply` returns early when nothing changed, so the station flag has to be part of that
        // comparison — otherwise the two controls stay dimmed until something unrelated moves.
        let controller = controller(radio: true)
        controller.apply(
            isPlaying: true, canSkip: true, isTransportAvailable: true,
            playerBundleIdentifier: "com.apple.Music", isRadioStation: false, reduceMotion: true
        )
        #expect(controller.canChangeQueueBehavior)
    }
}

/// Where Semi-Liquid Glass stops being black, and where it never starts.
@Suite("The semi-glass underlay")
struct SemiGlassUnderlayTests {

    /// A 14" MacBook Pro's cutout, which is what the island is at rest.
    static let resting: CGFloat = 32
    static let peek: CGFloat = 40
    static let open: CGFloat = 200

    private func stops(_ height: CGFloat) -> [(opacity: Double, location: Double)] {
        SemiGlassUnderlay.stops(inHeight: height, restingHeight: Self.resting)
    }

    // MARK: - The closed island

    @Test("a closed island has no glass at its bottom edge")
    func restIsSolid() {
        // Reported from hardware. At rest the island *is* the cutout, so its bottom edge is the
        // bottom of the notch — and a glass rim there is a white line drawn across a hole.
        #expect(stops(Self.resting).allSatisfy { $0.opacity == SemiGlassUnderlay.topOpacity })
        #expect(SemiGlassUnderlay.fadePresence(inHeight: Self.resting, restingHeight: Self.resting) == 0)
    }

    @Test("a peek has none either — it is the closed island wearing a larger shape")
    func peekIsSolid() {
        // A peek is an invitation to click, never the click's result. Changing material for it would
        // make the invitation look like a different island.
        #expect(stops(Self.peek).allSatisfy { $0.opacity == SemiGlassUnderlay.topOpacity })
    }

    @Test("the tip arrives over the opening rather than appearing at the end of it")
    func theTipRampsIn() {
        // The height handed in is the *animated* one, so this ramp plays on the island's own spring.
        // A step would be a second animation on a different clock, which is what §6.1 exists to stop.
        var previous = 0.0
        for height in stride(from: Double(Self.resting), through: Double(Self.open), by: 2) {
            let presence = SemiGlassUnderlay.fadePresence(
                inHeight: height, restingHeight: Self.resting
            )
            #expect(presence >= previous, "the tip shrank while the island grew, at \(height)pt")
            #expect(presence <= 1)
            previous = presence
        }
        #expect(previous == 1, "an open island is meant to reach the full tip")
    }

    // MARK: - The open island

    @Test("the top is solid, so the island cannot read lighter than the bezel")
    func theTopIsBlack() {
        // The flat 0.55 veil this replaced made the top of the island a shade above the bezel it has
        // to disappear into, which is the exact failure §6.4 spells `Color.black` in sRGB to avoid.
        #expect(SemiGlassUnderlay.topOpacity == 1)
        for height in [Self.resting, Self.peek, 140, Self.open] {
            #expect(stops(height).first?.opacity == 1)
            #expect(stops(height).first?.location == 0)
        }
    }

    @Test("the tip is glass, but keeps enough black to still be an island")
    func theTipIsGlass() {
        // It reached fully clear, and that took the island's bottom edge with it: over a bright
        // window the last centimetre became whatever was behind it, white text included. The floor
        // holds the edge while leaving what is behind the island plainly legible.
        #expect(SemiGlassUnderlay.bottomOpacity > 0, "a clear tip is a hole, not a glass island")
        #expect(SemiGlassUnderlay.bottomOpacity < 0.5, "and past this it stops reading as glass")
        #expect(stops(Self.open).last?.location == 1)
        // Within a tolerance: the last stop is computed as `top + (bottom - top) * ease(1)`, which
        // is 0.32000000000000006 rather than 0.32. Asserting the arithmetic lands where it is aimed,
        // not that a double round-trips exactly.
        #expect(abs((stops(Self.open).last?.opacity ?? 0) - SemiGlassUnderlay.bottomOpacity) < 0.000_001)
    }

    @Test("the fade leaves the solid run with no corner in it")
    func theFadeHasNoHardEdge() {
        // A straight ramp meets the flat black at an angle — constant, then falling at a fixed rate
        // — and the eye reads that corner as an edge drawn across the island, which is the one thing
        // this style is trying not to have. Smoothstep is flat at both ends, so the first step down
        // is a fraction of the steepest one instead of equal to it.
        let s = stops(Self.open)
        let deltas = zip(s.dropFirst(1), s.dropFirst(2)).map { $0.opacity - $1.opacity }
        let first = deltas.first ?? 0
        let steepest = deltas.max() ?? 0
        #expect(first < steepest / 3, "the fade has to enter gently, not at full rate")
        #expect((deltas.last ?? 0) < steepest / 3, "and level off before the island's own edge")
        #expect(deltas.allSatisfy { $0 >= -0.000_001 }, "and never lighten going down")
    }

    @Test("the solid run is flat rather than easing the whole way down")
    func thereIsRealBlackAndNotJustAGradient() {
        // Two stops instead of three is the flat-veil bug in a new shape: a gradient from black to
        // clear over the whole island has black at exactly one row of pixels and is lighter than the
        // bezel everywhere else.
        let open = stops(Self.open)
        #expect(open[0].opacity == open[1].opacity)
        #expect(open[1].location > 0.5, "the solid run has to be most of the island")
    }

    @Test("the fade is a distance from the bottom, not a fraction of the island")
    func theFadeIsAbsolute() {
        // "The bottom tip" has to mean the same thing on a 200pt open island and a 160pt one. A
        // fraction does not: it would be 50pt on one and 40pt on the other. Both of these are past
        // the ramp, so the only variable left is the rule under test.
        func fade(_ h: CGFloat) -> Double {
            (1 - SemiGlassUnderlay.fadeStart(inHeight: h, restingHeight: Self.resting)) * Double(h)
        }
        #expect(abs(fade(200) - fade(160)) < 0.001)
        #expect(abs(fade(200) - Double(SemiGlassUnderlay.fadeHeight)) < 0.001)
    }

    @Test("the fade's locations are fractions of the island, never of the panel")
    func theFadeIsMeasuredAgainstTheIsland() {
        // Semi-Liquid Glass shipped inert, and this is the arithmetic that made it so. The stops
        // are fractions of the *island's* height, and a `LinearGradient` used as a mask spans
        // whatever view it is given. Given the panel — which is a fixed 608x400 and never resizes —
        // the whole fade lands below the island and every pixel of the island falls in the flat
        // opaque run. Solid black at every size, which is indistinguishable from the style working
        // on any dark desktop.
        //
        // This asserts the trap rather than the fix: it shows that the two coordinate spaces give
        // different answers, so a mask that spans the panel cannot be correct by accident.
        let island: CGFloat = 180
        let panel = IslandLayout.maxExpandedBodySize.height
        let start = SemiGlassUnderlay.fadeStart(inHeight: island, restingHeight: Self.resting)

        #expect(start * Double(island) < Double(island),
                "measured against the island, the fade begins inside it")
        #expect(start * Double(panel) > Double(island),
                "measured against the panel, the fade begins below the island and nothing is drawn")
    }

    @Test("a short island is capped rather than being glass most of the way up")
    func theCapProtectsAShortIsland() {
        // The ramp already keeps a peek solid; this is the second guard, for a screen whose cutout
        // is short enough that the island is past the ramp while still being small.
        let height: CGFloat = 60
        let fade = (1 - SemiGlassUnderlay.fadeStart(inHeight: height, restingHeight: 0)) * Double(height)
        #expect(fade <= Double(height) * SemiGlassUnderlay.maximumFadeFraction + 0.001)
    }

    @Test("a zero or negative height is a gradient rather than a divide by zero")
    func aCollapsedIslandIsSafe() {
        // SwiftUI lays a view out at zero before it has a size, and the island rebuilds its panels
        // on every display change.
        for height in [CGFloat(0), -10] {
            let s = SemiGlassUnderlay.stops(inHeight: height, restingHeight: Self.resting)
            #expect(s.count >= 2)
            #expect(s.allSatisfy { $0.location >= 0 && $0.location <= 1 })
        }
    }

    @Test("the stops are in order, at every size the island can be")
    func locationsAscend() {
        for height in stride(from: CGFloat(0), through: 400, by: 4) {
            let s = SemiGlassUnderlay.stops(inHeight: height, restingHeight: Self.resting)
            for (a, b) in zip(s, s.dropFirst()) {
                #expect(a.location <= b.location, "out of order at \(height)pt")
            }
        }
    }

    @Test("a synthesized island's own resting height is what counts, not a constant")
    func theRestingHeightIsTheScreens() {
        // A cutout is a property of the display and a synthesized island is whatever
        // `NotchResolver` made up for that screen. A hardcoded 32 would draw a glass rim on a
        // closed island the moment somebody plugged in a display with a different one.
        #expect(SemiGlassUnderlay.fadePresence(inHeight: 48, restingHeight: 48) == 0)
        #expect(SemiGlassUnderlay.fadePresence(inHeight: 48, restingHeight: 20) > 0)
    }
}

/// Apple's audio badges, borrowed from Music rather than shipped.
///
/// These read the *live* system, which is unusual for a test here and is the point: the whole
/// feature is a claim about what `/System/Applications/Music.app` contains, and a mock would only
/// ever confirm that the mock was written correctly. The names are Apple's and Apple may change
/// them — this is what would say so.
@Suite("Apple's audio badges")
@MainActor
struct AudioFormatBadgeTests {

    /// **No trademark is shipped in this repository.** The badge for an Atmos track is Dolby's mark
    /// and the Lossless one is Apple's; both are read out of Music's own bundle at runtime. This
    /// pins the mapping so that "add the SVG to the asset catalog" is a decision somebody has to
    /// take deliberately rather than one they can drift into.
    @Test("the kinds Apple draws map to Apple's own asset names")
    func assetNames() {
        #expect(AudioFormatBadge.assetName(for: .dolbyAtmos) == "audioBadgeDolbyAtmosTemplate")
        #expect(AudioFormatBadge.assetName(for: .lossless) == "audioBadgeLosslessTemplate")
        #expect(AudioFormatBadge.assetName(for: .hiResLossless) == "audioBadgeHi-ResLosslessTemplate")
        // Apple sells no multichannel-but-not-Atmos tier and has no badge for one, and AAC is not a
        // thing to decorate. Both keep Isleta's own symbol and word.
        #expect(AudioFormatBadge.assetName(for: .multichannel) == nil)
        #expect(AudioFormatBadge.assetName(for: .lossy) == nil)
    }

    /// The three Apple draws load, and every one is a template — which is the property that makes
    /// them usable at all. The island is white on black; black artwork would vanish into it.
    ///
    /// Skipped rather than failed where Music is not installed: that is a real configuration and
    /// the feature has a real fallback for it.
    @Test("Apple's badges load from Music and are tintable")
    func badgesLoad() throws {
        try #require(Bundle(path: "/System/Applications/Music.app") != nil,
                     "Music is not installed; the badge route has nothing to read")
        for kind in [AudioFormat.Kind.dolbyAtmos, .lossless, .hiResLossless] {
            let image = try #require(AudioFormatBadge.image(for: kind),
                                     "Apple renamed \(String(describing: kind))'s badge")
            #expect(image.isTemplate)
            #expect(image.size.width > 0 && image.size.height > 0)
            // Every one measured wider than it is tall: these are wordmarks, which is why nothing
            // is drawn beside them.
            #expect(image.size.width > image.size.height)
        }
    }

    /// The kinds Apple has no badge for fall through to Isleta's own mark, and must not answer with
    /// somebody else's.
    @Test("a kind Apple does not draw has no borrowed badge")
    func unbadgedKinds() {
        #expect(AudioFormatBadge.image(for: .multichannel) == nil)
        #expect(AudioFormatBadge.image(for: .lossy) == nil)
    }
}
