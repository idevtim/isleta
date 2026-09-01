import Foundation
import IslandActivities

/// How long the battery has left, when that is a thing anybody can say.
///
/// **Three of the four values IOKit answers with are not durations**, and every one of them is a
/// number a naive reader would divide by 60 and draw. Measured on macOS 27.0 with the machine on AC
/// at 100 %:
///
/// | Source | Value | Means |
/// |---|---|---|
/// | `IOPSGetTimeRemainingEstimate()` | **−2.0** (`kIOPSTimeRemainingUnlimited`) | on AC; there is no "left" |
/// | `IOPSGetTimeRemainingEstimate()` | **−1.0** (`kIOPSTimeRemainingUnknown`) | on battery, still calculating |
/// | `Time to Empty` / `Time to Full Charge` | **0** | not calculated — both read 0 in that same snapshot |
/// | the IORegistry's `TimeRemaining` / `AvgTimeToEmpty` | **65535** | the sentinel that is not in any header |
///
/// So the rule is inverted from the obvious one: a value is a duration only if it is **strictly
/// positive and below the sentinel**, and everything else is `.unknown` or `.notApplicable`. Written
/// as a type rather than as a clamp at the call site because there are four call sites and the
/// failure is silent — "0 min left" on a machine at 100 % reads as a bug in the battery, not in
/// Isleta.
public enum PowerTimeEstimate: Equatable, Sendable {

    /// A real duration, in seconds.
    case remaining(TimeInterval)

    /// The system does not know yet. On battery this is normal for the first minute or so after a
    /// plug change, which is exactly when a user looks.
    case unknown

    /// There is nothing to estimate — on AC, or charged. Distinct from `.unknown` because the two
    /// deserve opposite treatment: one is a silence that will end, the other is a question that does
    /// not apply.
    case notApplicable

    /// The IORegistry's "no answer" value, in minutes. Not in any SDK header; see the table above.
    public static let registrySentinel = 65535

    /// From `IOPSGetTimeRemainingEstimate()`, which answers in seconds and uses the two negative
    /// sentinels.
    public static func seconds(_ value: Double) -> Self {
        if value == kIOPSTimeRemainingUnlimitedValue { return .notApplicable }
        guard value > 0, value < Double(registrySentinel) * 60 else { return .unknown }
        return .remaining(value)
    }

    /// From the power-source dictionary's `Time to Empty` / `Time to Full Charge`, which answer in
    /// **minutes** and use 0 and 65535 rather than the negative pair. Two units, two spellings of
    /// "no answer", one type.
    public static func minutes(_ value: Int) -> Self {
        guard value > 0, value < registrySentinel else { return .unknown }
        return .remaining(TimeInterval(value) * 60)
    }

    /// `kIOPSTimeRemainingUnlimited` as a plain `Double`. The header spells it as a `CFTimeInterval`
    /// cast, which is not usable in a `case` pattern.
    private static let kIOPSTimeRemainingUnlimitedValue: Double = -2.0

    /// "2 hr 40 min", "40 min", or nil when there is nothing to say.
    ///
    /// A **plain enum's** static formatting rather than anything on a view: `View` conformance is
    /// main-actor isolated, so the same function declared there is `@MainActor` and fails the first
    /// nonisolated test that calls it — under `-warnings-as-errors` that is an error, not a warning.
    public var formatted: String? {
        guard case .remaining(let seconds) = self else { return nil }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours == 0 { return sourceText("power.duration.minutes", "\(max(minutes, 1)) min") }
        if minutes == 0 { return sourceText("power.duration.hours", "\(hours) hr") }
        return sourceText("power.duration.hoursMinutes", "\(hours) hr \(minutes) min")
    }
}

/// Everything about the machine's power that the island can draw, in one comparable value.
///
/// `Equatable` is doing real work here: the notify keys fire in bursts — measured at **3 in 39 ms**
/// under load, two of them in the same millisecond, with identical content — so the source coalesces
/// on ~100 ms and then compares. A snapshot equal to the last one published is not an event, and
/// without the comparison the island would announce the same 100 % three times for one plug.
public struct PowerState: Equatable, Sendable {

