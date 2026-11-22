import AppKit

/// SF Symbols arrive with each macOS release. A name the running macOS does not have draws nothing (it only logs "No
/// symbol named … found in system symbol set"), and the compiler cannot catch it because the names are strings. A
/// symbol newer than the deployment target (macOS 15) goes here with `available(_:fallback:)`.
public enum SymbolName {
    /// `preferred` if this macOS has that symbol, otherwise `fallback` (which must exist on macOS 15).
    public static func available(_ preferred: String, fallback: String) -> String {
        NSImage(systemSymbolName: preferred, accessibilityDescription: nil) != nil ? preferred : fallback
    }

    /// Privacy Shield is protecting the traffic.
    public static let shieldProtected = "shield.checkered"

    /// Nothing was found in the captured area.
    public static let noTextFound = "exclamationmark.magnifyingglass"

    /// The Accessibility permission.
    public static let accessibility = "accessibility"
}
