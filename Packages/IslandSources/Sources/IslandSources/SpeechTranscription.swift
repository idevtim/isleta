import AVFoundation
import Foundation
import Speech

/// On-device transcription of a dropped file. **Runs in the child process and nowhere else.**
///
/// ## It needs no permission, and the API named for asking is the one that would break that
///
/// `SpeechAnalyzer` / `SpeechTranscriber` are the *opposite* of the ActivityKit case: the macOS
/// `.swiftinterface` is built for `arm64e-apple-macos26.5` and carries no `@available(macOS,
/// unavailable)` anywhere in it. Measured on macOS 27.0: a hardened-runtime, `LSUIElement` app
/// **with no `NSSpeechRecognitionUsageDescription` at all**, launched through LaunchServices,
/// transcribed in 0.88 s while `authorizationStatus()` read `.notDetermined` before and after — no
/// prompt, no TCC abort, nothing naming Speech in `tccd`'s log. Unlike the Bluetooth case the
/// shell-versus-`open -a` distinction made no difference, because nothing here consults TCC.
///
/// **So do not add the usage string, and never call `SFSpeechRecognizer.requestAuthorization`.**
/// That call is the only thing in this area that needs the key, and adding it would put a Speech
/// Recognition row in the user's System Settings for a feature that never asks.
///
/// ## Why this is in a child process rather than in Isleta
///
/// In-process cost passes §9 outright and is not where the memory is: peak RSS on a 31-minute file
/// was 23.9 MB against a 9.0 MB baseline and **flat** — it does not scale with the file — and idle
/// afterwards was 0.006 % of one core. The memory lives in `localspeechrecognition.xpc`, which
/// settles at 53 MB after one short run, **112 MB after four, and never shrinks**.
/// `SpeechModels.endRetention()`, the API named for exactly this, did nothing measurable, and only
/// the client exiting freed it. Isleta never exits — so a user who transcribes one voice memo at
/// 9 a.m. would carry an extra 53 MB until they log out. A child process makes that memory end when
/// the transcription does. Note that `await SpeechTranscriber.installedLocales` **alone** spawns the
/// helper, so even asking what languages exist belongs on this side of the boundary.
///
/// ## `SFSpeechRecognizer` is not the fallback
///
/// It silently eats the first three minutes of a long file: a 232 s recording came back as one
/// final whose *first* segment timestamp is 180.18 s, `isFinal` true, no error, the end timestamp
/// correct, 914 characters against `SpeechAnalyzer`'s 4,024. The documented one-minute limit
/// arrives as a plausible tail rather than as an error, and `shouldReportPartialResults` does not
/// rescue it — 941 callbacks, every partial reporting timestamp 0.00, and the final still only the
/// tail. There is no degraded mode here worth having.
enum SpeechTranscription {

