import AppKit
import IslandActivities
import SwiftUI

/// The bundled marks `ActivityContent.mark` names, loaded once and drawn as templates in each
/// agent's own colour — amber for Claude, emerald for Codex, the shades LunoPeak draws them in on a
/// dark background (Tailwind's 400s), and a step lighter under Increase Contrast.
///
/// The files are 44 px black-on-clear glyphs: the expanded well draws a mark at 22 pt, which is
/// 44 px on a Retina display, and the sliver draws it smaller.
@MainActor
enum ActivityMarkImage {

    private static var cache: [ActivityMark: NSImage] = [:]

    static func color(for mark: ActivityMark, increaseContrast: Bool) -> Color {
        switch (mark, increaseContrast) {
        case (.claude, false): Color(.sRGB, red: 251 / 255, green: 191 / 255, blue: 36 / 255)
        case (.claude, true): Color(.sRGB, red: 252 / 255, green: 211 / 255, blue: 77 / 255)
        case (.openAI, false): Color(.sRGB, red: 52 / 255, green: 211 / 255, blue: 153 / 255)
        case (.openAI, true): Color(.sRGB, red: 110 / 255, green: 231 / 255, blue: 183 / 255)
        }
    }

    static func image(for mark: ActivityMark) -> NSImage? {
        if let cached = cache[mark] { return cached }
        let name = switch mark {
        case .claude: "AgentMarkClaude"
        case .openAI: "AgentMarkOpenAI"
        }
        guard let url = Bundle.module.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url)
        else { return nil }
        image.isTemplate = true
        cache[mark] = image
        return image
    }
}
