import AppKit
import IslandActivities
import IslandKit
import SwiftUI
import Testing
@testable import IslandUI

@Suite("Audio sources page")
@MainActor
struct AudioApplicationsTests {
    @Test("opening a paused row addresses its own app without changing playback state")
    func openAddressesSelectedApplication() {
        let audio = AudioApplicationsModel()
        let paused = AudioApplication(bundleIdentifier: "spotify", name: "Spotify", state: .paused)
        audio.applications = [paused]
        var opened: String?
        audio.onOpen = { opened = $0 }
        audio.open(paused)
        #expect(opened == "spotify")
        #expect(audio.applications == [paused])
    }

    @Test("the page renders populated and empty states with no system providers",
          .enabled(if: ProcessInfo.processInfo.environment["ISLETA_TEST_AUDIO_RENDER"] == "1"))
    func renderPage() async throws {
        let metrics = IslandShapeMetrics(bodySize: CGSize(width: 368, height: 280),
                                         topCornerRadius: 0, bottomCornerRadius: 22)
        let model = IslandScreenModel(metricsByForm: [.rest: metrics], notchKind: .hardware,
                                      cutoutSize: CGSize(width: 185, height: 32))
        let audio = AudioApplicationsModel()
        model.audioApplications = audio
        for populated in [false, true] {
            audio.applications = populated ? [
                AudioApplication(bundleIdentifier: "com.google.Chrome", name: "Google Chrome",
                                 title: "A video on YouTube", state: .active),
                AudioApplication(bundleIdentifier: "com.spotify.client", name: "Spotify",
                                 title: "A paused song", state: .paused),
                AudioApplication(bundleIdentifier: "com.apple.Music", name: "Music", state: .inactive),
            ] : []
            let view = IslandAudioPageView(model: model).frame(width: 440, height: 320).background(.black)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 440, height: 320),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            window.orderBack(nil)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            window.orderOut(nil)
            try png.write(to: URL(fileURLWithPath: "/tmp/isleta-audio-\(populated ? "populated" : "empty").png"))
        }
    }
}
