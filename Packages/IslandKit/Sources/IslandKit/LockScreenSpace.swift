import AppKit

/// Somewhere to put a window that loginwindow's shield does not cover.
///
/// ## The measurement this exists for
///
/// A window's **level** has nothing to do with whether it survives a lock. Fourteen probe runs on
/// macOS 27.0 (26A5421a) tried every level from 0 to `Int32.max`, ordered front before the lock, at
/// the lock and every 250 ms during it, with `canBecomeVisibleWithoutLogin`, with every collection
/// behavior, with `sharingType = .none`, and with a byte-accurate replica of a competitor's own
/// disassembled window initializer. All of them composite **below** the shield.
///
/// What works is the absolute level of the **space** the window is hosted in:
///
/// ```
/// SLSSpaceCreate(connection, 1, nil)
/// SLSSpaceSetAbsoluteLevel(connection, space, 400)
/// SLSShowSpaces(connection, [space])
/// SLSAddWindowsToSpaces(connection, [windowNumber], [space])
/// ```
///
/// **400 is `kSLSSpaceAbsoluteLevelNotificationCenterAtScreenLock`** — the level macOS uses for
/// Notification Center's own content on the locked screen. Isolated across three locked samples with
/// a positive control in the same stack: a space at 400 composites above the shield whether its
/// window is at `CGShieldingWindowLevel()` or `Int32.max`, and a space at `Int32.max` composites
/// below at either. The window level is not the mechanism in either direction.
///
/// The surviving record — including why the first ten arms were unfalsifiable — is the
/// lock-screen section of `docs/PLATFORM-CONSTRAINTS.md`.
///
/// ## Why this is not `SkyLightOverlaySpace` with an argument
///
/// The two spaces want opposite things and one of them is load-bearing for a shipped feature.
/// `SkyLightOverlaySpace` exists so the island is in **no desktop's picture** during a space slide;
/// this exists so one panel is in **loginwindow's** picture during a lock. A space at 400 sits below
/// ordinary windows while unlocked, so hosting the island there would put it behind Safari. Sharing
/// a type would make that a one-argument mistake, and `IslandController` creates its space at
/// launch and keeps it for the process lifetime — exactly where such a mistake would not show up
/// until somebody locked the screen.
///
/// ## `Int32.max` was never a valid absolute level
///
/// `SLSSpaceSetAbsoluteLevel(space, Int32.max)` **silently fails**: `SLSSpaceGetAbsoluteLevel` reads
/// back 0. Asked for 400, it reads back 400. `SkyLightOverlaySpace` has therefore been running with
/// its space at level 0 since it was written — the island works anyway because its *window* level
/// does the ordering, so nothing surfaced it. That is a real discrepancy between what
/// `OverlaySpace.swift`'s comment claims and what the window server holds, and it is **deliberately
/// not fixed here**: the island's behavior is verified on hardware at the level it is actually
/// running at, and changing it is a separate change with its own probe. See PROGRESS.md.
///
/// ## Private API, and the shape that makes it safe
///
/// Same shape as `SkyLightOverlaySpace`, for the same reason: every symbol resolved with `dlsym`,
/// never linked, so a macOS that renames one produces `nil` from `make()` and there is simply no
/// lock-screen surface. The feature is absent, not broken. This is an undocumented space level and
/// it can change in any release — re-measure it every OS bump.
///
/// ## Teardown is not optional
///
/// The space lives in the window server, not in this process. `tearDown()` must run synchronously
/// before `exit()`, or the space outlives us until logout — the `applicationWillTerminate` trap in
/// CLAUDE.md, which this type is the second instance of.
@MainActor
public protocol LockScreenSpaceHost: AnyObject {
    /// Whether windows handed to `host(_:)` land in a space above the lock shield. False for the
    /// fallback. Diagnostics report this rather than assuming, because a host that silently did
    /// nothing would look exactly like one that worked until somebody locked the screen.
    var isHosting: Bool { get }
    func host(_ window: NSWindow)
    func release(_ window: NSWindow)
    /// Destroys the space. Must be called before the process exits.
    func tearDown()
}

/// The fallback: does nothing, says so. With this in place there is no lock-screen surface and
/// every other Isleta feature behaves exactly as it did before this existed.
@MainActor
public final class UnavailableLockScreenSpace: LockScreenSpaceHost {
    public init() {}
    public var isHosting: Bool { false }
    public func host(_ window: NSWindow) {}
    public func release(_ window: NSWindow) {}
    public func tearDown() {}
}

