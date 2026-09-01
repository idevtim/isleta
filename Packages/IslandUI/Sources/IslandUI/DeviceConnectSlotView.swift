import IslandActivities
import IslandKit
import SwiftUI

/// A device that has just connected: its picture in one sliver, its charge in the other.
///
/// The third use of the bespoke-renderer escape hatch IslandActivities' README sanctions, after Now
/// Playing and the timer, and for the same reason both of those took it — neither half of this is
/// sayable in a vocabulary of symbols and strings. The generic renderer would draw the battery
/// fraction as a horizontal bar, which is the wrong shape for a charge and the wrong shape for the
/// sliver it sits in, and it would draw the device as a still glyph.
///
/// ## The turn, and why it is not a full one
///
/// iOS turns a rendered 3D model of the actual product. That art lives inside Apple's frameworks
/// and there is no public route to it, so this is the SF Symbol turning about its own vertical
/// axis — §6.5 allows SF Pro and SF Symbols and nothing else, and a bundled render of somebody
/// else's hardware would be both a resource bundle in a package that has none and a picture we do
/// not have the right to ship.
///
/// **A symbol cannot be turned through 90°, and the first version of this did.** A `rotation3DEffect`
/// of 360° reads perfectly well in the description and on paper; on screen a flat glyph has no
/// depth, so at 90° it is one pixel wide — the AirPods vanish outright, mid-arrival — and between
/// 90° and 270° it is drawn *mirrored*, which for an asymmetric device is the wrong hardware. Caught
/// on a screenshot rather than in a test, because every frame of it is individually plausible.
///
/// So the turn is `arrivalAngle` to zero: it comes in tilted and settles square, never approaching
/// edge-on. That is also what the moment is — an arrival, not a process — which is the other reason
/// it is not `repeatForever`. PERF.md's open Milestone 9.6 finding is that a small
/// continuously-redrawing flank appears to cost the *whole* 608×200pt transparent panel a repaint;
/// the equaliser measured 9.9% against §9's 4% animating ceiling. Under Reduce Motion it does not
/// turn at all (§6.3), and the still frame is the same picture.
struct DeviceConnectSlotView: View {

    let content: ActivityContent
    let slot: ActivitySlot
    let increaseContrast: Bool
    let reduceMotion: Bool

    /// Where amber takes over from green. Twenty percent is where Apple's own battery menu starts
    /// warning, and matching it means the island never disagrees with the menu bar two inches away.
    static let lowBatteryThreshold = 0.2

    /// The ring's diameter and stroke, per slot.
    ///
    /// Named rather than written at the three call sites because the two numbers only mean anything
    /// against each other: a stroke is read as a *proportion* of the circle it draws, so changing
    /// one without the other is what turns a charge indicator into either a hairline or a disc.
    /// These hold the ratio at very nearly 1:6 across all three, which is what makes the same ring
    /// recognisable at 15pt in the compact strip and at 26pt in the open island.
    ///
    /// Tightened from 24/2.5, 18/2 and 30/3 — smaller and heavier at every size. The old ring read
    /// as a thin outline of a circle rather than as an arc with weight, and at the trailing sliver's
    /// 24pt it crowded the flank it sits in. Note the stroke is centred on the path, so the drawn
    /// extent is `diameter + stroke`: 20 + 3.2 leaves the footprint within a point of the old
    /// 24 + 2.5 while the arc itself is a third heavier.
    private enum Ring {
        static let trailing = (diameter: 20.0, stroke: 3.2)
        static let compact = (diameter: 15.0, stroke: 2.6)
        static let expanded = (diameter: 26.0, stroke: 3.8)
    }

    /// How far over the device starts. Short of edge-on by a wide margin — at 62° the glyph is
    /// still 47% of its width and unmistakably itself, where anything past about 75° reads as a
    /// smear for the first frames.
    private static let arrivalAngle: Double = 62

    /// Driven from `.onAppear`, so the turn happens once when the island arrives with the device on
    /// it and never again — there is nothing here that can re-fire it, because the activity's
    /// identity is the device address and a repeat connect updates rather than replaces.
    @State private var settled = false

