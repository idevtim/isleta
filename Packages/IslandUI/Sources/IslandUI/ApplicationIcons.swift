import AppKit
import CoreGraphics
import Foundation

/// The sizes an application icon is drawn and kept at.
///
/// Separate from the view so the raster size is derived from the largest place the icon is drawn
/// rather than picked, and so both numbers are testable without a window.
public enum ApplicationIconMetrics {

    /// macOS draws an app icon's shape on a canvas larger than the shape: the squircle occupies
    /// 824 of a 1024pt icon, so an icon dropped into a 13pt box reads about 10pt and sits visibly
    /// smaller than the SF Symbol it replaced. The glyph and the icon have to weigh the same in
    /// that sliver, so the icon's *box* is scaled by the reciprocal and the shape lands where the
    /// glyph was.
    public static let canvasScale: CGFloat = 1024.0 / 824.0

    /// The one raster kept per app, in pixels.
    ///
    /// 128, which is an icon representation size — so the draw scales from a rep of the same size
    /// rather than resampling a larger one — and comfortably above the largest box the island
    /// draws: the expanded well is `ActivityExpandedHeight.symbolWellSide` at `canvasScale`, which
    /// is 110px at 2x.
    ///
    /// It also sets what the cache costs: 128 × 128 × 4 bytes is 64 KB an app, so a full cache is
    /// half a megabyte against §9's 60 MB.
    public static let pixelSide = 128
}

/// A few decoded application icons, evicted oldest-first.
///
/// A plain value type with no clock and no I/O, so the eviction rule is testable without decoding
/// anything. **Insertion-ordered rather than least-recently-used on purpose**: a read has to be
/// free of mutation, because the only reader is a SwiftUI `body` and mutating observable state
/// from inside one is how a view invalidates itself in a loop. An LRU touch on read is exactly that
/// mutation, and it buys nothing here — the working set is the handful of apps that notify a person
/// in a session, and it is smaller than the cache.
struct ApplicationIconCache {

    /// Eight apps. More than anyone hears from in the minute an island is worth keeping a raster
    /// for, and 512 KB at `ApplicationIconMetrics.pixelSide`.
    static let capacity = 8

    private var images: [String: CGImage] = [:]

    /// Insertion order, oldest first. Never reordered by a read.
    private var order: [String] = []

    func image(for name: String) -> CGImage? { images[name] }

    var count: Int { images.count }

    mutating func store(_ image: CGImage, for name: String) {
        if images[name] == nil { order.append(name) }
        images[name] = image
        while order.count > Self.capacity {
            images.removeValue(forKey: order.removeFirst())
        }
    }

    mutating func removeAll() {
        images.removeAll()
        order.removeAll()
    }
}

/// Where an application with a given display name might be, and how its icon becomes a bitmap.
///
/// Free functions rather than a type with state, because everything here is a question about the
/// disk that has one answer, and because the expensive half has to be callable from a background
/// queue with nothing captured.
public enum ApplicationIconResolver {

    /// The directories scanned for installed applications, in the order a match is taken.
    ///
    /// `/System/Library/CoreServices` is on the list for one app and it is not an obscure one:
    /// **Finder** lives there and nowhere else, and it posts notifications. The rest is the ordinary
    /// set plus one level of nesting, because vendors ship folders (`/Applications/Utilities`,
    /// Setapp, Adobe) and an app one level down is not an unusual install, it is a common one.
    public static var searchDirectories: [URL] {
        [
            "/Applications",
            "/System/Applications",
            NSHomeDirectory() + "/Applications",
            "/System/Library/CoreServices",
        ].map { URL(fileURLWithPath: $0) }
    }

