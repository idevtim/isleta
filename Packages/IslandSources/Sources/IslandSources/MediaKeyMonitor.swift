import AppKit
import IOKit.hidsystem
import IslandKit

/// One of the keys along the top of the keyboard that drives a system level.
///
/// Only the four that move something with an end to reach. Mute is deliberately not here: it is a
/// toggle, not a range, and there is nothing to push against.
public enum MediaKey: String, Hashable, Sendable, CaseIterable {
    case volumeUp
    case volumeDown

    /// **Added with HUD replacement, and it had no reason to exist before.** The rebound this file
    /// was written for is about a level pushed past its end, and mute is not a level — it has no
    /// end to push against, so nothing ever needed to decode it. Swallowing the volume keys does:
    /// a Mac whose volume keys Isleta answers and whose mute key still reaches macOS would show
    /// Apple's HUD for one key out of three.
    case mute
    case brightnessUp
    case brightnessDown

    /// Whether this key is one HUD replacement takes over. Brightness is deliberately not, for now
    /// — see `SystemHUDSuppression`.
    var isVolumeKey: Bool {
        switch self {
        case .volumeUp, .volumeDown, .mute: true
        case .brightnessUp, .brightnessDown: false
        }
    }

    /// The `NX_KEYTYPE_*` code this key arrives as, from `IOKit/hidsystem/ev_keymap.h`.
    var keyCode: Int32 {
        switch self {
        case .volumeUp: NX_KEYTYPE_SOUND_UP
        case .volumeDown: NX_KEYTYPE_SOUND_DOWN
        case .mute: NX_KEYTYPE_MUTE
        case .brightnessUp: NX_KEYTYPE_BRIGHTNESS_UP
        case .brightnessDown: NX_KEYTYPE_BRIGHTNESS_DOWN
        }
    }

    static func named(_ keyCode: Int32) -> MediaKey? {
        allCases.first { $0.keyCode == keyCode }
    }
}

/// One media key going down, with the modifiers that were held.
///
/// A value rather than two arguments, because the pair travels together through a protocol, a C
/// callback and a source, and a `Bool` positional parameter at the end of that chain is the kind of
/// thing that gets passed in the wrong order once and is wrong forever after.
public struct MediaKeyPress: Sendable, Equatable {

    public let key: MediaKey

    /// ⇧⌥ was held, which on macOS means quarter-notches — `VolumeStep.fineNotch`.
    public let isFine: Bool

    public init(key: MediaKey, isFine: Bool = false) {
        self.key = key
        self.isFine = isFine
    }
}

/// Something that can tell Isleta a media key went down.
///
/// A protocol so `SystemHUDSource` can be exercised with no window, no permission and no keyboard —
/// the layering test §3 applies to sources as much as to views.
@MainActor
public protocol MediaKeyObserving: AnyObject {

    /// Whether this Mac will actually deliver the events. See `MediaKeyMonitor.isAvailable`.
    var isAvailable: Bool { get }

    func start(_ onPress: @escaping (MediaKey) -> Void)

    /// Start in a mode that may **swallow** the keys it handles.
    ///
    /// Separate from `start(_:)` rather than a parameter with a default, because the two are
    /// genuinely different contracts and a caller should have to say which it wants. Observing is
    /// free and cannot affect anything; replacing puts Isleta on the path of every level key on the
    /// machine and makes it responsible for what that key does.
    ///
    /// - Parameter onPress: returns `true` to consume the key, which requires `mode == .replace`.
    ///   In `.observe` the return is ignored — a `.listenOnly` tap cannot consume whatever it says.
    func start(mode: MediaKeyMode, onPress: @escaping (MediaKeyPress) -> Bool)

    func stop()
}

/// Whether the tap watches the level keys or *is* them.
public enum MediaKeyMode: Sendable, Equatable {

    /// `.listenOnly`. Nothing Isleta does can swallow or delay a key. The only mode that existed
    /// before HUD replacement, and still the default everywhere.
    case observe

    /// `.defaultTap`, so a handled key never reaches the system.
    ///
    /// **This is the whole of HUD suppression**, and it is why the mechanism satisfies the
    /// restore-after-crash rule that defeated every alternative: the tap is process-scoped kernel
    /// state, so quitting, crashing or force-quitting hands the keys straight back to macOS with
    /// nothing to undo and nothing to remember. Compare `SystemHUDSuppression`'s rejected
    /// candidates, every one of which writes state that outlives the process.
    case replace
}

