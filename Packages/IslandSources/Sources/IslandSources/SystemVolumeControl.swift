import AppKit
import AudioToolbox
import CoreAudio
import Foundation
import IslandKit

/// Writing the level, behind a seam.
///
/// A protocol for the reason every other system reach in this package has one: `SystemHUDSource`'s
/// replacement path decides *when* to write and `VolumeStep` decides *what* to write, and both have
/// to be testable on a machine with no sound device and without actually moving the developer's
/// volume. A test that drove the real one would change the volume of the Mac running it.
@MainActor
public protocol SystemVolumeWriting: AnyObject {

    /// The level and mute flag now, or nil if this Mac has no writable output.
    func current() -> (volume: Double, isMuted: Bool)?

    /// - Returns: the level read back, or nil if the write was refused.
    @discardableResult
    func setVolume(_ volume: Double) -> Double?

    /// - Returns: the mute flag read back, or nil if the write was refused.
    @discardableResult
    func setMuted(_ muted: Bool) -> Bool?

    /// The click, if the user's Sound setting asks for one.
    func playFeedback()
}

/// The one for a Mac that cannot be written to — a test, a preview. Refuses everything, which makes
/// `SystemHUDSource` fall back to letting the key through rather than swallowing one it cannot act
/// on.
@MainActor
public final class UnavailableVolumeControl: SystemVolumeWriting {
    public init() {}
    public func current() -> (volume: Double, isMuted: Bool)? { nil }
    public func setVolume(_ volume: Double) -> Double? { nil }
    public func setMuted(_ muted: Bool) -> Bool? { nil }
    public func playFeedback() {}
}

/// Writing the output level, for when Isleta has swallowed the key that would have done it.
///
/// **This exists only because consuming a key means becoming the thing the key did.** Isleta reads
/// the level everywhere else — `SystemHUDAudioObserver` and `SystemHUDAudioReader` — and reading is
/// all it needed while Apple's HUD was still on screen doing the work. The moment
/// `MediaKeyMonitor` returns nil for a volume key, nothing else in the system is going to move the
/// level, and this is what has to.
///
/// The arithmetic is deliberately not here: `VolumeStep` decides *where the level goes* with no I/O
/// at all, and this decides *how to put it there*. That split is what makes the half that has to be
/// exactly right testable without a sound device.
///
/// # Writing is not the mirror image of reading
///
/// `SystemHUDAudioReader` tries three property addresses in order because the built-in output on
/// macOS 26+ has no main-element `VolumeScalar`. Writing has the same problem *and one more*: a
/// property can exist, answer a read, and refuse a write. `AudioObjectIsPropertySettable` is the
/// question to ask, and — this being CoreAudio — it is asked **and** the result is read back,
/// because §"measure the effect, never the return value" has cost this codebase four entries
/// already and a `noErr` from an audio device is not evidence the level moved.
@MainActor
public final class SystemVolumeControl: SystemVolumeWriting {

    public init() {}

    public func current() -> (volume: Double, isMuted: Bool)? { Self.current() }

    @discardableResult
    public func setVolume(_ volume: Double) -> Double? { Self.setVolume(volume) }

    @discardableResult
    public func setMuted(_ muted: Bool) -> Bool? { Self.setMuted(muted) }

    public func playFeedback() { Self.playFeedbackIfEnabled() }
}

extension SystemVolumeControl {

    /// Where the level and the mute flag are right now, or nil if this Mac has no readable output.
    ///
    /// Reads through `SystemHUDAudioReader` rather than duplicating its candidate list — that list
    /// encodes which property actually tracks the volume keys on this OS, which is a fact that took
    /// a measurement to establish and must not exist twice.
    public static func current() -> (volume: Double, isMuted: Bool)? {
        let device = SystemHUDAudioReader.defaultOutputDevice()
        guard device != AudioObjectID(kAudioObjectUnknown),
              let volume = SystemHUDAudioReader.volume(of: device) else { return nil }
        return (volume, SystemHUDAudioReader.isMuted(of: device) ?? false)
    }

