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
    /// 0 when the app was only listed (`listInstalledApps`): measuring every app would read all of /Applications.
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
    /// The entry carries the app's display name, not its bundle identifier. A name is weaker proof of ownership
    /// (two products can share one), so the uninstaller's list leaves these unticked.
    public let matchedByName: Bool

    public init(
        id: String = UUID().uuidString,
        name: String,
        path: String,
        kind: AppLeftoverKind,
        sizeBytes: Int64,
        matchedByName: Bool = false
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.kind = kind
        self.sizeBytes = sizeBytes
        self.matchedByName = matchedByName
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

/// Why an app is not offered for uninstalling.
public enum UninstallRefusal: Error, Equatable, Sendable {
    /// Not a folder ending in `.app`.
    case notAnApp
    /// Lives in a system location or is one of Apple's own apps.
    case partOfMacOS
    /// Zenith does not remove itself.
    case isZenith
    /// The bundle sits inside another app (a helper, a login item).
    case insideAnotherApp
    /// No Info.plist with a usable bundle identifier, so nothing can be tied to it safely.
    case unreadable
}

/// How the uninstaller finds out that an app is open, and asks it to quit. Tests pass a fake.
public struct RunningAppControl: Sendable {
    public let isRunning: @Sendable (_ bundleIdentifier: String, _ bundlePath: String) -> Bool
    public let requestQuit: @Sendable (_ bundleIdentifier: String, _ bundlePath: String) -> Void

    public init(
        isRunning: @escaping @Sendable (_ bundleIdentifier: String, _ bundlePath: String) -> Bool,
        requestQuit: @escaping @Sendable (_ bundleIdentifier: String, _ bundlePath: String) -> Void
    ) {
        self.isRunning = isRunning
        self.requestQuit = requestQuit
    }

    /// The copies of this app that are running from this very bundle (a second copy elsewhere is left alone).
    private static func instances(_ bundleIdentifier: String, _ bundlePath: String) -> [NSRunningApplication] {
        guard !bundleIdentifier.isEmpty else { return [] }
        let wanted = URL(fileURLWithPath: bundlePath).resolvingSymlinksInPath().path
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).filter {
            guard let url = $0.bundleURL else { return true }
            return url.resolvingSymlinksInPath().path == wanted
        }
    }

    public static let system = RunningAppControl(
        isRunning: { identifier, path in !instances(identifier, path).isEmpty },
        // `terminate()` is the polite quit: the app may still ask about unsaved documents.
        requestQuit: { identifier, path in instances(identifier, path).forEach { $0.terminate() } }
    )
}

/// Service providing deep application analysis, leftover artifact discovery,
/// and safe uninstallation for Zenith.
///
/// What it will remove is deliberately narrow:
///   - never an app in a system location, one of Apple's (`com.apple.*`), or Zenith itself;
///   - leftovers only as direct children of the usual `~/Library` folders, named after the app's bundle identifier
///     (or, flagged `matchedByName`, its display name), and never anything macOS owns (`isSafeLeftoverPath`);
///   - `uninstall` looks the leftovers up again, so a stale or hand-made list cannot reach anything else;
///   - the app goes first: if macOS refuses to move it, nothing else is touched.
public final class AppUninstallerService: @unchecked Sendable {
    public static let shared = AppUninstallerService()

    private let fileManager: FileManager
    private let homeDirectory: String
    private let applicationDirectories: [String]
    private let ownBundleIdentifier: String?
    private let ownBundlePath: String?
    private let trashMover: TrashMover
    private let runCommand: SystemCommandRunner
    private let runningApps: RunningAppControl
    private let quitTimeout: TimeInterval
    private let recordHistory: @Sendable (_ operation: String, _ bytes: Int64, _ items: Int) -> Void