/// Watches the volume and brightness keys, and **only** to answer one question: did the user press
/// a key asking for more of a level that has none left to give?
///
/// # Why this exists at all, when `SystemHUDSource` says the keys are the wrong thing to watch
///
/// That note stands and this does not contradict it. Watching the *levels* is strictly better for
/// knowing what a level is: it catches every change from every cause — the keys, Control Center, a
/// slider in Music, `osascript` — with no permission and nothing on the idle path. This is for the
/// one thing a level cannot report, because it is the absence of a change:
///
/// **Measured 2026-08-29.** Setting the volume to the value it already holds fires *no* CoreAudio
/// property listener at all — three consecutive writes of 1.0 after a real change to 1.0 produced
/// two callbacks and then zero, and the same at 0.0. So a volume key pressed at the top of the range
/// is invisible to the level observer by construction, and the rebound the owner asked for
/// (`IslandScreenModel.limitBounce`, "keep bouncing as the user continues to press") has no other
/// signal to run on.
///
/// It is therefore **additive and narrow**: nothing here decides what a level *is*, publishes a HUD,
/// or has any effect when the level is anywhere but its end. Turn it off and Isleta behaves exactly
/// as it did before — the island still bounces when a level *arrives* at an end, because that is a
/// change and the level observer sees it.
///
/// # The permission, and what happens without it
///
/// `NSEvent.addGlobalMonitorForEvents` needs Accessibility for keyboard events —
/// `IslandKit.HotKeyMonitor` records that, which is why Isleta's hot keys go through Carbon instead.
/// Isleta asks for Accessibility on the first-run flow's `accessibility` page, so this is a **new use
/// of a grant the app already requests**, not a new permission — but it is not one every user will
/// have given, and this must never be the reason a HUD does not appear.
///
/// **That sentence was false for one release and is worth the correction rather than a silent edit.**
/// The Accessibility page left the flow with notifications on 2026-08-28 and this comment went on
/// asserting it, so the argument below rested on an ask that no longer happened: Accessibility was a
/// permission Isleta used and never requested anywhere outside `#if DEBUG`. `AccessibilityAccess` is
/// the shipping path now, and `OnboardingStep.accessibility` is the button that reaches it.
///
/// Nothing here changes either way: no prompt, no `AXIsProcessTrustedWithOptions`, no explanation
/// offered *from this file*. It registers, and if nothing ever arrives, nothing ever bounces on a
/// repeat. §10's rule is that the one button that asks is the one the user clicks, and a decorative
/// rebound has not earned a dialog of its own.
///
/// # A tap, not `NSEvent.addGlobalMonitorForEvents`
///
/// The obvious route is a global monitor for `.systemDefined`, and it was written that way first. A
/// `CGEventTap` on `NX_SYSDEFINED` replaced it: it is where every media-key app has read these since
/// the type existed, and it sits at `.cghidEventTap`, below where the system consumes a volume key.
///
/// ## `CGEvent.tapCreate` does **not** report its own refusal, and this file was written believing
/// it did
///
/// The tap was chosen partly on the argument that it fails loudly where a global monitor fails
/// silently — nil without the grant, against a monitor object that is perfectly good and never
/// fires. **Measured 2026-08-29: that is false.** Isleta, launched with `open -a` and with
/// `AXIsProcessTrusted() == false`, got a non-nil mach port from `tapCreate` at `.cghidEventTap`,
/// added it to the main run loop, enabled it — and received **nothing at all**, not one event of any
/// type, while an identical tap in a trusted process saw events posted from a *different* process
/// on the same machine. Every step said yes and the stream was empty.
///
/// So this is the same trap as `IOServiceAddInterestNotification` in `DisplayBrightnessMonitor` and
/// the KVO-on-battery-percentage in `BluetoothDeviceBattery`, in a third place: registration
/// succeeds, the callback is never called, and the code reads as correct forever.
/// `isAvailable` therefore asks the *grant*, not the port.
///
/// `.listenOnly`, so nothing Isleta does can swallow or delay a key on its way to the system. A tap
/// that could modify the stream would put this decorative rebound on the path of every volume press
/// on the machine, which is not a trade a flourish gets to make.
///
/// **`isAvailable` is the tap existing *and* the grant being held**, because measurement showed the
/// first without the second is worth nothing. It is still not proof that events arrive —
/// `--media-key-test` answers that against a real keypress, which is the only stimulus
/// `DisplayServicesBrightnessMonitor`'s recorded trap permits.
@MainActor
public final class MediaKeyMonitor: MediaKeyObserving {

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Held for the C callback, which gets a raw pointer and no context of its own.
    ///
    /// Returns whether the key was handled and should be swallowed. In `.observe` the answer is
    /// ignored, because a `.listenOnly` tap's return value is.
    private var onPress: ((MediaKeyPress) -> Bool)?

    /// Fixed for the life of the tap: `CGEvent.tapCreate` takes the option at creation, so changing
    /// modes means `stop()` and `start(mode:)` again rather than flipping a flag. That is the
    /// honest shape — a tap that could become consuming without being rebuilt would be one whose
    /// `.listenOnly` promise depended on a variable.
    private var mode: MediaKeyMode = .observe

