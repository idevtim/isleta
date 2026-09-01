import AppKit
import Observation

/// Captures the next shortcut the user types, for the "click here, then press keys" field.
///
/// A **local** event monitor, not a global one. `addGlobalMonitorForEvents` needs the Accessibility
/// permission, and asking for it in order to let someone choose a keyboard shortcut would be an
/// absurd trade — the settings window is key while recording, so the events are ours already.
///
/// The monitor returns nil for the events it takes, which swallows them. Without that, ⌘Q typed
/// while recording would be recorded *and* quit the app.
@MainActor
@Observable
public final class HotKeyRecorder {

    public private(set) var isRecording = false

    /// The modifiers held right now, so the field can show ⌃⌥⌘ building up before a key completes
    /// the shortcut. Without it, recording looks like nothing is happening until it is over.
    public private(set) var pendingModifiers: NSEvent.ModifierFlags = []

    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private let onCapture: @MainActor (HotKeyBinding) -> Void

    public init(onCapture: @escaping @MainActor (HotKeyBinding) -> Void) {
        self.onCapture = onCapture
    }

    isolated deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    public func begin() {
        guard !isRecording else { return }
        isRecording = true
        pendingModifiers = []

        // AppKit delivers local monitor callbacks on the main thread, but the block is not typed
        // as isolated, so the hop is asserted rather than performed — a real hop would let the key
        // event be dispatched to the window before we had a chance to swallow it. The result is
        // carried out through a local rather than returned from `assumeIsolated`, whose return type
        // must be `Sendable` and `NSEvent` explicitly is not.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            var result: NSEvent?
            MainActor.assumeIsolated { result = self.handle(event) }
            return result
        }
    }

    public func cancel() {
        guard isRecording else { return }
        isRecording = false
        pendingModifiers = []
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        if event.type == .flagsChanged {
            pendingModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            return nil
        }

        // Escape with no modifiers abandons recording rather than becoming the shortcut. A bare
        // Escape is how the rest of macOS says "never mind", and it is also not a legal binding.
        if Int(event.keyCode) == 53, HotKeyBinding.carbonModifiers(from: event.modifierFlags) == 0 {
            cancel()
            return nil
        }

        guard let binding = HotKeyBinding(event: event) else {
            // A key with no ⌘/⌃/⌥ is rejected and recording continues, rather than being accepted
            // and then failing later: registering a bare letter globally would take it away from
            // every text field on the machine, and the user could not type it back to undo that.
            return nil
        }

        cancel()
        onCapture(binding)
        return nil
    }
}
