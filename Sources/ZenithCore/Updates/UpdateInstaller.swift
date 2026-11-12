import Foundation
import CryptoKit
import CoreServices

// Downloading and installing an update. The order is the security model:
//   1. may this copy replace itself at all (stable signature, a writable app bundle not on an image or translocated)
//   2. the release's URL, name, size and version are re-checked
//   3. download into a private temporary folder; exact size, size cap, SHA-256 when GitHub publishes one
//   4. mount read-only, without Finder, at a mount point inside that folder; copy Zenith.app out; detach (always)
//   5. verify THAT COPY: bundle identifier, announced version == bundle version > running version, and its signature
//      satisfies the running app's designated requirement (same certificate)
//   6. swap that same copy in with one atomic replace, beside the installed app (same volume), old app to the Trash
// A failure at any step leaves the installed app where it was.

public enum UpdateInstallProgress: Equatable, Sendable {
    case downloading(Double?)
    case verifying
    case installing
}

public enum UpdateInstallError: Error, Equatable, Sendable, LocalizedError {
    case refused(UpdateInstallRefusal)
    case untrustedRelease
    case download(String)
    case tooLarge
    case sizeMismatch(expected: Int64, actual: Int64)
    case digestMismatch
    case mountFailed
    case appMissingInImage
    case copyFailed(String)
    case rejected(UpdateCandidateRejection)
    case replaceFailed(String)

    public var errorDescription: String? {
        switch self {
        case .refused(let refusal):
            return refusal.message
        case .untrustedRelease:
            return String(localized: "The release does not point at a Zenith download Zenith can trust. Nothing was changed.")
        case .download(let detail):
            return String(localized: "The download failed (\(detail)). Nothing was changed.")
        case .tooLarge:
            return String(localized: "The download is far larger than a Zenith release, so it was stopped. Nothing was changed.")
        case .sizeMismatch:
            return String(localized: "The download is not the size GitHub announced. Nothing was changed.")
        case .digestMismatch:
            return String(localized: "The download does not match the checksum GitHub published. Nothing was changed.")
        case .mountFailed:
            return String(localized: "The downloaded disk image could not be opened. Nothing was changed.")
        case .appMissingInImage:
            return String(localized: "The downloaded disk image does not contain Zenith.app. Nothing was changed.")
        case .copyFailed(let detail):
            return String(localized: "The new version could not be copied (\(detail)). Nothing was changed.")
        case .rejected(let rejection):
            return rejection.errorDescription
        case .replaceFailed(let detail):
            return String(localized: "The new version could not be put in place (\(detail)). This copy of Zenith was kept.")
        }
    }
}

/// The file operations the installer performs, so tests can make each one fail.
public struct UpdateFileOperations: Sendable {
    public var copy: @Sendable (_ source: URL, _ destination: URL) throws -> Void
    /// Puts `replacement` at `original`, leaving the original at `backupName` beside it.
    public var replace: @Sendable (_ original: URL, _ replacement: URL, _ backupName: String) throws -> Void
    public var trash: @Sendable (URL) throws -> Void

    public init(
        copy: @escaping @Sendable (URL, URL) throws -> Void,
        replace: @escaping @Sendable (URL, URL, String) throws -> Void,
        trash: @escaping @Sendable (URL) throws -> Void
    ) {
        self.copy = copy
        self.replace = replace
        self.trash = trash
    }

    /// `copyItem` (keeps symbolic links as links), `replaceItemAt` as `BinarySlimmerService` uses it, and the Trash.
    public static let live = UpdateFileOperations(
        copy: { try FileManager.default.copyItem(at: $0, to: $1) },
        replace: { original, replacement, backupName in
            _ = try FileManager.default.replaceItemAt(
                original, withItemAt: replacement, backupItemName: backupName, options: [.withoutDeletingBackupItem]
            )
        },
        trash: { try TrashMover.system.move($0) }
    )
}

