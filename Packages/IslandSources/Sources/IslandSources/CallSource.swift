import AppKit
import Foundation
import IslandActivities
import IslandKit

/// Whether a set of recording processes is a **call**, as opposed to a recording.
///
/// Pure, and the whole of the honesty of this feature. The microphone running is not a call: on
/// this machine, cold, with nobody talking to anybody, `com.apple.CoreSpeech` was already running
/// input — Siri's listener — and Voice Memos, Dictation, QuickTime and a screen recording with audio
/// are all indistinguishable from a conference call at the CoreAudio layer.
///
/// So the island only says "call" for an app whose whole purpose is calls. The cost of the list is
/// stated rather than hidden: **a call in a browser tab is not shown**, because Google Meet in
/// Chrome is `com.google.Chrome` recording, which is the same thing a webcam test page is. That is
/// the honest answer to an unanswerable question, and it is better than an island that says a user
/// is on a call because a website asked for their microphone.
public enum CallDetection {

    /// Apps whose microphone means a call. FaceTime's daemon is in the list because FaceTime's
    /// audio runs through `avconferenced` rather than through the app.
    public static let conferencingIdentifiers: Set<String> = [
        "com.apple.FaceTime",
        "com.apple.avconferenced",
        "com.apple.identityservicesd",
        "us.zoom.xos",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "com.cisco.webexmeetingsapp",
        "Cisco-Systems.Spark",
        "net.whatsapp.WhatsApp",
        "com.skype.skype",
        "org.whispersystems.signal-desktop",
        "ru.keepcoder.Telegram",
        "com.facebook.archon.developerID",
    ]

    /// The first recording process that is a calling app, or nil.
    ///
    /// Returns the identifier rather than a `Bool` so the caller can put the app's own name and icon
    /// on the island. Who is *calling* is not readable by anybody outside Apple (§7); which app the
    /// call is in plainly is, and withholding it would make the island less useful for no gain.
    public static func callingIdentifier(among identifiers: [String]) -> String? {
        identifiers.first { conferencingIdentifiers.contains($0) }
    }
}

/// A call in progress — the one part of the competitor's Calls feature that can honestly be built.
///
/// # What this is not
///
/// There is no answer, no decline, no mute, no caller name and no caller photo, and none of them is
/// missing for want of effort: they are behind `com.apple.telephonyutilities.callservicesd`, an
/// entitlement Apple issues to FaceTime. `docs/PLATFORM-CONSTRAINTS.md` has the measurements and
/// the daemon's own log line refusing us. There is also deliberately no "call spectrum": drawing a live
/// waveform of a call means tapping the call's audio, which is a microphone grant and a recording of
/// the other party, and is not something to ship whether or not it is possible.
///
/// What is left is ungated, push-driven, and genuinely useful: a chip saying a call is happening,
/// in which app, and for how long — the same discipline as the AirPods ring, which shows what can be
/// known once and does not invent a way to keep it current.
///
/// # The retraction this source owes
///
/// `ActivityKind.call` is the one 2.0 kind that both **opens the island** and has `.never` expiry —
/// pinned by a test in `BuiltInActivityTests`, which spells out the price: if the source that raised
/// a call ever fails to retract it, the island is stuck open. So the retraction is on every path
/// out of this file — the falling edge, `stop()`, `stopAndWait()`, and the input device going away —
/// and `live` is the single piece of state all four go through.
///
/// # Nothing here polls
///
/// The device edge is a CoreAudio property listener (105 ms behind a real capture) and the process
/// list is read **on that edge only**, because enumerating it costs 39 ms. The elapsed time on
/// screen is an `ActivityValue.elapsed(since:)`, which IslandUI evaluates against the display link
/// it already runs — so a two-hour call publishes one activity, not 7,200.
@MainActor
public final class CallSource: ActivitySource {

    public static let sourceName = "Calls"

    /// Nothing to ask for, and nothing that *could* be asked for: the microphone is never opened
    /// here. `kAudioDevicePropertyDeviceIsRunningSomewhere` and the process-object list are
    /// metadata about the audio system, not audio, and both answer an unentitled, unprompted app.
    public var authorization: SourceAuthorization { .notRequired }

    public var onActivity: ((any IslandActivity) -> Void)?
    public var onDismiss: ((ActivityID) -> Void)?

    public private(set) var isRunning = false

    private let observer: any CallAudioObserving
    private let now: () -> Date

    /// The call on the island, if there is one. One at a time: CoreAudio reports that the input is
    /// running, not how many conversations are happening in it.
    private var live: (id: ActivityID, identifier: String)?

