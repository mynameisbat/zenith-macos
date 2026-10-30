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

public enum ExternalDriveError: Error, LocalizedError, Equatable {
    case notAnExternalVolume(String)

    public var errorDescription: String? {
        switch self {
        case .notAnExternalVolume(let path):
            return "\(path) is not a mounted, writable external volume, so nothing was removed."
        }
    }
}

/// Service that scrubs macOS phantom files (.DS_Store, AppleDouble ._*, .TemporaryItems)
/// from external drives, USB thumbsticks, and shared FAT/exFAT/NTFS storage.
/// Modeled after Mole's `mo clean --external`.
///
/// It deletes permanently, so it is deliberately narrow: it only works on the root of a mounted external volume, and a
/// file is only "phantom" when its content says so, not merely because of its name.
public final class ExternalDriveSanitizerService: @unchecked Sendable {
    public static let shared = ExternalDriveSanitizerService()

    private let volumeProvider: (@Sendable () -> [URL])?

    /// - Parameter volumeProvider: The volumes `sanitize` may work on. By default, the mounted external volumes.
    public init(volumeProvider: (@Sendable () -> [URL])? = nil) {
        self.volumeProvider = volumeProvider
    }

    /// Folders macOS creates at the top of a volume. Below the root a folder of that name is the user's.
    private static let volumeRootFolders: Set<String> = [".TemporaryItems", ".Spotlight-V100", ".fseventsd"]
    /// Files that are junk wherever they are. (`desktop.ini` is not: it holds a Windows user's folder customisation.)
    private static let phantomFileNames: Set<String> = [".DS_Store", "Thumbs.db"]
    /// The first four bytes of every AppleDouble file.
    private static let appleDoubleMagic = Data([0x00, 0x05, 0x16, 0x07])

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

    /// Scans a target volume for phantom macOS metadata files, streaming through it rather than listing the whole tree
    /// first (a multi-terabyte drive has millions of entries).
    public func scanVolume(url: URL) async -> (fileCount: Int, byteSize: Int64, paths: [URL]) {
        await Task.detached(priority: .utility) {
            Self.findPhantoms(in: url)
        }.value
    }

    /// The names in a directory, `._*` files included. Foundation's `enumerator` and `contentsOfDirectory` both leave
    /// those out (they are the main thing to find here), so the directory is read with POSIX `readdir`.
    static func directoryEntries(atPath path: String) -> [String]? {
        guard let directory = opendir(path) else { return nil }
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." {
                names.append(name)
            }
        }
        return names
    }

    /// Walks the volume one directory at a time; `lstat` tells links from real files so nothing is followed.
    static func findPhantoms(in root: URL) -> (fileCount: Int, byteSize: Int64, paths: [URL]) {
        let rootPath = root.standardizedFileURL.path
        var phantomPaths: [URL] = []
        var totalBytes: Int64 = 0
        var pending = [root]
        var directoriesVisited = 0

        while let directory = pending.popLast() {
            directoriesVisited += 1
            if directoriesVisited % 256 == 0, Task.isCancelled { break }
            guard let names = directoryEntries(atPath: directory.path) else { continue }  // unreadable: skipped

            for name in names {
                let url = directory.appendingPathComponent(name)
                var info = stat()
                guard lstat(url.path, &info) == 0 else { continue }

                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    if volumeRootFolders.contains(name), directory.standardizedFileURL.path == rootPath {
                        phantomPaths.append(url)
                        totalBytes += size(of: url)
                    } else {
                        pending.append(url)
                    }
                case S_IFREG:
                    if phantomFileNames.contains(name) || (name.hasPrefix("._") && isAppleDouble(url)) {
                        phantomPaths.append(url)
                        totalBytes += Int64(info.st_size)
                    }
                default:
                    continue    // symlinks, sockets, devices: never touched
                }
            }
        }

        return (phantomPaths.count, totalBytes, phantomPaths)
    }

    /// A `._name` file is only AppleDouble metadata if it starts with the AppleDouble header. On a Mac-formatted drive a
    /// file called `._notes` is quite possibly the user's own.
    static func isAppleDouble(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return handle.readData(ofLength: 4) == appleDoubleMagic
    }

    private static func size(of directory: URL) -> Int64 {
        var total: Int64 = 0
        var pending = [directory]
        while let current = pending.popLast() {
            guard let names = directoryEntries(atPath: current.path) else { continue }
            for name in names {
                let url = current.appendingPathComponent(name)
                var info = stat()
                guard lstat(url.path, &info) == 0 else { continue }
                switch info.st_mode & S_IFMT {
                case S_IFDIR: pending.append(url)
                case S_IFREG: total += Int64(info.st_blocks) * 512
                default: continue
                }
            }
        }
        return total
    }

    /// Sanitizes an external volume by permanently removing all macOS phantom metadata files.
    /// Throws without touching anything unless `volumeURL` is the root of a mounted external volume.
    @discardableResult
    public func sanitize(volumeURL: URL) async throws -> (removedCount: Int, freedBytes: Int64) {
        let volumes = volumeProvider?() ?? discoverExternalVolumes().map(\.url)
        guard volumes.contains(where: { $0.standardizedFileURL.path == volumeURL.standardizedFileURL.path }) else {
            throw ExternalDriveError.notAnExternalVolume(volumeURL.path)
        }

        let (_, _, paths) = await scanVolume(url: volumeURL)
        let fileManager = FileManager.default

        var removedCount = 0
        var freedBytes: Int64 = 0

        for path in paths {
            if CleanerWhitelistService.shared.isWhitelisted(path: path.path) {
                continue
            }

            let size = (try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            let weight = (try? path.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? Self.size(of: path) : size

            // Count only what was really removed (a read-only share or a locked file fails here).
            do {
                try fileManager.removeItem(at: path)
                removedCount += 1
                freedBytes += weight
            } catch {
                continue
            }
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
