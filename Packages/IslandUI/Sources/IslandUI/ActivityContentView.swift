import Foundation
import IslandActivities
import SwiftUI

/// Draws one `ActivityContent` in one slot.
///
/// `ActivityContent` is inert data — a symbol name, two strings, a value and a tint — and this is
/// the only place in Isleta that decides what any of that looks like. That split is what lets
/// IslandActivities be exercised with no window and no permission, and it is why an activity cannot
/// draw something the vocabulary has no word for (see that package's README).
///
/// ## Type
///
/// SF Pro through `.system()` and nothing else, ever (§6.5). Isleta bundles no font: a bundled face
/// would be a second typeface on a surface whose entire claim is that it is part of the system, and
/// it would not track the user's Text Size or the optical sizes SF switches between. `.rounded` is
/// reserved for numerals that are being read as a quantity — timers and HUD levels — where SF
/// Rounded's even-width digits are what stops a counting number from looking like it is flickering.
///
/// Every size, inset and spacing here is a whole number of points, so the layout lands on the pixel
/// grid at 1x as well as at 2x (§6.6). Half-points are what make a 1pt separator look like a 2pt
/// smudge on a non-Retina external display.
public struct ActivityContentView: View {

    /// The one `matchedGeometryEffect` id in Isleta.
    ///
    /// The symbol is the object that survives the compact-to-expanded morph — it is the same glyph,
    /// in the same activity, moving and growing — and §6.2 asks for exactly that. The title and
    /// subtitle are *not* matched: they change size, weight and line count at once, and a matched
    /// `Text` interpolates its frame while its glyphs snap, which reads as the text jumping inside a
    /// box that is sliding. They crossfade instead.
    static let symbolGeometryID = "isleta.activity.symbol"

    private let content: ActivityContent
    private let slot: ActivitySlot
    private let increaseContrast: Bool
    private let reduceMotion: Bool
    private let now: Date
    private let namespace: Namespace.ID?

    /// Extra points a level in this slot is drawn longer by, while the island rebounds at the end of
    /// a range — see `IslandScreenModel.bounceStretch(for:)`. A magnitude, never negative, and zero
    /// for everything else always. Which end it grows from is `levelStretchAnchor`.
    private let levelStretch: CGFloat

    /// The end of the bar that stays put while `levelStretch` grows it: its left at the top of a
    /// range, its right at the bottom.
    ///
    /// **Handed in separately because it must not animate**, and that is the point rather than a
    /// detail — see `IslandScreenModel.bounceStretchAnchor`. A signed stretch would carry both, and
    /// a signed spring aimed at zero overshoots through it, which puts the growth on the far end
    /// for a frame or two at the end of every rebound.
    private let levelStretchAnchor: UnitPoint

    /// Where an app icon comes from, or nil for a slot that has no business asking — a preview, a
    /// test, a HUD. A content naming an icon with no store simply draws its `symbol`, which is the
    /// same thing that happens while the icon is still being decoded.
    private let icons: ApplicationIconStore?

    /// - Parameters:
    ///   - namespace: the namespace the compact/expanded morph is matched in. `nil` renders the
    ///     content with no matched geometry, which is what a flank wants — a flank and the expanded
    ///     body are on screen *at the same time*, and two views claiming one geometry id is a
    ///     SwiftUI runtime error, not a design choice.
    public init(
        content: ActivityContent,
        slot: ActivitySlot,
        increaseContrast: Bool = false,
        reduceMotion: Bool = false,
        now: Date = Date(),
        namespace: Namespace.ID? = nil,
        icons: ApplicationIconStore? = nil,
        levelStretch: CGFloat = 0,
        levelStretchAnchor: UnitPoint = .leading
    ) {
        self.content = content
        self.slot = slot
        self.increaseContrast = increaseContrast
        self.reduceMotion = reduceMotion
        self.now = now
        self.namespace = namespace
        self.icons = icons
        self.levelStretch = levelStretch
        self.levelStretchAnchor = levelStretchAnchor
    }

