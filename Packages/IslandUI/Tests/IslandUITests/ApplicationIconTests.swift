import AppKit
import CoreGraphics
import Foundation
import IslandActivities
import Testing

@testable import IslandUI

/// The app icon an activity is drawn with, and the two ways resolving one goes wrong: it is far
/// too slow to do on the frame that needs it, and it is allowed to fail.
@Suite("Application icons")
struct ApplicationIconTests {

    /// A 1×1 bitmap, so the cache can be exercised without decoding anything real.
    private static func swatch() -> CGImage {
        let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    // MARK: - The cache

    @Test("the cache holds what it is given and evicts the oldest past capacity")
    func evictsOldestFirst() {
        var cache = ApplicationIconCache()
        let image = Self.swatch()
        for index in 0..<(ApplicationIconCache.capacity + 2) {
            cache.store(image, for: "App \(index)")
        }
        #expect(cache.count == ApplicationIconCache.capacity)
        #expect(cache.image(for: "App 0") == nil)
        #expect(cache.image(for: "App 1") == nil)
        #expect(cache.image(for: "App 2") != nil)
    }

    /// **A read must not reorder the cache.** The only reader is a SwiftUI `body`, and an LRU touch
    /// there is a mutation during view evaluation — the shape of bug that makes a view invalidate
    /// itself forever. Re-reading the oldest entry therefore must not save it from eviction.
    @Test("reading an entry does not promote it")
    func readsDoNotReorder() {
        var cache = ApplicationIconCache()
        let image = Self.swatch()
        for index in 0..<ApplicationIconCache.capacity {
            cache.store(image, for: "App \(index)")
        }
        _ = cache.image(for: "App 0")
        cache.store(image, for: "Newcomer")
        #expect(cache.image(for: "App 0") == nil)
        #expect(cache.image(for: "Newcomer") != nil)
    }

    @Test("re-storing a name replaces it rather than filling a second slot")
    func rewritingOneNameDoesNotGrow() {
        var cache = ApplicationIconCache()
        let image = Self.swatch()
        for _ in 0..<20 { cache.store(image, for: "Mail") }
        #expect(cache.count == 1)
    }

    // MARK: - The catalog

    /// The banner spells an app the way the user's Mac spells it, so the catalog is keyed on the
    /// localized display name — and that name arrives with `.app` on it when the user has filename
    /// extensions turned on, which would key every app under a string no banner ever contains.
    @Test("a bundle is keyed by its display name with the extension off")
    func displayNameDropsTheExtension() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("isleta-icons-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let nested = root.appendingPathComponent("Vendor")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        for path in [root.appendingPathComponent("Widget.app"), nested.appendingPathComponent("Deep.app")] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }

        let catalog = ApplicationIconResolver.applicationsByDisplayName(in: [root])
        #expect(catalog["Widget"] != nil, "an app in the directory itself must be found")
        #expect(catalog["Widget.app"] == nil, "the key is the display name, not the file name")
        // Vendors ship folders, so one level down is an ordinary install rather than an edge case.
        #expect(catalog["Deep"] != nil, "an app one level down must be found")
    }

    /// Finder lives in `/System/Library/CoreServices` and nowhere else. Losing that directory from
    /// the list is a one-word change that drops the icon for the app the user has open at all times.
    @Test("the search list covers the places apps actually live")
    func searchListCoversCoreServices() {
        let paths = ApplicationIconResolver.searchDirectories.map(\.path)
        #expect(paths.contains("/Applications"))
        #expect(paths.contains("/System/Applications"))
        #expect(paths.contains("/System/Library/CoreServices"))
    }

    /// The whole disk path, once, against an app that is on every Mac and cannot be uninstalled.
    ///
    /// Every other test here injects, so this is the only thing that would notice
    /// `NSWorkspace.icon(forFile:)` starting to hand back an image with no bitmap in it, or Finder
    /// moving out of CoreServices. It asserts a raster comes back at the size the cache is sized
    /// for — a nil here is a bell where the app icon should be, everywhere, silently.
    @Test("Finder's icon resolves and rasterises at the size the island keeps")
    func resolvesARealApplication() throws {
        let catalog = ApplicationIconResolver.applicationsByDisplayName(
            in: ApplicationIconResolver.searchDirectories
        )
        let url = try #require(
            ApplicationIconResolver.applicationURL(forDisplayName: "Finder", in: catalog)
        )
        let icon = try #require(ApplicationIconResolver.icon(atApplicationURL: url))
        #expect(icon.width == ApplicationIconMetrics.pixelSide)
        #expect(icon.height == ApplicationIconMetrics.pixelSide)
    }

    // MARK: - The store

