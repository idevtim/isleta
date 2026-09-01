import AppKit
import SwiftUI

/// The panes of the settings window, in the order they are listed.
///
/// An enum rather than a hand-built `List` of views, because the sidebar, the detail pane and the
/// window's restored selection all have to agree on what exists. A `String` selection would let the
/// three drift the day a pane is renamed; here a new pane is a `case` and the `switch` in
/// `SettingsView.detail` stops compiling until it has somewhere to go.
///
/// The ordering is not alphabetical and not arbitrary. It runs from what the user is most likely to
/// have opened the window for — whether Isleta starts with the Mac — through what the island is
/// allowed to say and what the glance looks at, to the pane a person visits once. `about` is last
/// because it is where destructive things live.
///
/// **A pane has to be worth walking to.** Five have been removed rather than kept. `system` held one
/// switch that `SystemHUDSuppression` can never let move; `shortcut` held one row, which now sits
/// under Startup in `general`; `updates` held one switch and one button, which sit there too.
/// `island` and `appearance` went in schema 18 along with everything in them — eight sliders, a
/// style picker, a per-kind side table — none of which had a second right answer to offer. A sidebar
/// entry is a promise that there is something behind it, and a pane holding a single control that a
/// user has to select the row to discover breaks that promise in both directions: it costs a click
/// and it is empty when you arrive. If a new pane would have one card in it, it belongs in an
/// existing pane instead.
/// Public so a caller can ask for a pane by name — `SettingsWindowController.show(section:)`. The
/// alternative was a second, public enum mirroring this one, which is the mistake `SourceToggles`
/// documents at length: two spellings of one vocabulary that agree until somebody adds a case to
/// one of them.
public enum SettingsSection: String, CaseIterable, Identifiable, Sendable {

    case general
    case sources
    case glance
    case about

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .general: settingsText("settings.pane.general", "General")
        case .sources: settingsText("settings.pane.sources", "Sources")
        case .glance: settingsText("settings.pane.glance", "Glance")
        case .about: settingsText("settings.pane.about", "About")
        }
    }

    /// SF Symbols only (§6.5). Chosen to say what the pane is about rather than to be pretty:
    /// `sources` gets the aerial that feeds the island.
    public var symbol: String {
        switch self {
        case .general: "gearshape"
        case .sources: "dot.radiowaves.left.and.right"
        // The pane holds two cards — which calendars, and where — so it clears the bar this type's
        // own note sets. The glyph is the calendar rather than the weather because the calendar half
        // is the one that works without a signing change; see `WeatherKitProvider`.
        case .glance: "calendar"
        case .about: "info.circle"
        }
    }

    /// The color of the pane's icon chip, in the sidebar and in the pane's own header.
    ///
    /// System colors, never literals. These are the four colors macOS itself adapts for dark
    /// appearance, for increase contrast and for the colorblind accommodations — a hand-picked hex
    /// would be one of the few things in this window that stayed exactly as chosen when a user
    /// asked the system to change it, which §6.3 treats as a correctness failure rather than a
    /// styling one.
    ///
    /// Chosen for what the pane is, so the four are told apart by more than position:
    /// `sources` is teal because it is the pane that carries Isleta's own subject, and it is the
    /// one color here that also appears in the icon.
    var tint: Color {
        switch self {
        case .general: .gray
        case .sources: .teal
        case .glance: .orange
        case .about: .blue
        }
    }
}

/// A pane's icon, as a filled rounded square.
///
/// One type, used by the sidebar row and by the pane header, because the two have to be the same
/// object — a header whose chip is a different size or corner from the row that leads to it reads
/// as a different icon for the same thing.
///
/// **The glyph is white rather than `.primary`.** It sits on a saturated fill in both appearances,
/// and `.primary` would turn it black on orange in light mode — legible, but no longer the pair of
/// tones every other chip in the list is drawn with.
struct SectionIcon: View {

    let section: SettingsSection

    /// Matched to the sidebar's row height rather than to the text: a chip that grows with Dynamic
    /// Type pushes the rows apart faster than the labels need, and the glyph inside it is what
    /// carries the meaning at any size.
    var size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(section.tint)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: section.symbol)
                    .font(.system(size: size * 0.58, weight: .semibold))
                    .foregroundStyle(.white)
            }
            // The label beside it already says the pane's name, so the chip is decoration to a
            // screen reader and announcing it would read the name twice.
            .accessibilityHidden(true)
    }
}

/// Isleta's own icon, at whatever size it is asked for.
///
/// Read from the running application rather than from a bundled asset. The app icon is already in
/// the bundle — `Isleta.icon`, compiled by Icon Composer — and a second copy inside this package
/// would be a copy that is right until the day the icon changes and nobody remembers there were two.
/// It also means this module needs no asset catalog of its own, which is what keeps it building
/// and previewing standalone.
///
/// The fallback matters more than it looks. In a SwiftUI preview, and in a unit test, there is no
/// application icon to read: `NSImage(named:)` answers nil and an `Image(nsImage:)` built from a nil
/// image is a crash. Drawing the app's own gradient instead keeps the preview honest about the
/// layout without pretending to be the icon.
struct AppIconView: View {

    var size: CGFloat = 64

    var body: some View {
        Group {
            if let icon = NSImage(named: NSImage.applicationIconName) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [SettingsPalette.deep, SettingsPalette.bright],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// What Isleta calls itself, read from the bundle.
///
/// One definition, used by the About pane, the sidebar header and the app shell's status menu.
/// Three call sites each reaching into `Bundle.main.infoDictionary` is three places to update the
/// day the format changes, and — as the status menu proved by reading "Isleta — Milestone 0" for
/// four milestones — a hardcoded one is a string nobody remembers is there.
public enum AppVersion {

    public static var name: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Isleta"
    }

    /// The marketing version — `CFBundleShortVersionString`. Nil in a preview or a test bundle,
    /// which has no app to ask.
    public static var marketing: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// The build — `CFBundleVersion`. Deliberately **not** shown anywhere in the interface.
    ///
    /// A build number is for telling two copies of the same release apart, which is a thing Sparkle
    /// and a bug report need to do and a person reading Settings does not. Shown, it is a second
    /// number beside the version that most users read as part of it and none can act on. It stays in
    /// the bundle, where the updater compares it, and it belongs in a diagnostics report rather than
    /// on screen.
    public static var build: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    /// "Isleta 1.0.0" — for the status menu, where the name has to be there too.
    public static var nameAndVersion: String {
        guard let marketing else { return name }
        return "\(name) \(marketing)"
    }

    /// "Version 1.0.0" — for Settings, where the name is already on screen above it.
    ///
    /// Falls back to a sentence rather than to `"Version nil"`, which is what a preview and the test
    /// bundle would otherwise show.
    public static var settingsSummary: String {
        guard let marketing else { return settingsText("about.version.development", "Development build") }
        return settingsText("about.version", "Version \(marketing)")
    }
}
