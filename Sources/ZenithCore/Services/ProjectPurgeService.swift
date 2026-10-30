import Foundation

/// Known rebuildable project artifact directories.
public enum PurgeArtifactType: String, CaseIterable, Sendable, Equatable {
    case nodeModules = "node_modules"
    case target = "target"
    case build = "build"
    case dist = "dist"
    case dotBuild = ".build"
    case venv = "venv"
    case dotVenv = ".venv"
    case pycache = "__pycache__"
    case pytestCache = ".pytest_cache"
    case next = ".next"
    case nuxt = ".nuxt"
    case turbo = ".turbo"
    case derivedData = "DerivedData"
    case pods = "Pods"
    case dartTool = ".dart_tool"
    case bin = "bin"
    case obj = "obj"

    public var title: String {
        switch self {
        case .nodeModules: return "Node Modules (JS/TS)"
        case .target: return "Cargo / Rust Target"
        case .build, .dist: return "Build & Distribution"
        case .dotBuild: return "Swift Package Build"
        case .venv, .dotVenv: return "Python Virtualenv"
        case .pycache, .pytestCache: return "Python Bytecode & Test Cache"
        case .next, .nuxt, .turbo: return "Modern Web Framework Cache"
        case .derivedData, .pods: return "Xcode DerivedData & CocoaPods"
        case .dartTool: return "Flutter / Dart Tool Cache"
        case .bin, .obj: return ".NET / C# Build Artifacts"
        }
    }
}

extension PurgeArtifactType {
    /// Files in the project folder showing that the project's own tooling rebuilds this folder. Entries starting with
    /// `*.` match by suffix. A `bin` next to a `package.json` is somebody's scripts, not a build output.
    var projectMarkers: [String] {
        switch self {
        case .nodeModules, .next, .nuxt, .turbo:
            return ["package.json"]
        case .target:
            return ["Cargo.toml", "pom.xml"]
        case .build:
            return ["package.json", "build.gradle", "build.gradle.kts", "pyproject.toml", "setup.py", "pubspec.yaml"]
        case .dist:
            return ["package.json", "pyproject.toml", "setup.py"]
        case .dotBuild:
            return ["Package.swift"]
        case .venv, .dotVenv, .pycache, .pytestCache:
            return ["requirements.txt", "pyproject.toml", "setup.py", "Pipfile"]
        case .derivedData:
            return ["*.xcodeproj", "*.xcworkspace", "Package.swift"]
        case .pods:
            return ["Podfile"]
        case .dartTool:
            return ["pubspec.yaml"]
        case .bin, .obj:
            return ["*.csproj", "*.fsproj", "*.vbproj", "*.sln"]
        }
    }

    /// Names that projects also use for files they commit: scripts in `bin`, hand-written assets in `build`/`dist`.
    /// These are only offered when git says the folder is ignored (so it holds no committed content).
    var isAmbiguous: Bool {
        switch self {
        case .build, .dist, .bin, .obj: return true
        default: return false
        }
    }
}

public enum ProjectPurgeError: Error, LocalizedError, Equatable {
    /// Some folders could not be removed; `freedBytes` is what the others released.
    case someItemsFailed(paths: [String], freedBytes: Int64)

    public var errorDescription: String? {
        switch self {
        case .someItemsFailed(let paths, _):
            return "\(paths.count) folder\(paths.count == 1 ? "" : "s") could not be removed."
        }
    }
}

/// A discovered project artifact directory eligible for purging.
public struct ProjectArtifactItem: Identifiable, Sendable, Equatable {
    public let id: String
    public let projectName: String
    public let projectPath: String
    public let artifactName: String
    public let artifactPath: String
    public let sizeBytes: Int64
    public let lastModified: Date
    public let daysSinceModified: Int

    public init(
        projectName: String,
        projectPath: String,
        artifactName: String,
        artifactPath: String,
        sizeBytes: Int64,
        lastModified: Date = Date(),
        daysSinceModified: Int = 0
    ) {
        self.id = artifactPath
        self.projectName = projectName
        self.projectPath = projectPath
        self.artifactName = artifactName
        self.artifactPath = artifactPath
        self.sizeBytes = sizeBytes
        self.lastModified = lastModified
        self.daysSinceModified = daysSinceModified
    }
}

/// Summary of all discovered project artifacts and total reclaimable space.
public struct ProjectPurgeSummary: Sendable, Equatable {
    public let searchRoots: [String]
    public let totalProjectsFound: Int
    public let artifacts: [ProjectArtifactItem]
    public let totalReclaimableBytes: Int64

    public init(
        searchRoots: [String],
        totalProjectsFound: Int,
        artifacts: [ProjectArtifactItem]
    ) {
        self.searchRoots = searchRoots
        self.totalProjectsFound = totalProjectsFound
        self.artifacts = artifacts
        self.totalReclaimableBytes = artifacts.reduce(0) { $0 + $1.sizeBytes }
    }
}