    struct Failure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// Transcribes one file and writes the text beside it.
    ///
    /// **The transcript never leaves this process except as a file.** It is not returned, not
    /// emitted on the pipe, and not logged anywhere — the parent learns a character count and a
    /// path, and the words themselves go straight to disk. That is the same rule the notification
    /// source keeps about message bodies, applied to the one feature that produces more of the
    /// user's private text than anything else Isleta touches.
    ///
    /// - Parameter report: 0...1, derived from `result.range.end` against the file's duration.
    ///   `prepareToAnalyze`'s own `Progress` is **not** that: it reads `fractionCompleted 1.000`
    ///   before analysis begins — sampled six times across a four-second run, always 1.000 — because
    ///   it is *model preparation* progress wearing a name that reads like a transcription bar.
    ///   There is no transcription progress object.
    static func write(
        transcriptOf input: URL,
        to url: URL,
        localeIdentifier: String,
        report: @Sendable @escaping (Double) -> Void
    ) async throws -> URL {
        // A video with no audio track and a corrupt file throw *indistinguishably* out of
        // `AVAudioFile` — `'dta?'` against `'wht?'`, both "AVAudioFile threw", neither saying "there
        // is nothing to transcribe" — so the tracks are asked first, purely to tell the user which
        // of the two happened.
        let asset = AVURLAsset(url: input)
        if let tracks = try? await asset.loadTracks(withMediaType: .audio), tracks.isEmpty {
            throw Failure(sourceText("transcribe.failed.noAudio", "There is no audio in that file"))
        }

        // `AVAudioFile(forReading:)` is the whole decoder: AIFF, WAV, CAF/AAC, M4A, MP3, FLAC and
        // Opus-in-Ogg all open, and so do MP4 and MOV, because it pulls the audio track. The
        // `AVAssetReader` step everyone writes first is unnecessary.
        guard let file = try? AVAudioFile(forReading: input) else {
            throw Failure(sourceText("transcribe.failed.fileUnreadable", "That file could not be read"))
        }
        let duration = file.length > 0 ? Double(file.length) / file.fileFormat.sampleRate : 0

        let locale = try await resolvedLocale(preferring: localeIdentifier)
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // `.transcription`, never `.progressiveTranscription`: the progressive preset delivered
        // **8,310 volatile results** for a 31-minute file (247 a second) against this one's 254
        // finals. It is for a live microphone, not for a file that is already on disk.
        let collector = Task {
            var text = ""
            for try await result in transcriber.results {
                text += String(result.text.characters)
                guard duration > 0 else { continue }
                let end = result.range.end.seconds
                report(min(max(0, end / duration), 1))
            }
            return text
        }

        do {
            _ = try await analyzer.analyzeSequence(from: file)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            collector.cancel()
            throw Self.failure(for: error)
        }

        let text: String
        do {
            text = try await collector.value
        } catch {
            throw Self.failure(for: error)
        }

        // **Silence is not an error.** Ten seconds of digital silence gives 0 results, 0 characters,
        // no throw, in 0.09 s — so "there was nothing said in that file" is something Isleta has to
        // say for itself rather than something the framework reports.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure(sourceText("transcribe.failed.noSpeech", "No speech was found in that file")) }

        try trimmed.write(to: url, atomically: true, encoding: .utf8)
        report(1)
        return url
    }

    /// The best installed model for what was asked for.
    ///
    /// **A missing language model reports itself as an audio-format error**, which is the trap worth
    /// the whole of this function: `fr-FR` (supported, not installed) and `sv-SE` (unsupported) both
    /// failed with `SFSpeechErrorDomain` code 3, `unexpectedAudioFormat`, *"Audio format is not
    /// supported"* — on the exact file that transcribes perfectly in `en-US`. That sends you to
    /// `AVAudioConverter` for an afternoon. `SFSpeechError.noModel` exists, is 4, and is not what
    /// you get. So the installed set is asked *first* and the honest message is produced here.
    ///
    /// `installedLocales` and not `AssetInventory.status(forModules:)`, which answers `.supported`
    /// for a locale that is installed and only says `.installed` after `AssetInventory.reserve` —
    /// so the case named `installed` means "installed **and allocated to you**", and is not the one
    /// that tells you the model is on disk. Reservation is not required to transcribe: every
    /// successful run had `reservedLocales == []`.
    private static func resolvedLocale(preferring identifier: String) async throws -> Locale {
        let installed = await SpeechTranscriber.installedLocales
        guard !installed.isEmpty else {
            throw Failure(sourceText("transcribe.failed.noLanguageInstalled", "No transcription language is installed"))
        }
        let wanted = identifier.isEmpty ? Locale.current.identifier(.bcp47) : identifier
        if let exact = installed.first(where: { $0.identifier(.bcp47) == wanted }) {
            return exact
        }
        // Language match rather than region match: a user set to `en-GB` with `en-US` installed
        // wants the English model, and nine "installed" English locales here are one 132 MB asset.
        let language = wanted.split(separator: "-").first.map(String.init) ?? wanted
        if let related = installed.first(where: { $0.identifier(.bcp47).hasPrefix(language) }) {
            return related
        }
        return installed[0]
    }

    /// Isleta's own words for a failure, never the framework's.
    ///
    /// The framework's `localizedDescription` for the commonest case here is "Audio format is not
    /// supported", which is *wrong* — it is what a missing model says — so passing it through would
    /// be repeating a mistake to the user.
    private static func failure(for error: any Error) -> Failure {
        let nsError = error as NSError
        if nsError.domain == "SFSpeechErrorDomain", nsError.code == 3 {
            return Failure(sourceText("transcribe.failed.languageNotInstalled", "That language is not installed"))
        }
        return Failure(sourceText("transcribe.failed.generic", "That file could not be transcribed"))
    }
}
