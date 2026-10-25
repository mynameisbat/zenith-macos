import Foundation

/// Discovered heavy storage footprint category.
public struct HeavyStorageCategory: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let iconName: String
    public let url: URL
    public let byteSize: Int64
    public let itemCount: Int
    public let subtitle: String
    public let canPurgeSafely: Bool

    public init(
        id: String,
        name: String,
        iconName: String,
        url: URL,
        byteSize: Int64,
        itemCount: Int,
        subtitle: String,
        canPurgeSafely: Bool = true
    ) {
        self.id = id
        self.name = name
        self.iconName = iconName
        self.url = url
        self.byteSize = byteSize
        self.itemCount = itemCount
        self.subtitle = subtitle
        self.canPurgeSafely = canPurgeSafely
    }
}

/// Service that discovers massive silent storage consumers on macOS
/// (iOS local backups, Xcode simulator runtimes, Android AVD emulators, Mail downloads),
/// modeled after Mole's `mo analyze` insight engine.
public final class HeavyStorageInsightService: @unchecked Sendable {
    public static let shared = HeavyStorageInsightService()

    public init() {}

    /// Scans known heavy macOS storage locations.
    public func scan(
        customTargets: [(id: String, name: String, icon: String, url: URL, subtitle: String)]? = nil,
        minSizeBytes: Int64 = 10 * 1024 * 1024
    ) async -> [HeavyStorageCategory] {
        let home = FileManager.default.homeDirectoryForCurrentUser

        let targets: [(id: String, name: String, icon: String, url: URL, subtitle: String)] = customTargets ?? [
            (
                id: "ios_backups",
                name: "iOS Device Backups",
                icon: "iphone.gen3",
                url: home.appendingPathComponent("Library/Application Support/MobileSync/Backup"),
                subtitle: "Local iPhone & iPad Finder backups"
            ),
            (
                id: "xcode_simulators",
                name: "Xcode Simulator Devices",
                icon: "hammer.fill",
                url: home.appendingPathComponent("Library/Developer/CoreSimulator/Devices"),
                subtitle: "iOS, watchOS, and tvOS test simulator runtimes"
            ),
            (
                id: "android_avd",
                name: "Android Virtual Devices",
                icon: "candybarphone",
                url: home.appendingPathComponent(".android/avd"),
                subtitle: "Android Studio emulator disk images (.qcow2, .img)"
            ),
            (
                id: "mail_downloads",
                name: "Mail Attachments",
                icon: "envelope.fill",
                url: home.appendingPathComponent("Library/Containers/com.apple.mail/Data/Library/Mail Downloads"),
                subtitle: "Cached local downloads from Apple Mail attachments"
            )
        ]

        var categories: [HeavyStorageCategory] = []
        let fileManager = FileManager.default

        for target in targets {
            guard fileManager.fileExists(atPath: target.url.path) else { continue }
            let (size, count) = calculateDirectoryMetrics(url: target.url)

            if size >= minSizeBytes { // Only surface if exceeds threshold
                categories.append(HeavyStorageCategory(
                    id: target.id,
                    name: target.name,
                    iconName: target.icon,
                    url: target.url,
                    byteSize: size,
                    itemCount: count,
                    subtitle: target.subtitle
                ))
            }
        }

        return categories.sorted { $0.byteSize > $1.byteSize }
    }

    /// Purges all items within a heavy storage category.
    @discardableResult
    public func purgeCategory(_ category: HeavyStorageCategory, moveToTrash: Bool = true) async throws -> Int64 {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: category.url.path) else { return 0 }

        if CleanerWhitelistService.shared.isWhitelisted(path: category.url.path) {
            return 0
        }

        let contents = (try? fileManager.contentsOfDirectory(at: category.url, includingPropertiesForKeys: nil)) ?? []
        var freed: Int64 = 0

        for itemURL in contents {
            if CleanerWhitelistService.shared.isWhitelisted(path: itemURL.path) {
                continue
            }

            if moveToTrash {
                try fileManager.trashItem(at: itemURL, resultingItemURL: nil)
            } else {
                try fileManager.removeItem(at: itemURL)
            }
            freed += 1
        }

        let totalFreed = category.byteSize
        if totalFreed > 0 {
            SystemCleaningHistoryTracker.shared.record(
                operationName: "Heavy Insights (\(category.name))",
                bytesFreed: totalFreed,
                itemCount: category.itemCount
            )
        }

        return totalFreed
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
