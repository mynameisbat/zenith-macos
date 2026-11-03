import AppKit

/// The one place destructive actions ask "are you sure?".
@MainActor
public enum DestructiveConfirmation {
    /// Modal confirmation with Cancel as the default button, so a stray Return never destroys anything.
    public static func confirm(title: String, message: String, destructiveTitle: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: destructiveTitle)
        return alert.runModal() == .alertSecondButtonReturn
    }
}
