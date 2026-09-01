import Foundation
import Testing

@testable import IslandActivities

@Suite("Activity stack — the empty state")
struct EmptyStackTests {

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    /// An empty stack is the app's normal condition, not an error path. Every accessor has to be
    /// safe on it, because the island rests here far more of the time than it presents anything.
    @Test("an empty stack presents nothing and schedules nothing")
    func emptyIsQuiet() {
        let stack = ActivityStack()
        #expect(stack.isEmpty)
        #expect(stack.count == 0)
        #expect(stack.presented == nil)
        #expect(stack.queued.isEmpty)
        // The §9 consequence: no deadline means the coordinator starts no task at all.
        #expect(stack.nextExpiry == nil)
    }

    @Test("removing from an empty stack is a no-op, not a change")
    func removingNothing() {
        var stack = ActivityStack()
        #expect(stack.remove("nobody") == ActivityChange.none)
        #expect(stack.removeExpired(at: t0) == ActivityChange.none)
        #expect(stack.removeAll() == ActivityChange.none)
        #expect(stack.isEmpty)
    }

    @Test("the last activity leaving reports a dismissal, not a swap")
    func drainToEmpty() {
        var stack = ActivityStack()
        stack.insert(TestActivity("only"), at: t0)
        #expect(stack.remove("only") == .dismissed("only"))
        #expect(stack.presented == nil)
    }

    /// Activities that never expire must not put a deadline on the stack, or the coordinator would
    /// hold a sleep for a Now Playing session that lasts all afternoon.
    @Test("a stack of never-expiring activities still has no deadline")
    func neverExpiringSchedulesNothing() {
        var stack = ActivityStack()
        stack.insert(TestActivity("a", expiry: .never), at: t0)
        stack.insert(TestActivity("b", expiry: .never), at: t0)
        #expect(stack.nextExpiry == nil)
    }
}

@Suite("Activity stack — priority and preemption")
struct ActivityPriorityTests {

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    @Test("the levels are ordered ambient below interrupting")
    func levelsAreOrdered() {
        #expect(ActivityPriority.ambient < .standard)
        #expect(ActivityPriority.standard < .prominent)
        #expect(ActivityPriority.prominent < .interrupting)
        #expect(ActivityPriority.allCases.sorted() == [.ambient, .standard, .prominent, .interrupting])
    }

    /// "Interrupting activities preempt": the only level that takes the stage from its own peers.
    @Test("only interrupting displaces its peers")
    func onlyInterruptingDisplacesPeers() {
        for priority in ActivityPriority.allCases {
            #expect(priority.displacesPeers == (priority == .interrupting))
        }
    }

    @Test("higher priority takes the stage from lower, whatever order it arrives in",
          arguments: [true, false])
    func higherPriorityWins(highFirst: Bool) {
        var stack = ActivityStack()
        let low = TestActivity("low", priority: .ambient)
        let high = TestActivity("high", priority: .prominent)

        if highFirst {
            stack.insert(high, at: t0)
            #expect(stack.insert(low, at: t0) == ActivityChange.none)
        } else {
            stack.insert(low, at: t0)
            #expect(stack.insert(high, at: t0) == .swapped(from: "low", to: "high"))
        }

        #expect(stack.presented?.id == "high")
        #expect(stack.queued.map(\.id) == ["low"])
    }

    /// "Ambient ones yield" needs no special case — being the lowest level and not displacing peers
    /// is the whole of it. This pins that down so a later edit cannot quietly promote it.
    @Test("an ambient activity yields to every other level", arguments: ActivityPriority.allCases)
    func ambientYields(other: ActivityPriority) {
        var stack = ActivityStack()
        stack.insert(TestActivity("ambient", priority: .ambient), at: t0)
        stack.insert(TestActivity("other", priority: other), at: t0)

        let expected: ActivityID = other == .ambient ? "ambient" : "other"
        #expect(stack.presented?.id == expected)
    }

