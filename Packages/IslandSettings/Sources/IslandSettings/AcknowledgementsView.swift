import SwiftUI

/// The acknowledgements card in Settings' About pane.
///
/// Collapsed by default — the obligation is that the notice is *reachable and complete*, not that it
/// occupies the settings window. Expanding shows the license verbatim, because clause 2 asks for the
/// conditions and the disclaimer themselves and a summary is not a reproduction.
struct AcknowledgementsCard: View {

    @State private var expanded: Set<String> = []

    var body: some View {
        SettingsCard(settingsText("about.acknowledgements", "Acknowledgements")) {
            ForEach(Acknowledgements.all) { component in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(component.name).font(.body.weight(.medium))
                        Spacer()
                        Text(component.licenseName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text(component.purpose)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // The line clause 2 exists for. Selectable so it can be copied rather than
                    // retyped by anyone auditing the bundle.
                    Text(component.copyrightNotice)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)

                    HStack(spacing: 12) {
                        Button(isExpanded(component)
                               ? settingsText("about.acknowledgements.hideLicense", "Hide License")
                               : settingsText("about.acknowledgements.showLicense", "Show License")) {
                            toggle(component)
                        }
                        .buttonStyle(.link)
                        .font(.caption)

                        Link(settingsText("about.acknowledgements.project", "Project"), destination: component.url)
                            .font(.caption)
                    }

                    if isExpanded(component) {
                        ScrollView {
                            Text(component.licenseText)
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(height: 180)
                        .padding(8)
                        // A plain fill rather than a second `glassEffect`. This block already sits
                        // on the card's glass, and glass over glass compounds into an opaque slab —
                        // the license text is the one thing in this window that has to stay
                        // straightforwardly readable.
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func isExpanded(_ component: Acknowledgement) -> Bool {
        expanded.contains(component.id)
    }

    private func toggle(_ component: Acknowledgement) {
        if expanded.contains(component.id) {
            expanded.remove(component.id)
        } else {
            expanded.insert(component.id)
        }
    }
}
