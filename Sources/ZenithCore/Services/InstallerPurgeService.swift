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

/// Service that hunts stale installer images (.dmg, .pkg, .iso, .xip) and large installer archives (.zip)
/// across user download and staging folders, modeled after Mole's `mo installer`.
///
/// Only regular files directly inside the scanned folders are offered, only when nothing has touched them for
/// `minAgeDays` (the newest of the modification, creation and "added to folder" dates counts: a download that keeps
/// the server's old modification date, or a file moved in from elsewhere, is still new), and never while the disk image is mounted. `purge` checks each item again, so a
/// file that was replaced after the scan is left alone.
public final class InstallerPurgeService: @unchecked Sendable {
    public static let shared = InstallerPurgeService()

    public static let supportedExtensions: Set<String> = ["dmg", "pkg", "iso", "xip"]

    /// A .zip is an installer only if its name says so; "mac-backup.zip" or "app-assets.zip" are somebody's files.
    private static let zipInstallerKeywords = ["installer", "install", "setup"]

    private let runCommand: SystemCommandRunner
    private let zipMinSizeBytes: Int64
    private let now: @Sendable () -> Date

    public init(
        runCommand: @escaping SystemCommandRunner = SystemCommand.processRunner,
        zipMinSizeBytes: Int64 = 50 * 1024 * 1024,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.runCommand = runCommand
        self.zipMinSizeBytes = zipMinSizeBytes
        self.now = now
    }

    private func isInstallerCandidate(_ url: URL, size: Int64) -> Bool {
        let ext = url.pathExtension.lowercased()
        if Self.supportedExtensions.contains(ext) { return true }
        guard ext == "zip", size >= zipMinSizeBytes else { return false }
        let baseName = url.deletingPathExtension().lastPathComponent.lowercased()
        return Self.zipInstallerKeywords.contains { baseName.contains($0) }
    }

    /// The most recent of the modification, creation and added-to-folder dates.
    private static func lastTouched(_ values: URLResourceValues) -> Date? {
        [values.contentModificationDate, values.creationDate, values.addedToDirectoryDate].compactMap { $0 }.max()
    }

    private static let fileKeys: Set<URLResourceKey> = [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey,
        .addedToDirectoryDateKey
    ]

    /// Scans download and desktop folders (or `directories`) for leftover installers.
    public func scan(
        directories: [URL]? = nil,
        minAgeDays: Int = 3,
        minSizeBytes: Int64 = 10 * 1024 * 1024 // 10 MB minimum
    ) async -> [StaleInstallerItem] {
        let fileManager = FileManager.default
        let targets = directories ?? defaultScanDirectories()

        let cutoffDate = Calendar.current.date(byAdding: .day, value: -minAgeDays, to: now()) ?? now()
        let mountedImages = mountedImagePaths()

        var results: [StaleInstallerItem] = []

        for dir in targets {
            guard let enumerator = fileManager.enumerator(
                at: dir,
                includingPropertiesForKeys: Array(Self.fileKeys),
                options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]
            ) else { continue }

            while let fileURL = enumerator.nextObject() as? URL {
                guard let values = try? fileURL.resourceValues(forKeys: Self.fileKeys),
                      values.isRegularFile == true,
                      values.isSymbolicLink != true,
                      let size = values.fileSize,
                      let touched = Self.lastTouched(values),
                      let modDate = values.contentModificationDate else { continue }

                let byteSize = Int64(size)
                guard byteSize >= minSizeBytes,
                      isInstallerCandidate(fileURL, size: byteSize),
                      touched <= cutoffDate,
                      !CleanerWhitelistService.shared.isWhitelisted(path: fileURL.path) else { continue }

                results.append(StaleInstallerItem(
                    name: fileURL.lastPathComponent,
                    url: fileURL,
                    byteSize: byteSize,
                    fileExtension: fileURL.pathExtension,
                    modifiedAt: modDate,
                    isMounted: mountedImages.contains(fileURL.resolvingSymlinksInPath().path)
                ))
            }
        }

        return results.sorted { $0.byteSize > $1.byteSize }
    }

    /// Moves discovered stale installers to the Trash (or deletes them when `moveToTrash` is false).
    /// Returns the bytes freed by what was actually removed.
    @discardableResult
    public func purge(items: [StaleInstallerItem], moveToTrash: Bool = true) async throws -> Int64 {
        let fileManager = FileManager.default
        let mountedImages = mountedImagePaths()
        var totalFreed: Int64 = 0
        var purgedCount = 0
        var firstError: Error?

        for item in items {
            guard !item.isMounted,
                  !mountedImages.contains(item.url.resolvingSymlinksInPath().path),
                  !CleanerWhitelistService.shared.isWhitelisted(path: item.url.path),
                  isUnchangedInstaller(item) else { continue }

            do {
                if moveToTrash {
                    try fileManager.trashItem(at: item.url, resultingItemURL: nil)
                } else {
                    try fileManager.removeItem(at: item.url)
                }
            } catch {
                firstError = firstError ?? error
                continue
            }
            totalFreed += item.byteSize
            purgedCount += 1
        }

        if purgedCount > 0 {
            SystemCleaningHistoryTracker.shared.record(
                operationName: "Installer Purge",
                bytesFreed: totalFreed,
                itemCount: purgedCount
            )
        }
        if let firstError, purgedCount == 0 { throw firstError }
        return totalFreed
    }

    /// The item is still the regular installer file the scan saw: same size, same modification date, no symlink.
    private func isUnchangedInstaller(_ item: StaleInstallerItem) -> Bool {
        // A fresh URL: the item's own one still caches the size and dates it had when it was scanned.
        guard let values = try? URL(fileURLWithPath: item.url.path).resourceValues(forKeys: Self.fileKeys),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize, Int64(size) == item.byteSize,
              let modified = values.contentModificationDate,
              abs(modified.timeIntervalSince(item.modifiedAt)) < 1 else { return false }
        return isInstallerCandidate(item.url, size: item.byteSize)
    }

    private func defaultScanDirectories() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home.appendingPathComponent("Downloads"), home.appendingPathComponent("Desktop")]
    }

    /// Paths of the disk images attached right now, from `hdiutil info`. A volume's name often differs from its
    /// image's file name ("Install Foo" from Foo-1.2.dmg), so the image path is the reliable key.
    private func mountedImagePaths() -> Set<String> {
        guard let result = runCommand("/usr/bin/hdiutil", ["info", "-plist"]), result.status == 0,
              let plist = try? PropertyListSerialization.propertyList(from: Data(result.output.utf8), format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return [] }
        return Set(images.compactMap { ($0["image-path"] as? String).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } })
    }
}
