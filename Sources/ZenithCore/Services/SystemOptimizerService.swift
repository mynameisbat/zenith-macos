import Foundation

/// Identifier for specific system optimization and maintenance operations.
public enum OptimizationTaskId: String, CaseIterable, Sendable, Equatable {
    case apfsSnapshots = "apfs_snapshots"
    case orphanLaunchAgents = "orphan_launch_agents"
    case quarantineDatabase = "quarantine_database"
    case preventNetworkDsStore = "prevent_network_dsstore"
    case quickLookCacheRefresh = "quicklook_cache_refresh"
    case dnsCacheFlush = "dns_cache_flush"
    case launchServicesRebuild = "launch_services_rebuild"
    case zombieProcessCleanup = "zombie_process_cleanup"

    public var title: String {
        switch self {
        case .apfsSnapshots: return "APFS Local Snapshots"
        case .orphanLaunchAgents: return "Orphaned Launch Agents"
        case .quarantineDatabase: return "Gatekeeper Download History"
        case .preventNetworkDsStore: return "Prevent Network & USB .DS_Store"
        case .quickLookCacheRefresh: return "QuickLook & Thumbnail Cache"
        case .dnsCacheFlush: return "Flush System DNS Cache"
        case .launchServicesRebuild: return "Rebuild LaunchServices Database"
        case .zombieProcessCleanup: return "Purge Zombie / Defunct Processes"
        }
    }

    public var systemIcon: String {
        switch self {
        case .apfsSnapshots: return "clock.arrow.circlepath"
        case .orphanLaunchAgents: return "bolt.slash.fill"
        case .quarantineDatabase: return "shield.lefthalf.filled"
        case .preventNetworkDsStore: return "externaldrive.fill.badge.minus"
        case .quickLookCacheRefresh: return "eye.slash.fill"
        case .dnsCacheFlush: return "network.badge.shield.half.filled"
        case .launchServicesRebuild: return "arrow.triangle.2.circlepath.circle.fill"
        case .zombieProcessCleanup: return "exclamationmark.triangle.fill"
        }
    }
}

public enum OptimizationStatus: Sendable, Equatable {
    case ready
    case optimized
    case pending
    case failed(String)
}

/// Represents an individual system maintenance or optimization opportunity.
public struct OptimizationTaskItem: Identifiable, Sendable, Equatable {
    public let id: OptimizationTaskId
    public let title: String
    public let description: String
    public let icon: String
    public var reclaimableBytes: Int64
    public var itemCount: Int
    public var details: String
    public var status: OptimizationStatus

    public init(
        id: OptimizationTaskId,
        title: String? = nil,
        description: String,
        icon: String? = nil,
        reclaimableBytes: Int64 = 0,
        itemCount: Int = 0,
        details: String = "",
        status: OptimizationStatus = .ready
    ) {
        self.id = id
        self.title = title ?? id.title
        self.description = description
        self.icon = icon ?? id.systemIcon
        self.reclaimableBytes = reclaimableBytes
        self.itemCount = itemCount
        self.details = details
        self.status = status
    }
}

/// Native macOS System Maintenance and Optimization Service for Zenith.
public final class SystemOptimizerService: @unchecked Sendable {
    public static let shared = SystemOptimizerService()

    private let fileManager: FileManager
    private let baseHome: String?
    private let runner: SystemCommandRunner

    /// - Parameters:
    ///   - homeDirectory: Home directory the tasks act on; the current user's when `nil`.
    ///   - runner: Runs `defaults`, `qlmanage`, `lsregister`, `tmutil` and friends; tests substitute a fake so that
    ///     exercising a task never changes the machine running them.
    public init(
        fileManager: FileManager = .default,
        homeDirectory: String? = nil,
        runner: @escaping SystemCommandRunner = SystemCommand.processRunner
    ) {
        self.fileManager = fileManager
        self.baseHome = homeDirectory
        self.runner = runner
    }

    // MARK: - Scanning

