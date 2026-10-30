import Foundation
import AppKit

/// Metadata for a universal Mach-O architecture slice.
public struct MachOSliceInfo: Sendable, Equatable {
    public let cpuType: UInt32
    public let size: UInt32
    public let archName: String

    public init(cpuType: UInt32, size: UInt32, archName: String) {
        self.cpuType = cpuType
        self.size = size
        self.archName = archName
    }
}

/// Metadata for an individual binary eligible for architecture slimming.
public struct SlimmableBinary: Identifiable, Sendable, Equatable {
    public let id: String
    public let path: String
    public let name: String
    public let totalSizeBytes: Int64
    public let intelSizeBytes: Int64
    public let architectures: [String]
    public let isUniversal: Bool

    public init(
        id: String? = nil,
        path: String,
        name: String,
        totalSizeBytes: Int64,
        intelSizeBytes: Int64,
        architectures: [String],
        isUniversal: Bool
    ) {
        self.id = id ?? path
        self.path = path
        self.name = name
        self.totalSizeBytes = totalSizeBytes
        self.intelSizeBytes = intelSizeBytes
        self.architectures = architectures
        self.isUniversal = isUniversal
    }
}

/// A comprehensive plan representing an application bundle and its universal Mach-O binaries.
public struct SlimmableAppPlan: Identifiable, Sendable, Equatable {
    public let id: String
    public let appPath: String
    public let appName: String
    public let binaries: [SlimmableBinary]
    public let totalAppSizeBytes: Int64
    public let reclaimableIntelBytes: Int64

    public init(
        appPath: String,
        appName: String,
        binaries: [SlimmableBinary],
        totalAppSizeBytes: Int64,
        reclaimableIntelBytes: Int64
    ) {
        self.id = appPath
        self.appPath = appPath
        self.appName = appName
        self.binaries = binaries
        self.totalAppSizeBytes = totalAppSizeBytes
        self.reclaimableIntelBytes = reclaimableIntelBytes
    }
}

/// Universal Binary Slimming Service for Apple Silicon.
/// Detects Mach-O universal binaries containing redundant x86_64 slices,
/// extracts the native arm64 slice, and re-signs the bundle.
public final class BinarySlimmerService: @unchecked Sendable {
    public static let shared = BinarySlimmerService()

    private let fileManager: FileManager
    private let runner: SystemCommandRunner
    private let isApplicationRunning: @Sendable (String) -> Bool
    private let disposeBackup: @Sendable (URL) throws -> Void
    private let historyTracker: SystemCleaningHistoryTracker

    // Mach-O constants
    private static let FAT_MAGIC: UInt32 = 0xCAFEBABE
    private static let FAT_CIGAM: UInt32 = 0xBEBAFECA
    private static let CPU_TYPE_X86_64: UInt32 = 0x01000007
    private static let CPU_TYPE_ARM64: UInt32 = 0x0100000C

    /// - Parameters:
    ///   - runner: Runs `lipo` / `codesign`; tests substitute a fake.
    ///   - isApplicationRunning: Whether the app bundle at the given path is currently running.
    ///   - disposeBackup: Gets rid of the original bundle once the slimmed one is in place (default: the Trash).
    public init(
        fileManager: FileManager = .default,
        runner: @escaping SystemCommandRunner = SystemCommand.processRunner,
        isApplicationRunning: @escaping @Sendable (String) -> Bool = BinarySlimmerService.isBundleRunning,
        disposeBackup: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
        historyTracker: SystemCleaningHistoryTracker = .shared
    ) {
        self.fileManager = fileManager
        self.runner = runner
        self.isApplicationRunning = isApplicationRunning
        self.disposeBackup = disposeBackup
        self.historyTracker = historyTracker
    }

