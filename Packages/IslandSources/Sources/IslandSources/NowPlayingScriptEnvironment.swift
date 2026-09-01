import AppKit
import CoreServices
import Foundation
import IslandActivities
import IslandKit

/// The deep link into Automation, beside the code that knows why it is needed.
///
/// Same arrangement as `BluetoothPrivacySettings`, `GlancePrivacySettings`, `FocusPrivacySettings`
/// and `AccessibilityPrivacySettings`: the URL lives next to the permission rather than in a table
/// of strings somewhere central, so the one that breaks is the one you are already reading.
///
/// **Only worth offering once Isleta is in the list**, which it is not until it has asked at least
/// once — the Automation pane enumerates apps that have requested, not apps that might. Offering it
/// to somebody who has never been asked sends them to a pane Isleta does not appear in, which reads
/// as the app being broken. `SourceHub.onboardingState()` therefore offers it only for `.denied`.
public enum AutomationPrivacySettings {
    public static let settingsURLString =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
}

/// Everything `NowPlayingScriptProvider` needs from the machine, behind one seam.
///
/// Injected so the provider is testable with no player installed, no Automation permission decided,
/// and no process spawned. That matters more here than anywhere else in this package, because the
/// states worth testing are precisely the ones a developer's Mac will not be in: the permission
/// refused, the permission never asked, the player quitting halfway through a track. Waiting for a
/// machine in those states means never testing them.
@MainActor
public protocol NowPlayingScriptEnvironment: AnyObject {

    /// Whether the player is running *right now*.
    ///
    /// Checked before every script, and the reason is a genuine trap: `tell application "Music" to …`
    /// **launches Music** if it is not running. AppleScript's application specifiers are
    /// launch-on-demand, so the obvious implementation of "ask the player what is playing" opens a
    /// music app on a user who was working in silence — at login, on every wake, on every display
    /// reconnect that rebuilds the sources. There is no scripting idiom that avoids this reliably;
    /// the fix is to not send the event at all unless the process already exists, which is a
    /// `NSWorkspace.runningApplications` lookup and costs nothing.
    func isRunning(_ player: NowPlayingPlayer) -> Bool

    /// Whether Isleta may send Apple events to the player, **without asking**.
    ///
    /// §10 is explicit that a permission prompt belongs to a moment the user initiated, not to
    /// launch. So this must report the current state rather than provoke one.
    func automationStatus(for player: NowPlayingPlayer) -> SourceAuthorization

    /// The same question **with** `askUserIfNeeded`, from a control the user clicked.
    ///
    /// The counterpart `automationStatus` exists to avoid, and the only reason both exist: one
    /// reports, one asks, and which is which has to be legible at the call site rather than hidden
    /// behind a `Bool` argument. §10's rule is that the asking one is reachable only from a button.
    func requestAutomation(
        for player: NowPlayingPlayer,
        completion: @escaping @MainActor (SourceAuthorization) -> Void
    )

    /// Runs the one-shot read. Asynchronous by construction, never blocking the caller.
    func readCurrentTrack(
        from player: NowPlayingPlayer,
        completion: @escaping @MainActor (NowPlayingUpdate?) -> Void
    )

    /// Reads the playing track's Favorite state. Nil for a player with no favorite of its own, a
    /// refused permission, a stopped player, or a script that failed.
    func readFavorite(
        from player: NowPlayingPlayer,
        completion: @escaping @MainActor (Bool?) -> Void
    )

    /// Writes it, waits for Music to settle, and reports what it settled on.
    ///
    /// The read-back is the point rather than politeness: `set favorited` returns before the
    /// property agrees, by something under two seconds — see `NowPlayingPlayer.favoriteWriteScript`,
    /// where the delay lives and the measurement is written down.
    func setFavorite(
        _ favorite: Bool,
        on player: NowPlayingPlayer,
        completion: @escaping @MainActor (Bool?) -> Void
    )

    /// Brings the player forward showing the playing track. No completion: there is nothing to
    /// report, and the user is about to be looking at the answer.
    func revealCurrentTrack(in player: NowPlayingPlayer)
}

/// The real one.
@MainActor
public final class NowPlayingSystemScriptEnvironment: NowPlayingScriptEnvironment {

    /// Where `osascript` runs. Off the main actor, and that is not merely good manners.
    ///
    /// An Apple event is a synchronous round trip to another process, and the timeout is measured in
    /// tens of seconds. A player that is busy — beach-balling on a slow network library, or showing
    /// a modal — does not answer, and `NSAppleScript.executeAndReturnError` on the main thread would
    /// hold the main actor for the whole wait. Isleta would stop drawing, the island would freeze
    /// mid-spring, and the cause would be an app Isleta does not control.
    private let queue = DispatchQueue(
        label: "com.tryisleta.isleta.nowplaying.script",
        qos: .utility
    )

    private let workspace: NSWorkspace

    public init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    public func isRunning(_ player: NowPlayingPlayer) -> Bool {
        workspace.runningApplications.contains { $0.bundleIdentifier == player.bundleIdentifier }
    }

