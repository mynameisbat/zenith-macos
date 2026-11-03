import Foundation
import AppKit

/// Category of leftover artifacts left behind by macOS applications.
public enum AppLeftoverKind: String, Sendable, CaseIterable, Equatable {
    case appSupport = "Application Support"
    case caches = "Caches"
    case sandboxContainers = "Containers"
    case groupContainers = "Group Containers"
    case preferences = "Preferences"
    case savedState = "Saved Application State"
    case launchAgents = "Launch Agents"
    case logs = "Logs"
    case webKit = "WebKit Data"
    case httpStorages = "HTTP Storages"

    public var systemIcon: String {
        switch self {
        case .appSupport: return "folder.fill"
        case .caches: return "archivebox.fill"
        case .sandboxContainers: return "shippingbox.fill"
        case .groupContainers: return "person.2.fill"
        case .preferences: return "gearshape.fill"
        case .savedState: return "macwindow.on.rectangle"
        case .launchAgents: return "bolt.badge.clock.fill"
        case .logs: return "doc.text.fill"
        case .webKit: return "safari.fill"
        case .httpStorages: return "network"
        }
    }
}

/// Metadata representation of an installed application bundle.
public struct InstalledAppInfo: Identifiable, Sendable, Equatable {
    public let id: String
    public let bundlePath: String
    public let bundleIdentifier: String
    public let displayName: String
    public let version: String
    public let appSizeBytes: Int64
    public let isSystemApp: Bool

    public init(
        id: String? = nil,
        bundlePath: String,
        bundleIdentifier: String,
        displayName: String,
        version: String,
        appSizeBytes: Int64,
        isSystemApp: Bool = false
    ) {
        self.id = id ?? bundleIdentifier
        self.bundlePath = bundlePath
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.version = version
        self.appSizeBytes = appSizeBytes
        self.isSystemApp = isSystemApp
    }
}

/// Concrete leftover file or folder item associated with an application.
public struct AppLeftoverItem: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let path: String
    public let kind: AppLeftoverKind
    public let sizeBytes: Int64

    public init(
        id: String = UUID().uuidString,
        name: String,
        path: String,
        kind: AppLeftoverKind,
        sizeBytes: Int64
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.kind = kind
        self.sizeBytes = sizeBytes
    }
}

/// A comprehensive plan representing an application and all its discoverable disk artifacts.
public struct AppUninstallPlan: Identifiable, Sendable, Equatable {
    public let id: String
    public let app: InstalledAppInfo
    public var leftovers: [AppLeftoverItem]

    public var totalReclaimableBytes: Int64 {
        app.appSizeBytes + leftovers.reduce(0) { $0 + $1.sizeBytes }
    }

    public init(app: InstalledAppInfo, leftovers: [AppLeftoverItem]) {
        self.id = app.bundleIdentifier.isEmpty ? app.bundlePath : app.bundleIdentifier
        self.app = app
        self.leftovers = leftovers
    }
}

/// Service providing deep application analysis, leftover artifact discovery,
/// and safe uninstallation for Zenith.
public final class AppUninstallerService: @unchecked Sendable {
    public static let shared = AppUninstallerService()

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    // MARK: - App Scanning

    /// Scans standard application directories (/Applications and ~/Applications)
    /// and returns metadata for user-uninstallable apps.
    public func scanInstalledApps(customDirectory: String? = nil) -> [InstalledAppInfo] {
        let home = NSHomeDirectory()
        let dirsToScan: [String]
        if let custom = customDirectory {
            dirsToScan = [custom]
        } else {
            dirsToScan = ["/Applications", "\(home)/Applications"]
        }

        var apps: [InstalledAppInfo] = []
        for dir in dirsToScan {
            guard let contents = try? fileManager.contentsOfDirectory(atPath: dir) else { continue }
            for item in contents where item.hasSuffix(".app") {
                let fullPath = "\(dir)/\(item)"
                if let info = parseAppInfo(atPath: fullPath) {
                    // Filter out protected system apps unless explicitly in test environment
                    if !info.isSystemApp {
                        apps.append(info)
                    }
                }
            }
        }
        return apps.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Parses an application bundle Info.plist to extract name, bundle ID, version, and size.
    public func parseAppInfo(atPath path: String) -> InstalledAppInfo? {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }

        let plistPath = "\(path)/Contents/Info.plist"
        guard let plistData = try? Data(contentsOf: URL(fileURLWithPath: plistPath)),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
            // Fallback for simple/un-bundled test folders
            let fallbackName = (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
            let size = calculateSize(of: path)
            return InstalledAppInfo(
                bundlePath: path,
                bundleIdentifier: "com.unknown.\(fallbackName.lowercased())",
                displayName: fallbackName,
                version: "1.0",
                appSizeBytes: size,
                isSystemApp: isSystemPath(path)
            )
        }

        let bundleId = (plist["CFBundleIdentifier"] as? String) ?? ""
        let name = (plist["CFBundleDisplayName"] as? String)
            ?? (plist["CFBundleName"] as? String)
            ?? ((path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: ""))
        let version = (plist["CFBundleShortVersionString"] as? String)
            ?? (plist["CFBundleVersion"] as? String)
            ?? "1.0"
        let size = calculateSize(of: path)
        let isSystem = isSystemPath(path) || isProtectedAppleBundle(bundleId)

        return InstalledAppInfo(
            bundlePath: path,
            bundleIdentifier: bundleId,
            displayName: name,
            version: version,
            appSizeBytes: size,
            isSystemApp: isSystem
        )
    }

