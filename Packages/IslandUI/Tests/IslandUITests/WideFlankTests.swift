import AppKit
import CoreGraphics
import Foundation
import IslandActivities
import IslandKit
import Testing

@testable import IslandUI

/// Whether the word actually fits in the sliver the island grew for it.
///
/// The island's flank is a *constant* — §4.2 needs a settled shape for hit testing to stay exact —
/// so nothing at runtime can notice a label that does not fit, and a translation that overruns is a
/// word truncated to an ellipsis in the notch. That failure has happened once already on this
/// surface: `ActivityContentView.flankPadding` records a temperature drawn as "…" until the island
/// was opened. This is the arithmetic behind `IslandLayout.wideFlankedWidthGrowth`, so the two
/// cannot drift apart.
@Suite("Wide flanks")
struct WideFlankLayoutTests {

    /// A 14" MacBook Pro's cutout.
    private static let cutout = CGSize(width: 185, height: 32)

    private static let screen = IslandScreen(
        id: 1, name: "Built-in",
        frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
        backingScaleFactor: 2,
        notch: NotchGeometry(
            kind: .hardware,
            rect: CGRect(x: 771.5, y: 1085, width: cutout.width, height: cutout.height)
        )
    )

    private func layout(_ form: IslandForm) -> ActivitySlotLayout {
        ActivitySlotLayout.resolve(
            bodySize: IslandLayout.metrics(for: form, on: Self.screen).bodySize,
            cutoutSize: Self.cutout
        )
    }

    /// **Measured, not asserted from memory.** The longest label the four shipped languages produce
    /// is German's "Lautstärke"; the figures were taken in real SF Pro on 2026-08-28 and are
    /// re-measured here on every run rather than hardcoded, because a system font update moves them.
    ///
    /// Held as strings rather than read through `SystemHUD.label`, and that is deliberate: SwiftPM
    /// gives a test process no main bundle to negotiate a language against, so every lookup in this
    /// target answers in English (`docs/LOCALIZATION.md`). A test that asked the type would be
    /// measuring English three times and calling it coverage.
    private static let shippedLabels = [
        "Volume", "Muted", "Display",              // en
        "Lautstärke", "Stumm", "Bildschirm",       // de
        "Volumen", "Silenciado", "Pantalla",       // es
        "Volume", "Son coupé", "Écran",            // fr
    ]

    /// The same list for power, which spells itself in the sliver one span further out — see
    /// `IslandLayout.widerFlankedWidthGrowth`. Six announcements in four languages, held as strings
    /// for `shippedLabels`' reason: a test process has no main bundle to negotiate a language
    /// against, so asking `BuiltInActivity.power` would measure English six times and call it
    /// coverage. IslandSources cannot be seen from here in any case.
    private static let shippedPowerLabels = [
        "Charging", "On Battery", "Charged",
        "Low Battery", "Low Power On", "Low Power Off",                       // en
        "Lädt auf", "Akkubetrieb", "Geladen",
        "Akku fast leer", "Sparmodus ein", "Sparmodus aus",                   // de
        "Cargando", "Con batería", "Cargada",
        "Batería baja", "Ahorro activo", "Ahorro inactivo",                   // es
        "En charge", "Sur batterie", "Chargé",
        "Batterie faible", "Éco activée", "Éco désactivée",                   // fr
    ]

    /// The widest glyph any built-in HUD puts beside its word.
    private static var widestSymbolWidth: CGFloat {
        symbolWidth(of: SystemHUD.allCases.map(\.symbol))
    }

    /// The same for power, and it is **wider than any HUD glyph** — every `battery.*` symbol
    /// measures the same 23pt, against `speaker.wave.2.fill`'s 20. That 3pt is why the second span
    /// is not simply the first plus the difference in words.
    private static var widestPowerSymbolWidth: CGFloat {
        symbolWidth(of: [
            "battery.100percent.bolt", "battery.100percent", "battery.75percent",
            "battery.50percent", "battery.25percent", "battery.0percent",
            "bolt.badge.a.fill", "bolt.fill",
        ])
    }

