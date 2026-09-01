import Foundation

/// Every word the island itself puts on screen, in the language the user reads.
///
/// The full argument for the shape — symbolic key, English in the source as the `defaultValue`, no
/// `en.lproj` — is written once, on `activityText` in IslandActivities. Two things are specific to
/// this package and are the reason it has its own table rather than sharing that one.
///
/// **The island cannot grow.** `ActivitySlotLayout`, `DropHistoryLayout`, `NowPlayingQueueLayout`
/// and `GlanceLayout` all compute against fixed widths, and a translated
/// string that does not fit is truncated rather than accommodated — see `IslandUI/README.md`, which
/// records what was measured and what the truncation rule is. So a string in this package is
/// written to a length budget in a way a settings caption is not, and keeping the two tables apart
/// keeps that constraint attached to the strings it applies to.
///
/// **`Text` is the trap here.** `Text("some literal")` is a `LocalizedStringKey` and would look up
/// the literal against **`Bundle.main`**, which is the app — not this package — so it would silently
/// find nothing and draw the English. Every string on the island therefore goes through this
/// function and reaches SwiftUI as an already-resolved `String`, which `Text.init<S: StringProtocol>`
/// draws verbatim. That also means one mechanism covers `Text`, `.help`, `.accessibilityLabel`,
/// `NSMenuItem.title` and a `TextField` prompt, instead of four spellings with four ways to be wrong.
///
/// - Parameters:
///   - key: a stable identifier that survives an edit to the English.
///   - english: the source text, and the fallback for any language Isleta does not yet speak.
func islandText(_ key: StaticString, _ english: String.LocalizationValue) -> String {
    String(localized: key, defaultValue: english, bundle: .module)
}
