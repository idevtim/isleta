import CoreGraphics
import Foundation
import IslandActivities
import IslandKit
import Testing

@testable import IslandUI

private let noon = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func event(_ title: String, at offset: TimeInterval, meeting: MeetingLink? = nil) -> GlanceEvent {
    GlanceEvent(
        id: "\(title)@\(offset)",
        title: title,
        start: noon.addingTimeInterval(offset),
        end: noon.addingTimeInterval(offset + 1800),
        meeting: meeting
    )
}

@Suite("Glance layout")
struct GlanceLayoutTests {

    @Test("three rows do not fit the island's default height, which is why the shell must ask")
    func theDefaultIslandIsTooShortForADay() {
        // **This is the assertion that was missing while the glance shipped with a sliced row.**
        // `ActivityKind.glance.sizesOpenIslandToContent` is false, so if the app shell does not
        // explicitly ask `GlanceModel.contentHeight(for:)`, the island opens at
        // `IslandLayout.expandedBodySize.height` — and that is *not* a merely different height, it
        // is a shorter one. The last row is then cut by the island's own bottom edge.
        //
        // Everything else in this file measures `GlanceLayout` against itself and passed throughout
        // that bug. This one measures it against the height it gets when nobody asks.
        let cutout: CGFloat = 32
        let roomWhenNobodyAsks = IslandLayout.expandedBodySize.height - cutout
        #expect(GlanceLayout.contentHeight(rowCount: GlanceLayout.maximumRows) > roomWhenNobodyAsks,
                "a full day needs more room than the default island has, so the override is not optional")
    }

    @Test("the island grows a row at a time, and stops at three")
    func heightFollowsRowCount() {
        let one = GlanceLayout.contentHeight(rowCount: 1)
        let two = GlanceLayout.contentHeight(rowCount: 2)
        let three = GlanceLayout.contentHeight(rowCount: 3)
        #expect(two - one == GlanceLayout.rowHeight + GlanceLayout.rowSpacing)
        #expect(three - two == GlanceLayout.rowHeight + GlanceLayout.rowSpacing)
        // Past three this stops reading as the notch having opened and starts reading as a calendar
        // window bolted to one, so the extra rows are simply not listed.
        #expect(GlanceLayout.contentHeight(rowCount: 9) == three)
    }

    @Test("an empty glance is still one row tall, because the sentence needs the room")
    func emptyIsARow() {
        // An island that shrank to its header to say "Calendar access is off" would put the sentence
        // outside itself.
        #expect(GlanceLayout.emptyContentHeight == GlanceLayout.contentHeight(rowCount: 1))
        #expect(GlanceLayout.contentHeight(rowCount: 0) == GlanceLayout.emptyContentHeight)
    }

    @Test("rowsHeight is the exact inverse of contentHeight")
    func inverseAgrees() {
        // The two answer the same question in opposite directions, and the way they fail on screen
        // when they drift is a row sliced in half by the island's own bottom edge — with every test
        // still passing.
        for count in 1...GlanceLayout.maximumRows {
            let content = GlanceLayout.contentHeight(rowCount: count)
            #expect(GlanceLayout.rowsHeight(inContentHeight: content) == GlanceLayout.rowsExtent(rowCount: count))
        }
    }

    @Test("the glance fits inside the island's ceiling with the switcher row on top of it")
    func fitsTheIsland() {
        // `IslandLayout.maxExpandedBodySize` is what the panel was built at, and a body taller than
        // it is a body clipped by a panel that cannot grow — the panel frame never animates (§4.2).
        let tallest = GlanceLayout.contentHeight(rowCount: GlanceLayout.maximumRows)
            + IslandPageIndicatorLayout.height
            // The tallest cutout any Mac in the range has, plus room to spare.
            + 40
        #expect(tallest <= IslandLayout.maxExpandedBodySize.height)
    }

    @Test("a meeting gets a shape of its own, not a day list with empty rows in it")
    func meetingHasItsOwnHeight() {
        #expect(GlanceLayout.meetingContentHeight != GlanceLayout.contentHeight(rowCount: 1))
        #expect(GlanceLayout.meetingContentHeight >= GlanceLayout.emptyContentHeight)
    }

    @Test("only the two glance kinds ask for a height")
    func onlyGlanceKindsSize() {
        // Nil rather than a default, matching `ActivityExpandedHeight.contentHeight`: a kind that
        // does not size the island says so, instead of arriving at the default by another route.
        #expect(GlanceLayout.contentHeight(for: .glance, rowCount: 2) != nil)
        #expect(GlanceLayout.contentHeight(for: .meeting, rowCount: 0) == GlanceLayout.meetingContentHeight)
        #expect(GlanceLayout.contentHeight(for: .nowPlaying, rowCount: 2) == nil)
        #expect(GlanceLayout.contentHeight(for: nil, rowCount: 2) == nil)
    }

    @Test("the glance owns its height, which is why the generic measurement must not")
    func kindDoesNotSizeToContent() {
        // If this ever flipped, `ActivityExpandedHeight` would measure a title and a subtitle that
        // are not there — the expanded slot is empty by design — and the island would open at the
        // default height with a three-row day drawn into it.
        #expect(!ActivityKind.glance.sizesOpenIslandToContent)
    }
}

