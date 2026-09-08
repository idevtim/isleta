import Foundation
import IslandActivities
import Testing

@testable import IslandSources

/// The half of the one-shot format read that has decisions in it, exercised without spawning
/// anything — `NowPlayingArtworkTests`' arrangement, for its reason.
@Suite("Reading the audio format one-shot")
struct NowPlayingFormatReaderTests {

    /// The payload measured on macOS 27.0, 2026-09-08, for a track the stream had stopped carrying a
    /// format for — the state the whole route exists to answer in.
    @Test("the playing entry's format is read out of a one-shot queue payload")
    func readsTheCurrentEntrysFormat() throws {
        let payload = Data("""
        {"queueItems":[{"artist":"An Artist","contentItemIdentifier":"1::2","title":"A Song",\
        "duration":205.1,"album":"An Album","audioFormat":{"sampleRate":44100,"bitDepth":0,\
        "spatialized":false,"codec":1902928227,"tier":2,"bitrate":0,"multiChannel":false}}]}
        """.utf8)
        let format = try #require(NowPlayingFormatReader.decodeFormat(fromQueuePayload: payload))
        #expect(format.kind == .lossless)
    }

    /// `null` is what the adapter prints when no player is running, and it is an ordinary answer
    /// rather than an error.
    @Test("no player answers nothing rather than failing")
    func noPlayerIsNotAnError() {
        #expect(NowPlayingFormatReader.decodeFormat(fromQueuePayload: Data("null".utf8)) == nil)
        #expect(NowPlayingFormatReader.decodeFormat(fromQueuePayload: Data()) == nil)
        #expect(NowPlayingFormatReader.decodeFormat(fromQueuePayload: Data("not json".utf8)) == nil)
    }

    /// A queue whose entry carries no format at all — a stream, a podcast — is nothing to draw, and
    /// must not be mistaken for a parse failure or answered with a guess.
    @Test("an entry with no format answers nothing")
    func anEntryWithoutAFormatAnswersNothing() {
        let payload = Data(#"{"queueItems":[{"title":"A Song"}]}"#.utf8)
        #expect(NowPlayingFormatReader.decodeFormat(fromQueuePayload: payload) == nil)
    }

    @Test("an empty queue answers nothing")
    func anEmptyQueueAnswersNothing() {
        #expect(NowPlayingFormatReader.decodeFormat(fromQueuePayload: Data(#"{"queueItems":[]}"#.utf8)) == nil)
    }

    /// Spatial audio through the same door, so the decode is not pinned to one kind.
    @Test("a Dolby Atmos entry reads as Dolby Atmos")
    func readsAtmos() throws {
        let payload = Data("""
        {"queueItems":[{"title":"A Song","audioFormat":{"sampleRate":48000,"bitrate":768,\
        "spatialized":true,"multiChannel":true,"tier":4}}]}
        """.utf8)
        let format = try #require(NowPlayingFormatReader.decodeFormat(fromQueuePayload: payload))
        #expect(format.kind == .dolbyAtmos)
    }

    /// A build with no adapter spawns nothing and answers nothing — a developer build, or the
    /// scripting fallback.
    @MainActor
    @Test("with no adapter in the bundle, nothing is spawned")
    func noAdapterSpawnsNothing() {
        let reader = NowPlayingFormatReader(executable: URL(fileURLWithPath: "/usr/bin/perl"), arguments: [])
        var answered = false
        reader.read { _ in answered = true }
        #expect(!answered)
    }
}
