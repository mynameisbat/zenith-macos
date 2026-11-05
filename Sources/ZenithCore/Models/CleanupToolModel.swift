import Foundation

/// One thing a cleanup tool offers: a build folder, an installer, an orphaned app folder, a drive's junk files.
public struct CleanupCandidate: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let detail: String
    public let bytes: Int64
    public var isSelected: Bool

    public init(id: String, title: String, detail: String, bytes: Int64, isSelected: Bool = false) {
        self.id = id
        self.title = title
        self.detail = detail
        self.bytes = bytes
        self.isSelected = isSelected
    }
}

/// What the confirmation dialog says before a tool removes anything.
public struct CleanupConfirmation: Sendable, Equatable {
    public let title: String
    public let message: String
    public let actionTitle: String
}

/// The state behind one screen of the Cleaner tab: scan, tick what to remove, confirm, remove.
///
/// The model knows nothing about which service is behind it (see the factories below) and never removes anything
/// itself: `cleanSelected` asks `confirm` first and does nothing when it says no.
@MainActor
public final class CleanupToolModel: ObservableObject, Identifiable {
    public enum Kind: String, CaseIterable, Sendable {
        case projects, installers, leftovers, drives
    }

    public nonisolated let kind: Kind
    public nonisolated let title: String
    public nonisolated let explanation: String
    /// "Move to Trash" for the tools that can; "Delete" where the files are junk that cannot be trashed.
    public nonisolated let actionTitle: String
    public nonisolated let movesToTrash: Bool
    public nonisolated var id: String { kind.rawValue }

    @Published public private(set) var candidates: [CleanupCandidate] = []
    @Published public private(set) var isScanning = false
    @Published public private(set) var isCleaning = false
    @Published public private(set) var hasScanned = false
    @Published public private(set) var status: String?

    private let scanWork: @Sendable () async -> [CleanupCandidate]
    private let cleanWork: @Sendable ([CleanupCandidate]) async throws -> Int64

    public init(
        kind: Kind,
        title: String,
        explanation: String,
        actionTitle: String,
        movesToTrash: Bool,
        scan: @escaping @Sendable () async -> [CleanupCandidate],
        clean: @escaping @Sendable ([CleanupCandidate]) async throws -> Int64
    ) {
        self.kind = kind
        self.title = title
        self.explanation = explanation
        self.actionTitle = actionTitle
        self.movesToTrash = movesToTrash
        self.scanWork = scan
        self.cleanWork = clean
    }

    // MARK: Selection

    public var selectedCandidates: [CleanupCandidate] { candidates.filter(\.isSelected) }
    public var selectedBytes: Int64 { selectedCandidates.reduce(0) { $0 + $1.bytes } }
    public var totalBytes: Int64 { candidates.reduce(0) { $0 + $1.bytes } }

    public func setSelected(_ isSelected: Bool, id: String) {
        guard let index = candidates.firstIndex(where: { $0.id == id }) else { return }
        candidates[index].isSelected = isSelected
    }

    public func selectAll(_ isSelected: Bool) {
        for index in candidates.indices { candidates[index].isSelected = isSelected }
    }

    /// The largest selected items, by name, for the confirmation: what is really about to go.
    public func selectionSummary(limit: Int = 6) -> String {
        let chosen = selectedCandidates.sorted { $0.bytes > $1.bytes }
        var lines = chosen.prefix(limit).map { "• \($0.title) — \(Self.format($0.bytes))" }
        if chosen.count > limit { lines.append("…and \(chosen.count - limit) more") }
        return lines.joined(separator: "\n")
    }

    public func confirmation() -> CleanupConfirmation {
        let count = selectedCandidates.count
        let noun = count == 1 ? "item" : "items"
        if movesToTrash {
            return CleanupConfirmation(
                title: "Move \(count) \(noun) to the Trash?",
                message: "\(Self.format(selectedBytes)) will go to the Trash, where you can still restore it:\n\(selectionSummary())",
                actionTitle: "Move to Trash"
            )
        }
        return CleanupConfirmation(
            title: "Delete the junk files on \(count) \(count == 1 ? "drive" : "drives")?",
            message: "These are deleted for good and cannot be restored:\n\(selectionSummary())",
            actionTitle: "Delete"
        )
    }

    // MARK: Actions

    public func scan() async {
        guard !isScanning, !isCleaning else { return }
        isScanning = true
        status = nil
        let found = await scanWork()
        candidates = found
        hasScanned = true
        isScanning = false
        status = found.isEmpty ? "Nothing to clean here." : "\(found.count) found, \(Self.format(totalBytes)) in all."
    }

