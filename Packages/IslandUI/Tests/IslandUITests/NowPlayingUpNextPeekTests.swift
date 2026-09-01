import Foundation
import IslandActivities
import Testing

@testable import IslandUI

/// The ten-second window, as arithmetic.
///
/// Every case here is a fact about a `Date` and an `ActivityTimeline` — there is no clock, no
/// display link and no view, which is the whole claim the feature rests on: "ten seconds before the
/// end" is a pure function of an instant, so nothing has to be scheduled, canceled on a pause or
/// re-armed after a seek.
@Suite("Now Playing — the Up Next peek window")
struct NowPlayingUpNextPeekTests {

    private static let anchor = Date(timeIntervalSince1970: 1_700_000_000)

    /// A three-and-a-half minute track, anchored at the start and playing at 1x.
    private static func track(
        duration: TimeInterval = 214,
        elapsed: TimeInterval = 0,
        rate: Double = 1
    ) -> ActivityTimeline {
        ActivityTimeline(elapsed: elapsed, duration: duration, anchor: anchor, rate: rate)
    }

    private static func instant(_ offset: TimeInterval) -> Date {
        anchor.addingTimeInterval(offset)
    }

    @Test("not due through the body of the track")
    func notDueEarly() {
        let timeline = Self.track()
        #expect(NowPlayingUpNextPeek.isDue(timeline: timeline, at: Self.instant(0)) == false)
        #expect(NowPlayingUpNextPeek.isDue(timeline: timeline, at: Self.instant(100)) == false)
        #expect(NowPlayingUpNextPeek.isDue(timeline: timeline, at: Self.instant(203)) == false)
    }

    /// The boundary, from both sides and a second apart — which is the resolution the display link
    /// publishes at, so this is the finest granularity the flip can actually happen with.
    @Test("due from ten seconds out")
    func dueAtTheBoundary() {
        let timeline = Self.track()
        #expect(NowPlayingUpNextPeek.isDue(timeline: timeline, at: Self.instant(203.9)) == false)
        #expect(NowPlayingUpNextPeek.isDue(timeline: timeline, at: Self.instant(204.1)) == true)
        #expect(NowPlayingUpNextPeek.isDue(timeline: timeline, at: Self.instant(213)) == true)
    }

    /// `position(at:)` clamps at the duration, so a player that stops reporting at the end leaves
    /// the remaining time at exactly zero rather than running negative. The peek stays up for the
    /// beat between the track ending and the next one being reported, which is the moment it is
    /// most nearly literally true.
    @Test("still due at the end of the track, and not past it")
    func dueAtTheEnd() {
        let timeline = Self.track()
        #expect(NowPlayingUpNextPeek.remaining(timeline: timeline, at: Self.instant(214)) == 0)
        #expect(NowPlayingUpNextPeek.remaining(timeline: timeline, at: Self.instant(400)) == 0)
        #expect(NowPlayingUpNextPeek.isDue(timeline: timeline, at: Self.instant(400)) == true)
    }

    /// Pause is `rate == 0`, and so is a drag — `NowPlayingController.beginScrub` pins the dragged
    /// timeline's rate at zero so the playhead does not crawl away from the pointer. Both fall out
    /// of one condition rather than needing a flag each, which is the reason the resolved timeline
    /// is what the view hands in.
    @Test("a paused track — and a drag, which is the same condition — is never due")
    func pausedIsNeverDue() {
        let paused = Self.track(elapsed: 210, rate: 0)
        #expect(NowPlayingUpNextPeek.isDue(timeline: paused, at: Self.instant(0)) == false)
        #expect(NowPlayingUpNextPeek.isDue(timeline: paused, at: Self.instant(60)) == false)
    }

