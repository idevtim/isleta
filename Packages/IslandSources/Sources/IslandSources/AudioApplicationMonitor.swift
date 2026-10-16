import CoreAudio
import Foundation
import os

public struct AudioApplicationProcess: Equatable, Sendable {
    public let processIdentifier: Int32
    public let hasActiveOutput: Bool
    public init(processIdentifier: Int32, hasActiveOutput: Bool) {
        self.processIdentifier = processIdentifier
        self.hasActiveOutput = hasActiveOutput
    }
}

@MainActor
public protocol AudioApplicationMonitoring: AnyObject {
    var onProcesses: (([AudioApplicationProcess]) -> Void)? { get set }
    func start()
    func stop()
}

/// Used when the HAL process list is unavailable. Now Playing and player notifications still
/// supply the application list through the shell; an unavailable HAL never removes that route.
@MainActor
public final class UnavailableAudioApplicationMonitor: AudioApplicationMonitoring {
    public var onProcesses: (([AudioApplicationProcess]) -> Void)?
    public init() {}
    public func start() {}
    public func stop() {}
}

/// Public CoreAudio process properties, present since macOS 14.2. No capture, no permission,
/// no polling. All HAL reads and registration changes stay on one serial queue.
@MainActor
public final class CoreAudioApplicationMonitor: AudioApplicationMonitoring {
    public var onProcesses: (([AudioApplicationProcess]) -> Void)?
    private let worker = AudioApplicationWorker()
    private var running = false
    private var generation = 0

    public init() {}

    deinit { worker.stop() }

    public func start() {
        guard !running else { return }
        running = true
        generation += 1
        let generation = generation
        worker.start { [weak self] processes in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.running, self.generation == generation else { return }
                self.onProcesses?(processes)
            }
        }
    }

    public func stop() {
        guard running else { return }
        running = false
        generation += 1
        worker.stop()
    }
}

private final class AudioApplicationWorker: @unchecked Sendable {
    // HAL state stays on queue. The stop gate rejects already-enqueued callbacks before they
    // perform IPC, so synchronous teardown does not drain minutes of obsolete full-list scans.
    private let queue = DispatchQueue(label: "com.tryisleta.audioApplications")
    private let active = OSAllocatedUnfairLock(initialState: false)
    private var events: (any DispatchSourceUserDataOr)?
    private var registrations: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var callback: (@Sendable ([AudioApplicationProcess]) -> Void)?
    private var previous: [AudioApplicationProcess]?

    func start(_ callback: @escaping @Sendable ([AudioApplicationProcess]) -> Void) {
        active.withLock { $0 = true }
        queue.async { [self] in
            guard isActive else { return }
            self.callback = callback
            let events = DispatchSource.makeUserDataOrSource(queue: queue)
            events.setEventHandler { [weak self] in
                guard let self, self.isActive, let events = self.events else { return }
                if events.data & 1 != 0 { self.rebuild() } else { self.publish() }
            }
            self.events = events
            events.resume()
            rebuild()
        }
    }

    func stop() {
        active.withLock { $0 = false }
        queue.sync {
            callback = nil
            events?.cancel()
            events = nil
            removeListeners()
            previous = nil
        }
    }

    private var isActive: Bool { active.withLock { $0 } }

    private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private func ids() -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var a = address(kAudioHardwarePropertyProcessObjectList)
        guard AudioObjectHasProperty(system, &a) else { return [] }
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = ids.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(system, &a, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private func read(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var a = address(selector)
        guard AudioObjectHasProperty(object, &a) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private func register(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                          rebuilding: Bool = false) {
        var a = address(selector)
        guard AudioObjectHasProperty(object, &a) else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.isActive else { return }
            // Coalesce a HAL burst before any property read; output equality alone is too late.
            self.events?.or(data: rebuilding ? 1 : 2)
        }
        guard AudioObjectAddPropertyListenerBlock(object, &a, queue, block) == noErr else { return }
        registrations.append((object, a, block))
    }

    private func rebuild() {
        guard isActive, callback != nil else { return }
        removeListeners()
        register(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList, rebuilding: true)
        for id in ids() {
            // On macOS 26.0.1 IsRunningOutput reads correctly but did not notify for afplay.
            // IsRunning does notify; re-read output in response so input alone never adds a row.
            guard isActive else { return }
            register(id, kAudioProcessPropertyIsRunning)
            register(id, kAudioProcessPropertyIsRunningOutput)
        }
        publish()
    }

    private func publish() {
        guard isActive, let callback else { return }
        let processes = ids().compactMap { id -> AudioApplicationProcess? in
            guard isActive, let pid = read(id, kAudioProcessPropertyPID), pid > 0,
                  let output = read(id, kAudioProcessPropertyIsRunningOutput) else { return nil }
            return AudioApplicationProcess(processIdentifier: Int32(bitPattern: pid), hasActiveOutput: output != 0)
        }
        guard isActive, processes != previous else { return }
        previous = processes
        callback(processes)
    }

    private func removeListeners() {
        for (id, stored, block) in registrations {
            var a = stored
            AudioObjectRemovePropertyListenerBlock(id, &a, queue, block)
        }
        registrations.removeAll()
    }
}