    /// A HUD arriving while a HUD is up must be the one shown: the user has just pressed a key and
    /// is watching for the result. Queueing it behind the older HUD shows them stale information.
    @Test("a newer interrupting activity displaces an older one")
    func interruptingPeersAreNewestFirst() {
        var stack = ActivityStack()
        stack.insert(TestActivity("volume", priority: .interrupting), at: t0)
        let change = stack.insert(TestActivity("brightness", priority: .interrupting), at: t0)

        #expect(change == .swapped(from: "volume", to: "brightness"))
        #expect(stack.presented?.id == "brightness")
    }

    /// Everything below interrupting does the opposite, and must: two ambient sources updating a
    /// few hundred milliseconds apart would otherwise trade the island back and forth.
    @Test("below interrupting, the incumbent keeps the stage against a peer",
          arguments: [ActivityPriority.ambient, .standard, .prominent])
    func peersDoNotDisplace(priority: ActivityPriority) {
        var stack = ActivityStack()
        stack.insert(TestActivity("first", priority: priority), at: t0)
        let change = stack.insert(TestActivity("second", priority: priority), at: t0)

        #expect(change == ActivityChange.none)
        #expect(stack.presented?.id == "first")
        #expect(stack.queued.map(\.id) == ["second"])
    }

    /// The tie-break must be a strict total order, or `Array.sort` — which is not stable — could
    /// reorder same-priority entries on an unrelated insertion and change what is on screen.
    @Test("ties are broken deterministically across many entries")
    func tiesAreTotal() {
        var stack = ActivityStack()
        for index in 0..<8 {
            stack.insert(TestActivity(ActivityID("peer\(index)"), priority: .standard), at: t0)
        }
        let order = stack.entries.map(\.id)
        #expect(order == (0..<8).map { ActivityID("peer\($0)") })

        // Inserting something unrelated at a different level must not disturb the peers' order.
        stack.insert(TestActivity("interloper", priority: .interrupting), at: t0)
        #expect(stack.entries.dropFirst().map(\.id) == order)
    }

    @Test("the queue drains back down the priority order")
    func queueDrains() {
        var stack = ActivityStack()
        stack.insert(TestActivity("music", priority: .ambient), at: t0)
        stack.insert(TestActivity("shelf", priority: .standard), at: t0)
        stack.insert(TestActivity("banner", priority: .prominent), at: t0)
        stack.insert(TestActivity("hud", priority: .interrupting), at: t0)

        #expect(stack.presented?.id == "hud")
        #expect(stack.remove("hud") == .swapped(from: "hud", to: "banner"))
        #expect(stack.remove("banner") == .swapped(from: "banner", to: "shelf"))
        #expect(stack.remove("shelf") == .swapped(from: "shelf", to: "music"))
        #expect(stack.remove("music") == .dismissed("music"))
        #expect(stack.isEmpty)
    }

    /// Removing something that is merely queued changes nothing on screen. If this reported a
    /// change the island would re-run a morph for an activity the user never saw.
    @Test("removing a queued activity does not disturb the stage")
    func removingQueuedIsInvisible() {
        var stack = ActivityStack()
        stack.insert(TestActivity("front", priority: .prominent), at: t0)
        stack.insert(TestActivity("back", priority: .ambient), at: t0)

        #expect(stack.remove("back") == ActivityChange.none)
        #expect(stack.presented?.id == "front")
        #expect(stack.count == 1)
    }
}

@Suite("Activity stack — identity and updates")
struct ActivityIdentityTests {

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    /// The bug this prevents: a source that emits on every scrub adds a new entry each time, the
    /// stack grows without bound, and the island re-enters from nothing on every seek.
    @Test("re-presenting an id updates in place rather than duplicating")
    func updateInPlace() {
        var stack = ActivityStack()
        stack.insert(TestActivity("np", priority: .ambient, title: "First"), at: t0)
        let change = stack.insert(TestActivity("np", priority: .ambient, title: "Second"), at: t0)

        #expect(stack.count == 1)
        // Same activity, new content: §6.2 wants a crossfade here, not a morph.
        #expect(change == .contentChanged("np"))
        #expect(stack.presented?.presentations.compact.title == "Second")
    }

