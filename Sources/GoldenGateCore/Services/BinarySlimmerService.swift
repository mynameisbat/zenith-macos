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

    // Mach-O constants
    private static let FAT_MAGIC: UInt32 = 0xCAFEBABE
    private static let FAT_CIGAM: UInt32 = 0xBEBAFECA
    private static let CPU_TYPE_X86_64: UInt32 = 0x01000007
    private static let CPU_TYPE_ARM64: UInt32 = 0x0100000C

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
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

    /// Strips the Intel x86_64 slice from universal binaries in the plan
    /// and re-signs the application bundle.
    @discardableResult
    public func slimApp(plan: SlimmableAppPlan) throws -> Int64 {
        guard !isProtectedSystemApp(atPath: plan.appPath) else {
            throw SlimmerError.protectedSystemApplication
        }

        var totalSaved: Int64 = 0

        for binary in plan.binaries where binary.isUniversal {
            let originalPath = binary.path
            let thinPath = "\(originalPath).arm64_thin"

            // 1. Extract arm64 slice via lipo
            let lipo = Process()
            lipo.executableURL = URL(fileURLWithPath: "/usr/bin/lipo")
            lipo.arguments = ["-thin", "arm64", originalPath, "-output", thinPath]
            try lipo.run()
            lipo.waitUntilExit()

            guard lipo.terminationStatus == 0 && fileManager.fileExists(atPath: thinPath) else {
                try? fileManager.removeItem(atPath: thinPath)
                continue
            }

            // 2. Preserve permissions
            let origAttrs = try? fileManager.attributesOfItem(atPath: originalPath)
            if let posixPerms = origAttrs?[.posixPermissions] as? NSNumber {
                try? fileManager.setAttributes([.posixPermissions: posixPerms], ofItemAtPath: thinPath)
            }

            // 3. Swap binary
            try? fileManager.removeItem(atPath: originalPath)
            try fileManager.moveItem(atPath: thinPath, toPath: originalPath)
            totalSaved += binary.intelSizeBytes
        }

        // 4. Re-sign the slimmed application bundle with ad-hoc signature
        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["--force", "--deep", "--sign", "-", plan.appPath]
        try? codesign.run()
        codesign.waitUntilExit()

        return totalSaved
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

    public var errorDescription: String? {
        switch self {
        case .protectedSystemApplication:
            return "Cannot modify protected macOS system applications."
        case .binaryExtractionFailed(let path):
            return "Failed to extract arm64 slice for binary at \(path)."
        }
    }
}