    /// - Parameters:
    ///   - homeDirectory: Whose `Library` holds the leftovers; tests pass a throwaway one.
    ///   - applicationDirectories: Where installed apps are listed from (default `/Applications` and `~/Applications`).
    ///   - ownBundleIdentifier, ownBundlePath: The running app, which is never offered.
    ///   - trashMover: How an item reaches the Trash (retried through Finder where macOS refuses the app).
    ///   - runCommand: Runs `launchctl` for the app's launch agents.
    ///   - runningApps: Whether the app is open, and asking it to quit.
    ///   - quitTimeout: How long an open app gets to quit before the uninstall gives up without removing anything.
    ///   - recordHistory: Where a finished uninstall is noted (the Command Hub's "freed so far").
    public init(
        fileManager: FileManager = .default,
        homeDirectory: String = NSHomeDirectory(),
        applicationDirectories: [String]? = nil,
        ownBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        ownBundlePath: String? = Bundle.main.bundlePath,
        trashMover: TrashMover = .system,
        runCommand: @escaping SystemCommandRunner = SystemCommand.processRunner,
        runningApps: RunningAppControl = .system,
        quitTimeout: TimeInterval = 5,
        recordHistory: @escaping @Sendable (_ operation: String, _ bytes: Int64, _ items: Int) -> Void = { operation, bytes, items in
            SystemCleaningHistoryTracker.shared.record(operationName: operation, bytesFreed: bytes, itemCount: items)
        }
    ) {
        self.fileManager = fileManager
        self.homeDirectory = (homeDirectory as NSString).standardizingPath
        self.applicationDirectories = applicationDirectories ?? ["/Applications", "\(homeDirectory)/Applications"]
        self.ownBundleIdentifier = ownBundleIdentifier
        self.ownBundlePath = ownBundlePath
        self.trashMover = trashMover
        self.runCommand = runCommand
        self.runningApps = runningApps
        self.quitTimeout = quitTimeout
        self.recordHistory = recordHistory
    }

    // MARK: - App Scanning

