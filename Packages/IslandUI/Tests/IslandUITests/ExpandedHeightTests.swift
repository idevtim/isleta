import CoreGraphics
import Foundation
import IslandActivities
import IslandKit
import Testing

@testable import IslandUI

/// Captured from a 14" MacBook Pro, as everywhere else in these tests.
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

/// A measurer with no fonts in it, so these tests assert the *arithmetic* rather than what SF Pro
/// happens to measure today. 20pt lines, 30 characters each.
private let fake = ActivityTextMeasure.fixed(lineHeight: 20, charactersPerLine: 30)

/// A title with a subtitle that can wrap — the shape the generic measurement was written for.
private func message(body: String?) -> ActivityPresentations {
    ActivityPresentations(
        compact: ActivityContent(symbol: "calendar.badge.clock", title: "Q3 numbers"),
        expanded: ActivityContent(
            symbol: "calendar.badge.clock",
            title: "Q3 numbers",
            subtitle: body
        )
    )
}

@Suite("Open island height")
struct ExpandedHeightTests {

    // MARK: - The arithmetic

    @Test("a longer message opens a taller island")
    func longerMessageIsTaller() throws {
        let short = ActivityExpandedHeight.contentHeight(
            for: message(body: "one line"),
            kind: .calendarAlert,
            measure: fake
        )
        let long = ActivityExpandedHeight.contentHeight(
            for: message(body: String(repeating: "long enough to wrap. ", count: 6)),
            kind: .calendarAlert,
            measure: fake
        )
        try #expect(#require(short) < #require(long))
    }

