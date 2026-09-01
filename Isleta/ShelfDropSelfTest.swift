import AppKit
import IslandKit
import IslandUI

/// Drives a real drag onto the island and reports what happened.
///
/// The same bargain `ClickSelfTest` strikes, for the same reason. A genuine drag cannot be
/// synthesised without `CGEventPost` and the Accessibility permission Isleta does not ask for, so
/// this builds the `NSDraggingInfo` AppKit would hand us and calls the destination methods
/// directly. That covers everything from AppKit's entry point inward — type registration, the
/// enter/exit latch, `islandPath` gating the drop, the island opening, the pasteboard being read,
/// the item landing on the shelf, the tile being draggable back out, and the remove badge — but
/// **not** the window server's decision to route the drag to our window in the first place. That
/// half is the same mechanism `PassThroughSelfTest` measures for clicks, and this checks it the
/// same way: by asking the window server who owns the pixel the drag was delivered to.
@MainActor
enum ShelfDropSelfTest {

    static func isRequested() -> Bool {
        ProcessInfo.processInfo.arguments.contains("--shelf-test")
    }

    static func run(
        controller: IslandController,
        shelf: ShelfModel,
        screenModel: @escaping @MainActor (CGDirectDisplayID) -> IslandScreenModel?,
        completion: @escaping @MainActor (String) -> Void
    ) {
        var lines: [String] = []
        var failures: [String] = []

        func check(_ label: String, _ condition: Bool, _ detail: String = "") {
            lines.append("\(condition ? "ok  " : "FAIL") \(label)\(detail.isEmpty ? "" : " — \(detail)")")
            if !condition { failures.append(label) }
        }

        guard let info = controller.debugInfo().first,
              let window = NSApp.window(withWindowNumber: info.windowNumber),
              let view = window.contentView as? IslandHitTestView else {
            completion("no island to test")
            return
        }
        guard let model = screenModel(info.screen.id) else {
            completion("no model for screen \(info.screen.id)")
            return
        }

        // 1. Registration survived panel construction.
        let registered = view.registeredDraggedTypes
        check("registered for file URLs", registered.contains(.fileURL), "\(registered.count) types")

        // 2. A file to drag. Deleted at the very end rather than by a `defer`, which would fire
        // when this method returns — long before the asynchronous steps below run, leaving the
        // drop to land on a file that no longer exists.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("isleta-shelf-selftest-\(UUID().uuidString).txt")
        do {
            try Data("shelf".utf8).write(to: file)
        } catch {
            completion("FAIL — could not write a file to drag: \(error)")
            return
        }

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.tryisleta.isleta.shelf-selftest"))
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])

        // The notch center, in the window's own y-up space — where a drag aimed at the island lands.
        let notch = info.screen.notch.rect
        let inWindow = CGPoint(x: notch.midX - info.panelFrame.minX, y: notch.midY - info.panelFrame.minY)

        // The window server's half of the routing, asked the same way `PassThroughSelfTest` asks it.
        // On a locked screen every pixel resolves to the window server's shield window, and this
        // reports a false failure exactly as the documented `inside-*` probes do.
        if ScreenLock.isLocked {
            lines.append("skip the window server routes the notch pixel to Isleta — screen locked")
        } else {
            let owner = controller.windowNumberAtScreenPoint(CGPoint(x: notch.midX, y: notch.midY))
            check("the window server routes the notch pixel to Isleta", owner == info.windowNumber, "window #\(owner)")
        }

        let drag = StubDraggingInfo(pasteboard: pasteboard, location: inWindow, window: window)
        let outside = StubDraggingInfo(pasteboard: pasteboard, location: CGPoint(x: 8, y: 8), window: window)

        func finish() {
            view.draggingExited(nil)
            try? FileManager.default.removeItem(at: file)
            let verdict = failures.isEmpty
                ? "PASS — drag in, open, leave, close, drop, hold, drag out, remove"
                : "FAIL — \(failures.joined(separator: ", "))"
            completion(([verdict] + lines).joined(separator: "\n                  "))
        }

        func after(_ seconds: TimeInterval, _ next: @escaping @MainActor () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                MainActor.assumeIsolated { next() }
            }
        }

        // 3. Entering opens the island.
        check("draggingEntered accepts a file", view.draggingEntered(drag).contains(.copy))

        after(0.7) {
            check("the island opened for the drag", model.isExpanded, "\(model.presentation)")

            // The expansion has to have rendered, not merely been recorded: this point is far below
            // the resting island and can only be ours if the island really grew.
            let deep = CGPoint(
                x: notch.midX,
                y: notch.minY - (IslandLayout.expandedBodySize.height - notch.height) / 2
            )
            if ScreenLock.isLocked {
                lines.append("skip the open island renders where the drop lands — screen locked")
            } else {
                check(
                    "the open island renders where the drop lands",
                    controller.ownsWindowNumber(controller.windowNumberAtScreenPoint(deep))
                )
            }

            // 4. A drag wandering off the island is refused, and closes it again — the latch in
            // `IslandDragAndDrop`, which does not wait for a `draggingExited:` that may never come.
            check("a drag over transparent panel is refused", view.draggingUpdated(outside) == NSDragOperation())

            after(0.7) {
                check("the island closed when the drag left it", !model.isExpanded, "\(model.presentation)")
                check("re-entering re-opens it", view.draggingUpdated(drag).contains(.copy))

                after(0.7) {
                    // 5. The drop itself.
                    check("performDragOperation accepted", view.performDragOperation(drag))

                    after(0.6) {
                        check("the file is on the shelf", shelf.count == 1, "\(shelf.count) item(s)")
                        check("the shelf is what the island is showing", shelf.isPresented)

                        // 6. The tile can be lifted back out, and the remove badge is reachable.
                        let handlers = view.dragging.handlers
                        let origin = IslandLayout.bodyOrigin(
                            for: model.contentMetrics, in: info.panelFrame.size
                        )
                        let layout = ShelfLayout.resolve(
                            body: model.slotLayout.body, slotCount: shelf.slotCount
                        )

                        guard let handlers, let layout, let tile = layout.tiles.first,
                              let badge = layout.removeBadge(at: 0) else {
                            check("the open shelf resolved a layout", false)
                            finish()
                            return
                        }

                        let tileCenter = CGPoint(x: origin.x + tile.midX, y: origin.y + tile.midY)
                        check(
                            "the tile is inside the island's hit region",
                            view.hitTest(view.convert(tileCenter, to: nil)) != nil
                        )
                        check("the tile drags out as a file", handlers.itemsToDragOut(tileCenter).count == 1)

                        let badgeCenter = CGPoint(x: origin.x + badge.midX, y: origin.y + badge.midY)
                        check("the remove badge consumes its click", handlers.mouseDown(badgeCenter))
                        check("removing empties the shelf", shelf.isEmpty, "\(shelf.count) item(s)")
                        finish()
                    }
                }
            }
        }
    }
}

/// The `NSDraggingInfo` AppKit would hand a destination, with only the parts a destination reads
/// filled in.
///
/// Every member is required by the protocol whether or not anything here uses it. The conformance
/// is isolated to the main actor because dragging is main-actor work throughout, and
/// `namesOfPromisedFilesDropped` overrides a deprecated `NSObject` method of the same name rather
/// than merely satisfying the protocol — which is a compile error without `override` and no warning
/// at all with it.
@MainActor
private final class StubDraggingInfo: NSObject, @MainActor NSDraggingInfo {

    private let pasteboard: NSPasteboard
    private let location: NSPoint
    private let window: NSWindow

    init(pasteboard: NSPasteboard, location: NSPoint, window: NSWindow) {
        self.pasteboard = pasteboard
        self.location = location
        self.window = window
    }

    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .generic] }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { location }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination: Bool = false
    var numberOfValidItemsForDrop: Int = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions,
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
}
