import AppKit
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
///
/// What is offered is deliberately narrow, because these folders can hold data that cannot be rebuilt (a sandboxed
/// app's documents, a Docker VM disk, a browser profile):
///   - only entries named like a bundle identifier (`com.vendor.app`). A plain name such as "Google" or "JetBrains"
///     cannot be tied to one app, and is the vendor folder of Chrome profiles and IDE settings, so it is never offered;
///   - never when Launch Services still knows the app, it is running, or another installed app comes from the same
///     vendor (updaters and helpers share the vendor prefix);
///   - never when anything inside was changed recently (`minIdleDays`): an app on an unplugged drive or a network
///     volume looks "not installed", but it has been used lately;
///   - `purge` re-checks all of this, so a stale or hand-made item list cannot reach anything else.
public final class OrphanedAppLeftoversService: @unchecked Sendable {
    public static let shared = OrphanedAppLeftoversService()

    /// Bundle identifier prefixes that are never offered, whatever else is true.
    static let protectedPrefixes = ["com.apple.", "group.com.apple.", "com.docker."]

    private let locations: [(url: URL, category: String)]
    private let applicationRoots: [URL]
    private let isBundleIdentifierInUse: @Sendable (String) -> Bool
    private let minIdleDays: Int
    private let trashMover: TrashMover

