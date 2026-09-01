import Foundation

/// The app shell's own words — the sentences `SourceHub` writes about each source, and the handful
/// of panels and alerts that only an application can put on screen.
///
/// The full argument for the shape — symbolic key, English in the source as the `defaultValue`, no
/// `en.lproj` — is written once, on `activityText` in IslandActivities. Two things are specific to
/// the shell.
///
/// **The bundle is `.main`, and it is the one bundle everything else depends on.** Measured on
/// macOS 27.0: a package's resource bundle is only ever consulted in a language the **main** bundle
/// also claims. With `-AppleLanguages '(de)'` and no `de` on the app, `Bundle.module.preferredLocalizations`
/// for every package collapses to `["en"]` and each one silently draws English — no warning, no log
/// line, nothing to look at. So `Config/Isleta-Info.plist`'s `CFBundleLocalizations` and the
/// `.lproj` folders under `Isleta/Resources` are what switch the other four packages on, and
/// dropping a language there turns it off everywhere at once.
///
/// **`SourceHub`'s prose is here rather than in IslandSettings on purpose, and localizing it does
/// not move it.** `SourceSettingsRow` is a value handed *in*: IslandSettings must build and preview
/// with nothing granted, so the shell — the one layer that sees both a source's `authorization` and
/// `IsletaConfiguration` — is what phrases the row. That argument is about which layer may *read*
/// the state, and it is untouched by which language the sentence is written in.
///
/// - Parameters:
///   - key: a stable identifier that survives an edit to the English.
///   - english: the source text, and the fallback for any language Isleta does not yet speak.
func appText(_ key: StaticString, _ english: String.LocalizationValue) -> String {
    String(localized: key, defaultValue: english, bundle: .main)
}
