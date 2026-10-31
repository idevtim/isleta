import AppKit
import IslandActivities

/// The bundled marks `ActivityContent.mark` names, loaded once and drawn as templates — so they
/// take the content's tint and Increase Contrast exactly as an SF Symbol in the same place does.
///
/// The files are 44 px black-on-clear glyphs: the expanded well draws a mark at 22 pt, which is
/// 44 px on a Retina display, and the sliver draws it smaller.
@MainActor
enum ActivityMarkImage {

    private static var cache: [ActivityMark: NSImage] = [:]

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