    /// How many events the tap has delivered, of any kind. Diagnostic only — see `receive`.
    private var received = 0

    public init() {}

    public var isAvailable: Bool { tap != nil && AXIsProcessTrusted() }

    public func start(_ onPress: @escaping (MediaKey) -> Void) {
        start(mode: .observe) { press in
            onPress(press.key)
            return false
        }
    }

    public func start(mode: MediaKeyMode, onPress: @escaping (MediaKeyPress) -> Bool) {
        guard tap == nil else { return }
        self.onPress = onPress
        self.mode = mode

        // `NX_SYSDEFINED` is 14, and `CGEventMask` is a bitfield of raw event types. There is no
        // `CGEventType` case for it — the enum covers the mouse and keyboard types only — so the
        // mask is built from the number, which is `IOKit/hidsystem/IOLLEvent.h`'s and not ours.
        let mask: CGEventMask = 1 << 14
        let created = CGEvent.tapCreate(
            // **`.cghidEventTap`, the earliest point in the stream.** Measured 2026-08-29: a
            // synthetic subtype-8 event posted to the HID tap is seen by a listen-only tap at both
            // `.cghidEventTap` and `.cgSessionEventTap` (and by neither at
            // `.cgAnnotatedSessionEventTap`), so the mechanism works at either — but a *real* volume
            // key is handled by the system itself, and anything the system consumes on the way up
            // is gone before a session tap sees it. The HID tap sits below that, which is the only
            // place a key the system is about to swallow can still be observed.
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            // `.listenOnly` unless the caller asked to replace the keys. The distinction is not
            // cosmetic: a `.defaultTap` puts this callback on the delivery path of every level key
            // on the machine, and a slow one delays them — macOS disables a tap that overruns its
            // timeout, which shows up as the keys dying rather than as anything logged. `receive`
            // does no I/O for that reason.
            options: mode == .replace ? .defaultTap : .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<MediaKeyMonitor>.fromOpaque(context).takeUnretainedValue()
                let consumed = MainActor.assumeIsolated { monitor.receive(event) }
                // Returning nil is the suppression. In `.observe` `receive` always answers false and
                // `.listenOnly` would ignore this anyway — returning the event explicitly is what
                // keeps that true rather than incidental.
                return consumed ? nil : Unmanaged.passUnretained(event)
            },
            // **Retained, not `passUnretained`** — and that is a crash rather than a style. The
            // callback is C: it receives a raw pointer and no lifetime. A monitor released while
            // its tap is still live leaves that pointer dangling, and the next media key on the
            // machine dereferences freed memory. Found as a SIGSEGV in the test suite the first time
            // a `SystemHUDSource` was built without injecting a fake, which is exactly the shape the
            // bug takes in the app: nothing crashes until somebody presses a key.
            //
            // The tap holds the monitor alive, `stop()` gives that reference back, and
            // `SystemHUDSource.stop()` is the one caller — the same lifecycle every other monitor in
            // this package has.
            userInfo: Unmanaged.passRetained(self).toOpaque()
        )
        guard let created else {
            // Balance the retain above: without the tap there is nothing to release it later, and
            // the monitor would outlive its owner forever.
            Unmanaged.passUnretained(self).release()
            IslandLog.sources.info("media key tap refused; the limit rebound will not repeat")
            return
        }
        // **Not a guard, deliberately.** Without Accessibility this tap will never deliver an event,
        // but it is created anyway and left attached: the grant can be given while Isleta is
        // running, and the system does not tell us when it is. A tap that is already in place simply
        // starts working. The alternative — refusing to create it and re-checking on some schedule —
        // is a poll on the idle path for a decorative rebound, which §9 does not sell that cheaply.
        tap = created
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        // **`AXIsProcessTrusted()` beside it, because the tap existing is not the same fact.** A
        // HID tap created by an untrusted process can come back as a perfectly good mach port that
        // never delivers an event — which is exactly the "registration status is evidence of
        // nothing" trap this repository keeps paying for. The two together are what tell a reader
        // whether silence means "not permitted" or "not observable".
        IslandLog.sources.info(
            "media key tap attached — accessibility: \(AXIsProcessTrusted())"
        )
    }

    public func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        self.tap = nil
        runLoopSource = nil
        onPress = nil
        // The reference the tap was holding. Guarded on the tap having existed, so a second `stop()`
        // cannot over-release — `SystemHUDSource.stop()` is idempotent and is entitled to be.
        Unmanaged.passUnretained(self).release()
    }

    /// A tap can be **disabled by the system** — for being slow, or when the user toggles the grant
    /// — and it stays disabled until it is re-enabled. Silently, which is the failure mode this
    /// whole file is written around, so the two notification types are handled rather than decoded
    /// as keys.
    /// - Returns: whether the event was handled and must be swallowed. Always false in `.observe`.
    @discardableResult
    private func receive(_ event: CGEvent) -> Bool {
        let type = event.type
        // **Every event, before any decoding.** Logging only the keys we recognise cannot tell
        // "the tap receives nothing" from "the tap receives something we fail to read", and those
        // are opposite conclusions: the first retires this whole file, the second is a bug in the
        // four lines below it. Free when off, like every `debug`.
        received += 1
        // `debug`, which is an autoclosure and free when off. It was `info` for exactly as long as
        // the route was unproven — silence at `info` is evidence and silence at `debug` is not — and
        // came straight back down once it was: a held brightness key produced **173 of these lines
        // in eleven seconds**, which is not "once per user action" by any reading.
        IslandLog.sources.debug("media key tap saw event type \(type.rawValue) (#\(received))")
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            // **Worth an `info` rather than a `debug`, and worth more in `.replace`.** A timeout
            // means this callback overran, and in replace mode the user's level keys stopped working
            // until this line ran. Re-enabling is the recovery; the log line is how anyone finds out
            // it happened at all, because nothing on screen says so.
            IslandLog.sources.info("media key tap was disabled and has been re-enabled")
            return false
        }
        guard let nsEvent = NSEvent(cgEvent: event),
              let decoded = Self.press(in: nsEvent) else { return false }
        let key = decoded.key
        // **`debug`, which is an autoclosure and free when off.** Whether the keys arrive at all is
        // the question this whole file turns on, and it is not answerable from the outside: the
        // rebound not repeating looks identical whether the tap is silent or the level is not at its
        // end. `--verbose-logging` turns this on and settles it in one press.
        IslandLog.sources.debug("media key: \(key.rawValue)")
        let handled = onPress?(MediaKeyPress(key: key, isFine: decoded.isFine)) ?? false
        // The mode is the authority, not the handler: a handler that answers true while the tap is
        // `.listenOnly` must not be able to imply a suppression that did not happen, because the
        // return value of a listen-only tap is discarded and the key goes through regardless.
        return handled && mode == .replace
    }

    // No `deinit` that stops the tap: `SystemHUDSource.stop()` owns the lifecycle, which is where
    // every other monitor in this package is detached from anyway.

    /// Decodes a media key going **down** out of a system-defined event, or nil for everything else.
    ///
    /// The layout is `IOKit/hidsystem/ev_keymap.h`'s and is not ours to choose: an aux-control event
    /// packs the key code into the top half of `data1` and its state into the bottom half, where
    /// `0x0A` in the second byte is a key-down. `nonisolated` and `static` so the decoding can be
    /// tested against a synthesised event without a monitor, a permission or a keyboard.
    ///
    /// **Key repeats count.** The bottom bit of `keyFlags` is the repeat flag, and it is deliberately
    /// not filtered: a key held down at the top of the range is exactly the gesture the rebound
    /// answers, and dropping repeats would leave it firing once for a press the user is still making.
    nonisolated static func mediaKey(in event: NSEvent) -> MediaKey? {
        press(in: event)?.key
    }

    /// The key **and its modifiers**, which is what replacing the key needs and observing it never
    /// did.
    ///
    /// ⇧⌥ held means quarter-notches (`VolumeStep.fineNotch`), and the flags live on the event
    /// rather than in the aux-control payload — `data1` carries the key code and the up/down bit and
    /// says nothing about modifiers. Reading `modifierFlags` here rather than asking
    /// `NSEvent.modifierFlags` later is the difference between the state at the moment of the press
    /// and the state whenever the handler happened to run.
    nonisolated static func press(in event: NSEvent) -> (key: MediaKey, isFine: Bool)? {
        guard event.type == .systemDefined,
              event.subtype.rawValue == Int16(NX_SUBTYPE_AUX_CONTROL_BUTTONS) else { return nil }
        let data = event.data1
        let keyCode = Int32((data & 0xFFFF_0000) >> 16)
        let keyFlags = data & 0x0000_FFFF
        let isDown = ((keyFlags & 0xFF00) >> 8) == 0x0A
        guard isDown, let key = MediaKey.named(keyCode) else { return nil }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return (key, modifiers.contains(.shift) && modifiers.contains(.option))
    }
}

/// The monitor for a Mac that is not being watched — a test, a preview, a build with the rebound
/// switched off. Answers nothing, forever.
@MainActor
public final class UnavailableMediaKeyMonitor: MediaKeyObserving {
    public init() {}
    public var isAvailable: Bool { false }
    public func start(_ onPress: @escaping (MediaKey) -> Void) {}
    public func start(mode: MediaKeyMode, onPress: @escaping (MediaKeyPress) -> Bool) {}
    public func stop() {}
}
