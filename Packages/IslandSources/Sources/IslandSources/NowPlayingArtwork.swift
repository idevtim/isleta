import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One track's cover art, with the token that says which track it belongs to.
///
/// The identity travels *with* the image rather than beside it, because the fetch is asynchronous
/// and the user is not: a track change during a fetch would otherwise deliver the previous album's
/// cover under the new title, and there is nothing about the image itself that says it is wrong.
public struct NowPlayingArtworkImage: @unchecked Sendable {

    /// The `NowPlayingSnapshot.artworkIdentity` this was fetched for.
    public let identity: String

    /// Already downsampled to `NowPlayingArtworkLoader.maximumPixelSize`. See there for why the
    /// full-resolution image is never decoded at all.
    public let image: CGImage

    public init(identity: String, image: CGImage) {
        self.identity = identity
        self.image = image
    }
}

/// Fetches and caches the artwork for whatever is playing.
///
/// ## Why this is a second invocation of the adapter rather than a field on the stream
///
/// `artworkData` is base64 JPEG, and it measured **211,300 characters — about 155 KB — for a single
/// track** on this hardware. `stream` re-emits the *entire* payload on every update it reports, and
/// during a scrub it reports several a second, so streaming with artwork on would push hundreds of
/// kilobytes per second through a pipe, allocate it in the reader, merge it into the decoder's
/// dictionary and hold it until the next update — against §9's 60 MB resident budget, to redeliver
/// an image that has not changed since the track started. So `stream` runs `--no-artwork` and this
/// runs `get` **once per track**, keyed on `NowPlayingSnapshot.artworkIdentity`.
///
/// ## What bounds it
///
/// Three things, and each of them is a specific failure it is preventing rather than tidiness:
///
/// - **One image is retained, ever.** `current` is replaced, not appended to. A cache keyed by track
///   would grow for the length of a listening session and there is nothing to evict it.
/// - **The image is decoded at thumbnail size, never at full size.**
///   `CGImageSourceCreateThumbnailAtMaxPixelSize` decodes straight to the target, so a 3000x3000
///   cover never exists as 36 MB of pixels even momentarily. Decoding first and scaling after is the
///   version of this that works perfectly and spends the budget anyway.
/// - **stdout is capped.** A helper that goes wrong is a helper writing into our address space, and
///   an uncapped `readDataToEndOfFile` on a pipe is bounded only by what the other end feels like
///   sending.
///
/// ## Threading
///
/// Everything expensive — the spawn, the base64 decode, the image decode — happens on `queue`.
/// `@MainActor` members are the API and the cache. §9 forbids decoding an image on the main thread,
/// and the reason bites here specifically: the decode lands on a track change, which is exactly when
/// `Motion.contentSwap` is running, so a main-thread decode drops frames of the one animation the
/// user is looking at.
/// A few recently-fetched covers, so stepping back and forth through a queue does not re-spawn a
/// helper for a track whose art is already decoded.
///
/// Bounded twice, and both bounds matter. **Capacity**, because each decoded cover is a 256px bitmap
/// — about a quarter of a megabyte — and §9's memory budget is 60 MB for the whole app. **Age**,
/// because an hour-old cover for a track nobody is playing is not worth a byte, and a cache with no
/// clock quietly becomes a leak that only shows up in a long session.
///
/// A plain value type with an injectable clock, so every rule here is testable without decoding an
/// image or spawning anything.
struct ArtworkCache {

    struct Entry {
        var image: CGImage
        var storedAt: Date
    }

    /// Six covers. A queue is usually stepped through a few at a time, and six spans the "went too
    /// far, came back" case that this exists for without holding a megabyte and a half.
    static let capacity = 6

    /// Long enough to cover skipping around an album, short enough that an idle session does not
    /// keep art for music that stopped playing long ago.
    static let maximumAge: TimeInterval = 300

    private(set) var entries: [String: Entry] = [:]

    /// Insertion order, oldest first — what decides which cover is dropped when the cache is full.
    private(set) var order: [String] = []

    mutating func insert(_ image: CGImage, for identity: String, now: Date) {
        if entries[identity] == nil { order.append(identity) }
        entries[identity] = Entry(image: image, storedAt: now)
        evictIfNeeded(now: now)
    }