    /// An update must not jump the queue. A Now Playing update arriving while a notification is on
    /// the stage would otherwise reorder the two every time the track's elapsed time ticked.
    @Test("an update keeps its place in the queue")
    func updateKeepsSequence() {
        var stack = ActivityStack()
        stack.insert(TestActivity("first", priority: .standard), at: t0)
        stack.insert(TestActivity("second", priority: .standard), at: t0)
        stack.insert(TestActivity("second", priority: .standard, title: "changed"), at: t0)

        #expect(stack.entries.map(\.id) == ["first", "second"])
    }

    /// Nothing on screen changed, so nothing should be reported — an update to a *queued* activity
    /// must not make the island redraw.
    @Test("updating a queued activity reports no change")
    func updatingQueuedIsSilent() {
        var stack = ActivityStack()
        stack.insert(TestActivity("front", priority: .prominent), at: t0)
        stack.insert(TestActivity("back", priority: .ambient, title: "a"), at: t0)

        #expect(stack.insert(TestActivity("back", priority: .ambient, title: "b"), at: t0) == ActivityChange.none)
    }

    /// Re-presenting identical content is not a change. Some sources re-emit unconditionally on a
    /// timer tick, and a crossfade on every one of those is a visible flicker for no information.
    @Test("re-presenting identical content reports no change")
    func identicalContentIsSilent() {
        var stack = ActivityStack()
        let activity = TestActivity("np", priority: .ambient, title: "Same")
        stack.insert(activity, at: t0)
        #expect(stack.insert(activity, at: t0) == ActivityChange.none)
    }

    /// The other half of the update rule: the sequence survives, the deadline does not. Pressing
    /// the volume key again buys another full dwell.
    @Test("re-presenting restarts a relative expiry")
    func updateRestartsExpiry() {
        var stack = ActivityStack()
        let hud = TestActivity("hud", priority: .interrupting, expiry: .after(.seconds(2)))
        stack.insert(hud, at: t0)
        #expect(stack.nextExpiry == t0.addingTimeInterval(2))

        stack.insert(hud, at: t0.addingTimeInterval(1.5))
        #expect(stack.nextExpiry == t0.addingTimeInterval(3.5))
        // And the restart must not have expired it in the meantime.
        #expect(stack.removeExpired(at: t0.addingTimeInterval(2.5)) == ActivityChange.none)
        #expect(stack.presented?.id == "hud")
    }

    /// An absolute deadline is absolute. A timer ending at 3:45 must not slide forward every time
    /// its remaining-time content is updated.
    @Test("an absolute expiry survives an update")
    func absoluteExpirySurvivesUpdate() {
        var stack = ActivityStack()
        let deadline = t0.addingTimeInterval(10)
        stack.insert(TestActivity("timer", expiry: .at(deadline)), at: t0)
        stack.insert(TestActivity("timer", expiry: .at(deadline), title: "9"), at: t0.addingTimeInterval(1))

        #expect(stack.nextExpiry == deadline)
    }

    /// A priority change has to reorder immediately. Now Playing going from ambient to prominent
    /// when the user hits play is the case this exists for.
    @Test("an update that changes priority reorders the stack")
    func updateCanChangePriority() {
        var stack = ActivityStack()
        stack.insert(TestActivity("np", priority: .ambient), at: t0)
        stack.insert(TestActivity("banner", priority: .prominent), at: t0)
        #expect(stack.presented?.id == "banner")

        let change = stack.insert(TestActivity("np", priority: .interrupting), at: t0)
        #expect(change == .swapped(from: "banner", to: "np"))
    }
}

@Suite("Activity stack — expiry")
struct ActivityExpiryTests {

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    @Test("a relative expiry resolves against the insertion instant")
    func relativeDeadline() {
        #expect(ActivityExpiry.never.deadline(from: t0) == nil)
        #expect(ActivityExpiry.after(.seconds(3)).deadline(from: t0) == t0.addingTimeInterval(3))
        #expect(ActivityExpiry.after(.milliseconds(1500)).deadline(from: t0) == t0.addingTimeInterval(1.5))
        #expect(ActivityExpiry.at(t0).deadline(from: t0.addingTimeInterval(-99)) == t0)
    }