    var body: some View {
        switch slot {
        case .leading:
            device(size: 22)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .trailing:
            ring(diameter: Ring.trailing.diameter, stroke: Ring.trailing.stroke, textSize: 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .compact:
            HStack(spacing: 6) {
                device(size: 18)
                if let title = content.title {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(.white)
                }
                if fraction != nil {
                    ring(diameter: Ring.compact.diameter, stroke: Ring.compact.stroke, textSize: 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .expanded:
            expanded
        }
    }

    /// The open island. Reachable only by the user clicking — this kind never opens it — so it says
    /// the whole thing in words: which device, and what percentage, rather than a ring to read.
    private var expanded: some View {
        HStack(spacing: ActivityExpandedHeight.symbolSpacing) {
            device(size: ActivityExpandedHeight.symbolWellSide * 0.7)
                .frame(width: ActivityExpandedHeight.symbolWellSide,
                       height: ActivityExpandedHeight.symbolWellSide)
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
            if fraction != nil {
                ring(diameter: Ring.expanded.diameter, stroke: Ring.expanded.stroke, textSize: 9)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, ActivityExpandedHeight.horizontalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The device itself, turning about its vertical axis as it arrives.
    ///
    /// `perspective` is deliberately shallow. At the default the symbol's near edge swells enough
    /// to touch the sliver's boundary mid-turn, and a glyph touching the edge of the island reads
    /// as a rendering fault — the same reason `ActivitySlotLayout.minimumFlankWidth` exists.
    private func device(size: CGFloat) -> some View {
        Image(systemName: content.symbol ?? "headphones")
            .font(.system(size: size * 0.9, weight: .regular))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .rotation3DEffect(
                .degrees(settled ? 0 : Self.arrivalAngle),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.15
            )
            .onAppear {
                // Under Reduce Motion the device is simply square from the first frame. Note this
                // does **not** go through `Motion.respectingReduceMotion`, which substitutes a
                // crossfade for a morph — a crossfade between two angles is still a rotation, only
                // a shorter one, and §6.3 asks for the motion to be absent rather than hurried.
                guard !reduceMotion else {
                    settled = true
                    return
                }
                // `Motion.nudge`, not a duration. §6.1 allows four spring tokens and no inline
                // curve anywhere in this codebase, and `nudge` is the arrival one — the device
                // overshoots square by a few degrees and settles, which is what gives a flat glyph
                // the suggestion of weight that its missing third dimension cannot.
                withAnimation(Motion.nudge) { settled = true }
            }
    }

    /// The charge, as an arc that fills rather than one that empties — the opposite of the timer's,
    /// because a battery at 80% is 80% *full* where a timer at 80% has 80% left to run.
    private func ring(diameter: CGFloat, stroke: CGFloat, textSize: CGFloat) -> some View {
        ZStack {
            Circle()
                .stroke(increaseContrast ? .white.opacity(0.35) : ActivityPalette.timerRingTrack,
                        style: StrokeStyle(lineWidth: stroke, lineCap: .round))
            if let fraction {
                Circle()
                    // Floored so a device reporting 1% still draws a mark rather than nothing —
                    // an unlit ring and an absent battery would otherwise look identical.
                    .trim(from: 0, to: max(0.02, fraction))
                    .stroke(ringColor, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            if textSize > 0, let percent = percentText {
                Text(percent)
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

    private var ringColor: Color {
        guard let fraction else { return ActivityPalette.batteryRing }
        if increaseContrast { return .white }
        return fraction <= Self.lowBatteryThreshold
            ? ActivityPalette.batteryRingLow
            : ActivityPalette.batteryRing
    }

    /// The charge as 0...1, or nil when the device reported none — in which case no ring is drawn
    /// at all. An empty ring is a claim about the battery, and a false one.
    private var fraction: Double? { content.value?.normalized }

    private var percentText: String? {
        fraction.map { "\(Int(($0 * 100).rounded()))" }
    }
}
