import Foundation
import IslandActivities
import IslandKit
import Testing

@testable import IslandUI

/// **The schedule is a drill-down, not a page and not an activity, and nothing about which stage it
/// was opened over may change that.**
///
/// This suite exists for one bug, shipped in 2.0.0 and reported from use with a screenshot: the
/// island's bottom edge moved up through the schedule while it was open, "even though most of the
/// time it's the right height". `AppDelegate.expandedContentHeightForStage` gated the schedule's
/// height on `kind == .glance || kind == .meeting` — and `.glance` is **never on stage**, because
/// the kind was withdrawn when the calendar stopped standing on the stack as an ambient activity
/// (see `IslandScreenModel.drawsPages`, which keeps the case and never matches it).
///
/// So for the ordinary stages — nothing on stage at all, or a track playing — that branch could not
/// answer. Opening was correct, because `toggleGlanceSchedule` sets the height itself and never
/// asks; the *next* stage change asked, was told the home page's height, and shrank the island
/// under a surface still being drawn at the schedule's.
///
/// What is pinned here is the half of that rule this package owns: the view draws the schedule over
/// **every** stage the pages can be shown under. A shell that gates its height on the kind is
/// therefore answering a different question from the one the island is drawing, and the two heights
/// are not close — `HomeLayoutTests` pins `full < GlanceScheduleLayout.contentHeight`.
@Suite("The schedule over whatever is on stage")
@MainActor
struct GlanceScheduleStageTests {

    private func model() -> IslandScreenModel {
        let screen = IslandScreen(
            id: 1, name: "Built-in Retina Display",
            frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            backingScaleFactor: 2,
            notch: NotchGeometry(kind: .hardware, rect: CGRect(x: 771.5, y: 1085, width: 185, height: 32))
        )
        let table = Dictionary(uniqueKeysWithValues: IslandForm.allCases.map {
            ($0, IslandLayout.metrics(
                for: $0,
                on: screen,
                expandedContentHeight: GlanceScheduleLayout.contentHeight,
                expandedContentWidth: GlanceScheduleLayout.bodyWidth,
                pageIndicatorHeight: IslandPageIndicatorLayout.height
            ))
        })
        return IslandScreenModel(
            metricsByForm: table,
            notchKind: .hardware,
            cutoutSize: CGSize(width: 185, height: 32)
        )
    }

    /// The stages an open island can be showing a page under, which are exactly the stages the
    /// schedule can be opened from: the date block is on the home page, and the home page draws for
    /// all of these.
    ///
    /// `.glance` is in the list and is the reason the list is written out rather than described:
    /// it is the one that is never presented, so a rule that happens to be right for it and wrong
    /// for the other two reads as a rule about the schedule.
    private static let stagesThePagesOwn: [ActivityKind?] = [nil, .nowPlaying, .glance]

    @Test("the schedule owns the body over every stage a page is drawn under")
    func theScheduleOwnsTheBodyWhateverIsOnStage() {
        for kind in Self.stagesThePagesOwn {
            let m = model()
            let glance = GlanceModel()
            m.glance = glance
            if let kind {
                m.setActivity(Self.presentations, kind: kind, change: .presented("stub"), reduceMotion: true)
            }
            m.setExpanded(true, reduceMotion: true)

            // Without it, the page has the body — which is the state whose height the shell was
            // answering with.
            #expect(m.pagesOwnBody, "a page should own the body for \(String(describing: kind))")

            glance.isShowingSchedule = true
            m.setShowingGlanceSchedule(true, reduceMotion: true)

            // With it, the same is true and the surface drawn is the schedule. `pagesOwnBody` is
            // the question `IslandRootView` asks before it draws either, and it does not consult
            // the kind for this surface at all.
            #expect(m.pagesOwnBody, "the schedule should own the body for \(String(describing: kind))")
            #expect(m.isShowingGlanceSchedule)
            // And the island is the schedule's shape, not the page's — the whole point of the
            // height being agreed before the transition.
            #expect(m.contentMetrics.bodySize.width == GlanceScheduleLayout.bodyWidth)
        }
    }

    /// The surfaces that win over it, in the order `IslandScreenModel.pagesOwnBody` states: the two
    /// cannot be up with the schedule today, and an order that relies on that is an order that
    /// breaks the day they can be.
    @Test("Up Next and the drop history still take the body from it")
    func theListsWinOverTheSchedule() {
        for surface in ["queue", "history"] {
            let m = model()
            let glance = GlanceModel()
            m.glance = glance
            m.setExpanded(true, reduceMotion: true)
            glance.isShowingSchedule = true
            m.setShowingGlanceSchedule(true, reduceMotion: true)
            #expect(m.pagesOwnBody)

            // Both are read off the model they belong to, not stored here — which is what makes
            // them impossible to get out of step with the surface actually drawn.
            if surface == "queue" {
                let player = NowPlayingController()
                m.nowPlaying = player
                player.isShowingQueue = true
            } else {
                let history = DropHistoryModel()
                m.dropHistory = history
                history.isShowing = true
            }
            #expect(!m.pagesOwnBody, "\(surface) should take the body from the schedule")
        }
    }

    /// Flanks and a compact badge, with the **empty** `expanded` slot the kinds behind the pages
    /// publish — see `ActivitySlotLayout.bodySlot`, which is what lets a page have the body at all.
    private static let presentations = ActivityPresentations(
        leading: ActivityContent(symbol: "music.note"),
        compact: ActivityContent(symbol: "music.note", title: "A track")
    )
}
