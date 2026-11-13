import Foundation

/// Carbon modifier masks represented as a type-safe OptionSet.
public struct CarbonModifierFlags: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Carbon cmdKey flag (0x0100 = 256)
    public static let command = CarbonModifierFlags(rawValue: 1 << 8)
    /// Carbon shiftKey flag (0x0200 = 512)
    public static let shift   = CarbonModifierFlags(rawValue: 1 << 9)
    /// Carbon optionKey flag (0x0800 = 2048)
    public static let option  = CarbonModifierFlags(rawValue: 1 << 11)
    /// Carbon controlKey flag (0x1000 = 4096)
    public static let control = CarbonModifierFlags(rawValue: 1 << 12)
}

/// Immutable domain definition of a global keyboard shortcut.
public struct HotKeyDefinition: Identifiable, Sendable, Equatable, Hashable, Codable {
    /// Unique identifier for the shortcut action (e.g. "clipboard.toggle").
    public let id: String

    /// User-friendly display name (e.g. "Toggle Clipboard History").
    public let name: String

    /// Virtual key code according to Carbon HIToolbox (e.g. 0x09 for 'V').
    public let keyCode: UInt32

    /// Carbon modifier flags mask (e.g. `cmdKey | shiftKey`).
    public let carbonModifiers: UInt32

    /// Visual key equivalent badge string (e.g. "⌘⇧V", "⌘⇧2").
    public let keyEquivalent: String

    public init(
        id: String,
        name: String,
        keyCode: UInt32,
        carbonModifiers: UInt32,
        keyEquivalent: String
    ) {
        self.id = id
        self.name = name
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.keyEquivalent = keyEquivalent
    }

    // MARK: - Standard Action Identifiers
    public static let clipboardToggleId = "clipboard.toggle"
    public static let captureAreaId = "capture.area"
    public static let captureFullscreenId = "capture.fullscreen"
    public static let captureOCRId = "capture.ocr"
    public static let snippetsMenuId = "snippets.menu"

    // MARK: - Built-in Default Shortcut Configurations

    /// Default clipboard panel trigger: ⌘⇧V (Keycode 9: 'V', cmdKey + shiftKey)
    public static let defaultClipboard = HotKeyDefinition(
        id: clipboardToggleId,
        name: "Toggle Clipboard History",
        keyCode: 9, // kVK_ANSI_V
        carbonModifiers: CarbonModifierFlags.command.rawValue | CarbonModifierFlags.shift.rawValue,
        keyEquivalent: "⌘⇧V"
    )

    /// Alternative clipboard panel trigger: ⌥V (Keycode 9: 'V', optionKey)
    public static let alternativeClipboardOptionV = HotKeyDefinition(
        id: clipboardToggleId,
        name: "Toggle Clipboard History (Option+V)",
        keyCode: 9, // kVK_ANSI_V
        carbonModifiers: CarbonModifierFlags.option.rawValue,
        keyEquivalent: "⌥V"
    )

    /// Default area capture trigger: ⌘⇧2 (Keycode 19: '2', cmdKey + shiftKey)
    public static let defaultAreaCapture = HotKeyDefinition(
        id: captureAreaId,
        name: "Area Screen Capture",
        keyCode: 19, // kVK_ANSI_2
        carbonModifiers: CarbonModifierFlags.command.rawValue | CarbonModifierFlags.shift.rawValue,
        keyEquivalent: "⌘⇧2"
    )

    /// Alternative area capture trigger: ⌘⇧X (Keycode 7: 'X', cmdKey + shiftKey)
    public static let alternativeAreaCaptureX = HotKeyDefinition(
        id: captureAreaId,
        name: "Area Screen Capture (Cmd+Shift+X)",
        keyCode: 7, // kVK_ANSI_X
        carbonModifiers: CarbonModifierFlags.command.rawValue | CarbonModifierFlags.shift.rawValue,
        keyEquivalent: "⌘⇧X"
    )

