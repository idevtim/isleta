import IslandActivities
import Testing

@testable import IslandSources

/// These run against the real machine on purpose. The whole point of these two types is a claim
/// about what macOS will and will not tell us, and a claim about the platform that is only checked
/// against a mock is a claim about the mock.
///
/// That is not a general principle here — it is the specific lesson of this file. The claim it
/// used to check was "display brightness cannot be read on Apple Silicon", and it passed for three
/// releases while being false, because it asserted only that the *documented* API declined to
/// answer. The tests below are written so that the interesting outcome fails rather than passes
/// quietly.
@Suite("SystemHUDBrightness")
struct SystemHUDBrightnessTests {

    @MainActor
    @Test("DisplayServices answers with a real brightness on this machine")
    func displayServicesMonitorResolves() throws {
        // If this ever stops resolving, the fallback is correct and the app still runs — but it is
        // news, and it should be a red test rather than a silently degraded feature.
        let monitor = try #require(
            DisplayServicesBrightnessMonitor.make(),
            "DisplayServices brightness symbols no longer resolve or no longer answer"
        )
        let level = try #require(monitor.currentBrightness())
        #expect(level >= 0 && level <= 1)
    }

    @MainActor
    @Test("reading it twice is stable and cheap enough to do on demand")
    func brightnessIsRepeatable() throws {
        let monitor = try #require(DisplayServicesBrightnessMonitor.make())
        // Not necessarily equal — brightness can move between the two reads — but the *availability*
        // must not flap, or `supportedHUDs` would flicker.
        #expect((monitor.currentBrightness() == nil) == (monitor.currentBrightness() == nil))
    }

    @MainActor
    @Test("the unavailable monitor reads nothing and starts nothing")
    func unavailableMonitorIsInert() {
        let monitor = UnavailableBrightnessMonitor()
        #expect(!monitor.isAvailable)
        #expect(monitor.currentBrightness() == nil)
        // §10's denied state: starting it is legal and simply never reports anything.
        var received: [Double] = []
        monitor.start { received.append($0) }
        monitor.stop()
        #expect(received.isEmpty)
    }

    /// The string this used to assert — "a privileged device that only Apple's own software may
    /// query" — was a claim about HID that CoreBrightness disproves. A test that pins the wording
    /// of a withdrawn claim is how it survives to the next release, so this pins the retraction.
    @Test("no explanation claims the platform forbids what it does not")
    func explanationsDoNotOverclaim() {
        for explanation in [SystemHUDBrightness.displayUnavailableExplanation] {
            #expect(!explanation.contains("privileged"))
            #expect(!explanation.contains("only Apple"))
            #expect(!explanation.contains("Apple Silicon"))
        }
    }

    /// §10 asks for an explanation of what is lost, not of what failed. A message naming an IOKit
    /// symbol would be the second thing.
    @Test("the explanations are written for a user, not for a log")
    func explanationsAreUserFacing() {
        for explanation in [SystemHUDBrightness.displayUnavailableExplanation] {
            #expect(!explanation.isEmpty)
            #expect(!explanation.contains("IODisplay"))
            #expect(!explanation.contains("IOHID"))
            #expect(!explanation.contains("kIOReturn"))
            #expect(!explanation.contains("DisplayServices"))
        }
    }

    /// One brightness HUD, where there were two. The keyboard backlight went with schema 18 — the
    /// route worked and the HUD was still wrong, because the ambient-light sensor moves the level
    /// with nobody having pressed anything. See `SystemHUD`.
    @Test("the brightness HUD has a glyph and a spoken label, and it is the only one")
    func brightnessVocabularyExists() {
        #expect(!SystemHUD.brightness.symbol.isEmpty)
        #expect(!SystemHUD.brightness.accessibilityLabel.isEmpty)
        #expect(!SystemHUD.allCases.contains { $0.rawValue.contains("keyboard") })
    }
}
