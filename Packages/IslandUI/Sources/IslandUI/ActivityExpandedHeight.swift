import AppKit
import CoreGraphics
import Foundation
import IslandActivities
import IslandKit

/// A font, named the way `ActivityContentView` names one: a size and a weight, nothing else.
///
/// Its own type rather than an `NSFont` so the height arithmetic below can be exercised against a
/// measurer that knows no fonts at all — see `ActivityTextMeasure.fixed(lineHeight:)`. §6.5 allows
/// SF Pro through `.system()` and nothing else, so a family name would be a field with one value.
public struct ActivityTextStyle: Equatable, Sendable {

    public enum Weight: Equatable, Sendable {
        case regular
        case medium
        case semibold
    }

    public var size: CGFloat
    public var weight: Weight

    public init(size: CGFloat, weight: Weight = .regular) {
        self.size = size
        self.weight = weight
    }
}

/// How tall a run of text lays out. The one impure thing the island's expanded height depends on.
///
/// Injected rather than called directly, for the reason every other pure-geometry type in this
/// package is written the way it is: the *arithmetic* — which paddings apply, what a missing
/// subtitle costs, where the line limit bites — is what breaks, and it should be checkable without
/// asking the system what SF Pro does today. `.system` is the real answer and `.fixed` is the one
/// tests use to pin the sums.
public struct ActivityTextMeasure: Sendable {

    /// One line's height at a style.
    public var lineHeight: @Sendable (ActivityTextStyle) -> CGFloat

    /// How tall `text` is at `style`, wrapped into `width` points and capped at `lineLimit` lines.
    public var height: @Sendable (_ text: String, _ style: ActivityTextStyle, _ width: CGFloat, _ lineLimit: Int) -> CGFloat

    public init(
        lineHeight: @escaping @Sendable (ActivityTextStyle) -> CGFloat,
        height: @escaping @Sendable (String, ActivityTextStyle, CGFloat, Int) -> CGFloat
    ) {
        self.lineHeight = lineHeight
        self.height = height
    }

    /// SF Pro, asked directly.
    ///
    /// Measured in whole lines rather than by taking the layout rect's height, and that is not
    /// rounding for its own sake: SwiftUI's `lineLimit` truncates to a whole number of lines, so a
    /// rect 2.4 lines tall would reserve a strip of island for the four tenths of a line that will
    /// never be drawn — and §6.6 wants whole points anyway.
    public static let system = ActivityTextMeasure(
        lineHeight: { style in ceil(Self.lineHeight(of: Self.font(for: style))) },
        height: { text, style, width, lineLimit in
            guard !text.isEmpty, width > 0, lineLimit > 0 else { return 0 }
            let font = Self.font(for: style)
            let line = ceil(Self.lineHeight(of: font))
            guard line > 0 else { return 0 }
            let bounds = NSAttributedString(string: text, attributes: [.font: font])
                .boundingRect(
                    with: CGSize(width: width, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]
                )
            let lines = max(1, min(lineLimit, Int((bounds.height / line).rounded(.up))))
            return line * CGFloat(lines)
        }
    )

    /// A measurer with no fonts in it: every line is `lineHeight` tall and a line holds
    /// `charactersPerLine` characters. For tests of the arithmetic around the text, which is the
    /// part that has decisions in it.
    public static func fixed(lineHeight: CGFloat, charactersPerLine: Int = 30) -> Self {
        Self(
            lineHeight: { _ in lineHeight },
            height: { text, _, _, lineLimit in
                guard !text.isEmpty, lineLimit > 0 else { return 0 }
                let wrapped = Int((Double(text.count) / Double(charactersPerLine)).rounded(.up))
                return lineHeight * CGFloat(max(1, min(lineLimit, wrapped)))
            }
        )
    }

    private static func font(for style: ActivityTextStyle) -> NSFont {
        let weight: NSFont.Weight = switch style.weight {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        }
        return NSFont.systemFont(ofSize: style.size, weight: weight)
    }

    private static func lineHeight(of font: NSFont) -> CGFloat {
        font.ascender - font.descender + font.leading
    }
}