    /// Default full screen capture trigger: ⌘⇧1 (Keycode 18: '1', cmdKey + shiftKey)
    public static let defaultFullscreenCapture = HotKeyDefinition(
        id: captureFullscreenId,
        name: "Full Screen Capture",
        keyCode: 18, // kVK_ANSI_1
        carbonModifiers: CarbonModifierFlags.command.rawValue | CarbonModifierFlags.shift.rawValue,
        keyEquivalent: "⌘⇧1"
    )

    /// Screen OCR & barcode recognition: ⌃⌥T (Keycode 17: 'T', "T for text").
    /// It used to be ⌘⇧3, which is also macOS's own "screenshot of the whole screen" shortcut: pressing it ran both.
    /// ⌘⇧3, ⌘⇧4, ⌘⇧5 and ⌘⇧6 belong to the system (see `macOSScreenshotShortcuts`). Not part of `defaultDictionary`,
    /// which holds the shortcuts older settings files know about.
    public static let defaultOCR = HotKeyDefinition(
        id: captureOCRId,
        name: "Screen OCR",
        keyCode: 17, // kVK_ANSI_T
        carbonModifiers: CarbonModifierFlags.control.rawValue | CarbonModifierFlags.option.rawValue,
        keyEquivalent: "⌃⌥T"
    )

    /// The snippet menu: ⌃⌥S (Keycode 1: 'S'). Like `defaultOCR`, not part of `defaultDictionary`.
    public static let defaultSnippetsMenu = HotKeyDefinition(
        id: snippetsMenuId,
        name: "Insert Snippet",
        keyCode: 1, // kVK_ANSI_S
        carbonModifiers: CarbonModifierFlags.control.rawValue | CarbonModifierFlags.option.rawValue,
        keyEquivalent: "⌃⌥S"
    )

    /// Key codes (with ⌘⇧) of macOS's screenshot shortcuts: 3, 4, 5 and 6. A Zenith shortcut on one of these fires
    /// together with the system's.
    public static let macOSScreenshotShortcuts: [(keyCode: UInt32, carbonModifiers: UInt32)] = {
        let modifiers = CarbonModifierFlags.command.rawValue | CarbonModifierFlags.shift.rawValue
        return [20, 21, 23, 22].map { (keyCode: UInt32($0), carbonModifiers: modifiers) }   // 3, 4, 5, 6
    }()

    /// Whether a shortcut would fire together with one of macOS's screenshot shortcuts.
    public var clashesWithMacOSScreenshot: Bool {
        Self.macOSScreenshotShortcuts.contains { $0.keyCode == keyCode && $0.carbonModifiers == carbonModifiers }
    }

    /// The shortcut as macOS menus write it: modifiers in the order ⌃⌥⇧⌘, then the key (e.g. "⇧⌘2").
    public var menuStyleKeyEquivalent: String {
        Self.menuStyle(keyEquivalent)
    }

    /// Puts the modifier symbols of a shortcut string in the order macOS menus use (⌃⌥⇧⌘), key last.
    public static func menuStyle(_ shortcut: String) -> String {
        let order: [Character] = ["⌃", "⌥", "⇧", "⌘"]
        let modifiers = order.filter { shortcut.contains($0) }
        let key = shortcut.filter { !order.contains($0) }
        return String(modifiers) + key
    }

    /// The built-in shortcut of an action, if it has one.
    public static func builtIn(for id: String) -> HotKeyDefinition? {
        if let definition = defaultDictionary[id] { return definition }
        switch id {
        case captureOCRId: return defaultOCR
        case snippetsMenuId: return defaultSnippetsMenu
        default: return nil
        }
    }

    /// Default dictionary containing all standard shortcut presets.
    public static var defaultDictionary: [String: HotKeyDefinition] {
        [
            defaultClipboard.id: defaultClipboard,
            defaultAreaCapture.id: defaultAreaCapture,
            defaultFullscreenCapture.id: defaultFullscreenCapture
        ]
    }
}
