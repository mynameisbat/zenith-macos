import Foundation

/// Protocol abstracting macOS system permission queries and deep-link navigations.
public protocol PermissionsServiceProtocol: Sendable {
    func checkScreenRecordingPermission() -> Bool
    func checkAccessibilityPermission() -> Bool
    func requestScreenRecordingPermission() -> Bool
    func requestAccessibilityPermission() -> Bool
    func openScreenRecordingSettings() -> Bool
    func openAccessibilitySettings() -> Bool
}