    // MARK: - Leftover Artifact Discovery

    /// Analyzes an application bundle and scans all standard user Library folders
    /// for associated state, caches, preferences, containers, and daemons.
    public func analyzeApp(atPath path: String, homeDirectory: String? = nil) -> AppUninstallPlan? {
        guard let appInfo = parseAppInfo(atPath: path) else { return nil }
        let home = homeDirectory ?? NSHomeDirectory()
        let leftovers = scanLeftovers(for: appInfo, home: home)
        return AppUninstallPlan(app: appInfo, leftovers: leftovers)
    }

    /// Discovers all leftover files and folders matching the app name or bundle identifier.
    public func scanLeftovers(for app: InstalledAppInfo, home: String) -> [AppLeftoverItem] {
        let bundleId = app.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let appName = app.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        var items: [AppLeftoverItem] = []

        // 1. Application Support (~/Library/Application Support/<Name> or <BundleID>)
        let appSupport = "\(home)/Library/Application Support"
        checkDirectoryCandidates(base: appSupport, kind: .appSupport, names: [appName, bundleId], items: &items)

        // 2. Caches (~/Library/Caches/<BundleID> or <Name>)
        let caches = "\(home)/Library/Caches"
        checkDirectoryCandidates(base: caches, kind: .caches, names: [bundleId, appName], items: &items)

        // 3. Sandboxed Containers (~/Library/Containers/<BundleID>)
        if !bundleId.isEmpty {
            let containerPath = "\(home)/Library/Containers/\(bundleId)"
            if fileManager.fileExists(atPath: containerPath) {
                let size = calculateSize(of: containerPath)
                items.append(AppLeftoverItem(name: bundleId, path: containerPath, kind: .sandboxContainers, sizeBytes: size))
            }
        }

        // 4. Group Containers (~/Library/Group Containers/*.<BundleID>*)
        let groupContainers = "\(home)/Library/Group Containers"
        if fileManager.fileExists(atPath: groupContainers),
           let contents = try? fileManager.contentsOfDirectory(atPath: groupContainers) {
            for dirName in contents {
                // Matched by bundle identifier only: an app's display name ("Notes", "Mail") is too common a word
                // to decide that a shared container belongs to it.
                if !bundleId.isEmpty && dirName.localizedCaseInsensitiveContains(bundleId) {
                    let fullPath = "\(groupContainers)/\(dirName)"
                    let size = calculateSize(of: fullPath)
                    items.append(AppLeftoverItem(name: dirName, path: fullPath, kind: .groupContainers, sizeBytes: size))
                }
            }
        }

        // 5. Preferences (~/Library/Preferences/<BundleID>.plist)
        if !bundleId.isEmpty {
            let prefPath = "\(home)/Library/Preferences/\(bundleId).plist"
            if fileManager.fileExists(atPath: prefPath) {
                let size = calculateSize(of: prefPath)
                items.append(AppLeftoverItem(name: "\(bundleId).plist", path: prefPath, kind: .preferences, sizeBytes: size))
            }
            // ByHost Preferences
            let byHostDir = "\(home)/Library/Preferences/ByHost"
            if fileManager.fileExists(atPath: byHostDir),
               let byHostContents = try? fileManager.contentsOfDirectory(atPath: byHostDir) {
                for file in byHostContents where file.hasPrefix(bundleId) {
                    let p = "\(byHostDir)/\(file)"
                    items.append(AppLeftoverItem(name: file, path: p, kind: .preferences, sizeBytes: calculateSize(of: p)))
                }
            }
        }

        // 6. Saved Application State (~/Library/Saved Application State/<BundleID>.savedState)
        if !bundleId.isEmpty {
            let statePath = "\(home)/Library/Saved Application State/\(bundleId).savedState"
            if fileManager.fileExists(atPath: statePath) {
                items.append(AppLeftoverItem(name: "\(bundleId).savedState", path: statePath, kind: .savedState, sizeBytes: calculateSize(of: statePath)))
            }
        }

        // 7. WebKit (~/Library/WebKit/<BundleID>)
        if !bundleId.isEmpty {
            let webKitPath = "\(home)/Library/WebKit/\(bundleId)"
            if fileManager.fileExists(atPath: webKitPath) {
                items.append(AppLeftoverItem(name: bundleId, path: webKitPath, kind: .webKit, sizeBytes: calculateSize(of: webKitPath)))
            }
        }

        // 8. HTTPStorages (~/Library/HTTPStorages/<BundleID>)
        if !bundleId.isEmpty {
            let httpPath = "\(home)/Library/HTTPStorages/\(bundleId)"
            if fileManager.fileExists(atPath: httpPath) {
                items.append(AppLeftoverItem(name: bundleId, path: httpPath, kind: .httpStorages, sizeBytes: calculateSize(of: httpPath)))
            }
        }

        // 9. Logs (~/Library/Logs/<AppName> or <BundleID>)
        let logsDir = "\(home)/Library/Logs"
        checkDirectoryCandidates(base: logsDir, kind: .logs, names: [appName, bundleId], items: &items)

        // 10. Launch Agents (~/Library/LaunchAgents/<BundleID>*.plist)
        let userAgents = "\(home)/Library/LaunchAgents"
        checkLaunchAgentCandidates(base: userAgents, bundleId: bundleId, items: &items)

        return items
    }