public protocol UpdateInstalling: Sendable {
    /// Installs `release` over the running app and returns where it is. Never relaunches.
    func install(_ release: UpdateRelease, progress: @escaping @Sendable (UpdateInstallProgress) -> Void) async throws -> URL
    /// Downloads the DMG for the user to install by hand (into Downloads, marked as downloaded from the web) and
    /// returns its location. Does not open it.
    func downloadForManualInstall(_ release: UpdateRelease, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL
    /// nil when `install` may run; otherwise why the manual download is offered instead.
    func automaticInstallRefusal() -> UpdateInstallRefusal?
}

public final class UpdateInstaller: UpdateInstalling, @unchecked Sendable {
    private let appURL: URL
    private let runningVersion: AppVersion
    private let verifier: CodeSignatureVerifying
    private let downloader: UpdateDownloading
    private let runner: SystemCommandRunner
    private let fileOperations: UpdateFileOperations
    private let temporaryRoot: URL
    private let downloadsDirectory: URL?

    /// - Parameters:
    ///   - appURL: The installed bundle to replace (the running app's).
    ///   - runner: Runs `hdiutil`; tests record it.
    ///   - temporaryRoot: Where the private download folder is made.
    ///   - downloadsDirectory: Where a manual download is saved (default: the user's Downloads).
    public init(
        appURL: URL = Bundle.main.bundleURL,
        runningVersion: AppVersion = .running,
        verifier: CodeSignatureVerifying = SecurityFrameworkSignatureVerifier(),
        downloader: UpdateDownloading = URLSessionUpdateDownloader(),
        runner: @escaping SystemCommandRunner = SystemCommand.processRunner,
        fileOperations: UpdateFileOperations = .live,
        temporaryRoot: URL = FileManager.default.temporaryDirectory,
        downloadsDirectory: URL? = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    ) {
        self.appURL = appURL.standardizedFileURL
        self.runningVersion = runningVersion
        self.verifier = verifier
        self.downloader = downloader
        self.runner = runner
        self.fileOperations = fileOperations
        self.temporaryRoot = temporaryRoot
        self.downloadsDirectory = downloadsDirectory
    }

    public func automaticInstallRefusal() -> UpdateInstallRefusal? {
        UpdateInstallPolicy.automaticInstallRefusal(signing: verifier.runningAppSigning(), appURL: appURL)
    }

    // MARK: - Install

    public func install(_ release: UpdateRelease, progress: @escaping @Sendable (UpdateInstallProgress) -> Void) async throws -> URL {
        if let refusal = automaticInstallRefusal() { throw UpdateInstallError.refused(refusal) }
        try checkReleaseAgain(release)

        let work = try makeWorkDirectory()
        defer { removeWorkDirectory(work) }

        let image = work.directory.appendingPathComponent(release.assetName)
        try await downloadAndCheck(release, to: image) { progress(.downloading($0)) }
        progress(.verifying)

        // Staging sits beside the installed app, on the same volume, so the swap is a rename of what was verified.
        let parent = appURL.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".zenith-update-\(UUID().uuidString)", isDirectory: true)
        try createPrivateDirectory(staging, failure: { UpdateInstallError.copyFailed($0) })
        defer { try? FileManager.default.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(UpdateLimits.appBundleName, isDirectory: true)

        try withMountedImage(image, mountPoint: work.mountPoint) { mountPoint in
            let source = mountPoint.appendingPathComponent(UpdateLimits.appBundleName, isDirectory: true)
            guard Self.isRealDirectory(source) else { throw UpdateInstallError.appMissingInImage }
            do {
                try fileOperations.copy(source, staged)
            } catch {
                throw UpdateInstallError.copyFailed(error.localizedDescription)
            }
        }
        // From here on only the copy is looked at; the image is gone.
        guard Self.isRealDirectory(staged) else { throw UpdateInstallError.copyFailed("the copy is not a folder") }
        let info = Self.readInfo(of: staged)
        let signature = verifier.checkCandidate(at: staged)
        if let rejection = UpdateInstallPolicy.candidateRejection(
            bundleIdentifier: info?["CFBundleIdentifier"] as? String,
            shortVersion: info?["CFBundleShortVersionString"] as? String,
            claimed: release.version,
            running: runningVersion,
            signature: signature
        ) {
            throw UpdateInstallError.rejected(rejection)
        }

        progress(.installing)
        try swapIn(staged)
        return appURL
    }

