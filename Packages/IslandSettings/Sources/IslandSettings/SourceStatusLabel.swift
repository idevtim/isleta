import SwiftUI

/// What a source can do right now, and the one offer that can raise a permission prompt.
///
/// Extracted because two windows draw it: the Sources pane, where it sits under a switch, and the
/// first-run flow, where it is the whole page. A second copy in the onboarding view would be a
/// second answer to "what does *not asked* look like" — and the two would agree until somebody
/// changed the icon in one of them.
///
/// The `Button` here is **the only path in Isleta that can raise a permission dialog**, wherever it
/// is rendered. That is what §10 means by a moment the user initiated: a control they clicked, in a
/// window they can see, describing what it is about to ask for.
struct SourceStatusLabel: View {

    let row: SourceSettingsRow

    /// Whether to print the state in three words rather than the full sentence. See
    /// `SourceSettingsRow.Status.headline` — true where the surrounding page has already made the
    /// argument the long form exists to make.
    var brief = false

    /// Called after the action runs, so the caller can re-read the authorization and turn the offer
    /// into a status without the user having to close and reopen the window.
    let onAction: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(
                brief ? row.status.headline : row.status.explanation,
                systemImage: Self.symbol(row.status)
            )
            .font(.caption)
            .foregroundStyle(Self.tint(row.status))
            // Wraps rather than truncates. The `.denied` sentences run to three lines, and a status
            // that ends in an ellipsis is one the user cannot act on — the part that says what to do
            // is the part that gets cut.
            .fixedSize(horizontal: false, vertical: true)

            if let action = row.action {
                Button(action.title) {
                    action.perform()
                    onAction()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }

    /// SF Symbols only (§6.5), and one per case rather than one for "not working". A lock says
    /// *you can open this*; a minus in a circle says *there is nothing behind this door* — which is
    /// the distinction `SourceSettingsRow.Status` has three cases to preserve.
    static func symbol(_ status: SourceSettingsRow.Status) -> String {
        switch status {
        case .working: "checkmark.circle"
        case .needsPermission: "lock"
        case .unavailable: "minus.circle"
        }
    }

    /// Orange for the one state the user can act on, secondary for both states they cannot. Green
    /// for "working" was tried and is wrong here: it draws the eye to the rows that need nothing
    /// and leaves the one that needs something competing with three of them.
    static func tint(_ status: SourceSettingsRow.Status) -> Color {
        switch status {
        case .working: .secondary
        case .needsPermission: .orange
        case .unavailable: .secondary
        }
    }
}