    /// The cover for a track, if it is here and still fresh.
    ///
    /// Non-mutating on purpose: a lookup that reordered entries would make this an LRU, and an LRU
    /// keyed on *looking* would keep the currently-playing track's cover alive forever while the one
    /// the user is skipping back toward gets dropped. Oldest-inserted-first is what suits stepping
    /// through a queue.
    func image(for identity: String, now: Date) -> CGImage? {
        guard let entry = entries[identity] else { return nil }
        guard now.timeIntervalSince(entry.storedAt) <= Self.maximumAge else { return nil }
        return entry.image
    }

    mutating func removeAll() {
        entries.removeAll()
        order.removeAll()
    }

    private mutating func evictIfNeeded(now: Date) {
        // Stale first, so age never costs a live entry its place.
        for identity in order where entries[identity].map({ now.timeIntervalSince($0.storedAt) > Self.maximumAge }) == true {
            entries[identity] = nil
        }
        order.removeAll { entries[$0] == nil }

        while order.count > Self.capacity {
            let oldest = order.removeFirst()
            entries[oldest] = nil
        }
    }
}

@MainActor
public final class NowPlayingArtworkLoader {

    /// The longest edge, in pixels, the decoded image is allowed to have.
    ///
    /// The leading flank is 40pt wide and the expanded island's artwork well is 44pt, so 256px
    /// covers both at 2x with headroom for a future larger well — and costs 256 KB of RGBA rather
    /// than the 36 MB a 3000x3000 cover would. Chosen against the drawn size, not against the source
    /// image: artwork arrives at whatever size the player felt like.
    public static let maximumPixelSize = 256

    /// Cap on what one `get` may write to us. A full-resolution cover is ~155 KB of base64 and the
    /// rest of the payload is under a kilobyte; 8 MB is fifty times the largest thing ever seen and
    /// still a bound.
    private static let maximumOutputBytes = 8 * 1024 * 1024

    /// Long enough for a framework load and one XPC round trip, short enough that a wedged
    /// `mediaremoted` cannot hold a child process for the session.
    private static let timeout: TimeInterval = 6

    /// Called on the main actor when the artwork changes — including with `nil`, which means "the
    /// track has no artwork". That is not the same as "not fetched yet", and the island needs the
    /// difference: the first draws the fallback glyph, the second keeps drawing the previous cover
    /// until an answer arrives, which is what stops a skip from flashing a hole where the art was.
    public var onArtwork: ((NowPlayingArtworkImage?) -> Void)?

    /// The one image this object retains.
    public private(set) var current: NowPlayingArtworkImage?

    /// What `current` is *for*, even when `current` is nil — a track whose fetch came back empty.
    /// Without it an artworkless track re-fetches on every unrelated update for the whole track.
    private var resolvedIdentity: String?

    private let location: NowPlayingAdapterLocation?
    private let executable: URL
    private let queue = DispatchQueue(
        label: "com.tryisleta.isleta.nowplaying.artwork",
        qos: .utility
    )

    /// The identity currently being fetched, so a repeat request for the same track is a no-op and
    /// the answer to a stale one can be dropped on arrival.
    private var inFlight: String?

    /// How many times each identity has come back empty or describing the wrong track, so a re-ask
    /// is bounded.
    private var attemptsByIdentity: [String: Int] = [:]

    /// The pending re-ask, if any. One at a time, canceled by a new track.
    private var retryTask: Task<Void, Never>?

    /// Which identity that pending re-ask belongs to.
    ///
    /// It is what makes the attempt budget mean "asks over time" rather than "updates that happened
    /// to arrive". While a re-ask is scheduled for a track, the scheduled ask **owns** that track:
    /// stream updates for it do nothing. Without that, playback itself defeats the budget — the
    /// stream reports several times a second across a track change, each report spent an attempt on
    /// a cover the player had not finished loading, and all three were gone inside 200ms.
    private var retryingIdentity: String?

    /// Whether the identity being fetched is the player's own, and therefore comparable.
    private var playerReportedIdentity = false

    /// Recently decoded covers, so stepping back through a queue is instant.
    private var cache = ArtworkCache()

    /// Injectable so the cache's age rule is testable without waiting five minutes.
    private let now: @Sendable () -> Date

    /// Long enough for the player to have finished switching, short enough that the cover is not
    /// visibly late. The stream's own update usually beats this; it is the backstop for a track that
    /// then sits still and sends nothing more.
    static let retryDelay: Duration = .milliseconds(350)