    /// Release values are re-checked here, whoever built the `UpdateRelease`.
    private func checkReleaseAgain(_ release: UpdateRelease) throws {
        guard release.version > runningVersion else {
            throw UpdateInstallError.rejected(.notNewer(found: release.version.description, running: runningVersion.description))
        }
        guard AppVersion(release.tag) == release.version,
              release.assetName == UpdateLimits.assetName(forVersionText: Self.versionText(ofTag: release.tag)),
              UpdateURLPolicy.isAllowedDownloadURL(release.downloadURL, tag: release.tag, assetName: release.assetName),
              release.assetSize > 0, release.assetSize <= UpdateLimits.maximumDownloadBytes else {
            throw UpdateInstallError.untrustedRelease
        }
    }

    static func versionText(ofTag tag: String) -> String {
        (tag.first == "v" || tag.first == "V") ? String(tag.dropFirst()) : tag
    }

    /// The swap and what happens if it fails. `replaceItemAt` exchanges the two in one step; if it throws, and the
    /// installed app is missing while its backup exists, the backup is put back.
    private func swapIn(_ staged: URL) throws {
        let parent = appURL.deletingLastPathComponent()
        let backupName = "\(appURL.lastPathComponent).zenith-previous-\(UUID().uuidString.prefix(8))"
        let backupURL = parent.appendingPathComponent(backupName)
        do {
            try fileOperations.replace(appURL, staged, backupName)
        } catch {
            let fileManager = FileManager.default
            if !fileManager.fileExists(atPath: appURL.path), fileManager.fileExists(atPath: backupURL.path) {
                try? fileManager.moveItem(at: backupURL, to: appURL)
            }
            throw UpdateInstallError.replaceFailed(error.localizedDescription)
        }
        // The new app is in place. The old one goes to the Trash; if it cannot, it stays beside it, never deleted.
        if FileManager.default.fileExists(atPath: backupURL.path) {
            do {
                try fileOperations.trash(backupURL)
            } catch {
                NSLog("[Updater] Previous version kept at %@: %@", backupURL.path, error.localizedDescription)
            }
        }
    }

    // MARK: - Manual download

    public func downloadForManualInstall(_ release: UpdateRelease, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        try checkReleaseAgain(release)
        guard let downloadsDirectory else { throw UpdateInstallError.download("no Downloads folder") }
        let work = try makeWorkDirectory()
        defer { removeWorkDirectory(work) }

        let file = work.directory.appendingPathComponent(release.assetName)
        try await downloadAndCheck(release, to: file, progress: progress)
        let destination = Self.unusedURL(in: downloadsDirectory, name: release.assetName)
        do {
            try FileManager.default.moveItem(at: file, to: destination)
        } catch {
            throw UpdateInstallError.download(error.localizedDescription)
        }
        Self.markAsDownloaded(destination, from: release.downloadURL)
        return destination
    }

    /// Gives the file the quarantine a browser download gets, so opening it is exactly what installing by hand is:
    /// Gatekeeper checks the app as usual. (Nothing in the updater ever removes quarantine.)
    static func markAsDownloaded(_ url: URL, from source: URL) {
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
            kLSQuarantineAgentNameKey as String: "Zenith",
            kLSQuarantineDataURLKey as String: source
        ]
        var target = url
        do {
            try target.setResourceValues(values)
        } catch {
            NSLog("[Updater] Could not mark %@ as downloaded: %@", url.lastPathComponent, error.localizedDescription)
        }
    }

