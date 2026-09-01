import CoreAudio
import IslandActivities
import Testing

@testable import IslandSources

/// The real CoreAudio observer, against whatever output device this machine has — including none.
/// Nothing here changes a level: a test suite that moves the volume is a test suite nobody runs
/// twice.
@MainActor
@Suite("SystemHUDAudioObserver")
struct SystemHUDAudioObserverTests {

    @Test("start and stop are idempotent and symmetric")
    func lifecycle() {
        let observer = SystemHUDAudioObserver()
        #expect(!observer.isRunning)

        observer.start()
        observer.start()
        #expect(observer.isRunning)

        observer.stop()
        observer.stop()
        #expect(!observer.isRunning)
    }

    /// The §9 idle budget is measured with sources running, so "stopped" has to mean the process is
    /// back to where it was: no listener block still held by CoreAudio.
    @Test("stopping unregisters every listener")
    func stopUnregisters() {
        let observer = SystemHUDAudioObserver()
        observer.start()
        observer.stop()
        #expect(observer.registrationCount == 0)
    }

    /// `SystemHUDSource.supportedHUDs` asks before `start()` and after `stop()`. Answering
    /// "unavailable" there — which an earlier version did — told the app that a Mac with working
    /// speakers had no volume to show, and it was invisible to every test that used a fake observer.
    @Test("a snapshot before starting still reads the default output device")
    func snapshotBeforeStart() {
        let observer = SystemHUDAudioObserver()
        let running = SystemHUDAudioObserver()
        running.start()
        defer { running.stop() }
        #expect(observer.snapshot() == running.snapshot())
    }

    @Test("a snapshot while running is a fraction, or nothing at all on a Mac with no output")
    func snapshotWhileRunning() {
        let observer = SystemHUDAudioObserver()
        observer.start()
        defer { observer.stop() }

        let snapshot = observer.snapshot()
        if let volume = snapshot.volume {
            #expect(volume >= 0 && volume <= 1)
        }
    }

    /// Registering a listener for a property a device does not have returns `noErr` and then never
    /// fires — which is why `SystemHUDAudioObserver` gates on `AudioObjectHasProperty` instead. If
    /// a level address is resolved at all it must be one the device actually has.
    @Test("the resolved level address is one the device really has")
    func levelAddressIsReal() {
        let device = SystemHUDAudioReader.defaultOutputDevice()
        guard let resolved = SystemHUDAudioReader.levelAddress(for: device) else { return }
        var address = resolved
        #expect(AudioObjectHasProperty(device, &address))
        #expect(SystemHUDAudioReader.volume(of: device) != nil)
    }

    @Test("an unknown device reads as unavailable rather than as silence")
    func unknownDeviceIsUnavailable() {
        #expect(SystemHUDAudioReader.snapshot(of: 0) == .unavailable)
        #expect(SystemHUDAudioReader.volume(of: 0) == nil)
        #expect(SystemHUDAudioReader.isMuted(of: 0) == nil)
    }
}