    /// Attempts before a track is accepted as having no cover.
    ///
    /// Three *spaced* asks — see `retryingIdentity` for why the spacing is the load-bearing half.
    /// With `retryDelay` that covers the ~700ms after a skip, against a measured ~130ms of the
    /// player naming the new track while still answering `get` with no `artworkData`. A cover that
    /// has not arrived by then is a track that has none, which is a state the well draws honestly.
    static let maximumAttempts = 3

    public init(
        location: NowPlayingAdapterLocation?,
        executable: URL = NowPlayingAdapterLocation.perlExecutable,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.location = location
        self.executable = executable
        self.now = now
    }

    public convenience init(bundle: Bundle) {
        self.init(location: NowPlayingAdapterLocation.inBundle(bundle))
    }

    public var isAvailable: Bool { location != nil }

    /// Asks for the artwork of the track identified by `identity`.
    ///
    /// Idempotent per identity, which is what makes it safe to call from every update: Now Playing
    /// republishes on every pause, seek and rate change, and only a genuine track change moves the
    /// identity. Passing `nil` clears — playback stopped, and holding the last album's cover would
    /// leave it on the island under whatever arrives next.
    /// - Parameter playerReported: whether `identity` is the player's own `contentItemIdentifier`.
    ///   Only then can a fetched cover be checked against it; a hash we synthesized can never match
    ///   what the payload reports, and comparing anyway rejects every cover forever.
    public func load(identity: String?, playerReported: Bool = false) {
        guard let identity else {
            cancelReAsk()
            inFlight = nil
            resolvedIdentity = nil
            attemptsByIdentity.removeAll()
            guard current != nil else { return }
            current = nil
            onArtwork?(nil)
            return
        }
        guard location != nil else { return }

        switch Self.request(
            identity: identity,
            resolved: resolvedIdentity,
            coverIdentity: current?.identity,
            inFlight: inFlight,
            reAsking: retryingIdentity
        ) {
        case .republish:
            onArtwork?(current)
            return
        case .ignore:
            return
        case .supersede:
            cancelReAsk()
        case .ask:
            break
        }

        // Already have it, and recently enough to trust: show it and spawn nothing.
        //
        // This is the whole point of the cache — stepping back one track should be instant, not a
        // fresh Perl process and a 155 KB payload for a cover that was on screen ten seconds ago.
        // Note it does *not* clear first: there is no gap to cover, so there is no reason to blink.
        if let cached = cache.image(for: identity, now: now()) {
            inFlight = nil
            resolvedIdentity = identity
            current = NowPlayingArtworkImage(identity: identity, image: cached)
            onArtwork?(current)
            return
        }

        // A different track: drop the cover we are showing before fetching the new one.
        //
        // It used to be kept until a replacement arrived, to avoid a hole. But the hole is the
        // honest state — the well with its glyph reads as "the cover is coming" — while the previous
        // track's art reads as *this* track's, confidently and wrongly, for as long as the fetch
        // takes.
        if current != nil {
            current = nil
            onArtwork?(nil)
        }

        inFlight = identity
        self.playerReportedIdentity = playerReported
        let arguments = location?.artworkArguments ?? []
        let executable = self.executable
        let timeout = Self.timeout
        let limit = Self.maximumOutputBytes
        let maxPixel = Self.maximumPixelSize

        queue.async { [weak self] in
            let fetched = Self.fetch(
                executable: executable,
                arguments: arguments,
                byteLimit: limit,
                timeout: timeout,
                maximumPixelSize: maxPixel
            )
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.inFlight == identity else { return }
                    self.inFlight = nil

                    // Did the player answer about the track we asked about?
                    //
                    // Pressing next asks immediately, and the player has usually not switched yet —
                    // so this comes back describing the *previous* track. Accepting it recorded the
                    // old cover against the new identity and never asked again, which is why the
                    // artwork sat one track behind until the track after that.
                    //
                    // Only a payload that names a *different* track is rejected. One that names none
                    // is believed, because a player that does not report `contentItemIdentifier` at
                    // all would otherwise never get a cover.
                    if playerReported, let answered = fetched.identity, answered != identity {
                        let attempts = (self.attemptsByIdentity[identity] ?? 0) + 1
                        self.attemptsByIdentity[identity] = attempts
                        if attempts < Self.maximumAttempts {
                            // Ask again shortly. The player is mid-switch, not silent, so this
                            // converges in one or two goes — and without it nothing would ask again
                            // until the next stream update, which on a paused or steady track may
                            // never come.
                            self.retry(identity: identity, playerReported: playerReported)
                        }
                        return
                    }

                    let image = fetched.image

                    // Only a *successful* fetch retires the identity.
                    //
                    // Recording it unconditionally was the original design, so that a track with no
                    // cover is asked about once rather than on every update for its whole length.
                    // But it cannot tell "this track has no artwork" from "this one attempt
                    // failed", and the adapter's own README warns that artwork "often takes a bit of
                    // time to load and may not appear in the output in all cases" — it explicitly
                    // says to ask again. So one slow or failed fetch pinned the placeholder for the
                    // whole track, which is exactly what was reported from a running build.
                    //
                    // The re-ask is still bounded: `attemptsByIdentity` caps it, so a genuinely
                    // artworkless track settles after a few tries instead of spawning a helper on
                    // every stream update for the length of the song.
                    if let image {
                        self.resolvedIdentity = identity
                        self.attemptsByIdentity.removeValue(forKey: identity)
                        self.cache.insert(image, for: identity, now: self.now())
                        self.current = NowPlayingArtworkImage(identity: identity, image: image)
                        self.onArtwork?(self.current)
                    } else {
                        let attempts = (self.attemptsByIdentity[identity] ?? 0) + 1
                        self.attemptsByIdentity[identity] = attempts
                        if attempts >= Self.maximumAttempts {
                            // Give up on this track, and say so by retiring the identity — the well
                            // with its glyph is the honest answer for a track that has no cover.
                            self.resolvedIdentity = identity
                        } else {
                            // Ask again on our own clock rather than waiting for the next stream
                            // update. Measured: after a skip the player names the new track
                            // immediately but answers `get` with no `artworkData` for ~130ms, so the
                            // first ask is empty for every track a user skips to. Leaving the re-ask
                            // to the stream meant it only happened while something else was
                            // changing — which, on a track that then sits still, is never.
                            self.retry(identity: identity, playerReported: playerReported)
                        }
                        // Deliberately no `onArtwork` call: there is nothing new to say, and
                        // publishing nil here would blank a cover we may already be showing for
                        // this same track from an earlier attempt.
                    }
                }
            }
        }
    }

    /// What an incoming request means, decided from state alone.
    ///
    /// Pure, and separated out for the reason the rest of this codebase separates its rules from its
    /// I/O: the bug this encodes was invisible in every test that existed, because the fetch it goes
    /// wrong in cannot run in a test bundle. The rules are the part that was wrong.
    enum Request: Equatable {

        /// The cover is already in hand — hand it over again.
        ///
        /// A consumer can lose its copy without the loader knowing: `.cleared` arrives, the bridge
        /// calls `NowPlayingController.reset()`, and the same track then re-presents. Returning
        /// silently meant the cover never came back. Playing, the next update papered over it;
        /// **paused, nothing else ever arrives**, which is why the artwork once appeared to load
        /// only for music that was playing.
        case republish

        /// Someone is already asking — a fetch in flight, a re-ask scheduled, or an answer already
        /// settled. This is what makes the call safe on every update.
        case ignore

        /// A re-ask scheduled for a *different* track is stale: the user has moved on. Cancel it,
        /// then ask about this one.
        case supersede

        /// Nothing knows about this track yet.
        case ask
    }

    nonisolated static func request(
        identity: String,
        resolved: String?,
        coverIdentity: String?,
        inFlight: String?,
        reAsking: String?
    ) -> Request {
        if resolved == identity, coverIdentity == identity { return .republish }
        // Before the settled/in-flight checks, and that ordering is the fix: a scheduled re-ask
        // **owns** its track, so the stream reporting three times a second across a skip cannot
        // spend the attempt budget on a cover the player has not finished loading.
        if reAsking == identity { return .ignore }
        if resolved == identity || inFlight == identity { return .ignore }
        if reAsking != nil { return .supersede }
        return .ask
    }

    private func cancelReAsk() {
        retryTask?.cancel()
        retryTask = nil
        retryingIdentity = nil
    }

    /// Asks again for a track the player answered about too early, or had no cover ready for.
    ///
    /// `playerReported` is carried through rather than defaulted: the answer-names-a-different-track
    /// check is only meaningful for the player's own identifier, and dropping the flag on the re-ask
    /// would make the second attempt accept the cover the first one rejected.
    private func retry(identity: String, playerReported: Bool) {
        retryTask?.cancel()
        retryingIdentity = identity
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: Self.retryDelay)
            guard !Task.isCancelled, let self else { return }
            self.retryingIdentity = nil
            self.load(identity: identity, playerReported: playerReported)
        }
    }

    /// Drops the cached image. Called from the source's `stop()`, so switching Now Playing off in
    /// Settings does not leave a quarter of a megabyte of album cover resident for the session.
    public func reset() {
        cancelReAsk()
        // Called from the source's `stop()`, so switching Now Playing off really does give the
        // memory back rather than leaving a megabyte of album art resident for the session.
        cache.removeAll()
        inFlight = nil
        resolvedIdentity = nil
        attemptsByIdentity.removeAll()
        guard current != nil else { return }
        current = nil
        onArtwork?(nil)
    }

    // MARK: - Off the main actor

    /// Runs one `get`, reads its stdout under a cap, and decodes the artwork it carries.
    ///
    /// `nonisolated` and static so it cannot accidentally touch the cache: everything it needs is an
    /// argument, and the result crosses back as a single value.
    private nonisolated static func fetch(
        executable: URL,
        arguments: [String],
        byteLimit: Int,
        timeout: TimeInterval,
        maximumPixelSize: Int
    ) -> FetchedArtwork {
        guard !arguments.isEmpty else { return FetchedArtwork(image: nil, identity: nil) }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        // stderr to /dev/null rather than to a pipe nobody drains. An undrained stderr pipe fills
        // and blocks the writer, so a chatty helper would hang here instead of exiting — the exact
        // failure the streaming reader documents, arriving through a different door.
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return FetchedArtwork(image: nil, identity: nil)
        }

        // Deadline before the read, not after: `readDataToEndOfFile` blocks until the writer closes
        // the pipe, so a helper that never exits would park this queue for the life of the app.
        let boxed = UncheckedBox(process)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            guard boxed.value.isRunning else { return }
            boxed.value.terminate()
        }

        var data = Data()
        let handle = pipe.fileHandleForReading
        while data.count < byteLimit {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        if data.count >= byteLimit {
            // Over the cap: stop reading, and kill the writer rather than leaving it blocked on a
            // pipe nobody is emptying.
            if process.isRunning { process.terminate() }
            return FetchedArtwork(image: nil, identity: nil)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return FetchedArtwork(image: nil, identity: nil) }

        return decodeArtwork(fromPayload: data, maximumPixelSize: maximumPixelSize)
    }

    /// Pulls `artworkData` out of a `get` payload and decodes it at thumbnail size.
    ///
    /// Internal rather than private so the tests can exercise the half that has decisions in it —
    /// base64 with and without padding, a payload with no artwork, a payload that is not JSON —
    /// without spawning anything.
    /// What a fetch came back with: the cover, and **which track the player said it was for**.
    ///
    /// The identity is the whole fix for artwork lagging a track behind. Pressing next asks for the
    /// new track's cover immediately, but the player has not switched yet, so `get` answers with the
    /// *old* one — and recording that against the new identity meant it was never asked again. The
    /// cover stayed one track behind until the track after that.
    struct FetchedArtwork {
        var image: CGImage?
        /// `contentItemIdentifier` from the payload, when it named one.
        var identity: String?
    }

    nonisolated static func decodeArtwork(fromPayload data: Data, maximumPixelSize: Int) -> FetchedArtwork {
        guard
            let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
            let fields = object as? [String: Any]
        else { return FetchedArtwork(image: nil, identity: nil) }

        let identity = fields["contentItemIdentifier"] as? String
        guard
            let base64 = fields["artworkData"] as? String,
            // `.ignoreUnknownCharacters` because the adapter's own JSON is clean but the string has
            // crossed a pipe, and a decoder that returns nil on a stray newline is one buffering
            // change away from an island that never shows a cover again.
            let jpeg = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters]),
            !jpeg.isEmpty
        else { return FetchedArtwork(image: nil, identity: identity) }

        return FetchedArtwork(image: downsample(jpeg, maximumPixelSize: maximumPixelSize),
                              identity: identity)
    }

    /// Decodes image data straight to the target size.
    ///
    /// `kCGImageSourceCreateThumbnailFromImageAlways` matters as much as the max-pixel-size option:
    /// without it ImageIO returns the *embedded* thumbnail when the JPEG has one, which for cover
    /// art is often 60x60 and lands on the island as a visibly soft square. With it, ImageIO decodes
    /// the full image at the requested scale — the point being that it never materialises the
    /// full-resolution bitmap on the way, which `CGImageSourceCreateImageAtIndex` followed by a
    /// redraw would.
    nonisolated static func downsample(_ data: Data, maximumPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
