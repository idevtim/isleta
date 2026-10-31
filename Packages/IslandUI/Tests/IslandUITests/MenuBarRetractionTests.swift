import AppKit
import SwiftUI
import CoreGraphics
import IslandActivities
import IslandKit
import Testing
@testable import IslandUI

@Suite("Menu bar retraction")
@MainActor
struct MenuBarRetractionTests {
    private func model(kind: NotchGeometry.Kind = .hardware) -> IslandScreenModel {
        let screen = IslandScreen(id: 1, name: "Test", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                  backingScaleFactor: 2,
                                  notch: NotchGeometry(kind: kind, rect: CGRect(x: 663, y: 950, width: 185, height: 32)))
        let model = IslandScreenModel(metricsByForm: Dictionary(uniqueKeysWithValues: IslandForm.allCases.map {
            ($0, IslandLayout.metrics(for: $0, on: screen))
        }), notchKind: kind, cutoutSize: screen.notch.cutoutSize)
        let music = BuiltInActivity.nowPlaying(title: "Test")
        model.setActivity(ActivityStage(primary: music, primaryFlank: .leading), change: .presented(music.id), reduceMotion: true)
        return model
    }

    @Test("menu conflict reveals commands without dismissing music or changing manual stow")
    func retracts() {
        let model = model()
        let id = model.stage?.primary.id
        model.setMenuBarNeedsSpace(true, reduceMotion: true)
        #expect(model.form == .rest)
        #expect(model.metrics.bodySize == CGSize(width: 185, height: 32))
        #expect(model.flanks == .none)
        #expect(!model.needsClock)
        #expect(model.stage?.primary.id == id)
        #expect(!model.isStowed)
        model.setMenuBarNeedsSpace(false, reduceMotion: true)
        #expect(model.form == .flankedRest)
    }

    /// Reported from use: plugging in while an app's menus filled the menu bar showed nothing.
    @Test("an announcement that leaves on its own comes through, and the retraction resumes after it")
    func momentaryComesThrough() {
        let model = model()
        model.setMenuBarNeedsSpace(true, reduceMotion: true)
        #expect(model.isRetractedForMenuBar)

        let volume = BuiltInActivity.systemHUD(.volume, level: 0.5)
        model.setActivity(ActivityStage(primary: volume, primaryFlank: .leading), change: .presented(volume.id), reduceMotion: true)
        #expect(!model.isRetractedForMenuBar)
        #expect(model.form != .rest)
        #expect(model.flanks != .none)

        // Music back on stage: it stays, so it stays out of the menus' way.
        let music = BuiltInActivity.nowPlaying(title: "Test")
        model.setActivity(ActivityStage(primary: music, primaryFlank: .leading), change: .presented(music.id), reduceMotion: true)
        #expect(model.isRetractedForMenuBar)
        #expect(model.form == .rest)
    }

    @Test("hover reveals the original activity and leaving retracts it again")
    func hover() {
        let model = model()
        model.setMenuBarNeedsSpace(true, reduceMotion: true)
        model.setHovering(true, reduceMotion: true)
        #expect(model.form == .flankedPeek)
        #expect(!model.isRetractedForMenuBar)
        #expect(model.contentForm == model.form)
        model.setHovering(false, reduceMotion: true)
        #expect(model.isRetractedForMenuBar)
        #expect(model.contentForm == .rest)
    }

    @Test("a clicked or keyboard-opened island stays available until closed")
    func open() {
        let model = model()
        model.setMenuBarNeedsSpace(true, reduceMotion: true)
        model.setExpanded(true, reduceMotion: true)
        model.setHovering(false, reduceMotion: true)
        #expect(model.presentation == .expanded)
        #expect(!model.isRetractedForMenuBar)
        model.setExpanded(false, reduceMotion: true)
        #expect(model.form == .rest)
    }

    @Test("manual stow survives both menu changes and hover")
    func manualStow() {
        let model = model()
        model.setStowed(true, reduceMotion: true)
        model.setMenuBarNeedsSpace(true, reduceMotion: true)
        model.setHovering(true, reduceMotion: true)
        #expect(model.isStowed)
        #expect(model.flanks == .none)
        model.setMenuBarNeedsSpace(false, reduceMotion: true)
        #expect(model.isStowed)
    }

    /// A standing activity — one that lasts until its source says otherwise — would sit over the
    /// menus for as long as it lasts, so it arrives retracted. (A momentary one comes through: see
    /// `momentaryComesThrough`.)
    @Test("a standing activity arriving during retraction stays narrow and appears on hover")
    func incomingActivity() {
        let model = model()
        model.setMenuBarNeedsSpace(true, reduceMotion: true)
        let waiting = BuiltInActivity.codingAgent(
            CodingAgentSession(agent: .claudeCode, sessionID: "s", name: nil, terminalApplicationName: nil),
            moment: .needsInput)
        model.setActivity(ActivityStage(primary: waiting, primaryFlank: .leading), change: .presented(waiting.id), reduceMotion: true)
        #expect(model.form == .rest)
        model.setHovering(true, reduceMotion: true)
        #expect(model.flanks != .none)
        #expect(model.stage?.primary.id == waiting.id)
    }

    @Test("rapid animated hover reversals leave content and hit testing at the retracted shape")
    func hoverReversal() async throws {
        let model = model()
        model.setMenuBarNeedsSpace(true, reduceMotion: false)
        model.setHovering(true, reduceMotion: false)
        model.setHovering(false, reduceMotion: false)
        let deadline = ContinuousClock.now + .seconds(1)
        while model.contentForm != .rest && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.form == .rest)
        #expect(model.contentForm == .rest)
        #expect(model.hitRegionMetrics == model.metrics)
    }

    @Test("retracted and hovered islands render with their activity retained",
          .enabled(if: ProcessInfo.processInfo.environment["ISLETA_TEST_MENU_RENDER"] == "1"))
    func render() async throws {
        let model = model()
        model.reduceMotion = true
        model.setMenuBarNeedsSpace(true, reduceMotion: true)
        for hovering in [false, true] {
            model.setHovering(hovering, reduceMotion: true)
            let host = NSHostingView(rootView: IslandRootView(model: model).frame(width: 608, height: 120))
            let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 608, height: 120),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            window.isOpaque = false
            window.backgroundColor = .clear
            window.orderBack(nil)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let probeX = Int(185 * CGFloat(bitmap.pixelsWide) / 608)
            let alpha = try #require(bitmap.colorAt(x: probeX, y: 8)).alphaComponent
            #expect(hovering ? alpha > 0.9 : alpha == 0)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: "/tmp/isleta-menu-\(hovering ? "hover" : "retracted").png"))
            window.orderOut(nil)
        }
    }

    @Test("notchless models ignore automatic retraction")
    func notchless() {
        let model = model(kind: .synthesized)
        let before = model.form
        model.setMenuBarNeedsSpace(true, reduceMotion: true)
        #expect(model.form == before)
        #expect(!model.isRetractedForMenuBar)
    }
}
