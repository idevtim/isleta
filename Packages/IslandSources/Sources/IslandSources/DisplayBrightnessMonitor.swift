import CoreGraphics
import Foundation
import IslandKit

/// One route to "the display brightness just changed".
///
/// A protocol for the same reason `BluetoothDeviceMonitoring` and `NowPlayingProvider` are: the
/// real implementation resolves private symbols at runtime, and the source's own behavior —
/// baselining at launch, coalescing the ramp, publishing a HUD — has to be testable without a
/// panel to dim. `UnavailableBrightnessMonitor` is the fallback, and it is what runs on an OS that
/// has taken the symbols away.
@MainActor
public protocol DisplayBrightnessMonitoring: AnyObject {

    /// Whether this monitor can read the brightness at all.
    var isAvailable: Bool { get }

    /// The built-in display's brightness, 0...1, or nil if it cannot be read.
    ///
    /// A read on demand, never on a timer.
    func currentBrightness() -> Double?

    /// Begin observing. The handler is called with the new level for every change.
    ///
    /// **The handler fires many times for one keypress** — 27 to 78 times over 0.5–1.4s, measured
    /// on macOS 27.0 — because it traces the panel's easing ramp toward the new value rather than
    /// announcing the destination once. Coalescing belongs to the caller, in
    /// `SystemHUDBrightnessState`, where it is a pure function that can be tested against the
    /// recorded shape of a real ramp.
    func start(onChange: @escaping (Double) -> Void)

    func stop()
}

/// The monitor for an OS where the symbols have gone.
///
/// Not an error path. A Mac that cannot report brightness is one where `SystemHUDSource` leaves the
/// brightness HUD to the system and says so — §10's denied-state rule in its mildest form, and
/// exactly the behavior Isleta shipped through 1.3.0.
@MainActor
public final class UnavailableBrightnessMonitor: DisplayBrightnessMonitoring {
    public init() {}
    public var isAvailable: Bool { false }
    public func currentBrightness() -> Double? { nil }
    public func start(onChange: @escaping (Double) -> Void) {}
    public func stop() {}
}

// MARK: - DisplayServices

/// `DisplayServices.framework`, asked at runtime for the brightness it will not admit to publicly.
///
/// ## Why this is the fourth exception, and what it is held to
///
/// §Working agreements sanction two private paths — the `mediaremote-adapter` helper and
/// `SkyLightOverlaySpace` — and say a third needs the same measurement those two got first.
/// `BluetoothDeviceMonitor` was the third. This is the fourth, and it is the only one that
/// *replaces a documented finding*: through 1.3.0 this codebase stated in four release notes, in
/// PROGRESS.md and in `SystemHUDBrightness` that brightness had no public route **and no change
/// notification anywhere**. The second half was the load-bearing claim, because a value that
/// cannot be observed cannot drive a HUD however well it reads. Both halves are false.
///
/// So it is held to the same three rules: resolved at runtime rather than linked, behind this
/// protocol, with `UnavailableBrightnessMonitor` as the fallback.
///
/// ## What was measured, on macOS 27.0 (26A5416b), M3 Max, 2026-08-22
///
/// - **`DisplayServicesGetBrightness` reads the real user brightness on Apple Silicon.** It
///   tracked every change exactly across a run driving the panel from 0.835 to 0.20 to 1.0 and
///   back. The probe was **unsigned with no entitlements**, and read identically after re-signing
///   with `--options runtime`, so nothing about the hardened runtime Isleta ships under blocks it.
/// - **`DisplayServicesRegisterForBrightnessChangeNotifications` is a genuine push callback.**
///   Across nine real key-holds: 419 callbacks, mean **1.94 ms** from callback to a correct
///   re-read, and **zero callbacks in the 45 s after the user stopped**. Nothing on the idle path,
///   which is what §9 requires of every source.
///
/// ## Three things in the same area lie, and each is the one you would reach for
///
/// - **The `AppleARMBacklight` IORegistry route is dead, and it is dead in the most convincing way
///   possible.** `IODisplayParameters` → `brightness` reads a plausible `32768/65536`, and
///   `rawBrightness` and `BrightnessMilliNits` sit beside it looking live at `1488/2047` and
///   `381794/1599999`. **All three are frozen constants**: they did not move a digit while actual
///   brightness went 0.835 → 0.20 → 1.00 → 0.67. PROGRESS.md previously recorded this as "could not
///   be shown to track the panel, so it may be a constant"; it is not a maybe.
/// - **`IOServiceAddInterestNotification` on that node returns `KERN_SUCCESS` and never fires.**
///   Same shape as the KVO-on-battery-percentage trap in `BluetoothDeviceBattery`: registration
///   succeeds, and the callback is never called, so the code reads as correct forever.
/// - **`CoreDisplay_Display_GetUserBrightness` answers a constant `1.0000`.** It is named as the
///   user-brightness getter and it is the one every sample online reaches for.
///
/// ## The trap that invalidated the earlier measurement
///
/// PROGRESS.md recorded that the registry property "could not be shown to track the panel over ten
/// synthesized brightness keypresses". **Synthesized brightness keys do not change brightness on
/// Apple Silicon at all.** An `NSEventTypeSystemDefined` subtype-8 media key for
/// `NX_KEYTYPE_BRIGHTNESS_UP`/`DOWN`, posted to `kCGHIDEventTap` from a process with
/// `AXIsProcessTrusted() == true`, moved the value by exactly zero across four presses — the keys
/// are consumed below the event-tap layer. So the earlier probe's stimulus never fired, and a
/// frozen reading was evidence of nothing. The conclusion happened to be right; the reasoning that
/// produced it could not have distinguished a constant from a working property. **Any future
/// brightness measurement has to be driven by a real keypress or by `DisplayServicesSetBrightness`,
/// never by a posted key event.**
@MainActor
public final class DisplayServicesBrightnessMonitor: DisplayBrightnessMonitoring {

    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias RegisterForChanges = @convention(c) (
        CGDirectDisplayID, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
    ) -> Int32
    private typealias UnregisterForChanges = @convention(c) (
        CGDirectDisplayID, UnsafeMutableRawPointer?
    ) -> Int32

