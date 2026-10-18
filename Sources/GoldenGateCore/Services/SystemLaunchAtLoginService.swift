import Foundation
import ServiceManagement
import AppKit

/// Production implementation of LaunchAtLoginServiceProtocol using SMAppService (macOS 13+).
public final class SystemLaunchAtLoginService: LaunchAtLoginServiceProtocol, Sendable {
    public static let shared = SystemLaunchAtLoginService()

    public init() {}

    public var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public var status: LaunchAtLoginStatus {
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .notFound
        case .notRegistered:
            fallthrough
        @unknown default:
            return .notRegistered
        }
    }

    public func enable() throws {
        let service = SMAppService.mainApp
        do {
            try service.register()
            if service.status == .requiresApproval {
                throw LaunchAtLoginError.requiresApproval
            }
        } catch let error as LaunchAtLoginError {
            throw error
        } catch {
            if service.status == .requiresApproval {
                throw LaunchAtLoginError.requiresApproval
            } else if service.status == .notFound {
                throw LaunchAtLoginError.notFound
            } else {
                throw LaunchAtLoginError.systemError(error.localizedDescription)
            }
        }
    }

    public func disable() throws {
        let service = SMAppService.mainApp
        do {
            try service.unregister()
        } catch {
            throw LaunchAtLoginError.systemError(error.localizedDescription)
        }
    }

    /// Deep link to macOS System Settings -> General -> Login Items.
    public static func openLoginItemsSettings() {
        if #available(macOS 13.0, *) {
            SMAppService.openSystemSettingsLoginItems()
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
