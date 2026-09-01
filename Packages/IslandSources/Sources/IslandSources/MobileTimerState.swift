import Foundation
import IslandActivities

/// One timer as `mobiletimerd` stores it, and the parser that reads the store.
///
/// ## What was measured, on macOS 27.0
///
/// There is no public API for Clock's timers: Clock.app is not scriptable (`sdef` → error -192, no
/// `NSAppleScriptEnabled`, no URL types), and neither ActivityKit nor AlarmKit is available on
/// macOS. What works is the `com.apple.mobiletimerd` **preferences domain**, read through cfprefsd,
/// which needs no permission at all.
///
/// | State | `MTTimerState` | `MTTimerFireTimerClass` | Payload |
/// |---|---|---|---|
/// | idle | `1` | `MTTimerTimeInterval` | the timer's **original duration** |
/// | paused | `2` | `MTTimerTimeInterval` | the time **remaining** |
/// | running | `3` | `MTTimerDate` | the absolute `Date` it fires |
///
/// ## The trap: idle and paused are the same shape
///
/// A paused timer reverts to a *relative* interval — same class, same field, same type as an idle
/// one — and differs only by the state number. So a parser that keys on `MTTimerFireTimerClass`,
/// which is the field that reads like the discriminator, shows every idle preset in the user's
/// Clock as a paused timer with its full duration left. On this machine that is three "5 min"
/// entries and a "15 min" that have not been touched since 2023.
///
/// **The state number is the discriminator. The class tells you how to read the payload.**
///
/// Ignore `MTTimerStorageMigratedToCoreData = true`: the Core Data store it points at lives in
/// `~/Library/Group Containers/group.com.apple.mobiletimerd` and is Full-Disk-Access walled, but
/// the prefs domain is not the stale mirror that flag suggests — it is written on every state
/// change, and the value is visible to `CFPreferencesCopyAppValue` about 150ms after the click.
public struct MobileTimerState: Equatable, Sendable {

    public let id: ActivityID

    /// The user's name for it, or nil. Clock stores `""` for an unnamed timer, and `"CURRENT_TIMER"`
    /// for one of its own internal presets — neither is a name a person chose, so both become nil.
    public let title: String?

    public let state: TimerRunState

    /// What the timer was set for, which is not what is left. Only an idle or running timer has
    /// this to hand; a paused one stores its remainder in the same field, so this falls back to the
    /// remainder rather than reporting zero.
    public let totalDuration: TimeInterval

    public init(id: ActivityID, title: String?, state: TimerRunState, totalDuration: TimeInterval) {
        self.id = id
        self.title = title
        self.state = state
        self.totalDuration = totalDuration
    }

    // MARK: - Parsing

    /// Clock's own placeholder for an unnamed preset. Not a title anybody typed.
    static let placeholderTitle = "CURRENT_TIMER"

    /// Every timer in the store that is not idle, in the order stored.
    ///
    /// Idle timers are dropped here rather than by the caller. They are the user's saved presets —
    /// this machine holds four that have not been touched since 2023 — and surfacing them would put
    /// four dormant countdowns on the island of somebody who has never started one.
    public static func timers(from raw: Any?, now: Date = Date()) -> [MobileTimerState] {
        guard let outer = raw as? [String: Any],
              let list = outer["MTTimers"] as? [[String: Any]]
        else { return [] }

        return list.compactMap { wrapper in
            guard let fields = wrapper["$MTTimer"] as? [String: Any] else { return nil }
            return timer(from: fields, now: now)
        }
    }

    static func timer(from fields: [String: Any], now: Date) -> MobileTimerState? {
        guard let rawID = fields["MTTimerID"] as? String, !rawID.isEmpty else { return nil }
        guard let stateCode = (fields["MTTimerState"] as? NSNumber)?.intValue else { return nil }

        let duration = (fields["MTTimerDuration"] as? NSNumber)?.doubleValue ?? 0
        let payload = fireTime(from: fields)

        // The state number, never the fire-time class. See the trap in this type's documentation.
        let state: TimerRunState
        switch stateCode {
        case 3:
            // A running timer whose date has already passed has rung and is waiting to be
            // dismissed. `mobiletimerd` sets `MTTimerFiredDate` for that, but only once it gets
            // round to it — the date passing is the earlier and more reliable signal, and it is the
            // one the island is already counting against.
            guard case .date(let fireDate) = payload else { return nil }
            state = fireDate <= now ? .finished : .running(fireDate: fireDate)
        case 2:
            guard case .interval(let remaining) = payload, remaining > 0 else { return nil }
            state = .paused(remaining: remaining)
        default:
            // 1, and anything a later macOS invents. An unknown state is treated as idle rather
            // than guessed at: showing nothing is recoverable, and showing a countdown that is not
            // running is not.
            return nil
        }

        let stored = fields["MTTimerTitle"] as? String
        let title = (stored == placeholderTitle || stored?.isEmpty == true) ? nil : stored

        return MobileTimerState(
            id: ActivityID("timer.\(rawID)"),
            title: title,
            state: state,
            totalDuration: duration > 0 ? duration : payloadSeconds(payload, now: now)
        )
    }

    // MARK: - The fire time, which is two different kinds of value

    enum FireTime: Equatable {
        case date(Date)
        case interval(TimeInterval)
        case absent
    }

    /// `MTTimerFireTime` wraps its value in a single-key dictionary named after the class, and the
    /// **key inside** is spelled differently again: the wrapper says `$MTTimerDate` while the field
    /// it holds says `MTTimerTimeDate`. Read by looking for the field rather than by trusting either
    /// spelling, so a rename of the wrapper does not silently produce "no timers running".
    static func fireTime(from fields: [String: Any]) -> FireTime {
        guard let wrapper = fields["MTTimerFireTime"] as? [String: Any],
              let inner = wrapper.values.first as? [String: Any]
        else { return .absent }

        if let date = inner["MTTimerTimeDate"] as? Date { return .date(date) }
        if let interval = (inner["MTTimerTimeInterval"] as? NSNumber)?.doubleValue {
            return .interval(interval)
        }
        return .absent
    }

    private static func payloadSeconds(_ payload: FireTime, now: Date) -> TimeInterval {
        switch payload {
        case .date(let date): max(0, date.timeIntervalSince(now))
        case .interval(let interval): interval
        case .absent: 0
        }
    }
}
