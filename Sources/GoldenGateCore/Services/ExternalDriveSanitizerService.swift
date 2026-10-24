import Foundation

/// Discovered external drive or USB volume with macOS metadata footprint.
public struct ExternalVolumeItem: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let url: URL
    public let totalCapacity: Int64
    public let availableCapacity: Int64
    public let isRemovable: Bool
    public let phantomFileCount: Int
    public let phantomBytes: Int64

    public init(
        id: String = UUID().uuidString,
        name: String,
        url: URL,
        totalCapacity: Int64 = 0,
        availableCapacity: Int64 = 0,
        isRemovable: Bool = true,
        phantomFileCount: Int = 0,
        phantomBytes: Int64 = 0
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.totalCapacity = totalCapacity
        self.availableCapacity = availableCapacity
        self.isRemovable = isRemovable
        self.phantomFileCount = phantomFileCount
        self.phantomBytes = phantomBytes
    }
}

/// Service that scrubs macOS phantom files (.DS_Store, AppleDouble ._*, .TemporaryItems)
/// from external drives, USB thumbsticks, and shared FAT/exFAT/NTFS storage.
/// Modeled after Mole's `mo clean --external`.
public final class ExternalDriveSanitizerService: @unchecked Sendable {
    public static let shared = ExternalDriveSanitizerService()

    public init() {}

    /// Discovers all mounted external volumes (excluding the boot disk).
    public func discoverExternalVolumes() -> [ExternalVolumeItem] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeIsRemovableKey,
            .volumeIsInternalKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeIsReadOnlyKey
        ]

        let fileManager = FileManager.default
        guard let volumeURLs = fileManager.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) else {
            return []
        }

        var items: [ExternalVolumeItem] = []

        for volume in volumeURLs {
            // Skip the boot volume "/"
            if volume.path == "/" {
                continue
            }

            guard let vals = try? volume.resourceValues(forKeys: Set(keys)) else {
                continue
            }

            // Skip read-only volumes (e.g. installer DMGs, Time Machine backups)
            if vals.volumeIsReadOnly == true {
                continue
            }

            let name = vals.volumeName ?? volume.lastPathComponent
            let total = Int64(vals.volumeTotalCapacity ?? 0)
            let free = Int64(vals.volumeAvailableCapacity ?? 0)
            let isRemovable = vals.volumeIsRemovable ?? true
            let isInternal = vals.volumeIsInternal ?? false

            // Treat any mounted non-root volume as external/secondary
            if isRemovable || !isInternal {
                items.append(ExternalVolumeItem(
                    name: name,
                    url: volume,
                    totalCapacity: total,
                    availableCapacity: free,
                    isRemovable: isRemovable
                ))
            }
        }

        return items
    }

    /// Scans a target volume for phantom macOS metadata files.
    public func scanVolume(url: URL) async -> (fileCount: Int, byteSize: Int64, paths: [URL]) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            return (0, 0, [])
        }

        var phantomPaths: [URL] = []
        var totalBytes: Int64 = 0

        guard let subpaths = try? fileManager.subpathsOfDirectory(atPath: url.path) else {
            return (0, 0, [])
        }

        for subpath in subpaths {
            let fileURL = url.appendingPathComponent(subpath)
            let filename = fileURL.lastPathComponent

            var isPhantom = false
            if filename == ".DS_Store" ||
               filename.hasPrefix("._") ||
               filename == ".TemporaryItems" ||
               filename == ".Spotlight-V100" ||
               filename == ".fseventsd" ||
               filename == "Thumbs.db" ||
               filename == "desktop.ini" {
                isPhantom = true
            }

            if isPhantom {
                phantomPaths.append(fileURL)
                if let vals = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
                   let size = vals.fileSize {
                    totalBytes += Int64(size)
                }
            }
        }

        return (phantomPaths.count, totalBytes, phantomPaths)
    }

    /// Sanitizes an external volume by permanently removing all macOS phantom metadata files.
    @discardableResult
    public func sanitize(volumeURL: URL) async throws -> (removedCount: Int, freedBytes: Int64) {
        let (_, _, paths) = await scanVolume(url: volumeURL)
        let fileManager = FileManager.default

        var removedCount = 0
        var freedBytes: Int64 = 0

        for path in paths {
            if CleanerWhitelistService.shared.isWhitelisted(path: path.path) {
                continue
            }

            if let vals = try? path.resourceValues(forKeys: [.fileSizeKey]),
               let size = vals.fileSize {
                freedBytes += Int64(size)
            }

            try? fileManager.removeItem(at: path)
            removedCount += 1
        }

        if freedBytes > 0 {
            SystemCleaningHistoryTracker.shared.record(
                operationName: "External Drive Sanitizer (\(volumeURL.lastPathComponent))",
                bytesFreed: freedBytes,
                itemCount: removedCount
            )
        }

        return (removedCount, freedBytes)
    }
}
