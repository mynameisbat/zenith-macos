import Foundation
import CoreGraphics
import ApplicationServices
import AppKit

/// Static system permission utilities for macOS Screen Recording and Accessibility.
public struct SystemPermissions {
    /// Deep link to macOS System Settings -> Privacy & Security -> Screen Recording.
    public static let screenRecordingSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    )!

    /// Deep link to macOS System Settings -> Privacy & Security -> Accessibility.
    public static let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )!

    /// Checks whether Zenith currently has permission to record/capture the screen.
    /// Does not present a dialog if permission is denied or not yet requested.
    public static func checkScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Requests screen recording access from the user, presenting the system dialog if needed.
    public static func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Checks whether the application is trusted for Accessibility access.
    public static func checkAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    /// Requests accessibility access, triggering the macOS system prompt directing the user to System Settings.
    public static func requestAccessibilityPermission() -> Bool {
        let key = "AXTrustedCheckOptionPrompt"
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Opens System Settings directly to the Screen Recording privacy pane.
    @discardableResult
    public static func openScreenRecordingSettings() -> Bool {
        NSWorkspace.shared.open(screenRecordingSettingsURL)
    }

    /// Opens System Settings directly to the Accessibility privacy pane.
    @discardableResult
    public static func openAccessibilitySettings() -> Bool {
        NSWorkspace.shared.open(accessibilitySettingsURL)
    }
}

/// Concrete implementation of `PermissionsServiceProtocol` wrapping `SystemPermissions`.
public final class SystemPermissionsService: PermissionsServiceProtocol, Sendable {
    public static let shared = SystemPermissionsService()

    public init() {}

    public func checkScreenRecordingPermission() -> Bool {
        SystemPermissions.checkScreenRecordingPermission()
    }

    public func checkAccessibilityPermission() -> Bool {
        SystemPermissions.checkAccessibilityPermission()
    }

    public func requestScreenRecordingPermission() -> Bool {
        SystemPermissions.requestScreenRecordingPermission()
    }

    public func requestAccessibilityPermission() -> Bool {
        SystemPermissions.requestAccessibilityPermission()
    }

    public func openScreenRecordingSettings() -> Bool {
        SystemPermissions.openScreenRecordingSettings()
    }

    public func openAccessibilitySettings() -> Bool {
        SystemPermissions.openAccessibilitySettings()
    }
}
