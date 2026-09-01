import Foundation

/// Stable identity for one *logical* activity, not for one update of it.
///
/// The distinction is the whole point. Now Playing emits a new payload on every track change, every
/// scrub, every pause; if each of those arrived under a fresh id the coordinator would see a stream
/// of unrelated activities, and the island would re-enter from nothing on every seek instead of
/// swapping its content in place (§6.2 wants `contentSwap` there, not `expand`). So a source picks
/// one id for the stream it owns and keeps it: `ActivityKind.singletonID` hands out the built-in
/// ones. Notifications are the exception — several can be outstanding at once, so each gets its own.
public struct ActivityID: Hashable, Sendable, RawRepresentable, ExpressibleByStringLiteral, CustomStringConvertible {

    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: StringLiteralType) { self.rawValue = value }

    public var description: String { rawValue }
}

/// How hard an activity pushes for the stage.
///
/// Four levels rather than a free integer, because a free integer is how you end up with a
/// notification at 500 and a HUD at 501 and nobody able to say why. The ordering is the ordering of
/// the cases; the *behavior* that the README asks for — "interrupting activities preempt, ambient
/// ones yield" — is not a second axis, it falls out of `displacesPeers` plus the level itself.
public enum ActivityPriority: Int, Comparable, CaseIterable, Sendable {

    /// Always there, never urgent: Now Playing. Sits at the bottom, so anything else takes the
    /// stage from it and it comes back when the stage clears. This is what "ambient ones yield"
    /// means — it needs no special case, only the lowest level and no peer displacement.
    case ambient = 0

    /// User-initiated and durable: the drag-and-drop shelf. Outranks ambient chrome because the
    /// user is holding something over the island; yields to anything the system says.
    case standard = 1

    /// Something happened that the user did not cause: a notification, a wake.
    case prominent = 2

    /// The user just pressed a key and expects the result on screen *now*: volume, brightness,
    /// mute. The only level that displaces its own peers — see `displacesPeers`.
    case interrupting = 3

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Whether a newly arriving activity at this level takes the stage from one already on it at
    /// the *same* level.
    ///
    /// True only for `.interrupting`, and the asymmetry is deliberate. An interrupting activity is
    /// by definition the thing that just happened — pressing brightness while the volume HUD is up
    /// must show brightness, not queue it behind a HUD the user has stopped caring about. Every
    /// other level does the opposite: the incumbent keeps the stage, because if a peer could evict
    /// it, two ambient sources updating a few hundred milliseconds apart would trade the island
    /// back and forth and the user would read it as a fault rather than as information.
    public var displacesPeers: Bool { self == .interrupting }
}

/// When an activity stops being worth showing.
///
/// Expressed as data rather than as a live timer so the whole expiry model is a pure function of a
/// stack and a `Date` — `ActivityStack` can be tested at any instant without waiting for one, and
/// `ActivityCoordinator` needs exactly one scheduled sleep for the whole stack rather than one
/// timer per activity (§9).
public enum ActivityExpiry: Equatable, Sendable {

    /// Lives until its source removes it. Now Playing and the shelf: nothing about the passage of
    /// time makes "this track is playing" false.
    case never

    /// Relative to the moment it was handed to the coordinator. Re-presenting the same id restarts
    /// this — pressing the volume key again is a request for another 1.5 seconds, not a no-op.
    case after(Duration)

    /// An absolute instant. A timer that ends at 3:45 expires at 3:45 no matter how long it has
    /// been on the stack, and no matter how many times its content was updated on the way there.
    case at(Date)