    /// Scans the system for maintenance opportunities and reclaimable overhead.
    public func scan(homeDirectory: String? = nil) -> [OptimizationTaskItem] {
        let home = homeDirectory ?? baseHome ?? NSHomeDirectory()
        var tasks: [OptimizationTaskItem] = []

        // 1. APFS Local Snapshots
        tasks.append(scanApfsSnapshots())

        // 2. Orphaned LaunchAgents
        tasks.append(scanOrphanLaunchAgents(home: home))

        // 3. Gatekeeper Quarantine Download History
        tasks.append(scanQuarantineDatabase(home: home))

        // 4. Prevent Network & USB .DS_Store
        tasks.append(scanDsStorePreventionPreference())

        // 5. QuickLook & Thumbnail Cache
        tasks.append(scanQuickLookCache(home: home))

        // 6. DNS Cache
        tasks.append(OptimizationTaskItem(
            id: .dnsCacheFlush,
            description: "Clear stale domain resolution entries and mDNS responder state.",
            details: "Ready to flush",
            status: .ready
        ))

        // 7. LaunchServices Database
        tasks.append(OptimizationTaskItem(
            id: .launchServicesRebuild,
            description: "Rebuilds application associations to fix duplicate, stale, or missing Open With icons.",
            details: "Ready to rebuild",
            status: .ready
        ))

        // 8. Zombie Process Cleanup
        let zombies = HardwareTelemetryService.shared.readCPUTelemetry().zombieProcesses
        tasks.append(OptimizationTaskItem(
            id: .zombieProcessCleanup,
            description: "Terminates defunct/zombie processes lingering in the kernel process table.",
            itemCount: zombies.count,
            details: zombies.isEmpty ? "Clean — zero zombie processes discovered" : "\(zombies.count) defunct zombie(s) found",
            status: zombies.isEmpty ? .optimized : .ready
        ))

        return tasks
    }

    // MARK: - Individual Scanners

    public func scanApfsSnapshots() -> OptimizationTaskItem {
        let snapshots = listApfsLocalSnapshots()
        let count = snapshots.count
        let estBytes = Int64(count) * 1_073_741_824 // ~1GB estimated per local snapshot
        return OptimizationTaskItem(
            id: .apfsSnapshots,
            description: "Local Time Machine backup snapshots stored silently on the boot APFS container.",
            reclaimableBytes: estBytes,
            itemCount: count,
            details: count > 0 ? "\(count) snapshot(s) found" : "Clean — no local snapshots pending",
            status: count > 0 ? .ready : .optimized
        )
    }

    public func scanOrphanLaunchAgents(home: String) -> OptimizationTaskItem {
        let orphans = findOrphanLaunchAgents(home: home)
        return OptimizationTaskItem(
            id: .orphanLaunchAgents,
            description: "Background daemons whose target application binaries no longer exist on disk.",
            reclaimableBytes: 0,
            itemCount: orphans.count,
            details: orphans.isEmpty ? "All registered launch agents have valid binaries" : "\(orphans.count) orphan agent(s) discovered",
            status: orphans.isEmpty ? .optimized : .ready
        )
    }

    public func scanQuarantineDatabase(home: String) -> OptimizationTaskItem {
        let path = "\(home)/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2"
        var size: Int64 = 0
        if fileManager.fileExists(atPath: path) {
            let attrs = try? fileManager.attributesOfItem(atPath: path)
            size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        }
        return OptimizationTaskItem(
            id: .quarantineDatabase,
            description: "Internal Gatekeeper log containing historical records of every downloaded file.",
            reclaimableBytes: size,
            itemCount: size > 0 ? 1 : 0,
            details: size > 0 ? "\(size / 1024) KB of quarantine download history" : "Clean",
            status: size > 0 ? .ready : .optimized
        )
    }

