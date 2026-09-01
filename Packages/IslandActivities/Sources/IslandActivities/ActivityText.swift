import Foundation

/// Every word IslandActivities puts in front of a person, in the language they read.
///
/// ## Why the English is still in the Swift file
///
/// The call site reads `activityText("timer.paused", "Paused")`: a stable key, and the English
/// beside it. That is `String(localized:defaultValue:bundle:)`'s own shape, and it is chosen over
/// the more usual "English string *is* the key" for two reasons that matter to this codebase
/// specifically.
///
/// **The copy is the product.** Isleta's captions are long, argued, and sit under doc comments
/// explaining why a shorter version was wrong. Moving the sentence out to a table would leave the
/// argument attached to an opaque identifier, and the next person to shorten the sentence would do
/// it without ever reading the paragraph that says not to. The English stays where the reasoning is.
///
/// **Editing the English must not silently orphan the translations.** With the English as the key,
/// fixing a typo detaches every language at once, invisibly. With a symbolic key it does not — and
/// `LocalizationCoverageTests` is what notices when a *new* key has no translation yet.
///
/// ## Why there is no `en.lproj`
///
/// English is the `defaultValue` argument, so it needs no table: measured, a language with no
/// `.lproj` — and English is one — falls through to it with the interpolation intact. An
/// `en.lproj/Localizable.strings` would be a second copy of every sentence, free to drift from the
/// one in the source, and the drift would show only to English readers, who are the people least
/// likely to be checking.
///
/// The one exception is plurals, which a format string cannot express: those live in
/// `en.lproj/Localizable.stringsdict` because there is nowhere else for a plural rule to be.
///
/// ## The trap this file exists to make unhittable
///
/// `bundle: .module` is load-bearing and silent when forgotten — a lookup against `Bundle.main`
/// finds nothing, returns the `defaultValue`, and the feature is "not translated yet" rather than
/// broken. Going through one function means the bundle is never spelled at a call site and so can
/// never be left out.
///
/// - Parameters:
///   - key: a stable identifier. It survives an edit to the English, which is the whole point.
///   - english: the source text, and the fallback for any language Isleta does not yet speak.
func activityText(_ key: StaticString, _ english: String.LocalizationValue) -> String {
    String(localized: key, defaultValue: english, bundle: .module)
}