/// How tall the island opens for what is on stage.
///
/// ## Why this exists
///
/// `IslandLayout.expandedBodySize` was one constant for every activity, which is right for exactly
/// two of them and wrong for the rest. The Now Playing player and the shelf draw their own body
/// against a known rectangle — a 56pt cover, a scrub row, a transport row; six tiles — so their
/// height is a property of the layout rather than of the content in it. Everything else is a symbol,
/// a line of title and some amount of message, and giving all of them the player's 176pt produces
/// two failures at once: a wake greeting hanging four lines deep with one line in it, and a
/// notification whose message is cut off at two lines inside an island with room to spare.
///
/// ## Why a settled constant is still a constant
///
/// The rule this has to respect is the one `IslandLayout` writes down: `islandPath` must track a
/// *settled* shape, because hit testing is exact and a body that resizes while it is being read
/// moves the clickable region under the pointer. That rule is about the height changing **while an
/// activity is on stage**, not about two activities having different heights. A notification's text
/// is fixed at the moment it is published and never changes; the height is computed once, on the
/// same change that puts it on stage, and travels through the same widen-then-tighten protocol a
/// click does (`AppDelegate.transition`). Now Playing, the one kind whose content genuinely does
/// change several times a second, is also the one kind that keeps a constant height.
public enum ActivityExpandedHeight {

    // MARK: - The numbers `ActivityContentView.expanded` lays out with
    //
    // Duplicated from the view deliberately, and pinned by `ActivityExpandedHeightTests` against the
    // view's own constants — the height and the layout are the same arithmetic asked in two
    // directions, and the failure when they drift is an island a few points too short for its last
    // line, which reads as a clipping bug rather than as a sizing one.

    public static let horizontalPadding: CGFloat = 18

    /// Air above and below the content block. The view centers inside whatever it is given, so this
    /// is the only place it exists.
    public static let verticalPadding: CGFloat = 16

    public static let symbolWellSide: CGFloat = 44

    public static let symbolSpacing: CGFloat = 14

    public static let titleSubtitleSpacing: CGFloat = 3

    public static let valueTopPadding: CGFloat = 4

    /// The level capsule, at `ActivityValueView`'s expanded size.
    public static let levelHeight: CGFloat = 6

    /// How much of a message the open island will show.
    ///
    /// Five, not two — "open it and read the notification" is the whole point of opening it, and a
    /// message cut off mid-sentence in an island with 60pt of unused height is worse than not
    /// opening at all. Not unbounded, because the island is not a window: past five lines it stops
    /// reading as the notch having opened and starts reading as a panel that happens to be attached
    /// to one, and `IslandLayout.maxExpandedBodySize` would clamp it anyway.
    public static let messageLineLimit = 5

    static let titleStyle = ActivityTextStyle(size: 15, weight: .semibold)
    static let subtitleStyle = ActivityTextStyle(size: 12, weight: .regular)
    static let numeralsStyle = ActivityTextStyle(size: 26, weight: .semibold)

    // MARK: - Answers

    /// How much drawable height one expanded content needs — the block plus the air around it, and
    /// **not** the cutout.
    ///
    /// The cutout is the screen's business rather than the content's, and it is added at the far end
    /// by `IslandLayout.expandedHeight(contentHeight:cutoutHeight:)`. That split is what lets one
    /// number be right on a MacBook and on a Studio Display at the same time: the same greeting
    /// needs the same room, and only one of those displays has a hole above it.
    ///
    /// - Parameter width: the open island's width — fixed, and the reason only the height varies. A
    ///   width that followed the title would move the island's edges between one notification and
    ///   the next, and the two flanks either side of the cutout with them.
    public static func drawableHeight(
        for content: ActivityContent,
        width: CGFloat = IslandLayout.expandedBodySize.width,
        measure: ActivityTextMeasure = .system
    ) -> CGFloat {
        blockHeight(for: content, width: width, measure: measure) + 2 * verticalPadding
    }

