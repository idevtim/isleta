import Foundation
import Testing

@testable import IslandSettings

/// These tests exist because a license obligation that depends on someone remembering it is one
/// release away from being broken. `mediaremote-adapter` is BSD 3-Clause and clause 2 requires a
/// binary distribution to reproduce the copyright notice, the conditions and the disclaimer; Sparkle
/// is MIT and asks for the notice in "all copies or substantial portions". If a future edit trims
/// either to a friendly one-liner, the build should fail rather than ship.
///
/// Sparkle is the reason the second half of this suite exists: it was linked into the app target
/// without being added here, and the test that stood guard at the time asserted it was *absent* —
/// so shipping it unacknowledged was the state the suite was passing on.
@Suite("Acknowledgements")
struct AcknowledgementTests {

    /// A path under `Vendor/`, found relative to this file so the test does not depend on the
    /// working directory a test runner happens to choose.
    private static func vendoredURL(_ path: String) -> URL {
        URL(fileURLWithPath: #filePath)          // …/Packages/IslandSettings/Tests/IslandSettingsTests/…
            .deletingLastPathComponent()         // IslandSettingsTests
            .deletingLastPathComponent()         // Tests
            .deletingLastPathComponent()         // IslandSettings
            .deletingLastPathComponent()         // Packages
            .deletingLastPathComponent()         // repo root
            .appendingPathComponent(path)
    }

    /// Trailing whitespace differs between an editor-saved file and a Swift multiline literal, and
    /// neither is a license problem. Everything else must match exactly.
    private static func normalize(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Both license tests are the same assertion against different files: what ships in the binary is
    /// byte-identical to the `LICENSE` a reviewer can check on disk.
    private func expectMatchesFile(_ bundled: String, _ path: String) {
        let url = Self.vendoredURL(path)
        // If the file has moved, that is worth knowing too — a silent skip here would let the two
        // drift apart unnoticed, which is the failure this test exists to prevent.
        #expect(FileManager.default.fileExists(atPath: url.path), "LICENSE not found at \(url.path)")
        guard let onDisk = try? String(contentsOf: url, encoding: .utf8) else { return }
        #expect(Self.normalize(bundled) == Self.normalize(onDisk), "\(path) has drifted from what ships")
    }

    @Test("the bundled license text is byte-identical to the vendored LICENSE")
    func matchesVendoredLicense() {
        expectMatchesFile(Acknowledgements.bsd3Clause, "Vendor/mediaremote-adapter/LICENSE")
    }

    /// Sparkle is not vendored — it arrives through SwiftPM, whose checkout lives under `.build/` and
    /// is gone after a clean. `Vendor/Sparkle/LICENSE` is a tracked copy of it precisely so this
    /// comparison has something to make on a fresh clone; upgrading Sparkle means refreshing both.
    @Test("the bundled Sparkle license is byte-identical to the copy on disk")
    func matchesSparkleLicense() {
        expectMatchesFile(Acknowledgements.sparkleMIT, "Vendor/Sparkle/LICENSE")
    }

    @Test("the acknowledgement names the copyright holder clause 2 requires")
    func namesTheCopyrightHolder() {
        let component = Acknowledgements.mediaRemoteAdapter
        #expect(component.copyrightNotice.contains("Jonas van den Berg"))
        #expect(component.copyrightNotice.contains("2025"))
    }

    @Test("the full conditions and disclaimer ship, not a summary")
    func reproducesConditionsAndDisclaimer() {
        let text = Acknowledgements.mediaRemoteAdapter.licenseText
        // All three numbered conditions.
        #expect(text.contains("1. Redistributions of source code"))
        #expect(text.contains("2. Redistributions in binary form"))
        #expect(text.contains("3. Neither the name of the copyright holder"))
        // The disclaimer, which clause 2 names separately from the conditions.
        #expect(text.contains("THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS"))
        #expect(text.contains("EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE"))
    }

    @Test("every bundled component carries a license, a holder and somewhere to check")
    func everyComponentIsComplete() {
        #expect(!Acknowledgements.all.isEmpty, "Isleta bundles mediaremote-adapter; the list cannot be empty")
        for component in Acknowledgements.all {
            #expect(!component.name.isEmpty)
            #expect(!component.licenseName.isEmpty)
            #expect(!component.copyrightNotice.isEmpty)
            #expect(component.licenseText.count > 500, "\(component.name) looks like a summary, not a license")
            #expect(component.url.scheme == "https")
            // A user reading this list is asking what a third party is doing inside an app that sits
            // over their menu bar. An entry that does not answer that is decoration.
            #expect(!component.purpose.isEmpty)
        }
    }

    @Test("Sparkle is acknowledged, because it is linked into the app")
    func acknowledgesSparkle() {
        // The app target links Sparkle (see the XCRemoteSwiftPackageReference in project.pbxproj), so
        // it is in every distributed build and MIT's one condition applies to it. This assertion used
        // to run the other way, guarding a Sparkle-free binary; it is inverted rather than deleted so
        // the list can never quietly go back to omitting a framework it ships.
        #expect(Acknowledgements.all.contains { $0.name.localizedCaseInsensitiveContains("sparkle") })
    }

    @Test("the Sparkle notice names every holder MIT's condition covers")
    func namesEverySparkleHolder() {
        let notice = Acknowledgements.sparkle.copyrightNotice
        for holder in ["Andy Matuschak", "Elgato Systems", "Kornel Lesiński",
                       "Mayur Pawashe", "C.W. Betts", "Petroules", "Big Nerd Ranch"] {
            #expect(notice.contains(holder), "\(holder) is in Sparkle's LICENSE and must be in the notice")
        }
    }

    @Test("Sparkle's permission notice and its external licenses both ship")
    func reproducesSparkleConditionsAndDisclaimer() {
        let text = Acknowledgements.sparkleMIT
        // MIT's condition, and the disclaimer it sits above.
        #expect(text.contains("Permission is hereby granted, free of charge"))
        #expect(text.contains("shall be included in all\ncopies or substantial portions of the Software"))
        #expect(text.contains("THE SOFTWARE IS PROVIDED \"AS IS\""))
        // The four components compiled into the framework and its helper tools. Two of them carry a
        // binary-redistribution clause of their own, so trimming this section is a license problem
        // and not a tidy-up.
        #expect(text.contains("EXTERNAL LICENSES"))
        #expect(text.contains("Colin Percival"))     // bsdiff
        #expect(text.contains("Yuta Mori"))          // sais-lite
        #expect(text.contains("Orson Peters"))       // ed25519
        #expect(text.contains("Mark Hamlin"))        // SUSignatureVerifier.m
    }
}
