import AppKit
import Carbon.HIToolbox

/// A system-wide hot key, via Carbon's `RegisterEventHotKey`.
///
/// Deliberately *not* `NSEvent.addGlobalMonitorForEvents`, which requires the Accessibility
/// permission — Milestone 0 requests no permissions, and the debug overlay must work before any
/// consent dialog has ever been shown. `RegisterEventHotKey` is public API in the still-supported
/// HIToolbox subset of Carbon, needs no entitlement and no permission, and was verified to return
/// `noErr` from an unbundled binary on this SDK.
@MainActor
public final class HotKeyMonitor {

    public struct RegistrationError: Error, CustomStringConvertible {
        public let status: OSStatus
        public var description: String { "RegisterEventHotKey failed with OSStatus \(status)" }
    }

    private static var handlers: [UInt32: () -> Void] = [:]
    private static var references: [UInt32: EventHotKeyRef] = [:]
    private static var eventHandler: EventHandlerRef?
    private static var nextID: UInt32 = 1

    /// Four-char code identifying our hot keys, so we never collide with another app's.
    private static let signature: OSType = 0x49_53_4C_41   // 'ISLA'

    public init() {}

    /// Registers a hot key and returns its identifier, usable with `unregister(_:)`.
    ///
    /// - Parameters:
    ///   - keyCode: A virtual key code, e.g. `kVK_ANSI_D`.
    ///   - modifiers: Carbon modifier mask, e.g. `optionKey | cmdKey`.
    @discardableResult
    public func register(
        keyCode: Int,
        modifiers: Int,
        handler: @escaping @MainActor () -> Void
    ) throws -> UInt32 {
        try Self.installEventHandlerIfNeeded()

        let id = Self.nextID
        Self.nextID += 1

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            UInt32(modifiers),
            EventHotKeyID(signature: Self.signature, id: id),
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else { throw RegistrationError(status: status) }

        Self.references[id] = ref
        Self.handlers[id] = handler
        return id
    }

    public func unregister(_ id: UInt32) {
        if let ref = Self.references.removeValue(forKey: id) {
            UnregisterEventHotKey(ref)
        }
        Self.handlers[id] = nil
    }

    public func unregisterAll() {
        for id in Self.references.keys { unregister(id) }
    }

    private static func installEventHandlerIfNeeded() throws {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            hotKeyEventHandler,
            1,
            &spec,
            nil,
            &eventHandler
        )
        guard status == noErr else { throw RegistrationError(status: status) }
    }

    /// Invoked from the Carbon dispatcher, which runs on the main thread — hence
    /// `assumeIsolated` rather than a hop, so the handler runs in the same turn as the key press.
    fileprivate nonisolated static func dispatch(id: UInt32) {
        MainActor.assumeIsolated {
            handlers[id]?()
        }
    }
}

private func hotKeyEventHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }
    HotKeyMonitor.dispatch(id: hotKeyID.id)
    return noErr
}
