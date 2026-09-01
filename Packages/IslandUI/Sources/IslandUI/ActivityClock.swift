import AppKit
import QuartzCore
import SwiftUI

/// Advances the instant that `.countdown` and `.elapsed` values are formatted at.
///
/// ## Why this is a display link and not a `Timer`
///
/// §9 forbids a `Timer` for anything that drives what is on screen. The reasons are not stylistic:
/// a `Timer` fires against the run loop rather than against the display, so its ticks drift in and
/// out of phase with the frames they are meant to land on — a one-second timer redrawing a counter
/// produces a visible stutter roughly once a minute, where the tick and the vsync beat against each
/// other. It also keeps firing while the display is asleep or the island is not on screen.
/// `NSView.displayLink(target:selector:)` is the supported replacement for the deprecated
/// `CVDisplayLink`, it is bound to the screen the view is actually on, and the window server stops
/// it when there is nothing to draw to.
///
/// ## Why there is no clock at all most of the time
///
/// The link exists only while something time-dependent is *visible* — not merely presented. An
/// activity carrying a countdown in its `expanded` slot costs nothing until the island is opened,
/// because until then that slot is not drawn (`ActivitySlotLayout.needsClock`). At rest, with
/// nothing presented, or with a Now Playing activity that has no timer in it, no `CADisplayLink` is
/// ever created and the idle path is exactly what it was before this file existed.
///
/// ## Why it publishes once a second and not once a frame
///
/// The link is asked for a low frame rate, but a display that cannot honor that will simply run it
/// at 60 or 120Hz, and a `@State` write on every one of those would re-run the island's `body` at
/// the refresh rate to produce the same characters. So the tick is gated to whole seconds *here*,
/// below SwiftUI, which is the resolution the numerals actually have. The callback then fires
/// exactly as often as the display changes.
///
/// ## Why there is more than one cadence
///
/// The numerals have a resolution of one second and there is nothing to gain by publishing faster.
/// The Now Playing equaliser does not: it is continuous motion, and at one frame a second it is not
/// motion at all. Rather than run a second display link for it — §9's rule is one clock, started
/// only when something visible needs it — the same link publishes faster while something continuous
/// is on screen and drops back to second-gating when it leaves. `ActivityClockRate` is that choice,
/// and it is derived from what is *visible*, so an equaliser in an activity nobody has opened costs
/// nothing (`IslandScreenModel.clockRate`).
public enum ActivityClockRate: Equatable, Sendable {

    /// Nothing on screen is a function of time. No `CADisplayLink` exists.
    case stopped

    /// Numerals only. Ticks are gated to whole seconds, which is the resolution they have.
    case seconds

    /// Continuous motion, at approximately this many frames per second.
    ///
    /// Approximately, and the word is doing work: `CAFrameRateRange` is a *request*. A ProMotion
    /// display honors it and genuinely runs the link this slowly; a fixed 60Hz panel runs it at 60
    /// and the gate in `tick` throws away five frames in six. Either way the callback fires at this
    /// rate, so what is downstream costs the same on both.
    case frames(Int)

    /// The shorter of two rates, for a screen showing both kinds of value at once.
    ///
    /// Not `max` of the numbers: the enum is ordered by *cost* rather than by rate, and `.frames`
    /// always wins over `.seconds` because a second-gated numeral drawn at 10fps is still correct
    /// while a 10fps equaliser drawn once a second is a slideshow. Getting this backwards is silent
    /// — everything renders, the bars just stop looking alive.
    func combined(with other: ActivityClockRate) -> ActivityClockRate {
        switch (self, other) {
        case (.stopped, let other): other
        case (let mine, .stopped): mine
        case (.frames(let a), .frames(let b)): .frames(max(a, b))
        case (.frames(let a), .seconds): .frames(a)
        case (.seconds, .frames(let b)): .frames(b)
        case (.seconds, .seconds): .seconds
        }
    }
}

struct ActivityClock: NSViewRepresentable {

    /// How often anything on screen needs redrawing, if at all.
    let rate: ActivityClockRate

    /// Called on the main actor when the tick is due.
    let onTick: (Date) -> Void

    func makeNSView(context: Context) -> DisplayLinkView {
        let view = DisplayLinkView()
        view.onTick = onTick
        view.rate = rate
        return view
    }

    func updateNSView(_ view: DisplayLinkView, context: Context) {
        view.onTick = onTick
        view.rate = rate
    }

    static func dismantleNSView(_ view: DisplayLinkView, coordinator: ()) {
        view.rate = .stopped
    }

