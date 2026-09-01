import Foundation

/// What a Clock timer is doing, in the three shapes `mobiletimerd` actually stores.
///
/// Measured on macOS 27.0 rather than assumed — see `MobileTimerState` in IslandSources for the
/// probe and the numbers. The distinction that matters here is that **running carries an absolute
/// instant and paused carries a relative remainder**, so they are different types of fact and not
/// one number with a flag beside it.
public enum TimerRunState: Equatable, Sendable {

    /// Counting down, and will fire at this instant. The island counts against its own clock from
    /// here; nothing has to be polled to keep the number moving.
    case running(fireDate: Date)

    /// Held, with this much left. A relative remainder, frozen — not a fire date in the future.
    case paused(remaining: TimeInterval)

    /// Rang, and has not been dismissed yet.
    case finished

    public var isFinished: Bool { self == .finished }

    /// Whether the island has to redraw as the clock moves. False for both of the still states,
    /// which is what keeps a paused timer off the display link entirely (§9).
    public var isCounting: Bool {
        if case .running = self { return true }
        return false
    }
}
