import Foundation

/// The words the sources themselves supply — a greeting, a refusal, what a call is doing.
///
/// The full argument for the shape — symbolic key, English in the source as the `defaultValue`, no
/// `en.lproj` — is written once, on `activityText` in IslandActivities. What is specific to this
/// package is **which strings belong here and which ones must never come near it**, because this is
/// the package where user content and Isleta's own words sit closest together.
///
/// Localize: an `ActivityContent.subtitle` a source composes itself ("Call in progress"), a
/// `SourceAuthorization.denied(explanation:)`, a `WelcomeBackGreeting`.
///
/// Never localize, and none of these is a judgement call:
///
/// - **Anything that reaches `IslandLog`.** The log is written for whoever debugs it and is emailed
///   to strangers by "Export Logs…", so it is English wherever it is read. A translated log line
///   would also break every existing grep in `docs/`.
/// - **Anything the *system* named.** A track title, a notification's text, an app's display name,
///   a volume's name, a calendar's title, a device name. macOS has already localized what it can,
///   and translating a proper noun is how "Music" becomes something no search finds. Note that
///   `NotificationAppKey.normalize` folds against the **root** locale for exactly this family of
///   reasons and is not to be made locale-sensitive.
/// - **Any string that is persisted or matched on** — a `DropHistory` action id, an `ActivityKind`
///   raw value, a `UserDefaults` key. A translated key is a record the same Mac cannot read back
///   after a language change.
///
/// - Parameters:
///   - key: a stable identifier that survives an edit to the English.
///   - english: the source text, and the fallback for any language Isleta does not yet speak.
func sourceText(_ key: StaticString, _ english: String.LocalizationValue) -> String {
    String(localized: key, defaultValue: english, bundle: .module)
}
