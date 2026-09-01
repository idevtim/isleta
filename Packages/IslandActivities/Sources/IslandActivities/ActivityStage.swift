import Foundation
import IslandKit

/// Which of the two lit slivers beside the cutout an activity occupies.
///
/// Two cases and no `.none`, because "not on a flank" is the absence of an `ActivityFlank`, not a
/// third value of one. A `.none` case would have to be handled at every site that maps a flank to a
/// rectangle, and every one of those handlers would be dead code guarding against a state the type
/// should not be able to express.
///
/// Deliberately *not* `ActivitySlot`, which lives in IslandUI and has four cases. A flank is a
/// position on the resting island; a slot is one of the four ways an activity can be drawn. They
/// coincide for two of the four, and IslandActivities cannot see IslandUI in any case — the layering
/// runs the other way.
///
/// `String`-backed because a flank was persisted by name for as long as sides were adjustable
/// (`IslandSides`, through 2.0). Nothing stores one now, and the raw values stay because
/// `ActivityKind.flankAffinity` reads better against a named case than against an ordinal.
public enum ActivityFlank: String, Hashable, Sendable, CaseIterable {

    case leading

    case trailing

    /// The other one. There are only two, which is what makes the companion rule a single line
    /// rather than a table: whichever flank the primary took, the companion takes this.
    public var opposite: ActivityFlank {
        switch self {
        case .leading: .trailing
        case .trailing: .leading
        }
    }
}

/// What the island is showing at rest: one activity, or two sharing the flanks.
///
/// ## Why the stage is a pair
///
/// A single stage forces a choice nobody wants to make. A running timer that outranks Now Playing
/// takes the music off the island for the whole of its run; one that does not is invisible for the
/// whole of its run. No priority rule fixes that, because the user wants **both** — and the resting
/// island already has two places to put them.
///
/// So `primary` keeps everything it had — the body, and the flank its kind prefers — and `companion`
/// gets the other flank and nothing else.
///
/// ## Derived, never stored
///
/// Built on demand from `ActivityStack`'s order, for the reason that type's own documentation opens
/// with: a stored pair is a second source of truth that agrees with the order until an activity
/// expires while queued, and then quietly does not.
///
/// ## The unpaired case is the old behavior, exactly
///
/// With no companion the primary owns **both** flanks, which is what every build before the pair
/// did. That is not a special case bolted on for compatibility; it is what `content(on:)` computes
/// when there is nobody to give the other flank to. It matters because it is the common case — most
/// of the time there is one thing on the island — and a pair that quietly narrowed the single-activity
/// island to one sliver would be a regression in the state users spend the most time in.
public struct ActivityStage: Sendable {

    /// The head of the order. Owns the body in every presentation, and one flank at rest.
    public let primary: any IslandActivity

    /// The highest-ranked other activity willing to share, or nil — which is the ordinary state.
    public let companion: (any IslandActivity)?

    /// Which sliver `primary` took — its kind's own preference; see `ActivityKind.flankAffinity`.
    public let primaryFlank: ActivityFlank

    public init(
        primary: any IslandActivity,
        companion: (any IslandActivity)? = nil,
        primaryFlank: ActivityFlank
    ) {
        self.primary = primary
        self.companion = companion
        self.primaryFlank = primaryFlank
    }

    /// Where the companion sits. Always the other flank — see `ActivityFlank.opposite`.
    ///
    /// This is why the affinity table produces "music left, timer right" whichever of the two is on
    /// the body: the primary takes the side its kind asked for, and the only side left is the one
    /// the companion's kind would have asked for anyway.
    public var companionFlank: ActivityFlank { primaryFlank.opposite }

    public var isPaired: Bool { companion != nil }

    /// Who owns a flank. Nil only when the companion flank is unclaimed *and* there is a companion
    /// slot in principle — which cannot happen, so this is total in practice; it returns the primary
    /// for its own flank and for the other one when unpaired.
    public func activity(on flank: ActivityFlank) -> any IslandActivity {
        flank == companionFlank ? (companion ?? primary) : primary
    }

    /// What to draw in a flank.
    ///
    /// Reads from the owning activity's presentation for **that** flank, not from a single
    /// activity's pair of them. A companion assigned the trailing sliver draws its own `trailing`
    /// content, which is the content its kind was written to put there.
    ///
    /// A glyph identifying the activity on one side of the cutout, reading into a value on the
    /// other, is the arrangement every built-in is drawn for, and it is fixed: a sliver draws the
    /// presentation its own name says it draws. It was briefly a setting (`IslandSides.mirrored`,
    /// through 2.0) and swapping the two reads as a rendering fault rather than as a preference —
    /// the glyph is what tells a user *which* activity the value belongs to, and putting it on the
    /// outside edge is the one arrangement in which the pair does not read as two unrelated things.
    public func content(on flank: ActivityFlank) -> ActivityContent {
        activity(on: flank).presentations.content(for: flank)
    }

    /// Whether either sliver has anything in it — the question that decides whether the resting
    /// island is wider than the bare cutout.
    ///
    /// Asked of the **pair**, which is the whole point of it living here. Asked of the primary alone
    /// — which is what `IslandScreenModel.hasFlankContent(in:)` does today, because until now there
    /// was only ever one activity to ask — an island whose primary has empty flanks narrows back to
    /// the cutout while the companion still has something to say, and the companion is then drawn
    /// into a sliver that no longer exists.
    public var hasFlankContent: Bool {
        !content(on: .leading).isEmpty || !content(on: .trailing).isEmpty
    }

    /// How wide the slivers have to be for what is in them — the island's whole flank axis, answered
    /// in the one place that can see both sides at once.
    ///
    /// **Asked per flank and of the owning activity's kind**, not of the primary. The two slivers can
    /// belong to different activities, and the island is one shape: a HUD in one sliver widens it
    /// whether or not the thing on the body has anything to spell. Asked of the primary alone, a HUD
    /// that arrived as the companion would be drawn with its word in a sliver sized for a glyph.
    ///
    /// A sliver with nothing in it asks for nothing, which is why the emptiness test comes first —
    /// otherwise a kind that names itself would widen the island for a flank it is not using.
    ///
    /// **And a sliver drawing no word asks for no room for one**, which is the same rule one step
    /// finer and is what `ActivityKind.power` needs. A kind that spells itself does so in *one* of
    /// its two contents — the glyph-and-word one — and a pair gives it only one sliver, which is not
    /// always that one: power behind a ringing call takes the flank the call did not, and what it
    /// draws there is the level. Keyed on the kind alone, that would widen the island by 274pt for a
    /// bar. The word is `title` on the content of the flank that has it, so that is what is asked.
    public var flanks: IslandFlanks {
        var span = IslandFlanks.none
        for flank in ActivityFlank.allCases where !content(on: flank).isEmpty {
            let spells = content(on: flank).title != nil
            span = max(span, spells ? activity(on: flank).kind.flankSpan : .standard)
        }
        return span
    }
}
