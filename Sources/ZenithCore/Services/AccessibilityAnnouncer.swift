import AppKit

/// Reads a short message aloud with VoiceOver (or any assistive app), for feedback that is otherwise only seen:
/// island alerts and toasts.
@MainActor
public enum AccessibilityAnnouncer {
    /// The messages announced so far, newest last (kept short; tests read it).
    public private(set) static var recentAnnouncements: [String] = []

    public static func announce(_ message: String) {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        recentAnnouncements.append(text)
        if recentAnnouncements.count > 20 {
            recentAnnouncements.removeFirst(recentAnnouncements.count - 20)
        }
        // A test process has no application object; there is nobody to announce to.
        guard let app = NSApp as NSApplication? else { return }
        NSAccessibility.post(
            element: app,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }
}
