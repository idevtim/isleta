import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import IslandSources

@Suite("Now Playing artwork")
struct NowPlayingArtworkTests {

    /// A real JPEG, encoded here rather than checked in. The decode path under test is ImageIO's,
    /// and feeding it bytes that only look like an image would exercise the error branch and call it
    /// a pass.
    static func jpeg(side: Int) throws -> Data {
        let context = try #require(CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        // Four quadrants, so a downsample that returned a wrong-sized or blank image is visible in
        // the pixel assertions rather than passing on a flat color.
        for (index, color) in [(0.9, 0.1, 0.1), (0.1, 0.9, 0.1), (0.1, 0.1, 0.9), (0.9, 0.9, 0.1)].enumerated() {
            context.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: 1)
            context.fill(CGRect(
                x: (index % 2) * side / 2,
                y: (index / 2) * side / 2,
                width: side / 2,
                height: side / 2
            ))
        }
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    /// The bound that keeps a 3000x3000 cover from ever existing as 36 MB of pixels. The decode goes
    /// straight to the target size — decoding first and scaling after works perfectly and spends the
    /// budget anyway.
    @Test("a large cover is decoded down, never at full size")
    func downsample() throws {
        let data = try Self.jpeg(side: 1200)
        let image = try #require(NowPlayingArtworkLoader.downsample(data, maximumPixelSize: 256))
        #expect(image.width <= 256)
        #expect(image.height <= 256)
        #expect(image.width > 200)
    }

    /// `kCGImageSourceCreateThumbnailFromImageAlways` is why: without it ImageIO returns the JPEG's
    /// *embedded* thumbnail, which for cover art is often 60x60 and lands on the island visibly soft.
    @Test("a small cover is not enlarged")
    func smallImageIsNotUpscaled() throws {
        let data = try Self.jpeg(side: 64)
        let image = try #require(NowPlayingArtworkLoader.downsample(data, maximumPixelSize: 256))
        #expect(image.width == 64)
    }

    @Test("artwork is pulled out of a get payload")
    func decodesFromPayload() throws {
        let data = try Self.jpeg(side: 300)
        let payload = try JSONSerialization.data(withJSONObject: [
            "title": "Song",
            "artworkMimeType": "image/jpeg",
            "artworkData": data.base64EncodedString(),
        ])
        let fetched = NowPlayingArtworkLoader.decodeArtwork(fromPayload: payload, maximumPixelSize: 128)
        let image = try #require(fetched.image)
        #expect(image.width <= 128)
    }

    /// A track with no cover is a completely normal answer, not an error — and it must be
    /// distinguishable from "not fetched yet", or a skip flashes a hole where the art was.
    @Test("a payload with no artwork decodes to nothing rather than failing")
    func noArtwork() throws {
        let payload = try JSONSerialization.data(withJSONObject: ["title": "Song"])
        #expect(NowPlayingArtworkLoader.decodeArtwork(fromPayload: payload, maximumPixelSize: 128).image == nil)
    }

