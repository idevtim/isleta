import Foundation

/// What a playing track's audio actually is — "Lossless", "AAC", "Hi-Res Lossless" — as it goes
/// under the artist in the open player.
///
/// ## What macOS will and will not tell us, measured on 2026-08-28
///
/// **MediaRemote does not carry it.** The adapter dumps forty keys — title, artist, album, genre,
/// composer, chapter, queue, radio station, media type — and there is no codec, bitrate or quality
/// key among them. There is nothing to read, so there is nothing to parse.
///
/// **Music's own scripting carries it for a *file*, and not for a stream.** On a downloaded or
/// imported track `kind` is populated and `sample rate` is real. On a track streamed from Apple
/// Music — `class: URL track` — the same properties come back `kind: ""`, `bit rate: missing value`,
/// `sample rate: 48000`. Apple Music draws its own Lossless badge from state it does not publish.
///
/// **So a stream gets no badge**, deliberately, and that is the whole design of this type. The
/// alternative on the table was to infer one from `com.apple.Music`'s `losslessEnabled` and
/// `preferredStreamPlaybackAudioQuality`, which is what the user has *asked for* rather than what
/// this track *is* — a catalog track with no lossless master would then be labelled Lossless by an
/// island that had no way of knowing. `nil` is the honest answer and the island simply draws one
/// line fewer.
///

/// ## The two routes that were built and thrown away
///
/// Both worked, in the narrow sense that they returned a string. Neither survived contact with a
/// real library.
///
/// **Music's `kind` through AppleScript** names the format for a track you imported yourself and
/// answers the empty string for everything from Apple Music — which on most machines is everything.
///
/// **Music's own on-screen badge through Accessibility** is exactly right whenever it can be read,
/// and can only be read while Music has a window open. A player minimised to keep playing has no
/// badge in its accessibility tree, which is the state Isleta is most useful in. A feature that
/// depends on another application's window being on screen is not a feature.
public struct AudioFormat: Equatable, Sendable {

    /// Which of the things a track can be. What the badge *says* and what it is *drawn as* both
    /// come from this, so the two cannot drift apart.
    public enum Kind: Equatable, Sendable {
        case dolbyAtmos
        case multichannel
        case hiResLossless
        case lossless
        /// A fixed-bitrate stream. Apple Music's is AAC.
        case lossy
    }

    public let kind: Kind

    /// What goes on screen. Never empty.
    ///
    /// Derived rather than stored, so the words and the mark are two readings of one value and
    /// cannot be set to disagree.
    public var name: String { Self.label(for: kind) }


    /// The SF Symbol beside it — one per kind, and **deliberately not the logo Apple draws.**
    ///
    /// Apple puts the Dolby Atmos logotype next to an Atmos track. That mark is Dolby's registered
    /// trademark, displayed by Apple under licence; Isleta has no such licence, and shipping a
    /// downloaded copy of it inside a notarised product is not a thing to do casually. Nor is
    /// drawing something close enough to be mistaken for it, which is the same problem wearing a
    /// disguise. These are SF Symbols: they ship with the OS, they are the same weight and optical
    /// size as every other glyph in this island, and they claim nothing about who endorsed what.
    ///
    /// The metaphors, in the order they matter:
    ///
    /// - **Atmos is a cube** — spatial audio's standard visual, and the one thing on this list that
    ///   is about *where* the sound is rather than how much of it survived compression.
    /// - **Multichannel is a speaker throwing three waves**, which is the same idea one step down.
    /// - **Hi-Res Lossless is the waveform with a plus**, because that is exactly what it is:
    ///   lossless, and then some.
    /// - **Lossless and lossy share the plain waveform.** A track being AAC is not a thing to
    ///   decorate, and a distinct mark for it would read as a demerit badge.
    public var symbol: String {
        switch kind {
        case .dolbyAtmos: "cube"
        case .multichannel: "speaker.wave.3"
        case .hiResLossless: "waveform.badge.plus"
        case .lossless, .lossy: "waveform"
        }
    }

    /// The words, which follow the kind so the mark and the label cannot disagree.
    ///
    /// Apple ships "Lossless", "Hi-Res Lossless" and "Dolby Atmos" untranslated in Music in every
    /// language Isleta speaks — these are keys rather than literals only so that the day one locale
    /// does translate them, there is somewhere for it to go. "AAC" is a codec name and is not a key
    /// at all: nobody translates it.
    static func label(for kind: Kind) -> String {
        switch kind {
        case .dolbyAtmos: activityText("nowPlaying.format.dolbyAtmos", "Dolby Atmos")
        case .multichannel: activityText("nowPlaying.format.multichannel", "Multichannel")
        case .hiResLossless: activityText("nowPlaying.format.hiResLossless", "Hi-Res Lossless")
        case .lossless: activityText("nowPlaying.format.lossless", "Lossless")
        case .lossy: "AAC"
        }
    }

