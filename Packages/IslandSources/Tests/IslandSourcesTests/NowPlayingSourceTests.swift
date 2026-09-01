import Foundation
import IslandActivities
import Testing

@testable import IslandSources

@Suite("Now Playing — the source")
@MainActor
struct NowPlayingSourceTests {

    private static func track(_ title: String, playing: Bool = true) -> NowPlayingUpdate {
        .snapshot(NowPlayingSnapshot(title: title, artist: "Prznt", isPlaying: playing))
    }

    // MARK: - Identity

    /// A track change is an *update of one logical activity*, not a new one. Under a fresh id per
    /// track the coordinator would see unrelated activities arriving and the island would re-enter
    /// from nothing on every skip — §6.2's `expand` spring where it wants `contentSwap`.
    @Test("every track carries the same activity id")
    func identityIsStableAcrossTracks() {
        let provider = FakeNowPlayingProvider()
        let source = NowPlayingSource(provider: provider)
        var ids: [ActivityID] = []
        source.onActivity = { ids.append($0.id) }
        source.start()

        provider.emit(Self.track("Alone"))
        provider.emit(Self.track("Second"))
        provider.emit(Self.track("Second", playing: false))

        #expect(ids.count == 3)
        #expect(Set(ids).count == 1)
        #expect(ids.first == NowPlayingSource.activityID)
        #expect(ids.first == ActivityKind.nowPlaying.singletonID)
    }

    @Test("the activity carries the track and the right kind")
    func activityContent() throws {
        let provider = FakeNowPlayingProvider()
        let source = NowPlayingSource(provider: provider)
        var activities: [any IslandActivity] = []
        source.onActivity = { activities.append($0) }
        source.start()

        provider.emit(
            .snapshot(
                NowPlayingSnapshot(
                    title: "Alone",
                    artist: "Prznt",
                    album: "Alone - Single",
                    isPlaying: true
                )
            )
        )

        let activity = try #require(activities.first)
        #expect(activity.kind == .nowPlaying)
        // Ambient, so anything else takes the stage from it and it comes back when the stage clears.
        #expect(activity.priority == .ambient)
        // Nothing about the passage of time makes "this is playing" false; the source removes it.
        #expect(activity.expiry == .never)
        #expect(activity.presentations.expanded.title == "Alone")
        #expect(activity.presentations.expanded.subtitle == "Prznt — Alone - Single")
    }

    // MARK: - Dismissal

    @Test("a clear dismisses the activity that was presented")
    func clearDismisses() {
        let provider = FakeNowPlayingProvider()
        let source = NowPlayingSource(provider: provider)
        var dismissed: [ActivityID] = []
        source.onActivity = { _ in }
        source.onDismiss = { dismissed.append($0) }
        source.start()

        provider.emit(Self.track("Alone"))
        provider.emit(.cleared)

        #expect(dismissed == [NowPlayingSource.activityID])
    }

    /// A provider may report `.cleared` for a player that was never presented — the scripting route
    /// does exactly that whenever a non-owning player stops. Forwarding it would call `onDismiss`
    /// for an id the coordinator has never seen.
    @Test("a clear with nothing presented dismisses nothing")
    func clearWithoutPresentationIsSilent() {
        let provider = FakeNowPlayingProvider()
        let source = NowPlayingSource(provider: provider)
        var dismissed: [ActivityID] = []
        source.onDismiss = { dismissed.append($0) }
        source.start()

        provider.emit(.cleared)
        #expect(dismissed.isEmpty)
    }

    @Test("a second clear does not dismiss twice")
    func repeatedClearDismissesOnce() {
        let provider = FakeNowPlayingProvider()
        let source = NowPlayingSource(provider: provider)
        var dismissed: [ActivityID] = []
        source.onActivity = { _ in }
        source.onDismiss = { dismissed.append($0) }
        source.start()

        provider.emit(Self.track("Alone"))
        provider.emit(.cleared)
        provider.emit(.cleared)

        #expect(dismissed.count == 1)
    }

    // MARK: - Lifecycle

    /// Without this, switching Now Playing off in IslandSettings would tear the provider down and
    /// leave the track pinned to the stack with nothing alive to remove it — an ambient activity
    /// that outlives its source is one the island can never get back to `.rest` from.
    @Test("stop dismisses whatever it was showing")
    func stopDismisses() {
        let provider = FakeNowPlayingProvider()
        let source = NowPlayingSource(provider: provider)
        var dismissed: [ActivityID] = []
        source.onActivity = { _ in }
        source.onDismiss = { dismissed.append($0) }
        source.start()

        provider.emit(Self.track("Alone"))
        source.stop()

        #expect(dismissed == [NowPlayingSource.activityID])
        #expect(provider.stopCount == 1)
    }

