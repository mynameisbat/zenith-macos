import Foundation

/// Service managing custom user-defined and statutory whitelists,
/// protecting critical directories and applications from deletion across all cleaner modules.
/// Modeled after Mole's `mo whitelist`.
public final class CleanerWhitelistService: @unchecked Sendable {
    public static let shared = CleanerWhitelistService()

    private let queue = DispatchQueue(label: "com.zenith.whitelist", attributes: .concurrent)
    private var paths: Set<String> = []
    private var bundleIds: Set<String> = []
    private let storageURL: URL

    public init(storageURL: URL? = nil) {
        if let custom = storageURL {
            self.storageURL = custom
        } else {
            let configDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config", isDirectory: true)
                .appendingPathComponent("zenith", isDirectory: true)
            try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            self.storageURL = configDir.appendingPathComponent("whitelist.json")
        }
        loadWhitelist()
    }

    /// Checks if a path or any of its parent directories is whitelisted.
    public func isWhitelisted(path: String) -> Bool {
        let normalized = (path as NSString).standardizingPath
        return queue.sync {
            // Statutory Apple Neural Engine & Game Protections
            if normalized.contains("com.apple.e5rt.e5bundlecache") ||
               normalized.contains("Steam/steamapps") ||
               normalized.contains("Epic Games") {
                return true
            }

            for rule in paths {
                let normRule = (rule as NSString).standardizingPath
                if normalized == normRule || normalized.hasPrefix(normRule + "/") {
                    return true
                }
            }
            return false
        }
    }

    /// Checks if a bundle identifier is whitelisted.
    public func isBundleIdWhitelisted(_ bundleId: String) -> Bool {
        let lower = bundleId.lowercased()
        return queue.sync {
            if lower == "com.apple.e5rt.e5bundlecache" { return true }
            return bundleIds.contains(lower)
        }
    }

    /// Adds a directory or file path to the whitelist.
    public func addPath(_ path: String) {
        let normalized = (path as NSString).standardizingPath
        queue.sync(flags: .barrier) {
            self.paths.insert(normalized)
            self.persist()
        }
    }

    /// Removes a path from the whitelist.
    public func removePath(_ path: String) {
        let normalized = (path as NSString).standardizingPath
        queue.sync(flags: .barrier) {
            self.paths.remove(normalized)
            self.persist()
        }
    }

    /// Adds a bundle identifier to the whitelist.
    public func addBundleId(_ bundleId: String) {
        let lower = bundleId.lowercased()
        queue.sync(flags: .barrier) {
            self.bundleIds.insert(lower)
            self.persist()
        }
    }

    /// Removes a bundle identifier from the whitelist.
    public func removeBundleId(_ bundleId: String) {
        let lower = bundleId.lowercased()
        queue.sync(flags: .barrier) {
            self.bundleIds.remove(lower)
            self.persist()
        }
    }

    /// All currently active custom whitelisted paths.
    public var allPaths: [String] {
        queue.sync { Array(paths).sorted() }
    }

    /// All currently active whitelisted bundle IDs.
    public var allBundleIds: [String] {
        queue.sync { Array(bundleIds).sorted() }
    }

    /// Clears custom entries and restores default protection rules.
    public func resetToDefaults() {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            self.paths.removeAll()
            self.bundleIds.removeAll()
            self.persist()
        }
    }

    // MARK: - Persistence

    private func loadWhitelist() {
        guard let data = try? Data(contentsOf: storageURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if let savedPaths = json["paths"] as? [String] {
            self.paths = Set(savedPaths)
        }
        if let savedBundles = json["bundleIds"] as? [String] {
            self.bundleIds = Set(savedBundles)
        }
    }

    private func persist() {
        let dict: [String: Any] = [
            "paths": Array(paths),
            "bundleIds": Array(bundleIds)
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]) {
            try? data.write(to: storageURL, options: .atomic)
        }
    }
}
