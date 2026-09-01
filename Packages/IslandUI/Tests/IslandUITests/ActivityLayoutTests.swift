import CoreGraphics
import Foundation
import IslandActivities
import IslandKit
import Testing

@testable import IslandUI

/// Captured from a 14" MacBook Pro: the cutout the geometry actually has to work around.
private let cutout = CGSize(width: 185, height: 32)

private let notchedScreen = IslandScreen(
    id: 1,
    name: "Built-in",
    frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
    backingScaleFactor: 2,
    notch: NotchGeometry(
        kind: .hardware,
        rect: CGRect(x: 771.5, y: 1085, width: cutout.width, height: cutout.height)
    )
)

private func metrics(_ form: IslandForm) -> IslandShapeMetrics {
    IslandLayout.metrics(for: form, on: notchedScreen)
}

private func layout(_ form: IslandForm, cutoutSize: CGSize = cutout) -> ActivitySlotLayout {
    ActivitySlotLayout.resolve(bodySize: metrics(form).bodySize, cutoutSize: cutoutSize)
}

@Suite("Activity slot layout")
struct ActivitySlotLayoutTests {

    /// With nothing on stage the resting island *is* the cutout, so there is nowhere to put a
    /// pixel. This is the same fact as "the island is invisible at rest", stated from the content's
    /// side — and it is why an activity with flank content puts the island in a flanked form
    /// instead, which is the next test but one.
    @Test("at rest on a hardware notch nothing can be drawn at all")
    func restIsBlind() {
        let resolved = layout(.rest)
        #expect(resolved.isBlind)
        #expect(resolved.leading == nil)
        #expect(resolved.trailing == nil)
        #expect(resolved.body == nil)
    }

    /// Peek adds 6pt of flank and 8pt below the cutout. Both are real lit pixels and neither is
    /// anything like enough for a glyph, so an *unflanked* peek stays what it is meant to be — an
    /// invitation to click, not the click's result. Growing peek to fit content instead is the
    /// alternative that was rejected: it would answer the invitation before the user accepted it,
    /// and make the island's size depend on the pointer rather than on what is on stage.
    @Test("peek grows the island but not enough to draw in")
    func peekIsBlind() {
        let resolved = layout(.peek)
        #expect(resolved.cutout?.minX == IslandLayout.peekWidthGrowth / 2)
        #expect(resolved.isBlind)
    }

    /// The flanks are the whole point: two slivers of lit pixels either side of a hole, which is
    /// what `leading` and `trailing` mean on a Mac. They must touch the cutout exactly — a gap
    /// would read as the glyphs being afraid of the notch, an overlap would put them in the hole.
    @Test("the open island has a sliver either side of the cutout and a body below it")
    func expandedAffordsEverything() {
        let resolved = layout(.expanded)
        let expectedFlank = (IslandLayout.expandedBodySize.width - cutout.width) / 2

        #expect(resolved.affordsFlanks)
        #expect(resolved.affordsBody)
        #expect(resolved.leading == CGRect(x: 0, y: 0, width: expectedFlank, height: cutout.height))
        #expect(resolved.trailing == CGRect(
            x: IslandLayout.expandedBodySize.width - expectedFlank,
            y: 0,
            width: expectedFlank,
            height: cutout.height
        ))
        #expect(resolved.leading?.maxX == resolved.cutout?.minX)
        #expect(resolved.trailing?.minX == resolved.cutout?.maxX)
        #expect(resolved.body == CGRect(
            x: 0,
            y: cutout.height,
            width: IslandLayout.expandedBodySize.width,
            height: IslandLayout.expandedBodySize.height - cutout.height
        ))
    }

    /// The island never paints outside its own body (`IslandShapeMetrics.bodySize`), and content is
    /// masked to the island outline. A slot rect that escaped the body would be silently clipped
    /// rather than visibly wrong, which is the kind of bug that survives a milestone.
    @Test("no slot ever leaves the body, in any form")
    func slotsStayInsideTheBody() {
        for form in IslandForm.allCases {
            let resolved = layout(form)
            let body = CGRect(origin: .zero, size: resolved.bodySize)
            for slot in ActivitySlot.allCases {
                guard let frame = resolved.frame(for: slot) else { continue }
                #expect(body.contains(frame), "\(slot) escaped the body at \(form)")
            }
        }
    }

    /// The cutout is centerd on the body because the panel is centerd on the notch and the body is
    /// centerd in the panel. Stated as a test because two independent centrings agreeing is exactly
    /// the sort of thing that stops being true when one of them gains a clamp.
    @Test("the cutout is centerd on the body")
    func cutoutIsCenterd() {
        let resolved = layout(.expanded)
        #expect(resolved.cutout?.midX == resolved.bodySize.width / 2)
        #expect(resolved.cutout?.minY == 0)
    }

    /// A synthesized island has no hole in it. Treating its synthesized 210x32 rect as a cutout
    /// would carve a dead zone out of a display that has none.
    @Test("a synthesized island is drawable end to end and has no flanks")
    func synthesizedHasNoCutout() {
        let synthesized = NotchGeometry(
            kind: .synthesized,
            rect: CGRect(x: 0, y: 0, width: 210, height: 32)
        )
        #expect(ActivitySlotLayout.cutoutSize(for: synthesized) == .zero)

        let resolved = ActivitySlotLayout.resolve(bodySize: CGSize(width: 210, height: 32), cutoutSize: .zero)
        #expect(resolved.cutout == nil)
        #expect(!resolved.affordsFlanks)
        #expect(resolved.body == CGRect(x: 0, y: 0, width: 210, height: 32))
    }

    /// A cutout wider or taller than the body is not reachable through `IslandLayout`, but a
    /// negative flank width would invert the rects rather than fail, so it is clamped.
    @Test("a cutout larger than the body clamps instead of inverting")
    func oversizedCutoutClamps() {
        let resolved = ActivitySlotLayout.resolve(
            bodySize: CGSize(width: 100, height: 20),
            cutoutSize: CGSize(width: 400, height: 90)
        )
        #expect(resolved.cutout == CGRect(x: 0, y: 0, width: 100, height: 20))
        #expect(resolved.isBlind)
    }
}

