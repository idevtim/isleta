import AppKit
import SwiftUI

/// A page that is about one permission: a picture of the dialog that is coming, a sentence saying
/// what it buys, the apps it buys it for, and a line saying which button to press.
///
/// ## Why the page shows a mock of the dialog
///
/// A TCC dialog arrives with no context. It names a framework, it is answered in about a second by
/// somebody who did not know it was coming, and the app that caused it is not on screen. Every
/// permission Isleta has was being asked for that way — Bluetooth three seconds after login,
/// Calendar from a settings pane nobody opened, Accessibility never at all.
///
/// The drawing above the headline is that dialog, one click early: Isleta's own icon badged with the
/// permission, two bars where its sentence goes, and its two buttons with the one to press picked
/// out. It is deliberately **not** a faithful copy — no real text, no Apple wordmark, no system
/// artwork — because a convincing replica of a security dialog is a phishing lesson, and because
/// Apple redraws these between releases and a replica would be wrong within a year. It has to read
/// as *a dialog is about to appear and this is the shape of it*, and nothing more.
///
/// ## The offer is repeatable, and it is still not a wall
///
/// Continue asks, then reads the answer back. If the user allowed, the page advances. If they
/// dismissed the dialog without answering, the page **stays** and offers again — this is what the
/// owner asked for, and it is honest, because TCC still holds no answer and the dialog genuinely
/// will show a second time. If they refused, the page stays once to say what is switched off, and
/// the primary button becomes System Settings.
///
/// In every one of those states there is a way forward: `Skip` appears the moment Continue stops
/// being the thing that advances. That is the line between asking twice and nagging, and §10 puts
/// it exactly there — the flow may re-offer, and it may never be the only way out. Closing the
/// window still counts as finished, as it did before.
struct OnboardingPermissionPage: View {

    let permission: OnboardingPermission

    /// Nil in a preview, in a unit test, and on a Mac where the app shell could not describe this
    /// permission. The page then draws its explanation with no offer, which is the correct thing to
    /// show when nothing can be asked — not an error, and not a disabled button.
    let state: OnboardingState.Permission?

    var body: some View {
        VStack(spacing: 18) {
            PermissionDialogPreview(symbol: permission.symbol)

            Text(permission.headline(for: state?.access ?? .notDetermined))
                .font(.system(.title3, weight: .semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)

            if let payoff = state?.payoff, !payoff.isEmpty {
                PermissionPayoffRow(items: payoff)
            }

            Text(caption)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)

            Spacer(minLength: 0)
        }
    }

    /// The grey line under the row, which is a different sentence in each of the three states — and
    /// is the whole of what the page has to say once the answer is in.
    private var caption: String {
        switch state?.access {
        case .granted: permission.granted
        case .notNeeded: permission.notNeeded()
        case .denied: permission.denied
        // `.notDetermined` and *no state at all* get the same sentence, which is the one that says
        // what is about to happen. A page that cannot ask still explains what the permission is
        // for; it simply has no button that acts on it.
        case .notDetermined, nil: permission.instruction
        }
    }
}

/// A drawing of the system dialog that is about to appear.
///
/// Placeholder bars rather than text, for three reasons and each of them independently decides it:
/// Apple's sentence is Apple's and changes between releases; it would need translating into three
/// languages to say something the real dialog is about to say correctly in all of them; and a page
/// that prints the dialog's words is one a user reads instead of the dialog. Bars say *a dialog,
/// with a sentence in it* and get out of the way.
private struct PermissionDialogPreview: View {

    let symbol: String

    @Environment(\.colorScheme) private var colorScheme

    /// Slightly wider than tall, which is the proportion of every TCC dialog on macOS. The number
    /// that matters is the ratio rather than either dimension — at these sizes the eye reads the
    /// shape long before it reads anything in it.
    private let size = CGSize(width: 186, height: 176)

    var body: some View {
        VStack(spacing: 14) {
            badgedIcon

            VStack(spacing: 7) {
                bar(width: 118)
                bar(width: 74)
            }

            HStack(spacing: 10) {
                button(tinted: false)
                // The tinted one is on the right, where macOS puts the default action, and it is
                // the *only* colored thing in the drawing. That is the whole instruction the picture
                // carries on its own: this is the button.
                button(tinted: true)
            }
        }
        .padding(.vertical, 20)
        .frame(width: size.width, height: size.height)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(SettingsPalette.card(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(SettingsPalette.hairline(colorScheme), lineWidth: 1)
        )
        // One element to VoiceOver, and a description rather than a reading. Its parts are
        // placeholders — a screen reader announcing four unlabelled shapes would be worse than
        // silence, and the headline directly below says what this is a picture of.
        .accessibilityElement()
        .accessibilityLabel(settingsText(
            "onboarding.permission.preview.a11y",
            "A preview of the macOS permission dialog that appears next."
        ))
    }

    /// Isleta's own icon with the permission badged on it, which is how macOS draws these itself.
    private var badgedIcon: some View {
        AppIconView(size: 56)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(SettingsPalette.bright)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(SettingsPalette.card(colorScheme), lineWidth: 2)
                    )
                    .offset(x: 7, y: 7)
            }
    }

    private func bar(width: CGFloat) -> some View {
        Capsule(style: .continuous)
            .fill(.tertiary)
            .frame(width: width, height: 6)
    }

    private func button(tinted: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(tinted ? AnyShapeStyle(SettingsPalette.bright) : AnyShapeStyle(.quaternary))
            .frame(width: 62, height: 21)
    }
}

/// The apps or devices this permission is about, in a row of up to three.
///
/// Hairlines between the columns rather than around each one, which is what macOS does wherever it
/// groups peers — a box per icon reads as three things to choose between, and there is nothing here
/// to choose.
private struct PermissionPayoffRow: View {

    let items: [OnboardingState.Payoff]

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.prefix(3).enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Rectangle()
                        .fill(SettingsPalette.hairline(colorScheme))
                        .frame(width: 1, height: 54)
                }
                column(item)
            }
        }
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: SettingsSurface.cornerRadius, style: .continuous)
                .fill(SettingsPalette.card(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: SettingsSurface.cornerRadius, style: .continuous)
                .strokeBorder(SettingsPalette.hairline(colorScheme), lineWidth: 1)
        )
    }

    private func column(_ item: OnboardingState.Payoff) -> some View {
        VStack(spacing: 7) {
            Group {
                if let icon = item.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                } else {
                    // The fallback is a symbol on the app's own teal, not a grey box: a row where
                    // one column is missing artwork should look like three things, and a blank
                    // square looks like a bug.
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(SettingsPalette.bright.opacity(0.16))
                        .overlay {
                            Image(systemName: item.symbol)
                                .font(.system(size: 20, weight: .regular))
                                .foregroundStyle(SettingsPalette.bright)
                        }
                }
            }
            .frame(width: 44, height: 44)

            Text(item.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        // A **fixed** column width, so the card is as wide as it has columns rather than always as
        // wide as the page. Three of these is 354pt, which is where the row was drawn to sit; one of
        // them is 118pt and reads as a deliberate single item. `maxWidth: .infinity` inside a
        // 380pt card was the first version, and on a Mac with only Apple's Calendar installed — or
        // only Music, which is most of them — it left one small icon adrift in the middle of a wide
        // empty box that looked like two icons had failed to load.
        .frame(width: 118)
        // One element per column: the icon is decoration and the name is the label, so VoiceOver
        // should hear "Spotify" rather than "image, Spotify".
        .accessibilityElement()
        .accessibilityLabel(item.name)
    }
}