    /// Above this, "Lossless" becomes "Hi-Res Lossless" — Apple's own line, and the standard one.
    ///
    /// 48 kHz rather than 44.1: Apple Music's Lossless tier tops out at 48, and everything above it
    /// is what Apple calls Hi-Res. A 48 kHz file is Lossless; a 96 or 192 kHz file is not merely a
    /// bigger one.
    static let hiResSampleRate: Double = 48_000

    /// Reads the format MediaRemote publishes on the playing queue entry's metadata.
    ///
    /// **The only route that answers headlessly, and the last one standing.** The other three are in
    /// the type's own doc; this one arrives on the queue line the stream already delivers on every
    /// track change, so it costs nothing new and needs no window open and no Accessibility.
    ///
    /// The fields, as measured on macOS 27.0, 2026-08-28, on an Apple Music lossless stream:
    /// `sampleRate 44100, bitDepth 0, bitrate 0, codec 1902928227 ('qlac'), tier 2,
    /// spatialized false, multiChannel false` — and, on a Dolby Atmos stream:
    /// `sampleRate 48000, bitrate 768, codec 1902324531, tier 4, spatialized true,
    /// multiChannel true, renderingMode 5`.
    ///
    /// `tier` looks like the enum that would answer this outright — 2 for lossless, 4 for Atmos —
    /// and is deliberately not read. Two observations are not an enum, and a value guessed wrong
    /// here is a confident wrong word under somebody's artist rather than a missing one.
    ///
    /// - Parameter fields: `activeFormat`'s own `dictionaryRepresentation`, passed through
    ///   verbatim by the adapter. Read defensively: it is a private dictionary and every key in it
    ///   is one Apple can rename.
    public init?(mediaRemoteFields fields: [String: Any]) {
        let spatialized = (fields["spatialized"] as? NSNumber)?.boolValue ?? false
        let multiChannel = (fields["multiChannel"] as? NSNumber)?.boolValue ?? false
        let sampleRate = (fields["sampleRate"] as? NSNumber)?.doubleValue ?? 0
        // **A `bitrate` is what makes something lossy.** Lossless has no fixed one and reports zero;
        // a constant-bitrate codec reports what it was encoded at. That is the discriminator here
        // rather than `codec`, which came back as `'qlac'` — Apple's own streaming variant, absent
        // from every published FourCC table, so a codec allow-list would have to be discovered one
        // value at a time and would answer nothing for the values not yet seen.
        let bitrate = (fields["bitrate"] as? NSNumber)?.intValue ?? 0
        // Present at all is the floor: an empty or unrecognisable dictionary is not a format.
        guard sampleRate > 0 || bitrate > 0 || spatialized || multiChannel else { return nil }

        // **Channel layout before bitrate, and that order is a correction.** The first version put
        // the bitrate test second, which was safe only by luck: a Dolby Atmos stream turns out to
        // report `bitrate 768` — measured, macOS 27.0 — so anything that reached the lossy branch
        // before the spatial one would have called Atmos "AAC". The spatial test caught it, but a
        // *multichannel, non-spatial* track with a bitrate would still have been mislabelled.
        //
        // What a track is delivered as outranks how hard it was compressed: the layout is a fact
        // the player states, and the bitrate reading below is an inference from the shape of it.
        if spatialized {
            kind = .dolbyAtmos
        } else if multiChannel {
            // MediaRemote's own word for it — see `MRNowPlayingBestAvailableAudioFormatDescription`,
            // whose vocabulary is Stereo, Multichannel, Atmos.
            kind = .multichannel
        } else if bitrate > 0 {
            // **Unverified**, and honestly so: the account this was measured on streams lossless, so
            // no plain lossy stream was ever seen through this route. A fixed bitrate means lossy
            // and AAC is what Apple Music streams lossily — but Atmos reports one too, which is why
            // this is the last test rather than the second. If it is ever seen to be wrong the
            // answer is to name the codec, not to guess harder.
            kind = .lossy
        } else {
            kind = sampleRate > Self.hiResSampleRate ? .hiResLossless : .lossless
        }
    }
}