    /// A countdown runs backwards (`rate == -1`); `ActivityTimeline` is shared with the timer kind,
    /// and "ten seconds from the end" means nothing there.
    @Test("a backwards timeline is never due")
    func backwardsIsNeverDue() {
        #expect(
            NowPlayingUpNextPeek.isDue(
                timeline: Self.track(elapsed: 5, rate: -1), at: Self.instant(0)
            ) == false
        )
    }

    /// A live stream reports zero, which is already how `ActivityTimeline.fraction(at:)` says
    /// "there is no end to be a fraction of". There is no end to be ten seconds before either.
    @Test("a stream with no duration is never due")
    func noDurationIsNeverDue() {
        #expect(
            NowPlayingUpNextPeek.isDue(timeline: Self.track(duration: 0), at: Self.instant(30))
                == false
        )
        #expect(NowPlayingUpNextPeek.isDue(timeline: nil, at: Self.instant(30)) == false)
    }

    /// A track shorter than the lead time would wear the peek for its whole length, which is not a
    /// peek — it is a permanent second subtitle naming a song that is not playing. The peek has to
    /// be a *change* during the track or it says nothing.
    @Test("a track shorter than the lead time is never due")
    func shortTrackIsNeverDue() {
        let jingle = Self.track(duration: NowPlayingUpNextPeek.leadTime - 1)
        #expect(NowPlayingUpNextPeek.isDue(timeline: jingle, at: Self.instant(0)) == false)
        #expect(NowPlayingUpNextPeek.isDue(timeline: jingle, at: Self.instant(8)) == false)
        // And exactly at the lead time, for the same reason — a ten-second track is ten seconds of
        // "Up Next".
        let exact = Self.track(duration: NowPlayingUpNextPeek.leadTime)
        #expect(NowPlayingUpNextPeek.isDue(timeline: exact, at: Self.instant(0)) == false)
    }

    /// A podcast at 1.5x reaches the window a third earlier in wall-clock time, and the arithmetic
    /// has to come from the rate rather than from a subtraction of seconds. Nothing here knows the
    /// rate is not 1; `position(at:)` does.
    @Test("the window is measured in playback time, not wall clock")
    func honorsPlaybackRate() {
        let fast = Self.track(rate: 1.5)
        // 204s of playback at 1.5x is 136s of wall clock.
        #expect(NowPlayingUpNextPeek.isDue(timeline: fast, at: Self.instant(135)) == false)
        #expect(NowPlayingUpNextPeek.isDue(timeline: fast, at: Self.instant(137)) == true)
    }

    @Test("remaining is nil exactly when the question does not apply")
    func remainingIsNilWhereIsDueIsFalseForStructuralReasons() {
        #expect(NowPlayingUpNextPeek.remaining(timeline: nil, at: Self.instant(0)) == nil)
        #expect(
            NowPlayingUpNextPeek.remaining(timeline: Self.track(rate: 0), at: Self.instant(0)) == nil
        )
        #expect(
            NowPlayingUpNextPeek.remaining(timeline: Self.track(duration: 0), at: Self.instant(0))
                == nil
        )
        #expect(
            NowPlayingUpNextPeek.remaining(timeline: Self.track(), at: Self.instant(14)) == 200
        )
    }
}

/// What the controller does with a next track it has been handed.
@Suite("Now Playing — the controller's Up Next")
@MainActor
struct NowPlayingUpNextControllerTests {

    @Test("the next track is held, and is not a claim that it is on screen")
    func holdsWithoutShowing() {
        let controller = NowPlayingController()
        #expect(controller.hasUpNext == false)
        controller.setUpNext(title: "Maybach", artist: "SEV")
        #expect(controller.hasUpNext)
        #expect(controller.upNextTitle == "Maybach")
        #expect(controller.upNextArtist == "SEV")
        // Whether it is drawn is `NowPlayingUpNextPeek.isDue`, against the display link's instant.
        // There is deliberately no stored flag here to disagree with it.
    }

    /// The one failure of this feature a user would actually notice: the island naming a song that
    /// will not play, because the queue it came from is gone.
    @Test("a stop forgets it")
    func resetForgets() {
        let controller = NowPlayingController()
        controller.setUpNext(title: "Maybach", artist: "SEV")
        controller.reset()
        #expect(controller.upNextTitle == nil)
        #expect(controller.upNextArtist == nil)
        #expect(controller.hasUpNext == false)
    }

    @Test("clearing it is expressible")
    func clearing() {
        let controller = NowPlayingController()
        controller.setUpNext(title: "Maybach", artist: "SEV")
        controller.setUpNext(title: nil, artist: nil)
        #expect(controller.hasUpNext == false)
    }
}
