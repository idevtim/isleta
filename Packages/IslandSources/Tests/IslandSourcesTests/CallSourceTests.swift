import Foundation
import IslandActivities
import Testing

@testable import IslandSources

/// An observer with no CoreAudio behind it, so every path — a call starting, a recording that is
/// not a call, the call ending, and the teardown retraction — is reachable without a microphone.
@MainActor
private final class StubCallObserver: CallAudioObserving {
    var onChange: ((CallInputActivity) -> Void)?
    private(set) var isRunning = false

    func start() { isRunning = true }
    func stop() { isRunning = false }
    func fire(_ activity: CallInputActivity) { onChange?(activity) }
}

@Suite("Calls")
@MainActor
struct CallSourceTests {

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    private func source(_ observer: StubCallObserver) -> CallSource {
        CallSource(observer: observer, now: { self.t0 })
    }

    /// The microphone running is not a call, and this machine proves it: read cold, with nobody
    /// talking to anybody, CoreAudio reported `com.apple.CoreSpeech` running input — Siri's
    /// listener. A source that took the process list as the signal would announce a call for ever.
    @Test("a recording that is not a call publishes nothing")
    func recordingIsNotACall() {
        let observer = StubCallObserver()
        let source = source(observer)
        var published: [any IslandActivity] = []
        source.onActivity = { published.append($0) }
        source.start()

        observer.fire(CallInputActivity(
            isInputRunning: true,
            bundleIdentifiers: ["com.apple.CoreSpeech", "com.apple.VoiceMemos", "com.apple.QuickTimePlayerX"]
        ))
        #expect(published.isEmpty)
        #expect(source.publishedCount == 0)
    }

    @Test("a call in a calling app publishes one activity with a running clock")
    func callPublishes() {
        let observer = StubCallObserver()
        let source = source(observer)
        var published: [any IslandActivity] = []
        source.onActivity = { published.append($0) }
        source.start()

        observer.fire(CallInputActivity(isInputRunning: true, bundleIdentifiers: ["us.zoom.xos"]))
        #expect(published.count == 1)
        #expect(published.first?.kind == .call)
        // An elapsed *value*, not a formatted string: IslandUI draws the numerals off the display
        // link it already runs, so a two-hour call publishes one activity rather than 7,200.
        #expect(published.first?.presentations.trailing.value == .elapsed(since: t0))
    }

    /// The obligation `BuiltInActivityTests` pins: `.call` opens the island and never expires, so a
    /// source that fails to retract leaves the island stuck open.
    @Test("the call ending retracts it")
    func callEndingRetracts() {
        let observer = StubCallObserver()
        let source = source(observer)
        var dismissed: [ActivityID] = []
        source.onActivity = { _ in }
        source.onDismiss = { dismissed.append($0) }
        source.start()

        observer.fire(CallInputActivity(isInputRunning: true, bundleIdentifiers: ["us.zoom.xos"]))
        observer.fire(CallInputActivity(isInputRunning: false))
        #expect(dismissed == [ActivityID("builtin.call.us.zoom.xos")])
    }

    /// The same obligation on the path that has no "later": teardown returns into `exit()`.
    @Test("teardown retracts a call that is still in progress")
    func teardownRetracts() {
        let observer = StubCallObserver()
        let source = source(observer)
        var dismissed: [ActivityID] = []
        source.onActivity = { _ in }
        source.onDismiss = { dismissed.append($0) }
        source.start()

        observer.fire(CallInputActivity(isInputRunning: true, bundleIdentifiers: ["com.apple.FaceTime"]))
        source.stopAndWait()
        #expect(dismissed == [ActivityID("builtin.call.com.apple.FaceTime")])
        #expect(observer.isRunning == false)
    }

    /// A second capture starting inside one call — a screen share, a second device — must not
    /// republish, because republishing restarts the clock the user is reading.
    @Test("a call already on stage is not republished")
    func callIsNotRepublished() {
        let observer = StubCallObserver()
        let source = source(observer)
        var published: [any IslandActivity] = []
        source.onActivity = { published.append($0) }
        source.start()

        observer.fire(CallInputActivity(isInputRunning: true, bundleIdentifiers: ["us.zoom.xos"]))
        observer.fire(CallInputActivity(isInputRunning: true, bundleIdentifiers: ["us.zoom.xos"]))
        observer.fire(CallInputActivity(
            isInputRunning: true, bundleIdentifiers: ["us.zoom.xos", "com.apple.CoreSpeech"]
        ))
        #expect(published.count == 1)
    }

    /// Switching app mid-session is a different call: the first is retracted before the second is
    /// raised, so the island never holds two.
    @Test("a call in a different app replaces the first")
    func differentAppReplaces() {
        let observer = StubCallObserver()
        let source = source(observer)
        var published: [any IslandActivity] = []
        var dismissed: [ActivityID] = []
        source.onActivity = { published.append($0) }
        source.onDismiss = { dismissed.append($0) }
        source.start()

        observer.fire(CallInputActivity(isInputRunning: true, bundleIdentifiers: ["us.zoom.xos"]))
        observer.fire(CallInputActivity(isInputRunning: true, bundleIdentifiers: ["com.apple.FaceTime"]))
        #expect(published.count == 2)
        #expect(dismissed == [ActivityID("builtin.call.us.zoom.xos")])
    }

    /// The input running with an empty process list — which is what a device that reports running
    /// but names nobody looks like — is not a call either. "Something is recording" is not the
    /// sentence this feature promises.
    @Test("an anonymous capture is not a call")
    func anonymousCaptureIsNotACall() {
        let observer = StubCallObserver()
        let source = source(observer)
        var published: [any IslandActivity] = []
        source.onActivity = { published.append($0) }
        source.start()

        observer.fire(CallInputActivity(isInputRunning: true, bundleIdentifiers: []))
        #expect(published.isEmpty)
    }

    @Test("the detection list picks the calling app out of everything else recording")
    func detection() {
        #expect(CallDetection.callingIdentifier(among: ["com.apple.CoreSpeech", "us.zoom.xos"]) == "us.zoom.xos")
        #expect(CallDetection.callingIdentifier(among: ["com.apple.VoiceMemos"]) == nil)
        // A call in a browser tab is deliberately not detectable: Google Meet in Chrome is
        // `com.google.Chrome` recording, which is the same thing a webcam test page is.
        #expect(CallDetection.callingIdentifier(among: ["com.google.Chrome"]) == nil)
    }

    /// Nothing here is asked of the user, and nothing can be: the microphone is never opened.
    @Test("calls need no permission and no microphone")
    func needsNothingGranted() {
        let source = source(StubCallObserver())
        #expect(source.authorization == .notRequired)
    }
}