    /// What to open to for what is on stage, or `nil` for "the default" — which is what
    /// `IslandLayout.expandedHeight(contentHeight:cutoutHeight:)` and
    /// `IslandController.expandedContentHeight` both take.
    ///
    /// `nil` rather than a number so that the two kinds which size themselves say so, instead of
    /// arriving at the default by a different route and leaving nobody able to tell a deliberate
    /// default from a coincidence.
    public static func contentHeight(
        for presentations: ActivityPresentations?,
        kind: ActivityKind?,
        width: CGFloat = IslandLayout.expandedBodySize.width,
        measure: ActivityTextMeasure = .system
    ) -> CGFloat? {
        guard let presentations, let kind, kind.sizesOpenIslandToContent else { return nil }
        let content = presentations.expanded
        guard !content.isEmpty else { return nil }
        return drawableHeight(for: content, width: width, measure: measure)
    }

    // MARK: - The content block

    /// The drawable block below the cutout, without its padding: the taller of the symbol well and
    /// the text column beside it.
    static func blockHeight(
        for content: ActivityContent,
        width: CGFloat,
        measure: ActivityTextMeasure
    ) -> CGFloat {
        let hasSymbol = content.symbol != nil
        var textWidth = width - 2 * horizontalPadding
        if hasSymbol { textWidth -= symbolWellSide + symbolSpacing }

        // A time-dependent value is the headline and sits at the trailing edge, taking width from
        // the text column rather than height from it — the countdown and the title are on the same
        // row. Its own line height still has to be cleared, which is what the `max` at the end is
        // for.
        var trailing: CGFloat = 0
        if let value = content.value, value.isTimeDependent {
            let numerals = measure.lineHeight(numeralsStyle)
            textWidth -= numerals * 2.6
            trailing = numerals
        }
        textWidth = max(0, textWidth)

        var text: CGFloat = 0
        if let title = content.title, !title.isEmpty {
            text += measure.height(title, titleStyle, textWidth, 1)
        }
        if let subtitle = content.subtitle, !subtitle.isEmpty {
            if text > 0 { text += titleSubtitleSpacing }
            text += measure.height(subtitle, subtitleStyle, textWidth, messageLineLimit)
        }
        if let value = content.value, !value.isTimeDependent {
            if text > 0 { text += valueTopPadding }
            text += value.normalized == nil ? measure.lineHeight(subtitleStyle) : levelHeight
        }

        return max(hasSymbol ? symbolWellSide : 0, max(text, trailing))
    }
}

extension ActivityKind {

    /// Whether the open island takes its height from this kind's content.
    ///
    /// False for the kinds that draw their own body against a rectangle they already agreed on
    /// — see `NowPlayingExpandedLayout` and `ShelfLayout`, both of which anchor rows to the bottom
    /// of a body whose height they treat as given. Sizing those to their text would move a transport
    /// row between tracks, which is the thing `NowPlayingExpandedLayout` exists to prevent.
    var sizesOpenIslandToContent: Bool {
        switch self {
        // A connected device joins the two for a related reason rather than the same one: it does
        // draw title and subtitle, but it draws its battery *beside* them rather than below, and
        // the generic measurement has no way to know that — it sees a `.fraction` that is not time
        // dependent and adds a level row's height for a bar this kind never draws. The island would
        // open a row taller than its content for a slot that is one row of symbol-well height.
        case .nowPlaying, .shelf, .deviceConnected: false
        // Three more that own their body. Each draws a *layout* — a month grid, a caller's photo
        // above two buttons, a scrolling record of what was converted — and the generic measurement
        // can only see the title and subtitle in the content, so it would size the island to a
        // caption and clip the thing the caption is about. They arrive here with the same obligation
        // `NowPlayingExpandedLayout` carries: agree a height and hold it, because
        // `IslandController.expandedContentHeight` is read *before* the transition.
        case .glance, .call, .fileAction: false
        // Everything else is a title, a subtitle and at most a value — which is exactly what the
        // generic measurement was written for.
        case .systemHUD, .welcomeBack, .timer: true
        case .calendarAlert, .meeting, .power, .focusChanged, .screenSharing: true
        }
    }
}
