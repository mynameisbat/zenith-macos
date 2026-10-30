import Foundation
import Combine
import Darwin

/// Individual cleanable file or directory item.
public struct JunkItem: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let path: String
    public let size: Int64
    public var isSelected: Bool

    public init(id: UUID = UUID(), name: String, path: String, size: Int64, isSelected: Bool = true) {
        self.id = id
        self.name = name
        self.path = path
        self.size = size
        self.isSelected = isSelected
    }

    public var formattedSize: String {
        SystemCleanerService.formatBytes(size)
    }
}

/// Category grouping related junk items (e.g. Xcode DerivedData, Application Caches, User Logs).
public struct JunkCategory: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let description: String
    public let icon: String
    public var items: [JunkItem]
    public var isSelected: Bool
    public var isExpanded: Bool

    public init(
        id: String,
        title: String,
        description: String,
        icon: String,
        items: [JunkItem] = [],
        isSelected: Bool = true,
        isExpanded: Bool = false
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.icon = icon
        self.items = items
        self.isSelected = isSelected
        self.isExpanded = isExpanded
    }

    public var totalSize: Int64 {
        items.reduce(0) { $0 + $1.size }
    }

    public var selectedSize: Int64 {
        items.filter(\.isSelected).reduce(0) { $0 + $1.size }
    }

    public var formattedTotalSize: String {
        SystemCleanerService.formatBytes(totalSize)
    }

    public var formattedSelectedSize: String {
        SystemCleanerService.formatBytes(selectedSize)
    }
}

/// System disk volume storage telemetry.
public struct DiskSpaceInfo: Sendable, Equatable {
    public let totalBytes: Int64
    public let freeBytes: Int64
    public let usedBytes: Int64

    public init(totalBytes: Int64, freeBytes: Int64, usedBytes: Int64) {
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.usedBytes = usedBytes
    }

    public var usedPercentage: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes)
    }

    public var formattedFree: String {
        SystemCleanerService.formatBytes(freeBytes)
    }

    public var formattedTotal: String {
        SystemCleanerService.formatBytes(totalBytes)
    }

    public var formattedUsed: String {
        SystemCleanerService.formatBytes(usedBytes)
    }
}

/// Service managing system junk scanning, disk space calculation, and safe cleanup operations.
@MainActor
public final class SystemCleanerService: ObservableObject {
    public static let shared = SystemCleanerService()

    @Published public var isScanning: Bool = false
    @Published public var isCleaning: Bool = false
    @Published public var showCleanConfirmation: Bool = false
    @Published public var categories: [JunkCategory] = []
    @Published public var diskInfo: DiskSpaceInfo? = nil
    @Published public var memoryTelemetry: SystemMemoryTelemetry? = nil
    @Published public var isOptimizingMemory: Bool = false
    @Published public var lastFreedBytes: Int64? = nil
    @Published public var statusMessage: String? = nil

    private let homeOverride: String?

    /// - Parameter homeDirectory: The home directory to scan and clean; the current user's when `nil`.
    public init(homeDirectory: String? = nil) {
        self.homeOverride = homeDirectory
        refreshDiskSpace()
        refreshMemoryTelemetry()
    }

    public var totalJunkSize: Int64 {
        categories.reduce(0) { $0 + $1.totalSize }
    }

    public var selectedJunkSize: Int64 {
        categories.reduce(0) { $0 + $1.selectedSize }
    }

    public var totalItemCount: Int {
        categories.reduce(0) { $0 + $1.items.count }
    }

    public var selectedItemCount: Int {
        categories.reduce(0) { $0 + $1.items.filter(\.isSelected).count }
    }

    public var formattedTotalJunkSize: String {
        Self.formatBytes(totalJunkSize)
    }

    public var formattedSelectedJunkSize: String {
        Self.formatBytes(selectedJunkSize)
    }

    public var formatSelectedSize: String {
        Self.formatBytes(selectedJunkSize)
    }

    /// What a clean would permanently delete, category by category, for confirmation dialogs.
    public var selectionSummary: String {
        categories
            .filter { $0.selectedSize > 0 }
            .map { "• \($0.title) — \(Self.formatBytes($0.selectedSize))" }
            .joined(separator: "\n")
    }

