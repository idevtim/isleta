import Foundation
import IslandActivities
import IslandKit

@testable import IslandUI

/// An activity built from presentations and a kind, for tests that care about neither.
///
/// Most of this target's suites are about layout, clock rate and morph timing — they need *some*
/// activity carrying *some* content, and nothing about its priority, expiry or identity. This is
/// that, so those suites can go on saying what they mean.
struct StubActivity: IslandActivity {
    var id: ActivityID = "stub"
    var kind: ActivityKind = .calendarAlert
    var priority: ActivityPriority = .standard
    var expiry: ActivityExpiry = .never
    var presentations: ActivityPresentations
}

extension ActivityStage {

    /// A stage with one activity and no companion — which is what every test here predates the pair
    /// by assuming, and what the island still does most of the time.
    static func lone(_ presentations: ActivityPresentations, kind: ActivityKind = .calendarAlert) -> ActivityStage {
        let activity = StubActivity(kind: kind, presentations: presentations)
        return ActivityStage(primary: activity, primaryFlank: kind.flankAffinity)
    }
}

extension IslandScreenModel {

    /// The pre-pair call shape, kept **in the test target only**.
    ///
    /// Deliberately not a convenience on `IslandScreenModel` itself. A production overload taking
    /// loose presentations plus a kind is a second spelling of what is on the island, and the whole
    /// point of storing an `ActivityStage` is that there is one — a call site reaching for the old
    /// shape would silently drop the companion and look entirely correct. Tests that are not about
    /// the pair can use it; nothing that ships can.
    func setActivity(
        _ presentations: ActivityPresentations?,
        kind: ActivityKind? = nil,
        change: ActivityChange,
        reduceMotion: Bool,
        metricsByForm: [IslandForm: IslandShapeMetrics]? = nil,
        completion: @escaping @MainActor () -> Void = {}
    ) {
        setActivity(
            presentations.map { ActivityStage.lone($0, kind: kind ?? .calendarAlert) },
            change: change,
            reduceMotion: reduceMotion,
            metricsByForm: metricsByForm,
            completion: completion
        )
    }
}