/// A host that hosts nothing and says it did: the space `--lockscreen-demo` runs against.
///
/// The lock surfaces cannot be looked at while the Mac is unlocked, and a space at absolute level
/// 400 is the reason — 400 composites above loginwindow's shield and **below** ordinary windows on
/// a desktop, so a demo that created the real space would draw the card behind Xcode. Hosting
/// nothing leaves the panels at `CGShieldingWindowLevel()` on the live desktop, which is where they
/// can be seen.
///
/// `isHosting` is true because that is what the caller's guard is asking — "is there any point
/// building panels?" — and for this one run there is. It is emphatically **not** a claim that the
/// panels would survive a lock; nothing that reports diagnostics should read it as one, which is
/// why the demo logs that it is a demo.
///
/// This eats clicks over the card's rectangle for as long as the run lasts. That is the trade a
/// demo flag makes, and it is why there is no way to turn it on except by typing it.
@MainActor
public final class DesktopLockScreenSpace: LockScreenSpaceHost {
    public init() {}
    public var isHosting: Bool { true }
    public func host(_ window: NSWindow) {}
    public func release(_ window: NSWindow) {}
    public func tearDown() {}
}

/// A private SkyLight space at the absolute level loginwindow shows Notification Center at.
@MainActor
public final class SkyLightLockScreenSpace: LockScreenSpaceHost {

    private typealias ConnectionID = UInt32
    private typealias SpaceID = UInt64
    private typealias MainConnection = @convention(c) () -> ConnectionID
    private typealias SpaceCreate = @convention(c) (ConnectionID, Int, CFDictionary?) -> SpaceID
    private typealias SpaceDestroy = @convention(c) (ConnectionID, SpaceID) -> Void
    private typealias SpaceSetLevel = @convention(c) (ConnectionID, SpaceID, Int) -> Void
    private typealias SpaceGetLevel = @convention(c) (ConnectionID, SpaceID) -> Int
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

    /// `kSLSSpaceAbsoluteLevelNotificationCenterAtScreenLock`.
    ///
    /// Not a number to tune. Measured: 400 composites above loginwindow's shield and `Int32.max`
    /// does not, and `Int32.max` is not even accepted — see the type comment. Named for what the
    /// system calls it so the next reader can search for it rather than wondering where 400 came
    /// from.
    public static let notificationCenterAtScreenLockLevel = 400

    /// Resolves the API and creates the space, or returns nil if any part of that fails.
    ///
    /// A nil here is the fallback engaging, not an error: the caller substitutes
    /// `UnavailableLockScreenSpace` and Isleta simply has no lock-screen surface.
    ///
    /// The level is **verified by read-back** rather than assumed. `SLSSpaceSetAbsoluteLevel` is a
    /// `void` call that accepts a value it will not honor — that is precisely how `Int32.max` went
    /// unnoticed in `SkyLightOverlaySpace` — so a space whose level does not read back as asked is
    /// destroyed and treated as unavailable. A surface silently sitting under the shield is worse
    /// than no surface, because it looks like a bug in the drawing rather than in the space.
    public static func make() -> SkyLightLockScreenSpace? {
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
              let getLevel = symbol("SLSSpaceGetAbsoluteLevel", SpaceGetLevel.self),
              let add = symbol("SLSAddWindowsToSpaces", WindowsAndSpaces.self),
              let remove = symbol("SLSRemoveWindowsFromSpaces", WindowsAndSpaces.self),
              let show = symbol("SLSShowSpaces", Spaces.self),
              let hide = symbol("SLSHideSpaces", Spaces.self)
        else {
            IslandLog.space.info("lock screen space: a SkyLight symbol is missing — no lock surface")
            return nil
        }

        let connection = mainConnection()
        // The `1` is boring.notch's undocumented constant, carried for the same reason
        // `SkyLightOverlaySpace` carries it: nobody has documented why, and changing it makes
        // Finder draw desktop icons in the new space.
        let space = create(connection, 1, nil)
        guard space != 0 else { return nil }

        setLevel(connection, space, notificationCenterAtScreenLockLevel)
        let readBack = getLevel(connection, space)
        guard readBack == notificationCenterAtScreenLockLevel else {
            IslandLog.space.info(
                "lock screen space: level read back \(readBack), asked "
                    + "\(notificationCenterAtScreenLockLevel) — no lock surface"
            )
            hide(connection, [space] as CFArray)
            destroy(connection, space)
            return nil
        }
        show(connection, [space] as CFArray)

        return SkyLightLockScreenSpace(
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
