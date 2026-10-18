import Testing
import Foundation
import AppKit
@testable import GoldenGateCore

@Suite("HotKeyParser Unit & Edge Case Test Suite")
struct HotKeyParserTests {

    @Test("Validates standard character keycode mapping")
    func testStandardKeycodeMapping() {
        #expect(HotKeyParser.keyCode(for: "A") == 0)
        #expect(HotKeyParser.keyCode(for: "a") == 0)
        #expect(HotKeyParser.keyCode(for: "V") == 9)
        #expect(HotKeyParser.keyCode(for: "v") == 9)
        #expect(HotKeyParser.keyCode(for: "X") == 7)
        #expect(HotKeyParser.keyCode(for: "x") == 7)
        #expect(HotKeyParser.keyCode(for: "C") == 8)
        #expect(HotKeyParser.keyCode(for: "Z") == 6)
        #expect(HotKeyParser.keyCode(for: "1") == 18)
        #expect(HotKeyParser.keyCode(for: "2") == 19)
        #expect(HotKeyParser.keyCode(for: "0") == 29)
        #expect(HotKeyParser.keyName(for: 0) == "A")
        #expect(HotKeyParser.keyName(for: 9) == "V")
    }

    @Test("Validates special navigation and whitespace keycode mapping")
    func testSpecialKeycodeMapping() {
        #expect(HotKeyParser.keyCode(for: "Return") == 36)
        #expect(HotKeyParser.keyCode(for: "Enter") == 36)
        #expect(HotKeyParser.keyCode(for: "↵") == 36)
        #expect(HotKeyParser.keyCode(for: "Escape") == 53)
        #expect(HotKeyParser.keyCode(for: "Esc") == 53)
        #expect(HotKeyParser.keyCode(for: "⎋") == 53)
        #expect(HotKeyParser.keyCode(for: "Space") == 49)
        #expect(HotKeyParser.keyCode(for: "Tab") == 48)
        #expect(HotKeyParser.keyCode(for: "⇥") == 48)
        #expect(HotKeyParser.keyCode(for: "Delete") == 51)
        #expect(HotKeyParser.keyCode(for: "Backspace") == 51)
        #expect(HotKeyParser.keyCode(for: "⌫") == 51)
        #expect(HotKeyParser.keyCode(for: "Left") == 123)
        #expect(HotKeyParser.keyCode(for: "←") == 123)
        #expect(HotKeyParser.keyCode(for: "Right") == 124)
        #expect(HotKeyParser.keyCode(for: "→") == 124)
        #expect(HotKeyParser.keyCode(for: "Down") == 125)
        #expect(HotKeyParser.keyCode(for: "↓") == 125)
        #expect(HotKeyParser.keyCode(for: "Up") == 126)
        #expect(HotKeyParser.keyCode(for: "↑") == 126)
    }

    @Test("Validates function keys F1 through F12 mapping")
    func testFunctionKeysMapping() {
        #expect(HotKeyParser.keyCode(for: "F1") == 122)
        #expect(HotKeyParser.keyCode(for: "F2") == 120)
        #expect(HotKeyParser.keyCode(for: "F3") == 99)
        #expect(HotKeyParser.keyCode(for: "F4") == 118)
        #expect(HotKeyParser.keyCode(for: "F5") == 96)
        #expect(HotKeyParser.keyCode(for: "F6") == 97)
        #expect(HotKeyParser.keyCode(for: "F7") == 98)
        #expect(HotKeyParser.keyCode(for: "F8") == 100)
        #expect(HotKeyParser.keyCode(for: "F9") == 101)
        #expect(HotKeyParser.keyCode(for: "F10") == 109)
        #expect(HotKeyParser.keyCode(for: "F11") == 103)
        #expect(HotKeyParser.keyCode(for: "F12") == 111)
    }

    @Test("Validates Apple modifier symbols parsing")
    func testAppleModifierSymbolsParsing() throws {
        let (mods, key) = try HotKeyParser.parse("⌘⇧V")
        let expectedMods = CarbonModifierFlags.command.rawValue | CarbonModifierFlags.shift.rawValue
        #expect(mods == expectedMods)
        #expect(key == 9)
    }

    @Test("Validates text format shortcut parsing with plus delimiter")
    func testTextFormatShortcutParsing() throws {
        let (mods, key) = try HotKeyParser.parse("Cmd+Shift+V")
        let expectedMods = CarbonModifierFlags.command.rawValue | CarbonModifierFlags.shift.rawValue
        #expect(mods == expectedMods)
        #expect(key == 9)
    }

    @Test("Validates alternative Option+V shortcut parsing")
    func testOptionVShortcutParsing() throws {
        let (mods, key) = try HotKeyParser.parse("⌥V")
        #expect(mods == CarbonModifierFlags.option.rawValue)
        #expect(key == 9)

        let (textMods, textKey) = try HotKeyParser.parse("Option+V")
        #expect(textMods == CarbonModifierFlags.option.rawValue)
        #expect(textKey == 9)
    }