    @Test("garbage in the pipe decodes to nothing")
    func garbage() {
        let notJSON = Data("half a line of {".utf8)
        #expect(NowPlayingArtworkLoader.decodeArtwork(fromPayload: notJSON, maximumPixelSize: 128).image == nil)

        let notAnImage = try? JSONSerialization.data(withJSONObject: [
            "artworkData": Data("not a jpeg".utf8).base64EncodedString(),
        ])
        #expect(NowPlayingArtworkLoader.decodeArtwork(
            fromPayload: notAnImage ?? Data(), maximumPixelSize: 128
        ).image == nil)
    }

    /// The base64 has crossed a pipe. A decoder that returns nil on a stray newline is one buffering
    /// change away from an island that never shows a cover again.
    @Test("base64 survives whitespace injected by the pipe")
    func toleratesWhitespace() throws {
        let data = try Self.jpeg(side: 120)
        var encoded = data.base64EncodedString()
        encoded.insert("\n", at: encoded.index(encoded.startIndex, offsetBy: 40))
        let payload = try JSONSerialization.data(withJSONObject: ["artworkData": encoded])
        #expect(NowPlayingArtworkLoader.decodeArtwork(fromPayload: payload, maximumPixelSize: 128).image != nil)
    }

    /// §10, and the state every `check.sh` build is in: no adapter vendored. Asking for artwork must
    /// be a quiet no-op rather than a spawn attempt.
    @MainActor
    @Test("a build with no adapter fetches nothing and reports so")
    func unavailable() async {
        let loader = NowPlayingArtworkLoader(location: nil)
        var delivered: [NowPlayingArtworkImage?] = []
        loader.onArtwork = { delivered.append($0) }
        #expect(loader.isAvailable == false)
        loader.load(identity: "abc")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(delivered.isEmpty)
        #expect(loader.current == nil)
    }

    /// Clearing must reach the island: holding the last album's cover would leave it under whatever
    /// arrives next.
    @MainActor
    @Test("clearing publishes nil exactly once")
    func clearing() {
        let loader = NowPlayingArtworkLoader(location: nil)
        var delivered = 0
        loader.onArtwork = { _ in delivered += 1 }
        loader.load(identity: nil)
        // Nothing was cached, so there is nothing to clear and nothing to say about it.
        #expect(delivered == 0)
    }
}

@Suite("Artwork answers for the right track")
struct ArtworkIdentityTests {

