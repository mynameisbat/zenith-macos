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

    /// Default dictionary containing all standard shortcut presets.
    public static var defaultDictionary: [String: HotKeyDefinition] {
        [
            defaultClipboard.id: defaultClipboard,
            defaultAreaCapture.id: defaultAreaCapture,
            defaultFullscreenCapture.id: defaultFullscreenCapture
        ]
    }
}
