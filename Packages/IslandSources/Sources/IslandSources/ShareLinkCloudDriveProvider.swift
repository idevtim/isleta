import AppKit
import Foundation
import IslandKit

/// The real "Copy link": `com.apple.CloudSharingUI.CopyLink`, resolved at runtime.
///
/// See `ShareLink.swift` for what was measured and what lies. The shape of this class is decided by
/// four of those measurements and nothing else:
///
/// 1. **Runtime resolution is `NSSharingService(named:)` returning nil.** No `dlsym` and no
///    `NSClassFromString` is needed — the API is public and only the *name* is private, suppressed
///    from every list by `AvailableInServiceMenu = false` in Apple's own Info.plist. Five invented
///    names all resolved to nil in the probe, so a nil answer really does mean "this OS has no such
///    extension" and not "the lookup is broken".
/// 2. **`canPerform` is never called.** It answered true for a file on `/private/tmp` that iCloud
///    has never seen. `ShareLinkEligibilityRule` is the gate, and it reads two local facts.
/// 3. **The link arrives on the pasteboard, and the delegate is only the signal.** `didShareItems`
///    hands back an `NSItemProvider` carrying the *input* — its `public.url` loads as the file URL.
/// 4. **The completion can silently never run**, so every request carries a deadline. The timer
///    lives only while a request is in flight, so the idle path keeps none.
///
/// One request at a time. A second `copyLink` while one is running answers `.busy` rather than
/// queueing: the user clicked twice, and two links for one file is worse than one and a shrug.
@MainActor
public final class CloudDriveShareLinkProvider: ShareLinkProviding {

    /// Where the extension writes the link. Injectable so a test can prove the request machinery
    /// without touching the user's clipboard.
    private let pasteboard: NSPasteboard

    /// Reads the two facts eligibility needs. Injectable for the same reason.
    private let facts: @Sendable (URL) -> ShareLinkFileFacts

    private var inFlight: Request?

    public init(
        pasteboard: NSPasteboard = .general,
        facts: @escaping @Sendable (URL) -> ShareLinkFileFacts = ShareLinkFileFacts.read
    ) {
        self.pasteboard = pasteboard
        self.facts = facts
    }

    // MARK: - ShareLinkProviding

    /// Resolved every time rather than cached. It costs a dictionary lookup, and a cached answer
    /// from launch would survive an OS update installed underneath a running Isleta.
    public var isAvailable: Bool {
        NSSharingService(named: NSSharingService.Name(ShareLink.serviceName)) != nil
    }

    public func affordance(for url: URL) -> ShareLinkAffordance {
        ShareLinkEligibilityRule.affordance(
            for: ShareLinkEligibilityRule.eligibility(of: facts(url), providerAvailable: isAvailable)
        )
    }

    public func copyLink(for url: URL, completion: @escaping @MainActor (ShareLinkOutcome) -> Void) {
        guard inFlight == nil else {
            completion(.busy)
            return
        }

        let eligibility = ShareLinkEligibilityRule.eligibility(
            of: facts(url),
            providerAvailable: isAvailable
        )
        guard eligibility == .eligible else {
            IslandLog.shelf.info("share link not attempted — \(eligibility)")
            completion(.notEligible(eligibility))
            return
        }

        guard let service = NSSharingService(named: NSSharingService.Name(ShareLink.serviceName)) else {
            // isAvailable said yes a microsecond ago; this is the OS changing under us.
            completion(.notEligible(.providerUnavailable))
            return
        }

        let request = Request(
            service: service,
            changeCountBefore: pasteboard.changeCount,
            startedAt: Date(),
            completion: completion
        )
        inFlight = request

        let delegate = Delegate(
            onShared: { [weak self] in self?.finishFromDelegate() },
            onFailed: { [weak self] error in self?.finish(with: .refused(
                domain: (error as NSError).domain,
                code: (error as NSError).code
            )) }
        )
        request.delegate = delegate
        service.delegate = delegate

        let deadline = DispatchWorkItem { [weak self] in self?.finish(with: .silent) }
        request.deadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + ShareLinkDeadline.seconds, execute: deadline)

        IslandLog.shelf.info("share link requested")
        service.perform(withItems: [url])
    }

    public func cancel() {
        guard let request = inFlight else { return }
        inFlight = nil
        request.deadline?.cancel()
        request.service.delegate = nil
    }

    // MARK: - Finishing

    /// `didShareItems` fired. Read the clipboard **here**: measured, its `changeCount` has already
    /// advanced by the time this callback runs, every time.
    private func finishFromDelegate() {
        guard let request = inFlight else { return }
        let reading = ShareLinkPasteboardReading(
            changeCountBefore: request.changeCountBefore,
            changeCountAfter: pasteboard.changeCount,
            text: pasteboard.string(forType: .string)
        )
        guard let link = ShareLinkPasteboard.link(in: reading) else {
            finish(with: .wroteNothing)
            return
        }
        finish(with: .copied(link))
    }

    /// The single exit. Whichever of the three arrives first wins and the other two are torn down,
    /// so the completion runs exactly once.
    private func finish(with outcome: ShareLinkOutcome) {
        guard let request = inFlight else { return }
        inFlight = nil
        request.deadline?.cancel()
        request.service.delegate = nil

        let elapsed = Int(Date().timeIntervalSince(request.startedAt) * 1000)
        if case .copied(let url) = outcome {
            // The host is Apple's constant, not the user's document. The token never goes near a log.
            IslandLog.shelf.info(
                "share link copied in \(elapsed) ms, expected host: \(ShareLinkPasteboard.isExpectedICloudHost(url))"
            )
        } else {
            IslandLog.shelf.info("share link \(outcome.logDescription) after \(elapsed) ms")
        }
        request.completion(outcome)
    }

    // MARK: - Request state

    private final class Request {
        let service: NSSharingService
        let changeCountBefore: Int
        let startedAt: Date
        let completion: @MainActor (ShareLinkOutcome) -> Void

        /// `NSSharingService.delegate` is weak, so the delegate has to be owned by something that
        /// outlives the call. Forgetting this is a request that simply never calls back — which,
        /// given the measured silent case, would be indistinguishable from the platform's own bug.
        var delegate: NSObject?
        var deadline: DispatchWorkItem?

        init(
            service: NSSharingService,
            changeCountBefore: Int,
            startedAt: Date,
            completion: @escaping @MainActor (ShareLinkOutcome) -> Void
        ) {
            self.service = service
            self.changeCountBefore = changeCountBefore
            self.startedAt = startedAt
            self.completion = completion
        }
    }

    private final class Delegate: NSObject, NSSharingServiceDelegate {
        private let onShared: @MainActor () -> Void
        private let onFailed: @MainActor (Error) -> Void

        init(
            onShared: @escaping @MainActor () -> Void,
            onFailed: @escaping @MainActor (Error) -> Void
        ) {
            self.onShared = onShared
            self.onFailed = onFailed
        }

        func sharingService(_ service: NSSharingService, didShareItems items: [Any]) {
            MainActor.assumeIsolated { onShared() }
        }

        func sharingService(
            _ service: NSSharingService,
            didFailToShareItems items: [Any],
            error: Error
        ) {
            MainActor.assumeIsolated { onFailed(error) }
        }
    }
}