    public var body: some View {
        Group {
            switch slot {
            case .leading: flank(alignment: .leading)
            case .trailing: flank(alignment: .trailing)
            case .compact: compact
            case .expanded: expanded
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var tintColor: Color {
        ActivityPalette.color(for: content.tint, increaseContrast: increaseContrast)
    }

    private var secondaryOpacity: Double {
        ActivityPalette.secondaryOpacity(increaseContrast: increaseContrast)
    }

    // MARK: - Slots

    /// A sliver beside the cutout.
    ///
    /// Aligned to the island's outer edge rather than centerd in the sliver. Centring reads fine at
    /// peek widths and wrong once the island opens: the flanks then run ~98pt wide and a centerd
    /// glyph floats in the middle of a black field with the cutout half a flank away. Hugging the
    /// outer edge keeps the two flanks reading as the ends of one bar, which is what they are.
    /// The margin each side of a flank's content.
    ///
    /// A flank holding nothing but a number gets its padding back. 10pt each side of a 40pt sliver
    /// leaves 20pt for the content, which is enough for a glyph and not for a number — and a flank
    /// with no symbol *is* the number, with nothing beside it to crowd.
    ///
    /// The rule used to require `title == nil` as well, so only a flank carrying a bare `value`
    /// qualified. A `title` of "84°" did not: 26pt of text in 20pt of room truncated to an ellipsis,
    /// so the island showed "…" where the temperature belonged and only came right once it opened
    /// and the slivers grew to 91pt. Reported from hardware as the degrees not appearing until hover.
    ///
    /// The margin exists to keep a *glyph* off the cutout's edge. A number needs the room more than
    /// it needs the margin.
    ///
    /// `nonisolated` because `View` conformance is `@MainActor` and this is arithmetic on a value —
    /// a test should not need the main actor to ask how wide a margin is.
    nonisolated static func flankPadding(for content: ActivityContent) -> CGFloat {
        content.symbol == nil ? 4 : 10
    }

    /// The widest a level is drawn in a sliver, whatever room the sliver has.
    ///
    /// **76, which is 16pt of black either side of it on a wide island** (`IslandLayout`'s
    /// `wideFlankedFlankWidth` is 108) — enough that the bar is clearly *in* the flank rather than
    /// spanning it, and enough that neither end is near the cutout or the island's outer edge. The
    /// figure is a look rather than a measurement, arrived at from the owner's note that the filled
    /// bar sat "so close to the outside and inside of the notch".
    ///
    /// A ceiling, not a width: at the standard 40pt sliver there are only 32pt to be had and the bar
    /// takes all of them, exactly as it did before this existed. Nothing about the collapsed island
    /// most people see changes.
    nonisolated static let flankLevelWidth: CGFloat = 76

    private func flank(alignment: HorizontalAlignment) -> some View {
        // A level is **centred in its sliver** rather than held against the outer edge, and capped
        // at `flankLevelWidth` rather than filling it. Filling was the first version and it put the
        // bar 4pt from the island's outer edge and 4pt from the cutout, which on a 108pt sliver
        // reads as a bar wedged into a slot — the same objection `ActivitySlotLayout.minimumFlankWidth`
        // makes about a glyph touching the edge of a black shape on a black bezel. Centred and
        // short, it reads as a gauge sitting in the flank.
        //
        // At the standard `IslandLayout.flankedFlankWidth` of 40 nothing changes: the available room
        // is 32pt, well under the cap, so the bar still spans the sliver exactly as it always did.
        // The cap only ever bites on a wide island. A number is not a level and keeps the spacer:
        // numerals hug the edge, a bar sits in the middle.
        let levelFills = content.value?.normalized != nil
        return HStack(spacing: 4) {
            if levelFills { Spacer(minLength: 0) }
            if alignment == .trailing, !levelFills { Spacer(minLength: 0) }
            symbol(size: 13, weight: .semibold, matched: false)
            if let title = content.title {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tintColor)
                    .lineLimit(1)
                    // The sliver is a constant and the word in it is not: `IslandLayout`'s
                    // `wideFlankedWidthGrowth` is measured against the longest label the shipped
                    // languages produce, so nothing tightens today — this is the floor that keeps a
                    // future translation, or a larger Text Size, shrinking rather than truncating.
                    // A label cut to "Lautstär…" says less than a label at 10pt.
                    .minimumScaleFactor(0.8)
                    .allowsTightening(true)
                    .contentTransition(.opacity)
            }
            if let value = content.value {
                valueView(value)
                    .frame(maxWidth: levelFills ? Self.flankLevelWidth : nil)
                    // **A scale, not a wider frame.** `scaleEffect` does not take part in layout, so
                    // the spacers either side of a centred bar do not rebalance and the fixed end
                    // stays exactly where it is — which is the whole point. A frame that grew would
                    // push the bar back toward the middle and move both ends. The track and the fill
                    // stretch together because the fill is a fraction of the frame *before* the
                    // scale, which is what makes it read as one elastic object rather than a fill
                    // sliding inside a track.
                    //
                    // Anchored at the end that is *not* being pushed, and the anchor is a
                    // parameter rather than the sign of this number — see `levelStretchAnchor`.
                    // Against `flankLevelWidth` rather than the drawn width because a rebound only
                    // ever happens on a wide island, where the bar is at that cap — see
                    // `ActivityKind.reboundsAtItsLimits`, the system HUDs and nothing else.
                    .scaleEffect(
                        x: (Self.flankLevelWidth + max(0, levelStretch)) / Self.flankLevelWidth,
                        anchor: levelStretchAnchor
                    )
            }
            if alignment == .leading, !levelFills { Spacer(minLength: 0) }
            if levelFills { Spacer(minLength: 0) }
        }
        .padding(.horizontal, Self.flankPadding(for: content))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The single badge, for an island with no flanks to fill — a synthesized one, or a hardware
    /// one that has not yet grown wide enough to have slivers beside the cutout.
    private var compact: some View {
        HStack(spacing: 5) {
            symbol(size: 12, weight: .semibold, matched: true)
            if let title = content.title {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tintColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentTransition(.opacity)
            }
            // A level spans whatever is left, the way it does in a sliver — the badge is the whole
            // island here, so a 40pt bar stranded beside the word was a bar that did not grow when
            // the island did. Numerals still take their own width and sit where they fall.
            if let value = content.value {
                valueView(value)
                    .frame(maxWidth: value.normalized == nil ? nil : .infinity)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The open island: the click's result.
    ///
    /// A level and a countdown sit in different places on purpose. A fraction is an attribute of
    /// the thing named above it, so it goes under the text and runs its full width; a countdown is
    /// the headline, so it goes to the trailing edge at a size that can be read across a desk.
    ///
    /// **Every measurement here is `ActivityExpandedHeight`'s**, because the island was sized to
    /// this layout before it was drawn — the two are the same arithmetic asked in opposite
    /// directions, and a number changed in one of them and not the other is a message clipped by
    /// exactly the difference. `ActivityExpandedHeightTests` pins them together.
    private var expanded: some View {
        HStack(spacing: ActivityExpandedHeight.symbolSpacing) {
            symbolWell
            VStack(alignment: .leading, spacing: ActivityExpandedHeight.titleSubtitleSpacing) {
                if let title = content.title {
                    Text(title)
                        .font(.system(size: ActivityExpandedHeight.titleStyle.size, weight: .semibold))
                        .foregroundStyle(tintColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .contentTransition(.opacity)
                }
                if let subtitle = content.subtitle {
                    Text(subtitle)
                        .font(.system(size: ActivityExpandedHeight.subtitleStyle.size, weight: .regular))
                        .foregroundStyle(tintColor.opacity(secondaryOpacity))
                        // The island was opened to fit this many lines — see
                        // `ActivityExpandedHeight.messageLineLimit`. Two was the old value and the
                        // old constant height, which cut a notification off mid-sentence in an
                        // island with 60pt of nothing under it.
                        .lineLimit(ActivityExpandedHeight.messageLineLimit)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                }
                if let value = content.value, value.isTimeDependent == false {
                    valueView(value)
                        .padding(.top, ActivityExpandedHeight.valueTopPadding)
                }
            }
            Spacer(minLength: 8)
            if let value = content.value, value.isTimeDependent {
                valueView(value)
            }
        }
        .padding(.horizontal, ActivityExpandedHeight.horizontalPadding)
        .padding(.vertical, ActivityExpandedHeight.verticalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// The expanded symbol, in a rounded well.
    ///
    /// Continuous corners, never circular — the same rule as the island's own outline (§6.4). The
    /// well is what gives the symbol a frame to grow into during the morph; a bare glyph scaling
    /// from 12pt to 22pt has nothing around it and reads as a zoom rather than as an object
    /// arriving.
    private var symbolWell: some View {
        ZStack {
            // An app icon is already a shaped object with its own material, so it replaces the
            // well rather than sitting in one. A tinted rounded square behind a rounded square
            // reads as a badge on a badge, and at 44pt the two radii are close enough to look like
            // a rendering mistake rather than a frame.
            if applicationIcon != nil {
                symbol(size: ActivityExpandedHeight.symbolWellSide, weight: .medium, matched: true)
            } else if content.symbol != nil {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(tintColor.opacity(increaseContrast ? 0.24 : 0.14))
                symbol(size: 22, weight: .medium, matched: true)
            }
        }
        .frame(
            width: content.symbol == nil ? 0 : ActivityExpandedHeight.symbolWellSide,
            height: content.symbol == nil ? 0 : ActivityExpandedHeight.symbolWellSide
        )
    }

    // MARK: - Pieces

    /// The posting app's icon, if the store has decoded one for this content yet.
    ///
    /// Read through a computed property rather than at each use so one `body` evaluation makes one
    /// request, and so the "is there an icon" question the well asks and the "draw it" the glyph
    /// does cannot disagree within a frame.
    private var applicationIcon: CGImage? {
        guard let name = content.applicationIconName, let icons else { return nil }
        return icons.icon(named: name)
    }

    @ViewBuilder
    private func symbol(size: CGFloat, weight: Font.Weight, matched: Bool) -> some View {
        // One `if`/`else` chain, never two views, because both branches claim
        // `symbolGeometryID`: during the swap from bell to icon the outgoing view is still in the
        // hierarchy, and two live claims on one geometry id resolve against the wrong one and make
        // the glyph jump instead of traveling.
        if let icon = applicationIcon {
            let image = Image(decorative: icon, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(
                    // See `ApplicationIconMetrics.canvasScale`: the icon's shape fills 80% of its
                    // own canvas, so the box has to be larger than the glyph's for the two to
                    // weigh the same in the sliver.
                    width: size * ApplicationIconMetrics.canvasScale,
                    height: size * ApplicationIconMetrics.canvasScale
                )
                .contentTransition(.opacity)
            if matched, let namespace {
                image.matchedGeometryEffect(id: Self.symbolGeometryID, in: namespace)
            } else {
                image
            }
        } else if let name = content.symbol {
            // `variableValue` lights a glyph's own layers in turn — the volume glyph's two waves,
            // which is what makes the sliver say roughly where in its range the level is without
            // the bar on the other side of the cutout being read. Nil for every other content, and
            // ignored outright by the symbols that carry no variable layers: see
            // `ActivityContent.symbolVariableValue`, where which is which is measured.
            let image = Image(systemName: name, variableValue: content.symbolFill)
                .font(.system(size: size, weight: weight))
                // Hierarchical gives a glyph depth against pure black. Increase Contrast is a
                // request for fewer shades, not more, so it collapses to a single one.
                .symbolRenderingMode(increaseContrast ? .monochrome : .hierarchical)
                .foregroundStyle(tintColor)
                // A glyph swapping under a live activity — "waveform" to "pause.fill" — is a
                // content change in the §6.2 sense and crossfades on whatever curve opened the
                // transaction, rather than snapping a frame ahead of the text beside it.
                .contentTransition(.opacity)
            if matched, let namespace {
                image.matchedGeometryEffect(id: Self.symbolGeometryID, in: namespace)
            } else {
                image
            }
        }
    }

    private func valueView(_ value: ActivityValue) -> some View {
        ActivityValueView(
            value: value,
            slot: slot,
            tint: content.tint,
            increaseContrast: increaseContrast,
            reduceMotion: reduceMotion,
            now: now
        )
    }

    // MARK: - Accessibility

    /// What VoiceOver reads for this slot.
    ///
    /// `ActivityContent.accessibilityLabel` wins where a provider supplied one, because the compact
    /// slots are glyphs and abbreviations by design and "1:04" read aloud is nothing at all. Where
    /// it did not, the visible strings are assembled — including the value, which is otherwise a
    /// bar with no text in it anywhere.
    private var accessibilityLabel: String {
        if let supplied = content.accessibilityLabel, !supplied.isEmpty { return supplied }
        var parts = [content.title, content.subtitle].compactMap { $0 }
        if let value = content.value,
           let spoken = ActivityValueFormatter.accessibilityText(for: value, at: now) {
            parts.append(spoken)
        }
        return parts.joined(separator: islandText("list.separator", ", "))
    }
}