    static func unusedURL(in directory: URL, name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = directory.appendingPathComponent(name)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) \(index).\(ext)")
            index += 1
        }
        return candidate
    }

    // MARK: - Download and checks

    private func downloadAndCheck(_ release: UpdateRelease, to file: URL, progress: @escaping @Sendable (Double?) -> Void) async throws {
        do {
            try await downloader.download(release.downloadURL, to: file, maximumBytes: UpdateLimits.maximumDownloadBytes, progress: progress)
        } catch let error as UpdateInstallError {
            throw error
        } catch {
            throw UpdateInstallError.download(error.localizedDescription)
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        guard attributes?[.type] as? FileAttributeType == .typeRegular else {
            throw UpdateInstallError.download("no file was received")
        }
        guard size <= UpdateLimits.maximumDownloadBytes else { throw UpdateInstallError.tooLarge }
        guard size == release.assetSize else { throw UpdateInstallError.sizeMismatch(expected: release.assetSize, actual: size) }
        if let expected = release.sha256 {
            guard let actual = Self.sha256Hex(of: file), actual == expected else { throw UpdateInstallError.digestMismatch }
        }
    }

    static func sha256Hex(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Disk image

    /// Attaches `image` read-only, without Finder or auto-open, at `mountPoint`, runs `body`, and detaches in every
    /// case (`-force` if a plain detach fails). Nothing from the network reaches these arguments: both paths are ours.
    func withMountedImage(_ image: URL, mountPoint: URL, body: (URL) throws -> Void) throws {
        try createPrivateDirectory(mountPoint, failure: { _ in UpdateInstallError.mountFailed })
        let attach = runner("/usr/bin/hdiutil", Self.attachArguments(image: image, mountPoint: mountPoint))
        defer { detach(mountPoint) }
        guard let attach, attach.status == 0 else { throw UpdateInstallError.mountFailed }
        try body(mountPoint)
    }

    static func attachArguments(image: URL, mountPoint: URL) -> [String] {
        ["attach", image.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mountPoint.path]
    }

    private func detach(_ mountPoint: URL) {
        if let result = runner("/usr/bin/hdiutil", ["detach", mountPoint.path]), result.status == 0 { return }
        if let result = runner("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"]), result.status == 0 { return }
        if Self.isMountPoint(mountPoint) {
            NSLog("[Updater] Could not detach the update image at %@", mountPoint.path)
        }
    }

    /// Whether something is mounted at `url` (its device differs from its parent's).
    static func isMountPoint(_ url: URL) -> Bool {
        var own = stat()
        var parent = stat()
        guard lstat(url.path, &own) == 0, lstat(url.deletingLastPathComponent().path, &parent) == 0 else { return false }
        return own.st_dev != parent.st_dev
    }

    // MARK: - Folders

    private struct WorkDirectory {
        let directory: URL
        var mountPoint: URL { directory.appendingPathComponent("mount", isDirectory: true) }
    }

    private func makeWorkDirectory() throws -> WorkDirectory {
        let directory = temporaryRoot.appendingPathComponent("ZenithUpdate-\(UUID().uuidString)", isDirectory: true)
        try createPrivateDirectory(directory, failure: { UpdateInstallError.download($0) })
        return WorkDirectory(directory: directory)
    }

    /// Removes the download folder, unless an image is somehow still mounted inside it (never recurse into a volume).
    private func removeWorkDirectory(_ work: WorkDirectory) {
        if Self.isMountPoint(work.mountPoint) {
            NSLog("[Updater] Left %@ in place: an image is still mounted there", work.directory.path)
            return
        }
        try? FileManager.default.removeItem(at: work.directory)
    }

    private func createPrivateDirectory(_ url: URL, failure: (String) -> UpdateInstallError) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            throw failure(error.localizedDescription)
        }
    }

    /// A directory that is not a symbolic link.
    static func isRealDirectory(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// The candidate's Info.plist, read as data (not through `Bundle`, which caches).
    static func readInfo(of bundle: URL) -> [String: Any]? {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: plist.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue, size <= 1024 * 1024,
              let data = try? Data(contentsOf: plist) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}
