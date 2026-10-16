import IslandActivities
import IslandKit
import SwiftUI

struct IslandAudioPageView: View {
    let model: IslandScreenModel
    @State private var scrollPosition = ScrollPosition(y: 0)

    var body: some View {
        GeometryReader { proxy in
            let width = model.contentBodyWidth
            let origin = IslandLayout.bodyOrigin(bodyWidth: width, in: proxy.size)
            VStack(alignment: .leading, spacing: AudioApplicationsLayout.headerSpacing) {
                Text(islandText("page.audio", "Audio sources"))
                    .font(.system(size: 13, weight: .semibold))
                    .frame(height: AudioApplicationsLayout.headerHeight, alignment: .leading)
                if let audio = model.audioApplications, !audio.applications.isEmpty {
                    // The island owns gesture routing. A native enabled scroller consumes the
                    // horizontal sequence before the carousel can see it.
                    ScrollView(.vertical) {
                        LazyVStack(spacing: AudioApplicationsLayout.rowSpacing) {
                            ForEach(audio.applications) { application in
                                row(application, audio: audio)
                            }
                        }
                        .frame(height: AudioApplicationsLayout.contentExtent(rowCount: audio.applications.count), alignment: .top)
                    }
                    .scrollDisabled(true)
                    .scrollPosition($scrollPosition)
                    .frame(height: AudioApplicationsLayout.viewportHeight)
                    .onChange(of: audio.scrollTarget, initial: true) { _, target in
                        scrollPosition.scrollTo(y: target.offset)
                    }
                } else {
                    Spacer()
                    Text(islandText("audioSources.empty", "No audio sources detected"))
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(model.increaseContrast ? 0.9 : 0.6))
                        .frame(maxWidth: .infinity)
                    Spacer()
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, AudioApplicationsLayout.verticalPadding)
            .frame(width: width, height: IslandPageHeight.layoutHeight(
                for: .audio, glance: model.glance, cutoutHeight: model.cutoutSize.height
            ), alignment: .top)
            .offset(x: origin.x, y: origin.y + model.cutoutSize.height)
        }
    }

    private func row(_ application: AudioApplication, audio: AudioApplicationsModel) -> some View {
        Button { audio.open(application) } label: {
            HStack(spacing: 10) {
                if let icon = model.applicationIcons.icon(forBundleIdentifier: application.bundleIdentifier) {
                    Image(decorative: icon, scale: 2).resizable().frame(width: 26, height: 26)
                } else {
                    Image(systemName: "waveform").frame(width: 26, height: 26)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(application.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if let title = application.title {
                        Text(title)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(model.increaseContrast ? 0.9 : 0.6))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Text(stateName(application.state)).font(.system(size: 10, weight: .medium))
                Image(systemName: "arrow.up.forward").font(.system(size: 11, weight: .semibold))
            }
            .frame(height: AudioApplicationsLayout.rowHeight - 16)
            .padding(8)
            .background(.white.opacity(model.increaseContrast ? 0.14 : 0.07), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(islandText("audioSources.open", "Open application"))
    }

    private func stateName(_ state: AudioApplication.State) -> String {
        switch state {
        case .active: islandText("audioSources.active", "Active")
        case .paused: islandText("audioSources.paused", "Paused")
        case .inactive: islandText("audioSources.inactive", "Inactive")
        }
    }
}