    /// `AEDeterminePermissionToAutomateTarget` with `askUserIfNeeded: false`.
    ///
    /// The only supported way to read Automation state without a prompt, and its four return codes
    /// map onto `SourceAuthorization` exactly, which is the reason that enum has four cases rather
    /// than being a `Bool`:
    ///
    /// - `noErr` — granted.
    /// - `errAEEventWouldRequireUserConsent` (-1744) — never asked. `.undetermined`, so IslandSettings
    ///   can offer a prompt at a moment the user chose. Attempting the event here instead is what
    ///   makes a menu-bar app throw a TCC dialog at someone three seconds after login.
    /// - `errAEEventNotPermitted` (-1743) — refused.
    /// - `procNotFound` (-600) — the player is not running, so there is nothing to be permitted.
    ///
    /// Inferring the state by sending an event and reading the error would work and is wrong: the
    /// send *is* the prompt in the undetermined case.
    public func automationStatus(for player: NowPlayingPlayer) -> SourceAuthorization {
        var target = AEAddressDesc()
        let identifier = Array(player.bundleIdentifier.utf8)
        let created = AECreateDesc(
            AEKeyword(typeApplicationBundleID),
            identifier,
            identifier.count,
            &target
        )
        guard created == noErr else {
            return .denied(explanation: Self.explanation(for: player))
        }
        defer { AEDisposeDesc(&target) }

        let status = AEDeterminePermissionToAutomateTarget(
            &target,
            AEEventClass(typeWildCard),
            AEEventID(typeWildCard),
            false
        )

        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventWouldRequireUserConsent): return .undetermined
        case OSStatus(procNotFound): return .notRequired
        default: return .denied(explanation: Self.explanation(for: player))
        }
    }

    /// `AEDeterminePermissionToAutomateTarget` with `askUserIfNeeded: **true**`.
    ///
    /// Three things about this call are worth having written down, because each of them looks like a
    /// bug from the outside.
    ///
    /// **It blocks for as long as the dialog is up.** The call does not return until the user
    /// answers, so on the main actor it would hold the main thread for the length of a human
    /// decision — the island would freeze mid-spring behind a dialog Isleta had just raised. It
    /// therefore runs on `queue`, exactly as every script here does, and the answer comes back
    /// through the completion.
    ///
    /// **It asks only about a player that is running.** A quit app answers `procNotFound` and
    /// raises nothing; there is no permission to grant for a process that does not exist. That is
    /// why this reports the resulting `SourceAuthorization` rather than a `Bool` — `.notRequired`
    /// is the honest answer for "nothing happened, and nothing was supposed to", and the caller
    /// needs to tell it apart from a refusal.
    ///
    /// **It asks once per player, ever.** Once TCC holds an answer the call returns it immediately
    /// with no dialog, which is what makes `.denied` a dead end here and a System Settings link the
    /// only remaining offer — the same rule `SourceHub.action(for:)` already follows everywhere
    /// else.
    public func requestAutomation(
        for player: NowPlayingPlayer,
        completion: @escaping @MainActor (SourceAuthorization) -> Void
    ) {
        // Read first, on the main actor, where it costs nothing: a player that is not running has
        // no dialog to show and would otherwise buy a queue hop to learn that.
        let current = automationStatus(for: player)
        guard current == .undetermined else {
            completion(current)
            return
        }
        IslandLog.system.info("automation: prompt raised for \(player.scriptingName)")
        queue.async { [weak self] in
            var target = AEAddressDesc()
            let identifier = Array(player.bundleIdentifier.utf8)
            let created = AECreateDesc(
                AEKeyword(typeApplicationBundleID),
                identifier,
                identifier.count,
                &target
            )
            guard created == noErr else {
                Task { @MainActor in completion(.denied(explanation: Self.explanation(for: player))) }
                return
            }
            defer { AEDisposeDesc(&target) }

            _ = AEDeterminePermissionToAutomateTarget(
                &target,
                AEEventClass(typeWildCard),
                AEEventID(typeWildCard),
                true
            )
            // The *return value is deliberately discarded* and the state re-read on the main actor
            // instead. §"Measure the effect, never the return value": this call has answered `noErr`
            // for a dialog the user had not yet touched, and the authoritative answer is the one
            // `automationStatus` reads back afterwards.
            Task { @MainActor in
                guard let self else { return }
                completion(self.automationStatus(for: player))
            }
        }
    }

    public func readCurrentTrack(
        from player: NowPlayingPlayer,
        completion: @escaping @MainActor (NowPlayingUpdate?) -> Void
    ) {
        // Guarded twice on purpose. `isRunning` keeps the event from launching the player, and the
        // authorization check keeps a refused permission from spawning `osascript` once per start()
        // for a result that is known in advance to be an error.
        guard isRunning(player), automationStatus(for: player) == .granted else {
            completion(nil)
            return
        }

        let script = player.currentTrackScript
        queue.async {
            let output = Self.runOSAScript(script)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // `nil`, not `.cleared`, when the script fails. A failed read means Isleta does
                    // not know what is playing; `.cleared` would mean it knows nothing is. Reporting
                    // the second would take a perfectly good activity off the island the moment a
                    // permission was revoked mid-session.
                    guard let output else {
                        completion(nil)
                        return
                    }
                    completion(player.update(fromScriptOutput: output))
                }
            }
        }
    }

    public func readFavorite(
        from player: NowPlayingPlayer,
        completion: @escaping @MainActor (Bool?) -> Void
    ) {
        run(player.favoriteReadScript, for: player) { output in
            completion(output.flatMap { player.favorite(fromScriptOutput: $0) })
        }
    }

    public func setFavorite(
        _ favorite: Bool,
        on player: NowPlayingPlayer,
        completion: @escaping @MainActor (Bool?) -> Void
    ) {
        // One `osascript`, not two: `favoriteWriteScript` carries its own settle and read-back, so
        // the answer describes the record that was written rather than whatever is playing by the
        // time a second fork gets there.
        run(player.favoriteWriteScript(favorite), for: player, allowingPrompt: true) { output in
            completion(output.flatMap { player.favorite(fromScriptOutput: $0) })
        }
    }

    public func revealCurrentTrack(in player: NowPlayingPlayer) {
        // **`allowingPrompt`, for the same reason the star has it — and this is the second time the
        // deadlock it describes has been shipped.** A reveal happens because the user clicked the
        // song. Automation is `.undetermined` until something sends an event, the send *is* the
        // prompt, and requiring the grant first means nobody is ever asked: every click opened Music
        // at whatever it was last showing and the reveal was dead code. §10's rule is that a prompt
        // belongs to exactly the moment the user initiated, and a click on a song is one.
        run(player.revealCurrentTrackScript, for: player, allowingPrompt: true) { _ in }
    }

    /// The two guards every script in this type shares, and the hop off the main actor.
    ///
    /// **`allowingPrompt` is the difference between a control that works and one that cannot**, and
    /// the rule for setting it is not "is this a write". It is *did the user just ask for this*: a
    /// read issued off a snapshot must never prompt, and anything issued from a press, a click or a
    /// star must. Two callers have now shipped without it and been dead in the field until somebody
    /// noticed the permission dialog never appeared.
    ///
    /// `isRunning` keeps the event from launching the player — see the protocol's note, which is the
    /// trap this whole type is shaped around — and the authorization check keeps a refused
    /// permission from forking `osascript` for a result known in advance to be an error.
    private func run(
        _ script: String?,
        for player: NowPlayingPlayer,
        allowingPrompt: Bool = false,
        completion: @escaping @MainActor (String?) -> Void
    ) {
        guard let script, isRunning(player) else {
            completion(nil)
            return
        }
        // **`allowingPrompt` is what breaks a deadlock, and it is narrow on purpose.**
        //
        // Automation starts `.undetermined`, and the only thing that can move it is sending an
        // event — the send *is* the prompt. A read issued from a snapshot must never do that: it
        // would throw a TCC dialog at somebody three seconds after login, which is the whole reason
        // `automationStatus` asks with `askUserIfNeeded: false`. But a *write* only happens because
        // the user pressed the star, and §10's rule is that a prompt belongs to exactly that moment.
        //
        // Without this the star could never light: the read needs the grant, the grant needs a
        // press, and the press needs a star that is not dimmed. Shipped that way for one build.
        let status = automationStatus(for: player)
        let permitted = status == .granted || (allowingPrompt && status == .undetermined)
        guard permitted else {
            completion(nil)
            return
        }
        queue.async {
            let output = Self.runOSAScript(script)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(output) }
            }
        }
    }

    /// `osascript` in a child process rather than `NSAppleScript` in ours.
    ///
    /// `NSAppleScript` is the obvious choice and brings the Apple event machinery, the Carbon
    /// component instance and the target app's failure modes into Isleta's own address space and
    /// main thread. A child process is isolated, killable, and cannot wedge the island; the cost is
    /// one fork per read, and reads happen at `start()` and when a player launches — not on a timer.
    private nonisolated static func runOSAScript(_ source: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", source]

        let out = Pipe()
        task.standardOutput = out
        // stderr goes to /dev/null rather than to a pipe nobody drains. The failure text is a Carbon
        // error number that is no use to a user, and an undrained pipe blocks the child.
        task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            return nil
        }

        // Read before waiting. Waiting first deadlocks the moment the output exceeds the pipe
        // buffer: the child blocks writing, we block waiting, and neither moves. The output here is
        // four short fields, but "it is small today" is how that bug ships.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard task.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// §10: what the user gains, in their words, naming the exact place they would go.
    private static func explanation(for player: NowPlayingPlayer) -> String {
        // The player's name is its own — Music, Spotify — and travels as an argument.
        sourceText("nowPlaying.scripting.denied", """
            Isleta shows what’s playing as soon as you next play, pause, or change track. \
            To have it show the current track right away, allow Isleta to control \
            \(player.scriptingName) in System Settings › Privacy & Security › Automation.
            """)
    }
}