    private func checkDirectoryCandidates(base: String, kind: AppLeftoverKind, names: [String], items: inout [AppLeftoverItem]) {
        for n in names where !n.isEmpty {
            let candidate = "\(base)/\(n)"
            if fileManager.fileExists(atPath: candidate) {
                // Avoid duplicates if appName == bundleId
                if !items.contains(where: { $0.path == candidate }) {
                    let s = calculateSize(of: candidate)
                    items.append(AppLeftoverItem(name: n, path: candidate, kind: kind, sizeBytes: s))
                }
            }
        }
    }

    private func checkLaunchAgentCandidates(base: String, bundleId: String, items: inout [AppLeftoverItem]) {
        guard fileManager.fileExists(atPath: base),
              let files = try? fileManager.contentsOfDirectory(atPath: base) else { return }
        for f in files where f.hasSuffix(".plist") {
            // Agents are unloaded and deleted, so only those named after the app's bundle identifier qualify.
            if !bundleId.isEmpty && f.hasPrefix(bundleId) {
                let p = "\(base)/\(f)"
                if !items.contains(where: { $0.path == p }) {
                    items.append(AppLeftoverItem(name: f, path: p, kind: .launchAgents, sizeBytes: calculateSize(of: p)))
                }
            }
        }
    }

    // MARK: - Uninstallation Execution

    /// Executes the uninstallation plan: terminates running process, unloads launchd jobs,
    /// and either moves all artifacts to the macOS Trash or removes them permanently.
    @discardableResult
    public func uninstall(
        plan: AppUninstallPlan,
        selectedLeftovers: [AppLeftoverItem]? = nil,
        moveToTrash: Bool = true
    ) throws -> Int64 {
        // Safety guard: Reject protected system or Apple apps
        if isSystemPath(plan.app.bundlePath) || isProtectedAppleBundle(plan.app.bundleIdentifier) {
            throw UninstallError.protectedSystemApplication
        }

        // 1. Terminate running process if active
        terminateRunningApp(bundleIdentifier: plan.app.bundleIdentifier)

        let itemsToDelete = selectedLeftovers ?? plan.leftovers
        var totalFreed: Int64 = 0

        // 2. Unload & remove Launch Agents first
        for item in itemsToDelete where item.kind == .launchAgents {
            unloadLaunchAgent(atPath: item.path)
        }

        // 3. Remove/Trash leftover items
        for item in itemsToDelete {
            if isSafeLeftoverPath(item.path) {
                totalFreed += item.sizeBytes
                try removeFile(atPath: item.path, moveToTrash: moveToTrash)
            }
        }

        // 4. Remove/Trash the main .app bundle
        if fileManager.fileExists(atPath: plan.app.bundlePath) {
            totalFreed += plan.app.appSizeBytes
            try removeFile(atPath: plan.app.bundlePath, moveToTrash: moveToTrash)
        }

        if totalFreed > 0 {
            SystemCleaningHistoryTracker.shared.record(
                operationName: "App Uninstallation (\(plan.app.displayName))",
                bytesFreed: totalFreed,
                itemCount: itemsToDelete.count + 1
            )
        }

        return totalFreed
    }