    // MARK: - Disk Space Telemetry

    public func refreshDiskSpace() {
        if let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) {
            let total = Int64(values.volumeTotalCapacity ?? 0)
            let free = values.volumeAvailableCapacityForImportantUsage ?? 0
            let used = max(0, total - free)
            self.diskInfo = DiskSpaceInfo(totalBytes: total, freeBytes: free, usedBytes: used)
        }
    }

    // MARK: - Memory Telemetry & Optimization

    public func refreshMemoryTelemetry() {
        self.memoryTelemetry = SystemMemoryTelemetry.current()
    }

    // MARK: - Scanning Logic

    public func scan() async {
        guard !isScanning && !isCleaning else { return }
        isScanning = true
        statusMessage = "Analyzing system storage..."

        refreshDiskSpace()

        let homeOverride = self.homeOverride
        let scannedCategories = await Task.detached(priority: .userInitiated) { () -> [JunkCategory] in
            let fm = FileManager.default
            let home = homeOverride ?? fm.homeDirectoryForCurrentUser.path
            var result: [JunkCategory] = []

            // 1. Browser Caches (Chrome, Arc, Brave, Edge, Firefox - cache directories only, preserving cookies & history)
            var browserItems: [JunkItem] = []
            let browserPaths: [(String, String)] = [
                ("Google Chrome Cache", "\(home)/Library/Caches/Google/Chrome"),
                ("Arc Browser Cache", "\(home)/Library/Caches/company.thebrowser.Browser"),
                ("Brave Browser Cache", "\(home)/Library/Caches/BraveSoftware/Brave-Browser"),
                ("Microsoft Edge Cache", "\(home)/Library/Caches/Microsoft Edge"),
                ("Firefox Cache", "\(home)/Library/Caches/Firefox"),
                ("Firefox Profile Cache", "\(home)/Library/Caches/org.mozilla.firefox")
            ]
            for (label, p) in browserPaths {
                if fm.fileExists(atPath: p) {
                    let s = Self.calculateSize(of: p, fileManager: fm)
                    if s > 1024 {
                        browserItems.append(JunkItem(name: label, path: p, size: s))
                    }
                }
            }
            if !browserItems.isEmpty {
                result.append(JunkCategory(
                    id: "browser_caches",
                    title: "Browser Caches",
                    description: "Temporary web data and media caches (Chrome, Arc, Brave, Edge, Firefox). Logins and history are strictly preserved.",
                    icon: "network",
                    items: browserItems
                ))
            }

            // 2. Xcode DerivedData & Simulators
            let derivedDataPath = "\(home)/Library/Developer/Xcode/DerivedData"
            if let cat = Self.scanDirectoryItems(
                id: "xcode_derived_data",
                title: "Xcode DerivedData",
                description: "Build intermediate files, indexing caches, and logs generated by Xcode.",
                icon: "hammer.fill",
                basePath: derivedDataPath,
                fileManager: fm
            ) {
                result.append(cat)
            }

            // 2b. CoreSimulator Caches
            let simCachesPath = "\(home)/Library/Developer/CoreSimulator/Caches"
            if let cat = Self.scanDirectoryItems(
                id: "simulator_caches",
                title: "CoreSimulator Caches",
                description: "Temporary runtime caches for iOS and watchOS simulators.",
                icon: "iphone.gen2",
                basePath: simCachesPath,
                fileManager: fm
            ) {
                result.append(cat)
            } else if fm.fileExists(atPath: simCachesPath) {
                let s = Self.calculateSize(of: simCachesPath, fileManager: fm)
                if s > 1024 {
                    result.append(JunkCategory(
                        id: "simulator_caches",
                        title: "CoreSimulator Caches",
                        description: "Temporary runtime caches for iOS and watchOS simulators.",
                        icon: "iphone.gen2",
                        items: [JunkItem(name: "CoreSimulator Caches", path: simCachesPath, size: s)]
                    ))
                }
            }

            // 3. Xcode iOS DeviceSupport & Archives
            let deviceSupportPath = "\(home)/Library/Developer/Xcode/iOS DeviceSupport"
            if let cat = Self.scanDirectoryItems(
                id: "xcode_device_support",
                title: "Xcode Device Support",
                description: "Debug symbols for older connected iOS devices and simulators.",
                icon: "iphone.gen3",
                basePath: deviceSupportPath,
                fileManager: fm
            ) {
                result.append(cat)
            }

            // 4. User Application Caches
            let userCachesPath = "\(home)/Library/Caches"
            if let cat = Self.scanTopDirectories(
                id: "user_caches",
                title: "Application Caches",
                description: "Temporary internet and app runtime caches stored in ~/Library/Caches.",
                icon: "internaldrive.fill",
                basePath: userCachesPath,
                limit: 15,
                fileManager: fm
            ) {
                result.append(cat)
            }

            // 5. Developer Artifacts & Package Caches
            var devItems: [JunkItem] = []
            let devPaths: [(String, String)] = [
                ("CocoaPods Cache", "\(home)/Library/Caches/CocoaPods"),
                ("Gradle Cache", "\(home)/.gradle/caches"),
                ("Cargo Registry Cache", "\(home)/.cargo/registry/cache"),
                ("Cargo Git DB Cache", "\(home)/.cargo/git/db"),
                ("Homebrew Cache", "\(home)/Library/Caches/Homebrew"),
                ("Swift Package Manager Cache", "\(home)/Library/Caches/org.swift.swiftpm"),
                ("npm Cache", "\(home)/.npm/_cacache"),
                ("pnpm Store", "\(home)/Library/pnpm/store"),
                ("pnpm Global Cache", "\(home)/.pnpm-store"),
                ("Yarn Cache", "\(home)/Library/Caches/Yarn"),
                ("Bun Cache", "\(home)/.bun/install/cache"),
                ("Go Build Cache", "\(home)/Library/Caches/go-build"),
                ("Go Module Cache", "\(home)/go/pkg/mod/cache"),
                ("Python pip Cache", "\(home)/Library/Caches/pip"),
                ("Python uv Cache", "\(home)/.cache/uv"),
                ("Python Poetry Cache", "\(home)/Library/Caches/pypoetry"),
                ("Android SDK & Build Cache", "\(home)/.android/cache"),
                ("JetBrains IDE Caches", "\(home)/Library/Caches/JetBrains"),
                ("Cursor AI Editor Cache", "\(home)/Library/Application Support/Cursor/Cache"),
                ("Claude Desktop App Cache", "\(home)/Library/Caches/com.anthropic.claudedesktop")
            ]
            for (label, p) in devPaths {
                if fm.fileExists(atPath: p) {
                    let s = Self.calculateSize(of: p, fileManager: fm)
                    if s > 1024 {
                        devItems.append(JunkItem(name: label, path: p, size: s))
                    }
                }
            }
            if !devItems.isEmpty {
                result.append(JunkCategory(
                    id: "developer_package_caches",
                    title: "Package & Dependency Caches",
                    description: "Downloaded build dependencies, compiler caches, and language package stores (Node, Python, Go, Rust, Gradle, Xcode, Docker, JetBrains).",
                    icon: "shippingbox.fill",
                    items: devItems
                ))
            }

            // 6. Saved Application State (Window states from closed applications)
            let savedStatePath = "\(home)/Library/Saved Application State"
            if let cat = Self.scanTopDirectories(
                id: "saved_application_state",
                title: "Saved Application State",
                description: "Preserved window states and restoration snapshots from closed applications.",
                icon: "macwindow.on.rectangle",
                basePath: savedStatePath,
                limit: 25,
                fileManager: fm
            ) {
                result.append(cat)
            }

            // 7. Incomplete & Stale Downloads (*.download, *.crdownload, *.part)
            let downloadsPath = "\(home)/Downloads"
            if fm.fileExists(atPath: downloadsPath),
               let downloadFiles = try? fm.contentsOfDirectory(atPath: downloadsPath) {
                var staleDownloads: [JunkItem] = []
                for file in downloadFiles {
                    let ext = (file as NSString).pathExtension.lowercased()
                    if ["download", "crdownload", "part"].contains(ext) {
                        let fullPath = "\(downloadsPath)/\(file)"
                        let s = Self.calculateSize(of: fullPath, fileManager: fm)
                        if s > 1024 {
                            staleDownloads.append(JunkItem(name: file, path: fullPath, size: s))
                        }
                    }
                }
                if !staleDownloads.isEmpty {
                    result.append(JunkCategory(
                        id: "incomplete_downloads",
                        title: "Incomplete Downloads",
                        description: "Interrupted and abandoned web downloads (.download, .crdownload, .part) in ~/Downloads.",
                        icon: "arrow.down.circle.fill",
                        items: staleDownloads
                    ))
                }
            }

            // 8. Mail Downloads Cache
            let mailDownloadsPath = "\(home)/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"
            if let cat = Self.scanDirectoryItems(
                id: "mail_downloads",
                title: "Mail Attachments Cache",
                description: "Locally cached copies of email attachments opened from Apple Mail.",
                icon: "envelope.open.fill",
                basePath: mailDownloadsPath,
                fileManager: fm
            ) {
                result.append(cat)
            }

            // 9. Cached iOS / iPadOS Firmware Updates (IPSW)
            var ipswItems: [JunkItem] = []
            let ipswPaths = [
                "\(home)/Library/iTunes/iPhone Software Updates",
                "\(home)/Library/iTunes/iPad Software Updates"
            ]
            for p in ipswPaths {
                if fm.fileExists(atPath: p) {
                    let s = Self.calculateSize(of: p, fileManager: fm)
                    if s > 1024 * 1024 {
                        let name = (p as NSString).lastPathComponent
                        ipswItems.append(JunkItem(name: name, path: p, size: s))
                    }
                }
            }
            if !ipswItems.isEmpty {
                result.append(JunkCategory(
                    id: "ios_firmware_updates",
                    title: "iOS Device Firmware (IPSW)",
                    description: "Cached iOS/iPadOS device firmware update images downloaded via Finder or iTunes.",
                    icon: "externaldrive.badge.icloud",
                    items: ipswItems
                ))
            }

            // 5. User Logs & Diagnostic Reports
            let logsPath = "\(home)/Library/Logs"
            if let cat = Self.scanDirectoryItems(
                id: "system_logs",
                title: "User Logs & Crash Reports",
                description: "Diagnostic reports, system crash dumps, and application log files.",
                icon: "doc.text.fill",
                basePath: logsPath,
                fileManager: fm
            ) {
                result.append(cat)
            }

            // 6. User Trash Bin
            let trashPath = "\(home)/.Trash"
            if var cat = Self.scanDirectoryItems(
                id: "user_trash",
                title: "Trash Bin",
                description: "Deleted files in macOS Trash waiting to be permanently erased. Not selected by default: this is your own data, and emptying it cannot be undone.",
                icon: "trash.fill",
                basePath: trashPath,
                fileManager: fm
            ) {
                cat.isSelected = false
                for index in cat.items.indices { cat.items[index].isSelected = false }
                result.append(cat)
            }

            return result
        }.value

        self.categories = scannedCategories
        self.isScanning = false
        self.statusMessage = "Found \(scannedCategories.count) categories • \(Self.formatBytes(totalJunkSize)) cleanable"
    }

    // MARK: - Safe Boundaries & Bundle Protection (CRIT-02, CRIT-03, HIGH-10)

    /// Blacklisted macOS protected system bundles that should never have caches deleted (HIGH-10).
    nonisolated public static let protectedBundleIdentifiers: Set<String> = [
        "com.apple.safari",
        "com.apple.cloudkit",
        "com.apple.akd",
        "com.apple.spotlight",
        "com.apple.addressbook",
        "com.apple.mail",
        "com.apple.passbook",
        "com.apple.preferences",
        "com.apple.keychainaccess",
        "com.apple.security",
        "com.apple.icloud",
        "com.apple.iclouddrive",
        "com.apple.homed",
        "com.apple.homekit",
        "com.apple.identityservicesd",
        "com.apple.coreservices"
    ]

    /// Helper to determine if a bundle identifier or directory name corresponds to a protected system bundle.
    nonisolated public static func isProtectedBundle(nameOrPath: String) -> Bool {
        // Explicitly allow ephemeral Mail Downloads attachment cache while preserving all mailboxes
        if nameOrPath.contains("/Containers/com.apple.mail/Data/Library/Mail Downloads") {
            return false
        }

        let components = URL(fileURLWithPath: nameOrPath).pathComponents.map { $0.lowercased() }
        for comp in components {
            for bundle in protectedBundleIdentifiers {
                if comp == bundle || comp.hasPrefix(bundle + ".") {
                    return true
                }
            }
        }
        let lower = nameOrPath.lowercased()
        for bundle in protectedBundleIdentifiers {
            if lower == bundle || lower.hasPrefix(bundle + ".") {
                return true
            }
        }
        return false
    }

    /// Checks if a directory contains a valid CACHEDIR.TAG conforming to the FreeDesktop Cache Directory Tagging Standard.
    /// Directories marked with this tag are guaranteed to contain only regenerable cached data.
    nonisolated public static func hasValidCacheDirTag(atPath path: String) -> Bool {
        let tagPath = (path as NSString).appendingPathComponent("CACHEDIR.TAG")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: tagPath), options: .alwaysMapped) else {
            return false
        }
        guard let prefix = String(data: data.prefix(43), encoding: .utf8) else {
            return false
        }
        return prefix.hasPrefix("Signature: 8a477f597d28d172789f06886806bc55")
    }

    /// Canonical safe directory roots where deletions are allowed.
    nonisolated public static func safeDirectoryRoots(home: String) -> [String] {
        [
            "\(home)/Library/Caches",
            "\(home)/Library/Developer/Xcode/DerivedData",
            "\(home)/Library/Developer/Xcode/iOS DeviceSupport",
            "\(home)/Library/Developer/CoreSimulator",
            "\(home)/Library/Developer/CoreSimulator/Caches",
            "\(home)/Library/Logs",
            "\(home)/Library/Saved Application State",
            "\(home)/Library/pnpm",
            "\(home)/Library/iTunes",
            "\(home)/Library/Containers/com.apple.mail/Data/Library/Mail Downloads",
            "\(home)/Library/Application Support/Cursor/Cache",
            "\(home)/.Trash",
            "\(home)/.npm",
            "\(home)/.pnpm-store",
            "\(home)/.yarn",
            "\(home)/.bun",
            "\(home)/.cache",
            "\(home)/.cargo",
            "\(home)/.cargo/registry",
            "\(home)/.gradle",
            "\(home)/.gradle/caches",
            "\(home)/.android",
            "\(home)/go/pkg/mod/cache",
            "\(home)/Downloads",
            NSTemporaryDirectory()
        ].map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    }

    /// User and system roots that must NEVER be deleted.
    nonisolated public static func protectedRoots(home: String) -> Set<String> {
        Set([
            home,
            "\(home)/Library",
            "\(home)/Documents",
            "\(home)/Desktop",
            "\(home)/Downloads",
            "/",
            "/System",
            "/Library",
            "/Applications",
            "/Users",
            "/bin",
            "/usr",
            "/private",
            "/var",
            "/etc"
        ].map { URL(fileURLWithPath: $0).standardizedFileURL.path })
    }

    /// True when the item's parent directory really is where its path says, relative to the (possibly symlinked) root.
    /// The root itself may be a symlink, as when `~/.cache` lives on another drive; a symlinked directory below it may not.
    nonisolated static func staysInsideRootPhysically(candidate: String, root: String) -> Bool {
        let relativeParents = candidate.dropFirst(root.hasSuffix("/") ? root.count : root.count + 1)
            .split(separator: "/")
            .dropLast()
        var expected = URL(fileURLWithPath: root).resolvingSymlinksInPath()
        for component in relativeParents {
            expected.appendPathComponent(String(component))
        }
        let actualParent = URL(fileURLWithPath: candidate).deletingLastPathComponent().resolvingSymlinksInPath()
        return actualParent.path == expected.path
    }

    /// Validates whether a candidate path is safe for deletion (CRIT-02, CRIT-03, HIGH-10).
    /// Standardizes relative segments with standardizedFileURL.
    /// CRITICAL: Does NOT call resolvingSymlinksInPath() to prevent symlink traversal attacks.
    nonisolated public static func isPathSafeForDeletion(_ path: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> Bool {
        let stdURL = URL(fileURLWithPath: path).standardizedFileURL
        let candidate = stdURL.path

        let roots = protectedRoots(home: home)
        if roots.contains(candidate) {
            return false
        }

        let safeRoots = safeDirectoryRoots(home: home)
        // Candidate must be strictly within one of the safe directory roots, never equal to the root itself
        let containingRoot = safeRoots.first { root in
            let prefix = root.hasSuffix("/") ? root : root + "/"
            return candidate.hasPrefix(prefix) && candidate != root
        }

        guard let root = containingRoot else {
            return false
        }

        // Docker Desktop keeps every image, container and named volume in its VM disk under here. It is user data.
        if candidate.contains("/Containers/com.docker.docker/") {
            return false
        }

        // A symlink between the root and the item would send the deletion somewhere the lexical check never saw.
        guard staysInsideRootPhysically(candidate: candidate, root: root) else {
            return false
        }

        // Special protection for ~/Downloads: only allow deletion of partial/incomplete downloads (*.download, *.crdownload, *.part)
        let downloadsPrefix = "\(home)/Downloads/"
        if candidate.hasPrefix(downloadsPrefix) {
            let ext = (candidate as NSString).pathExtension.lowercased()
            guard ["download", "crdownload", "part"].contains(ext) else {
                return false
            }
        }

        // Apple Neural Engine (ANE) compiled model cache protection (prevents CPU spikes & background model re-compilation)
        if candidate.contains("com.apple.e5rt.e5bundlecache") {
            return false
        }

        // Steam & Epic Games installed game libraries protection (prevent deleting heavy game files)
        if candidate.contains("/Steam/steamapps") || candidate.contains("/Epic Games") {
            return false
        }

        // User Custom & Statutory Whitelist
        if CleanerWhitelistService.shared.isWhitelisted(path: candidate) {
            return false
        }

        // Must not be a protected system bundle (HIGH-10)
        if isProtectedBundle(nameOrPath: candidate) {
            return false
        }

        return true
    }

    // MARK: - Cleaning Logic

    public func cleanSelected() async -> Int64 {
        guard !isCleaning && selectedJunkSize > 0 else { return 0 }
        isCleaning = true
        statusMessage = "Cleaning selected items..."

        let itemsToDelete = categories.flatMap { cat in
            cat.items.filter(\.isSelected)
        }
        let homeOverride = self.homeOverride

        let freed = await Task.detached(priority: .userInitiated) { () -> Int64 in
            let fm = FileManager.default
            var bytesFreed: Int64 = 0
            let home = homeOverride ?? fm.homeDirectoryForCurrentUser.path

            for item in itemsToDelete {
                let stdURL = URL(fileURLWithPath: item.path).standardizedFileURL
                let candidatePath = stdURL.path

                // Path validation before deletion (CRIT-02, CRIT-03, HIGH-10)
                guard Self.isPathSafeForDeletion(candidatePath, home: home) else {
                    NSLog("[SystemCleaner] Blocked deletion of unsafe or protected path: \(candidatePath)")
                    continue
                }

                var statBuf = stat()
                let lstatSymlink = (lstat(candidatePath, &statBuf) == 0) && ((statBuf.st_mode & S_IFMT) == S_IFLNK)
                let resourceSymlink = (try? stdURL.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
                let isSymlink = lstatSymlink || resourceSymlink

                // If candidate is a symbolic link, call unlink() or removeItem(atPath:) directly
                // on the link without traversing into the destination directory (CRIT-03)
                if isSymlink {
                    if unlink(candidatePath) == 0 {
                        bytesFreed += item.size
                    } else {
                        do {
                            try fm.removeItem(atPath: candidatePath)
                            bytesFreed += item.size
                        } catch {
                            NSLog("[SystemCleaner] Could not unlink symlink \(candidatePath): \(error)")
                        }
                    }
                    continue
                }

                if fm.fileExists(atPath: candidatePath) {
                    do {
                        try fm.removeItem(atPath: candidatePath)
                        bytesFreed += item.size
                    } catch {
                        NSLog("[SystemCleaner] Could not remove \(candidatePath): \(error)")
                    }
                }
            }
            return bytesFreed
        }.value

        self.lastFreedBytes = freed
        self.isCleaning = false
        self.statusMessage = "Successfully freed \(Self.formatBytes(freed))!"

        if freed > 0 {
            SystemCleaningHistoryTracker.shared.record(
                operationName: "System Caches & Junk",
                bytesFreed: freed,
                itemCount: itemsToDelete.count
            )
        }

        // Re-scan to update remaining sizes
        await scan()
        return freed
    }

    /// Flushes system QuickLook and DNS lookup caches, triggers in-process malloc zone pressure relief,
    /// and returns freed and available RAM bytes.
    @discardableResult
    public func optimizeMemory() async -> (freedBytes: UInt64, availableBytes: UInt64) {
        guard !isOptimizingMemory else {
            let current = SystemMemoryTelemetry.current()
            return (0, current.availableBytes)
        }
        isOptimizingMemory = true
        defer { isOptimizingMemory = false }

        let before = SystemMemoryTelemetry.current()

        // 1. In-process malloc zone pressure relief
        malloc_zone_pressure_relief(nil, 0)

        // 2. Flush system QuickLook cache and Directory Services cache
        await Task.detached(priority: .userInitiated) {
            let p1 = Process()
            p1.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
            p1.arguments = ["-r", "cache"]
            p1.standardOutput = Pipe()
            p1.standardError = Pipe()
            try? p1.run()
            p1.waitUntilExit()

            let p2 = Process()
            p2.executableURL = URL(fileURLWithPath: "/usr/bin/dscacheutil")
            p2.arguments = ["-flushcache"]
            p2.standardOutput = Pipe()
            p2.standardError = Pipe()
            try? p2.run()
            p2.waitUntilExit()
        }.value

        // Allow kernel virtual memory manager a moment to reclaim pages
        try? await Task.sleep(nanoseconds: 150_000_000)

        let after = SystemMemoryTelemetry.current()
        let freed: UInt64
        if after.usedBytes < before.usedBytes {
            freed = before.usedBytes - after.usedBytes
        } else if before.inactiveBytes > after.inactiveBytes {
            freed = before.inactiveBytes - after.inactiveBytes
        } else {
            freed = 0
        }

        self.memoryTelemetry = after
        return (freedBytes: freed, availableBytes: after.availableBytes)
    }

    // MARK: - Category & Item Toggles

    public func toggleCategory(id: String) {
        guard let idx = categories.firstIndex(where: { $0.id == id }) else { return }
        categories[idx].isSelected.toggle()
        let newState = categories[idx].isSelected
        for i in 0..<categories[idx].items.count {
            categories[idx].items[i].isSelected = newState
        }
    }

    public func toggleCategoryExpansion(id: String) {
        guard let idx = categories.firstIndex(where: { $0.id == id }) else { return }
        categories[idx].isExpanded.toggle()
    }

    public func toggleItem(categoryId: String, itemId: UUID) {
        guard let catIdx = categories.firstIndex(where: { $0.id == categoryId }) else { return }
        guard let itemIdx = categories[catIdx].items.firstIndex(where: { $0.id == itemId }) else { return }

        categories[catIdx].items[itemIdx].isSelected.toggle()
        // If any item is selected, keep category selected
        categories[catIdx].isSelected = categories[catIdx].items.contains(where: \.isSelected)
    }

    /// Selects all cleaning categories and items.
    public func selectAll() {
        setAllSelected(true)
    }

    /// Deselects all cleaning categories and items (Clean Code N7, F3).
    public func deselectAll() {
        setAllSelected(false)
    }

    /// Selects or deselects all items (backwards-compatible facade).
    public func selectAll(_ select: Bool) {
        setAllSelected(select)
    }

    private func setAllSelected(_ isSelected: Bool) {
        for i in 0..<categories.count {
            categories[i].isSelected = isSelected
            for j in 0..<categories[i].items.count {
                categories[i].items[j].isSelected = isSelected
            }
        }
    }

    // MARK: - Directory Scanning Helpers

    nonisolated private static func scanDirectoryItems(
        id: String,
        title: String,
        description: String,
        icon: String,
        basePath: String,
        fileManager: FileManager
    ) -> JunkCategory? {
        guard fileManager.fileExists(atPath: basePath) else { return nil }
        guard let contents = try? fileManager.contentsOfDirectory(atPath: basePath) else { return nil }

        var items: [JunkItem] = []
        for name in contents {
            guard !name.hasPrefix(".") else { continue }
            let fullPath = "\(basePath)/\(name)"
            if isProtectedBundle(nameOrPath: name) && !hasValidCacheDirTag(atPath: fullPath) { continue }
            var statBuf = stat()
            if lstat(fullPath, &statBuf) == 0 && (statBuf.st_mode & S_IFMT) == S_IFLNK {
                continue
            }
            let s = calculateSize(of: fullPath, fileManager: fileManager)
            if s > 0 {
                items.append(JunkItem(name: name, path: fullPath, size: s))
            }
        }

        guard !items.isEmpty else { return nil }
        items.sort { $0.size > $1.size }
        return JunkCategory(id: id, title: title, description: description, icon: icon, items: items)
    }

    nonisolated private static func scanTopDirectories(
        id: String,
        title: String,
        description: String,
        icon: String,
        basePath: String,
        limit: Int = 15,
        fileManager: FileManager
    ) -> JunkCategory? {
        guard fileManager.fileExists(atPath: basePath) else { return nil }
        guard let contents = try? fileManager.contentsOfDirectory(atPath: basePath) else { return nil }

        var items: [JunkItem] = []
        for name in contents {
            guard !name.hasPrefix(".") else { continue }
            let fullPath = "\(basePath)/\(name)"
            if isProtectedBundle(nameOrPath: name) && !hasValidCacheDirTag(atPath: fullPath) { continue }
            var statBuf = stat()
            if lstat(fullPath, &statBuf) == 0 && (statBuf.st_mode & S_IFMT) == S_IFLNK {
                continue
            }
            let s = calculateSize(of: fullPath, fileManager: fileManager)
            if s > 1024 * 1024 { // Only show caches > 1MB
                items.append(JunkItem(name: name, path: fullPath, size: s))
            }
        }

        guard !items.isEmpty else { return nil }
        items.sort { $0.size > $1.size }
        let topItems = Array(items.prefix(limit))
        return JunkCategory(id: id, title: title, description: description, icon: icon, items: topItems)
    }

    nonisolated public static func calculateSize(of path: String, fileManager: FileManager) -> Int64 {
        // Check if path itself is a symlink using lstat or resourceValues (CRIT-03)
        var statBuf = stat()
        let lstatSymlink = (lstat(path, &statBuf) == 0) && ((statBuf.st_mode & S_IFMT) == S_IFLNK)
        let rootURL = URL(fileURLWithPath: path)
        let resourceSymlink = (try? rootURL.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
        if lstatSymlink || resourceSymlink {
            return 0
        }

        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDir) else { return 0 }

        if !isDir.boolValue {
            let attr = try? fileManager.attributesOfItem(atPath: path)
            return (attr?[.size] as? NSNumber)?.int64Value ?? 0
        }

        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey, .isSymbolicLinkKey]
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: Set(keys)) else { continue }
            // Skip symbolic links: do not count size and never traverse into symlinked targets (CRIT-03)
            if resourceValues.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            let fileSize = resourceValues.totalFileAllocatedSize ?? resourceValues.fileAllocatedSize ?? resourceValues.fileSize ?? 0
            total += Int64(fileSize)
        }
        return total
    }

    // MARK: - Byte Formatting Utility

    nonisolated public static func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        }
        let kb = Double(bytes) / 1024.0
        if kb < 1024 {
            return String(format: "%.1f KB", kb)
        }
        let mb = kb / 1024.0
        if mb < 1024 {
            return String(format: "%.1f MB", mb)
        }
        let gb = mb / 1024.0
        return String(format: "%.2f GB", gb)
    }
}
