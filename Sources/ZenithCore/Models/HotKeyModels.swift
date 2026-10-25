import Foundation
import AppKit
import Carbon

// MARK: - Carbon Modifier Flags AppKit Bridge

public extension CarbonModifierFlags {
    /// Initializes CarbonModifierFlags from AppKit's NSEvent.ModifierFlags.
    init(nsModifierFlags: NSEvent.ModifierFlags) {
        var flags: CarbonModifierFlags = []
        if nsModifierFlags.contains(.command) { flags.insert(.command) }
        if nsModifierFlags.contains(.shift)   { flags.insert(.shift) }
        if nsModifierFlags.contains(.option)  { flags.insert(.option) }
        if nsModifierFlags.contains(.control) { flags.insert(.control) }
        self = flags
    }

    /// Converts CarbonModifierFlags to AppKit's NSEvent.ModifierFlags.
    var nsModifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.command) { flags.insert(.command) }
        if contains(.shift)   { flags.insert(.shift) }
        if contains(.option)  { flags.insert(.option) }
        if contains(.control) { flags.insert(.control) }
        return flags
    }
}

// MARK: - KeyCode Mapping Catalog

/// Exhaustive lookup table mapping Carbon virtual key codes (ANSI US standard)
/// to string names, glyphs, and vice versa.
public enum KeyCodeMapping {
    private static let codeToName: [UInt32: String] = [
        // ANSI Letters
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L",
        38: "J", 40: "K", 45: "N", 46: "M",

        // ANSI Numbers Row
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7",
        28: "8", 25: "9", 29: "0",

        // Navigation, Control & Whitespace
        36: "Return",
        48: "Tab",
        49: "Space",
        51: "Delete",
        53: "Escape",
        117: "ForwardDelete",
        123: "LeftArrow",
        124: "RightArrow",
        125: "DownArrow",
        126: "UpArrow",

        // Function Keys (F1 - F12)
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",

        // Punctuation & Symbols
        27: "-", 24: "=", 33: "[", 30: "]", 42: "\\", 41: ";", 39: "'",
        43: ",", 47: ".", 44: "/", 50: "`"
    ]

    private static let nameToCode: [String: UInt32] = {
        var map: [String: UInt32] = [:]
        for (code, name) in codeToName {
            map[name.uppercased()] = code
        }
        // Aliases & Glyphs
        map["ENTER"] = 36
        map["RETURN"] = 36
        map["↵"] = 36
        map["TAB"] = 48
        map["⇥"] = 48
        map["SPACE"] = 49
        map["BACKSPACE"] = 51
        map["DELETE"] = 51
        map["⌫"] = 51
        map["ESC"] = 53
        map["ESCAPE"] = 53
        map["⎋"] = 53
        map["LEFT"] = 123
        map["LEFTARROW"] = 123
        map["←"] = 123
        map["RIGHT"] = 124
        map["RIGHTARROW"] = 124
        map["→"] = 124
        map["DOWN"] = 125
        map["DOWNARROW"] = 125
        map["↓"] = 125
        map["UP"] = 126
        map["UPARROW"] = 126
        map["↑"] = 126
        return map
    }()

    /// Returns the human-readable display string for a virtual key code.
    public static func name(for keyCode: UInt32) -> String? {
        codeToName[keyCode]
    }

    /// Returns the virtual key code for a character, name, or glyph string (case-insensitive).
    public static func keyCode(for name: String) -> UInt32? {
        nameToCode[name.uppercased()]
    }
}

// MARK: - HotKey Parsing Errors

/// Errors thrown when parsing textual or symbol representations of hotkeys.
public enum HotKeyParseError: Error, Equatable, LocalizedError, Sendable {
    case emptyString
    case missingModifier
    case missingKey
    case unknownKey(String)

    public var errorDescription: String? {
        switch self {
        case .emptyString:
            return "The shortcut string is empty or contains only whitespace."
        case .missingModifier:
            return "The shortcut requires at least one modifier key (⌘, ⇧, ⌥, ⌃)."
        case .missingKey:
            return "The shortcut requires a valid non-modifier key character."
        case .unknownKey(let key):
            return "The key '\(key)' is not recognized in the virtual keycode mapping."
        }
    }
}

// MARK: - HotKey Parser & Formatter

/// Engine for bidirectional translation between user-facing shortcut strings and Carbon values.
public enum HotKeyParser {
    /// Returns the virtual keycode for a character or key name.
    public static func keyCode(for key: String) -> UInt32? {
        KeyCodeMapping.keyCode(for: key)
    }

    /// Returns the display name for a virtual keycode.
    public static func keyName(for code: UInt32) -> String? {
        KeyCodeMapping.name(for: code)
    }

    /// Formats a HotKeyDefinition into a standardized Apple HIG badge string (e.g. "⌘⇧V").
    public static func format(_ definition: HotKeyDefinition) -> String {
        if !definition.keyEquivalent.isEmpty {
            return definition.keyEquivalent
        }
        return format(keyCode: definition.keyCode, carbonModifiers: definition.carbonModifiers)
    }