    /// Whether this Mac has an internal battery at all. False on a mini, a Studio and an iMac,
    /// where every other field here is meaningless and the source publishes nothing.
    public var isPresent: Bool

    /// Whether the wall is providing the power. `IOPSGetProvidingPowerSourceType` rather than
    /// `Is Charging`, which is false on a machine that is plugged in and already full.
    public var isPluggedIn: Bool

    public var isCharging: Bool

    /// Full, and told so by the system rather than inferred from `percent == 100` — a battery held
    /// at 80 % by Optimized Charging is charged in the sense that matters and is not at 100.
    public var isCharged: Bool

    /// 0...100, or nil where there is no battery to have a level.
    public var percent: Int?

    public var estimate: PowerTimeEstimate

    public var isLowPowerMode: Bool

    public init(
        isPresent: Bool = true,
        isPluggedIn: Bool = false,
        isCharging: Bool = false,
        isCharged: Bool = false,
        percent: Int? = nil,
        estimate: PowerTimeEstimate = .unknown,
        isLowPowerMode: Bool = false
    ) {
        self.isPresent = isPresent
        self.isPluggedIn = isPluggedIn
        self.isCharging = isCharging
        self.isCharged = isCharged
        self.percent = percent
        self.estimate = estimate
        self.isLowPowerMode = isLowPowerMode
    }

    /// 0...1 for the ring, or nil when there is no battery.
    public var fraction: Double? {
        percent.map { min(max(Double($0) / 100, 0), 1) }
    }
}

/// The one thing worth putting on the island out of a stream of power readings.
///
/// A separate type from `PowerState` because the two answer different questions: a state is what is
/// true, an announcement is what *changed and is worth saying*. The percent moving 74 → 73 changes
/// the state and is not news; the charger coming out is news whether or not the percent moved.
public enum PowerAnnouncement: Equatable, Sendable {
    case pluggedIn
    case unplugged
    case charged
    case low(percent: Int)
    case lowPowerMode(isOn: Bool)
}

/// Which readings become islands, and — as importantly — which do not.
///
/// Pure, so the whole matrix is testable without a battery, without unplugging the developer's
/// laptop, and without waiting for it to reach 5 %.
///
/// Two rules carry the weight:
///
/// - **The first reading is a baseline, never an announcement.** The source reads once at `start()`
///   so that the *next* callback has something to compare against, and a machine that has been
///   plugged in all night must not be told at every launch that it is plugged in. This is the
///   lesson `BluetoothDeviceSource` learned about already-connected devices, in a different source.
/// - **A threshold is announced once per discharge.** Crossing 20 % announces; the next reading at
///   19 % does not; plugging in and pulling the charger out again arms it once more. Without that,
///   a battery hovering on a boundary posts an island every time the estimate is recalculated.
public struct PowerAnnouncementPolicy: Equatable, Sendable {

    /// Descending, and the gaps are deliberate: three announcements over a whole discharge, at the
    /// points where a person's options actually change — find a charger soon, find one now, save
    /// your work.
    public static let lowThresholds = [20, 10, 5]

    public private(set) var previous: PowerState?

    /// The lowest threshold already announced on this discharge, or nil if none has been.
    public private(set) var announcedThreshold: Int?

    public init() {}

    /// Fold in a reading, and say what — if anything — the island should show.
    ///
    /// The order of the branches is the priority order, and it is argued rather than incidental:
    ///
    /// 1. **The charger.** It is the one thing here the user did with their hands a moment ago, and
    ///    a confirmation of an action beats a report about a condition.
    /// 2. **A low battery.** The only thing in this vocabulary with a consequence attached.
    /// 3. **Low Power Mode**, which macOS turns on by itself at 20 % — so it arrives in the same
    ///    breath as the low-battery reading, and announcing both would be two islands for one event.
    /// 4. **Charged**, which is the quietest thing here and is last for that reason.
    public mutating func handle(_ state: PowerState) -> PowerAnnouncement? {
        defer { previous = state }
        guard state.isPresent else { return nil }
        guard let previous else { return nil }

        if state.isPluggedIn != previous.isPluggedIn {
            // Arming the low thresholds again belongs here rather than on the discharge, because
            // this is the moment the battery's story restarts. A user who plugs in at 4 % and pulls
            // the charger out at 30 % is owed the 20 % warning on the way down again.
            announcedThreshold = nil
            return state.isPluggedIn ? .pluggedIn : .unplugged
        }

        // `last`, not `first`. The thresholds descend, so the *first* one a percentage is at or
        // below is always the highest — 10 % would report having crossed 20 % and, having already
        // announced 20 %, would then say nothing at 10 % or at 5 % for the rest of the discharge.
        // The lowest crossed threshold is the one this reading actually reached.
        if !state.isPluggedIn, let percent = state.percent,
           let threshold = Self.lowThresholds.last(where: { percent <= $0 }),
           announcedThreshold.map({ threshold < $0 }) ?? true {
            announcedThreshold = threshold
            return .low(percent: percent)
        }

        if state.isLowPowerMode != previous.isLowPowerMode {
            return .lowPowerMode(isOn: state.isLowPowerMode)
        }

        if state.isCharged && !previous.isCharged && state.isPluggedIn {
            return .charged
        }

        return nil
    }

