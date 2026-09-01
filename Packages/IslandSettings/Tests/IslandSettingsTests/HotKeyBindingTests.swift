import AppKit
import Carbon.HIToolbox
import Testing

@testable import IslandSettings

/// `@MainActor` because `keyName(for:)` is: the input-source API it calls aborts the process
/// when two threads reach it at once, and swift-testing runs these in parallel.
@Suite("Hot key binding")
@MainActor
struct HotKeyBindingTests {

    /// A shortcut with no ⌘/⌃/⌥ would take the key away from every text field on the machine for
    /// as long as Isleta runs — and the user could not type it back to undo the choice.
    @Test("a shortcut needs at least one of command, control or option")
    func requiresARealModifier() {
        #expect(HotKeyBinding(keyCode: kVK_ANSI_I, carbonModifiers: 0).isValid == false)
        #expect(HotKeyBinding(keyCode: kVK_ANSI_I, carbonModifiers: shiftKey).isValid == false)
        #expect(HotKeyBinding(keyCode: kVK_ANSI_I, carbonModifiers: cmdKey).isValid)
        #expect(HotKeyBinding(keyCode: kVK_ANSI_I, carbonModifiers: optionKey).isValid)
        #expect(HotKeyBinding(keyCode: kVK_ANSI_I, carbonModifiers: controlKey).isValid)
        #expect(HotKeyBinding.toggleIsland.isValid)
    }

    /// macOS prints modifiers in one order regardless of the order they were pressed. Any other
    /// order reads as some other platform's shortcut.
    @Test("modifiers print in Apple's order, not the order they were pressed")
    func modifierGlyphOrder() {
        let all = cmdKey | shiftKey | optionKey | controlKey
        #expect(HotKeyBinding.modifierGlyphs(all) == "⌃⌥⇧⌘")
        #expect(HotKeyBinding.modifierGlyphs(0).isEmpty)
        #expect(HotKeyBinding.toggleIsland.displayString == "⌃⌥⌘" + HotKeyBinding.keyName(for: kVK_ANSI_I))
    }

    /// The bits `RegisterEventHotKey` understands, and nothing else. A raw `NSEvent.ModifierFlags`
    /// also carries which side of the keyboard the key was on; persisting those would make a stored
    /// shortcut fail to match the same keys pressed with the other hand.
    @Test("Cocoa modifier flags convert to Carbon's mask, dropping device-specific bits")
    func cocoaToCarbon() {
        #expect(HotKeyBinding.carbonModifiers(from: [.command]) == cmdKey)
        #expect(HotKeyBinding.carbonModifiers(from: [.control, .option, .command])
                == controlKey | optionKey | cmdKey)
        #expect(HotKeyBinding.carbonModifiers(from: [.capsLock, .function, .numericPad]) == 0)
        #expect(HotKeyBinding.carbonModifiers(from: []) == 0)
    }

    /// Keys whose label is a glyph must come from the table, not from the keyboard layout —
    /// `UCKeyTranslate` answers for most of them too, with control characters that render as tofu.
    @Test("glyph keys use their glyph")
    func namedKeysWin() {
        #expect(HotKeyBinding.keyName(for: kVK_Escape) == "⎋")
        // Space is the one entry in that table that is a word rather than a glyph, so it is looked
        // up; this asserts against the source language, and `LocalizationCoverageTests` is what
        // guards the other languages.
        #expect(HotKeyBinding.keyName(for: kVK_Space) == "Space")
        #expect(HotKeyBinding.keyName(for: kVK_LeftArrow) == "←")
        #expect(HotKeyBinding.keyName(for: kVK_F5) == "F5")
    }

    /// The key code is a *position*, so the printable name comes from the current layout. This
    /// deliberately does not assert "I", which is only true on a QWERTY layout — it asserts that
    /// something printable comes back rather than the `Key 34` last-resort form.
    @Test("a character key prints something printable on whatever layout is installed")
    func characterKeysAreNamed() {
        let name = HotKeyBinding.keyName(for: kVK_ANSI_I)
        #expect(!name.isEmpty)
        #expect(!name.hasPrefix("Key "))
    }

    @Test("an unknown key code degrades to something identifiable rather than blank")
    func unknownKeyCodesDegrade() {
        #expect(HotKeyBinding.keyName(for: 999) == "Key 999")
    }

    @Test("a binding survives a round trip")
    func codableRoundTrip() throws {
        let binding = HotKeyBinding(keyCode: kVK_ANSI_Q, carbonModifiers: cmdKey | shiftKey)
        let decoded = try JSONDecoder().decode(
            HotKeyBinding.self, from: try JSONEncoder().encode(binding))
        #expect(decoded == binding)
    }
}