    @Test("an icon arrives a beat after it is asked for, and the first answer is nil")
    @MainActor
    func resolvesAsynchronously() async throws {
        let image = Self.swatch()
        let store = ApplicationIconStore { name in
            ResolvedApplication(url: nil, icon: name == "Mail" ? image : nil)
        }

        #expect(store.icon(named: "Mail") == nil, "the frame that asks cannot also be the frame that draws")
        try await waitUntil { store.icon(named: "Mail") != nil }
        #expect(store.icon(named: "Mail") != nil)
    }

    /// A name the disk has no answer for must be asked about **once**. Without the negative cache
    /// every activity naming an app that is not installed — a helper that ran and was deleted,
    /// an app the AX description named differently — pays the catalog scan again.
    @Test("a name that cannot be resolved is not looked up twice")
    @MainActor
    func remembersFailures() async throws {
        let attempts = Attempts()
        let store = ApplicationIconStore { name in
            attempts.record(name)
            return ResolvedApplication(url: nil, icon: nil)
        }

        #expect(store.icon(named: "Nowhere") == nil)
        try await waitUntil { attempts.count == 1 }
        for _ in 0..<5 { #expect(store.icon(named: "Nowhere") == nil) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(attempts.count == 1)
    }

    // MARK: - Looking one up by bundle identifier

    /// One cache serves both lookups, so the two keyspaces have to be airtight: a display name read
    /// as an identifier sends Launch Services after a bundle that does not exist, and an identifier
    /// read as a name sends the catalog scanner after an app called `com.google.Chrome`.
    @Test("a bundle identifier and a display name cannot be mistaken for each other")
    func theKeyspacesDoNotOverlap() {
        let key = ApplicationIconStore.key(forBundleIdentifier: "com.google.Chrome")
        #expect(ApplicationIconStore.bundleIdentifier(inKey: key) == "com.google.Chrome")
        #expect(key != "com.google.Chrome")
        for name in ["Google Chrome", "com.google.Chrome", "bundle:com.google.Chrome", ""] {
            #expect(ApplicationIconStore.bundleIdentifier(inKey: name) == nil)
        }
    }

    /// The identifier reaches the resolver intact. It is the whole of what the Now Playing route
    /// hands us about a player with no artwork, and a key that arrived mangled would resolve to
    /// nothing and be remembered as unresolvable for the session.
    @Test("an icon asked for by bundle identifier resolves on the identifier")
    @MainActor
    func resolvesByBundleIdentifier() async throws {
        let image = Self.swatch()
        let store = ApplicationIconStore { key in
            guard ApplicationIconStore.bundleIdentifier(inKey: key) == "com.google.Chrome" else {
                return ResolvedApplication(url: nil, icon: nil)
            }
            return ResolvedApplication(url: nil, icon: image)
        }

        #expect(store.icon(forBundleIdentifier: "com.google.Chrome") == nil)
        try await waitUntil { store.icon(forBundleIdentifier: "com.google.Chrome") != nil }
        // And the same app asked for by name is a different question, still unanswered.
        #expect(store.icon(named: "Google Chrome") == nil)
    }

    @Test("an empty identifier is never looked up")
    @MainActor
    func emptyIdentifierIsNotAQuestion() async throws {
        let attempts = Attempts()
        let store = ApplicationIconStore { name in
            attempts.record(name)
            return ResolvedApplication(url: nil, icon: nil)
        }
        #expect(store.icon(forBundleIdentifier: "") == nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(attempts.count == 0)
    }

    /// The other half of `resolvesARealApplication`, and it guards the same failure from the other
    /// direction: a nil here is the music note where a player's icon should be, everywhere.
    @Test("a real bundle identifier resolves to a real bundle")
    func resolvesARealBundleIdentifier() throws {
        let url = try #require(
            ApplicationIconResolver.applicationURL(forBundleIdentifier: "com.apple.finder")
        )
        let icon = try #require(ApplicationIconResolver.icon(atApplicationURL: url))
        #expect(icon.width == ApplicationIconMetrics.pixelSide)
        #expect(ApplicationIconResolver.applicationURL(forBundleIdentifier: "") == nil)
    }

    @Test("an empty name is never looked up")
    @MainActor
    func emptyNameIsNotAQuestion() async throws {
        let attempts = Attempts()
        let store = ApplicationIconStore { name in
            attempts.record(name)
            return ResolvedApplication(url: nil, icon: nil)
        }
        #expect(store.icon(named: "") == nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(attempts.count == 0)
    }

    // MARK: - Support

    /// Counts resolver calls from whatever queue they land on.
    private final class Attempts: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []

        func record(_ name: String) {
            lock.lock()
            names.append(name)
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return names.count
        }
    }

    /// Polls rather than sleeps a fixed interval, so the test is not timing out a background queue
    /// on a busy machine and is not waiting on one that is idle.
    @MainActor
    private func waitUntil(
        _ condition: () -> Bool,
        timeout: Duration = .seconds(2),
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("condition not met within \(timeout)", sourceLocation: sourceLocation)
    }
}
