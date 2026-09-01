import Foundation
import IslandActivities

/// Turns a stream of brightness callbacks into the HUDs worth showing.
///
/// A pure value type with no DisplayServices in it, for the same reason `SystemHUDLevelState` has
/// no CoreAudio in it: this is where the bugs are, and they are all about *when not to speak*.
///
/// # Why this is not `SystemHUDLevelState`
///
/// The audio state deduplicates by exact equality, and says so: "a duplicate callback hands back
/// the identical `Float32`, so exact comparison drops exactly the duplicates". That is true of
/// CoreAudio and false of this API. **One brightness key-hold delivers 27 to 78 callbacks whose
/// values all differ**, tracing the panel's easing ramp toward the destination — measured on
/// macOS 27.0 across nine real key-holds, 419 callbacks in total. Equality drops none of them, so
/// the volume rules applied here would publish ~50 activities per keypress, each one re-entering
/// `.interrupting` against a coordinator entitled to treat it as a fresh interruption.
///
/// # The two rules, and where the numbers come from
///
/// **The first change of a burst publishes immediately.** The HUD has to be on screen on the frame
/// the user's key lands; a throttle that delayed the first frame would be the one visible cost.
///
/// **Everything after it is throttled to `publishInterval`.** Chosen by replaying the recorded
/// 419-callback session against candidate intervals and measuring the error each would leave on
/// screen — the settled value the user is left looking at, and the worst transient lag mid-ramp:
///
/// | interval | publishes | worst settled error | worst transient |
/// |---------:|----------:|--------------------:|----------------:|
/// |     none |       419 |              0.0000 |          0.0000 |
/// |     40ms |       148 |              0.0016 |          0.0398 |
/// |     60ms |       109 |              0.0020 |          0.0594 |
/// |  **100ms** |    **72** |          **0.0034** |      **0.0677** |
/// |    150ms |        54 |              0.0047 |          0.0834 |
/// |    250ms |        35 |              0.0226 |          0.1506 |
///
/// 100ms is 5.8× fewer publishes than raw for a settled error of **0.34%** — under a third of one
/// notch on the sixteen-notch bar macOS itself draws, so it is not a rounding the user can see. It
/// is also the cadence `ActivityClockRate` already settled on for the equaliser, for the same §9
/// reason. The transient 6.8% is the bar lagging a fast ramp by one interval, which is what a bar
/// chasing a moving value looks like.
///
/// **The settled value is the last callback of the ramp, and the throttle can swallow it.** That is
/// the 0.34%: no trailing flush is scheduled, deliberately, because a flush means a timer, and a
/// timer that outlives the ramp is the thing §9 forbids on the idle path. The bound is measured
/// rather than assumed, and it is smaller than the display's own quantisation.
public struct SystemHUDBrightnessState: Equatable, Sendable {

    /// The throttle. See the table above.
    public static let publishInterval: TimeInterval = 0.100

    /// How long a silence has to be before the next callback counts as a new user action.
    ///
    /// Measured: callbacks *within* one key-hold arrive 17–20ms apart, and the gaps *between* the
    /// nine key-holds were 189–403ms. 150ms sits in the empty middle of that gap with an order of
    /// magnitude of headroom on the near side, so it separates the two without a judgement call.
    public static let burstGap: TimeInterval = 0.150

    /// The last level seen, published or not.
    public private(set) var level: Double?

    /// Whether a level has been taken as the reference point. Until one has, nothing is a *change*
    /// and nothing is published.
    public private(set) var hasBaseline: Bool

    private var lastPublishedAt: Date?
    private var lastCallbackAt: Date?

    public init() {
        level = nil
        hasBaseline = false
    }

    /// Adopt a level as the new reference without saying anything about it.
    ///
    /// The launch path, and it would be a user-visible bug through `apply(_:at:)` instead: reading
    /// the current brightness to know what a later change is relative to would otherwise throw a
    /// brightness HUD at the user every time Isleta starts, for something they did not do. Exactly
    /// the reasoning behind `SystemHUDLevelState.rebase`, and the same bug it prevents.
    public mutating func rebase(to level: Double) {
        self.level = level
        hasBaseline = true
        lastPublishedAt = nil
        lastCallbackAt = nil
    }

    /// Fold in a callback, returning the HUD to present or nil if nothing should be said yet.
    public mutating func apply(_ level: Double, at now: Date) -> SystemHUDReading? {
        guard hasBaseline else {
            rebase(to: level)
            return nil
        }

        let previous = self.level
        let previousCallbackAt = lastCallbackAt
        self.level = level
        lastCallbackAt = now

        // An identical value is not a change. Rare here — unlike CoreAudio, this API's duplicates
        // are the exception — but a callback that carries the level the user is already looking at
        // has nothing to say.
        guard level != previous else { return nil }

        let limit = SystemHUDReading.limit(atLevel: level)

        // A new user action, judged by the silence in front of it rather than by the value: the
        // first callback after a gap is the keypress landing, and it publishes on that frame.
        let startsBurst = previousCallbackAt.map { now.timeIntervalSince($0) >= Self.burstGap } ?? true

        // **An end of the range always publishes, throttle or no**, and it is the throttle's own
        // measurement that makes this necessary rather than a nicety. The table above records the
        // settled value being swallowed as a 0.34% error — invisible on a bar, and *fatal* to a
        // signal that is about the exact bound: a ramp to full brightness would publish 0.9966 as
        // its last word and the island would never learn it had arrived. One extra publish per
        // ramp, at the one value in it that is not a transient.
        //
        // It cannot repeat while the level sits there: the equality guard above drops every
        // subsequent callback carrying the same number, so a key held at the top publishes this
        // once. That is also what makes `ActivityLimit` a moment rather than a state.
        if startsBurst || limit != nil {
            lastPublishedAt = now
            return SystemHUDReading(hud: .brightness, level: level, limit: limit)
        }

        guard let lastPublishedAt, now.timeIntervalSince(lastPublishedAt) >= Self.publishInterval else {
            return nil
        }
        self.lastPublishedAt = now
        return SystemHUDReading(hud: .brightness, level: level, limit: limit)
    }
}
