import Foundation

/// Why Zenith will not replace itself. Each case falls back to downloading the DMG for the user to install by hand.
public enum UpdateInstallRefusal: Equatable, Sendable {
    case notSignedWithStableIdentity
    case signatureUnreadable
    case notAnAppBundle
    case translocated
    case onMountedVolume
    case notWritable

    public var message: String {
        switch self {
        case .notSignedWithStableIdentity:
            return String(localized: "This copy of Zenith is not signed with a stable identity, so an update cannot be verified.")
        case .signatureUnreadable:
            return String(localized: "Zenith could not read its own signature, so an update cannot be verified.")
        case .notAnAppBundle:
            return String(localized: "Zenith is not running from an app bundle, so it cannot replace itself.")
        case .translocated:
            return String(localized: "macOS is running Zenith from a temporary copy. Move Zenith to the Applications folder, open it from there and try again.")
        case .onMountedVolume:
            return String(localized: "Zenith is running from a disk image or an external drive, so it cannot replace itself.")
        case .notWritable:
            return String(localized: "Zenith cannot write to the folder it is installed in.")
        }
    }
}

/// Why a downloaded candidate is not installed.
public enum UpdateCandidateRejection: Error, Equatable, Sendable, LocalizedError {
    case unreadableInfo
    case wrongIdentifier
    case versionMismatch(claimed: String, found: String)
    case notNewer(found: String, running: String)
    case signature(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableInfo:
            return String(localized: "The downloaded app has no readable Info.plist. Nothing was changed.")
        case .wrongIdentifier:
            return String(localized: "The downloaded app is not Zenith. Nothing was changed.")
        case .versionMismatch(let claimed, let found):
            return String(localized: "The download was announced as Zenith \(claimed) but contains version \(found). Nothing was changed.")
        case .notNewer(let found, let running):
            return String(localized: "The downloaded Zenith \(found) is not newer than this copy (\(running)). Nothing was changed.")
        case .signature(let detail):
            return String(localized: "The downloaded app is not signed by the same signer as this copy of Zenith (\(detail)). Nothing was changed.")
        }
    }
}

/// Pure decisions: may Zenith replace itself, and is this candidate acceptable.
public enum UpdateInstallPolicy {
    /// Whether `path` is an App Translocation copy (`/private/var/folders/…/AppTranslocation/…`).
    public static func isTranslocated(_ path: String) -> Bool {
        URL(fileURLWithPath: path).standardizedFileURL.pathComponents.contains("AppTranslocation")
    }

    /// nil when automatic install may proceed. Signing is judged first: it is the reason that holds wherever the app is.
    public static func automaticInstallRefusal(
        signing: RunningAppSigning,
        appPath: String,
        isAppBundle: Bool,
        isOnReadOnlyVolume: Bool,
        isLocationWritable: Bool
    ) -> UpdateInstallRefusal? {
        switch signing {
        case .stable: break
        case .adHoc, .unsigned: return .notSignedWithStableIdentity
        case .unreadable: return .signatureUnreadable
        }
        guard isAppBundle else { return .notAnAppBundle }
        if isTranslocated(appPath) { return .translocated }
        if isOnReadOnlyVolume || AppLocation.isOnMountedVolume(appPath) { return .onMountedVolume }
        guard isLocationWritable else { return .notWritable }
        return nil
    }

    /// The same decision, reading the facts about `appURL` from the file system.
    public static func automaticInstallRefusal(
        signing: RunningAppSigning,
        appURL: URL,
        fileManager: FileManager = .default
    ) -> UpdateInstallRefusal? {
        let path = appURL.path
        let isBundle = appURL.pathExtension == "app"
            && fileManager.fileExists(atPath: appURL.appendingPathComponent("Contents/Info.plist").path)
        let readOnly = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        // Renaming the bundle needs the folder it is in; moving it to the Trash needs the bundle itself.
        let writable = fileManager.isWritableFile(atPath: appURL.deletingLastPathComponent().path)
            && fileManager.isWritableFile(atPath: path)
        return automaticInstallRefusal(
            signing: signing,
            appPath: path,
            isAppBundle: isBundle,
            isOnReadOnlyVolume: readOnly,
            isLocationWritable: writable
        )
    }

    /// nil when the candidate may be installed: it is Zenith, it is the version the release announced, that version is
    /// strictly newer than the running one, and its signature satisfies the running app's designated requirement.
    public static func candidateRejection(
        bundleIdentifier: String?,
        shortVersion: String?,
        claimed: AppVersion,
        running: AppVersion,
        signature: CandidateSignatureCheck
    ) -> UpdateCandidateRejection? {
        guard let bundleIdentifier, let shortVersion else { return .unreadableInfo }
        guard bundleIdentifier == UpdateLimits.bundleIdentifier else { return .wrongIdentifier }
        guard let found = AppVersion(shortVersion), found == claimed else {
            return .versionMismatch(claimed: claimed.description, found: String(shortVersion.prefix(AppVersion.maximumLength)))
        }
        guard found > running else { return .notNewer(found: found.description, running: running.description) }
        if case .rejected(let detail) = signature { return .signature(detail) }
        return nil
    }
}
