import CoreGraphics
import Foundation
import IslandKit

/// Writing the display brightness, for when Isleta has swallowed the key that would have done it.
///
/// The counterpart to `SystemVolumeControl`, and the reason it is a separate type is the same reason
/// `BrightnessStep` is separate from `VolumeStep`: the two levels are written through different
/// frameworks, fail in different ways, and **one of them animates**.
///
/// # `SetBrightness`, and **never** `SetBrightnessSmooth`
///
/// The two have the same C signature and **different semantics**, which is the trap this file was
/// first written straight into. `DisplayServicesSetBrightnessSmooth` was chosen for the name, on the
/// reasoning that a brightness write should glide where a volume write lands — and it shipped a bug
/// that pinned the panel at full brightness, because its argument is a **delta**, not a level.
///
/// Measured 2026-08-30, five cases including negatives and zero:
///
/// ```
/// from 0.5000  smooth(+0.0825) -> 0.5825      0.5 + 0.0825   MATCH
/// from 0.5000  smooth(-0.0825) -> 0.4175      0.5 - 0.0825   MATCH
/// from 0.3000  smooth(+0.2000) -> 0.5000      0.3 + 0.2      MATCH
/// from 0.8000  smooth(-0.3000) -> 0.5000      0.8 - 0.3      MATCH
/// from 0.5000  smooth(+0.0000) -> 0.5000                     MATCH
/// ```
///
/// Handed a *level* it therefore adds that level to the current one: a press asking for 0.9175 from
/// 0.75 asked for 1.6675, clamped to 1.0, and every press afterwards did the same. The symptom on
/// hardware was "brightness down does one notch, I don't see it, and then nothing" — which is one
/// jump to maximum followed by `pushed at its maximum` forever.
///
/// **The absolute setter is exact on every rung**, measured across the whole ladder:
///
/// ```
/// plain(0.0100) -> 0.0100    plain(0.5875) -> 0.5875
/// plain(0.0925) -> 0.0925    plain(1.0000) -> 1.0000
/// plain(0.4225) -> 0.4225    plain(0.0000) -> 0.0000
/// ```
///
/// The smooth setter *could* be used correctly by passing `target - current`, and it is deliberately
/// not. An absolute write to a rung is **self-correcting**: every press lands exactly on the ladder
/// whatever happened before it. A relative write accumulates float error and drifts off the grid,
/// and a single bad read of the current level would leave the panel permanently offset. Correctness
/// that repairs itself beats a ramp.
///
/// Both readings also settled in **0 ms** — `DisplayServicesGetBrightness` reports the new value
/// immediately even while the backlight is still visually travelling — so nothing here needs to
/// track a pending target, which was the other candidate explanation for the same symptom.
///
/// # The refusal that matters
///
/// `SystemHUDSuppression` said for a year that swallowing a brightness key would leave the user
/// unable to change brightness at all — *"not a gray area; it is a broken laptop"*. That claim was
/// wrong about the API and **right about the stakes**. Everything here reports failure honestly so
/// `SystemHUDSource` can hand the key back rather than swallow one it cannot act on: a Mac where the
/// write is refused keeps working brightness keys and Apple's HUD.
///
/// # External displays are not covered
///
/// Measured on a single built-in panel. `DisplayServicesSetBrightness` on an external display is
/// **unmeasured**, and the brightness keys drive the built-in panel regardless of where the menu bar
/// is — which is why `DisplayServicesBrightnessMonitor` picks `CGDisplayIsBuiltin` rather than
/// `CGMainDisplayID`. This does the same, so a Mac with an external monitor replaces the key for its
/// built-in screen and leaves the external one alone, which is what the keys do anyway.
@MainActor
public protocol SystemBrightnessWriting: AnyObject {

    /// The built-in panel's brightness now, or nil if it cannot be read.
    func current() -> Double?

    /// Put the panel at `level`, absolutely.
    ///
    /// - Returns: the level read back, or nil if the write was refused. The read is immediate and
    ///   accurate — measured — so this is the effect rather than the request.
    @discardableResult
    func setBrightness(_ level: Double) -> Double?
}

/// The one for a Mac whose panel cannot be written — a test, a preview, an OS that moved the
/// symbols. Refuses everything, which makes `SystemHUDSource` let the key through.
@MainActor
public final class UnavailableBrightnessControl: SystemBrightnessWriting {
    public init() {}
    public func current() -> Double? { nil }
    public func setBrightness(_ level: Double) -> Double? { nil }
}

@MainActor
public final class SystemBrightnessControl: SystemBrightnessWriting {

    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private struct API {
        let get: Get
        /// `DisplayServicesSetBrightness` only. **Never the smooth variant** — see the type's note:
        /// it takes a delta, and its identical signature is what let it be substituted here once.
        let set: Set
    }

    private let api: API
    private let display: CGDirectDisplayID

    /// Resolves the symbols and **proves the panel answers**, or returns nil.
    ///
    /// The read at the end is the whole point, and it is `DisplayServicesBrightnessMonitor`'s lesson
    /// verbatim: resolving a symbol is not evidence it works. `IODisplayGetFloatParameter` resolves
    /// on every Mac and answers `kIOReturnUnsupported` forever.
    public static func make() -> SystemBrightnessControl? {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW
        ) else { return nil }

        func symbol<T>(_ name: String, _: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }
        guard let get = symbol("DisplayServicesGetBrightness", Get.self),
              let set = symbol("DisplayServicesSetBrightness", Set.self)
        else { return nil }

        guard let display = builtInDisplay() else { return nil }
        let control = SystemBrightnessControl(api: API(get: get, set: set), display: display)
        guard control.current() != nil else { return nil }
        IslandLog.sources.info("brightness control ready")
        return control
    }

    private init(api: API, display: CGDirectDisplayID) {
        self.api = api
        self.display = display
    }

    /// The panel the brightness keys actually drive.
    ///
    /// `CGMainDisplayID()` is deliberately not it, for `DisplayServicesBrightnessMonitor`'s reason:
    /// the main display is wherever the menu bar is, which on a Mac with an external monitor is
    /// routinely not the built-in panel, and the brightness keys drive the built-in one regardless.
    private static func builtInDisplay() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return nil }
        return displays.first { CGDisplayIsBuiltin($0) != 0 }
    }

    public func current() -> Double? {
        var value: Float = 0
        guard api.get(display, &value) == 0 else { return nil }
        return Double(value)
    }

    @discardableResult
    public func setBrightness(_ level: Double) -> Double? {
        let target = Float(BrightnessStep.clamp(level))
        guard api.set(display, target) == 0 else {
            IslandLog.sources.info("brightness write refused")
            return nil
        }
        // The read-back, which is the rule everywhere else in this codebase and turns out to hold
        // here too. An earlier version returned the target instead, on the belief that a write starts
        // a ramp the reading would lag behind; measured 2026-08-30, `DisplayServicesGetBrightness`
        // reports the new value in **0 ms** even while the backlight is still visually travelling.
        // So the effect is measurable after all, and there is no reason to trust the argument.
        return current()
    }
}
