import Foundation
import IslandKit

/// "Copy link" — an iCloud Drive share URL for a file on the shelf, and the rules around it.
///
/// ## The door is open, and this file exists because it was measured open rather than assumed
///
/// Everything published about this feature said no route existed. `NSSharingServiceNameCloudSharing`
/// shares a `CKShare` over your own container's records and answers `canPerform == false` for a
/// plain file URL; no service in `sharingServices(forItems:)` produces a link under any mask;
/// Finder is not scriptable for it. What answers is `com.apple.CloudSharingUI.CopyLink`, a headless
/// app extension inside `CloudSharingUI.framework` that is missing from every list only because its
/// Info.plist carries `AvailableInServiceMenu = false` — a menu suppression, not a permission.
///
/// Measured end to end on macOS 27.0 (26A5416b) against throwaway files in iCloud Drive, from an app
/// bundle launched with `open -a` so TCC judged it as its own responsible process. Seven
/// invocations. A real `https://www.icloud.com/iclouddrive/<token>` link came back on **six** of
/// them — median **2.0 s**, range 1.68–4.13 s — identically from an ad-hoc-signed bundle and from a
/// Developer ID bundle signed `--options runtime`, which is Isleta's own shape. No prompt, no
/// consent sheet, no TCC row, nothing to grant. `docs/PLATFORM-CONSTRAINTS.md` has the numbers and
/// the daemon log.
///
/// This is a *path*, not a door, and the daemon's log is what says so rather than our own. The
/// extension holds `com.apple.private.clouddocs.sharing-proxy` and
/// `com.apple.private.clouddocs.sharing.private-interface`, gets a sharing proxy out of `bird`, and
/// `bird` then does the CloudKit work **as `com.apple.bird`** — cloudd logs *"TCC approved access
/// for container com.apple.clouddocs … applicationBundleID=com.apple.bird"*. Exactly the
/// relationship Perl has with `mediaremoted`: the helper holds what we cannot, and we are allowed to
/// ask it. Contrast `TUCallCenter`, where `callservicesd` logs a refusal naming our client and no
/// arrangement opens it.
///
/// ## Four things in this area lie, and each is the one you would reach for
///
/// - **`canPerform(withItems:)` is true for a file iCloud has never seen.** It answered true for
///   `/private/tmp`, which then failed. It is not a gate and is never called here; the gate is
///   `URLResourceValues.isUbiquitousItem`, which is local, free and correct.
/// - **`didShareItems` hands back the *input* items, not the link.** Its `NSItemProvider` registers
///   `public.plain-text`, `public.file-url` and `public.url`, and `public.url` loads as the
///   **file** URL — 116 bytes, against 60 for the share link. The link arrives *only* on the
///   pasteboard. The callback is the signal, the pasteboard is the channel.
/// - **`ubiquitousItemIsUploadedKey` reads false for a file that is fully uploaded.** It stayed
///   false for 90 s on an item `brctl status` reported as caught-up. Waiting on it is waiting
///   forever; `isUbiquitousItem` is the key that answers.
/// - **There is a state in which neither delegate callback ever arrives.** One invocation — the
///   first ever made on an account that had never created an iCloud Drive share — produced no
///   `didShareItems`, no `didFailToShareItems`, no pasteboard change, and left the extension idle
///   in its own run loop for the remaining two minutes. `bird` logged `denied access` and the
///   CloudKit operation was never started. Every one of the six invocations after it succeeded,
///   including the first from a brand-new bundle identifier, so it is not a per-app warm-up. It
///   cannot be reproduced on this machine again, and it is why `ShareLinkDeadline` exists: a
///   completion handler that can silently never run is a spinner that never stops.
///
/// ## What the user's clipboard costs
///
/// The extension writes the link to `NSPasteboard.general` itself; there is no way to receive it
/// without that happening, and for an action called "Copy link" that is the point rather than a
/// side effect. Reading it back is how we learn the link, and across every run here no macOS 26
/// pasteboard-access prompt appeared — the read follows a copy this app asked for, in the same app.
public enum ShareLink {

    /// The extension's service name. A constant with a test pinning it, for the same reason
    /// `perlExecutable` is one: it is somebody else's identifier, this is the only place it is
    /// spelled, and an OS that renames it must degrade rather than mis-resolve.
    public static let serviceName = "com.apple.CloudSharingUI.CopyLink"

    /// The host every measured link came back on. Used for a log flag and a test, never as a filter
    /// — see `ShareLinkPasteboard.link(in:)`.
    public static let expectedHost = "www.icloud.com"
}

// MARK: - Whether a file can become a link at all

/// Why a file can or cannot be given a link, decided before anything is asked of the system.
public enum ShareLinkEligibility: Equatable, Sendable {