    public func scanDsStorePreventionPreference() -> OptimizationTaskItem {
        let networkDisabled = UserDefaults.standard.persistentDomain(forName: "com.apple.desktopservices")?["DSDontWriteNetworkStores"] as? Bool ?? false
        let isOptimized = networkDisabled
        return OptimizationTaskItem(
            id: .preventNetworkDsStore,
            description: "Stop Finder from cluttering USB flash drives and network SMB shares with hidden .DS_Store files.",
            details: isOptimized ? "Optimized — writing suppressed on remote & removable media" : "Enabled (macOS default creates .DS_Store everywhere)",
            status: isOptimized ? .optimized : .ready
        )
    }

    public func scanQuickLookCache(home: String) -> OptimizationTaskItem {
        let candidatePaths = [
            "\(home)/Library/Caches/com.apple.QuickLook.thumbnailcache",
            "\(home)/Library/Caches/Quick Look"
        ]
        var totalSize: Int64 = 0
        for p in candidatePaths where fileManager.fileExists(atPath: p) {
            totalSize += calculateSize(of: p)
        }
        return OptimizationTaskItem(
            id: .quickLookCacheRefresh,
            description: "QuickLook thumbnail cache and system IconServices index.",
            reclaimableBytes: totalSize,
            itemCount: totalSize > 0 ? 1 : 0,
            details: totalSize > 0 ? "\(totalSize / 1024 / 1024) MB cached previews" : "Clean",
            status: .ready
        )
    }

    // MARK: - Execution

    /// Executes the specified optimization task.
    @discardableResult
    public func execute(taskId: OptimizationTaskId, homeDirectory: String? = nil) throws -> Int64 {
        let home = homeDirectory ?? baseHome ?? NSHomeDirectory()
        var freedBytes: Int64 = 0

        switch taskId {
        case .apfsSnapshots:
            let snapshots = listApfsLocalSnapshots()
            let availableBefore = availableCapacity()
            let deleted = snapshots.filter { deleteApfsSnapshot(date: $0) }.count
            if !snapshots.isEmpty && deleted == 0 {
                throw OptimizerError.requiresAdministrator("macOS only lets administrators delete local snapshots (tmutil needs root)")
            }
            // What was really reclaimed, not an estimate: how much more free space the volume has now.
            freedBytes = max(0, availableCapacity() - availableBefore)

        case .orphanLaunchAgents:
            let orphans = findOrphanLaunchAgents(home: home)
            for path in orphans {
                try? fileManager.removeItem(atPath: path)
            }

        case .quarantineDatabase:
            let path = "\(home)/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2"
            if fileManager.fileExists(atPath: path) {
                let attrs = try? fileManager.attributesOfItem(atPath: path)
                freedBytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                try? fileManager.removeItem(atPath: path)
            }

        case .preventNetworkDsStore:
            try runChecked("/usr/bin/defaults", ["write", "com.apple.desktopservices", "DSDontWriteNetworkStores", "-bool", "true"])
            try runChecked("/usr/bin/defaults", ["write", "com.apple.desktopservices", "DSDontWriteUSBStores", "-bool", "true"])

        case .quickLookCacheRefresh:
            let candidatePaths = [
                "\(home)/Library/Caches/com.apple.QuickLook.thumbnailcache",
                "\(home)/Library/Caches/Quick Look"
            ]
            for p in candidatePaths where fileManager.fileExists(atPath: p) {
                freedBytes += calculateSize(of: p)
                try? fileManager.removeItem(atPath: p)
            }
            // Reset qlmanage
            try runChecked("/usr/bin/qlmanage", ["-r"])

        case .dnsCacheFlush:
            try runChecked("/usr/bin/dscacheutil", ["-flushcache"])
            // mDNSResponder runs as root, so for a normal user this only succeeds when launched with elevated rights.
            // Saying so is better than reporting a flush that did not happen.
            if runner("/usr/bin/killall", ["-HUP", "mDNSResponder"])?.status != 0 {
                throw OptimizerError.requiresAdministrator("the directory-service cache was flushed, but the system DNS responder can only be reset by an administrator")
            }

        case .launchServicesRebuild:
            let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
            if fileManager.fileExists(atPath: lsregister) {
                try runChecked(lsregister, ["-kill", "-r", "-domain", "local", "-domain", "system", "-domain", "user"])
            }

        case .zombieProcessCleanup:
            // A zombie is already dead, so signalling it does nothing; only its parent can reap it, and the
            // standard nudge for that is SIGCHLD.
            let zombies = HardwareTelemetryService.shared.readCPUTelemetry().zombieProcesses
            for zombie in zombies {
                HardwareTelemetryService.shared.requestReap(of: zombie)
            }
        }

        return freedBytes
    }