    /// How many calls have been shown this launch. A count — which app somebody calls their family
    /// in is not something to put in a file that gets emailed.
    public private(set) var publishedCount = 0

    public init(
        observer: any CallAudioObserving = CoreAudioCallObserver(),
        now: @escaping () -> Date = Date.init
    ) {
        self.observer = observer
        self.now = now
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        observer.onChange = { [weak self] activity in
            self?.receive(activity)
        }
        observer.start()
        IslandLog.audio.info("call: started")
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        observer.stop()
        // The obligation in one line. A `.call` activity never expires, so a source that stopped
        // without retracting would leave the island open with a timer counting a call that ended
        // when the user switched this off.
        retract()
        IslandLog.audio.info("call: stopped")
    }

    /// Everything here is synchronous — the listener blocks are removed on this call and the
    /// retraction is delivered before it returns — so `stop()` already carries `stopAndWait()`'s
    /// promise. Spelled out rather than inherited because of what this source in particular leaves
    /// behind if it is wrong: an island that is open, on top of the user's screen, on the way out.
    public func stopAndWait() { stop() }

    /// Fold in one reading. The seam the tests drive: every path — a call starting, ending, a
    /// recording that is not a call, and the teardown retraction — is reachable from here with no
    /// microphone and no call.
    func receive(_ activity: CallInputActivity) {
        guard isRunning else { return }
        guard activity.isInputRunning,
              let identifier = CallDetection.callingIdentifier(among: activity.bundleIdentifiers)
        else {
            retract()
            return
        }
        // Already on stage, and from the same app: nothing to say. Republishing would restart the
        // elapsed timer, so a second capture starting inside the same call would reset the clock
        // the user is reading.
        if let live, live.identifier == identifier { return }

        retract()
        let id = ActivityID("builtin.call.\(identifier)")
        live = (id: id, identifier: identifier)
        publishedCount += 1
        // The app is named on the island and **not** in the log: which app somebody takes calls in
        // is theirs. That a call was shown at all is what a bug report needs.
        IslandLog.audio.info("call: a call is in progress")
        onActivity?(BuiltInActivity.call(
            id: id,
            applicationName: Self.applicationName(for: identifier),
            since: now()
        ))
    }

    private func retract() {
        guard let live else { return }
        self.live = nil
        onDismiss?(live.id)
    }

    /// The app's display name, or nil if it is not on this disk.
    ///
    /// Nil for `avconferenced`, which is a daemon rather than an app — so a FaceTime call falls back
    /// to the generic sentence rather than putting a daemon's name on the island.
    private static func applicationName(for identifier: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
        else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

public extension BuiltInActivity {

    /// A call in progress: an app, and how long it has been going.
    ///
    /// Declared in IslandSources for the reason `BuiltInActivity.power(_:state:)` gives — 2.0's
    /// parity work adds no members to the shared structs in IslandActivities.
    ///
    /// The elapsed time is an `ActivityValue.elapsed(since:)` rather than a formatted string, which
    /// is the difference between one activity and one per second: IslandUI draws the numerals from
    /// the display link it is already running, and this source publishes once and then says nothing
    /// until the call ends.
    static func call(id: ActivityID, applicationName: String?, since: Date) -> Self {
        // The app's name is macOS's — `FileManager.displayName(atPath:)` has already localized it —
        // so it travels as an argument and never through a table. The sentence around it is Isleta's.
        let title = applicationName ?? sourceText("call.title", "Call")
        let value = ActivityValue.elapsed(since: since)
        let spoken = applicationName.map { sourceText("call.a11y.inApp", "Call in progress in \($0)") }
            ?? sourceText("call.inProgress", "Call in progress")
        return Self(
            id: id,
            kind: .call,
            presentations: ActivityPresentations(
                leading: ActivityContent(
                    symbol: "phone.fill",
                    applicationIconName: applicationName,
                    tint: .positive,
                    accessibilityLabel: spoken
                ),
                trailing: ActivityContent(value: value, tint: .positive),
                compact: ActivityContent(
                    symbol: "phone.fill",
                    applicationIconName: applicationName,
                    title: title,
                    value: value,
                    tint: .positive
                ),
                expanded: ActivityContent(
                    symbol: "phone.fill",
                    applicationIconName: applicationName,
                    title: title,
                    subtitle: sourceText("call.inProgress", "Call in progress"),
                    value: value,
                    tint: .positive,
                    accessibilityLabel: spoken
                )
            )
        )
    }
}
