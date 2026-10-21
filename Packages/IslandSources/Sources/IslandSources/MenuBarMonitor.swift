import AppKit
import ApplicationServices
import IslandKit

/// Compares AX rectangles (global y-down) with the closed island (AppKit y-up).
public enum MenuBarAvoidance {
    public static func needsSpace(
        items: [CGRect]?, on screen: IslandScreen, closedWidth: CGFloat, desktopTop: CGFloat,
        wasRetracted: Bool = false
    ) -> Bool {
        guard screen.notch.kind == .hardware else { return false }
        // Pending/failed IPC is not evidence of a collision. Preserve the last confirmed shape.
        guard let items else { return wasRetracted }
        let notch = screen.notch.rect
        let body = CGRect(
            x: notch.midX - closedWidth / 2, y: desktopTop - notch.maxY,
            width: closedWidth, height: notch.height
        )
        return items.contains { $0.insetBy(dx: -4, dy: 0).intersects(body) }
    }
}

/// Reads only top-level menu geometry. No titles, menu commands or user content are retained.
/// Activation, screen changes and AX hints drive bounded reads; there is no idle poll.
@MainActor
public final class MenuBarMonitor {
    private var workspaceObservers: [NSObjectProtocol] = []
    private var appObservers: [NSObjectProtocol] = []
    private var onChange: (([CGRect]?) -> Void)?
    private var revision = 0
    private var lastReadItemCount: Int?
    private var lastAuthorization: Bool?
    private var lastProcessID: pid_t?
    private var pendingRefresh: Task<Void, Never>?
    private lazy var reader = MenuBarAXReader { [weak self] in
        Task { @MainActor [weak self] in self?.scheduleRefresh() }
    }

    public init() {}

    /// Read live for exported diagnostics; the source never raises a permission prompt.
    public var diagnosticSummary: String {
        guard AXIsProcessTrusted() else { return "Accessibility not granted; menu geometry unavailable" }
        if let lastReadItemCount { return "Accessibility granted; \(lastReadItemCount) menu items read" }
        return "Accessibility granted; no successful menu read"
    }

    isolated deinit { stop() }

    public func start(_ onChange: @escaping ([CGRect]?) -> Void) {
        guard self.onChange == nil else { return }
        self.onChange = onChange
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            })
        }
        for name in [NSApplication.didChangeScreenParametersNotification, NSApplication.didBecomeActiveNotification] {
            appObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            })
        }
        refresh()
    }

    /// Also called when settings/status menus are opened, to notice an Accessibility grant.
    public func refresh() {
        guard onChange != nil else { return }
        let authorized = AXIsProcessTrusted()
        if authorized != lastAuthorization {
            lastAuthorization = authorized
            IslandLog.panel.info(authorized
                ? "menu geometry: Accessibility granted"
                : "menu geometry unavailable: Accessibility is not granted to this build")
        }
        revision += 1
        let request = revision
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if pid != lastProcessID {
            lastProcessID = pid
            onChange?(nil)
        }
        reader.read(processID: pid) { [weak self] items in
            Task { @MainActor [weak self] in
                guard let self, self.revision == request, self.onChange != nil,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                self.lastReadItemCount = items?.count
                self.onChange?(items)
            }
        }
    }

    private func scheduleRefresh() {
        guard onChange != nil, pendingRefresh == nil else { return }
        pendingRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled, let self else { return }
            self.pendingRefresh = nil
            self.refresh()
        }
    }

    public func stop() {
        revision += 1
        onChange = nil
        pendingRefresh?.cancel()
        pendingRefresh = nil
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        for observer in appObservers { NotificationCenter.default.removeObserver(observer) }
        workspaceObservers.removeAll()
        appObservers.removeAll()
        reader.stopAndWait()
    }
}

/// All mutable AX state is confined to `queue`. The main-run-loop C callback only enqueues a hint.
private final class MenuBarAXReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.tryisleta.menu-geometry", qos: .utility)
    private let changed: @Sendable () -> Void
    private var processID: pid_t?
    private var application: AXUIElement?
    private var observer: AXObserver?

    init(changed: @escaping @Sendable () -> Void) { self.changed = changed }

    func read(processID: pid_t?, completion: @escaping @Sendable ([CGRect]?) -> Void) {
        queue.async { [self] in
            guard AXIsProcessTrusted(), let processID else {
                detach()
                completion(nil)
                return
            }
            if self.processID != processID || application == nil { attach(processID) }
            completion(application.flatMap { MenuBarGeometryReader.read(application: $0) })
        }
    }

    private func attach(_ pid: pid_t) {
        detach()
        processID = pid
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        application = app
        var created: AXObserver?
        guard AXObserverCreate(pid, { _, _, _, context in
            guard let context else { return }
            Unmanaged<MenuBarAXReader>.fromOpaque(context).takeUnretainedValue().changed()
        }, &created) == .success, let created else { return }
        observer = created
        // Hints only: registration success does not prove an app sends a particular notification.
        for name in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
                     kAXMenuOpenedNotification, kAXMenuClosedNotification, kAXLayoutChangedNotification] {
            AXObserverAddNotification(created, app, name as CFString, Unmanaged.passUnretained(self).toOpaque())
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        application = nil
        processID = nil
    }

    func stopAndWait() { queue.sync { detach() } }

    deinit { detach() }
}

/// The permission check precedes every IPC, including in the denied-state test.
enum MenuBarGeometryReader {
    static func read(processID: pid_t, isTrusted: () -> Bool) -> [CGRect]? {
        guard isTrusted() else { return nil }
        return read(application: AXUIElementCreateApplication(processID))
    }

    static func read(application: AXUIElement) -> [CGRect]? {
        AXUIElementSetMessagingTimeout(application, 0.05)
        let deadline = ContinuousClock.now + .milliseconds(200)
        guard let menu = element(application, attribute: kAXMenuBarAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(menu, 0.05)
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menu, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement], children.count <= 64 else { return nil }
        var frames: [CGRect] = []
        for child in children {
            guard ContinuousClock.now < deadline else { return nil }
            AXUIElementSetMessagingTimeout(child, 0.05)
            var positionValue: CFTypeRef?
            var sizeValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &positionValue) == .success,
                  AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &sizeValue) == .success,
                  let positionValue, let sizeValue,
                  CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID()
            else { return nil }
            var point = CGPoint.zero
            var size = CGSize.zero
            guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
                  AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
                  point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite
            else { return nil }
            if size.width > 0, size.height > 0 { frames.append(CGRect(origin: point, size: size)) }
        }
        return frames
    }

    private static func element(_ parent: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