    /// The apps that can be uninstalled, by name, without their sizes (see `InstalledAppInfo.appSizeBytes`).
    /// Looks in `applicationDirectories` and in plain folders one level down (`/Applications/Setapp/…`).
    public func listInstalledApps() -> [InstalledAppInfo] {
        var apps: [InstalledAppInfo] = []
        var seen = Set<String>()
        for directory in applicationDirectories {
            collectApps(in: directory, depth: 0, seen: &seen, into: &apps)
        }
        return apps.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func collectApps(in directory: String, depth: Int, seen: inout Set<String>, into apps: inout [InstalledAppInfo]) {
        guard let contents = try? fileManager.contentsOfDirectory(atPath: directory) else { return }
        for name in contents where !name.hasPrefix(".") {
            let path = "\(directory)/\(name)"
            guard !isSymbolicLink(path) else { continue }
            if name.lowercased().hasSuffix(".app") {
                guard seen.insert((path as NSString).standardizingPath).inserted,
                      case .success(let info) = eligibility(ofAppAt: path, measuringSize: false) else { continue }
                apps.append(info)
            } else if depth < 1 {
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                collectApps(in: path, depth: depth + 1, seen: &seen, into: &apps)
            }
        }
    }

    /// Whether the app at `path` may be uninstalled, and if so what it is.
    public func eligibility(ofAppAt path: String, measuringSize: Bool = true) -> Result<InstalledAppInfo, UninstallRefusal> {
        let canonical = (path as NSString).standardizingPath
        var isDirectory: ObjCBool = false
        guard canonical.lowercased().hasSuffix(".app"),
              fileManager.fileExists(atPath: canonical, isDirectory: &isDirectory), isDirectory.boolValue,
              !isSymbolicLink(canonical) else { return .failure(.notAnApp) }

        // A bundle inside another bundle is that app's helper: removing it breaks the outer app.
        let parents = (canonical as NSString).deletingLastPathComponent.lowercased()
        guard !parents.split(separator: "/").contains(where: { $0.hasSuffix(".app") }) else { return .failure(.insideAnotherApp) }

        guard !isSystemPath(canonical) else { return .failure(.partOfMacOS) }
        guard let info = readAppInfo(atPath: canonical, measuringSize: false),
              Self.isUsableBundleIdentifier(info.bundleIdentifier) else { return .failure(.unreadable) }
        guard !isProtectedAppleBundle(info.bundleIdentifier) else { return .failure(.partOfMacOS) }
        guard !isZenith(bundleIdentifier: info.bundleIdentifier, path: canonical) else { return .failure(.isZenith) }

        guard measuringSize else { return .success(info) }
        return .success(InstalledAppInfo(
            bundlePath: info.bundlePath,
            bundleIdentifier: info.bundleIdentifier,
            displayName: info.displayName,
            version: info.version,
            appSizeBytes: calculateSize(of: canonical),
            isSystemApp: false
        ))
    }

    /// Scans standard application directories (/Applications and ~/Applications)
    /// and returns metadata, with sizes, for user-uninstallable apps.
    public func scanInstalledApps(customDirectory: String? = nil) -> [InstalledAppInfo] {
        let dirsToScan = customDirectory.map { [$0] } ?? applicationDirectories

        var apps: [InstalledAppInfo] = []
        for dir in dirsToScan {
            guard let contents = try? fileManager.contentsOfDirectory(atPath: dir) else { continue }
            for item in contents where item.hasSuffix(".app") {
                let fullPath = "\(dir)/\(item)"
                if let info = parseAppInfo(atPath: fullPath), !info.isSystemApp {
                    apps.append(info)
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
        if let info = readAppInfo(atPath: path, measuringSize: true) { return info }

        // Fallback for simple/un-bundled test folders
        let fallbackName = (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
        return InstalledAppInfo(
            bundlePath: path,
            bundleIdentifier: "com.unknown.\(fallbackName.lowercased())",
            displayName: fallbackName,
            version: "1.0",
            appSizeBytes: calculateSize(of: path),
            isSystemApp: isSystemPath(path)
        )
    }

    /// What the bundle's Info.plist says, or `nil` when there is none to read.
    private func readAppInfo(atPath path: String, measuringSize: Bool) -> InstalledAppInfo? {
        let plistPath = "\(path)/Contents/Info.plist"
        guard let plistData = try? Data(contentsOf: URL(fileURLWithPath: plistPath)),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
            return nil
        }

        let fileName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let bundleId = (plist["CFBundleIdentifier"] as? String) ?? ""
        let name = [plist["CFBundleDisplayName"] as? String, plist["CFBundleName"] as? String]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? fileName
        let version = (plist["CFBundleShortVersionString"] as? String)
            ?? (plist["CFBundleVersion"] as? String)
            ?? "1.0"

        return InstalledAppInfo(
            bundlePath: path,
            bundleIdentifier: bundleId,
            displayName: name,
            version: version,
            appSizeBytes: measuringSize ? calculateSize(of: path) : 0,
            isSystemApp: isSystemPath(path) || isProtectedAppleBundle(bundleId)
        )
    }

    // MARK: - Leftover Artifact Discovery

    /// Analyzes an application bundle and scans all standard user Library folders
    /// for associated state, caches, preferences, containers, and daemons.
    public func analyzeApp(atPath path: String, homeDirectory: String? = nil) -> AppUninstallPlan? {
        guard let appInfo = parseAppInfo(atPath: path) else { return nil }
        let leftovers = scanLeftovers(for: appInfo, home: homeDirectory ?? self.homeDirectory)
        return AppUninstallPlan(app: appInfo, leftovers: leftovers)
    }

    /// Discovers all leftover files and folders matching the app name or bundle identifier, with their sizes.
    public func scanLeftovers(for app: InstalledAppInfo, home: String? = nil) -> [AppLeftoverItem] {
        leftoverCandidates(for: app, home: home ?? homeDirectory).map {
            AppLeftoverItem(
                name: $0.name,
                path: $0.path,
                kind: $0.kind,
                sizeBytes: calculateSize(of: $0.path),
                matchedByName: $0.matchedByName
            )
        }
    }

    private struct LeftoverCandidate {
        let name: String
        let path: String
        let kind: AppLeftoverKind
        let matchedByName: Bool
    }

    /// Where this app's leftovers are, without measuring them. Every candidate is a direct child of one of the
    /// folders below and passes `isSafeLeftoverPath`, so the list is exactly what an uninstall may remove.
    private func leftoverCandidates(for app: InstalledAppInfo, home rawHome: String) -> [LeftoverCandidate] {
        let home = (rawHome as NSString).standardizingPath
        let library = "\(home)/Library"
        // A name taken from an Info.plist is untrusted: "../Fonts" must not walk out of the folder it is looked up in.
        let trimmedId = app.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundleId = Self.isUsableBundleIdentifier(trimmedId) ? trimmedId : ""
        let trimmedName = app.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let appName = Self.isUsableEntryName(trimmedName) ? trimmedName : ""

        var found: [LeftoverCandidate] = []
        var seen = Set<String>()

        func add(_ name: String, in base: String, kind: AppLeftoverKind, byName: Bool = false) {
            let path = "\(base)/\(name)"
            let canonical = (path as NSString).standardizingPath
            guard (canonical as NSString).deletingLastPathComponent == (base as NSString).standardizingPath,
                  fileManager.fileExists(atPath: path),
                  isSafeLeftoverPath(canonical, home: home),
                  seen.insert(canonical.lowercased()).inserted else { return }
            found.append(LeftoverCandidate(name: name, path: path, kind: kind, matchedByName: byName))
        }

        /// Entries of `base` whose name is the identifier, alone or as whole dot-separated components.
        func addEntries(in base: String, kind: AppLeftoverKind, where matches: (String) -> Bool) {
            guard !bundleId.isEmpty, let entries = try? fileManager.contentsOfDirectory(atPath: base) else { return }
            for entry in entries.sorted() where matches(entry) { add(entry, in: base, kind: kind) }
        }

        func addByIdentifierThenName(in base: String, kind: AppLeftoverKind) {
            if !bundleId.isEmpty { add(bundleId, in: base, kind: kind) }
            if !appName.isEmpty, appName.lowercased() != bundleId.lowercased() { add(appName, in: base, kind: kind, byName: true) }
        }

        addByIdentifierThenName(in: "\(library)/Application Support", kind: .appSupport)
        addByIdentifierThenName(in: "\(library)/Caches", kind: .caches)
        if !bundleId.isEmpty {
            add(bundleId, in: "\(library)/Containers", kind: .sandboxContainers)
        }
        // Shared containers: by bundle identifier only. A display name ("Notes", "Mail") is too common a word to
        // decide that a shared container belongs to this app.
        addEntries(in: "\(library)/Group Containers", kind: .groupContainers) {
            Self.entryName($0, containsIdentifier: bundleId)
        }
        if !bundleId.isEmpty {
            add("\(bundleId).plist", in: "\(library)/Preferences", kind: .preferences)
        }
        addEntries(in: "\(library)/Preferences/ByHost", kind: .preferences) {
            Self.entryName($0, startsWithIdentifier: bundleId)
        }
        if !bundleId.isEmpty {
            add("\(bundleId).savedState", in: "\(library)/Saved Application State", kind: .savedState)
            add(bundleId, in: "\(library)/WebKit", kind: .webKit)
            add(bundleId, in: "\(library)/HTTPStorages", kind: .httpStorages)
        }
        addByIdentifierThenName(in: "\(library)/Logs", kind: .logs)
        // Agents are unloaded and removed, so only those named after the app's bundle identifier qualify.
        addEntries(in: "\(library)/LaunchAgents", kind: .launchAgents) {
            $0.hasSuffix(".plist") && Self.entryName($0, startsWithIdentifier: bundleId)
        }
        return found
    }

    // MARK: - Uninstallation Execution

    /// True while a copy of this app is running from this bundle.
    public func isAppRunning(_ app: InstalledAppInfo) -> Bool {
        runningApps.isRunning(app.bundleIdentifier, app.bundlePath)
    }

    /// Executes the uninstallation plan: asks the app to quit, moves the app to the Trash, unloads its launch agents
    /// and moves the chosen leftovers to the Trash (or removes everything permanently when `moveToTrash` is false).
    ///
    /// - Parameters:
    ///   - selectedLeftovers: The leftovers to remove; `nil` means all of the plan's. Each one is looked up again and
    ///     skipped unless it is still a leftover of this app.
    ///   - includeApp: `false` keeps the app and removes only the leftovers.
    /// - Returns: The bytes removed.
    /// - Throws: Before anything is removed if the app is protected, does not quit, or cannot be moved;
    ///   `UninstallError.someFailed` afterwards if some leftovers stayed behind.
    @discardableResult
    public func uninstall(
        plan: AppUninstallPlan,
        selectedLeftovers: [AppLeftoverItem]? = nil,
        includeApp: Bool = true,
        moveToTrash: Bool = true
    ) throws -> Int64 {
        let app = plan.app
        // Safety guard: Reject protected system or Apple apps
        if isSystemPath(app.bundlePath) || isProtectedAppleBundle(app.bundleIdentifier) {
            throw UninstallError.protectedSystemApplication
        }
        if isZenith(bundleIdentifier: app.bundleIdentifier, path: app.bundlePath) {
            throw UninstallError.cannotUninstallZenith
        }

        // 1. An open app keeps writing to the very files that are about to go: it has to quit first.
        try quitIfRunning(app)

        var totalFreed: Int64 = 0
        var removedCount = 0

        // 2. The app itself. If macOS refuses, stop here with everything else still in place.
        if includeApp, fileManager.fileExists(atPath: app.bundlePath) {
            try removeFile(atPath: app.bundlePath, moveToTrash: moveToTrash)
            totalFreed += app.appSizeBytes
            removedCount += 1
        }

        // 3. Leftovers: only what a fresh look still ties to this app.
        let stillLeftovers = Set(leftoverCandidates(for: app, home: homeDirectory).map { ($0.path as NSString).standardizingPath })
        let chosen = (selectedLeftovers ?? plan.leftovers).filter {
            stillLeftovers.contains(($0.path as NSString).standardizingPath)
        }
        for item in chosen where item.kind == .launchAgents {
            unloadLaunchAgent(atPath: item.path)
        }

        var failures: [(name: String, reason: String)] = []
        for item in chosen {
            do {
                try removeFile(atPath: item.path, moveToTrash: moveToTrash)
                totalFreed += item.sizeBytes
                removedCount += 1
            } catch {
                failures.append((name: item.name, reason: error.localizedDescription))
            }
        }

        if removedCount > 0 {
            recordHistory("App Uninstallation (\(app.displayName))", totalFreed, removedCount)
        }
        if let first = failures.first {
            throw UninstallError.someFailed(names: failures.map(\.name), firstReason: first.reason)
        }
        return totalFreed
    }

    /// Asks an open app to quit and waits for it. Throws, with nothing removed, if it is still open afterwards
    /// (it may be asking about unsaved documents).
    private func quitIfRunning(_ app: InstalledAppInfo) throws {
        guard runningApps.isRunning(app.bundleIdentifier, app.bundlePath) else { return }
        runningApps.requestQuit(app.bundleIdentifier, app.bundlePath)
        let deadline = Date().addingTimeInterval(quitTimeout)
        while runningApps.isRunning(app.bundleIdentifier, app.bundlePath) {
            guard Date() < deadline else { throw UninstallError.appStillRunning(app.displayName) }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    // MARK: - File Removal (Clean Code F3, G30)

    private func removeFile(atPath path: String, moveToTrash: Bool) throws {
        let url = URL(fileURLWithPath: path)
        if moveToTrash {
            try trashMover.move(url)
        } else {
            try fileManager.removeItem(at: url)
        }
    }

    private func unloadLaunchAgent(atPath path: String) {
        _ = runCommand("/bin/launchctl", ["bootout", "gui/\(getuid())", path])
    }

    // MARK: - Safety Validations

    public func isProtectedAppleBundle(_ bundleId: String) -> Bool {
        // System Apple apps cannot be uninstalled
        bundleId.lowercased().hasPrefix("com.apple.")
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

    private func isZenith(bundleIdentifier: String, path: String) -> Bool {
        if let own = ownBundleIdentifier, !own.isEmpty, own.lowercased() == bundleIdentifier.lowercased() { return true }
        if let own = ownBundlePath, !own.isEmpty {
            return URL(fileURLWithPath: own).resolvingSymlinksInPath().path == URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        }
        return false
    }

    public func isSafeLeftoverPath(_ path: String) -> Bool {
        isSafeLeftoverPath(path, home: homeDirectory)
    }

    private func isSafeLeftoverPath(_ path: String, home rawHome: String) -> Bool {
        let canonical = (path as NSString).standardizingPath
        let home = (rawHome as NSString).standardizingPath
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

    // MARK: - Matching names

    /// A name that can be looked up as one entry of a folder: no path separators, not hidden, not `.`/`..`.
    static func isUsableEntryName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains(":") && !name.contains("\0")
    }

    /// A bundle identifier worth matching files against: letters, digits, `-`, `_`, and at least two dot-separated
    /// parts. A one-word identifier would claim any folder of that name.
    static func isUsableBundleIdentifier(_ identifier: String) -> Bool {
        let parts = identifier.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return parts.allSatisfy { part in !part.isEmpty && part.unicodeScalars.allSatisfy { allowed.contains($0) } }
    }

    /// `com.acme.app.plist` and `com.acme.app.helper.plist` start with `com.acme.app`; `com.acme.apple.plist` does not.
    static func entryName(_ entry: String, startsWithIdentifier identifier: String) -> Bool {
        guard !identifier.isEmpty else { return false }
        let entry = entry.lowercased(), identifier = identifier.lowercased()
        return entry == identifier || entry.hasPrefix(identifier + ".")
    }

    /// `group.com.acme.app` and `TEAMID.com.acme.app.shared` contain `com.acme.app` as whole components.
    static func entryName(_ entry: String, containsIdentifier identifier: String) -> Bool {
        guard !identifier.isEmpty else { return false }
        let entry = entry.lowercased(), identifier = identifier.lowercased()
        return entry == identifier
            || entry.hasPrefix(identifier + ".")
            || entry.hasSuffix("." + identifier)
            || entry.contains("." + identifier + ".")
    }

    // MARK: - Helpers

    private func isSymbolicLink(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }

    /// Everything a removal takes with it: hidden files and the inside of bundles count, symbolic links do not.
    public func calculateSize(of path: String) -> Int64 {
        SystemCleanerService.calculateSize(of: path, fileManager: fileManager)
    }
}

public enum UninstallError: Error, LocalizedError, Equatable {
    case protectedSystemApplication
    case cannotUninstallZenith
    case appNotFound
    case failedToDelete(String)
    /// The app was asked to quit and is still open. Nothing was removed.
    case appStillRunning(String)
    /// The rest is in the Trash; these stayed where they were.
    case someFailed(names: [String], firstReason: String)

    public var errorDescription: String? {
        switch self {
        case .protectedSystemApplication:
            return String(localized: "Apps that are part of macOS or made by Apple can't be uninstalled here.")
        case .cannotUninstallZenith:
            return String(localized: "Zenith can't uninstall itself. Quit it and move it to the Trash in Finder.")
        case .appNotFound:
            return "Application bundle could not be found at the specified path."
        case .failedToDelete(let path):
            return "Failed to remove artifact at \(path)."
        case .appStillRunning(let name):
            return String(localized: "\(name) is still open, so nothing was removed. Quit it, then try again.")
        case .someFailed(let names, let reason):
            let listed = names.prefix(3).joined(separator: ", ")
            return names.count == 1
                ? String(localized: "1 item could not be moved: \(listed). \(reason)")
                : String(localized: "\(names.count) items could not be moved: \(listed). \(reason)")
        }
    }
}
