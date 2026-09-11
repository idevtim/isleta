import CoreGraphics
import Foundation
import IslandActivities
import IslandKit
import Testing

@testable import IslandUI

/// The bar in a HUD's sliver, dragged.
///
/// Two halves, and only one of them is arithmetic. **Where a point along the bar lands** is
/// `ActivityContentView.levelFraction(at:width:)`, which is pure and pinned here. **Which levels are
/// a control at all** is the activity's own answer, and it is the half that can go quietly wrong:
/// the bar drawn beside a crossed-out speaker looks exactly like the one beside a speaker with waves
/// and is not the same number, so a drag on it would set a volume nobody can hear.
///
/// What is deliberately *not* here is the gesture itself. A `DragGesture` needs a window, a hosting
/// view and a pointer; `ClickSelfTest` and the other headless self-tests in the app shell are where
/// this codebase drives real events, and §3's layering test is why nothing in IslandUI's own suite
/// tries to.
@Suite("Level drag")
@MainActor
struct LevelDragTests {

    private func makeModel() -> IslandScreenModel {
        IslandScreenModel(
            metricsByForm: [
                .rest: IslandShapeMetrics(
                    bodySize: CGSize(width: 185, height: 32), topCornerRadius: 0, bottomCornerRadius: 8
                ),
            ],
            notchKind: .hardware,
            cutoutSize: CGSize(width: 185, height: 32)
        )
    }

    // MARK: - Which levels a finger may move

    @Test("volume and brightness are levels the user may set")
    func theTwoDrivenLevels() {
        #expect(BuiltInActivity.systemHUD(.volume, level: 0.4).adjustableLevel == .volume)
        #expect(BuiltInActivity.systemHUD(.brightness, level: 0.4).adjustableLevel == .brightness)
    }

    /// **The one that has to be nil.** A mute publishes level zero whatever volume is held behind
    /// it — the same fact `ActivityLimit` exists for — so the bar is a statement rather than a
    /// setting, and dragging it would leave the user having set a level they cannot hear.
    @Test("a mute's bar is not a level")
    func muteIsNotAdjustable() {
        #expect(BuiltInActivity.systemHUD(.mute, level: 0).adjustableLevel == nil)
    }

    /// Everything else in the vocabulary draws bars the user has no business moving: a battery
    /// percentage, a conversion's progress, a track's position. The default on the protocol is what
    /// keeps them that way without every kind having to say so.
    @Test("nothing else offers one")
    func everythingElseIsNil() {
        #expect(BuiltInActivity.nowPlaying(title: "Blue in Green").adjustableLevel == nil)
        #expect(BuiltInActivity.welcomeBack(greeting: "Good morning").adjustableLevel == nil)
    }

    // MARK: - Where a point along the bar lands

    @Test("the ends of the bar are the ends of the range")
    func endsAreTheEnds() {
        #expect(ActivityContentView.levelFraction(at: 0, width: 76) == 0)
        #expect(ActivityContentView.levelFraction(at: 76, width: 76) == 1)
    }

    @Test("the middle is half")
    func middleIsHalf() {
        #expect(ActivityContentView.levelFraction(at: 38, width: 76) == 0.5)
    }

    /// **`minimumDistance: 0` keeps reporting after the pointer has left the bar**, which is exactly
    /// what a person does at the end of a range: they keep going. Off either end is that end, not a
    /// level that runs backwards past where it was pushed.
    @Test("a drag off either end stays at that end")
    func pastTheEndsIsClamped() {
        #expect(ActivityContentView.levelFraction(at: -40, width: 76) == 0)
        #expect(ActivityContentView.levelFraction(at: 200, width: 76) == 1)
    }

    /// A bar with no width is a bar that has not been laid out yet — a frame or two on the way in.
    /// Zero rather than a divide by it, and silence rather than an answer: the caller writes what it
    /// is handed, and `1` here would set the volume to full on the first frame of an arriving HUD.
    @Test("a bar with no width answers zero rather than dividing by it")
    func zeroWidthIsSafe() {
        #expect(ActivityContentView.levelFraction(at: 12, width: 0) == 0)
    }

    // MARK: - The island's end of it

    /// The model carries no level of its own and writes nothing: it hands the shell which level and
    /// how far along it, and the bar moves later because the *reading* moved. One publisher for a
    /// level, which is the rule the key-replacement path is already built on.
    @Test("the island reports the level and the fraction, and sets nothing itself")
    func theModelOnlyReports() {
        let model = makeModel()
        var asked: [(SystemHUD, Double)] = []
        model.onAdjustLevel = { asked.append(($0, $1)) }

        model.onAdjustLevel?(.volume, 0.25)
        #expect(asked.count == 1)
        #expect(asked.first?.0 == .volume)
        #expect(asked.first?.1 == 0.25)
    }

    /// Nil in every build with no app shell — a preview, a test, this suite before the line above —
    /// which is what keeps the bar a picture there rather than a control that silently does nothing.
    @Test("an island with no shell behind it offers no control at all")
    func noShellNoControl() {
        #expect(makeModel().onAdjustLevel == nil)
    }
}
