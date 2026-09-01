import IslandActivities
import SwiftUI

/// One event as a pill: the calendar's colour as the ground, its disc at the leading edge, and the
/// event inside it.
///
/// **Its own view because two surfaces draw it**, and they are one swipe apart: the home page's
/// date column and the schedule surface reached by clicking that column. A second spelling of a row
/// this recognisable is a row that drifts — a point of type here, a point of inset there — and the
/// drift is visible precisely because a person moves between the two in a single gesture.
///
/// A pill rather than the glance's time-gutter-plus-title row, because neither column is wide
/// enough for a fixed gutter — `GlanceLayout.timeColumnWidth` is 58pt, which is nearly half of
/// home's date column. So the calendar's colour becomes the ground the row is drawn on rather than
/// a dot beside it, and the time goes inside with the title.
struct GlanceEventPill: View {

    let event: GlanceEvent

    let increaseContrast: Bool

    var body: some View {
        let calendar = event.calendarTint ?? .init(red: 0.5, green: 0.5, blue: 0.5)
        let tint = calendar.color(increaseContrast: increaseContrast)
        return HStack(spacing: IslandHomeLayout.eventBadgeSpacing) {
            badge(tint: tint)

            // **The calendar's own colour, not white.** The pill is the row's identity and the
            // words are most of the pill, so drawing them in a neutral put the colour entirely in
            // the two elements nobody reads — the disc and a ground at a fifth of its strength.
            // `labelColor` is what makes that safe on a dark calendar; see it for the floor.
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(calendar.labelColor(increaseContrast: increaseContrast))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.leading, IslandHomeLayout.eventBadgeInset)
        .padding(.trailing, IslandHomeLayout.eventTextInset)
        .frame(height: IslandHomeLayout.eventHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Dimmer than the disc, because the colour is stated at full strength there. A ground that
        // carried the identity *and* a disc that did would be three coloured bars down the column,
        // which is the day reading as an alert rather than as a list.
        .contentShape(Capsule())
        .background(
            Capsule().fill(tint.opacity(increaseContrast ? 0.42 : 0.18))
        )
    }

    /// The disc at the leading edge — the calendar's colour at full strength, with a glyph knocked
    /// out of it.
    ///
    /// **The meeting's service where there is one to join, and a star otherwise.** The star carries
    /// no information and is not pretending to: what it does is give every pill the same silhouette,
    /// so three of them down a narrow column read as one list rather than as three unrelated
    /// coloured shapes. That is the whole job, and it is why the *one* glyph that does mean
    /// something — the service a click would take you into — takes the space when it applies.
    ///
    /// The glyph is drawn in near-black rather than in the ground's own colour: the disc is opaque
    /// and the capsule under it is not, so matching the ground would leave the symbol showing
    /// whatever the desktop is doing through the island's blur on a synthesized notch.
    private func badge(tint: Color) -> some View {
        ZStack {
            Circle().fill(tint)

            Image(systemName: event.meeting?.provider.symbol ?? "star.fill")
                .font(.system(size: IslandHomeLayout.eventBadgeGlyphSize, weight: .bold))
                .foregroundStyle(.black.opacity(0.7))
        }
        .frame(
            width: IslandHomeLayout.eventBadgeSide,
            height: IslandHomeLayout.eventBadgeSide
        )
    }

    /// An all-day event has no time worth printing, so it is the title alone; a timed one leads with
    /// its clock, which is what the eye reads down the column for.
    private var text: String {
        event.isAllDay
            ? event.title
            : "\(GlanceFormat.clock(event.start)) \(event.title)"
    }
}
