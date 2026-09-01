import Foundation
import IslandActivities
import SwiftUI

/// Turns an `ActivityValue` into the characters that go on screen.
///
/// Split out from the view because this is the part with decisions in it, and none of them need a
/// window: rounding, the point at which a timer grows an hours field, and what a negative interval
/// means. `ActivityContent` deliberately carries `.countdown(until:)` rather than a pre-formatted
/// `"4:59"` so that a provider does not have to re-emit an activity every second to keep a string
/// current — §9 forbids exactly that poll. The cost of that decision is this file.
public enum ActivityValueFormatter {

    /// The numerals for a value, or nil for the values that are drawn rather than spelled.
    ///
    /// - Parameter now: supplied rather than read, so every test of this is a pure function call
    ///   and so that one clock tick formats every visible value at the same instant — two timers
    ///   sampling `Date()` a few hundred microseconds apart can straddle a second boundary and
    ///   render "1:00" next to "0:59".
    /// The string for a value, spelled for the room the slot actually has.
    ///
    /// A flank gets the **compact** clock: `IslandLayout.flankedFlankWidth` is 40pt, which is four
    /// or five glyphs, and `1:04:20` is seven. `1h04` says the same thing in four.
    public static func text(for value: ActivityValue, at now: Date, slot: ActivitySlot) -> String? {
        guard slot == .leading || slot == .trailing else { return text(for: value, at: now) }
        switch value {
        case .fraction, .indeterminate:
            return nil
        case .countdown(let until):
            return compactClock(seconds: until.timeIntervalSince(now))
        case .elapsed(let since):
            return compactClock(seconds: now.timeIntervalSince(since))
        case .timeline(let timeline):
            return compactClock(seconds: timeline.position(at: now))
        }
    }

    /// `4:56`, and `1h04` where the full clock would be `1:04:20`.
    ///
    /// Hours and minutes, never hours-minutes-seconds. A seconds digit is unreadable at a glance on
    /// an hour-long timer anyway, and the two extra glyphs are what will not fit.
    static func compactClock(seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        guard total >= 3600 else { return clock(seconds: seconds) }
        // The `h` is the one separator in this file that is a *convention* rather than arithmetic,
        // so it is the one that is translatable: `1h04` is how English and French write it and not
        // how every language does. The minutes are padded here rather than in the format, because a
        // translation cannot be trusted to carry a `%02lld` through unchanged and losing the zero
        // turns `1h04` into `1h4`.
        return islandText(
            "value.compactClock.hours",
            "\(total / 3600)h\(String(format: "%02d", (total % 3600) / 60))"
        )
    }

    public static func text(for value: ActivityValue, at now: Date) -> String? {
        switch value {
        case .fraction, .indeterminate:
            return nil
        case .countdown(let until):
            return clock(seconds: until.timeIntervalSince(now))
        case .elapsed(let since):
            return clock(seconds: now.timeIntervalSince(since))
        case .timeline(let timeline):
            return clock(seconds: timeline.position(at: now))
        }
    }

    /// What VoiceOver says. Never the same string as `text`: "1:04" read aloud is "one oh four".
    public static func accessibilityText(for value: ActivityValue, at now: Date) -> String? {
        switch value {
        case .fraction:
            guard let fraction = value.normalized else { return nil }
            return islandText("value.a11y.percent", "\(Int((fraction * 100).rounded())) percent")
        case .indeterminate:
            return islandText("value.a11y.inProgress", "in progress")
        case .countdown(let until):
            return islandText(
                "value.a11y.remaining",
                "\(spoken(seconds: until.timeIntervalSince(now))) remaining"
            )
        case .elapsed(let since):
            return islandText(
                "value.a11y.elapsed",
                "\(spoken(seconds: now.timeIntervalSince(since))) elapsed"
            )
        case .timeline(let timeline):
            return islandText(
                "value.a11y.elapsed",
                "\(spoken(seconds: timeline.position(at: now))) elapsed"
            )
        }
    }