@Suite("Glance model")
@MainActor
struct GlanceModelTests {

    @Test("the model caps its rows at the layout's ceiling, not just the policy's")
    func rowsAreCapped() {
        // Two ceilings that happen to agree today. Capping in both places is what stops the height
        // and the drawn list disagreeing if one of them ever moves.
        let many = (1...9).map { event("Event \($0)", at: TimeInterval($0) * 600) }
        let model = GlanceModel(snapshot: GlanceSnapshot(access: .granted, events: many, asOf: noon))
        #expect(model.rows.count == GlanceLayout.maximumRows)
    }

    @Test("the height the shell reads matches what is actually drawn")
    func heightMatchesRows() {
        let model = GlanceModel(
            snapshot: GlanceSnapshot(
                access: .granted,
                events: [event("Standup", at: 600), event("Review", at: 3600)],
                asOf: noon
            )
        )
        #expect(model.contentHeight(for: .glance) == GlanceLayout.contentHeight(rowCount: 2))
        #expect(model.contentHeight(for: .meeting) == GlanceLayout.meetingContentHeight)
        #expect(model.contentHeight(for: .nowPlaying) == nil)
    }

    @Test("an empty day still asks for a height, because it still draws a sentence")
    func emptyDayHasAHeight() {
        let model = GlanceModel(snapshot: GlanceSnapshot(access: .denied, asOf: noon))
        #expect(model.contentHeight(for: .glance) == GlanceLayout.emptyContentHeight)
    }

    @Test("the join button appears only when there is a link to press")
    func canJoin() {
        let model = GlanceModel(snapshot: GlanceSnapshot(access: .granted, asOf: noon))
        #expect(!model.canJoin)
        model.joinableMeeting = event("Standup", at: 30)
        // An event that is joinable in *time* but carries no link is not joinable at all — a button
        // with no URL behind it is a control that visibly does nothing.
        #expect(!model.canJoin)
        model.joinableMeeting = event(
            "Standup",
            at: 30,
            meeting: MeetingLink(provider: .zoom, url: URL(string: "https://zoom.us/j/1")!)
        )
        #expect(model.canJoin)
    }

    @Test("the meeting is held beside the day, not folded into it")
    func meetingIsSeparate() {
        // Folding it into the snapshot would make the day list republish — and the island resize —
        // every time a meeting became joinable.
        let model = GlanceModel(
            snapshot: GlanceSnapshot(access: .granted, events: [event("Standup", at: 600)], asOf: noon)
        )
        model.joinableMeeting = event("Other", at: 30)
        #expect(model.rows.map(\.title) == ["Standup"])
    }
}