    /// - Parameters:
    ///   - homeDirectory: Whose `Library` is scanned; tests pass a throwaway one.
    ///   - locations: Folders to look in, with a display category; defaults to the usual spots under `homeDirectory`.
    ///   - applicationRoots: Folders searched (a few levels deep) for installed apps.
    ///   - isBundleIdentifierInUse: Whether the system knows or is running an app with this identifier.
    ///   - minIdleDays: Anything touched more recently than this is left alone.
    ///   - trashMover: How an item is moved to the Trash (retried through Finder where macOS refuses the app).
    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        locations: [(url: URL, category: String)]? = nil,
        applicationRoots: [URL]? = nil,
        isBundleIdentifierInUse: @escaping @Sendable (String) -> Bool = OrphanedAppLeftoversService.systemKnowsApp,
        minIdleDays: Int = 30,
        trashMover: TrashMover = .system
    ) {
        self.trashMover = trashMover
        self.locations = locations ?? [
            (homeDirectory.appendingPathComponent("Library/Application Support"), "Application Support"),
            (homeDirectory.appendingPathComponent("Library/Caches"), "Caches"),
            (homeDirectory.appendingPathComponent("Library/Containers"), "Containers"),
            (homeDirectory.appendingPathComponent("Library/Saved Application State"), "Saved State"),
            (homeDirectory.appendingPathComponent("Library/WebKit"), "WebKit")
        ]
        self.applicationRoots = applicationRoots ?? [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Cryptexes/App/System/Applications"),
            homeDirectory.appendingPathComponent("Applications")
        ]
        self.isBundleIdentifierInUse = isBundleIdentifierInUse
        self.minIdleDays = minIdleDays
    }

    /// True if Launch Services can locate an app with this identifier, or one is running right now.
    public static let systemKnowsApp: @Sendable (String) -> Bool = { identifier in
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) != nil
            || !NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty
    }

    /// Scans the user Library for residue belonging to apps that are no longer installed.
    public func scan() async -> [OrphanedAppItem] {
        let installed = installedBundleIdentifiers()
        let cutoff = Calendar.current.date(byAdding: .day, value: -minIdleDays, to: Date()) ?? Date()
        var orphans: [OrphanedAppItem] = []

        for location in locations {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: location.url, includingPropertiesForKeys: nil
            ) else { continue }

            for itemURL in contents {
                guard let identifier = orphanIdentifier(at: itemURL, installed: installed) else { continue }

                let metrics = calculateDirectoryMetrics(url: itemURL)
                guard metrics.size > 1024 else { continue } // Ignore empty 0-byte placeholders
                guard metrics.newest <= cutoff else { continue }

                orphans.append(OrphanedAppItem(
                    appName: extractCleanAppName(from: itemURL.lastPathComponent),
                    bundleId: identifier,
                    path: itemURL.path,
                    byteSize: metrics.size,
                    fileCount: metrics.count,
                    category: location.category
                ))
            }
        }

        return orphans.sorted { $0.byteSize > $1.byteSize }
    }

    /// Trashes (or, if asked, deletes) discovered leftovers. Each item is checked again first, so an item that has
    /// since been touched, whose app came back, or that was never a direct child of a scanned folder is skipped.
    @discardableResult
    public func purge(items: [OrphanedAppItem], moveToTrash: Bool = true) async throws -> Int64 {
        let fileManager = FileManager.default
        let installed = installedBundleIdentifiers()
        let cutoff = Calendar.current.date(byAdding: .day, value: -minIdleDays, to: Date()) ?? Date()
        let allowedParents = Set(locations.map { $0.url.resolvingSymlinksInPath().path })

        var totalFreed: Int64 = 0
        var purgedCount = 0
        var failures: [(name: String, reason: String)] = []

        for item in items {
            let url = URL(fileURLWithPath: item.path)
            guard allowedParents.contains(url.deletingLastPathComponent().resolvingSymlinksInPath().path),
                  orphanIdentifier(at: url, installed: installed) != nil,
                  calculateDirectoryMetrics(url: url).newest <= cutoff else { continue }

            do {
                if moveToTrash {
                    try trashMover.move(url)
                } else {
                    try fileManager.removeItem(at: url)
                }
            } catch {
                failures.append((name: url.lastPathComponent, reason: error.localizedDescription))
                continue
            }
            totalFreed += item.byteSize
            purgedCount += 1
        }

        if purgedCount > 0 {
            SystemCleaningHistoryTracker.shared.record(
                operationName: "Orphaned App Leftovers",
                bytesFreed: totalFreed,
                itemCount: purgedCount
            )
        }
        if let first = failures.first {
            throw PurgeError.someFailed(moved: purgedCount, failed: failures.count, firstReason: first.reason)
        }
        return totalFreed
    }

    /// Some items could not be removed. What did go is already gone and recorded.
    public enum PurgeError: Error, LocalizedError, Equatable {
        case someFailed(moved: Int, failed: Int, firstReason: String)

        public var errorDescription: String? {
            switch self {
            case .someFailed(let moved, let failed, let reason):
                let done = moved > 0 ? "\(moved) moved. " : ""
                return "\(done)\(failed) could not be moved. \(reason)"
            }
        }
    }

    // MARK: - Helpers

    /// The bundle identifier this entry would belong to if it is a leftover, or `nil` if it must be left alone.
    private func orphanIdentifier(at url: URL, installed: InstalledIndex) -> String? {
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values?.isSymbolicLink != true else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard !CleanerWhitelistService.shared.isWhitelisted(path: url.path) else { return nil }

        guard let identifier = Self.bundleIdentifier(fromEntryName: url.lastPathComponent) else { return nil }
        let lower = identifier.lowercased()
        guard !Self.protectedPrefixes.contains(where: { lower.hasPrefix($0) }) else { return nil }

        // Same app, a helper or extension of it (com.spotify.client.helper), or a sibling from the same vendor.
        guard !installed.identifiers.contains(where: { lower == $0 || lower.hasPrefix($0 + ".") }) else { return nil }
        guard !installed.vendors.contains(Self.vendor(of: lower)) else { return nil }
        guard !isBundleIdentifierInUse(identifier) else { return nil }
        return identifier
    }

    /// `com.vendor.app` out of `com.vendor.app.savedState`; `nil` for names that are not bundle identifiers.
    static func bundleIdentifier(fromEntryName name: String) -> String? {
        var candidate = name
        if candidate.hasSuffix(".savedState") { candidate = String(candidate.dropLast(".savedState".count)) }
        let parts = candidate.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        for part in parts {
            guard !part.isEmpty, part.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        }
        return candidate
    }

    /// The first two components of a lowercased identifier, ignoring a leading `group.`.
    static func vendor(of lowerIdentifier: String) -> String {
        var parts = lowerIdentifier.split(separator: ".").map(String.init)
        if parts.first == "group" { parts.removeFirst() }
        return parts.prefix(2).joined(separator: ".")
    }

    private struct InstalledIndex {
        var identifiers: Set<String> = []
        var vendors: Set<String> = []
    }

    /// Identifiers of the apps found under `applicationRoots`, looking inside folders such as `Utilities`.
    private func installedBundleIdentifiers() -> InstalledIndex {
        var index = InstalledIndex()
        for root in applicationRoots {
            collectApps(in: root, depth: 0, into: &index)
        }
        return index
    }

    private func collectApps(in directory: URL, depth: Int, into index: inout InstalledIndex) {
        guard depth < 4,
              let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for url in contents {
            if url.pathExtension.lowercased() == "app" {
                if let identifier = Bundle(url: url)?.bundleIdentifier?.lowercased() {
                    index.identifiers.insert(identifier)
                    index.vendors.insert(Self.vendor(of: identifier))
                }
            } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                collectApps(in: url, depth: depth + 1, into: &index)
            }
        }
    }

    private func extractCleanAppName(from folderName: String) -> String {
        let clean = Self.bundleIdentifier(fromEntryName: folderName) ?? folderName
        if let last = clean.split(separator: ".").last, last.count >= 2 {
            return last.capitalized
        }
        return clean
    }

    /// Total size and file count of everything inside, and the most recent modification date of any of it.
    private func calculateDirectoryMetrics(url: URL) -> (size: Int64, count: Int, newest: Date) {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey]
        var newest = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        ) else { return (0, 0, newest) }

        var totalSize: Int64 = 0
        var totalCount: Int = 0

        while let fileURL = enumerator.nextObject() as? URL {
            guard let vals = try? fileURL.resourceValues(forKeys: Set(keys)) else { continue }
            if let modified = vals.contentModificationDate, modified > newest { newest = modified }
            guard vals.isRegularFile == true, let size = vals.fileSize else { continue }
            totalSize += Int64(size)
            totalCount += 1
        }

        return (totalSize, totalCount, newest)
    }
}