    /// Display name → bundle, for every application in `directories` and one level below them.
    ///
    /// Keyed on the **localized** name (`URLResourceKey.localizedNameKey`), never on the file name.
    /// The banner spells the app the way the user's Mac spells it, and on a French system that is
    /// "Calendrier" for a bundle still called `Calendar.app` — a file-name match works perfectly in
    /// English and shows a bell to everyone else.
    ///
    /// Measured at **29 ms** for 151 apps on this hardware, which is why this is called once, from
    /// a background queue, on the first notification — and never from the main thread. First match
    /// wins, so `/Applications` beats a copy sitting in a vendor folder.
    public static func applicationsByDisplayName(in directories: [URL]) -> [String: URL] {
        var map: [String: URL] = [:]
        var pending = directories
        var depth = 0
        while !pending.isEmpty, depth < 2 {
            var next: [URL] = []
            for directory in pending {
                let contents = (try? FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.localizedNameKey, .isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )) ?? []
                for url in contents {
                    guard url.pathExtension == "app" else {
                        // Only descend into plain folders. Anything with an extension is a bundle
                        // of some other kind, and walking into one is how a 29 ms scan becomes a
                        // walk of every framework on the disk.
                        if url.pathExtension.isEmpty { next.append(url) }
                        continue
                    }
                    let name = displayName(of: url)
                    if map[name] == nil { map[name] = url }
                }
            }
            pending = next
            depth += 1
        }
        return map
    }

    /// The name the Finder shows for a bundle, with the extension off.
    ///
    /// `localizedName` includes `.app` when the user has "show all filename extensions" on, which
    /// would put every app under a key no banner ever spells.
    static func displayName(of url: URL) -> String {
        let localized = (try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName)
            ?? url.lastPathComponent
        return localized.hasSuffix(".app") ? String(localized.dropLast(4)) : localized
    }

    /// The icon of the application bundle at `url`, drawn into a bitmap of exactly `pixelSide`.
    ///
    /// **Never call this on the main thread.** `NSWorkspace.icon(forFile:)` itself is cheap (1.7 ms
    /// — it hands back a lazy `NSImage`), but the first draw that forces IconServices to rasterise
    /// measured **68 ms** on this hardware. That is four frames, and the frame it would land on is
    /// the one the island is arriving on.
    ///
    /// **`cgImage(forProposedRect:context:hints:)` is not a resize, and the rect is not a
    /// request.** It picks a *representation* and hands that back at whatever size it happens to
    /// be: asked for 128 it returned Finder's 256px rep and Calendar's 128px one, on the same
    /// machine in the same run. So the obvious one-line version of this function produces images
    /// whose size — and therefore whose cost, 64 KB against 1 MB for a 512px rep — depends on which
    /// app notified you. Drawing into our own context is what makes
    /// `ApplicationIconMetrics.pixelSide` a fact rather than a hope, and it is the only reason the
    /// cache's memory bound can be stated at all.
    ///
    /// Verified safe off the main thread: 200 concurrent resolves completed, none crashed. That is
    /// the same shape of probe that condemned
    /// `TISCopyCurrentASCIICapableKeyboardLayoutInputSource`, run because AppKit promises nothing
    /// here either. `NSGraphicsContext.current` is per-thread, so the context set here is not
    /// visible to any other resolve or to the main thread's drawing.
    public static func icon(atApplicationURL url: URL) -> CGImage? {
        let image = NSWorkspace.shared.icon(forFile: url.path)
        let side = ApplicationIconMetrics.pixelSide
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        image.draw(
            in: CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side)),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    /// The bundle for an identifier, which is a different question from the one below.
    ///
    /// A display name is a guess that has to be searched for; a bundle identifier is the answer
    /// Launch Services already holds, so this is one call and no catalog. It is the right lookup
    /// wherever the *system* told us who the app is rather than the user — the Now Playing route
    /// reports the player's identifier, and asking the disk for an app called "Google Chrome" to
    /// find something we already know is `com.google.Chrome` would be searching for a fact we have.
    ///
    /// Nil for an app that is not installed, which on this path means an identifier from a player
    /// that has since been removed.
    public static func applicationURL(forBundleIdentifier identifier: String) -> URL? {
        guard !identifier.isEmpty else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
    }

    /// The bundle for a display name: the disk first, then whatever is running.
    ///
    /// The order is the measurement. **The apps that notify a person are usually not running** —
    /// on this machine, with a notification from each in the last hour, Mail, Messages, Calendar,
    /// Reminders and Script Editor were all absent from `runningApplications` — so a running-process
    /// lookup is the fallback rather than the fast path, however much cheaper it looks. It still
    /// earns its place: it is what finds an app installed somewhere nobody scans, and it costs
    /// nothing until the disk has already missed.
    public static func applicationURL(
        forDisplayName name: String,
        in catalog: [String: URL]
    ) -> URL? {
        if let url = catalog[name] { return url }
        return NSWorkspace.shared.runningApplications
            .first { $0.localizedName == name }?
            .bundleURL
    }
}

