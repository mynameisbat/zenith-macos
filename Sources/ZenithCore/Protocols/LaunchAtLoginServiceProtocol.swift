import Foundation

/// Normalized status enumeration for login item registration.
public enum LaunchAtLoginStatus: String, Sendable, Equatable, Hashable, Codable {
    case enabled
    case notRegistered
    case requiresApproval
    case notFound
}

/// Errors thrown by launch-at-login operations.
public enum LaunchAtLoginError: Error, LocalizedError, Sendable, Equatable {
    case requiresApproval
    case notFound
    case systemError(String)
    case registrationFailed(String)
    case unsupportedOS

    public var errorDescription: String? {
        switch self {
        case .requiresApproval:
            return "Zenith requires user approval in macOS System Settings > Login Items to launch at login."
        case .notFound:
            return "Application bundle could not be found for login item registration."
        case .systemError(let message):
            return "Failed to update launch at login status: \(message)"
        case .registrationFailed(let message):
            return "Registration failed: \(message)"
        case .unsupportedOS:
            return "SMAppService is only supported on macOS 13 or later"
        }
    }
}

/// Protocol abstracting system login item registration and status checking.
public protocol LaunchAtLoginServiceProtocol: Sendable {
    /// Whether the application is currently registered to launch at login.
    var isEnabled: Bool { get }

    /// Detailed status of the login service (enabled, requiresApproval, notRegistered, notFound).
    var status: LaunchAtLoginStatus { get }

    /// Registers the application to launch automatically at login.
    func enable() throws

    /// Unregisters the application from launching at login.
    func disable() throws
}
