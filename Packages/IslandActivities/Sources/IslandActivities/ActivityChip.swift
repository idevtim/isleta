import Foundation

/// One activity, reduced to what fits in a switcher chip.
///
/// A glyph and — when the activity has one — a short value. Deliberately **no title**: a chip is
/// 30pt of island saying *which* activity this is, not what it says. The title is what the stage is
/// for, and a chip carrying one would either truncate every title to three characters or make the
/// row wider than the island.
///
/// A value type rather than a view or an activity reference, for the reason `ActivityContent` is
/// one: the row is drawn from data, so what the row shows can be tested without a renderer.
public struct ActivityChip: Equatable, Sendable, Identifiable {

    public let id: ActivityID

    public let kind: ActivityKind

    /// The chip's glyph. Nil is possible and drawn as a dot — an activity with no symbol anywhere is
    /// still reachable, because a chip the user cannot see is an activity they cannot get back to.
    public let symbol: String?

    /// A countdown, a count — something a few glyphs wide. Nil for most kinds.
    public let value: ActivityValue?

    public let accessibilityLabel: String?

    /// Whether this is the activity currently on the stage. The row marks it rather than removing
    /// it: a roster that hid the current entry would renumber itself on every selection, and the
    /// user would lose track of where they were.
    public let isOnStage: Bool

    public init(
        id: ActivityID,
        kind: ActivityKind,
        symbol: String?,
        value: ActivityValue? = nil,
        accessibilityLabel: String? = nil,
        isOnStage: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.symbol = symbol
        self.value = value
        self.accessibilityLabel = accessibilityLabel
        self.isOnStage = isOnStage
    }
}

extension IslandActivity {

    /// This activity as a chip.
    ///
    /// The glyph comes from the **kind**, not from the compact badge, and that is the point: a chip
    /// is a way back to something rather than a readout of it. See `ActivityKind.chipSymbol`.
    public func chip(isOnStage: Bool = false) -> ActivityChip {
        let compact = presentations.compact
        return ActivityChip(
            id: id,
            kind: kind,
            symbol: kind.chipSymbol,
            value: compact.value,
            accessibilityLabel: compact.accessibilityLabel ?? compact.title,
            isOnStage: isOnStage
        )
    }
}