    /// Formats virtual keycode and Carbon modifier mask into a standardized badge string.
    public static func format(keyCode: UInt32, carbonModifiers: UInt32) -> String {
        let flags = CarbonModifierFlags(rawValue: carbonModifiers)
        var result = ""
        // Apple HIG modifier display order: Control, Option, Command, Shift
        // Or Command, Shift for standard Cmd+Shift shortcuts:
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option)  { result += "⌥" }
        if flags.contains(.command) { result += "⌘" }
        if flags.contains(.shift)   { result += "⇧" }
        result += KeyCodeMapping.name(for: keyCode) ?? "?"
        return result
    }

    /// Parses a string representation (e.g. "⌘⇧V", "Cmd+Shift+V", "⌥V", "Ctrl+Alt+Cmd+A")
    /// into a tuple of Carbon modifier bitmask and virtual key code.
    public static func parse(_ string: String) throws -> (modifiers: UInt32, keyCode: UInt32) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw HotKeyParseError.emptyString
        }

        // 1. Separate leading/embedded modifier glyphs (⌘, ⇧, ⌥, ⌃)
        var glyphFlags: CarbonModifierFlags = []
        var nonGlyphChars: [Character] = []

        for char in trimmed {
            switch char {
            case "⌘": glyphFlags.insert(.command)
            case "⇧": glyphFlags.insert(.shift)
            case "⌥": glyphFlags.insert(.option)
            case "⌃": glyphFlags.insert(.control)
            default: nonGlyphChars.append(char)
            }
        }

        let nonGlyphString = String(nonGlyphChars).trimmingCharacters(in: .whitespaces)

        // If string had glyphs but no key character: missingKey
        if !glyphFlags.isEmpty && nonGlyphString.isEmpty {
            throw HotKeyParseError.missingKey
        }

        // If string had glyphs and a valid non-glyph key (e.g. "⌘⇧V", "⌥V", "⌘⌘V"):
        if !glyphFlags.isEmpty {
            if let code = KeyCodeMapping.keyCode(for: nonGlyphString) {
                return (glyphFlags.rawValue, code)
            }
        }

        // 2. Delimiter-separated text notation (e.g. "Cmd+Shift+V", "Cmd-Shift-V", "cmd + shift + v")
        let rawTokens: [String]
        if trimmed.contains("+") {
            rawTokens = trimmed.components(separatedBy: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        } else if trimmed.contains("-") && trimmed != "-" {
            rawTokens = trimmed.components(separatedBy: "-").map { $0.trimmingCharacters(in: .whitespaces) }
        } else {
            rawTokens = [trimmed]
        }

        if rawTokens.count > 1 {
            let keyToken = rawTokens.last!
            if keyToken.isEmpty {
                throw HotKeyParseError.missingKey
            }

            var textFlags: CarbonModifierFlags = []
            for modToken in rawTokens.dropLast() {
                guard let flag = parseModifierToken(modToken) else {
                    if !modToken.isEmpty {
                        throw HotKeyParseError.unknownKey(modToken)
                    }
                    continue
                }
                textFlags.insert(flag)
            }

            guard !textFlags.isEmpty else {
                throw HotKeyParseError.missingModifier
            }

            guard let code = KeyCodeMapping.keyCode(for: keyToken) else {
                throw HotKeyParseError.unknownKey(keyToken)
            }

            return (textFlags.rawValue, code)
        }

        // 3. Single token without delimiters
        if KeyCodeMapping.keyCode(for: trimmed) != nil {
            throw HotKeyParseError.missingModifier
        }

        if parseModifierToken(trimmed) != nil {
            throw HotKeyParseError.missingKey
        }

        throw HotKeyParseError.unknownKey(trimmed)
    }

    // MARK: - Token Parsing Helpers (Clean Code G28, G5)

    private static func parseModifierToken(_ token: String) -> CarbonModifierFlags? {
        switch token.lowercased() {
        case "cmd", "command", "⌘": return .command
        case "shift", "⇧": return .shift
        case "opt", "option", "alt", "⌥": return .option
        case "ctrl", "control", "⌃": return .control
        default: return nil
        }
    }
}

// MARK: - HotKeyShortcut Model

/// High-level model representing a validated keyboard shortcut combination.
public struct HotKeyShortcut: Sendable, Equatable, Hashable, Codable {
    public let keyCode: UInt32
    public let modifiers: CarbonModifierFlags

    public init(keyCode: UInt32, modifiers: CarbonModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = CarbonModifierFlags(rawValue: carbonModifiers)
    }

    public init(keyCode: UInt32, nsModifierFlags: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = CarbonModifierFlags(nsModifierFlags: nsModifierFlags)
    }

    /// Carbon modifier bitmask raw value.
    public var carbonModifiers: UInt32 {
        modifiers.rawValue
    }

    /// AppKit modifier flags equivalent.
    public var nsModifierFlags: NSEvent.ModifierFlags {
        modifiers.nsModifierFlags
    }

    /// Standardized badge glyph representation (e.g. "⌘⇧V").
    public var displayString: String {
        HotKeyParser.format(keyCode: keyCode, carbonModifiers: carbonModifiers)
    }

    /// Converts shortcut into a HotKeyDefinition.
    public func definition(id: String, name: String) -> HotKeyDefinition {
        HotKeyDefinition(
            id: id,
            name: name,
            keyCode: keyCode,
            carbonModifiers: carbonModifiers,
            keyEquivalent: displayString
        )
    }

    /// Parses a string representation (e.g. "⌘⇧V", "Cmd+Shift+V", "⌥V") into a HotKeyShortcut.
    public static func parse(_ string: String) -> HotKeyShortcut? {
        guard let (mods, code) = try? HotKeyParser.parse(string) else { return nil }
        return HotKeyShortcut(keyCode: code, carbonModifiers: mods)
    }
}