    private static func symbolWidth(of names: [String]) -> CGFloat {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        return names.compactMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)?.size.width
        }.max() ?? 0
    }

    /// Exactly what `ActivityContentView.flank(alignment:)` lays out: an inset each end, the glyph,
    /// the 4pt spacing, and the word.
    private func room(in flank: CGFloat, beside symbol: CGFloat) -> CGFloat {
        flank - 2 * ActivityContentView.flankPadding(for: ActivityContent(symbol: "sun.max.fill"))
            - symbol - 4
    }

    private func width(of label: String) -> CGFloat {
        (label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).width
    }

    @Test("every shipped label fits beside the glyph without tightening")
    func labelsFitTheSliver() throws {
        let flank = try #require(layout(.wideFlankedRest).leading?.width)
        #expect(flank == IslandLayout.wideFlankedFlankWidth)

        let room = room(in: flank, beside: Self.widestSymbolWidth)
        for label in Self.shippedLabels {
            #expect(width(of: label) <= room, "\(label) needs \(width(of: label))pt of \(room)")
        }
    }

    /// The same arithmetic for power, against its own sliver and its own glyph.
    @Test("every shipped power label fits beside the battery glyph without tightening")
    func powerLabelsFitTheWidestSliver() throws {
        let flank = try #require(layout(.widerFlankedRest).leading?.width)
        #expect(flank == IslandLayout.widerFlankedFlankWidth)

        let room = room(in: flank, beside: Self.widestPowerSymbolWidth)
        for label in Self.shippedPowerLabels {
            #expect(width(of: label) <= room, "\(label) needs \(width(of: label))pt of \(room)")
        }
    }

    /// **The wide sliver is the control for the widest one**, exactly as the standard sliver is the
    /// control for the wide one: it cannot hold the phrases power says. If this ever passes,
    /// `IslandFlanks.wider` has stopped being necessary and should go rather than sit there as a
    /// second spelling of `.wide` — and the shape language gets one fewer island back.
    @Test("the wide sliver could not have held power's phrases")
    func wideSliverIsTooNarrowForPower() throws {
        let flank = try #require(layout(.wideFlankedRest).leading?.width)
        let room = room(in: flank, beside: Self.widestPowerSymbolWidth)
        let overruns = Self.shippedPowerLabels.filter { width(of: $0) > room }
        #expect(!overruns.isEmpty, "every power label fits the HUD's sliver; drop the fourth span")
        // English's own phrase is one of them, so this is not a fact about translation alone.
        #expect(width(of: "On Battery") > room)
    }

    /// The standard sliver is the control: it cannot hold a word, which is the whole reason the wide
    /// one exists. If this ever passes, `IslandFlanks.wide` has stopped being necessary and should go
    /// rather than sit there as a second spelling of `.standard`.
    @Test("the standard sliver could not have held the word")
    func standardSliverIsTooNarrow() throws {
        let flank = try #require(layout(.flankedRest).leading?.width)
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let word = ("Volume" as NSString).size(withAttributes: [.font: font]).width
        #expect(flank < Self.widestSymbolWidth + 4 + word)
    }

    /// A wide island still draws its slivers *beside* the hole, and still draws nothing under it —
    /// the flank is wider, not the shape taller. See `IslandLayout.flankedHeightGrowth`.
    @Test("a wide island affords two slivers and no body")
    func widerFlanksNoBody() {
        let resolved = layout(.wideFlankedRest)
        #expect(resolved.affordsFlanks)
        #expect(!resolved.affordsBody)
        #expect(resolved.leading?.width == resolved.trailing?.width)
        #expect(resolved.leading?.height == Self.cutout.height)
    }

    /// The island's shape follows what is on stage, which is the whole of the plumbing between
    /// `ActivityStage.flanks` and `IslandLayout.metrics`.
    @MainActor
    @Test("a HUD on stage puts the island in the wide form and music does not")
    func modelReachesTheWideForm() {
        let model = IslandScreenModel(
            metricsByForm: Dictionary(
                uniqueKeysWithValues: IslandForm.allCases.map {
                    ($0, IslandLayout.metrics(for: $0, on: Self.screen))
                }
            ),
            notchKind: .hardware,
            cutoutSize: Self.cutout
        )

        model.setActivity(
            ActivityStage(primary: BuiltInActivity.nowPlaying(title: "Blue in Green"), primaryFlank: .leading),
            change: .presented("builtin.nowPlaying"),
            reduceMotion: true
        )
        #expect(model.form == .flankedRest)

        model.setActivity(
            ActivityStage(primary: BuiltInActivity.systemHUD(.volume, level: 0.3), primaryFlank: .leading),
            change: .swapped(from: "builtin.nowPlaying", to: "builtin.systemHUD"),
            reduceMotion: true
        )
        #expect(model.form == .wideFlankedRest)
        #expect(model.metrics.bodySize.width > IslandLayout.metrics(for: .flankedRest, on: Self.screen).bodySize.width)

        // And back to the cutout when the HUD expires with nothing behind it.
        model.setActivity(nil, change: .dismissed("builtin.systemHUD"), reduceMotion: true)
        #expect(model.form == .rest)
    }

    /// **The comparison the app shell makes before it widens the hit region.** A HUD arriving over
    /// music leaves "has flank content" true either side of the change while moving the outline by
    /// 112pt — so the shell asks for the *span*, and a flag here would answer "nothing moved".
    @MainActor
    @Test("a HUD replacing music moves the outline even though both have flank content")
    func spanDistinguishesWhatAFlagCannot() {
        let music = ActivityStage(
            primary: BuiltInActivity.nowPlaying(title: "So What"), primaryFlank: .leading
        )
        let hud = ActivityStage(
            primary: BuiltInActivity.systemHUD(.brightness, level: 0.8), primaryFlank: .leading
        )
        #expect(IslandScreenModel.hasFlankContent(in: music) == IslandScreenModel.hasFlankContent(in: hud))
        #expect(IslandScreenModel.flanks(in: music) != IslandScreenModel.flanks(in: hud))
    }
}