    @Test("stop with nothing showing dismisses nothing")
    func stopWithoutPresentationIsSilent() {
        let provider = FakeNowPlayingProvider()
        let source = NowPlayingSource(provider: provider)
        var dismissed: [ActivityID] = []
        source.onDismiss = { dismissed.append($0) }
        source.start()
        source.stop()

        #expect(dismissed.isEmpty)
    }

    /// `ActivitySource.start()` is documented as idempotent: the controller rebuilds on display
    /// changes, and a source started twice must not double-publish.
    @Test("start is idempotent")
    func startIsIdempotent() {
        let provider = FakeNowPlayingProvider()
        let source = NowPlayingSource(provider: provider)
        source.start()
        source.start()
        #expect(provider.startCount == 1)
    }

    @Test("stop is idempotent and safe before start")
    func stopIsIdempotent() {
        let provider = FakeNowPlayingProvider()
        let source = NowPlayingSource(provider: provider)
        source.stop()
        #expect(provider.stopCount == 0)

        source.start()
        source.stop()
        source.stop()
        #expect(provider.stopCount == 1)
    }

    /// The provider outlives the source, so a callback left attached would hold a strong reference
    /// back to it — and would keep publishing into a source the app believes is shut down.
    @Test("after stop the provider can no longer publish")
    func stopDetachesTheCallback() {
        let provider = FakeNowPlayingProvider()
        let source = NowPlayingSource(provider: provider)
        var activities = 0
        source.onActivity = { _ in activities += 1 }
        source.start()
        source.stop()

        provider.emit(Self.track("Alone"))
        #expect(activities == 0)
    }

    @Test("stop then start works again")
    func restartWorks() {
        let provider = FakeNowPlayingProvider()
        let source = NowPlayingSource(provider: provider)
        var activities = 0
        source.onActivity = { _ in activities += 1 }

        source.start()
        source.stop()
        source.start()
        provider.emit(Self.track("Alone"))

        #expect(activities == 1)
        #expect(provider.startCount == 2)
    }

    // MARK: - Denied

    /// §10's requirement, stated as a test: with the null provider the app is *whole*. Not "shows an
    /// empty Now Playing card" — Now Playing is simply not among the activities, and everything else
    /// behaves as though this milestone had never shipped.
    @Test("with the null provider the source is inert and the island is untouched")
    func nullProviderIsInert() {
        let source = NowPlayingSource(provider: NullNowPlayingProvider())
        var activities = 0
        var dismissals = 0
        source.onActivity = { _ in activities += 1 }
        source.onDismiss = { _ in dismissals += 1 }

        source.start()
        source.stop()

        // No placeholder activity. One would sit at `.ambient` forever, and because everything
        // outranks ambient the stack would never empty — an island that can never reach `.rest`.
        #expect(activities == 0)
        // And no dismissal for something that was never presented.
        #expect(dismissals == 0)
    }

    @Test("the null provider explains what granting would unlock, in the user's terms")
    func nullProviderExplains() {
        let source = NowPlayingSource(provider: NullNowPlayingProvider())
        guard case .denied(let explanation) = source.authorization else {
            Issue.record("expected .denied, got \(source.authorization)")
            return
        }
        #expect(!explanation.isEmpty)
        // Says where to go and what is gained; names nothing the user has not heard of.
        #expect(explanation.contains("System Settings"))
        #expect(!explanation.lowercased().contains("mediaremote"))
        #expect(!explanation.lowercased().contains("adapter"))
        #expect(!explanation.lowercased().contains("sip"))
    }

    /// The source reports its provider's verdict unmodified. A source that softened it into
    /// something more comfortable would be one whose settings row cannot be trusted.
    @Test("authorization is the provider's, verbatim")
    func authorizationPassesThrough() {
        let provider = FakeNowPlayingProvider()
        let source = NowPlayingSource(provider: provider)

        provider.authorization = .notRequired
        #expect(source.authorization == .notRequired)

        provider.authorization = .denied(explanation: "because")
        #expect(source.authorization == .denied(explanation: "because"))
        #expect(source.authorization.isUsable == false)
    }

    // MARK: - Route selection

    /// One route at a time. Running the adapter and the scripting fallback together looks like belt
    /// and braces and is a bug: both report the same track through different mechanisms with
    /// different timing, so every play publishes twice and every disagreement between them shows as
    /// the island flipping between two answers.
    ///
    /// This checkout has no vendored adapter, so the convenience initializer must land on scripting.
    @Test("with no adapter vendored the source selects the scripting route")
    func routeSelectionFallsBack() {
        let source = NowPlayingSource(bundle: .main)
        #expect(source.provider is NowPlayingScriptProvider)
        #expect(type(of: source.provider).providerName == NowPlayingScriptProvider.providerName)
    }

    @Test("the source names itself for diagnostics and settings")
    func sourceName() {
        #expect(NowPlayingSource.sourceName == "Now Playing")
    }
}
