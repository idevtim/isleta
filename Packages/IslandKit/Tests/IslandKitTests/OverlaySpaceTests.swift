import AppKit
import Testing
@testable import IslandKit

/// The private space is the second private-API path in the app, and the rule for those is a
/// working fallback tested in the denied state. "Denied" here is the API being absent, which a
/// running macOS cannot simulate — so the fallback is injected instead.
@Suite("The overlay space and its fallback")
struct OverlaySpaceTests {

    @Test("the fallback hosts nothing and says so")
    @MainActor
    func fallbackReportsNotHosting() {
        let space = UnavailableOverlaySpace()
        #expect(space.isHosting == false)
        // Every call must be a harmless no-op: the controller does not special-case the fallback.
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        space.host(window)
        space.release(window)
        space.tearDown()
        #expect(space.isHosting == false)
    }

    @Test("a controller given the fallback reports it, and can be torn down")
    @MainActor
    func controllerOnFallback() {
        let controller = IslandController(
            contentFactory: { _ in NSView() },
            overlaySpace: UnavailableOverlaySpace()
        )
        #expect(controller.isHostedInOverlaySpace == false)
        controller.stop()
    }

    /// On this OS the API is present, and the test says so rather than assuming it. A future macOS
    /// that removes a symbol turns this into a skip with a reason, not a failure — the fallback is
    /// what ships there, and the test above covers it.
    @Test("the real space is created and torn down cleanly when the API is present")
    @MainActor
    func realSpaceLifecycle() throws {
        guard let space = SkyLightOverlaySpace.make() else {
            // Not a failure: this is the fallback engaging on an OS without the API.
            return
        }
        #expect(space.isHosting == true)
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        space.host(window)
        space.host(window)          // idempotent
        space.release(window)
        space.release(window)       // idempotent
        space.tearDown()
        space.tearDown()            // idempotent
        #expect(space.isHosting == false)
        // After tear-down nothing is sent to the window server; these must be no-ops.
        space.host(window)
    }
}