    /// The instant this activity becomes stale, given when it was presented. `nil` means never.
    ///
    /// - Parameter dwellScale: the user's "how long an activity stays" multiplier
    ///   (`IsletaConfiguration.activityDwellScale`). It scales `.after` and **nothing else**, which
    ///   is the whole of the rule: `.after` is a dwell — a judgement about how long a person needs
    ///   to read something — and is therefore theirs to adjust. `.at` is a fact about the world; a
    ///   timer that ends at 3:45 ends at 3:45 whatever anyone would prefer, and scaling it would
    ///   silently make Isleta's clock disagree with the clock the user set. `.never` has nothing to
    ///   scale.
    public func deadline(from start: Date, dwellScale: Double = 1) -> Date? {
        switch self {
        case .never: nil
        case .after(let duration): start.addingTimeInterval(duration.timeInterval * dwellScale)
        case .at(let date): date
        }
    }
}

/// Anything the island can present.
///
/// Deliberately **data, not views** — see this package's README. A conformer describes what it has
/// to say in `ActivityContent`; IslandUI decides what that looks like. Making `presentations`
/// return `some View` instead would drag SwiftUI, and through it AppKit, into the one module whose
/// entire value is being testable with no window, no permission and no main thread; it would also
/// make the model un-`Equatable`, and `ActivityChange.contentChanged` — which is what tells §6.2 to
/// crossfade rather than morph — is precisely a comparison of two presentations.
///
/// `Sendable` because sources produce these off the main actor (a media adapter, an AX observer)
/// and hand them across. That is only free while they stay value types.
/// Which end of its range a value has just arrived at.
///
/// Carried by an activity whose value is a **level the user is driving** — the volume and brightness
/// HUDs — and set only on the update that *lands* on the end, never for as long as it sits there.
/// The island answers it with a bounce in that direction (`IslandScreenModel.limitBounce`), and a
/// flag that stayed true would be an island that bounced on every subsequent keypress that changed
/// nothing.
///
/// **Two cases and no `.none`**, for `ActivityFlank`'s reason: "not at an end" is the absence of an
/// `ActivityLimit`, not a third value of one.
///
/// Deliberately says *which end of the range*, not which way to move. Whether the maximum is to the
/// left or the right is a fact about how a level is drawn, and drawing is IslandUI's business —
/// see `IslandScreenModel.limitBounce`, which is where the two meet.
public enum ActivityLimit: String, Hashable, Sendable, CaseIterable {

    /// The bottom of the range. Volume at zero, brightness at its floor.
    case minimum

    /// The top of it.
    case maximum
}

public protocol IslandActivity: Sendable, Identifiable where ID == ActivityID {

    /// Stable across updates of the same logical activity. See `ActivityID`.
    var id: ActivityID { get }

    /// Which built-in vocabulary this belongs to. Kept on the protocol rather than left to
    /// conformers so the coordinator, the debug overlay and IslandSettings can all reason about
    /// "the Now Playing activity" without downcasting to a concrete type.
    var kind: ActivityKind { get }

    var priority: ActivityPriority { get }

    var expiry: ActivityExpiry { get }

    /// The four slots the island can draw this in.
    var presentations: ActivityPresentations { get }

    /// The end of its range this update just landed on, or nil — which is the ordinary answer and
    /// the one every kind but the system HUDs gives forever.
    ///
    /// On the protocol with a default rather than left to the coordinator to infer, because only the
    /// source that produced the value knows whether reaching zero was the user running a level down
    /// or something else entirely: `SystemHUDLevelState` publishes level zero for a *mute*, which is
    /// not the bottom of a range being reached and must not bounce the island.
    var reachedLimit: ActivityLimit? { get }
}

extension IslandActivity {

    /// Nothing is at an end unless it says so. A default rather than a requirement every conformer
    /// has to restate, because this is a property of two levels out of fourteen kinds.
    public var reachedLimit: ActivityLimit? { nil }
}

extension Duration {

    /// Seconds as a `TimeInterval`, for the one place the model meets `Date`.
    ///
    /// `Duration` is attosecond-exact and `TimeInterval` is a `Double`; the conversion is lossy in
    /// the last bits and that is fine here, because the consumer is a scheduled sleep whose real
    /// resolution is a display refresh.
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) * 1e-18
    }
}