    /// Forget everything. Called from `stop()`, so a source that is switched off and on again
    /// treats the next reading as a baseline rather than as an event — which is the same thing a
    /// fresh launch does, and for the same reason.
    public mutating func reset() {
        previous = nil
        announcedThreshold = nil
    }
}

// MARK: - The activity

public extension BuiltInActivity {

    /// One power moment, drawn.
    ///
    /// **Declared here rather than beside the other factories in `BuiltInActivity.swift`**, and that
    /// is a deliberate placement rather than an oversight. Adding a stored property to a type in
    /// IslandActivities is the cross-package memory-layout trap CLAUDE.md records — dependent
    /// packages keep the old layout and read every field at the wrong offset, with no compile error
    /// — so 2.0's parity work adds *no* members to the shared structs. The memberwise initializer is
    /// public and is documented as existing "for the cases they do not cover yet"; this is one of
    /// them. The kind's own tables still supply priority, expiry, flank and chip.
    ///
    /// The trailing flank carries the level and the leading one the glyph **and the word**, which is
    /// what `ActivityKind.power.flankSpan` (`.wider`) buys the room for — and it is why
    /// `flankAffinity` moved to `.leading` in the same change: the word is the half of this that
    /// could not be inferred from anywhere else on the screen, so it is the half a *paired* power
    /// activity keeps. Sharing the island with something that outranks it, power can land on the
    /// level's sliver instead, and `ActivityStage.flanks` then leaves the island at its standard
    /// width rather than widening it for a wordless bar.
    static func power(_ announcement: PowerAnnouncement, state: PowerState) -> Self {
        let symbol = Self.powerSymbol(for: announcement, state: state)
        let tint = Self.powerTint(for: announcement, state: state)
        let title = Self.powerTitle(for: announcement)
        let label = Self.powerFlankLabel(for: announcement)
        let subtitle = Self.powerSubtitle(for: announcement, state: state)
        let value = state.fraction.map { ActivityValue.fraction($0) }
        let spoken = [title, subtitle].compactMap { $0 }.joined(separator: ", ")

        return Self(
            kind: .power,
            presentations: ActivityPresentations(
                leading: ActivityContent(
                    symbol: symbol, title: label, tint: tint, accessibilityLabel: spoken
                ),
                // `.empty` rather than a zero fraction on a machine with no battery: an empty ring
                // is a claim about the charge, and a false one. The island collapses back to its
                // unflanked width instead, which is the same rule `deviceConnected` follows.
                trailing: value.map { ActivityContent(value: $0, tint: tint) } ?? .empty,
                compact: ActivityContent(symbol: symbol, title: title, value: value, tint: tint),
                expanded: ActivityContent(
                    symbol: symbol,
                    title: title,
                    subtitle: subtitle,
                    value: value,
                    tint: tint,
                    accessibilityLabel: spoken
                )
            )
        )
    }

    private static func powerTitle(for announcement: PowerAnnouncement) -> String {
        switch announcement {
        case .pluggedIn: sourceText("power.title.charging", "Charging")
        case .unplugged: sourceText("power.title.onBattery", "On Battery")
        case .charged: sourceText("power.title.charged", "Charged")
        case .low: sourceText("power.title.lowBattery", "Low Battery")
        case .lowPowerMode(let isOn):
            isOn
                ? sourceText("power.title.lowPowerModeOn", "Low Power Mode On")
                : sourceText("power.title.lowPowerModeOff", "Low Power Mode Off")
        }
    }

