import AppKit
import UniformTypeIdentifiers
import os

/// Isleta's row in Finder's share sheet: the files the user picked, handed to the running app.
///
/// This is the whole extension. It draws nothing, asks nothing and holds nothing — it turns a set of
/// attachments into one `isleta://shelf/add?path=…` URL, opens that URL **aimed at the containing
/// bundle**, and finishes. Everything about what a shelf is, what happens to a file once it is on
/// one, and whether the island opens lives in the app, where the shelf already lives.
///
/// ## Why a share extension and not a Finder Sync extension
///
/// Measured on macOS 27.0. A Finder Sync extension really
/// does declare a contextual menu, and on this OS **Finder never asks for it**: with the extension
/// enabled, attached to Finder over XPC and demonstrably observing the directory on screen,
/// `menuForMenuKind:` was called for the *toolbar* item (kind 3) and never once for a contextual
/// menu (kind 0 or 1), across a full 82-item menu read. What a Finder Sync extension buys is a
/// toolbar button, plus two resident 8 MB processes for the life of the Finder session. This route
/// costs nothing when idle: the extension is spawned per invocation and exits.
///
/// ## Three things that are load-bearing and look like details
///
/// - **All the work happens in `loadView`, and the request is completed there.** A share extension's
///   principal object is an `NSViewController`, so the obvious place is `viewDidAppear` — and a view
///   that appears is a window on the user's screen. Measured: doing the work in `loadView` and
///   completing from its callback means `viewDidAppear` is **never called at all**, so nothing is
///   ever presented and the user sees no sheet, no flash and no frame. Move this to `viewDidAppear`
///   and Isleta grows a window it never wanted.
/// - **The URL is opened at a *bundle*, not at the scheme.** `NSWorkspace.open(url)` alone works and
///   asks LaunchServices who owns `isleta://`, which is whichever copy of the app it last saw — a
///   stale build in `~/Downloads`, or another app that registered the scheme.
///   `open(_:withApplicationAt:configuration:)` names the app that contains *this* extension, which
///   is the only copy that can be the right one. Measured: it succeeds from inside the sandbox and
///   launches the app when it is not running. Handing over the plain **file** URLs the same way is
///   the design that reads better and does not work — the sandbox refuses to pass out URLs it has no
///   access to, and the call comes back `NSError` 256.
/// - **`completeRequest` must be called on every path.** The share sheet is waiting on it. Not
///   calling it leaves a spinner on the user's screen with no way back.
///
/// ## What it may not do
///
/// It is sandboxed, because an app extension that is not sandboxed **is not registered by
/// PlugInKit at all** — measured A/B/A, `pluginkit -m -i …` answers "no matches" and there is no
/// error anywhere. So this process cannot read the files it is naming, cannot see
/// `~/Library/Application Support/Isleta`, and cannot write to `/private/tmp`. It does not need to:
/// the app is not sandboxed and holds the same URLs a drag onto the island would have produced.
enum ShareExtensionLog {

    /// **The one place in this project that does not go through `IslandLog`, and it has to be.**
    /// `IslandLog`'s file sink writes to `~/Library/Logs/Isleta/isleta.log`, and two things are wrong
    /// with that here: inside the sandbox `~` is this extension's container, so the file would be
    /// written somewhere "Export Logs…" cannot see; and `IsletaMain` already records why two
    /// processes appending to one log file is how a log ends up interleaved mid-line. So: the
    /// unified log only, and only for the one failure the app cannot hear about — everything else is
    /// counted into the URL and logged by the app on receipt.
    ///
    /// The rule that does carry over unchanged is the one that matters: **nothing the user did not
    /// write goes in.** No paths, no file names, no counts of anything but attachments.
    static let log = Logger(subsystem: "com.tryisleta.isleta", category: "finderExtension")
}

/// The paths, in the order Finder listed them, filled in from whichever queue each
/// `NSItemProvider` happens to answer on.
///
/// A plain `var` array and an `NSLock` beside it is the same thing and does not compile under
/// strict concurrency: the array is a captured `var` mutated from a concurrent closure. This is the
/// shape that says the lock covers the storage rather than merely sitting next to it.
private final class ResolvedPaths: @unchecked Sendable {

    private let lock = NSLock()
    private var slots: [String?]

    init(count: Int) {
        slots = [String?](repeating: nil, count: count)
    }

    func record(_ path: String, at index: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard slots.indices.contains(index) else { return }
        slots[index] = path
    }

    func inOrder() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return slots.compactMap { $0 }
    }
}

@objc(IsletaShareExtension)
final class IsletaShareExtension: NSViewController {