/// What one lookup of an application by display name found.
///
/// The two halves travel together because they are one answer to one question, and because they are
/// wanted at different moments: the icon on the frame after a notification arrives, the URL on the
/// click that opens the app minutes later. Resolving twice would mean scanning the disk again for
/// something already in hand.
///
/// `@unchecked Sendable` for `CGImage`, exactly as `NowPlayingArtworkImage` is: it is immutable
/// once decoded and is handed across an isolation boundary once, on the hop back to the main actor.
public struct ResolvedApplication: @unchecked Sendable {

    /// The bundle, or nil where nothing on this disk answers to the name.
    public let url: URL?

    /// Its icon at `ApplicationIconMetrics.pixelSide`, or nil where the bundle was found and the
    /// icon could not be drawn — rare, and it still leaves a `url` worth keeping.
    public let icon: CGImage?

    public init(url: URL?, icon: CGImage?) {
        self.url = url
        self.icon = icon
    }
}

/// The island's application icons: ask by name, draw when one arrives.
///
/// Modelled on `NowPlayingArtworkLoader` and for the same reason — the work is far too expensive
/// for the frame that needs it, so the answer arrives a beat late and the view is written to expect
/// that. `ActivityContent.symbol` is what is on screen in the meantime, and it is what stays there
/// if the app cannot be found at all.
///
/// One store is shared by every screen (`shared`). An icon is a fact about the machine, not about a
/// display, and two panels resolving the same app would pay the 29 ms catalog scan twice for one
/// bitmap. It is injectable anyway, so a test can hand a model a store that resolves from a
/// dictionary and never touches the disk.
@MainActor
@Observable
public final class ApplicationIconStore {

    /// The instance `IslandScreenModel` takes by default.
    public static let shared = ApplicationIconStore()

    private var cache = ApplicationIconCache()

    /// Names a resolve is in flight for. Not observed — nothing draws from it, and it is written
    /// during a `body` evaluation, which is only safe because no view reads it.
    @ObservationIgnored private var inFlight: Set<String> = []

    /// Names the disk had no answer for. Held so a machine that genuinely does not have the app
    /// does not re-scan for it once per notification; bounded so a long session with a lot of
    /// unresolvable senders cannot grow it without limit.
    @ObservationIgnored private var unresolved: [String] = []

    /// Where each resolved name lives on disk, for the click that opens it. Not observed: it is
    /// read from a click handler, never from a `body`.
    @ObservationIgnored private var urls: [String: URL] = [:]

    @ObservationIgnored private let resolve: @Sendable (String) -> ResolvedApplication

    @ObservationIgnored
    private let queue = DispatchQueue(label: "com.tryisleta.isleta.app-icons", qos: .utility)

    /// - Parameter resolve: how a display name becomes a bitmap, called on a background queue.
    ///   The default reads the disk; tests pass a closure over a dictionary.
    public init(resolve: (@Sendable (String) -> ResolvedApplication)? = nil) {
        if let resolve {
            self.resolve = resolve
        } else {
            // The catalog is built once, on first use, and captured. An app installed while
            // Isleta is running is therefore missed until the next launch — which is the right
            // trade against re-scanning 151 bundles per notification, and is invisible in practice
            // because an app is running when you have just installed it, which is the fallback
            // path.
            let catalog = LazyApplicationCatalog()
            self.resolve = { key in
                let url: URL?
                if let identifier = ApplicationIconStore.bundleIdentifier(inKey: key) {
                    // Launch Services already knows where this one is — no catalog, no scan.
                    url = ApplicationIconResolver.applicationURL(forBundleIdentifier: identifier)
                } else {
                    url = ApplicationIconResolver.applicationURL(
                        forDisplayName: key,
                        in: catalog.value()
                    )
                }
                guard let url else { return ResolvedApplication(url: nil, icon: nil) }
                return ResolvedApplication(url: url, icon: ApplicationIconResolver.icon(atApplicationURL: url))
            }
        }
    }