/// The two halves of the flanked decision, checked against each other.
///
/// `IslandLayout.flankedWidthGrowth` (IslandKit) decides how wide the island gets; the floor it has
/// to clear, `ActivitySlotLayout.minimumFlankWidth`, lives here because only IslandUI knows what a
/// glyph costs. Neither package can see both numbers, so this is the only place they can be
/// compared — and a change to either one that quietly re-blinded the island would otherwise pass
/// both suites.
@Suite("Flanked layout")
struct FlankedLayoutTests {

    @Test("the flanked resting island affords both flanks and nothing below the cutout")
    func flankedRest() {
        let resolved = layout(.flankedRest)

        #expect(!resolved.isBlind)
        #expect(resolved.affordsFlanks)
        #expect(resolved.leading?.width == IslandLayout.flankedFlankWidth)
        #expect(resolved.trailing?.width == IslandLayout.flankedFlankWidth)
        #expect(resolved.leading?.maxX == resolved.cutout?.minX)
        #expect(resolved.trailing?.minX == resolved.cutout?.maxX)

        // No body region: the flanks are beside the cutout, and a strip of text hanging under the
        // notch at rest would be a panel rather than a notch.
        #expect(!resolved.affordsBody)
        #expect(resolved.bodySize.height == cutout.height)
    }

    /// The number the whole choice of 80pt turns on, with the margin stated rather than implied.
    @Test("the flank the island buys clears the width a glyph needs")
    func flankClearsTheMinimum() {
        #expect(IslandLayout.flankedFlankWidth >= ActivitySlotLayout.minimumFlankWidth)
        // Not sitting on the floor: a 13pt SF Symbol runs ~15-18pt wide depending on the glyph, and
        // the flank insets 10pt at each end, so the floor itself only fits the narrowest of them.
        #expect(IslandLayout.flankedFlankWidth - ActivitySlotLayout.minimumFlankWidth >= 5)
    }

    /// Peeking a flanked island must not lose the flanks it grew for — peek only ever adds.
    @Test("the flanked peek keeps both flanks and still affords no body")
    func flankedPeek() {
        let resolved = layout(.flankedPeek)

        #expect(resolved.affordsFlanks)
        #expect(resolved.leading?.width == IslandLayout.flankedFlankWidth + IslandLayout.peekWidthGrowth / 2)
        #expect(!resolved.affordsBody)
        #expect(resolved.bodySize.height < cutout.height + ActivitySlotLayout.minimumBodyHeight)
    }

