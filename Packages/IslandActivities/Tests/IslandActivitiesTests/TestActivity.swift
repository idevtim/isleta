import Foundation

@testable import IslandActivities

/// A minimal conformance, so the stack tests exercise the protocol rather than `BuiltInActivity`.
///
/// The distinction matters: `BuiltInActivity` derives its priority and expiry from its kind, which
/// is convenient in the app and useless in a test that wants an ambient activity with a 50ms expiry
/// to check queue drain. Everything here is set explicitly.
struct TestActivity: IslandActivity, Equatable {
    var id: ActivityID
    var kind: ActivityKind = .calendarAlert
    var priority: ActivityPriority = .standard
    var expiry: ActivityExpiry = .never
    var presentations: ActivityPresentations = .empty

    init(
        _ id: ActivityID,
        priority: ActivityPriority = .standard,
        expiry: ActivityExpiry = .never,
        title: String? = nil
    ) {
        self.id = id
        self.priority = priority
        self.expiry = expiry
        if let title {
            presentations = ActivityPresentations(
                compact: ActivityContent(title: title),
                expanded: ActivityContent(title: title)
            )
        }
    }
}

/// A clock the tests move by hand.
///
/// Expiry is the one part of this package that touches time, and a test that waits for real seconds
/// to pass is a test that fails on a loaded build machine. `ActivityStack` takes `now` as a
/// parameter and `ActivityCoordinator` takes it as an injected closure precisely so this works.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Date

    init(_ instant: Date = Date(timeIntervalSinceReferenceDate: 0)) {
        self.instant = instant
    }

    var now: Date {
        lock.withLock { instant }
    }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { instant += seconds }
    }

    /// Passed to `ActivityCoordinator(now:)`.
    var provider: @Sendable () -> Date {
        { [self] in now }
    }
}
