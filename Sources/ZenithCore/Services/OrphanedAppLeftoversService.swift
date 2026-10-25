import Foundation

/// Residual remnant folder or files left behind by an application previously deleted.
public struct OrphanedAppItem: Identifiable, Sendable, Equatable {
    public let id: String
    public let appName: String
    public let bundleId: String?
    public let path: String
    public let byteSize: Int64
    public let fileCount: Int
    public let category: String

    public init(
        id: String = UUID().uuidString,
        appName: String,
        bundleId: String?,
        path: String,
        byteSize: Int64,
        fileCount: Int,
        category: String = "Application Support"
    ) {
        self.id = id
        self.appName = appName
        self.bundleId = bundleId
        self.path = path
        self.byteSize = byteSize
        self.fileCount = fileCount
        self.category = category
    }
}

/// Service that hunts orphaned leftover residue from applications previously deleted without an uninstaller,
/// modeled after Mole's `lib/clean/apps.sh` orphaned discovery engine.
public final class OrphanedAppLeftoversService: @unchecked Sendable {
    public static let shared = OrphanedAppLeftoversService()

    public init() {}

    /// Scans user Library directories for residue belonging to apps no longer installed.
    public func scan(locations: [(url: URL, category: String)]? = nil) async -> [OrphanedAppItem] {
        let installedBundles = getInstalledBundleIdsAndNames()
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser

        let searchLocations: [(url: URL, category: String)] = locations ?? [
            (home.appendingPathComponent("Library/Application Support"), "Application Support"),
            (home.appendingPathComponent("Library/Caches"), "Caches"),
            (home.appendingPathComponent("Library/Containers"), "Containers"),
            (home.appendingPathComponent("Library/Saved Application State"), "Saved State"),
            (home.appendingPathComponent("Library/WebKit"), "WebKit")
        ]

        var orphans: [OrphanedAppItem] = []

        for location in searchLocations {
            guard fileManager.fileExists(atPath: location.url.path) else { continue }
            guard let contents = try? fileManager.contentsOfDirectory(at: location.url, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }

            for itemURL in contents {
                let name = itemURL.lastPathComponent

                // Skip Apple system folders and whitelisted statutory items
                if shouldIgnoreSystemItem(name: name, path: itemURL.path) {
                    continue
                }

                // Check if whitelisted
                if CleanerWhitelistService.shared.isWhitelisted(path: itemURL.path) {
                    continue
                }

                // Determine if this item corresponds to any installed application
                let isInstalled = isItemAssociatedWithInstalledApp(name: name, installedMap: installedBundles)
                if !isInstalled {
                    let (size, count) = calculateDirectoryMetrics(url: itemURL)
                    guard size > 1024 else { continue } // Ignore empty 0-byte placeholders

                    let cleanAppName = extractCleanAppName(from: name)
                    orphans.append(OrphanedAppItem(
                        appName: cleanAppName,
                        bundleId: name.contains(".") ? name : nil,
                        path: itemURL.path,
                        byteSize: size,
                        fileCount: count,
                        category: location.category
                    ))
                }
            }
        }

        return orphans.sorted { $0.byteSize > $1.byteSize }
    }

    /// Purges or trashes discovered orphaned application leftovers.
    @discardableResult
    public func purge(items: [OrphanedAppItem], moveToTrash: Bool = true) async throws -> Int64 {
        let fileManager = FileManager.default
        var totalFreed: Int64 = 0

        for item in items {
            if CleanerWhitelistService.shared.isWhitelisted(path: item.path) {
                continue
            }

            let url = URL(fileURLWithPath: item.path)
            guard fileManager.fileExists(atPath: item.path) else { continue }

            if moveToTrash {
                try fileManager.trashItem(at: url, resultingItemURL: nil)
            } else {
                try fileManager.removeItem(at: url)
            }

            totalFreed += item.byteSize
        }

        if totalFreed > 0 {
            SystemCleaningHistoryTracker.shared.record(
                operationName: "Orphaned App Leftovers",
                bytesFreed: totalFreed,
                itemCount: items.count
            )
        }

        return totalFreed
    }

    // MARK: - Helpers

    private func getInstalledBundleIdsAndNames() -> (bundles: Set<String>, names: Set<String>) {
        var bundles = Set<String>()
        var names = Set<String>()

        let appDirs = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        ]

        let fileManager = FileManager.default
        for dir in appDirs {
            guard let contents = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for appURL in contents where appURL.pathExtension.lowercased() == "app" {
                let appName = appURL.deletingPathExtension().lastPathComponent.lowercased()
                names.insert(appName)

                if let bundle = Bundle(url: appURL), let bId = bundle.bundleIdentifier {
                    bundles.insert(bId.lowercased())
                }
            }
        }

        return (bundles, names)
    }

    private func shouldIgnoreSystemItem(name: String, path: String) -> Bool {
        let lower = name.lowercased()
        if lower.hasPrefix("com.apple.") ||
           lower == "apple" ||
           lower == "icloud" ||
           lower == "clouddocs" ||
           lower == "addressbook" ||
           lower == "dock" ||
           lower == "finder" ||
           lower == "system" ||
           lower == "mobilesync" ||
           lower == "coresimulator" ||
           lower == "quicklook" ||
           lower == "zenith" ||
           lower == "goldengate" ||
           path.contains("com.apple.e5rt.e5bundlecache") ||
           path.contains("Steam/steamapps") ||
           path.contains("Epic Games") {
            return true
        }
        return false
    }

    private func isItemAssociatedWithInstalledApp(name: String, installedMap: (bundles: Set<String>, names: Set<String>)) -> Bool {
        let lower = name.lowercased()

        // 1. Direct bundle ID match
        if installedMap.bundles.contains(lower) {
            return true
        }

        // 2. Direct app name match
        if installedMap.names.contains(lower) {
            return true
        }

        // 3. Reverse DNS prefix match (e.g. com.spotify.client.savedState -> com.spotify.client)
        for bundle in installedMap.bundles {
            if lower.hasPrefix(bundle) {
                return true
            }
        }

        // 4. Name prefix match
        for appName in installedMap.names {
            if lower.contains(appName) && appName.count >= 4 {
                return true
            }
        }

        return false
    }

    private func extractCleanAppName(from folderName: String) -> String {
        var clean = folderName
        if clean.hasSuffix(".savedState") {
            clean = clean.replacingOccurrences(of: ".savedState", with: "")
        }
        if clean.contains(".") {
            let parts = clean.split(separator: ".")
            if let last = parts.last, last.count >= 2 {
                return last.capitalized
            }
        }
        return clean
    }

    private func calculateDirectoryMetrics(url: URL) -> (size: Int64, count: Int) {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsPackageDescendants]
        ) else { return (0, 0) }

        var totalSize: Int64 = 0
        var totalCount: Int = 0

        while let fileURL = enumerator.nextObject() as? URL {
            guard let vals = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  vals.isRegularFile == true,
                  let size = vals.fileSize else { continue }
            totalSize += Int64(size)
            totalCount += 1
        }

        return (totalSize, totalCount)
    }
}