    // MARK: - File Removal (Clean Code F3, G30)

    private func removeFile(atPath path: String, moveToTrash: Bool) throws {
        if moveToTrash {
            try sendToTrash(atPath: path)
        } else {
            try deletePermanently(atPath: path)
        }
    }

    private func sendToTrash(atPath path: String) throws {
        let url = URL(fileURLWithPath: path)
        try fileManager.trashItem(at: url, resultingItemURL: nil)
    }

    private func deletePermanently(atPath path: String) throws {
        let url = URL(fileURLWithPath: path)
        try fileManager.removeItem(at: url)
    }

    private func terminateRunningApp(bundleIdentifier: String) {
        guard !bundleIdentifier.isEmpty else { return }
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        for app in runningApps {
            app.terminate()
        }
    }

    private func unloadLaunchAgent(atPath path: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = ["bootout", "gui/\(getuid())", path]
        try? proc.run()
        proc.waitUntilExit()
    }

    // MARK: - Safety Validations

    public func isProtectedAppleBundle(_ bundleId: String) -> Bool {
        let lower = bundleId.lowercased()
        guard lower.hasPrefix("com.apple.") else { return false }
        // System Apple apps cannot be uninstalled
        return true
    }

    public func isSystemPath(_ path: String) -> Bool {
        let canonical = (path as NSString).standardizingPath
        if canonical.hasPrefix("/System") ||
           canonical.hasPrefix("/usr") ||
           canonical.hasPrefix("/bin") ||
           canonical.hasPrefix("/sbin") ||
           canonical == "/Applications" ||
           canonical == "/Library" {
            return true
        }
        return false
    }

    public func isSafeLeftoverPath(_ path: String) -> Bool {
        let canonical = (path as NSString).standardizingPath
        let home = (NSHomeDirectory() as NSString).standardizingPath
        // Leftovers must reside inside user's ~/Library
        guard canonical.hasPrefix("\(home)/Library/") else {
            return false
        }
        if isAppleOwnedLeftover(canonical, home: home) {
            return false
        }
        // Protect critical user root directories
        let prohibitedRoots = [
            "\(home)/Library",
            "\(home)/Library/Preferences",
            "\(home)/Library/Application Support",
            "\(home)/Library/Caches",
            "\(home)/Library/Containers",
            "\(home)/Library/Group Containers",
            "\(home)/Library/Saved Application State"
        ]
        if prohibitedRoots.contains(canonical) {
            return false
        }

        // Apple Neural Engine (ANE) compiled model cache protection
        if canonical.contains("com.apple.e5rt.e5bundlecache") {
            return false
        }

        // Steam & Epic Games installed game libraries protection
        if canonical.contains("/Steam/steamapps") || canonical.contains("/Epic Games") {
            return false
        }

        return true
    }

    /// Names of Apple's own data folders that no third-party app's leftovers can legitimately be.
    private static let appleOwnedLeftoverNames: Set<String> = [
        "addressbook", "mail", "messages", "safari", "keychains", "calendars", "cloudstorage", "icloud", "mobile documents"
    ]

    /// True when `~/Library/<category>[/<name>[/…]]` is, or sits inside, something macOS itself owns:
    /// a folder like `Keychains` or `Mail` at either level, or any `com.apple.*` entry.
    private func isAppleOwnedLeftover(_ canonicalPath: String, home: String) -> Bool {
        let relative = canonicalPath.dropFirst(home.count + "/Library/".count)
        let parts = relative.split(separator: "/").map { $0.lowercased() }
        guard let category = parts.first else { return false }
        if Self.appleOwnedLeftoverNames.contains(category) { return true }
        guard parts.count >= 2 else { return false }
        let name = parts[1]
        return name.hasPrefix("com.apple.") || name.hasPrefix("group.com.apple.") || Self.appleOwnedLeftoverNames.contains(name)
    }

    // MARK: - Helpers

    public func calculateSize(of path: String) -> Int64 {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            let attrs = try? fileManager.attributesOfItem(atPath: path)
            return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        }
        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let vals = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) else { continue }
            total += Int64(vals.totalFileAllocatedSize ?? vals.fileSize ?? 0)
        }
        return total
    }
}

public enum UninstallError: Error, LocalizedError, Equatable {
    case protectedSystemApplication
    case appNotFound
    case failedToDelete(String)

    public var errorDescription: String? {
        switch self {
        case .protectedSystemApplication:
            return "Cannot uninstall protected macOS system applications or Apple internal components."
        case .appNotFound:
            return "Application bundle could not be found at the specified path."
        case .failedToDelete(let path):
            return "Failed to remove artifact at \(path)."
        }
    }
}
