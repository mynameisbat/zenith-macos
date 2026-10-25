import Foundation

/// Discovered stale installer package or disk image.
public struct StaleInstallerItem: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let url: URL
    public let byteSize: Int64
    public let fileExtension: String
    public let modifiedAt: Date
    public let isMounted: Bool

    public init(
        id: String = UUID().uuidString,
        name: String,
        url: URL,
        byteSize: Int64,
        fileExtension: String,
        modifiedAt: Date,
        isMounted: Bool = false
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.byteSize = byteSize
        self.fileExtension = fileExtension.lowercased()
        self.modifiedAt = modifiedAt
        self.isMounted = isMounted
    }
}

/// Service that hunts stale installer images (.dmg, .pkg, .iso, .xip, .zip)
/// across user download and staging folders, modeled after Mole's `mo installer`.
public final class InstallerPurgeService: @unchecked Sendable {
    public static let shared = InstallerPurgeService()

    public static let supportedExtensions: Set<String> = ["dmg", "pkg", "iso", "xip"]

    public init() {}

    /// Scans standard target directories for leftover installers.
    public func scan(
        directories: [URL]? = nil,
        minAgeDays: Int = 3,
        minSizeBytes: Int64 = 10 * 1024 * 1024 // 10 MB minimum
    ) async -> [StaleInstallerItem] {
        let fileManager = FileManager.default
        let targets = directories ?? defaultScanDirectories()

        let cutoffDate = Calendar.current.date(byAdding: .day, value: -minAgeDays, to: Date()) ?? Date()
        let mountedNames = getMountedVolumeNames()

        var results: [StaleInstallerItem] = []

        for dir in targets {
            guard fileManager.fileExists(atPath: dir.path) else { continue }
            guard let enumerator = fileManager.enumerator(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]
            ) else { continue }

            while let fileURL = enumerator.nextObject() as? URL {
                let ext = fileURL.pathExtension.lowercased()
                var isCandidate = Self.supportedExtensions.contains(ext)

                // For ZIP archives, candidate if size > 50MB and name indicates an app installer
                if ext == "zip" {
                    let baseName = fileURL.deletingPathExtension().lastPathComponent.lowercased()
                    if baseName.contains("installer") || baseName.contains("setup") || baseName.contains("mac") || baseName.contains("darwin") || baseName.contains("app") {
                        isCandidate = true
                    }
                }

                guard isCandidate else { continue }

                guard let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                      let size = resourceValues.fileSize,
                      let modDate = resourceValues.contentModificationDate else {
                    continue
                }

                let byteSize = Int64(size)
                guard byteSize >= minSizeBytes else { continue }
                guard modDate <= cutoffDate else { continue }

                // Check if currently mounted DMG
                let baseName = fileURL.deletingPathExtension().lastPathComponent.lowercased()
                let isMounted = mountedNames.contains(where: { $0.lowercased().contains(baseName) })

                results.append(StaleInstallerItem(
                    name: fileURL.lastPathComponent,
                    url: fileURL,
                    byteSize: byteSize,
                    fileExtension: ext,
                    modifiedAt: modDate,
                    isMounted: isMounted
                ))
            }
        }

        return results.sorted { $0.byteSize > $1.byteSize }
    }

    /// Purges or moves discovered stale installers to the Trash.
    @discardableResult
    public func purge(items: [StaleInstallerItem], moveToTrash: Bool = true) async throws -> Int64 {
        let fileManager = FileManager.default
        var totalFreed: Int64 = 0

        for item in items {
            // Safety guard: skip if currently mounted
            if item.isMounted {
                continue
            }

            // Whitelist guard
            if CleanerWhitelistService.shared.isWhitelisted(path: item.url.path) {
                continue
            }

            guard fileManager.fileExists(atPath: item.url.path) else { continue }

            if moveToTrash {
                try fileManager.trashItem(at: item.url, resultingItemURL: nil)
            } else {
                try fileManager.removeItem(at: item.url)
            }

            totalFreed += item.byteSize
        }

        if totalFreed > 0 {
            SystemCleaningHistoryTracker.shared.record(
                operationName: "Installer Purge",
                bytesFreed: totalFreed,
                itemCount: items.count
            )
        }

        return totalFreed
    }

    private func defaultScanDirectories() -> [URL] {
        var dirs: [URL] = []
        let home = FileManager.default.homeDirectoryForCurrentUser
        dirs.append(home.appendingPathComponent("Downloads"))
        dirs.append(home.appendingPathComponent("Desktop"))
        dirs.append(URL(fileURLWithPath: "/tmp"))
        return dirs
    }

    private func getMountedVolumeNames() -> Set<String> {
        let keys: [URLResourceKey] = [.volumeNameKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return Set(urls.compactMap { (try? $0.resourceValues(forKeys: [.volumeNameKey]))?.volumeName })
    }
}
