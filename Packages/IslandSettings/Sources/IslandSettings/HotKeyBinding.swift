import AppKit
import Carbon.HIToolbox

/// A user-chosen global keyboard shortcut, stored as the pair `RegisterEventHotKey` actually wants.
///
/// Carbon's virtual key code and Carbon's modifier mask, not `NSEvent`'s. The conversion has to
/// happen somewhere, and doing it at the boundary where a key press is captured means the stored
/// value is the one `HotKeyMonitor.register(keyCode:modifiers:)` is handed verbatim. Storing Cocoa
/// modifier flags instead would put a translation step between the file and every registration —
/// and `NSEvent.ModifierFlags` carries device-specific bits (left vs right ⌘, numeric pad, caps
/// lock) that would be persisted and then silently fail to match a later key press from the other
/// side of the keyboard.
public struct HotKeyBinding: Codable, Equatable, Hashable, Sendable {

    /// A Carbon virtual key code, e.g. `kVK_ANSI_I`. Positional: it identifies the physical key,
    /// not the character on it, which is why `displayString` has to ask the current layout.
    public var keyCode: Int

    /// A Carbon modifier mask, e.g. `controlKey | optionKey | cmdKey`.
    public var carbonModifiers: Int

    public init(keyCode: Int, carbonModifiers: Int) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    /// The shipped default for the global island toggle: ⌃⌥⌘I.
    ///
    /// Chosen to collide with nothing rather than to be memorable — ⌥⌘I is the obvious pick and is
    /// Web Inspector in every browser. This is the value the hot key was hardcoded to before it was
    /// configurable, so a user who never opens Settings sees no change.
    public static let toggleIsland = HotKeyBinding(
        keyCode: kVK_ANSI_I,
        carbonModifiers: controlKey | optionKey | cmdKey
    )

    /// Whether this is safe to register system-wide.
    ///
    /// At least one of ⌘/⌃/⌥ is required. A shortcut with only ⇧ — or none at all — would take the
    /// key away from every text field on the machine for as long as Isleta is running, and the user
    /// would have no way to type it back to undo the choice.
    public var isValid: Bool {
        carbonModifiers & (cmdKey | controlKey | optionKey) != 0
    }

    /// The shortcut as it would be printed in a menu: modifier glyphs in Apple's order, then the key.
    ///
    /// Main-actor isolated because naming the key means asking the current keyboard layout, and
    /// that API is not thread-safe — see `keyName(for:)`.
    @MainActor
    public var displayString: String {
        Self.modifierGlyphs(carbonModifiers) + Self.keyName(for: keyCode)
    }

    /// Just the modifier glyphs, in the order macOS prints them — ⌃⌥⇧⌘, always, regardless of the
    /// order the user pressed them. Any other order reads as a different app's shortcut.
    ///
    /// Separate from `displayString` because the recorder has modifiers held and no key yet, and
    /// synthesising a binding with a placeholder key code to reuse `displayString` would print a
    /// letter the user never pressed.
    public static func modifierGlyphs(_ carbonModifiers: Int) -> String {
        var glyphs = ""
        if carbonModifiers & controlKey != 0 { glyphs += "⌃" }
        if carbonModifiers & optionKey != 0 { glyphs += "⌥" }
        if carbonModifiers & shiftKey != 0 { glyphs += "⇧" }
        if carbonModifiers & cmdKey != 0 { glyphs += "⌘" }
        return glyphs
    }

    // MARK: - Menu presentation

