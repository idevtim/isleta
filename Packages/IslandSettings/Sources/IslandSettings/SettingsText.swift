import Foundation

/// Every word the settings window, the first-run flow and the status menu put in front of a person.
///
/// The full argument for the shape — symbolic key, English in the source as the `defaultValue`, no
/// `en.lproj` — is written once, on `activityText` in IslandActivities. What is specific to this
/// package is that **this is where the argued copy lives**, and the rule that follows from it.
///
/// A caption here is not a label. "The weather works either way. With location off, Isleta asks
/// about the city you type instead of the one you are in — nothing else changes." exists in that
/// shape because a shorter version was measured to mislead, and the paragraph above it in
/// `SettingsView` says so. **A translation that cannot carry the argument is a bug to report, not a
/// sentence to shorten** — the second half of that caption is the whole of it, and a German or
/// French rendering that keeps only "The weather works either way" has thrown away the reason the
/// switch is safe to turn off.
///
/// Two consequences, both deliberate:
///
/// - The English stays in this file's call sites rather than moving to a table, so the doc comment
///   arguing for a sentence is still next to that sentence.
/// - `LocalizationCoverageTests` fails when a key added here has no entry in a shipped language,
///   which is what stops a pane going half-translated. It cannot judge whether a translation is
///   *good*; `IslandSettings/README.md` records which ones were hard.
///
/// - Parameters:
///   - key: a stable identifier that survives an edit to the English.
///   - english: the source text, and the fallback for any language Isleta does not yet speak.
func settingsText(_ key: StaticString, _ english: String.LocalizationValue) -> String {
    String(localized: key, defaultValue: english, bundle: .module)
}
