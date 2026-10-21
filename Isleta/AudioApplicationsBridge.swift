import AppKit
import Darwin
import IslandSources
import IslandUI

/// Resolves HAL helper processes to their containing app and joins all sessions to one page.
/// Opening an app never sends a global media key, so it cannot resume a different player.
@MainActor
final class AudioApplicationsBridge {
    let model = AudioApplicationsModel()
    var onOpenedApplication: (() -> Void)?
    private let monitor: any AudioApplicationMonitoring
    private let scripting: any NowPlayingScriptEnvironment
    private var state = AudioApplicationState()
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private struct MediaState: Equatable {
        let bundleIdentifier: String?
        let title: String
        let isPlaying: Bool
    }
    private var lastMedia: MediaState?
    private var running = false
    private var generation = 0

    init(monitor: any AudioApplicationMonitoring = CoreAudioApplicationMonitor(),
         scripting: any NowPlayingScriptEnvironment = NowPlayingSystemScriptEnvironment()) {
        self.monitor = monitor
        self.scripting = scripting
        monitor.onProcesses = { [weak self] processes in
            guard let self, self.running else { return }
            let active = Set(processes.filter(\.hasActiveOutput).compactMap {
                self.application(for: $0.processIdentifier)?.bundleIdentifier
            })
            self.state.setActiveOutput(active)
            self.publish()
        }
        model.onOpen = { [weak self] identifier in
            guard let self,
                  let application = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first
            else { return }
            guard let url = application.bundleURL else { return }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] app, error in
                DispatchQueue.main.async { [weak self] in
                    guard app != nil, error == nil else { return }
                    self?.onOpenedApplication?()
                }
            }
        }
    }

    func start() {
        guard !running else { return }
        running = true
        generation += 1
        let generation = generation
        let center = DistributedNotificationCenter.default()
        for player in NowPlayingPlayer.all {
            for name in player.notificationNames {
                observers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) {
                    [weak self] notification in
                    // Parse before crossing isolation: Notification's userInfo is not Sendable.
                    let update = player.update(fromPlayerInfo: notification.userInfo ?? [:])
                    MainActor.assumeIsolated {
                        guard let self, self.running else { return }
                        self.state.updatePlayer(update, bundleIdentifier: player.bundleIdentifier)
                        self.publish()
                    }
                })
            }
            // A denied or undecided Automation grant must never prompt from the launch path.
            if scripting.isRunning(player) {
                // readCurrentTrack checks existing consent on its worker. Even a non-prompting
                // Apple-event preflight can block; none belongs on the launch thread.
                scripting.readCurrentTrack(from: player) { [weak self] update in
                    guard let self, let update, self.running, self.generation == generation else { return }
                    self.state.updatePlayer(update, bundleIdentifier: player.bundleIdentifier)
                    self.publish()
                }
            }
        }
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.publish() }
        })
        monitor.start()
    }

    func stop() {
        running = false
        generation += 1
        monitor.stop()
        for observer in observers { DistributedNotificationCenter.default().removeObserver(observer) }
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        workspaceObservers.removeAll()
        state = AudioApplicationState()
        lastMedia = nil
        model.applications = []
    }

    func update(_ snapshot: NowPlayingSnapshot?) {
        let media = snapshot.map {
            MediaState(bundleIdentifier: $0.bundleIdentifier, title: $0.title, isPlaying: $0.isPlaying)
        }
        guard media != lastMedia else { return }
        lastMedia = media
        state.update(snapshot)
        publish()
    }

    private func publish() {
        let names = Dictionary(NSWorkspace.shared.runningApplications.compactMap { app -> (String, String)? in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier else { return nil }
            return (id, app.localizedName ?? id)
        }, uniquingKeysWith: { first, _ in first })
        let applications = state.applications(running: names)
        if applications != model.applications { model.applications = applications }
    }

    private func application(for pid: Int32) -> NSRunningApplication? {
        let app = NSRunningApplication(processIdentifier: pid)
        if app?.activationPolicy == .regular { return app }
        // Some browser audio services have no NSRunningApplication. proc_pidpath supplies the
        // executable's actual path, which still sits inside the outer browser application bundle.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count = buffer.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        let processPath: String?
        if count > 0 {
            processPath = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        } else {
            processPath = app?.bundleURL?.path
        }
        guard let processPath else { return nil }
        return NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular && $0.bundleURL.map {
                processPath.hasPrefix($0.path + "/")
            } == true
        }
    }
}
