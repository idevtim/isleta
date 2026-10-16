import Foundation
import IslandActivities
import Testing
@testable import IslandSources

@Suite("Audio applications")
struct AudioApplicationTests {
    @Test("a paused player survives a different app taking Now Playing")
    func keepsPausedSessions() {
        var state = AudioApplicationState()
        state.update(NowPlayingSnapshot(title: "Song", isPlaying: false, bundleIdentifier: "spotify"))
        state.update(nil) // MediaRemote may clear its current owner before naming the next one.
        state.update(NowPlayingSnapshot(title: "Video", isPlaying: true, bundleIdentifier: "browser"))
        // Some paused players keep a silent audio client running. Explicit pause still wins.
        state.setActiveOutput(["browser", "spotify"])
        let rows = state.applications(running: ["spotify": "Spotify", "browser": "Browser"])
        #expect(rows.count == 2)
        #expect(rows.first { $0.id == "spotify" }?.state == .paused)
        #expect(rows.first { $0.id == "browser" }?.state == .active)
    }

    @Test("only observed output adds an unknown app, and stopping IO means inactive")
    func outputIsNotAPauseSignal() {
        var state = AudioApplicationState()
        #expect(state.applications(running: ["browser": "Browser", "recorder": "Recorder"]).isEmpty)
        state.setActiveOutput(["browser"])
        #expect(state.applications(running: ["browser": "Browser"]).first?.state == .active)
        state.setActiveOutput([])
        #expect(state.applications(running: ["browser": "Browser"]).first?.state == .inactive)
    }

    @Test("exiting an application clears its session even if it later relaunches")
    func exitRemovesSession() {
        var state = AudioApplicationState()
        state.update(NowPlayingSnapshot(title: "Song", isPlaying: false, bundleIdentifier: "spotify"))
        #expect(state.applications(running: [:]).isEmpty)
        #expect(state.applications(running: ["spotify": "Spotify"]).isEmpty)
    }

    @Test("a stopped player clears while other paused sessions remain")
    func stoppingOnePlayerKeepsTheOthers() {
        var state = AudioApplicationState()
        for id in ["music", "spotify"] {
            state.updatePlayer(.snapshot(NowPlayingSnapshot(title: id, isPlaying: false, bundleIdentifier: id)),
                               bundleIdentifier: id)
        }
        state.updatePlayer(.cleared, bundleIdentifier: "music")
        #expect(state.applications(running: ["music": "Music", "spotify": "Spotify"]).map(\.id) == ["spotify"])
    }

    @Test("unavailable audio enumeration keeps the permission-free player route useful")
    @MainActor func unavailableMonitor() {
        let monitor = UnavailableAudioApplicationMonitor()
        var called = false
        monitor.onProcesses = { _ in called = true }
        monitor.start()
        monitor.stop()
        #expect(!called)
        var state = AudioApplicationState()
        state.update(NowPlayingSnapshot(title: "Song", isPlaying: false, bundleIdentifier: "spotify"))
        #expect(state.applications(running: ["spotify": "Spotify"]).first?.state == .paused)
    }
}

@Suite("CoreAudio application callbacks", .serialized)
@MainActor
struct AudioApplicationCallbackTests {
    /// Opt-in because CI may have no audio device. A silent file tests actual output notifications
    /// without changing volume, touching a user's players, or making an audible test sound.
    @Test("the HAL pushes start and stop for a real output process",
          .enabled(if: ProcessInfo.processInfo.environment["ISLETA_TEST_AUDIO_CALLBACKS"] == "1"))
    func observesRealOutput() async throws {
        let url = try silentWave()
        defer { try? FileManager.default.removeItem(at: url) }

        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [url.path]
        let monitor = CoreAudioApplicationMonitor()
        var sawActive = false
        var sawStopped = false
        var callbacks = 0
        var maximumProcessCount = 0
        var sawProcess = false
        monitor.onProcesses = { processes in
            callbacks += 1
            maximumProcessCount = max(maximumProcessCount, processes.count)
            sawProcess = sawProcess || processes.contains { $0.processIdentifier == player.processIdentifier }
            let active = processes.contains {
                $0.processIdentifier == player.processIdentifier && $0.hasActiveOutput
            }
            if active { sawActive = true }
            if sawActive && !active { sawStopped = true }
        }
        monitor.start()
        defer {
            monitor.stop()
            if player.isRunning { player.terminate() }
        }
        try player.run()
        for _ in 0..<80 {
            if sawStopped { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(sawActive, "Expected output start: callbacks=\(callbacks), maximum processes=\(maximumProcessCount), saw process=\(sawProcess)")
        #expect(sawStopped, "The actual listener must observe its output stopping")
    }

    @Test("stopping during real output returns promptly and rejects queued updates",
          .enabled(if: ProcessInfo.processInfo.environment["ISLETA_TEST_AUDIO_CALLBACKS"] == "1"))
    func stopsDuringOutput() async throws {
        let url = try silentWave()
        defer { try? FileManager.default.removeItem(at: url) }
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [url.path]
        let monitor = CoreAudioApplicationMonitor()
        var active = false
        var callbacks = 0
        monitor.onProcesses = { processes in
            callbacks += 1
            active = processes.contains {
                $0.processIdentifier == player.processIdentifier && $0.hasActiveOutput
            }
        }
        monitor.start()
        defer {
            monitor.stop()
            if player.isRunning { player.terminate() }
        }
        try player.run()
        let deadline = ContinuousClock.now + .seconds(5)
        while !active, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(active, "The stop must be tested during observed real output")
        let started = ContinuousClock.now
        monitor.stop()
        #expect(started.duration(to: .now) < .seconds(1))
        let delivered = callbacks
        try await Task.sleep(for: .milliseconds(200))
        #expect(callbacks == delivered, "Callbacks queued before stop must not reach the page")
    }

    private func silentWave() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        var wave = Data()
        func text(_ value: String) { wave.append(contentsOf: value.utf8) }
        func integer<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { wave.append(contentsOf: $0) }
        }
        let bytes: UInt32 = 44100 * 2 * 2
        text("RIFF"); integer(bytes + 36); text("WAVEfmt ")
        integer(UInt32(16)); integer(UInt16(1)); integer(UInt16(1))
        integer(UInt32(44100)); integer(UInt32(88200)); integer(UInt16(2)); integer(UInt16(16))
        text("data"); integer(bytes); wave.append(Data(repeating: 0, count: Int(bytes)))
        try wave.write(to: url)
        return url
    }
}
