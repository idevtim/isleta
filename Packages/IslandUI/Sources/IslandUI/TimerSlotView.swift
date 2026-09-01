import IslandActivities
import IslandKit
import SwiftUI

/// Clock's radial timer, drawn on the island.
///
/// The second use of the bespoke-renderer escape hatch IslandActivities' README sanctions, after
/// Now Playing. A ring is not sayable in a vocabulary of symbols and strings, and the generic
/// renderer's answer for a timeline is a *bar* — which is right for a scrubber and wrong for a
/// countdown that Apple's own Clock draws as a shrinking arc.
///
/// **The arc shrinks; it does not fill.** `BuiltInActivity.timer` carries a timeline running
/// backwards, so `fraction(at:)` is the proportion of the timer still to go — which is what Clock
/// shows, and the opposite of what a progress bar would.
struct TimerSlotView: View {

    let content: ActivityContent
    let slot: ActivitySlot
    let increaseContrast: Bool
    let reduceMotion: Bool
    let now: Date

    var body: some View {
        switch slot {
        case .leading, .trailing:
            // A 40pt sliver with 32pt of height. There is no room for a ring *and* a number side by
            // side, so the number goes inside the ring — which is how Clock draws it anyway.
            ring(diameter: 26, stroke: 2.5, textSize: 9)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .compact:
            HStack(spacing: 6) {
                ring(diameter: 20, stroke: 2, textSize: 0)
                if let title = content.title {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(.white)
                }
                if let text = clockText {
                    Text(text)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .expanded:
            expanded
        }
    }

    /// The open island: the ring where the symbol well would be, with the countdown inside it, and
    /// the timer's name beside it. Sized to `ActivityExpandedHeight.symbolWellSide` so the height
    /// arithmetic that decides how tall the island opens stays correct — see that type, which
    /// duplicates the view's constants on purpose and is pinned against them.
    private var expanded: some View {
        HStack(spacing: ActivityExpandedHeight.symbolSpacing) {
            ring(
                diameter: ActivityExpandedHeight.symbolWellSide,
                stroke: 3.5,
                textSize: 13
            )
            VStack(alignment: .leading, spacing: ActivityExpandedHeight.titleSubtitleSpacing) {
                if let title = content.title {
                    Text(title)
                        .font(.system(size: ActivityExpandedHeight.titleStyle.size, weight: .semibold))
                        .lineLimit(1)
                }
                if let subtitle = content.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: ActivityExpandedHeight.subtitleStyle.size))
                        .foregroundStyle(.white.opacity(increaseContrast ? 1 : 0.7))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, ActivityExpandedHeight.horizontalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The ring, and optionally the remaining time inside it.
    ///
    /// `textSize` zero draws no numerals — the compact badge puts them beside the ring instead,
    /// because it has the width and a number inside a 20pt circle would not be legible.
    private func ring(diameter: CGFloat, stroke: CGFloat, textSize: CGFloat) -> some View {
        ZStack {
            Circle()
                .stroke(increaseContrast ? .white.opacity(0.35) : ActivityPalette.timerRingTrack,
                        style: StrokeStyle(lineWidth: stroke, lineCap: .round))
            Circle()
                .trim(from: 0, to: max(0.0001, remainingFraction))
                // Gray while held, which is what Clock does — a lit orange arc on a paused timer
                // reads as one that is still running, and the flank has no subtitle to say
                // otherwise.
                .stroke(isCounting ? ActivityPalette.timerRing : ActivityPalette.timerRingPaused,
                        style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                // Twelve o'clock, clockwise, which is where Clock starts its arc.
                .rotationEffect(.degrees(-90))
                // The arc is redrawn on the display link's tick while the timer runs, so it needs no
                // animation of its own — and an implicit one would fight the tick, easing towards a
                // value that has already moved. Under Reduce Motion this is the same still frame,
                // one second later, which §6.3 asks for.
                .animation(nil, value: remainingFraction)
            if textSize > 0, let text = clockText {
                Text(text)
                    .font(.system(size: textSize, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(.white)
                    .padding(.horizontal, stroke + 1)
            }
        }
        .frame(width: diameter, height: diameter)
    }

    /// How much of the ring is still lit. Zero when there is nothing to draw, which is the finished
    /// timer — it carries no value at all.
    /// Whether the countdown is actually moving. False for a paused timer, which is the same fact
    /// that keeps it off the display link.
    private var isCounting: Bool {
        guard case .timeline(let timeline) = content.value else { return false }
        return timeline.isAdvancing
    }

    private var remainingFraction: Double {
        guard case .timeline(let timeline) = content.value else { return 0 }
        return timeline.fraction(at: now) ?? 0
    }

    private var clockText: String? {
        guard let value = content.value else { return nil }
        return ActivityValueFormatter.text(for: value, at: now, slot: slot)
    }
}