    /// How many unresolvable names are remembered before the oldest is forgotten.
    static let unresolvedCapacity = 32

    /// The icon for `name`, or nil while there isn't one.
    ///
    /// Safe to call from a `body`: it reads the cache, and the only thing it can start is one
    /// background resolve per name. The `nil` it returns on the first call is not a failure — it is
    /// the frame before the icon exists, and the caller draws `symbol` for it.
    public func icon(named name: String) -> CGImage? {
        if let image = cache.image(for: name) { return image }
        guard !name.isEmpty, !inFlight.contains(name), !unresolved.contains(name) else { return nil }
        inFlight.insert(name)
        let resolve = resolve
        queue.async { [weak self] in
            let resolved = resolve(name)
            Task { @MainActor in self?.store(resolved, for: name) }
        }
        return nil
    }

    /// The icon for the app with this bundle identifier, or nil while there isn't one.
    ///
    /// The same cache, the same one-resolve-per-key rule and the same "nil is the frame before the
    /// icon exists" contract as `icon(named:)` — only the lookup differs, and it differs because the
    /// question does: an identifier is a fact the system handed us, and a display name is a guess
    /// that has to be searched for.
    ///
    /// Safe to call from a `body`, for `icon(named:)`'s reasons exactly.
    public func icon(forBundleIdentifier identifier: String) -> CGImage? {
        guard !identifier.isEmpty else { return nil }
        return icon(named: Self.key(forBundleIdentifier: identifier))
    }

    /// How a bundle identifier is spelled as a cache key.
    ///
    /// One cache for both kinds of lookup, so the two have to be told apart — an app resolved by
    /// name and the same app resolved by identifier must not be two entries in a cache of eight,
    /// and a name must never be resolved as an identifier or the disk is searched for nothing. The
    /// prefix carries a character no application's display name contains, which is what makes the
    /// namespace airtight rather than merely unlikely.
    nonisolated static func key(forBundleIdentifier identifier: String) -> String {
        "\u{1}bundle:" + identifier
    }

    /// The identifier inside a key, or nil if the key is a display name.
    nonisolated static func bundleIdentifier(inKey key: String) -> String? {
        let prefix = "\u{1}bundle:"
        guard key.hasPrefix(prefix) else { return nil }
        return String(key.dropFirst(prefix.count))
    }

    /// Where the app called `name` lives, if a resolve has already found it.
    ///
    /// Deliberately does not start one. The only caller is a click on a recents row, and that row
    /// is on screen because its icon was drawn, which means the answer is already here; a
    /// synchronous disk scan on the main thread to serve a click would be 29 ms of nothing
    /// happening after the user pressed something. A nil means "this app was not found", and the
    /// caller's job is then to take the row away without opening anything.
    public func applicationURL(named name: String) -> URL? { urls[name] }

    /// Forget everything. What a screen teardown and a test both want.
    public func removeAll() {
        cache.removeAll()
        inFlight.removeAll()
        unresolved.removeAll()
        urls.removeAll()
    }

    private func store(_ resolved: ResolvedApplication, for name: String) {
        inFlight.remove(name)
        if let url = resolved.url { urls[name] = url }
        guard let image = resolved.icon else {
            unresolved.append(name)
            if unresolved.count > Self.unresolvedCapacity { unresolved.removeFirst() }
            return
        }
        cache.store(image, for: name)
    }
}

/// The catalog, built at most once, whichever thread asks first.
///
/// A tiny box rather than a `lazy var` because the closure that reads it is `@Sendable` and runs on
/// a background queue: a `lazy var` captured there is a data race the compiler cannot see and the
/// scan is 29 ms wide, which is plenty of room for two notifications to land inside it.
private final class LazyApplicationCatalog: @unchecked Sendable {

    private let lock = NSLock()
    private var catalog: [String: URL]?

    func value() -> [String: URL] {
        lock.lock()
        defer { lock.unlock() }
        if let catalog { return catalog }
        let built = ApplicationIconResolver.applicationsByDisplayName(
            in: ApplicationIconResolver.searchDirectories
        )
        catalog = built
        return built
    }
}
