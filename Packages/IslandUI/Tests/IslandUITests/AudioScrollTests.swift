import AppKit
import CoreGraphics
import IslandActivities
import IslandKit
import SwiftUI
import Testing
@testable import IslandUI

@Suite("Audio list scroll routing")
@MainActor
struct AudioScrollTests {
    private func audio() -> AudioApplicationsModel {
        let model = AudioApplicationsModel()
        model.applications = (0..<8).map {
            AudioApplication(bundleIdentifier: "test.\($0)", name: "Source \($0)", state: .paused)
        }
        return model
    }

    @Test("horizontal gestures and their vertical drift stay on the carousel")
    func horizontal() {
        let model = audio()
        #expect(!model.scrollIfVertical(.init(phase: .began, deltaX: 0)))
        #expect(!model.scrollIfVertical(.init(phase: .changed, deltaX: -40, deltaY: -2)))
        #expect(!model.scrollIfVertical(.init(phase: .changed, deltaX: 1, deltaY: -20)))
        #expect(!model.scrollIfVertical(.init(phase: .ended, deltaX: 0)))
        #expect(!model.scrollIfVertical(.init(phase: .momentum, deltaX: -8, deltaY: -25)))
        #expect(model.scrollTarget.offset == 0)
    }

    @Test("vertical scrolling retains its axis through diagonal movement and momentum")
    func vertical() {
        let model = audio()
        _ = model.scrollIfVertical(.init(phase: .began, deltaX: 0))
        #expect(model.scrollIfVertical(.init(phase: .changed, deltaX: -1, deltaY: -40)))
        #expect(model.scrollIfVertical(.init(phase: .changed, deltaX: -20, deltaY: -2)))
        #expect(model.scrollIfVertical(.init(phase: .ended, deltaX: 0)))
        #expect(model.scrollIfVertical(.init(phase: .momentum, deltaX: 0, deltaY: -10)))
        #expect(model.scrollTarget.offset == 52)
        #expect(model.scrollIfVertical(.init(phase: .momentumEnded, deltaX: 0)))
        #expect(!model.scrollIfVertical(.init(phase: .began, deltaX: -20)))
    }

    @Test("the mouse wheel, natural scrolling and changing row counts stay bounded")
    func wheelAndRows() {
        let model = audio()
        #expect(model.scrollIfVertical(.init(phase: .discrete, deltaX: 0, deltaY: -1, isPrecise: false)))
        let before = model.scrollTarget.offset
        #expect(before > 0)
        _ = model.scrollIfVertical(.init(phase: .began, deltaX: 0))
        _ = model.scrollIfVertical(.init(phase: .changed, deltaX: 0, deltaY: 5, isDirectionInverted: true))
        #expect(model.scrollTarget.offset == before - 5)
        _ = model.scrollIfVertical(.init(phase: .changed, deltaX: 0, deltaY: -10000))
        #expect(model.scrollTarget.offset == AudioApplicationsLayout.scrollExtent(rowCount: 8))
        model.applications = Array(model.applications.prefix(2))
        #expect(model.scrollTarget.offset == 0)
        #expect(AudioApplicationsLayout.scrollExtent(rowCount: 3) == 0)
        #expect(AudioApplicationsLayout.scrollExtent(rowCount: 4) > 0)
    }

    @Test("scrolling over real audio rows reaches the carousel and the vertical list",
          .enabled(if: ProcessInfo.processInfo.environment["ISLETA_TEST_AUDIO_SCROLL"] == "1"))
    func nativeRouting() async throws {
        let audio = audio()
        let metrics = IslandShapeMetrics(bodySize: CGSize(width: 368, height: 280), topCornerRadius: 0, bottomCornerRadius: 22)
        let model = IslandScreenModel(metricsByForm: [.rest: metrics], notchKind: .hardware, cutoutSize: CGSize(width: 185, height: 32))
        model.audioApplications = audio
        let gate = IslandHitTestView(frame: CGRect(x: 0, y: 0, width: 440, height: 320))
        gate.islandPath = CGPath(rect: gate.bounds, transform: nil)
        let host = NSHostingView(rootView: IslandAudioPageView(model: model).frame(width: 440, height: 320))
        host.frame = gate.bounds
        gate.addSubview(host)
        let window = NSPanel(contentRect: CGRect(x: -10000, y: -10000, width: 440, height: 320),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.contentView = gate
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        var tracker = SwipeTracker()
        var commits = 0
        var samples = 0
        gate.onScroll = { sample in
            samples += 1
            if !audio.scrollIfVertical(sample),
               case .commit = tracker.consume(sample, bounds: .init(canAdvance: true, canRetreat: true)) { commits += 1 }
        }
        // Window-local point inside the second source row, not the page header.
        let point = CGPoint(x: 220, y: 160)
        func gesture(dx: Int32, dy: Int32) throws {
            for phase in [CGScrollPhase.began, .changed, .changed, .changed, .changed, .ended] {
                let moving = phase != .began && phase != .ended
                let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                                wheel1: moving ? dy : 0, wheel2: moving ? dx : 0, wheel3: 0))
                event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
                event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(moving ? dy : 0))
                event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(moving ? dx : 0))
                event.location = CGPoint(x: point.x, y: CGDisplayBounds(CGMainDisplayID()).height - point.y)
                window.sendEvent(try #require(NSEvent(cgEvent: event)))
            }
        }
        try gesture(dx: -70, dy: 0)
        #expect(commits == 1)
        #expect(samples == 6)
        #expect(audio.scrollTarget.offset == 0)
        try gesture(dx: 0, dy: -20)
        #expect(audio.scrollTarget.offset == 80)
        #expect(commits == 1)
        #expect(!window.isKeyWindow)
    }
}