    /// The word drawn beside the glyph in the leading sliver, on an island widened to hold it — see
    /// `ActivityKind.flankSpan`.
    ///
    /// **A second string rather than `powerTitle` reused**, for the reason `SystemHUD.label` is a
    /// second string beside `accessibilityLabel`: the open island's title is read with a percentage
    /// and an estimate under it and can afford a sentence, while the sliver is one line beside a
    /// glyph and the shape of the island is sized to its longest translation. So Low Power Mode is
    /// "Low Power On" here and "Low Power Mode On" there — the same fact, said in the room each
    /// place has.
    ///
    /// **What it may not do is shorten the fact.** "Battery" is not "On Battery" and "Low" is not
    /// "Low Battery": the first pair differ on whether a cable is in, and the second on whether the
    /// user has to go and find one. Every candidate that fitted the HUD's 61pt sliver failed on
    /// that, which is why `IslandLayout.widerFlankedWidthGrowth` exists at all. A translation
    /// reaching for a clause where a phrase will do widens the island for everybody who reads that
    /// language — `WideFlankLayoutTests` measures all twenty-four against the sliver on every run.
    private static func powerFlankLabel(for announcement: PowerAnnouncement) -> String {
        switch announcement {
        case .pluggedIn: sourceText("power.flank.charging", "Charging")
        case .unplugged: sourceText("power.flank.onBattery", "On Battery")
        case .charged: sourceText("power.flank.charged", "Charged")
        case .low: sourceText("power.flank.lowBattery", "Low Battery")
        case .lowPowerMode(let isOn):
            isOn
                ? sourceText("power.flank.lowPowerModeOn", "Low Power On")
                : sourceText("power.flank.lowPowerModeOff", "Low Power Off")
        }
    }

    /// The percentage, and the estimate **only when there is one**.
    ///
    /// Never "0 min left" and never "unknown": where the estimate is not a duration the sentence is
    /// simply shorter, because a battery that has not finished working out how long it has is not
    /// telling the user anything by saying so.
    private static func powerSubtitle(
        for announcement: PowerAnnouncement,
        state: PowerState
    ) -> String? {
        var parts: [String] = []
        if let percent = state.percent { parts.append("\(percent)%") }
        if let formatted = state.estimate.formatted {
            switch announcement {
            case .pluggedIn: parts.append(sourceText("power.estimate.toFull", "\(formatted) to full"))
            case .unplugged, .low: parts.append(sourceText("power.estimate.left", "\(formatted) left"))
            case .charged, .lowPowerMode: break
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A glyph that says what is happening, at the level it is happening at.
    ///
    /// `battery.100percent.bolt` is the only battery symbol with a bolt in it — `battery.25percent.bolt`
    /// does not exist, checked against the installed SF Symbols rather than assumed, and a missing
    /// symbol name draws nothing at all in the one slot this kind has.
    private static func powerSymbol(for announcement: PowerAnnouncement, state: PowerState) -> String {
        switch announcement {
        case .lowPowerMode(let isOn): return isOn ? "bolt.badge.a.fill" : "bolt.fill"
        case .charged: return "battery.100percent.bolt"
        case .pluggedIn: return "battery.100percent.bolt"
        case .unplugged, .low: break
        }
        switch state.percent ?? 0 {
        case 88...: return "battery.100percent"
        case 63..<88: return "battery.75percent"
        case 38..<63: return "battery.50percent"
        case 13..<38: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    private static func powerTint(for announcement: PowerAnnouncement, state: PowerState) -> ActivityTint {
        switch announcement {
        case .pluggedIn, .charged: .positive
        case .lowPowerMode(let isOn): isOn ? .warning : .neutral
        // Five per cent is the point at which the machine is about to make the decision for the
        // user, which is the only thing in this kind that earns `.critical`.
        case .low(let percent): percent <= 5 ? .critical : .warning
        case .unplugged: state.percent.map { $0 <= 20 } == true ? .warning : .neutral
        }
    }
}