    /// Put the level at `volume`, and report whether it actually landed there.
    ///
    /// - Returns: the level read back afterwards, or nil if nothing could be written. **Not a
    ///   `Bool`**: the caller draws a HUD showing a number, and the number it must draw is the one
    ///   the device settled on rather than the one that was asked for. A device with coarser
    ///   granularity than 1/16 will land somewhere else, and a HUD that disagrees with the hardware
    ///   is worse than no HUD.
    @discardableResult
    public static func setVolume(_ volume: Double) -> Double? {
        let device = SystemHUDAudioReader.defaultOutputDevice()
        guard device != AudioObjectID(kAudioObjectUnknown) else { return nil }
        guard var address = settableLevelAddress(for: device) else {
            IslandLog.system.info("volume write: no settable level property on the default output")
            return nil
        }

        var value = Float32(VolumeStep.clamp(volume))
        let status = AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value
        )
        guard status == noErr else {
            IslandLog.system.info("volume write refused: \(status)")
            return nil
        }
        // The read-back, which is the actual answer. A `Float32` round trip also means the value
        // that comes back is 0.7499999 rather than 0.75, so nothing downstream may compare it for
        // equality — see `VolumeStep.tolerance`.
        return SystemHUDAudioReader.volume(of: device)
    }

    /// Set the mute flag, and report what it reads back as.
    @discardableResult
    public static func setMuted(_ muted: Bool) -> Bool? {
        let device = SystemHUDAudioReader.defaultOutputDevice()
        guard device != AudioObjectID(kAudioObjectUnknown) else { return nil }
        var address = SystemHUDAudioReader.muteAddress
        guard AudioObjectHasProperty(device, &address),
              isSettable(device, &address) else { return nil }

        var value: UInt32 = muted ? 1 : 0
        let status = AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value
        )
        guard status == noErr else {
            IslandLog.system.info("mute write refused: \(status)")
            return nil
        }
        return SystemHUDAudioReader.isMuted(of: device)
    }

    /// The click macOS plays when a volume key moves the level — **only if the user asked for it.**
    ///
    /// `com.apple.sound.beep.feedback` is the switch in Sound settings ("Play feedback when volume
    /// is changed"), and it is **off by default on this hardware**. Playing the click unconditionally
    /// would give a user a sound their Mac had never made, from an app that had just taken over
    /// their volume key — which is the most alarming possible way to discover a feature. Reading the
    /// global domain rather than Isleta's own is the point: this is the user's answer to Apple's
    /// question, not a setting Isleta gets to have an opinion about.
    ///
    /// Silent when suppression is off, because then Apple plays it and two clicks is worse than one.
    public static func playFeedbackIfEnabled() {
        guard UserDefaults.standard.object(forKey: feedbackKey) != nil,
              UserDefaults.standard.bool(forKey: feedbackKey) else { return }
        feedbackSound?.play()
    }

    private static let feedbackKey = "com.apple.sound.beep.feedback"

    /// Loaded once and reused. `NSSound(contentsOfFile:)` reads and decodes the file, and a volume
    /// key held down repeats faster than that is worth doing per press.
    ///
    /// **A system file read by path, which this codebase otherwise refuses**, so the exception is
    /// worth stating: it is a *sound*, not an API, the fallback is silence rather than a broken
    /// feature, and nothing about correctness depends on it. The private-framework rule exists
    /// because a resolved symbol that stops resolving takes a feature with it; a missing click takes
    /// nothing. Both paths are tried because the file moved between releases.
    private static let feedbackSound: NSSound? = {
        let candidates = [
            "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Media Keys.aif",
            "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff",
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            if let sound = NSSound(contentsOfFile: path, byReference: true) { return sound }
        }
        IslandLog.system.info("volume feedback sound not found; clicks will be silent")
        return nil
    }()

    // MARK: - Settability

    /// The first level property that exists **and can be written**.
    ///
    /// Existence and writability are different questions, and asking only the first is how you get a
    /// `noErr` that changes nothing. Built by re-probing `SystemHUDAudioReader`'s own ordering
    /// rather than by keeping a second list: which property tracks the volume keys is a measured
    /// fact and belongs in one place.
    private static func settableLevelAddress(for device: AudioObjectID) -> AudioObjectPropertyAddress? {
        guard var candidate = SystemHUDAudioReader.levelAddress(for: device) else { return nil }
        return isSettable(device, &candidate) ? candidate : nil
    }

    private static func isSettable(
        _ device: AudioObjectID,
        _ address: inout AudioObjectPropertyAddress
    ) -> Bool {
        var settable: DarwinBoolean = false
        let status = AudioObjectIsPropertySettable(device, &address, &settable)
        return status == noErr && settable.boolValue
    }
}