    /// Removes the selected candidates after `confirm` agrees. Returns the bytes freed (0 when declined or on failure).
    @discardableResult
    public func cleanSelected(confirm: @MainActor (CleanupConfirmation) -> Bool) async -> Int64 {
        let chosen = selectedCandidates
        guard !chosen.isEmpty, !isScanning, !isCleaning else { return 0 }
        guard confirm(confirmation()) else { return 0 }

        isCleaning = true
        var freed: Int64 = 0
        var failure: String?
        do {
            freed = try await cleanWork(chosen)
        } catch {
            failure = error.localizedDescription
        }
        isCleaning = false

        // What is left is whatever the disk says now, not what was listed before.
        await scan()
        if let failure {
            status = failure
        } else {
            status = "Freed \(Self.format(freed))."
        }
        return freed
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - The four tools

/// Keeps the service's own items, by candidate id, between the scan and the removal.
private final class ItemStore<Item: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Item] = [:]
    func replace(_ new: [String: Item]) { lock.withLock { items = new } }
    func items(for ids: [String]) -> [Item] { lock.withLock { ids.compactMap { items[$0] } } }
}

extension CleanupToolModel {
    private nonisolated static func tilde(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

    /// Build folders (`node_modules`, `target`, `.build`, …) of projects under `roots`.
    @MainActor
    public static func projects(
        service: ProjectPurgeService = .shared,
        roots: @escaping @Sendable () -> [String] = { ProjectPurgeService.defaultSearchRoots() }
    ) -> CleanupToolModel {
        let store = ItemStore<ProjectArtifactItem>()
        return CleanupToolModel(
            kind: .projects,
            title: "Project build folders",
            explanation: "Folders a project rebuilds by itself, such as node_modules, Cargo target and .build. Only projects Zenith recognises are listed, and folders named build, dist, bin or obj only if Git ignores them. Projects touched in the last week are not ticked for you.",
            actionTitle: "Move to Trash",
            movesToTrash: true,
            scan: {
                let summary = await Task.detached { service.scan(customSearchRoots: roots(), minAgeDays: 0) }.value
                store.replace(Dictionary(summary.artifacts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }))
                return summary.artifacts.sorted { $0.sizeBytes > $1.sizeBytes }.map {
                    CleanupCandidate(
                        id: $0.id,
                        title: "\($0.projectName) / \($0.artifactName)",
                        detail: "\(tilde($0.artifactPath)) · untouched \($0.daysSinceModified) days",
                        bytes: $0.sizeBytes,
                        // A project worked on this week is probably open in an editor or being built right now.
                        isSelected: $0.daysSinceModified >= 7
                    )
                }
            },
            clean: { chosen in
                try await Task.detached { try service.purge(artifacts: store.items(for: chosen.map(\.id)), moveToTrash: true) }.value
            }
        )
    }

