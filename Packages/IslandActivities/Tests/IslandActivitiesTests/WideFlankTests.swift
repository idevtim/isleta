import Foundation
import IslandKit
import Testing

@testable import IslandActivities

/// The island widening far enough for a HUD to say which key was pressed.
///
/// Two halves, and they fail in different places if they come apart: `ActivityKind` decides *who*
/// gets a wide island, `ActivityStage.flanks` decides *when* — and the second is asked of a pair,
/// where the two slivers can belong to different activities.
@Suite("Wide flanks")
struct WideFlankTests {

    private func hud(_ which: SystemHUD = .brightness, level: Double = 0.5) -> BuiltInActivity {
        BuiltInActivity.systemHUD(which, level: level)
    }

    private func music() -> BuiltInActivity {
        BuiltInActivity.nowPlaying(title: "Kind of Blue", artist: "Miles Davis")
    }

    /// Built here rather than through `BuiltInActivity.power(_:state:)`, which lives in IslandSources
    /// and cannot be seen from this package — the layering runs the other way. What matters to these
    /// tests is the shape of the presentations, which is the shape that factory produces: a glyph
    /// and a word in one sliver, a level in the other.
    private func power() -> BuiltInActivity {
        BuiltInActivity(
            kind: .power,
            presentations: ActivityPresentations(
                leading: ActivityContent(symbol: "battery.100percent.bolt", title: "Charging"),
                trailing: ActivityContent(value: .fraction(0.62)),
                compact: ActivityContent(symbol: "battery.100percent.bolt", title: "Charging"),
                expanded: ActivityContent(symbol: "battery.100percent.bolt", title: "Charging")
            )
        )
    }

    /// The word is what the widening is *for*, so it has to be in the sliver rather than only in the
    /// open island's header — which is where every other kind's title lives.
    @Test("a HUD spells itself in the leading sliver")
    func hudNamesItselfInTheFlank() {
        let volume = hud(.volume, level: 0.4)
        #expect(volume.presentations.leading.title == SystemHUD.volume.label)
        #expect(volume.presentations.leading.symbol == SystemHUD.volume.symbol)
        // The other sliver stays the bar alone. A word each side would be the island saying the same
        // thing twice, 192pt apart.
        #expect(volume.presentations.trailing.title == nil)
        #expect(volume.presentations.trailing.value != nil)
    }

    /// Volume and brightness draw the same picture at a glance, and the label is the whole of the
    /// difference — so it must not be the *spoken* label, which says "brightness" twice.
    @Test("the drawn label is a noun and the spoken one is a phrase")
    func labelIsNotTheAccessibilityLabel() {
        #expect(SystemHUD.brightness.label != SystemHUD.brightness.accessibilityLabel)
        #expect(SystemHUD.volume.label != SystemHUD.brightness.label)
        // VoiceOver still gets the phrase, from the sliver as well as from the open island.
        #expect(
            BuiltInActivity.systemHUD(.brightness, level: 0.5).presentations.leading.accessibilityLabel
                == SystemHUD.brightness.accessibilityLabel
        )
    }

    /// **Two kinds, and the bar for a third is high** — see the table's own note. This is what stops
    /// something *ambient* asking for room and leaving the island permanently at its widest, which
    /// is a black bar with a notch in it rather than a notch.
    @Test("nothing that outlives a moment asks for a wide island")
    func onlyTwoKindsNameThemselves() {
        #expect(ActivityKind.systemHUD.flankSpan == .wide)
        // Power's phrases are longer than a HUD's nouns, so it gets the span sized to them rather
        // than growing the HUD's — see `IslandLayout.widerFlankedWidthGrowth`.
        #expect(ActivityKind.power.flankSpan == .wider)
        for kind in ActivityKind.allCases where kind != .systemHUD && kind != .power {
            #expect(kind.flankSpan == .standard, "\(kind) should not widen the island")
        }
        for kind in ActivityKind.allCases where kind.flankSpan > .standard {
            #expect(kind.defaultExpiry != .never, "\(kind) would hold the island at its widest")
            #expect(kind.defaultPriority != .ambient, "\(kind) is a condition, not a moment")
        }
    }

    /// The span is the island's whole flank axis, and an empty stage is the bare cutout.
    @Test("an empty stage asks for no flanks at all")
    func emptyStageIsUnflanked() {
        let blank = BuiltInActivity(kind: .systemHUD, presentations: .empty)
        let stage = ActivityStage(primary: blank, primaryFlank: .leading)
        #expect(stage.flanks == .none, "a kind that would spell itself has nothing to spell")
    }

    @Test("a glyph in a sliver asks for the standard flanks and a word asks for the wide ones")
    func spanFollowsWhatIsInTheSliver() {
        #expect(ActivityStage(primary: music(), primaryFlank: .leading).flanks == .standard)
        #expect(ActivityStage(primary: hud(), primaryFlank: .leading).flanks == .wide)
        #expect(ActivityStage(primary: power(), primaryFlank: .leading).flanks == .wider)
    }

    /// **The reason this lives on the stage rather than on the primary.** The two slivers can belong
    /// to different activities and the island is one shape: asked of the primary alone, a HUD that
    /// arrived as the companion would be drawn with its word in a sliver sized for a glyph.
    @Test("either sliver's owner can widen the island", arguments: [true, false])
    func eitherHalfOfThePairWidensIt(hudIsPrimary: Bool) {
        // The HUD holds the **leading** sliver either way, which is where its word is: as the
        // primary it takes the flank its kind asked for, and as the companion it takes the one the
        // primary did not. So the island is wide whichever half of the pair it arrived as, which is
        // the claim — asked of the primary alone, the second of these would size the HUD's word to
        // a sliver built for a glyph.
        let stage = hudIsPrimary
            ? ActivityStage(primary: hud(), companion: music(), primaryFlank: .leading)
            : ActivityStage(primary: music(), companion: hud(), primaryFlank: .trailing)
        #expect(stage.content(on: .leading).title == SystemHUD.brightness.label)
        #expect(stage.flanks == .wide)
    }

    /// **The other half of that rule, and power is what needs it.** A kind spells itself in one of
    /// its two contents, and a pair hands it one sliver that is not always that one: power behind
    /// something that outranks it takes the flank the primary did not, and what it draws there is
    /// the level. Widening by 274pt for a bar is the island growing to its widest to say nothing, so
    /// the span follows the word rather than the kind alone.
    @Test("a sliver drawing no word asks for no room for one")
    func aBarDoesNotWidenTheIsland() {
        let paired = ActivityStage(primary: music(), companion: power(), primaryFlank: .leading)
        #expect(paired.content(on: .trailing).title == nil, "power's trailing sliver is the level")
        #expect(paired.flanks == .standard)

        // Alone it owns both slivers, and as the primary of a pair it keeps the one with the word
        // in it — `flankAffinity` is `.leading` for exactly that reason.
        #expect(ActivityStage(primary: power(), primaryFlank: .leading).flanks == .wider)
        #expect(ActivityKind.power.flankAffinity == .leading)
        #expect(
            ActivityStage(primary: power(), companion: music(), primaryFlank: .leading).flanks
                == .wider
        )
    }

    /// The four spans are ordered, and the ordering is what `IslandLayout.metrics` is monotone in —
    /// which is what makes `IslandShapeMetrics.union` of any two forms contain everything between.
    @Test("the spans are ordered from the bare cutout outward")
    func spansAreOrdered() {
        #expect(IslandFlanks.allCases == [.none, .standard, .wide, .wider])
        #expect(IslandFlanks.allCases == IslandFlanks.allCases.sorted())
    }
}
