import AppKit
import Foundation
import Testing

@testable import IslandSources

/// The rules around "Copy link", tested away from iCloud.
///
/// Nothing here touches the user's clipboard, needs an iCloud account, or reaches the extension —
/// which is deliberate and is the reason the decisions were split out as values. Every mistake made
/// while building this was in the *rules*: reporting a link that was already on the clipboard,
/// gating on the wrong resource key, and having no answer for a completion handler that never runs.
/// The parts that need a real account are measured once, by hand, and written up in
/// `docs/PLATFORM-CONSTRAINTS.md`.
@Suite("Share link")
struct ShareLinkTests {

    // MARK: - Eligibility

    @Test("A file in iCloud Drive is eligible")
    func ubiquitousFileIsEligible() {
        let facts = ShareLinkFileFacts(exists: true, isUbiquitous: true)
        #expect(ShareLinkEligibilityRule.eligibility(of: facts, providerAvailable: true) == .eligible)
    }

    @Test("A file outside iCloud Drive is the ordinary case, not an error")
    func localFileIsNotEligible() {
        let facts = ShareLinkFileFacts(exists: true, isUbiquitous: false)
        #expect(
            ShareLinkEligibilityRule.eligibility(of: facts, providerAvailable: true)
                == .notInICloudDrive
        )
    }

    @Test("A missing provider is reported ahead of anything about the file")
    func providerBeatsFile() {
        let facts = ShareLinkFileFacts(exists: false, isUbiquitous: false)
        #expect(
            ShareLinkEligibilityRule.eligibility(of: facts, providerAvailable: false)
                == .providerUnavailable
        )
    }

    /// A deleted file is not in iCloud Drive either, and "this file is gone" is the more useful of
    /// the two true things to say.
    @Test("A missing file is reported ahead of not-in-iCloud")
    func missingBeatsNotUbiquitous() {
        let facts = ShareLinkFileFacts(exists: false, isUbiquitous: false)
        #expect(
            ShareLinkEligibilityRule.eligibility(of: facts, providerAvailable: true) == .fileMissing
        )
    }

    @Test("Every ineligible reason falls back to AirDrop, and only eligible draws Copy link")
    func fallbackIsAirDropForEveryRefusal() {
        #expect(ShareLinkEligibilityRule.affordance(for: .eligible) == .copyLink)
        for reason: ShareLinkEligibility in [.notInICloudDrive, .fileMissing, .providerUnavailable] {
            #expect(ShareLinkEligibilityRule.affordance(for: reason) == .airDropInstead(reason))
        }
    }

    // MARK: - Reading the link back

    /// The load-bearing one. Most users have a URL on the clipboard most of the time; without the
    /// change-count guard, a request that wrote nothing hands them their own clipboard back and
    /// calls it a share link.
    @Test("An unchanged pasteboard yields no link, however link-shaped its contents")
    func unchangedPasteboardIsNotALink() {
        let reading = ShareLinkPasteboardReading(
            changeCountBefore: 42,
            changeCountAfter: 42,
            text: "https://www.icloud.com/iclouddrive/0c13Dvp7Hka_68G0yeWh16wyg"
        )
        #expect(ShareLinkPasteboard.link(in: reading) == nil)
    }

    @Test("A changed pasteboard carrying an https URL is the link")
    func changedPasteboardIsTheLink() {
        let reading = ShareLinkPasteboardReading(
            changeCountBefore: 42,
            changeCountAfter: 43,
            text: "https://www.icloud.com/iclouddrive/0c13Dvp7Hka_68G0yeWh16wyg"
        )
        let link = ShareLinkPasteboard.link(in: reading)
        #expect(link?.host == "www.icloud.com")
        #expect(link.map(ShareLinkPasteboard.isExpectedICloudHost) == true)
    }

    @Test("Surrounding whitespace does not stop a link being read")
    func whitespaceIsTrimmed() {
        let reading = ShareLinkPasteboardReading(
            changeCountBefore: 1,
            changeCountAfter: 2,
            text: "  https://www.icloud.com/iclouddrive/abc\n"
        )
        #expect(ShareLinkPasteboard.link(in: reading) != nil)
    }

    @Test("A changed pasteboard that is not an https URL is not a link", arguments: [
        "",
        "   ",
        "not a url at all",
        "file:///Users/someone/Documents/report.pdf",
        "http://www.icloud.com/iclouddrive/abc",
        "https://",
    ])
    func nonLinksAreRejected(text: String) {
        let reading = ShareLinkPasteboardReading(
            changeCountBefore: 7,
            changeCountAfter: 8,
            text: text
        )
        #expect(ShareLinkPasteboard.link(in: reading) == nil)
    }

    @Test("A nil pasteboard on a changed count is not a link")
    func nilTextIsNotALink() {
        let reading = ShareLinkPasteboardReading(changeCountBefore: 7, changeCountAfter: 8, text: nil)
        #expect(ShareLinkPasteboard.link(in: reading) == nil)
    }

    /// The host is read back for a log flag and never used to filter, so a link on a host Apple
    /// renames to still reaches the user.
    @Test("A link on an unexpected host is still a link, and is flagged")
    func unexpectedHostStillCounts() {
        let reading = ShareLinkPasteboardReading(
            changeCountBefore: 1,
            changeCountAfter: 2,
            text: "https://share.icloud.example/abc"
        )
        let link = ShareLinkPasteboard.link(in: reading)
        #expect(link?.host == "share.icloud.example")
        #expect(link.map(ShareLinkPasteboard.isExpectedICloudHost) == false)
    }

    // MARK: - What reaches the log

    /// A share URL identifies the user's document and the log is emailed to strangers.
    @Test("No outcome's log description carries the URL")
    func logDescriptionsCarryNoUserContent() {
        let secret = "https://www.icloud.com/iclouddrive/0c13Dvp7Hka_68G0yeWh16wyg"
        let outcomes: [ShareLinkOutcome] = [
            .copied(URL(string: secret)!),
            .notEligible(.notInICloudDrive),
            .refused(domain: NSCocoaErrorDomain, code: 4099),
            .wroteNothing,
            .silent,
            .busy,
        ]
        for outcome in outcomes {
            #expect(!outcome.logDescription.contains("icloud"))
            #expect(!outcome.logDescription.contains(secret))
            #expect(!outcome.logDescription.isEmpty)
        }
        #expect(ShareLinkOutcome.copied(URL(string: secret)!).logDescription == "copied")
        #expect(
            ShareLinkOutcome.refused(domain: NSCocoaErrorDomain, code: 4099).logDescription
                == "refused-NSCocoaErrorDomain-4099"
        )
    }

    // MARK: - Constants somebody else owns

    /// Pinned for the reason `perlExecutable` is pinned: it is Apple's identifier, this is the only
    /// place it is spelled, and it is suppressed from every list so nothing else would catch a typo.
    @Test("The service name and host are spelled once and pinned")
    func constantsArePinned() {
        #expect(ShareLink.serviceName == "com.apple.CloudSharingUI.CopyLink")
        #expect(ShareLink.expectedHost == "www.icloud.com")
    }

    /// Ten seconds is a shade over twice the slowest measured success (4.13 s) and well clear of the
    /// 146 ms refusal. The point of the assertion is that somebody tightening it has to come back
    /// here and read why.
    @Test("The deadline stays clear of the slowest measured success")
    func deadlineHasHeadroom() {
        #expect(ShareLinkDeadline.seconds >= 8)
        #expect(ShareLinkDeadline.seconds <= 20)
    }

    // MARK: - The fallback provider

    @MainActor
    @Test("The unavailable provider offers AirDrop for every file rather than an empty menu")
    func unavailableProviderFallsBackToAirDrop() {
        let provider = UnavailableShareLinkProvider()
        #expect(provider.isAvailable == false)
        #expect(
            provider.affordance(for: URL(fileURLWithPath: "/tmp/anything"))
                == .airDropInstead(.providerUnavailable)
        )
    }

    @MainActor
    @Test("The unavailable provider still runs its completion, exactly once")
    func unavailableProviderCompletes() {
        let provider = UnavailableShareLinkProvider()
        var outcomes: [ShareLinkOutcome] = []
        provider.copyLink(for: URL(fileURLWithPath: "/tmp/anything")) { outcomes.append($0) }
        #expect(outcomes == [.notEligible(.providerUnavailable)])
    }

    // MARK: - The real provider, on the paths that need no iCloud

    /// A file outside iCloud Drive must never reach the extension: performing anyway is a 146 ms
    /// round trip that ends in "Couldn't communicate with a helper application", which is a true
    /// statement about XPC and a useless one to show a person.
    @MainActor
    @Test("The real provider refuses a non-iCloud file without asking the system")
    func localFileNeverReachesTheExtension() {
        let provider = CloudDriveShareLinkProvider(
            pasteboard: NSPasteboard(name: NSPasteboard.Name("com.tryisleta.tests.sharelink")),
            facts: { _ in ShareLinkFileFacts(exists: true, isUbiquitous: false) }
        )
        var outcomes: [ShareLinkOutcome] = []
        provider.copyLink(for: URL(fileURLWithPath: "/private/tmp/nothing.txt")) {
            outcomes.append($0)
        }
        #expect(outcomes == [.notEligible(.notInICloudDrive)])
    }

    @MainActor
    @Test("The real provider draws AirDrop for a file it cannot link")
    func realProviderFallsBack() {
        let provider = CloudDriveShareLinkProvider(
            pasteboard: NSPasteboard(name: NSPasteboard.Name("com.tryisleta.tests.sharelink")),
            facts: { _ in ShareLinkFileFacts(exists: false, isUbiquitous: false) }
        )
        #expect(
            provider.affordance(for: URL(fileURLWithPath: "/private/tmp/gone.txt"))
                == .airDropInstead(.fileMissing)
        )
    }

    /// `ShareLinkFileFacts.read` is the one place the resource key is named, and naming
    /// `ubiquitousItemIsUploadedKey` there would be a feature that never fires — it read false for
    /// 90 s on a file `brctl status` reported as fully synced.
    @Test("Reading a plain temporary file reports it present and not ubiquitous")
    func readsFactsFromDisk() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("isleta-sharelink-test-\(UUID().uuidString).txt")
        try "x".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let facts = ShareLinkFileFacts.read(url)
        #expect(facts.exists)
        #expect(facts.isUbiquitous == false)

        let gone = ShareLinkFileFacts.read(url.appendingPathExtension("absent"))
        #expect(gone.exists == false)
    }

    @Test("A non-file URL is not a file at all")
    func nonFileURLIsNotAFile() {
        let facts = ShareLinkFileFacts.read(URL(string: "https://example.com/a.pdf")!)
        #expect(facts.exists == false)
        #expect(facts.isUbiquitous == false)
    }
}
