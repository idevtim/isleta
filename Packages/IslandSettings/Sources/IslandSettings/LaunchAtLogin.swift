import IslandKit
import AppKit
import ServiceManagement

/// Start Isleta when the user logs in, via `SMAppService.mainApp`.
///
/// Verified against the macOS 26.5 SDK before use: `SMAppService` is declared in
/// `ServiceManagement/SMAppService.h` with `API_AVAILABLE(macos(13.0))`, exposing the class property
/// `mainApp` (`mainAppService`), `register()`, `unregister()`, the `status` property, and
/// `openSystemSettingsLoginItems()`. Isleta's deployment target is 26.0, so no availability check is
/// needed and none is written — a `#available` guard that can never be false is noise that hides the
/// ones that matter.
///
/// Deliberately *not* the older `SMLoginItemSetEnabled`, which needs a separate helper app inside
/// `Contents/Library/LoginItems`. `mainApp` registers the app itself, which is what an agent app
/// with no helper actually wants.
///
/// This state is not mirrored into `IsletaConfiguration`. It is the system's, the user can change it
/// in System Settings while Isleta is not running, and a stored copy would be wrong from that moment
/// on — with Isleta then either disagreeing with System Settings or re-registering something the
/// user had just turned off.
@MainActor
public enum LaunchAtLogin {

    /// What the system says, mapped to what the UI has to say about it.
    ///
    /// There is deliberately no "unavailable" case. Whether the signature is good enough is not
    /// knowable from `status` — see `state(for:)` — and only `register()` can answer it, which is
    /// why that failure is reported as an error on the attempt rather than as a disabled switch.
    public enum State: Equatable, Sendable {
        /// Registered and eligible to run at login.
        case enabled

        /// Not registered: the login item is off, and asking for it is expected to work.
        case disabled

        /// Registered, but the user has to allow it in System Settings › General › Login Items.
        /// This is also what a revoked approval looks like, which is why the UI offers a way there
        /// rather than just showing the toggle as off and inviting the user to flip it again.
        case requiresApproval
    }

    /// Maps the system's four-valued status onto the three states the UI can draw.
    ///
    /// **`.notFound` means "never registered", not "cannot register"** — measured on macOS 27.0
    /// (26A5416b) with a Developer ID signed, notarized probe app in `/Applications` and again with
    /// an ad-hoc signed copy run from a scratch directory. Both reported `.notFound` before their
    /// first `register()`, both registered successfully, and both then reported `.notRegistered`
    /// after `unregister()`. So the two "off" answers are distinguished only by whether a Background
    /// Task Management record has ever existed for the bundle, and `.notFound` is precisely the
    /// state of every fresh install.
    ///
    /// Reading it as "this copy is not code signed" — which the header's "an error occurred and no
    /// such service could be found" invites, and which the ad-hoc debug build's behavior appears to
    /// confirm — leaves the switch dead for exactly the users who have never used it. That shipped
    /// in 1.0.0. The tell that it was a misreading is that the ad-hoc build registers fine too: no
    /// status value on this OS reports a signature problem, and `register()` is the only call that
    /// can, with `kSMErrorInvalidSignature`.
    static func state(for status: SMAppService.Status) -> State {
        switch status {
        case .enabled: .enabled
        case .notRegistered, .notFound: .disabled
        case .requiresApproval: .requiresApproval
        @unknown default: .disabled
        }
    }

    public static var state: State {
        state(for: SMAppService.mainApp.status)
    }

    /// Whether the login item is doing anything. `.requiresApproval` reads as on, because the user
    /// asked for it and the remaining step is theirs, not ours.
    public static var isEnabled: Bool {
        switch state {
        case .enabled, .requiresApproval: true
        case .disabled: false
        }
    }

    /// Registers or unregisters the login item.
    ///
    /// Throws rather than returning a `Bool`. The failures here are ones the user can act on —
    /// an unsigned build, a denial, an already-registered service — and a discarded `false` would
    /// leave a toggle that flips back with no explanation, which is exactly the kind of silent
    /// failure §12 is about.
    public static func set(_ enabled: Bool) throws {
        let verb = enabled ? "register" : "unregister"
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            IslandLog.settings.info("launch at login: \(verb)ed, status now \(state(for: SMAppService.mainApp.status))")
        } catch {
            IslandLog.settings.error("launch at login: could not \(verb): \(error)")
            throw error
        }
    }

    /// Turns a `register()`/`unregister()` failure into something a person can act on.
    ///
    /// The codes are `SMErrors.h`'s: 3 is `kSMErrorInvalidSignature`, 11 `kSMErrorLaunchDeniedByUser`,
    /// 12 `kSMErrorAlreadyRegistered`, 6 `kSMErrorJobNotFound`. The last two are the system and
    /// Isleta already agreeing about the outcome, so they are not worth a red line under the switch;
    /// `explanation(for:)` returns nil and the caller re-reads `state` instead.
    static func explanation(for error: Error, enabling: Bool) -> String? {
        let error = error as NSError
        switch error.code {
        case 3:
            return settingsText("startup.error.unsigned", """
                Isleta can’t be launched at login because this copy isn’t signed. Reinstall it from \
                tryisleta.com.
                """)
        case 11:
            return settingsText(
                "startup.error.denied",
                "macOS declined. Allow Isleta in System Settings › General › Login Items."
            )
        case 6, 12:
            return nil
        default:
            // Two keys rather than one sentence with an "enable/disable" argument in the middle: a
            // language whose verb agrees with nothing here would still have to inflect the rest of
            // the sentence around it, and a bare verb handed in as `%@` cannot be inflected at all.
            return enabling
                ? settingsText(
                    "startup.error.enable",
                    "Could not enable launch at login: \(error.localizedDescription)"
                )
                : settingsText(
                    "startup.error.disable",
                    "Could not disable launch at login: \(error.localizedDescription)"
                )
        }
    }

    /// Opens System Settings › General › Login Items, for the `.requiresApproval` case where the
    /// remaining step is the user's.
    public static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