/// Service providing discovery and purging of heavy, regenerable development
/// project artifacts (node_modules, target, .build, .venv, etc.).
public final class ProjectPurgeService: @unchecked Sendable {
    public static let shared = ProjectPurgeService()

    private let fileManager: FileManager

    // Project indicator markers
    private static let projectIndicators: Set<String> = [
        "package.json",
        "Cargo.toml",
        "Package.swift",
        "go.mod",
        "pom.xml",
        "requirements.txt",
        "pyproject.toml",
        "pubspec.yaml",
        "composer.json",
        "build.gradle",
        "build.gradle.kts",
        "setup.py",
        "Pipfile",
        "Podfile"
    ]

    /// Project files recognised by extension rather than by name.
    private static let projectIndicatorSuffixes = [".xcodeproj", ".xcworkspace", ".sln", ".csproj", ".fsproj", ".vbproj"]

    private let runner: SystemCommandRunner
    private let homeOverride: String?

    /// - Parameters:
    ///   - homeDirectory: The home directory folders must be inside to be purged; the current user's when `nil`.
    ///   - runner: Runs `git` to learn whether a folder is ignored; tests substitute a fake.
    public init(
        fileManager: FileManager = .default,
        homeDirectory: String? = nil,
        runner: @escaping SystemCommandRunner = SystemCommand.processRunner
    ) {
        self.fileManager = fileManager
        self.homeOverride = homeDirectory
        self.runner = runner
    }

    /// Whether `type` is a regenerable artifact of the project at `projectPath`, judged by the project's own files and,
    /// for names that are also used for committed content, by git.
    func isEligible(_ type: PurgeArtifactType, projectPath: String, projectContents: [String]) -> Bool {
        let hasMarker = type.projectMarkers.contains { marker in
            if marker.hasPrefix("*.") {
                let suffix = String(marker.dropFirst())
                return projectContents.contains { $0.hasSuffix(suffix) }
            }
            return projectContents.contains(marker)
        }
        guard hasMarker else { return false }
        guard type.isAmbiguous else { return true }
        // Exit status 0 means "ignored"; 1 "not ignored"; anything else (no git, not a repository) is not enough.
        return runner("/usr/bin/git", ["-C", projectPath, "check-ignore", "-q", "--", type.rawValue])?.status == 0
    }

    /// Returns standard development workspace search roots for the current user.
    public static func defaultSearchRoots(home: String = NSHomeDirectory()) -> [String] {
        return [
            "\(home)/Projects",
            "\(home)/dev",
            "\(home)/Code",
            "\(home)/RiderProjects",
            "\(home)/GitHub",
            "\(home)/workspace",
            "\(home)/Documents"
        ]
    }

    // MARK: - Scanning

    /// Scans search roots for projects and their heavy artifact directories.
    public func scan(
        customSearchRoots: [String]? = nil,
        minAgeDays: Int = 0,
        maxDepth: Int = 4
    ) -> ProjectPurgeSummary {
        let home = NSHomeDirectory()
        let rootsToScan = (customSearchRoots ?? Self.defaultSearchRoots(home: home)).filter {
            fileManager.fileExists(atPath: $0)
        }

        var discoveredArtifacts: [ProjectArtifactItem] = []
        var projectPathsSeen = Set<String>()

        for root in rootsToScan {
            scanDirectory(
                currentPath: root,
                depth: 0,
                maxDepth: maxDepth,
                minAgeDays: minAgeDays,
                projectPathsSeen: &projectPathsSeen,
                artifacts: &discoveredArtifacts
            )
        }

        return ProjectPurgeSummary(
            searchRoots: rootsToScan,
            totalProjectsFound: projectPathsSeen.count,
            artifacts: discoveredArtifacts
        )
    }

    private static let ignoredSystemDirectories: Set<String> = [
        "Library",
        "Applications",
        ".git"
    ]