    case eligible

    /// The file is not in iCloud Drive. **This is the ordinary case, not an error case**: the shelf
    /// takes files from anywhere, and most of them are somewhere else. Measured, performing anyway
    /// answers `NSCocoaErrorDomain 4099 "Couldn't communicate with a helper application."` in
    /// 146 ms — a true statement about XPC and a useless one to show a person.
    case notInICloudDrive

    /// The file was moved or deleted between landing on the shelf and the click.
    case fileMissing

    /// This OS has no such extension. The whole feature is gone, not this file.
    case providerUnavailable
}

/// What the shelf's action menu should draw for one file.
///
/// The fallback is a *decision made here*, not advice left to the caller, because the alternative is
/// a row that says "Copy link" and produces a message about a helper application.
public enum ShareLinkAffordance: Equatable, Sendable {

    /// Draw "Copy link".
    case copyLink

    /// A link is impossible for this file. Draw AirDrop in its place, and know why.
    ///
    /// **AirDrop is the fallback, and it is a real feature rather than an empty box.** It is
    /// measured to work — `NSSharingService(named: .sendViaAirDrop)` reports `canPerform` true for
    /// both local and iCloud files — it needs no permission, Apple draws the picker, it already
    /// ships as `DropAction.airDrop`, and it answers the same thing the user wanted: this file, to
    /// that person. The three alternatives were all worse. Copying the file *path* is `pbcopy` of a
    /// `file://` URL, which looks like a link, pastes like a link and resolves for exactly one
    /// person on Earth. Reveal in Finder answers a different question entirely. And offering
    /// nothing puts the burden of the platform's shape on the user, who dropped a file on the
    /// island and got a shorter menu than the last file they dropped, with nothing saying why.
    case airDropInstead(ShareLinkEligibility)
}

/// The two facts about a file that decide eligibility, split out so the rule is testable with no
/// iCloud account, no network and no file.
public struct ShareLinkFileFacts: Equatable, Sendable {

    public var exists: Bool

    /// `URLResourceValues.isUbiquitousItem` — true for anything under
    /// `~/Library/Mobile Documents`, including the Desktop and Documents folders when iCloud is
    /// syncing them. Deliberately **not** `ubiquitousItemIsUploadedKey`, which reads false for a
    /// file that is fully uploaded.
    public var isUbiquitous: Bool

    public init(exists: Bool, isUbiquitous: Bool) {
        self.exists = exists
        self.isUbiquitous = isUbiquitous
    }

    /// Reads both from disk. Cheap and local: no XPC, no daemon, no network.
    public static func read(_ url: URL) -> ShareLinkFileFacts {
        guard url.isFileURL else { return ShareLinkFileFacts(exists: false, isUbiquitous: false) }
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey])
        return ShareLinkFileFacts(
            exists: FileManager.default.fileExists(atPath: url.path),
            isUbiquitous: values?.isUbiquitousItem ?? false
        )
    }
}

/// The eligibility rule, kept pure for the same reason `TransitionSettle` is: every mistake here is
/// about the *order* the answers are checked in, and that needs no iCloud account to reproduce.
public enum ShareLinkEligibilityRule {

    /// The order matters. A missing provider is reported ahead of a missing file because it is a
    /// statement about the whole feature rather than about this row, and a missing file is reported
    /// ahead of "not in iCloud Drive" because a deleted file is not in iCloud Drive either and that
    /// is the less true of the two things to say.
    public static func eligibility(
        of facts: ShareLinkFileFacts,
        providerAvailable: Bool
    ) -> ShareLinkEligibility {
        guard providerAvailable else { return .providerUnavailable }
        guard facts.exists else { return .fileMissing }
        guard facts.isUbiquitous else { return .notInICloudDrive }
        return .eligible
    }

    public static func affordance(for eligibility: ShareLinkEligibility) -> ShareLinkAffordance {
        eligibility == .eligible ? .copyLink : .airDropInstead(eligibility)
    }
}

// MARK: - Reading the link back off the pasteboard

/// One before-and-after look at the pasteboard, as a value, so the rule below can be tested without
/// disturbing the user's clipboard.
public struct ShareLinkPasteboardReading: Equatable, Sendable {

    public var changeCountBefore: Int
    public var changeCountAfter: Int
    public var text: String?

    public init(changeCountBefore: Int, changeCountAfter: Int, text: String?) {
        self.changeCountBefore = changeCountBefore
        self.changeCountAfter = changeCountAfter
        self.text = text
    }
}

public enum ShareLinkPasteboard {