    /// A zero-sized host for the display link.
    ///
    /// Zero-sized, and that is load-bearing rather than incidental. It contributes no pixels, so it
    /// changes neither what the island looks like nor — far more importantly — the alpha the window
    /// server derives the panel's event shape from. It also must never be given
    /// `.allowsHitTesting(false)` by a caller: `NSHostingView` reports SwiftUI's hit-testing regions
    /// as the window's event shape, and a view that declines hit testing can collapse that shape for
    /// the *entire* window. A zero-sized view has nothing to decline in the first place, which is
    /// the reason to size it this way rather than to hide it.
    @MainActor
    final class DisplayLinkView: NSView {

        var onTick: ((Date) -> Void)?

        var rate: ActivityClockRate = .stopped {
            didSet {
                guard rate != oldValue else { return }
                updateLink()
            }
        }

        private var link: CADisplayLink?

        /// The instant last published, so a 120Hz link costs one comparison per frame instead of a
        /// SwiftUI invalidation. Reset when the rate changes, so speeding the clock up takes effect
        /// on the next frame rather than at the end of the current gate interval.
        private var lastPublished: TimeInterval?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // A display link belongs to a screen, so it cannot exist before the view is in a
            // window — and it must not outlive the view leaving one, or it keeps ticking against a
            // screen this view is no longer on.
            updateLink()
        }

        /// Isolated so it can invalidate the link, which is main-actor state. A nonisolated
        /// `deinit` cannot touch it, and a link that outlives its view keeps a retain on the
        /// target and goes on firing.
        isolated deinit {
            link?.invalidate()
            link = nil
        }

        private func updateLink() {
            guard rate != .stopped, window != nil else {
                link?.invalidate()
                link = nil
                lastPublished = nil
                return
            }
            lastPublished = nil

            // The range is updated in place rather than by rebuilding the link. Rebuilding would
            // drop a frame and, worse, re-enter `viewDidMoveToWindow`'s ordering assumptions every
            // time a track was paused — which is the one moment the clock's rate changes.
            guard let link else {
                let link = displayLink(target: self, selector: #selector(tick))
                link.preferredFrameRateRange = Self.frameRateRange(for: rate)
                link.add(to: .main, forMode: .common)
                self.link = link
                return
            }
            link.preferredFrameRateRange = Self.frameRateRange(for: rate)
        }

        /// A *request*, not a guarantee: a display that cannot slow down runs the link at its own
        /// refresh rate and the gate in `tick` absorbs the difference. Asking still matters on
        /// ProMotion, where it is honored and the frames are never generated in the first place —
        /// which is the difference between spending §9's idle budget and not.
        ///
        /// The band around `preferred` is deliberate rather than a range of one. A link pinned to a
        /// single rate can only be honored where that rate divides the panel's, so a 10Hz pin on a
        /// 60Hz display is honored and on a 120Hz ProMotion panel in its 80Hz mode is not; a band
        /// gives the compositor something it can round to.
        private static func frameRateRange(for rate: ActivityClockRate) -> CAFrameRateRange {
            switch rate {
            case .stopped, .seconds:
                CAFrameRateRange(minimum: 1, maximum: 6, preferred: 2)
            case .frames(let fps):
                CAFrameRateRange(
                    minimum: Float(max(1, fps - 2)),
                    maximum: Float(fps + 4),
                    preferred: Float(max(1, fps))
                )
            }
        }

        /// The shortest interval between published ticks, in seconds.
        ///
        /// Slightly under the nominal interval (`0.9 /`, not `1.0 /`). A gate set to exactly the
        /// interval throws away the frame that arrives a microsecond early and waits a whole further
        /// frame for the next — so a 10fps request on a 60Hz panel, where frames land every 16.7ms,
        /// resolves to one tick every 7 frames rather than every 6, and the equaliser runs 14% slow
        /// for no reason anyone would ever find.
        private static func minimumInterval(for rate: ActivityClockRate) -> TimeInterval {
            switch rate {
            case .stopped: .infinity
            case .seconds: 0
            case .frames(let fps): 0.9 / Double(max(1, fps))
            }
        }

        @objc private func tick() {
            let now = Date()
            let stamp = now.timeIntervalSinceReferenceDate

            if case .seconds = rate {
                // Numerals change on the second boundary, not every N seconds since the last tick:
                // gating on an interval would drift the displayed second off the real one and show
                // "1:04" for two seconds and "1:05" for none.
                let second = stamp.rounded(.down)
                guard second != lastPublished else { return }
                lastPublished = second
                onTick?(now)
                return
            }

            if let lastPublished, stamp - lastPublished < Self.minimumInterval(for: rate) { return }
            lastPublished = stamp
            onTick?(now)
        }
    }
}