    private func scanDirectory(
        currentPath: String,
        depth: Int,
        maxDepth: Int,
        minAgeDays: Int,
        projectPathsSeen: inout Set<String>,
        artifacts: inout [ProjectArtifactItem]
    ) {
        guard depth <= maxDepth else { return }

        // Skip system directories and applications
        let baseName = (currentPath as NSString).lastPathComponent
        if Self.ignoredSystemDirectories.contains(baseName) {
            return
        }

        guard let contents = try? fileManager.contentsOfDirectory(atPath: currentPath) else {
            return
        }

        let contentsSet = Set(contents)
        let isProject = !contentsSet.isDisjoint(with: Self.projectIndicators) ||
            contents.contains(where: { name in Self.projectIndicatorSuffixes.contains { name.hasSuffix($0) } })

        if isProject {
            projectPathsSeen.insert(currentPath)
            let projectName = baseName

            // Check for known artifact folders inside this project
            for artifactType in PurgeArtifactType.allCases {
                let artifactFolder = artifactType.rawValue
                if contentsSet.contains(artifactFolder),
                   isEligible(artifactType, projectPath: currentPath, projectContents: contents) {
                    let fullArtifactPath = "\(currentPath)/\(artifactFolder)"
                    var isDir: ObjCBool = false
                    if fileManager.fileExists(atPath: fullArtifactPath, isDirectory: &isDir), isDir.boolValue {
                        // Check last modified date
                        var statBuf = stat()
                        // A symlinked folder is not offered: its size would be the target's, and removing it frees nothing.
                        if lstat(fullArtifactPath, &statBuf) == 0, (statBuf.st_mode & S_IFMT) != S_IFLNK {
                            let modTime = Date(timeIntervalSince1970: TimeInterval(statBuf.st_mtimespec.tv_sec))
                            let daysOld = Calendar.current.dateComponents([.day], from: modTime, to: Date()).day ?? 0

                            if daysOld >= minAgeDays {
                                let size = calculateSize(of: fullArtifactPath)
                                if size > 0 {
                                    artifacts.append(ProjectArtifactItem(
                                        projectName: projectName,
                                        projectPath: currentPath,
                                        artifactName: artifactFolder,
                                        artifactPath: fullArtifactPath,
                                        sizeBytes: size,
                                        lastModified: modTime,
                                        daysSinceModified: daysOld
                                    ))
                                }
                            }
                        }
                    }
                }
            }
        }

        // Recurse into subdirectories (skip known artifact directories to prevent deep traversal)
        let artifactNamesSet = Set(PurgeArtifactType.allCases.map { $0.rawValue })
        for item in contents where !item.hasPrefix(".") {
            if artifactNamesSet.contains(item) { continue }
            let subPath = "\(currentPath)/\(item)"
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: subPath, isDirectory: &isDir), isDir.boolValue {
                scanDirectory(
                    currentPath: subPath,
                    depth: depth + 1,
                    maxDepth: maxDepth,
                    minAgeDays: minAgeDays,
                    projectPathsSeen: &projectPathsSeen,
                    artifacts: &artifacts
                )
            }
        }
    }

    // MARK: - Purging Execution

    /// Purges the selected project artifact folders and records metrics in history tracker.
    ///
    /// Each folder is checked again right before it goes: the project may have changed since the scan. A folder that
    /// cannot be removed does not stop the others; they are reported together once the rest are done.
    @discardableResult
    public func purge(
        artifacts: [ProjectArtifactItem],
        moveToTrash: Bool = true
    ) throws -> Int64 {
        var totalFreed: Int64 = 0
        var failedPaths: [String] = []

        for item in artifacts {
            guard isPathSafeForPurge(item.artifactPath, home: homeOverride ?? NSHomeDirectory()), isStillPurgeable(item) else { continue }
            let url = URL(fileURLWithPath: item.artifactPath)
            do {
                if moveToTrash {
                    try fileManager.trashItem(at: url, resultingItemURL: nil)
                } else {
                    try fileManager.removeItem(at: url)
                }
                totalFreed += item.sizeBytes
            } catch {
                failedPaths.append(item.artifactPath)
            }
        }

        if totalFreed > 0 {
            SystemCleaningHistoryTracker.shared.record(
                operationName: "Project Build Artifacts",
                bytesFreed: totalFreed,
                itemCount: artifacts.count - failedPaths.count
            )
        }

        if !failedPaths.isEmpty {
            throw ProjectPurgeError.someItemsFailed(paths: failedPaths, freedBytes: totalFreed)
        }
        return totalFreed
    }

    private func isStillPurgeable(_ item: ProjectArtifactItem) -> Bool {
        guard let type = PurgeArtifactType(rawValue: (item.artifactPath as NSString).lastPathComponent) else { return false }
        let parent = (item.artifactPath as NSString).deletingLastPathComponent
        guard let contents = try? fileManager.contentsOfDirectory(atPath: parent) else { return false }
        return isEligible(type, projectPath: parent, projectContents: contents)
    }

    // MARK: - Safety Invariants

    /// Validates that a path is safe for purging (must be inside user's home,
    /// cannot be a system root, and its last path component must match a known artifact).
    public func isPathSafeForPurge(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        let canonical = (path as NSString).standardizingPath
        let homeCanonical = (home as NSString).standardizingPath

        guard canonical.hasPrefix(homeCanonical + "/") else {
            return false
        }

        // Must not be user home or critical library roots
        if canonical == homeCanonical ||
           canonical == "\(homeCanonical)/Desktop" ||
           canonical == "\(homeCanonical)/Documents" ||
           canonical == "\(homeCanonical)/Downloads" ||
           canonical.hasPrefix("\(homeCanonical)/Library") {
            return false
        }

        // Custom user and statutory whitelist
        if CleanerWhitelistService.shared.isWhitelisted(path: canonical) {
            return false
        }

        // Last component must strictly be a known artifact directory name
        let lastComp = (canonical as NSString).lastPathComponent
        guard PurgeArtifactType.allCases.contains(where: { $0.rawValue == lastComp }) else {
            return false
        }

        return true
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