    /// The link the extension wrote, or nil.
    ///
    /// **`changeCount` is the load-bearing half.** Without it, a user who already had a URL on the
    /// clipboard — which is most users, most of the time — would be handed their own clipboard back
    /// and told it was their new share link, and the failure would be invisible precisely when it
    /// matters. Measured: the count had already advanced by the moment `didShareItems` fired, every
    /// time, so this is read in the callback rather than polled for.
    ///
    /// The host is **not** filtered on. `expectedHost` is somebody else's domain name and pinning it
    /// would turn a rename we do not control into a dead feature; the count already proves the
    /// extension is what wrote this, and text that is not a URL does not parse.
    public static func link(in reading: ShareLinkPasteboardReading) -> URL? {
        guard reading.changeCountAfter != reading.changeCountBefore else { return nil }
        guard let text = reading.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              let url = URL(string: text),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    /// Whether a link came back on the host every measured one came back on. For a log flag and for
    /// a test — never for a decision.
    public static func isExpectedICloudHost(_ url: URL) -> Bool {
        url.host?.lowercased() == ShareLink.expectedHost
    }
}

// MARK: - How long to wait

public enum ShareLinkDeadline {

    /// How long a request may run before it is called silent.
    ///
    /// Measured successes were 1.68–4.13 s and a second link for an already-shared file was 1.31 s;
    /// the refusal for a non-iCloud file was 146 ms. Ten seconds is a shade over twice the slowest
    /// success — generous enough that a cold CloudKit round trip on a slow connection is not cut
    /// off, short enough that the one measured silent invocation, which never answered at all,
    /// ends in a sentence rather than a spinner.
    public static let seconds: TimeInterval = 10
}

// MARK: - What a request ends as

public enum ShareLinkOutcome: Equatable, Sendable {

    /// A link is on the clipboard.
    case copied(URL)

    /// Nothing was asked of the system: this file could never have had one.
    case notEligible(ShareLinkEligibility)

    /// The extension answered with an error. `NSCocoaErrorDomain 4099` is the one measured, and it
    /// is what a file outside iCloud Drive gets — which `notEligible` should have caught first, so
    /// seeing this in a log means the eligibility rule missed something.
    case refused(domain: String, code: Int)

    /// The service reported success and the clipboard did not move. Not observed, and kept separate
    /// from `silent` because it says something different: the extension finished and wrote nothing.
    case wroteNothing

    /// Neither callback arrived inside `ShareLinkDeadline`. Observed exactly once — see the note at
    /// the top of this file.
    case silent

    /// A request for this provider was already in flight. The user clicked twice.
    case busy

    /// Safe to write to `IslandLog`: enum shape only, never the URL. A share URL identifies the
    /// user's document, and the log is emailed to strangers.
    public var logDescription: String {
        switch self {
        case .copied: "copied"
        case .notEligible(let why): "not-eligible-\(why)"
        case .refused(let domain, let code): "refused-\(domain)-\(code)"
        case .wroteNothing: "wrote-nothing"
        case .silent: "silent"
        case .busy: "busy"
        }
    }
}

// MARK: - The seam

/// One route to "give me a link for this file".
///
/// A protocol for the reason CLAUDE.md's private-API decision requires one: the extension is
/// somebody else's bundle, suppressed from every list by a flag in *their* Info.plist, and an OS
/// that removes it must leave Isleta with a shorter menu rather than a broken row.
@MainActor
public protocol ShareLinkProviding: AnyObject {

    /// Whether this OS has the extension at all. Resolved at runtime, never assumed.
    var isAvailable: Bool { get }

    /// What the action menu should draw for this file. The fallback decision lives here so that no
    /// caller has to make it twice.
    func affordance(for url: URL) -> ShareLinkAffordance

    /// Ask for a link. The completion runs exactly once, on the main actor, and always runs — that
    /// is the whole reason `ShareLinkDeadline` exists.
    func copyLink(for url: URL, completion: @escaping @MainActor (ShareLinkOutcome) -> Void)

    /// Abandon anything in flight. The completion for it does not run.
    func cancel()
}

/// The provider for an OS that has no such extension.
///
/// Not an error path and not an empty box: every file reports `.airDropInstead(.providerUnavailable)`,
/// so the shelf draws AirDrop where it would have drawn Copy link and the feature degrades to the
/// one thing in this area that is measured to always work.
@MainActor
public final class UnavailableShareLinkProvider: ShareLinkProviding {

    public init() {}

    public var isAvailable: Bool { false }

    public func affordance(for url: URL) -> ShareLinkAffordance {
        .airDropInstead(.providerUnavailable)
    }

    public func copyLink(for url: URL, completion: @escaping @MainActor (ShareLinkOutcome) -> Void) {
        completion(.notEligible(.providerUnavailable))
    }

    public func cancel() {}
}
