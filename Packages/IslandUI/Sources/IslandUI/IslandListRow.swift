import Foundation
import SwiftUI

/// A row that lights up under the pointer and dims while pressed, and draws no button chrome.
///
/// `.plain` alone would leave a row with no press feedback at all, on a surface where the click
/// does something irreversible-looking (the island closes and the row is gone). The highlight is
/// what says the whole row is the target rather than the words in it.
///
/// Generic on purpose. It was `RecentsRowButtonStyle`, written for the notification list and
/// borrowed by the drop history; the list went with notifications and the borrower is now the only
/// caller, so it takes a name that describes a row in a list rather than a subject it no longer has.
struct IslandListRowButtonStyle: ButtonStyle {

    let increaseContrast: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // The shape is the row, including the gaps between its words — a row whose hit region
            // was the text would be a list you have to aim at.
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(configuration.isPressed ? (increaseContrast ? 0.24 : 0.12) : 0))
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// How long ago a row's subject happened, in as few glyphs as possible.
///
/// A plain `enum` rather than a `static func` on the view, and that is not tidiness: a `static func`
/// on a `View` is `@MainActor` by inheritance, and the first nonisolated test to call one takes the
/// **whole bundle down with a signal** after every other suite has reported passing. That is exactly
/// what happened when this was written on the view, and CLAUDE.md already had the note.
public enum IslandListFormat {

    /// `now`, `4m`, `2h`, `3d`. Never "0m", which reads as broken rather than as recent.
    public static func age(seconds: TimeInterval) -> String {
        let elapsed = max(0, seconds)
        // Four keys rather than `RelativeDateTimeFormatter`, and the reason is the column this
        // is drawn in: it is a fixed width at the trailing edge of every row, and the formatter's
        // output length is not ours to bound — "vor 4 Minuten" where the layout has room for "4m".
        // A translator gets the same one-or-two-glyph budget the English had, and a language that
        // genuinely cannot abbreviate to it is reported rather than silently truncated.
        if elapsed < 60 { return islandText("list.age.now", "now") }
        if elapsed < 3600 { return islandText("list.age.minutes", "\(Int(elapsed / 60))m") }
        if elapsed < 86_400 { return islandText("list.age.hours", "\(Int(elapsed / 3600))h") }
        return islandText("list.age.days", "\(Int(elapsed / 86_400))d")
    }
}