    /// The scheme Isleta registers in `CFBundleURLTypes`, and the verb this extension sends.
    ///
    /// The verb is in the *path* rather than in the query so that a second extension — a drop action
    /// that converts, say — is a new path on the same scheme and not a new protocol. The app decides
    /// what an unknown path means; today it means "ignore this".
    private static let scheme = "isleta"
    private static let host = "shelf"
    private static let path = "/add"
    private static let pathKey = "path"

    /// How many attachments arrived that were not file URLs, so the app can say so in its own log.
    private static let unresolvedKey = "unresolved"

    override func loadView() {
        // A view is required and is never presented — see the class note. Zero-sized rather than
        // 1×1 so that nothing can lay it out into something visible.
        view = NSView(frame: .zero)
        handOff()
    }

    private func handOff() {
        let attachments = ((extensionContext?.inputItems as? [NSExtensionItem]) ?? [])
            .flatMap { $0.attachments ?? [] }

        let fileURLType = UTType.fileURL.identifier
        let providers = attachments.filter { $0.hasItemConformingToTypeIdentifier(fileURLType) }
        let unresolvable = attachments.count - providers.count

        guard !providers.isEmpty else {
            ShareExtensionLog.log.error("share invoked with no file attachments — nothing to hand over")
            finish()
            return
        }

        // `loadItem` is asynchronous per provider and the order it completes in is not the order the
        // user selected. Measured: two files selected in Finder arrived at the app in the opposite
        // order. So the results are written into a fixed-size array at the provider's own index
        // rather than appended, and the shelf receives them in the order Finder listed them.
        let resolved = ResolvedPaths(count: providers.count)
        let group = DispatchGroup()

        for (index, provider) in providers.enumerated() {
            group.enter()
            provider.loadItem(forTypeIdentifier: fileURLType, options: nil) { value, _ in
                defer { group.leave() }
                // The item comes back as `Data` holding the URL's bytes, not as a `URL` — and both
                // spellings are accepted here because which one arrives depends on the sender.
                let url: URL?
                if let data = value as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = value as? URL
                }
                guard let url, url.isFileURL else { return }
                resolved.record(url.path, at: index)
            }
        }

        group.notify(queue: .main) { [weak self] in
            let paths = resolved.inOrder()
            let missing = unresolvable + (providers.count - paths.count)
            self?.send(paths: paths, unresolved: missing)
        }
    }

    private func send(paths: [String], unresolved: Int) {
        guard !paths.isEmpty else {
            ShareExtensionLog.log.error("no attachment resolved to a file URL — nothing to hand over")
            finish()
            return
        }

        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        components.path = Self.path
        var queryItems = paths.map { URLQueryItem(name: Self.pathKey, value: $0) }
        if unresolved > 0 {
            queryItems.append(URLQueryItem(name: Self.unresolvedKey, value: String(unresolved)))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            ShareExtensionLog.log.error("could not build the hand-off URL")
            finish()
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        // Isleta is an `LSUIElement` agent with nothing to bring forward, and taking activation
        // would pull the user out of Finder to no visible effect. The island is the feedback.
        configuration.activates = false
        // A hand-off URL is not a document the user opened.
        configuration.addsToRecentItems = false

        guard let container = Self.containingApplicationURL() else {
            // No bundle to aim at — which should be impossible from inside one — so ask
            // LaunchServices who owns the scheme and accept that it might be a stale copy.
            let opened = NSWorkspace.shared.open(url)
            ShareExtensionLog.log.error("containing bundle not found; opened by scheme: \(opened, privacy: .public)")
            finish()
            return
        }

        NSWorkspace.shared.open([url], withApplicationAt: container, configuration: configuration) { [weak self] application, error in
            if application == nil {
                // The only failure the app cannot possibly report, because the app never heard.
                ShareExtensionLog.log.error(
                    "could not reach Isleta: \((error as NSError?)?.code ?? 0, privacy: .public)"
                )
            }
            // Back to the main queue: `completeRequest` tears down the extension's own UI.
            DispatchQueue.main.async { self?.finish() }
        }
    }

    /// The `.app` this `.appex` is inside: `…/Isleta.app/Contents/PlugIns/IsletaFinderExtension.appex`
    /// climbed three levels. Checked rather than assumed — if the layout ever changes, this returns
    /// nil and the caller falls back to the scheme instead of opening a directory that is not an app.
    private static func containingApplicationURL() -> URL? {
        let candidate = Bundle.main.bundleURL
            .deletingLastPathComponent()   // …/Contents/PlugIns
            .deletingLastPathComponent()   // …/Contents
            .deletingLastPathComponent()   // …/Isleta.app
        guard candidate.pathExtension == "app",
              FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        return candidate
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
