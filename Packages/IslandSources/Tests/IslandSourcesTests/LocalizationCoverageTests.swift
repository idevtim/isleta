import Foundation
import Testing

@testable import IslandSources

/// Every key this package asks for exists in every language it claims to speak, with the same
/// arguments in it.
///
/// **The thing this catches is silence.** A missing key is not an error at runtime:
/// `String(localized:defaultValue:)` returns the English and the app carries on, so a pane that is
/// half German reads as a translation somebody has not got to yet rather than as a bug — and a key
/// deleted from the Swift source leaves an entry behind that nothing would ever mention. None of it
/// shows up in a build log, in `IslandLog`, or on screen to anyone who reads English.
///
/// **It reads the source tree, not the built bundle, and that is the deliberate half.** The keys
/// only exist as literals at `sourceText` call sites — there is no registry to enumerate — so the
/// scan has to be over the files, and `#filePath` is what locates them. Checking the `.lproj`
/// folders on disk rather than through `Bundle.module` keeps the two halves symmetrical and checks
/// the thing that will ship rather than one build system's copy of it.
///
/// What it therefore does **not** check is that the resources reach the running app and that CFBundle
/// picks the right one. That cannot be checked from here: measured on macOS 27.0, language
/// negotiation for a nested bundle goes through the **main** bundle, and a `swift test` process has
/// no main bundle to speak of — `-AppleLanguages '(de)'` moves `Locale.preferredLanguages` and moves
/// `Bundle.preferredLocalizations` not at all. The proof for that half is running the built
/// `Isleta.app` binary under `-AppleLanguages`, which is written down in `IslandUI/README.md`.
///
/// If the directories are not there the test **fails** rather than skipping. A coverage test that
/// quietly stops covering is worse than none, because it goes on being green.
@Suite struct LocalizationCoverageTests {

    /// The languages this package ships. Must match `Config/Isleta-Info.plist`'s
    /// `CFBundleLocalizations`, which is what actually switches them on — see `AppText`.
    ///
    /// English is deliberately absent: it is the `defaultValue` at each call site and has no table.
    static let shippedLanguages = ["de", "fr", "es"]

    static let lookupFunction = "sourceText"

    /// The file that *declares* the lookup function, and the one file the scan skips.
    ///
    /// Its doc comment shows the call shape — which is the whole point of the doc comment — and the
    /// scan cannot tell a documented example from a real call, so without this the first thing this
    /// test ever reported was a demand to translate the key in that example, which does not exist.
    ///
    /// Skipping one known file rather than stripping comments everywhere is the smaller change and
    /// errs in the safe direction: a call commented out somewhere else still gets scanned, so the
    /// test asks for a translation nobody needs. That is noisy and visible. The opposite mistake —
    /// a real call the scan cannot see — is the silence this whole suite exists to prevent.
    static let definitionFileName = "SourceText.swift"

    static var moduleDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // IslandSourcesTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Sources/IslandSources")
    }

    // MARK: - Reading the two sides

    /// Every key passed to the lookup function anywhere in this package's sources.
    static func keysUsedInSource() throws -> Set<String> {
        let directory = moduleDirectory
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory)
        try #require(
            exists && isDirectory.boolValue,
            "the source scan could not find \(directory.path) — this test cannot cover anything"
        )

        // Whitespace and newlines between the paren and the key are allowed: a long call is
        // wrapped, and a pattern that assumed one line would silently miss the longest strings —
        // which are the ones most worth covering.
        let pattern = try NSRegularExpression(pattern: "\(lookupFunction)\\(\\s*\"((?:[^\"\\\\]|\\\\.)*)\"")
        var keys: Set<String> = []

        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift", url.lastPathComponent != definitionFileName else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                keys.insert(String(text[range]))
            }
        }
        return keys
    }

    /// One language's table, merged across `.strings` and `.stringsdict`.
    ///
    /// A plural lives in the dictionary and nowhere else, so a key present in only one of the two
    /// files is still translated. The value for a plural is reported as `nil`, because its argument
    /// shape is inside the sub-dictionary rather than in a format string and comparing it as one
    /// would report every plural as a mismatch.
    static func table(for language: String) throws -> [String: String?] {
        let lproj = moduleDirectory
            .appendingPathComponent("Resources")
            .appendingPathComponent("\(language).lproj")
        var entries: [String: String?] = [:]
        for name in ["Localizable.strings", "Localizable.stringsdict"] {
            let url = lproj.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let plist = NSDictionary(contentsOf: url) as? [String: Any] else {
                Issue.record("\(language)/\(name) is not a readable property list")
                continue
            }
            for (key, value) in plist { entries[key] = value as? String }
        }
        return entries
    }

    /// The printf argument types in a format string, sorted.
    ///
    /// Sorted rather than in order, because `"%1$@ in %2$@"` and `"%2$@ in %1$@"` are both correct —
    /// reordering the arguments is the main thing a translator is *for*. What must not differ is the
    /// multiset of types: a `%lld` translated as `%@` reads an integer as a pointer.
    static func argumentTypes(in format: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: "%(?:\\d+\\$)?(lld|ld|lf|[@a-zA-Z])")
        let range = NSRange(format.startIndex..., in: format)
        return pattern.matches(in: format, range: range).compactMap {
            Range($0.range(at: 1), in: format).map { r in String(format[r]) }
        }.sorted()
    }

    // MARK: - Tests

    @Test func everyKeyIsTranslatedInEveryShippedLanguage() throws {
        let used = try Self.keysUsedInSource()
        for language in Self.shippedLanguages {
            let missing = used.subtracting(try Self.table(for: language).keys).sorted()
            #expect(missing.isEmpty, "\(language) has no entry for: \(missing.joined(separator: ", "))")
        }
    }

    @Test func noLanguageCarriesAKeyTheSourceNoLongerUses() throws {
        let used = try Self.keysUsedInSource()
        for language in Self.shippedLanguages {
            let stale = Set(try Self.table(for: language).keys).subtracting(used).sorted()
            #expect(stale.isEmpty, "\(language) has entries nothing asks for: \(stale.joined(separator: ", "))")
        }
    }

    @Test func everyLanguageTakesTheSameArgumentsAsEveryOther() throws {
        var shapes: [String: [String: [String]]] = [:]
        for language in Self.shippedLanguages {
            for case let (key, value?) in try Self.table(for: language) {
                shapes[key, default: [:]][language] = Self.argumentTypes(in: value)
            }
        }
        for (key, perLanguage) in shapes {
            let distinct = Set(perLanguage.values.map { $0.joined(separator: ",") })
            #expect(
                distinct.count <= 1,
                "\(key) takes different arguments in different languages: \(perLanguage)"
            )
        }
    }
}
