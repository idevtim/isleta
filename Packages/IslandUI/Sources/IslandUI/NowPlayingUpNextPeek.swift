import Foundation
import IslandActivities

/// When the island says what is coming next.
///
/// ## Why this is arithmetic and not a timer
///
/// "Ten seconds before the track ends" reads like something that needs scheduling, and scheduling
/// it is the §9 violation: a `Timer` or a `DispatchQueue.asyncAfter` per track, re-armed on every
/// seek, canceled on every pause, and wrong after a scrub. There is nothing to schedule.
/// `ActivityTimeline` carries the position, the instant it was true and the rate, so "is the peek
/// due" is a pure function of an instant — and IslandUI is already publishing instants, once a
/// second, from the display link `ActivityClock` runs for the numerals beside this very line. The
/// peek appears on the tick it becomes true and costs one subtraction on the ticks it does not.
///
/// Everything here is `static` and takes its `now`, for the same reason `NowPlayingController`'s
/// pending-seek deadline does: a value that expires against a clock it was handed can be tested
/// exhaustively without one.
public enum NowPlayingUpNextPeek {

    /// How long before the end the next track is named.
    ///
    /// Ten seconds is long enough to read a title and short enough that it is unambiguously about
    /// *this* track ending rather than a permanent second line. It is also the number the feature
    /// was specified with, and it is a constant rather than a setting because there is nothing a
    /// user would tune it against — a slider here asks a question with no observable answer until
    /// the last ten seconds of a song.
    public static let leadTime: TimeInterval = 10

    /// Whether the peek should be on screen.
    ///
    /// Four conditions, and each rules out a way of showing it when it means nothing:
    ///
    /// - **A duration.** A live stream reports zero, which `ActivityTimeline.fraction(at:)` already
    ///   treats as "there is no end to be a fraction of". There is no end to be ten seconds before.
    /// - **A duration longer than the lead time.** A track shorter than ten seconds would wear the
    ///   peek for its entire length, which is not a peek — it is a second subtitle that happens to
    ///   name the wrong song. The peek has to be a *change* during the track or it says nothing.
    /// - **Moving forward.** `rate` is zero while paused and while the user is dragging the
    ///   scrubber (`NowPlayingController.beginScrub` pins it), so both fall out here rather than
    ///   needing their own flags. A negative rate is a countdown, which this is not.
    /// - **Inside the window.** `position(at:)` clamps to the track at both ends, so `remaining` is
    ///   never negative and a player that stops reporting at the end leaves it at exactly zero
    ///   rather than running away — which is why the lower bound is not written out.
    public static func isDue(timeline: ActivityTimeline?, at now: Date) -> Bool {
        guard let remaining = remaining(timeline: timeline, at: now) else { return false }
        return remaining < leadTime
    }

    /// Seconds left in the track, or nil when the question does not apply.
    ///
    /// Split out from `isDue` so a test can say *how far* off the boundary a case is rather than
    /// only which side of it — a window this small is one where "it flipped a second early" and "it
    /// never flips" both look like `false` from outside.
    public static func remaining(timeline: ActivityTimeline?, at now: Date) -> TimeInterval? {
        guard let timeline, timeline.duration > leadTime, timeline.rate > 0 else { return nil }
        return timeline.duration - timeline.position(at: now)
    }
}