    @Test("Validates multi-modifier combinations like Ctrl+Alt+Cmd+A")
    func testControlOptionCommandParsing() throws {
        let (mods, key) = try HotKeyParser.parse("⌃⌥⌘A")
        let expected = CarbonModifierFlags.control.rawValue | CarbonModifierFlags.option.rawValue | CarbonModifierFlags.command.rawValue
        #expect(mods == expected)
        #expect(key == 0)

        let (textMods, textKey) = try HotKeyParser.parse("Ctrl+Opt+Cmd+A")
        #expect(textMods == expected)
        #expect(textKey == 0)
    }

    @Test("Validates all four modifiers combination")
    func testAllFourModifiers() throws {
        let (mods, key) = try HotKeyParser.parse("⌃⌥⇧⌘Z")
        let expected = CarbonModifierFlags.control.rawValue | CarbonModifierFlags.option.rawValue | CarbonModifierFlags.shift.rawValue | CarbonModifierFlags.command.rawValue
        #expect(mods == expected)
        #expect(key == 6)
    }

    @Test("Validates hyphen delimiter syntax")
    func testHyphenDelimiterParsing() throws {
        let (mods, key) = try HotKeyParser.parse("Cmd-Shift-V")
        let expected = CarbonModifierFlags.command.rawValue | CarbonModifierFlags.shift.rawValue
        #expect(mods == expected)
        #expect(key == 9)
    }

    @Test("Validates repeated modifier deduplication safely")
    func testModifierDeduplication() throws {
        let (glyphMods, glyphKey) = try HotKeyParser.parse("⌘⌘V")
        #expect(glyphMods == CarbonModifierFlags.command.rawValue)
        #expect(glyphKey == 9)

        let (textMods, textKey) = try HotKeyParser.parse("Cmd+Cmd+V")
        #expect(textMods == CarbonModifierFlags.command.rawValue)
        #expect(textKey == 9)
    }

    @Test("Tolerates leading, trailing, and internal whitespace with mixed case")
    func testWhitespaceAndCaseInsensitivity() throws {
        let (mods, key) = try HotKeyParser.parse("  cmd + shift + v  ")
        let expected = CarbonModifierFlags.command.rawValue | CarbonModifierFlags.shift.rawValue
        #expect(mods == expected)
        #expect(key == 9)
    }

    @Test("Rejects bare key without modifiers")
    func testBareKeyRejection() {
        #expect(throws: HotKeyParseError.missingModifier) {
            try HotKeyParser.parse("V")
        }
        #expect(throws: HotKeyParseError.missingModifier) {
            try HotKeyParser.parse("Space")
        }
        #expect(throws: HotKeyParseError.missingModifier) {
            try HotKeyParser.parse("Return")
        }
    }

    @Test("Rejects empty string and whitespace-only inputs")
    func testEmptyStringRejection() {
        #expect(throws: HotKeyParseError.emptyString) {
            try HotKeyParser.parse("")
        }
        #expect(throws: HotKeyParseError.emptyString) {
            try HotKeyParser.parse("   ")
        }
    }

    @Test("Rejects missing key character")
    func testMissingKeyRejection() {
        #expect(throws: HotKeyParseError.missingKey) {
            try HotKeyParser.parse("⌘⇧")
        }
        #expect(throws: HotKeyParseError.missingKey) {
            try HotKeyParser.parse("Cmd+Shift+")
        }
    }

    @Test("Rejects unknown key names")
    func testUnknownKeyRejection() {
        #expect(throws: HotKeyParseError.unknownKey("UnknownKey123")) {
            try HotKeyParser.parse("Cmd+Shift+UnknownKey123")
        }
    }

    @Test("Serializes HotKeyDefinition to canonical badge string")
    func testCanonicalSerialization() {
        let def = HotKeyDefinition.defaultClipboard
        #expect(HotKeyParser.format(def) == "⌘⇧V")

        let optDef = HotKeyDefinition.alternativeClipboardOptionV
        #expect(HotKeyParser.format(optDef) == "⌥V")

        let areaDef = HotKeyDefinition.defaultAreaCapture
        #expect(HotKeyParser.format(areaDef) == "⌘⇧2")
    }

    @Test("Validates HotKeyShortcut model methods and AppKit modifiers bridge")
    func testHotKeyShortcutModel() {
        let shortcut = HotKeyShortcut.parse("⌘⇧V")
        #expect(shortcut != nil)
        #expect(shortcut?.keyCode == 9)
        #expect(shortcut?.carbonModifiers == CarbonModifierFlags.command.rawValue | CarbonModifierFlags.shift.rawValue)
        #expect(shortcut?.displayString == "⌘⇧V")

        let definition = shortcut?.definition(id: "custom.id", name: "Custom Name")
        #expect(definition?.id == "custom.id")
        #expect(definition?.name == "Custom Name")
        #expect(definition?.keyEquivalent == "⌘⇧V")

        // AppKit ModifierFlags conversion roundtrip
        let nsFlags: NSEvent.ModifierFlags = [.command, .shift]
        let carbonFlags = CarbonModifierFlags(nsModifierFlags: nsFlags)
        #expect(carbonFlags.contains(.command))
        #expect(carbonFlags.contains(.shift))
        #expect(!carbonFlags.contains(.option))

        let roundtrip = carbonFlags.nsModifierFlags
        #expect(roundtrip.contains(.command))
        #expect(roundtrip.contains(.shift))
    }
}
