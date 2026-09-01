import ServiceManagement
import Testing

@testable import IslandSettings

/// The status mapping only. Registering a real login item is the system's business and would leave
/// a Background Task Management record behind on whoever ran the suite.
@MainActor
@Suite("Launch at login")
struct LaunchAtLoginTests {

    /// The 1.0.0 bug, pinned. `.notFound` is what `SMAppService.mainApp` answers on a fresh install
    /// — measured on macOS 27.0 with a notarized probe *and* an ad-hoc one, both of which then
    /// registered successfully — so reading it as "unavailable" left the switch dead for exactly
    /// the users who had never used it.
    @Test("a never-registered app is off, not unavailable")
    func notFoundIsOff() {
        #expect(LaunchAtLogin.state(for: .notFound) == .disabled)
    }

    @Test("the two off answers are indistinguishable to the user")
    func offStatesAgree() {
        #expect(LaunchAtLogin.state(for: .notRegistered) == LaunchAtLogin.state(for: .notFound))
    }

    @Test("registered and approved states map straight through")
    func registeredStates() {
        #expect(LaunchAtLogin.state(for: .enabled) == .enabled)
        #expect(LaunchAtLogin.state(for: .requiresApproval) == .requiresApproval)
    }

    /// `.requiresApproval` reads as on: the user asked for it and the remaining step is theirs.
    @Test("only a disabled login item reads as off")
    func isEnabledFollowsState() {
        #expect(LaunchAtLogin.state(for: .enabled) != .disabled)
        #expect(LaunchAtLogin.state(for: .requiresApproval) != .disabled)
    }

    @Test("an unsigned build is named as such rather than reported as a raw error")
    func invalidSignatureIsExplained() {
        let error = NSError(domain: "SMAppServiceErrorDomain", code: 3)
        let message = LaunchAtLogin.explanation(for: error, enabling: true)
        #expect(message?.contains("isn’t signed") == true)
    }

    @Test("a user denial points at System Settings")
    func denialIsExplained() {
        let error = NSError(domain: "SMAppServiceErrorDomain", code: 11)
        #expect(LaunchAtLogin.explanation(for: error, enabling: true)?.contains("Login Items") == true)
    }

    /// Both mean the system already agrees with where the switch ended up; the UI re-reads `state`
    /// and needs nothing said about it.
    @Test("already-registered and job-not-found are silent")
    func agreementIsSilent() {
        #expect(LaunchAtLogin.explanation(for: NSError(domain: "SMAppServiceErrorDomain", code: 12), enabling: true) == nil)
        #expect(LaunchAtLogin.explanation(for: NSError(domain: "SMAppServiceErrorDomain", code: 6), enabling: false) == nil)
    }

    @Test("anything else still says which direction failed")
    func unknownFailureNamesTheDirection() {
        let error = NSError(domain: "SMAppServiceErrorDomain", code: 2)
        #expect(LaunchAtLogin.explanation(for: error, enabling: false)?.hasPrefix("Could not disable") == true)
    }
}