    /// The failure this whole change exists to fix, stated as a number: the message is what the
    /// island was opened to show, so the island has to be tall enough to hold it.
    @Test("a five-line message is given five lines of room")
    func messageGetsItsLines() throws {
        let five = try #require(
            ActivityExpandedHeight.contentHeight(
                for: message(body: String(repeating: "x", count: 30 * 5)),
                kind: .calendarAlert,
                measure: fake
            )
        )
        let two = try #require(
            ActivityExpandedHeight.contentHeight(
                for: message(body: String(repeating: "x", count: 30 * 2)),
                kind: .calendarAlert,
                measure: fake
            )
        )
        // Three extra lines of subtitle, and nothing else changed. Measured from *two* rather than
        // from one, because a one-line message does not reach past the symbol well — the well is
        // the floor, and the difference there would be the floor's, not the message's.
        #expect(abs(five - two - 60) < 0.0001)
    }

    /// Bounded on purpose — the island is not a window. See `messageLineLimit`.
    @Test("a message past the line limit stops growing the island")
    func lineLimitBites() {
        let five = String(repeating: "x", count: 30 * 5)
        let fifty = String(repeating: "x", count: 30 * 50)
        #expect(
            ActivityExpandedHeight.contentHeight(for: message(body: five), kind: .calendarAlert, measure: fake)
                == ActivityExpandedHeight.contentHeight(for: message(body: fifty), kind: .calendarAlert, measure: fake)
        )
    }

    /// The greeting is the other half of the complaint: one short sentence in a body sized for a
    /// music player. It should open shorter than an activity carrying a message, and shorter
    /// than the default.
    @Test("the wake greeting opens shorter than an activity with a message")
    func greetingIsShort() throws {
        let greeting = try #require(
            ActivityExpandedHeight.contentHeight(
                for: BuiltInActivity.welcomeBack(greeting: "Welcome back", subtitle: "Good evening").presentations,
                kind: .welcomeBack,
                measure: fake
            )
        )
        let message = try #require(
            ActivityExpandedHeight.contentHeight(
                for: message(body: String(repeating: "a long message. ", count: 8)),
                kind: .calendarAlert,
                measure: fake
            )
        )
        #expect(greeting < message)
        #expect(
            IslandLayout.expandedHeight(contentHeight: greeting, cutoutHeight: cutout.height)
                < IslandLayout.expandedBodySize.height
        )
    }

    /// The symbol well is the floor for a short content, not an addition to it: the glyph and the
    /// text are side by side, so a one-line title cannot make the island shorter than the well.
    @Test("a one-line title still clears the symbol well")
    func symbolWellIsTheFloor() {
        let content = ActivityContent(symbol: "bell.fill", title: "Hi")
        #expect(
            ActivityExpandedHeight.blockHeight(for: content, width: 368, measure: fake)
                == ActivityExpandedHeight.symbolWellSide
        )
    }

    // MARK: - Which kinds size themselves

    /// Now Playing and the shelf draw their own body against a rectangle they already agreed on.
    @Test("the two kinds that draw their own body keep the default height", arguments: [ActivityKind.nowPlaying, .shelf])
    func selfDrawingKindsKeepTheDefault(kind: ActivityKind) {
        let presentations = ActivityPresentations(
            expanded: ActivityContent(symbol: "play.fill", title: "Track", subtitle: "Artist")
        )
        #expect(ActivityExpandedHeight.contentHeight(for: presentations, kind: kind, measure: fake) == nil)
    }

    @Test("nothing on stage asks for nothing")
    func emptyStageKeepsTheDefault() {
        #expect(ActivityExpandedHeight.contentHeight(for: nil, kind: nil, measure: fake) == nil)
        #expect(ActivityExpandedHeight.contentHeight(for: .empty, kind: .calendarAlert, measure: fake) == nil)
    }

    // MARK: - Against the layout it has to agree with

    /// The height is only right if the slot layout it produces can actually hold the content: the
    /// body region is the island minus the cutout, and it is that region the text is drawn in.
    @Test("the height it asks for survives the slot layout")
    func heightSurvivesSlotLayout() throws {
        let content = message(body: String(repeating: "three lines of message. ", count: 3))
        let requested = try #require(
            ActivityExpandedHeight.contentHeight(for: content, kind: .calendarAlert, measure: fake)
        )
        let metrics = IslandLayout.metrics(
            for: .expanded,
            on: notchedScreen,
            expandedContentHeight: requested
        )
        let layout = ActivitySlotLayout.resolve(bodySize: metrics.bodySize, cutoutSize: cutout)
        let body = try #require(layout.body)
        #expect(body.height >= requested)
        #expect(layout.bodySlot(for: .expanded, in: content) == .expanded)
    }

    /// The clamp is what keeps the panel able to hold the island — it is created once at
    /// `maxExpandedBodySize` and never resized.
    @Test("an absurd content height is clamped to the panel, and a tiny one to the floor")
    func clamped() {
        #expect(
            IslandLayout.expandedHeight(contentHeight: 4000, cutoutHeight: 32)
                == IslandLayout.maxExpandedBodySize.height
        )
        #expect(
            IslandLayout.expandedHeight(contentHeight: 1, cutoutHeight: 32)
                == IslandLayout.minimumExpandedHeight
        )
        #expect(
            IslandLayout.expandedHeight(contentHeight: nil, cutoutHeight: 32)
                == IslandLayout.expandedBodySize.height
        )
    }

    /// The cutout is added at the end, by the screen, and not by the content — which is what lets
    /// one content height be correct on a notched display and a notchless one at the same time.
    @Test("the same content is 32pt taller where there is a hole above it")
    func cutoutIsTheScreensBusiness() {
        let withHole = IslandLayout.expandedHeight(contentHeight: 120, cutoutHeight: 32)
        let without = IslandLayout.expandedHeight(contentHeight: 120, cutoutHeight: 0)
        #expect(withHole - without == 32)
    }

    /// Every form still nests inside the open island, which is what lets the widen-then-tighten
    /// protocol name `.expanded` and cover most of the family in one call: it is the largest shape
    /// at any height it can take.
    ///
    /// **Except on the two spelling spans, and that exception is checked rather than excused.** A
    /// HUD spells itself in the slivers and power spells itself one span further out;
    /// `IslandLayout.wideFlankedWidthGrowth` is 216 and `widerFlankedWidthGrowth` is 274, against an
    /// open body of 368 — so those forms are *wider* than the island they open into, on every Mac.
    /// What keeps the protocol sound is that they exceed it in width **only**: they are still the
    /// cutout's own height, so `AppDelegate.transition` naming `.widerFlankedPeekWithLip` as a third
    /// maximal form covers the whole of the difference. A wide form that also grew downward would
    /// not be covered by that call, which is what this second half is here to catch.
    @Test("the expanded island is still the largest form at its shortest")
    func expandedIsStillLargest() {
        let shortest = IslandLayout.metrics(
            for: .expanded,
            on: notchedScreen,
            expandedContentHeight: 0
        )
        // Every *collapsed* form. `.expandedWithPageIndicator` is excluded because it is not one of the
        // shapes that has to nest inside the open island — it **is** the open island, grown to
        // reveal the row, and it is checked as a superset of `.expanded` below.
        let sizing = IslandSizing(peekScale: 1.5)
        for form in IslandForm.allCases where form.presentation != .expanded {
            let other = IslandLayout.metrics(for: form, on: notchedScreen, sizing: sizing)
            #expect(shortest.bodySize.height >= other.bodySize.height)
            if form.flanks >= .wide {
                #expect(other.bodySize.width > shortest.bodySize.width, "\(form) should be wider")
            } else {
                #expect(shortest.bodySize.width >= other.bodySize.width)
            }
        }
    }

    /// Revealing the switcher row grows the island **downward and only downward**, so the shape the
    /// pointer arrives into is a strict superset of the one it left.
    ///
    /// That direction is what makes the reveal safe under the widen-then-tighten protocol: a hit
    /// region widened to the taller form is a superset of every intermediate, and a superset is the
    /// harmless direction — the window server has already routed those clicks to us. A subset is
    /// the one that drops clicks on visible island pixels.
    @Test("revealing the row grows the open island and never shrinks it")
    func switcherFormIsASupersetOfExpanded() {
        for contentHeight in [nil, 0, 60, 200] as [CGFloat?] {
            let plain = IslandLayout.metrics(
                for: .expanded, on: notchedScreen, expandedContentHeight: contentHeight, pageIndicatorHeight: 42)
            let revealed = IslandLayout.metrics(
                for: .expandedWithPageIndicator, on: notchedScreen, expandedContentHeight: contentHeight, pageIndicatorHeight: 42)
            #expect(revealed.bodySize.width == plain.bodySize.width)
            #expect(revealed.bodySize.height >= plain.bodySize.height)
        }
    }

    // MARK: - Against the real font

    /// The system measurer is the one that ships, so it gets one test: whole lines, and more of
    /// them for more text. Deliberately not an absolute number — that would be asserting what SF
    /// Pro measures on this OS, which is Apple's to change.
    @Test("the real measurer grows in whole lines")
    func systemMeasurerIsSane() {
        let style = ActivityTextStyle(size: 12)
        let line = ActivityTextMeasure.system.lineHeight(style)
        #expect(line > 0)
        let one = ActivityTextMeasure.system.height("short", style, 274, 5)
        let many = ActivityTextMeasure.system.height(
            String(repeating: "a sentence that certainly wraps. ", count: 4), style, 274, 5
        )
        #expect(one == line)
        #expect(many > one)
        #expect(many.truncatingRemainder(dividingBy: line) == 0)
    }
}
