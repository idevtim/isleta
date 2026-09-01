import Foundation

/// How big a window of the playback queue to ask for.
///
/// ## Why there is arithmetic here at all
///
/// A playback queue is not a list, it is a *window* onto one. `+defaultPlaybackQueueRequest` asks
/// for the whole thing, and a music library on shuffle is tens of thousands of entries — so the
/// question a scrollable Up Next has to answer is not "how do I fetch the queue" but "how much of
/// it is worth asking for right now". The answer is: what is on screen, plus a page, and again when
/// the reader gets near the end of what we have.
///
/// The cost is measured rather than guessed. A 5-item window costs **4-5 ms** and a 25-item window
/// **15-30 ms**, both inside the streaming helper that is already alive — so a page is cheap and a
/// library is not. The one thing that would be expensive is asking on a clock, and nothing here
/// does: every ask is a consequence of the user opening the surface or scrolling it.
///
/// Pure and static, so the rule can be exercised with no helper, no player and no music. That is
/// the point of the file: the paging is the part of this feature that is easy to get subtly wrong
/// (asking again for a window we already have, or never asking again at all), and it is the part
/// that needs no adapter to test.
public enum NowPlayingQueuePaging {

    /// The window the stream opens with, before anybody has asked to see the queue.
    ///
    /// Five: the current track and four behind it. It is what the Up Next sneak peek reads —
    /// exactly one of them — and it is deliberately not larger, because on the overwhelmingly
    /// common path nobody ever opens the list and this is the only ask that happens.
    public static let restingWindow = 5

    /// How many entries beyond the last visible row to hold.
    ///
    /// One page's worth, so a reader who scrolls to the bottom finds rows already there rather than
    /// a gap that fills a beat later. Larger buys nothing a user can see; smaller means the read
    /// lands after the scroll it was meant to cover.
    public static let lookahead = 10

    /// The ceiling, matching the adapter's own `QUEUE_MAX_LENGTH`.
    ///
    /// A hard stop rather than a tuning knob. A user who scrolls for long enough would otherwise
    /// walk the request length up to the size of their library, which is the exact thing the
    /// windowing exists to avoid — and 100 entries is already far more Up Next than anyone reads.
    public static let maximumWindow = 100

    /// The window to ask for, given how far down the list the reader has got.
    ///
    /// - Parameters:
    ///   - lastVisibleRow: the index of the deepest row currently drawn, from zero.
    ///   - isOpen: whether the queue surface is on screen at all. Closed, the answer is always the
    ///     resting window: a list nobody is looking at must not hold a hundred rows because it was
    ///     scrolled ten minutes ago.
    public static func window(lastVisibleRow: Int, isOpen: Bool) -> Int {
        guard isOpen else { return restingWindow }
        let wanted = max(0, lastVisibleRow) + 1 + lookahead
        return min(maximumWindow, max(restingWindow, wanted))
    }

    /// Whether a new window is worth asking for, given what has already been asked for.
    ///
    /// **Only ever grows while the surface is open.** A window that shrank on every scroll back up
    /// would re-ask on the way down again, and each ask is a MediaRemote round trip in a helper
    /// that is also delivering track changes. Coming back to the resting window is what *closing*
    /// the surface is for, which is why that one case is allowed to shrink.
    public static func shouldRequest(_ window: Int, having current: Int, isOpen: Bool) -> Bool {
        guard isOpen else { return current != restingWindow }
        return window > current
    }
}