    // MARK: - Internal Helpers

    public func listApfsLocalSnapshots() -> [String] {
        guard let output = runner("/usr/bin/tmutil", ["listlocalsnapshots", "/"])?.output else { return [] }

        // Output lines look like: "com.apple.TimeMachine.2026-10-24-123456.local"
        var dates: [String] = []
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.contains("com.apple.TimeMachine.") {
                let parts = trimmed.components(separatedBy: ".")
                if parts.count >= 4 {
                    // Extract date portion (e.g. 2026-10-24-123456)
                    dates.append(parts[3])
                }
            }
        }
        return dates
    }

    @discardableResult
    public func deleteApfsSnapshot(date: String) -> Bool {
        runner("/usr/bin/tmutil", ["deletelocalsnapshots", date])?.status == 0
    }

    /// Runs a command whose failure means the task did not do its job.
    private func runChecked(_ executable: String, _ arguments: [String]) throws {
        let name = URL(fileURLWithPath: executable).lastPathComponent
        guard let result = runner(executable, arguments) else {
            throw OptimizerError.commandFailed(tool: name, detail: "it could not be started")
        }
        guard result.status == 0 else {
            let detail = result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            throw OptimizerError.commandFailed(tool: name, detail: detail.isEmpty ? "exit status \(result.status)" : detail)
        }
    }

    /// Free bytes on the startup volume, excluding space macOS could purge (which local snapshots count as).
    private func availableCapacity() -> Int64 {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return Int64(values?.volumeAvailableCapacity ?? 0)
    }

    public func findOrphanLaunchAgents(home: String) -> [String] {
        let dirs = ["\(home)/Library/LaunchAgents", "/Library/LaunchAgents"]
        var orphans: [String] = []

        for dir in dirs {
            guard fileManager.fileExists(atPath: dir),
                  let files = try? fileManager.contentsOfDirectory(atPath: dir) else { continue }
            for f in files where f.hasSuffix(".plist") {
                let fullPath = "\(dir)/\(f)"
                if isLaunchAgentOrphan(atPath: fullPath) {
                    orphans.append(fullPath)
                }
            }
        }
        return orphans
    }

    public func isLaunchAgentOrphan(atPath path: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return false
        }
        var binaryPath: String?
        if let prog = plist["Program"] as? String {
            binaryPath = prog
        } else if let args = plist["ProgramArguments"] as? [String], let first = args.first {
            binaryPath = first
        }
        guard let bin = binaryPath, !bin.isEmpty else { return false }
        // If binary is a system utility (/bin/sh, /usr/bin/python, etc.) it's not orphan
        if isSystemBinary(bin) {
            return false
        }
        // If target binary does not exist, it is an orphan
        return !fileManager.fileExists(atPath: bin)
    }

    private static let systemBinaryPrefixes = ["/bin", "/usr/bin", "/System"]

    private func isSystemBinary(_ path: String) -> Bool {
        Self.systemBinaryPrefixes.contains { path.hasPrefix($0) }
    }

    private func calculateSize(of path: String) -> Int64 {
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

public enum OptimizerError: Error, LocalizedError, Equatable {
    case commandFailed(tool: String, detail: String)
    case requiresAdministrator(String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let tool, let detail):
            return "\(tool) failed: \(detail)."
        case .requiresAdministrator(let reason):
            return "Administrator rights are required: \(reason)."
        }
    }
}