    /// `m:ss`, growing an hours field only once there are hours to show.
    ///
    /// A countdown that has run out reads `0:00` rather than going negative. The activity is
    /// expected to be withdrawn at that point, but the display link and the coordinator's scheduled
    /// sleep are two different clocks and there is no ordering between them — a frame drawn after
    /// the deadline and before the withdrawal is normal, and `-0:01` in it is not.
    static func clock(seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// The duration alone — "4 minutes 30 seconds" — with the "remaining"/"elapsed" word left to the
    /// caller.
    ///
    /// It used to take that word as a `suffix` and glue it on with a space, which is exactly the
    /// shape a translation cannot survive: the word goes *after* the duration in English, French and
    /// German and *before* it in Chinese, and a suffix parameter puts that decision in Swift where no
    /// translator can reach it. The two callers now own a whole sentence each.
    private static func spoken(seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        let minutes = total / 60
        let secs = total % 60
        var parts: [String] = []
        if minutes > 0 { parts.append(islandText("value.a11y.minutes", "\(minutes) minutes")) }
        if secs > 0 || minutes == 0 { parts.append(islandText("value.a11y.seconds", "\(secs) seconds")) }
        return parts.joined(separator: " ")
    }
}

/// Draws an `ActivityValue`.
///
/// The two shapes it can take are not interchangeable and are chosen by the value, not by the slot:
/// a fraction is a *level* and reads as a bar, a countdown is a *number* and reads as numerals. The
/// slot only decides how big.
struct ActivityValueView: View {

    let value: ActivityValue
    let slot: ActivitySlot
    let tint: ActivityTint
    let increaseContrast: Bool
    let reduceMotion: Bool
    /// The instant every visible value is formatted at. Advances on the display link's tick, and
    /// only while something on screen is time-dependent.
    let now: Date

    var body: some View {
        switch value {
        case .fraction:
            level
        case .countdown, .elapsed:
            numerals
        case .indeterminate:
            indeterminate
        case .timeline(let timeline):
            // A timeline reaching the *generic* renderer means an activity carried one without
            // being the kind that has a bespoke view for it. It is a position through something, so
            // it reads as a bar — except where there is no end to be a fraction of, which is a live
            // stream, and a full bar would be a claim the source never made.
            if let fraction = timeline.fraction(at: now) {
                ActivityValueView(
                    value: .fraction(fraction),
                    slot: slot,
                    tint: tint,
                    increaseContrast: increaseContrast,
                    reduceMotion: reduceMotion,
                    now: now
                )
            } else {
                numerals
            }
        }
    }

    private var color: Color { ActivityPalette.color(for: tint, increaseContrast: increaseContrast) }

    /// A level, drawn as a capsule filled left to right.
    ///
    /// `Capsule` and not `RoundedRectangle`: at 4pt tall the two are the same shape, and a capsule
    /// stays right if the bar ever gets taller. Whole-point dimensions throughout, so the bar lands
    /// on the pixel grid at 1x as well as 2x (§6.6).
    private var level: some View {
        GeometryReader { proxy in
            let fraction = value.normalized ?? 0
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(color.opacity(ActivityPalette.trackOpacity(increaseContrast: increaseContrast)))
                Capsule(style: .continuous)
                    .fill(color)
                    // Rounded rather than truncated: a bar one subpixel short of full at 100% is a
                    // rendering bug the user cannot unsee, and `normalized` has already clamped the
                    // 1.0000000149 that CoreAudio hands back.
                    .frame(width: (proxy.size.width * fraction).rounded())
            }
        }
        .frame(height: slot == .expanded ? 6 : 4)
    }

    private var numerals: some View {
        // `.rounded` for timer and HUD numerals (§6.5), monospaced digits so the string does not
        // change width as it counts and drag the rest of the row along with it.
        //
        // **`lineLimit(1)` is load-bearing in a flank, not tidiness.** A flank is 40pt wide with
        // 20pt of padding in it, and a countdown is the first value long enough not to fit: without
        // this the first live timer wrapped to two lines and drew "4:" over an ellipsis in the
        // sliver beside the notch. `minimumScaleFactor` is what makes the rare wide case — `59:59`,
        // the widest a sub-hour countdown gets — shrink to fit rather than truncate to nonsense.
        Text(ActivityValueFormatter.text(for: value, at: now, slot: slot) ?? "")
            .font(.system(size: slot == .expanded ? 26 : 12, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(slot == .expanded ? 1 : 0.7)
            .allowsTightening(true)
            .foregroundStyle(color)
    }

    @ViewBuilder
    private var indeterminate: some View {
        if reduceMotion {
            // The spinner is continuous motion with no state change behind it, which is precisely
            // what §6.3 asks us to stop doing. A static glyph says the same thing.
            Image(systemName: "ellipsis")
                .font(.system(size: slot == .expanded ? 18 : 11, weight: .semibold))
                .foregroundStyle(color.opacity(ActivityPalette.secondaryOpacity(increaseContrast: increaseContrast)))
        } else {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .tint(color)
        }
    }
}