    private func payload(identity: String?, hasArtwork: Bool) throws -> Data {
        var object: [String: Any] = ["title": "Song"]
        if let identity { object["contentItemIdentifier"] = identity }
        if hasArtwork {
            // A 1x1 JPEG is enough — this suite is about *which track* the payload described.
            object["artworkData"] = try NowPlayingArtworkTests.jpeg(side: 8).base64EncodedString()
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test("the payload says which track it was describing")
    func reportsIdentity() throws {
        let fetched = NowPlayingArtworkLoader.decodeArtwork(
            fromPayload: try payload(identity: "24067::24075", hasArtwork: true),
            maximumPixelSize: 128
        )
        #expect(fetched.identity == "24067::24075")
        #expect(fetched.image != nil)
    }

    @Test("a payload with no cover still says which track it was about")
    func identityWithoutArtwork() throws {
        // This is what lets a genuinely artworkless track be told apart from an answer about the
        // *previous* track — the first should be accepted and retired, the second re-asked.
        let fetched = NowPlayingArtworkLoader.decodeArtwork(
            fromPayload: try payload(identity: "99::99", hasArtwork: false),
            maximumPixelSize: 128
        )
        #expect(fetched.identity == "99::99")
        #expect(fetched.image == nil)
    }

    @Test("a player that names no track is still believed")
    func anonymousPayloadIsUsable() throws {
        // Only a payload naming a *different* track is rejected. A player that never reports
        // `contentItemIdentifier` would otherwise never get a cover at all.
        let fetched = NowPlayingArtworkLoader.decodeArtwork(
            fromPayload: try payload(identity: nil, hasArtwork: true),
            maximumPixelSize: 128
        )
        #expect(fetched.identity == nil)
        #expect(fetched.image != nil)
    }

    @MainActor
    @Test("the re-ask is bounded and quick enough not to be seen")
    func retryIsBoundedAndPrompt() {
        // Pressing next asks before the player has switched, so the first answer describes the old
        // track. The re-ask has to be fast enough that the cover is not visibly late, and bounded so
        // a player that never agrees does not spawn helpers forever.
        #expect(NowPlayingArtworkLoader.retryDelay <= .milliseconds(500))
        #expect(NowPlayingArtworkLoader.maximumAttempts >= 2)
        #expect(NowPlayingArtworkLoader.maximumAttempts <= 5)
    }
}

@Suite("Where the artwork key came from")
struct ArtworkIdentitySourceTests {

    @Test("a player-reported identifier is marked as the player's")
    func playerReportedIsMarked() {
        guard case .snapshot(let snapshot) = NowPlayingSnapshot.update(
            title: "HIGHEST IN THE ROOM",
            artist: "Travis Scott",
            album: "HIGHEST IN THE ROOM",
            isPlaying: true,
            bundleIdentifier: "com.apple.Music",
            artworkIdentity: "24067::24075"
        ) else { return #expect(Bool(false), "expected a snapshot") }

        #expect(snapshot.artworkIdentity == "24067::24075")
        #expect(snapshot.artworkIdentityIsFromPlayer)
    }

    @Test("a synthesized key is not, so nothing tries to match a payload against it")
    func synthesizedIsNotMarked() {
        // This is the bug it exists to prevent: the loader checks that a fetched cover describes the
        // track it asked about, and against a hash of title/artist/album that check can never pass.
        // Comparing anyway rejected every cover forever, and the island went on showing the previous
        // track's art indefinitely.
        guard case .snapshot(let snapshot) = NowPlayingSnapshot.update(
            title: "Some Song",
            artist: "Some Artist",
            album: nil,
            isPlaying: true,
            bundleIdentifier: "com.example.player"
        ) else { return #expect(Bool(false), "expected a snapshot") }

        #expect(snapshot.artworkIdentity != nil)
        #expect(!snapshot.artworkIdentityIsFromPlayer)
    }

    @Test("an empty identifier counts as not reported")
    func blankIsNotReported() {
        guard case .snapshot(let snapshot) = NowPlayingSnapshot.update(
            title: "Song", artist: nil, album: nil, isPlaying: false,
            bundleIdentifier: nil, artworkIdentity: "   "
        ) else { return #expect(Bool(false), "expected a snapshot") }
        #expect(!snapshot.artworkIdentityIsFromPlayer)
    }

    @Test("the key still ignores playback state, so a pause does not re-fetch 155KB")
    func keyIgnoresPlaybackState() {
        func key(playing: Bool) -> String? {
            guard case .snapshot(let s) = NowPlayingSnapshot.update(
                title: "Song", artist: "Artist", album: "Album",
                isPlaying: playing, bundleIdentifier: nil
            ) else { return nil }
            return s.artworkIdentity
        }
        #expect(key(playing: true) == key(playing: false))
    }
}

@Suite("The artwork cache")
struct ArtworkCacheTests {

    private let epoch = Date(timeIntervalSince1970: 1_000_000)

    private func image() throws -> CGImage {
        let data = try NowPlayingArtworkTests.jpeg(side: 8)
        return try #require(
            NowPlayingArtworkLoader.decodeArtwork(fromPayload: try JSONSerialization.data(
                withJSONObject: ["artworkData": data.base64EncodedString()]
            ), maximumPixelSize: 64).image
        )
    }

    @Test("a cover that was just fetched comes back without another fetch")
    func hit() throws {
        // The point of the whole thing: stepping back one track should be instant, not a fresh Perl
        // process and a 155KB payload for a cover that was on screen ten seconds ago.
        var cache = ArtworkCache()
        cache.insert(try image(), for: "a", now: epoch)
        #expect(cache.image(for: "a", now: epoch.addingTimeInterval(10)) != nil)
    }

    @Test("a cover nobody asked for is not invented")
    func miss() throws {
        var cache = ArtworkCache()
        cache.insert(try image(), for: "a", now: epoch)
        #expect(cache.image(for: "b", now: epoch) == nil)
    }

    @Test("an old cover is not served")
    func expiry() throws {
        // A cache with no clock quietly becomes a leak that only shows up in a long session.
        var cache = ArtworkCache()
        cache.insert(try image(), for: "a", now: epoch)
        let justInside = epoch.addingTimeInterval(ArtworkCache.maximumAge - 1)
        let justOutside = epoch.addingTimeInterval(ArtworkCache.maximumAge + 1)
        #expect(cache.image(for: "a", now: justInside) != nil)
        #expect(cache.image(for: "a", now: justOutside) == nil)
    }

    @Test("it holds a bounded number of covers")
    func capacity() throws {
        // Each decoded cover is a 256px bitmap — about a quarter of a megabyte — against §9's 60MB
        // budget for the whole app.
        var cache = ArtworkCache()
        let art = try image()
        for index in 0..<(ArtworkCache.capacity + 4) {
            cache.insert(art, for: "track-\(index)", now: epoch)
        }
        #expect(cache.entries.count <= ArtworkCache.capacity)
        #expect(cache.order.count == cache.entries.count)
        // The oldest went first, the newest stayed.
        #expect(cache.image(for: "track-0", now: epoch) == nil)
        #expect(cache.image(for: "track-\(ArtworkCache.capacity + 3)", now: epoch) != nil)
    }

    @Test("re-storing a track does not grow the cache or lose its place")
    func reinsertion() throws {
        var cache = ArtworkCache()
        let art = try image()
        cache.insert(art, for: "a", now: epoch)
        cache.insert(art, for: "a", now: epoch.addingTimeInterval(5))
        #expect(cache.entries.count == 1)
        #expect(cache.order == ["a"])
    }

    @Test("stale entries are dropped before live ones are evicted")
    func stalenessBeatsCapacity() throws {
        // Age must never cost a live entry its place: a cache full of expired covers should make
        // room by dropping those, not by throwing out the one just fetched.
        var cache = ArtworkCache()
        let art = try image()
        for index in 0..<ArtworkCache.capacity {
            cache.insert(art, for: "old-\(index)", now: epoch)
        }
        let later = epoch.addingTimeInterval(ArtworkCache.maximumAge + 10)
        cache.insert(art, for: "fresh", now: later)
        #expect(cache.image(for: "fresh", now: later) != nil)
        #expect(cache.entries.count == 1, "the expired covers should have gone, not the new one")
    }

    @Test("clearing gives the memory back")
    func removeAll() throws {
        var cache = ArtworkCache()
        cache.insert(try image(), for: "a", now: epoch)
        cache.removeAll()
        #expect(cache.entries.isEmpty)
        #expect(cache.order.isEmpty)
        #expect(cache.image(for: "a", now: epoch) == nil)
    }
}

@MainActor
@Suite("A cover survives a consumer forgetting it")
struct ArtworkRepublishTests {

    /// No adapter vendored in a test bundle, so nothing spawns — which is the point: this is about
    /// what `load` does *before* it decides to fetch.
    private func loader() -> NowPlayingArtworkLoader {
        NowPlayingArtworkLoader(location: nil)
    }

    @Test("asking again for a track with no adapter still does not crash or publish nonsense")
    func withoutAnAdapterNothingHappens() {
        let loader = loader()
        var published: [Bool] = []
        loader.onArtwork = { published.append($0 != nil) }
        loader.load(identity: "a", playerReported: true)
        loader.load(identity: "a", playerReported: true)
        #expect(published.isEmpty)
    }

    @Test("clearing publishes nothing when there was nothing to clear")
    func clearingEmptyIsSilent() {
        // `.cleared` arrives routinely — the stream opens with an empty payload — and a loader that
        // announced "no artwork" every time would make the island blink on every one.
        let loader = loader()
        var calls = 0
        loader.onArtwork = { _ in calls += 1 }
        loader.load(identity: nil)
        loader.load(identity: nil)
        #expect(calls == 0)
    }

    @Test("resetting forgets the track, so the next request is a fresh one")
    func resetForgets() {
        // The republish path keys off `resolvedIdentity`; if `reset` left it set, a loader with no
        // image would claim to have one.
        let loader = loader()
        loader.load(identity: "a", playerReported: true)
        loader.reset()
        var published: [Bool] = []
        loader.onArtwork = { published.append($0 != nil) }
        loader.load(identity: "a", playerReported: true)
        #expect(published.isEmpty)
    }
}

@Suite("Who is allowed to ask for a cover")
struct ArtworkRequestTests {

    private func request(
        _ identity: String,
        resolved: String? = nil,
        cover: String? = nil,
        inFlight: String? = nil,
        reAsking: String? = nil
    ) -> NowPlayingArtworkLoader.Request {
        NowPlayingArtworkLoader.request(
            identity: identity,
            resolved: resolved,
            coverIdentity: cover,
            inFlight: inFlight,
            reAsking: reAsking
        )
    }

    @Test("a track nothing knows about is asked about")
    func freshTrackAsks() {
        #expect(request("a") == .ask)
    }

    @Test("a scheduled re-ask owns its track, so playback cannot spend its attempts")
    func scheduledReAskOwnsTheTrack() {
        // The bug this exists for: after a skip the player names the new track immediately but
        // answers `get` with no artwork for ~130ms. The stream reports several times a second while
        // music is playing, and every one of those reports used to start a fresh attempt — so all
        // three were spent inside 200ms, the loader concluded the track had no cover, and nothing
        // asked again for the rest of the song. Paused, the reports stop and one late attempt
        // succeeded, which is exactly the "artwork only loads when playing" that was reported.
        #expect(request("a", reAsking: "a") == .ignore)
    }

    @Test("a fetch already in flight is not duplicated")
    func inFlightIsNotDuplicated() {
        #expect(request("a", inFlight: "a") == .ignore)
    }

    @Test("a track already settled with its cover hands the cover back")
    func settledWithCoverRepublishes() {
        #expect(request("a", resolved: "a", cover: "a") == .republish)
    }

    @Test("a track settled as having no cover is not asked about again")
    func settledWithoutCoverIsQuiet() {
        // Three spaced attempts came back empty: the honest answer is the well and its glyph, not a
        // Perl process on every stream update for the length of the track.
        #expect(request("a", resolved: "a") == .ignore)
    }

    @Test("a re-ask scheduled for a track the user has moved off is superseded")
    func staleReAskIsSuperseded() {
        #expect(request("b", reAsking: "a") == .supersede)
    }

    @Test("a cover held for another track does not answer for this one")
    func anotherTracksCoverIsNotReused() {
        #expect(request("b", resolved: "a", cover: "a") == .ask)
    }
}

@Suite("Telling a radio station from a queue")
struct RadioStationDecodingTests {

    private func snapshot(_ fields: [String: Any]) -> NowPlayingSnapshot? {
        var decoder = NowPlayingAdapterDecoder(now: { Date() })
        guard case .snapshot(let snapshot)? = decoder.decode(line: Self.line(fields)) else { return nil }
        return snapshot
    }

    private static func line(_ fields: [String: Any]) -> String {
        let envelope: [String: Any] = ["type": "data", "diff": false, "payload": fields]
        let data = try! JSONSerialization.data(withJSONObject: envelope)
        return String(decoding: data, as: UTF8.self)
    }

    @Test("Apple Music radio is recognized by the station hash it reports")
    func hashMarksAStation() {
        // Measured on macOS 27.0: Apple Music radio reports `radioStationHash` and no
        // `radioStationIdentifier`, and an ordinary queue reports neither.
        let snapshot = snapshot([
            "title": "What You Need", "playing": true,
            "radioStationHash": "CgkIARoF_-aTnhkQBQ",
        ])
        #expect(snapshot?.isRadioStation == true)
    }

    @Test("the other spelling counts too")
    func identifierAlsoMarksAStation() {
        // The header names both keys. A player that sets the one Music does not must not read as an
        // ordinary queue.
        let snapshot = snapshot([
            "title": "Something", "playing": true, "radioStationIdentifier": "abc",
        ])
        #expect(snapshot?.isRadioStation == true)
    }

    @Test("a track that mentions neither is an ordinary queue")
    func absenceIsAQueue() {
        // The right default: it is also what every player that has never heard of radio sends.
        #expect(snapshot(["title": "Outta Mind.", "playing": true])?.isRadioStation == false)
    }
}