    /// Old installers (`.dmg`, `.pkg`, `.iso`, `.xip` and large installer `.zip` files) in Downloads and Desktop.
    @MainActor
    public static func installers(service: InstallerPurgeService = .shared, directories: [URL]? = nil) -> CleanupToolModel {
        let store = ItemStore<StaleInstallerItem>()
        return CleanupToolModel(
            kind: .installers,
            title: "Old installers",
            explanation: "Disk images and packages in Downloads and Desktop that nothing has touched for three days. A disk image that is mounted right now is left out.",
            actionTitle: "Move to Trash",
            movesToTrash: true,
            scan: {
                let found = await service.scan(directories: directories).filter { !$0.isMounted }
                store.replace(Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }))
                return found.map {
                    CleanupCandidate(id: $0.id, title: $0.name, detail: tilde($0.url.deletingLastPathComponent().path), bytes: $0.byteSize, isSelected: true)
                }
            },
            clean: { chosen in
                try await service.purge(items: store.items(for: chosen.map(\.id)), moveToTrash: true)
            }
        )
    }

    /// App data in ~/Library whose app is gone. Nothing is ticked: this can be the only copy of someone's data.
    @MainActor
    public static func leftovers(service: OrphanedAppLeftoversService = .shared) -> CleanupToolModel {
        let store = ItemStore<OrphanedAppItem>()
        return CleanupToolModel(
            kind: .leftovers,
            title: "Leftovers of deleted apps",
            explanation: "Folders in your Library named after an app that is no longer installed and that nothing has touched for 30 days. They can hold documents or settings you would want if you reinstall the app, so nothing is ticked for you.",
            actionTitle: "Move to Trash",
            movesToTrash: true,
            scan: {
                let found = await service.scan()
                store.replace(Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }))
                return found.map {
                    CleanupCandidate(
                        id: $0.id,
                        title: $0.appName,
                        detail: "\($0.category) · \(tilde($0.path))" + ($0.category == "Containers" ? " · holds that app's own data, such as saved games" : ""),
                        bytes: $0.byteSize,
                        isSelected: false
                    )
                }
            },
            clean: { chosen in
                try await service.purge(items: store.items(for: chosen.map(\.id)), moveToTrash: true)
            }
        )
    }

    /// Finder and Windows junk (`.DS_Store`, `._*`, `Thumbs.db`, …) on mounted external drives.
    @MainActor
    public static func drives(
        service: ExternalDriveSanitizerService = .shared,
        discover: (@Sendable () -> [ExternalVolumeItem])? = nil
    ) -> CleanupToolModel {
        let store = ItemStore<ExternalVolumeItem>()
        return CleanupToolModel(
            kind: .drives,
            title: "External drive junk",
            explanation: "Hidden metadata files that macOS and Windows scatter on external drives. Your own files are not touched. These files are deleted, not moved to the Trash.",
            actionTitle: "Delete",
            movesToTrash: false,
            scan: {
                let volumes = await Task.detached { discover?() ?? service.discoverExternalVolumes() }.value
                let withJunk = volumes.filter { $0.phantomFileCount > 0 }
                store.replace(Dictionary(withJunk.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }))
                return withJunk.map {
                    CleanupCandidate(id: $0.id, title: $0.name, detail: "\($0.phantomFileCount) junk files", bytes: $0.phantomBytes, isSelected: true)
                }
            },
            clean: { chosen in
                var freed: Int64 = 0
                for volume in store.items(for: chosen.map(\.id)) {
                    freed += try await service.sanitize(volumeURL: volume.url).freedBytes
                }
                return freed
            }
        )
    }
}

// MARK: - Where projects are searched

/// The folders Zenith looks in for projects: the usual ones (`~/Projects`, `~/Code`, …) and any the user added.
public enum ProjectSearchRoots {
    static let defaultsKey = "zenith.projectSearchRoots"

    public static func custom(defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: defaultsKey) ?? []
    }

    /// The usual folders followed by the user's own, without repeats.
    public static func current(defaults: UserDefaults = .standard, home: String = NSHomeDirectory()) -> [String] {
        var seen = Set<String>()
        return (ProjectPurgeService.defaultSearchRoots(home: home) + custom(defaults: defaults)).filter { seen.insert($0).inserted }
    }

    public static func add(_ path: String, defaults: UserDefaults = .standard) {
        let standardized = (path as NSString).standardizingPath
        var roots = custom(defaults: defaults)
        guard !roots.contains(standardized) else { return }
        roots.append(standardized)
        defaults.set(roots, forKey: defaultsKey)
    }

    public static func remove(_ path: String, defaults: UserDefaults = .standard) {
        defaults.set(custom(defaults: defaults).filter { $0 != path }, forKey: defaultsKey)
    }
}

/// What the project tool's "Folders searched" list shows and changes.
@MainActor
public final class ProjectSearchRootsModel: ObservableObject {
    @Published public private(set) var custom: [String]
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.custom = ProjectSearchRoots.custom(defaults: defaults)
    }

    public func add(_ path: String) {
        ProjectSearchRoots.add(path, defaults: defaults)
        custom = ProjectSearchRoots.custom(defaults: defaults)
    }

    public func remove(_ path: String) {
        ProjectSearchRoots.remove(path, defaults: defaults)
        custom = ProjectSearchRoots.custom(defaults: defaults)
    }
}

/// The four tools, created once so a scan survives switching tabs in Settings.
@MainActor
public final class CleanupTools {
    public static let shared = CleanupTools()

    public let projectRoots = ProjectSearchRootsModel()
    public let projects = CleanupToolModel.projects(roots: { ProjectSearchRoots.current() })
    public let installers = CleanupToolModel.installers()
    public let leftovers = CleanupToolModel.leftovers()
    public let drives = CleanupToolModel.drives()

    public var all: [CleanupToolModel] { [projects, installers, leftovers, drives] }

    private init() {}
}
