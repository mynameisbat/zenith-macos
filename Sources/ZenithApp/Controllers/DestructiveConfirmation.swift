import AppKit

/// The one place destructive actions ask "are you sure?".
@MainActor
public enum DestructiveConfirmation {
    /// Modal confirmation with Cancel as the default button, so a stray Return never destroys anything.
    /// For texts written here (literals, translated through the string table).
    public static func confirm(
        title: String.LocalizationValue,
        message: String.LocalizationValue,
        destructiveTitle: String.LocalizationValue
    ) -> Bool {
        confirm(
            verbatimTitle: String(localized: title),
            message: String(localized: message),
            destructiveTitle: String(localized: destructiveTitle)
        )
    }

    /// For texts that are already in the user's language (Core builds its own, with `String(localized:)`).
    public static func confirm(verbatimTitle title: String, message: String, destructiveTitle: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: destructiveTitle)
        return alert.runModal() == .alertSecondButtonReturn
    }
}