    @Test("nothing expires before its deadline")
    func notEarly() {
        var stack = ActivityStack()
        stack.insert(TestActivity("hud", expiry: .after(.seconds(2))), at: t0)

        #expect(stack.removeExpired(at: t0.addingTimeInterval(1.999)) == ActivityChange.none)
        #expect(stack.count == 1)
        #expect(stack.removeExpired(at: t0.addingTimeInterval(2)) == .dismissed("hud"))
        #expect(stack.isEmpty)
    }

    /// The whole stack shares one deadline — the earliest — which is what lets the coordinator hold
    /// a single sleep instead of one timer per activity (§9).
    @Test("the next deadline is the earliest on the stack, regardless of order")
    func earliestDeadlineWins() {
        var stack = ActivityStack()
        stack.insert(TestActivity("late", priority: .interrupting, expiry: .after(.seconds(9))), at: t0)
        stack.insert(TestActivity("soon", priority: .ambient, expiry: .after(.seconds(1))), at: t0)
        stack.insert(TestActivity("forever", priority: .prominent, expiry: .never), at: t0)

        // "soon" is at the bottom of the priority order and still owns the deadline.
        #expect(stack.presented?.id == "late")
        #expect(stack.nextExpiry == t0.addingTimeInterval(1))
    }

    /// Deliberate, and worth pinning down because the alternative is defensible: an expiry says
    /// when the *information* goes stale, not how much screen time the island owes it. A five
    /// second old banner surfacing after a HUD clears is indistinguishable from a fresh one.
    @Test("queued activities expire on the same clock as the presented one")
    func queuedActivitiesExpire() {
        var stack = ActivityStack()
        stack.insert(TestActivity("banner", priority: .prominent, expiry: .after(.seconds(5))), at: t0)
        stack.insert(TestActivity("hud", priority: .interrupting, expiry: .after(.seconds(1.5))), at: t0)
        #expect(stack.presented?.id == "hud")

        // Six seconds later both deadlines have passed; the banner does not get a fresh five.
        #expect(stack.removeExpired(at: t0.addingTimeInterval(6)) == .dismissed("hud"))
        #expect(stack.isEmpty)
    }

    /// The stage clearing by expiry has to promote whatever was queued, in one step — a `.dismissed`
    /// followed by a `.presented` would make the island close and reopen.
    @Test("an expiry that clears the stage promotes the queue in one change")
    func expiryDrainsTheQueue() {
        var stack = ActivityStack()
        stack.insert(TestActivity("music", priority: .ambient, expiry: .never), at: t0)
        stack.insert(TestActivity("hud", priority: .interrupting, expiry: .after(.seconds(1.5))), at: t0)

        let change = stack.removeExpired(at: t0.addingTimeInterval(1.5))
        #expect(change == .swapped(from: "hud", to: "music"))
        #expect(stack.presented?.id == "music")
        #expect(stack.nextExpiry == nil)
    }

    /// Several deadlines landing on the same instant must resolve to one change, not one per entry.
    @Test("simultaneous expiries collapse into a single change")
    func simultaneousExpiries() {
        var stack = ActivityStack()
        stack.insert(TestActivity("a", priority: .prominent, expiry: .after(.seconds(1))), at: t0)
        stack.insert(TestActivity("b", priority: .standard, expiry: .after(.seconds(1))), at: t0)
        stack.insert(TestActivity("c", priority: .ambient, expiry: .after(.seconds(1))), at: t0)

        #expect(stack.removeExpired(at: t0.addingTimeInterval(1)) == .dismissed("a"))
        #expect(stack.isEmpty)
    }

    /// A Mac that slept through a deadline wakes with it long past. Everything stale must go at
    /// once rather than one deadline per turn of the run loop.
    @Test("a long jump forward expires everything stale at once")
    func wakeFromSleep() {
        var stack = ActivityStack()
        stack.insert(TestActivity("hud", priority: .interrupting, expiry: .after(.seconds(1.5))), at: t0)
        stack.insert(TestActivity("banner", priority: .prominent, expiry: .after(.seconds(5))), at: t0)
        stack.insert(TestActivity("music", priority: .ambient, expiry: .never), at: t0)

        #expect(stack.removeExpired(at: t0.addingTimeInterval(8 * 3600)) == .swapped(from: "hud", to: "music"))
        #expect(stack.entries.map(\.id) == ["music"])
    }
}