    /// The flanked island shows the two slivers and no badge. `compact` is the badge for an island
    /// with nothing to flank; drawing it *as well* would put a second copy of the same glyph under
    /// the cutout, and there is no room for it anyway.
    @Test("a flanked island draws its flanks and no compact badge")
    func flankedVisibleSlots() {
        let playing = BuiltInActivity.nowPlaying(title: "Avril 14th", artist: "Aphex Twin").presentations
        #expect(layout(.flankedRest).visibleSlots(for: .rest, in: playing) == [.leading, .trailing])
        #expect(layout(.flankedPeek).visibleSlots(for: .peek, in: playing) == [.leading, .trailing])
    }

    /// §9: a countdown in a flank *is* on screen, so it does start a display link — where the same
    /// countdown on an unflanked resting island does not, because nobody can see it.
    @Test("a countdown in a flank starts a display link and one nobody can see does not")
    func clockFollowsVisibility() {
        let value = ActivityValue.countdown(until: Date().addingTimeInterval(300))
        let ticking = ActivityPresentations(
            leading: ActivityContent(symbol: "timer"),
            trailing: ActivityContent(value: value)
        )
        #expect(layout(.flankedRest).needsClock(for: .rest, in: ActivityStage.lone(ticking)))
        #expect(!layout(.rest).needsClock(for: .rest, in: ActivityStage.lone(ticking)))
    }

    /// A synthesized island has no hole, so there is nothing to flank and the flanked forms would
    /// only make a wider badge. The island is drawable end to end there already.
    @Test("a synthesized island has no flanks to grow for")
    func synthesizedIsNotFlanked() {
        let resolved = layout(.flankedRest, cutoutSize: .zero)
        #expect(!resolved.affordsFlanks)
        #expect(resolved.affordsBody)
    }
}

@Suite("Activity slots")
struct ActivityVisibleSlotTests {

    private let nowPlaying = BuiltInActivity.nowPlaying(title: "Avril 14th", artist: "Aphex Twin").presentations

    /// The open island draws the body and *only* the body.
    ///
    /// It used to draw the flanks as well. That put the cover and the equaliser on screen twice, 40pt
    /// apart — once in the slivers beside the cutout and again in the body's own header — which
    /// reads as a rendering fault rather than as emphasis. The flanks are what the island says when
    /// it has no room to say more; open, it has the room.
    @Test("the open island draws its body and stops repeating it in the flanks")
    func expanded() {
        #expect(layout(.expanded).visibleSlots(for: .expanded, in: nowPlaying) == [.expanded])
    }

