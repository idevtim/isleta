import AppKit

/// Somewhere to put the island that a space transition cannot photograph.
///
/// A desktop space composites every window it contains into its own picture at the instant a slide
/// begins, and the island was in that picture — pinned over two desktops sailing past, then bouncing
/// back in on the space it had never left. Nothing the window server sends arrives before the picture
/// is taken, no window property opts out (five were tried, one at a time, all identical), and the
/// only trigger early enough is the trackpad gesture itself, which needs Input Monitoring. Measured on
/// macOS 27.0 across two days of probes; see CLAUDE.md.
///
/// The answer is not to hide in time. It is to not be *in* the space. The window server can host
/// windows in a space the user can never switch to, and a window there belongs to no desktop's
/// picture, so it stays pinned through every slide — desktop or fullscreen, swipe or keystroke —
/// with nothing to hide and nothing to restore. This is the mechanism boring.notch has shipped since
/// October 2024 (`NotchSpaceManager`, commit 970f875) and that DynamicIsland_Mac inherits; verified
/// on this Mac with a probe before a line of it was written: a panel in such a space reported zero
/// occlusion changes across nine switches, where an ordinary panel flips on every one.
///
/// ## Private API, and the shape that makes it safe
///
/// This is SkyLight, which `CLAUDE.md` forbids except behind a protocol with a working fallback —
/// the same shape as the `mediaremote-adapter` path, and this is the second and only other
/// exception. Every symbol is resolved with `dlsym` at runtime, never linked, so a macOS that
/// renames one produces `nil` from `SkyLightOverlaySpace.make()` and the island falls back to the
/// occlusion-driven hide in `IslandController`, which is what shipped before this existed and still
/// handles fullscreen transitions correctly. It does **not** fall back to crashing at launch.
///
/// `CGSSpaceCreate`'s first argument is `1`. boring.notch's wrapper notes it "MUST be 1, otherwise
/// Finder decides to draw desktop icons" in the new space; Lakr233's SkyLightWindow passes the same.
/// Neither says why and the header does not document it. Don't change it.
///
/// ## What it costs
///
/// - **The space must be destroyed on the way out.** It lives in the window server, not in this
///   process, so a space that is merely abandoned outlives us. `tearDown()` is synchronous through
///   to the window server for the same reason `ActivitySource.stopAndWait()` is — see the
///   `applicationWillTerminate` trap in CLAUDE.md. A crash still leaks one until logout; there is no
///   process-death hook for window-server state.
/// - **Nothing is above it.** `Int32.max` puts the island over Mission Control's own chrome. On a
///   real notch the closed island is inside the hardware cutout and covers nothing; on a synthesized
///   island it covers the center of the space-label row — boring.notch #1059, mitigated on their
///   `dev` branch with `.transient` on non-notched displays. Not yet done here; see PROGRESS.md.
@MainActor
public protocol OverlaySpaceHost: AnyObject {
    /// Whether windows handed to `host(_:)` actually land in a private space. False for the
    /// fallback, and what diagnostics report — a host that silently did nothing would be
    /// indistinguishable from one that worked.
    var isHosting: Bool { get }
    func host(_ window: NSWindow)
    func release(_ window: NSWindow)
    /// Destroys the space. Must be called before the process exits.
    func tearDown()
}

/// The fallback: does nothing, says so.
@MainActor
public final class UnavailableOverlaySpace: OverlaySpaceHost {
    public init() {}
    public var isHosting: Bool { false }
    public func host(_ window: NSWindow) {}
    public func release(_ window: NSWindow) {}
    public func tearDown() {}
}

/// A private SkyLight space at the highest absolute level.
@MainActor
public final class SkyLightOverlaySpace: OverlaySpaceHost {

    private typealias ConnectionID = UInt32
    private typealias SpaceID = UInt64
    private typealias MainConnection = @convention(c) () -> ConnectionID
    private typealias SpaceCreate = @convention(c) (ConnectionID, Int, CFDictionary?) -> SpaceID
    private typealias SpaceDestroy = @convention(c) (ConnectionID, SpaceID) -> Void
    private typealias SpaceSetLevel = @convention(c) (ConnectionID, SpaceID, Int) -> Void
    private typealias WindowsAndSpaces = @convention(c) (ConnectionID, CFArray, CFArray) -> Void
    private typealias Spaces = @convention(c) (ConnectionID, CFArray) -> Void

    private struct API {
        let connection: ConnectionID
        let destroy: SpaceDestroy
        let add: WindowsAndSpaces
        let remove: WindowsAndSpaces
        let hide: Spaces
    }

    private let api: API
    private let space: SpaceID
    private var hosted: Set<Int> = []
    private var isTornDown = false

    /// The level boring.notch uses. Anything lower risks sitting under some piece of system UI
    /// that then photographs the island again; nothing measured sits above this.
    private static let level = Int(Int32.max)

    /// Resolves the API and creates the space, or returns nil if any part of that fails. A nil
    /// here is the fallback engaging, not an error — the caller substitutes
    /// `UnavailableOverlaySpace` and the island behaves as it did before this existed.
    public static func make() -> SkyLightOverlaySpace? {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW
        ) else { return nil }

        func symbol<T>(_ name: String, _: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }
        guard let mainConnection = symbol("SLSMainConnectionID", MainConnection.self),
              let create = symbol("SLSSpaceCreate", SpaceCreate.self),
              let destroy = symbol("SLSSpaceDestroy", SpaceDestroy.self),
              let setLevel = symbol("SLSSpaceSetAbsoluteLevel", SpaceSetLevel.self),
              let add = symbol("SLSAddWindowsToSpaces", WindowsAndSpaces.self),
              let remove = symbol("SLSRemoveWindowsFromSpaces", WindowsAndSpaces.self),
              let show = symbol("SLSShowSpaces", Spaces.self),
              let hide = symbol("SLSHideSpaces", Spaces.self)
        else { return nil }

        let connection = mainConnection()
        let space = create(connection, 1, nil)
        guard space != 0 else { return nil }
        setLevel(connection, space, level)
        show(connection, [space] as CFArray)

        return SkyLightOverlaySpace(
            api: API(connection: connection, destroy: destroy, add: add, remove: remove, hide: hide),
            space: space
        )
    }

    private init(api: API, space: SpaceID) {
        self.api = api
        self.space = space
    }

    public var isHosting: Bool { !isTornDown }

    public func host(_ window: NSWindow) {
        guard !isTornDown, hosted.insert(window.windowNumber).inserted else { return }
        api.add(api.connection, [window.windowNumber] as CFArray, [space] as CFArray)
    }

    public func release(_ window: NSWindow) {
        guard !isTornDown, hosted.remove(window.windowNumber) != nil else { return }
        api.remove(api.connection, [window.windowNumber] as CFArray, [space] as CFArray)
    }

    public func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        if !hosted.isEmpty {
            api.remove(api.connection, Array(hosted) as CFArray, [space] as CFArray)
            hosted.removeAll()
        }
        api.hide(api.connection, [space] as CFArray)
        api.destroy(api.connection, space)
    }
}