    private struct API {
        var get: GetBrightness
        var register: RegisterForChanges
        var unregister: UnregisterForChanges
    }

    private let api: API
    private let display: CGDirectDisplayID
    private var onChange: ((Double) -> Void)?
    private var isObserving = false

    /// Resolves the symbols, or returns nil if any is missing. A nil here is the fallback
    /// engaging, not an error — the caller substitutes `UnavailableBrightnessMonitor` and the
    /// brightness HUD is reported unavailable exactly as it was before this existed.
    public static func make() -> DisplayServicesBrightnessMonitor? {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW
        ) else { return nil }

        func symbol<T>(_ name: String, _: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }
        guard let get = symbol("DisplayServicesGetBrightness", GetBrightness.self),
              let register = symbol(
                "DisplayServicesRegisterForBrightnessChangeNotifications", RegisterForChanges.self
              ),
              let unregister = symbol(
                "DisplayServicesUnregisterForBrightnessChangeNotifications", UnregisterForChanges.self
              )
        else { return nil }

        guard let display = Self.builtInDisplay() else { return nil }

        let monitor = DisplayServicesBrightnessMonitor(
            api: API(get: get, register: register, unregister: unregister), display: display
        )
        // Reading is the only proof the symbol answers on this hardware. Resolving it is not:
        // `IODisplayGetFloatParameter` also resolves, and answers `kIOReturnUnsupported` forever.
        guard monitor.currentBrightness() != nil else { return nil }
        return monitor
    }

    private init(api: API, display: CGDirectDisplayID) {
        self.api = api
        self.display = display
    }

    /// The panel the brightness keys actually drive.
    ///
    /// `CGMainDisplayID()` is deliberately not it: the main display is wherever the menu bar is,
    /// which on a Mac with an external monitor is routinely not the built-in panel, and the
    /// brightness keys drive the built-in one regardless.
    private static func builtInDisplay() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return nil }
        return displays.first(where: { CGDisplayIsBuiltin($0) != 0 }) ?? displays.first
    }

    public var isAvailable: Bool { true }

    public func currentBrightness() -> Double? {
        var value: Float = 0
        guard api.get(display, &value) == 0 else { return nil }
        // A level outside 0...1 means the call answered with something that is not a brightness.
        guard value >= 0, value <= 1 else { return nil }
        return Double(value)
    }

    public func start(onChange: @escaping (Double) -> Void) {
        guard !isObserving else { return }
        self.onChange = onChange
        activeMonitor = self
        // The context pointer is passed as the callback's first argument, but it is deliberately
        // not used to find `self`: the callback's *second* argument is documented by observation to
        // be always 0 rather than the display id, so this API's arguments are not to be trusted
        // for identity. `activeMonitor` is the single source of truth and there is only ever one.
        isObserving = api.register(display, nil, unsafeBitCast(brightnessDidChange, to: UnsafeMutableRawPointer.self)) == 0
        if !isObserving {
            activeMonitor = nil
            self.onChange = nil
        }
    }

    public func stop() {
        guard isObserving else { return }
        isObserving = false
        _ = api.unregister(display, nil)
        activeMonitor = nil
        onChange = nil
    }

    /// Called on the main actor, from the C trampoline below.
    fileprivate func handleChange() {
        guard isObserving, let level = currentBrightness() else { return }
        onChange?(level)
    }
}

/// The one live monitor, for the C callback to find.
///
/// `nonisolated(unsafe)` and written only from the main actor: `start` and `stop` are both
/// `@MainActor`, and the callback below never touches it except by hopping to main first.
private nonisolated(unsafe) var activeMonitor: DisplayServicesBrightnessMonitor?

/// The C function DisplayServices calls.
///
/// **The hop to the main actor is mandatory, not tidiness.** `IOBluetooth` delivers its connect
/// notification on CoreBluetooth's XPC queue and takes SIGTRAP the first time real hardware
/// connects if the handler is `@MainActor` — see `BluetoothDeviceMonitor`. Which thread
/// DisplayServices uses is not documented and was observed only on the run loop of the registering
/// thread, so this makes no assumption about it: the callback does nothing but schedule.
private let brightnessDidChange: @convention(c) (
    UnsafeMutableRawPointer?, CGDirectDisplayID, UnsafeMutableRawPointer?,
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
) -> Void = { _, _, _, _, _ in
    DispatchQueue.main.async {
        MainActor.assumeIsolated { activeMonitor?.handleChange() }
    }
}