    /// The same, for a surface that draws its open body with a layer of its own.
    @Test("an open island drops its flanks even when its expanded content is empty")
    func expandedWithABespokeBody() {
        // The rule used to be asked of the *body slot* — `body != .expanded` — and `bodySlot`
        // answers nil when `presentations.expanded` is empty. That is the case for every surface
        // that draws its open body with a layer of its own rather than through `ActivityContent`:
        // the glance, Now Playing's expanded view, the shelf, the switcher, the drop history. For
        // all of them the rule never fired and the open island kept its slivers, so the glance drew
        // "☀ 84°" in its header and again in the sliver a few points above it.
        let bespoke = ActivityPresentations(
            leading: ActivityContent(symbol: "sun.max.fill"),
            trailing: ActivityContent(title: "84°"),
            compact: ActivityContent(symbol: "calendar", title: "Nothing next"),
            expanded: .empty
        )
        #expect(layout(.expanded).visibleSlots(for: .expanded, in: bespoke).isEmpty,
                "an open island repeats nothing in the slivers, whoever draws its body")
        // And collapsed it still carries both, which is the whole point of having them.
        #expect(layout(.flankedRest).visibleSlots(for: .rest, in: bespoke) == [.leading, .trailing])
    }

    /// Collapsed, the flanks *are* the whole presentation and still carry it.    /// Collapsed, the flanks *are* the whole presentation and still carry it.
    @Test("a flank carrying a number keeps the room to draw it")
    func aNumberGetsItsPaddingBack() {
        // The temperature showed as "…" at rest. A flank is 40pt; at 10pt each side that leaves
        // 20pt, and "84°" needs about 26. The rule only gave the room back when *both* symbol and
        // title were absent, so a bare `value` qualified and a `title` did not — and the glance's
        // trailing sliver is a title.
        let degrees = ActivityContent(title: "84°")
        let glyph = ActivityContent(symbol: "sun.max.fill")
        let both = ActivityContent(symbol: "sun.max.fill", title: "84°")

        #expect(ActivityContentView.flankPadding(for: degrees) == 4)
        #expect(ActivityContentView.flankPadding(for: glyph) == 10,
                "a glyph still keeps its margin off the cutout's edge")
        #expect(ActivityContentView.flankPadding(for: both) == 10)

        // The number has to actually fit in what is left of a resting flank.
        let flank = IslandLayout.flankedFlankWidth
        #expect(flank - 2 * ActivityContentView.flankPadding(for: degrees) > 26,
                "three characters of rounded 12pt text need more than this or they truncate")
    }

    @Test("a flanked island still shows both flanks")
    func flankedRestKeepsFlanks() {
        #expect(
            layout(.flankedRest).visibleSlots(for: .rest, in: nowPlaying).contains(.leading)
        )
    }

    /// `compact` is the badge for an island with nothing to flank — which on a notchless display is
    /// every state, and on a notched one is nothing yet.
    @Test("an island with no cutout shows the single compact badge")
    func compactWhereThereAreNoFlanks() {
        let resolved = ActivitySlotLayout.resolve(bodySize: CGSize(width: 210, height: 32), cutoutSize: .zero)
        #expect(resolved.visibleSlots(for: .rest, in: nowPlaying) == [.compact])
        #expect(resolved.visibleSlots(for: .peek, in: nowPlaying) == [.compact])
    }

    @Test("a blind island shows nothing, however much the activity has to say")
    func restShowsNothing() {
        #expect(layout(.rest).visibleSlots(for: .rest, in: nowPlaying).isEmpty)
    }

    /// An empty slot draws as nothing at all, never as a reserved gap — `welcomeBack` supplies no
    /// trailing content, and the island must not hold a space open for it.
    @Test("an empty slot is not drawn")
    func emptySlotsAreSkipped() {
        let welcome = BuiltInActivity.welcomeBack(greeting: "Welcome back").presentations
        #expect(welcome.trailing.isEmpty)
        // Open, the body is the whole presentation, so neither flank is drawn — empty or not.
        #expect(layout(.expanded).visibleSlots(for: .expanded, in: welcome) == [.expanded])
        // Collapsed is where an empty slot could still hold a gap open, and must not.
        #expect(layout(.flankedRest).visibleSlots(for: .rest, in: welcome) == [.leading])
    }
}

@Suite("Activity clock")
struct ActivityClockTests {

    private func countdown() -> ActivityPresentations {
        let value = ActivityValue.countdown(until: Date().addingTimeInterval(300))
        return ActivityPresentations(
            leading: ActivityContent(symbol: "timer"),
            trailing: ActivityContent(value: value),
            compact: ActivityContent(symbol: "timer", value: value),
            expanded: ActivityContent(symbol: "timer", title: "Tea", value: value)
        )
    }

    @Test("only countdowns and elapsed times depend on the clock")
    func timeDependence() {
        #expect(ActivityValue.countdown(until: Date()).isTimeDependent)
        #expect(ActivityValue.elapsed(since: Date()).isTimeDependent)
        #expect(!ActivityValue.fraction(0.5).isTimeDependent)
        #expect(!ActivityValue.indeterminate.isTimeDependent)
    }

    /// §9's "no polling when idle", stated precisely: a countdown that is not on screen costs
    /// nothing. A blind island is idle no matter what the coordinator is holding.
    @Test("a countdown nobody can see does not start a display link")
    func noClockWhileBlind() {
        #expect(!layout(.rest).needsClock(for: .rest, in: ActivityStage.lone(countdown())))
        #expect(!layout(.peek).needsClock(for: .peek, in: ActivityStage.lone(countdown())))
    }

    @Test("a countdown on screen starts one")
    func clockWhileVisible() {
        #expect(layout(.expanded).needsClock(for: .expanded, in: ActivityStage.lone(countdown())))
    }

    @Test("nothing presented means no clock")
    func noClockWithoutAnActivity() {
        #expect(!layout(.expanded).needsClock(for: .expanded, in: nil as ActivityStage?))
    }

    @Test("an activity with no time-dependent value never starts one")
    func noClockForStaticContent() {
        let hud = BuiltInActivity.systemHUD(.volume, level: 0.4).presentations
        #expect(!layout(.expanded).needsClock(for: .expanded, in: ActivityStage.lone(hud)))
    }
}
