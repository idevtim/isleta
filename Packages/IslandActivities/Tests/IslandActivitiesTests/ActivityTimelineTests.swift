import Foundation
import Testing

@testable import IslandActivities

@Suite("Playback timeline")
struct ActivityTimelineTests {

    private let anchor = Date(timeIntervalSince1970: 1_700_000_000)

    private func timeline(
        elapsed: TimeInterval = 30,
        duration: TimeInterval = 180,
        rate: Double = 1
    ) -> ActivityTimeline {
        ActivityTimeline(elapsed: elapsed, duration: duration, anchor: anchor, rate: rate)
    }

    /// The whole reason this type exists rather than an `elapsedTime` field: a value published once
    /// is still exact ten minutes later, so a track playing for an hour publishes one activity
    /// instead of 3,600.
    @Test("position is a function of the clock, not a sample")
    func position() {
        let track = timeline()
        #expect(track.position(at: anchor) == 30)
        #expect(track.position(at: anchor.addingTimeInterval(45)) == 75)
    }

    /// A podcast at 1.5x reports `playbackRate` 1.5, and a bar advancing at 1x under it drifts a
    /// minute every two.
    @Test("rate is a multiplier, not a flag")
    func rate() {
        let track = timeline(rate: 1.5)
        #expect(track.position(at: anchor.addingTimeInterval(40)) == 90)
    }

    /// A paused track is a still picture with no special case anywhere: rate zero means the position
    /// never moves, which is what stops the display link and freezes the equaliser mid-stride.
    @Test("a paused track never moves and is never time-dependent")
    func paused() {
        let track = timeline(rate: 0)
        #expect(track.position(at: anchor.addingTimeInterval(600)) == 30)
        #expect(track.isAdvancing == false)
        #expect(ActivityValue.timeline(track).isTimeDependentForTests == false)
    }

    /// A player that stops reporting at the end of a track leaves the last anchor in place. Without
    /// the clamp the numerals run past the duration and the bar paints outside its own track.
    @Test("position clamps to the track at both ends")
    func clamping() {
        let track = timeline()
        #expect(track.position(at: anchor.addingTimeInterval(10_000)) == 180)
    }

    /// **The far-left blip.** This asserted `0` until 2026-08-27, and the zero was the bug rather
    /// than the clamp: a `now` before the anchor was extrapolated *backwards* and the negative
    /// result clamped, so the playhead read as the start of the track instead of as the last
    /// position the player reported.
    ///
    /// It is not a hypothetical `now`. `IslandScreenModel.clockRate` stops the display link dead
    /// while nothing is advancing, so a paused track freezes `IslandRootView.now` for the length of
    /// the pause; pressing play delivers a timeline anchored at the present against a `now` that is
    /// minutes old. One frame at the far left, then the restarted clock corrected it — reported from
    /// use as "it blips to the far left and immediately goes back to the place it's playing from".
    ///
    /// The anchor is the last thing the player actually said, so it is what a stale `now` reports.
    @Test("a now before the anchor reports the anchor's own position, not the start of the track")
    func staleNowHoldsTheAnchorPosition() {
        let track = timeline()
        #expect(track.position(at: anchor.addingTimeInterval(-100)) == 30)
        #expect(track.position(at: anchor.addingTimeInterval(-0.016)) == 30)
        // And the fraction that draws the bar, which is what was seen.
        #expect(track.fraction(at: anchor.addingTimeInterval(-100)) == 30.0 / 180)
    }

    /// The same clamp, for a timeline that runs the other way. A running timer counts down at rate
    /// `-1`; extrapolating a stale `now` backwards there would report *more* time remaining than the
    /// player last reported, which is the same fault wearing the opposite sign.
    @Test("a backwards timeline does not gain time from a stale now")
    func staleNowDoesNotRewindACountdown() {
        let countdown = ActivityTimeline(elapsed: 120, duration: 300, anchor: anchor, rate: -1)
        #expect(countdown.position(at: anchor.addingTimeInterval(-60)) == 120)
        #expect(countdown.position(at: anchor.addingTimeInterval(60)) == 60)
    }

    /// A live stream has no end to be a fraction of, and a bar that is always full would be a claim
    /// the source never made.
    @Test("no duration means no fraction")
    func liveStream() {
        let stream = timeline(elapsed: 12, duration: 0)
        #expect(stream.fraction(at: anchor) == nil)
        // The position still advances, which is what keeps the equaliser running on a radio station.
        #expect(stream.position(at: anchor.addingTimeInterval(8)) == 20)
    }

    @Test("fraction runs the length of the track")
    func fraction() {
        let track = timeline(elapsed: 0)
        #expect(track.fraction(at: anchor) == 0)
        #expect(track.fraction(at: anchor.addingTimeInterval(90)) == 0.5)
        #expect(track.fraction(at: anchor.addingTimeInterval(180)) == 1)
    }

    /// The optimistic value a scrub produces. Shaped like a real report rather than held as a bare
    /// fraction, so exactly one type answers "where is the playhead" everywhere on screen.
    @Test("a seek re-anchors and keeps moving")
    func seeked() {
        let track = timeline()
        let instant = anchor.addingTimeInterval(10)
        let after = track.seeked(to: 120, at: instant)
        #expect(after.elapsed == 120)
        #expect(after.anchor == instant)
        #expect(after.rate == 1)
        #expect(after.position(at: instant.addingTimeInterval(5)) == 125)
    }

    @Test("a seek past the end lands on the end")
    func seekedClamps() {
        let after = timeline().seeked(to: 500, at: anchor)
        #expect(after.elapsed == 180)
        #expect(timeline().seeked(to: -20, at: anchor).elapsed == 0)
    }
}

private extension ActivityValue {
    /// `isTimeDependent` lives in IslandUI, which this package cannot see. The property under test
    /// is really `ActivityTimeline.isAdvancing`; this states the relationship the two have so a
    /// change to one without the other fails here rather than in a render.
    var isTimeDependentForTests: Bool {
        switch self {
        case .countdown, .elapsed: true
        case .fraction, .indeterminate: false
        case .timeline(let timeline): timeline.isAdvancing
        }
    }
}
