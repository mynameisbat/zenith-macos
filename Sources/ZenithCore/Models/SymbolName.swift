import AppKit

/// SF Symbols arrive with each macOS release. A name the running macOS does not have draws nothing (it only logs "No
/// symbol named … found in system symbol set"), and the compiler cannot catch it because the names are strings. The
/// ones below are newer than macOS 13, so each has an older symbol to fall back on.
public enum SymbolName {
    /// `preferred` if this macOS has that symbol, otherwise `fallback` (which must exist on macOS 13).
    public static func available(_ preferred: String, fallback: String) -> String {
        NSImage(systemSymbolName: preferred, accessibilityDescription: nil) != nil ? preferred : fallback
    }

    /// Privacy Shield is protecting the traffic (`shield.checkered` needs macOS 14).
    public static let shieldProtected = available("shield.checkered", fallback: "checkmark.shield")

    /// Nothing was found in the captured area (`exclamationmark.magnifyingglass` needs macOS 14).
    public static let noTextFound = available("exclamationmark.magnifyingglass", fallback: "magnifyingglass")

    /// The Accessibility permission (`accessibility` needs macOS 14).
    public static let accessibility = available("accessibility", fallback: "figure.stand")
}