    /// True when an app bundle at `path` is currently running.
    public static let isBundleRunning: @Sendable (String) -> Bool = { path in
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        return NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.standardizedFileURL.path == target }
    }

    // MARK: - Scanning

    /// Scans an application bundle and identifies all universal Mach-O binaries.
    public func scanApp(atPath appPath: String) -> SlimmableAppPlan? {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: appPath, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }

        // Safety: System apps are protected
        if isProtectedSystemApp(atPath: appPath) {
            return nil
        }

        let appName = (appPath as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
        var candidates: [String] = []

        // 1. Main executable(s) in Contents/MacOS
        let macOsDir = "\(appPath)/Contents/MacOS"
        if let contents = try? fileManager.contentsOfDirectory(atPath: macOsDir) {
            for f in contents {
                candidates.append("\(macOsDir)/\(f)")
            }
        }

        // 2. Frameworks and dynamic libraries in Contents/Frameworks
        let frameworksDir = "\(appPath)/Contents/Frameworks"
        if let enumerator = fileManager.enumerator(at: URL(fileURLWithPath: frameworksDir), includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator {
                let p = fileURL.path
                if fileURL.pathExtension.isEmpty || fileURL.pathExtension == "dylib" {
                    candidates.append(p)
                }
            }
        }

        var slimmableBinaries: [SlimmableBinary] = []
        var totalIntelBytes: Int64 = 0

        for path in candidates {
            if let bin = inspectBinary(atPath: path), bin.isUniversal {
                slimmableBinaries.append(bin)
                totalIntelBytes += bin.intelSizeBytes
            }
        }

        guard !slimmableBinaries.isEmpty else { return nil }

        let totalAppSize = calculateSize(of: appPath)
        return SlimmableAppPlan(
            appPath: appPath,
            appName: appName,
            binaries: slimmableBinaries,
            totalAppSizeBytes: totalAppSize,
            reclaimableIntelBytes: totalIntelBytes
        )
    }

    /// Inspects a binary file's Mach-O header to detect fat architectures.
    public func inspectBinary(atPath path: String) -> SlimmableBinary? {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
            return nil
        }

        // Skip symlinks
        var statBuf = stat()
        if lstat(path, &statBuf) == 0 && (statBuf.st_mode & S_IFMT) == S_IFLNK {
            return nil
        }

        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return nil
        }
        defer { try? handle.close() }

        let headerData = handle.readData(ofLength: 4096)
        guard headerData.count >= 8 else { return nil }

        let magic = headerData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        guard magic == Self.FAT_MAGIC || magic == Self.FAT_CIGAM else {
            return nil
        }

        let nfat = Int(headerData.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self).bigEndian })
        guard nfat >= 2 && headerData.count >= 8 + (nfat * 20) else {
            return nil
        }

        var hasArm64 = false
        var hasX86_64 = false
        var intelBytes: Int64 = 0
        var archNames: [String] = []

        for i in 0..<nfat {
            let offset = 8 + (i * 20)
            let cputype = headerData.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self).bigEndian }
            let size = headerData.withUnsafeBytes { $0.load(fromByteOffset: offset + 12, as: UInt32.self).bigEndian }

            if cputype == Self.CPU_TYPE_ARM64 {
                hasArm64 = true
                archNames.append("arm64")
            } else if cputype == Self.CPU_TYPE_X86_64 {
                hasX86_64 = true
                archNames.append("x86_64")
                intelBytes += Int64(size)
            } else {
                archNames.append(String(format: "0x%08X", cputype))
            }
        }

        let isUniversal = hasArm64 && hasX86_64
        let totalSize = Int64(statBuf.st_size)
        let name = (path as NSString).lastPathComponent

        return SlimmableBinary(
            path: path,
            name: name,
            totalSizeBytes: totalSize,
            intelSizeBytes: intelBytes,
            architectures: archNames,
            isUniversal: isUniversal
        )
    }

    // MARK: - Slimming Execution

    /// Strips the Intel x86_64 slice from the universal binaries in the plan and re-signs the bundle.
    ///
    /// Nothing touches the installed app until the result is known to be good: the work happens on a copy
    /// (an instant clone on APFS), every thinned binary is checked to be arm64-only, and the re-signed copy must pass
    /// `codesign --verify`. Only then is it swapped in atomically, and the original goes to the Trash instead of
    /// being deleted. Any failure before the swap leaves the installed app exactly as it was.
    @discardableResult
    public func slimApp(plan: SlimmableAppPlan) throws -> Int64 {
        guard !isProtectedSystemApp(atPath: plan.appPath) else {
            throw SlimmerError.protectedSystemApplication
        }
        let universalBinaries = plan.binaries.filter(\.isUniversal)
        guard !universalBinaries.isEmpty else { return 0 }

        try checkSlimmable(appPath: plan.appPath)

        let appURL = URL(fileURLWithPath: plan.appPath)
        let workDirectory = fileManager.temporaryDirectory.appendingPathComponent("ZenithSlim-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workDirectory) }

        let cloneURL = workDirectory.appendingPathComponent(appURL.lastPathComponent)
        try fileManager.copyItem(at: appURL, to: cloneURL)

        var totalSaved: Int64 = 0
        for binary in universalBinaries {
            guard binary.path.hasPrefix(plan.appPath + "/") else {
                throw SlimmerError.binaryExtractionFailed(binary.path)
            }
            let cloneBinaryPath = cloneURL.path + String(binary.path.dropFirst(plan.appPath.count))
            try thin(binaryAt: cloneBinaryPath, reportedAs: binary.path)
            totalSaved += binary.intelSizeBytes
        }

        try resignAndVerify(bundleAt: cloneURL)
        try swapIn(clone: cloneURL, replacing: appURL)

        historyTracker.record(
            operationName: "Binary Slimming (\(plan.appName))",
            bytesFreed: totalSaved,
            itemCount: universalBinaries.count
        )
        return totalSaved
    }

    /// Reasons an app must not be re-signed locally.
    private func checkSlimmable(appPath: String) throws {
        if isApplicationRunning(appPath) {
            throw SlimmerError.applicationIsRunning
        }
        if fileManager.fileExists(atPath: "\(appPath)/Contents/_MASReceipt") {
            throw SlimmerError.unsupportedApplication("it comes from the Mac App Store, and re-signing would invalidate its receipt")
        }
        // Entitlements tied to the developer's team (iCloud, keychain and app groups, push, …) stop working
        // under a local ad-hoc signature.
        if let entitlements = runner("/usr/bin/codesign", ["-d", "--entitlements", ":-", appPath]) {
            let restricted = [
                "com.apple.developer.",
                "com.apple.application-identifier",
                "com.apple.security.application-groups",
                "keychain-access-groups"
            ]
            if restricted.contains(where: { entitlements.output.contains($0) }) {
                throw SlimmerError.unsupportedApplication("it uses entitlements that only work with its original developer signature")
            }
        }
    }

    /// Replaces a universal binary with its arm64 slice, checking the result is really arm64-only.
    private func thin(binaryAt path: String, reportedAs reportedPath: String) throws {
        let thinPath = "\(path).arm64_thin"
        defer { try? fileManager.removeItem(atPath: thinPath) }

        guard let lipo = runner("/usr/bin/lipo", ["-thin", "arm64", path, "-output", thinPath]),
              lipo.status == 0,
              fileManager.fileExists(atPath: thinPath),
              let archs = runner("/usr/bin/lipo", ["-archs", thinPath]),
              archs.status == 0,
              archs.output.trimmingCharacters(in: .whitespacesAndNewlines) == "arm64" else {
            throw SlimmerError.binaryExtractionFailed(reportedPath)
        }

        if let permissions = (try? fileManager.attributesOfItem(atPath: path))?[.posixPermissions] {
            try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: thinPath)
        }
        try fileManager.removeItem(atPath: path)
        try fileManager.moveItem(atPath: thinPath, toPath: path)
    }

    private func resignAndVerify(bundleAt url: URL) throws {
        let sign = runner("/usr/bin/codesign", [
            "--force", "--deep", "--sign", "-",
            "--preserve-metadata=identifier,entitlements,flags,runtime",
            url.path
        ])
        guard let sign, sign.status == 0 else {
            throw SlimmerError.signingFailed(sign?.errorOutput ?? "codesign could not be started")
        }
        let verify = runner("/usr/bin/codesign", ["--verify", "--deep", "--strict", url.path])
        guard let verify, verify.status == 0 else {
            throw SlimmerError.signingFailed(verify?.errorOutput ?? "codesign could not be started")
        }
    }

    private func swapIn(clone: URL, replacing appURL: URL) throws {
        let backupName = "\(appURL.lastPathComponent).zenith-backup-\(UUID().uuidString.prefix(8))"
        do {
            _ = try fileManager.replaceItemAt(appURL, withItemAt: clone, backupItemName: backupName, options: [.withoutDeletingBackupItem])
        } catch {
            throw SlimmerError.replacementFailed(error.localizedDescription)
        }

        // The slimmed app is in place; the original stays recoverable. If it cannot be moved to the Trash it is left
        // next to the app under its backup name rather than deleted.
        let backupURL = appURL.deletingLastPathComponent().appendingPathComponent(backupName)
        do {
            try disposeBackup(backupURL)
        } catch {
            NSLog("[BinarySlimmer] Original app kept at %@: %@", backupURL.path, error.localizedDescription)
        }
    }

    // MARK: - Helpers

    public func isProtectedSystemApp(atPath path: String) -> Bool {
        let canonical = (path as NSString).standardizingPath
        if canonical.hasPrefix("/System") ||
           canonical.hasPrefix("/Library/Apple") ||
           canonical.hasPrefix("/usr") {
            return true
        }
        return false
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

public enum SlimmerError: Error, LocalizedError, Equatable {
    case protectedSystemApplication
    case binaryExtractionFailed(String)
    case applicationIsRunning
    case unsupportedApplication(String)
    case signingFailed(String)
    case replacementFailed(String)

    public var errorDescription: String? {
        switch self {
        case .protectedSystemApplication:
            return "Cannot modify protected macOS system applications."
        case .binaryExtractionFailed(let path):
            return "Failed to extract arm64 slice for binary at \(path). The app was not changed."
        case .applicationIsRunning:
            return "Quit the application before slimming it. The app was not changed."
        case .unsupportedApplication(let reason):
            return "This app can't be slimmed safely: \(reason)."
        case .signingFailed(let detail):
            return "The slimmed app could not be re-signed (\(detail.trimmingCharacters(in: .whitespacesAndNewlines))). The app was not changed."
        case .replacementFailed(let detail):
            return "The slimmed app could not be installed (\(detail)). The app was not changed."
        }
    }
}
