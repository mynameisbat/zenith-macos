import Foundation

/// Protocol abstracting macOS system permission queries and deep-link navigations.
public protocol PermissionsServiceProtocol: Sendable {
    func checkScreenRecordingPermission() -> Bool
    func checkAccessibilityPermission() -> Bool
    func requestScreenRecordingPermission() -> Bool
    func requestAccessibilityPermission() -> Bool
    func openScreenRecordingSettings() -> Bool
    func openAccessibilitySettings() -> Bool
    /// Calendar access as macOS reports it, read without asking.
    func calendarAccess() -> CalendarAccessState
    /// Microphone access as macOS reports it, read without asking.
    func microphoneAccess() -> MicrophoneAccess
}

public extension PermissionsServiceProtocol {
    /// Stand-ins that predate the calendar report it as unavailable.
    func calendarAccess() -> CalendarAccessState { .unavailable }
    func microphoneAccess() -> MicrophoneAccess { .unavailable }
}