    /// AppKit's flags, for an `NSMenuItem` that shows the same shortcut.
    public var cocoaModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & controlKey != 0 { flags.insert(.control) }
        if carbonModifiers & optionKey != 0 { flags.insert(.option) }
        if carbonModifiers & shiftKey != 0 { flags.insert(.shift) }
        if carbonModifiers & cmdKey != 0 { flags.insert(.command) }
        return flags
    }

    /// The character an `NSMenuItem` needs to display this shortcut, or nil if the key has no
    /// single-character form.
    ///
    /// Nil rather than a glyph for the arrow and function keys: `NSMenuItem.keyEquivalent` expects
    /// the character the key produces, and handing it "←" prints a menu shortcut that no key press
    /// will ever match. A menu item with no key equivalent still works — the global hot key is what
    /// actually fires, and the menu is only echoing it.
    @MainActor
    public var menuKeyEquivalent: String? {
        let name = Self.keyName(for: keyCode)
        guard name.count == 1, let scalar = name.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(scalar) else { return nil }
        return name.lowercased()
    }

    // MARK: - Conversion

    /// Carbon's modifier mask from AppKit's flags.
    ///
    /// `deviceIndependentFlagsMask` first: a raw `NSEvent.ModifierFlags` also carries which side of
    /// the keyboard the key was on and whether the numeric pad was involved, and those bits mean
    /// nothing to `RegisterEventHotKey`.
    public static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> Int {
        let device = flags.intersection(.deviceIndependentFlagsMask)
        var mask = 0
        if device.contains(.control) { mask |= controlKey }
        if device.contains(.option) { mask |= optionKey }
        if device.contains(.shift) { mask |= shiftKey }
        if device.contains(.command) { mask |= cmdKey }
        return mask
    }

    /// The binding a key-down event describes, or nil if it does not describe a usable one.
    public init?(event: NSEvent) {
        let modifiers = Self.carbonModifiers(from: event.modifierFlags)
        let candidate = HotKeyBinding(keyCode: Int(event.keyCode), carbonModifiers: modifiers)
        guard candidate.isValid else { return nil }
        self = candidate
    }

    // MARK: - Key names

    /// Keys whose label is a glyph or a word rather than whatever character the layout produces.
    ///
    /// These are asked first because `UCKeyTranslate` answers for most of them too, with control
    /// characters and private-use scalars that render as tofu.
    static let namedKeys: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫",
        kVK_Escape: "⎋", kVK_ForwardDelete: "⌦", kVK_Help: "?⃝",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_ANSI_KeypadEnter: "⌤", kVK_ANSI_KeypadClear: "⌧",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16",
    ]

    /// What to print for a key code.
    ///
    /// Asks the *current* keyboard layout rather than assuming ANSI QWERTY. A key code is a
    /// position on the keyboard, so the hardcoded table every menu-bar app ships tells a Dvorak or
    /// AZERTY user their shortcut is a letter that is not on the key they pressed. The ANSI table
    /// below is the fallback for layouts that decline to translate, which is rare but does happen
    /// for input sources with no Unicode layout data (some IMEs).
    ///
    /// **`@MainActor` is load-bearing, not tidiness.**
    /// `TISCopyCurrentASCIICapableKeyboardLayoutInputSource` is not thread-safe: called from two
    /// threads at once it does not return a wrong answer, it aborts the process. Verified directly
    /// — 300 concurrent calls from a plain command-line binary die with SIGABRT, while 300
    /// concurrent `UCKeyTranslate` calls against one already-fetched layout blob are fine, so the
    /// input-source lookup is the unsafe half. It surfaced as a test bundle that crashed *after*
    /// every test reported passing, because swift-testing runs tests in parallel and three of them
    /// happened to name a key at the same moment. Isolating to the main actor serializes the call;
    /// caching the blob instead would also work but would go stale when the user switches layout.
    @MainActor
    static func keyName(for keyCode: Int) -> String {
        // Space is asked for ahead of the table because it is the one entry in it that is a *word*
        // rather than a glyph, and a word has to be said in the reader's language. Everything else
        // in `namedKeys` is a symbol or an F-number and reads the same in every language, which is
        // why the table itself stays a plain table.
        if keyCode == kVK_Space { return settingsText("shortcuts.key.space", "Space") }
        if let named = namedKeys[keyCode] { return named }
        if let translated = layoutCharacter(for: keyCode) { return translated }
        return ansiFallbackName(for: keyCode) ?? settingsText("shortcuts.key.unnamed", "Key \(keyCode)")
    }

    @MainActor
    private static func layoutCharacter(for keyCode: Int) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        let layoutData = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        // Read the capacity *before* the call. Passing `characters.count` as an argument to the
        // same call that takes `&characters` is a simultaneous access to `characters`, which the
        // exclusivity checker traps at runtime — a hard crash with no compile-time warning.
        let capacity = characters.count

        let status: OSStatus = layoutData.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return OSStatus(paramErr) }
            return UCKeyTranslate(
                base.assumingMemoryBound(to: UCKeyboardLayout.self),
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0,                                  // no modifiers: we want the bare key's label
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                capacity,
                &length,
                &characters
            )
        }

        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: characters, count: length)
        // Control characters and private-use scalars render as tofu; the named table covers the
        // keys that produce them, so anything left here is not printable.
        guard let scalar = text.unicodeScalars.first, scalar.value >= 0x20, scalar.value < 0xE000
        else { return nil }
        return text.uppercased()
    }

    private static func ansiFallbackName(for keyCode: Int) -> String? {
        let ansi: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
            kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
            kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
            kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
            kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        ]
        return ansi[keyCode]
    }
}
