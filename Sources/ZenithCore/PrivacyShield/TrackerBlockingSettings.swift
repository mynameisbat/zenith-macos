import Foundation
import Combine

/// Why a list could not be imported.
public enum TrackerListImportError: Error, Equatable, LocalizedError {
    case unreadable
    case tooLarge
    case noDomains

    public var errorDescription: String? {
        switch self {
        case .unreadable: return String(localized: "Zenith could not read that file.")
        case .tooLarge: return String(localized: "That file is too large for a domain list (over 50 MB).")
        case .noDomains: return String(localized: "No domain names were found in that file. Zenith reads hosts files, plain lists with one domain per line, and ad-blocker rules such as ||ads.example.com^.")
        }
    }
}

/// What happened to a domain the user typed.
public enum TrackerDomainEntryResult: Equatable, Sendable {
    case added(String)
    case alreadyListed(String)
    case invalid
}

/// Whether Privacy Shield blocks trackers, and the lists it uses: the built-in one, one the user imported, domains
/// they added, and domains they never want blocked. Saved in `UserDefaults` (the lists of names) and in a text file
/// (an imported list, which can have hundreds of thousands of entries).
///
/// Off until the user turns it on: blocking changes what loads on web pages, so it is their choice.
@MainActor
public final class TrackerBlockingSettings: ObservableObject {
    public static let shared = TrackerBlockingSettings()

    public enum Keys {
        public static let isEnabled = "zenith_tracker_blocking_enabled"
        public static let customDomains = "zenith_tracker_blocking_custom"
        public static let allowedDomains = "zenith_tracker_blocking_allowed"
        public static let importedListName = "zenith_tracker_blocking_imported_name"
    }

    /// The largest list file that is read, in bytes.
    public static let maxListFileBytes = 50 * 1024 * 1024
    static let importedFileName = "tracker-blocklist-imported.txt"

    @Published public var isEnabled: Bool {
        didSet {
            userDefaults.set(isEnabled, forKey: Keys.isEnabled)
            applyToBlocklist()
        }
    }

    /// Domains the user added to block, in the order they added them.
    @Published public private(set) var customDomains: [String]
    /// Domains the user never wants blocked.
    @Published public private(set) var allowedDomains: [String]
    /// The file name of the imported list, if there is one.
    @Published public private(set) var importedListName: String?
    @Published public private(set) var importedDomainCount: Int

    /// What the proxy checks. Kept up to date by this object; empty while blocking is off.
    public let blocklist: TrackerBlocklist

    private let userDefaults: UserDefaults
    private let storageDirectory: URL
    private var importedDomains: Set<String>

    public init(
        userDefaults: UserDefaults = .standard,
        storageDirectory: URL? = nil,
        blocklist: TrackerBlocklist = TrackerBlocklist()
    ) {
        self.userDefaults = userDefaults
        self.storageDirectory = storageDirectory ?? Self.defaultStorageDirectory
        self.blocklist = blocklist
        self.isEnabled = userDefaults.object(forKey: Keys.isEnabled) as? Bool ?? false
        self.customDomains = Self.cleaned(userDefaults.stringArray(forKey: Keys.customDomains) ?? [])
        self.allowedDomains = Self.cleaned(userDefaults.stringArray(forKey: Keys.allowedDomains) ?? [])

        let name = userDefaults.string(forKey: Keys.importedListName)
        let loaded = name == nil ? Set<String>() : Self.readImportedFile(in: self.storageDirectory)
        self.importedDomains = loaded
        self.importedListName = loaded.isEmpty ? nil : name
        self.importedDomainCount = loaded.count
        applyToBlocklist()
    }

    static var defaultStorageDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Zenith", isDirectory: true)
    }

    /// How many domains are blocked right now: zero while blocking is off.
    public var activeDomainCount: Int { blocklist.blockedCount }

    /// How many domains the built-in list has.
    public var builtInDomainCount: Int { TrackerBlocklist.builtInDomains.count }

    // MARK: - Domains the user typed

    @discardableResult
    public func addCustomDomain(_ text: String) -> TrackerDomainEntryResult {
        guard let domain = TrackerBlocklist.normalize(text) else { return .invalid }
        guard !customDomains.contains(domain) else { return .alreadyListed(domain) }
        customDomains.append(domain)
        userDefaults.set(customDomains, forKey: Keys.customDomains)
        if isEnabled { blocklist.insertBlocked(normalized: domain) }   // one more entry: no need to rebuild the set
        return .added(domain)
    }

    public func removeCustomDomain(_ domain: String) {
        guard let index = customDomains.firstIndex(of: domain) else { return }
        customDomains.remove(at: index)
        userDefaults.set(customDomains, forKey: Keys.customDomains)
        applyToBlocklist()
    }

    @discardableResult
    public func addAllowedDomain(_ text: String) -> TrackerDomainEntryResult {
        guard let domain = TrackerBlocklist.normalize(text) else { return .invalid }
        guard !allowedDomains.contains(domain) else { return .alreadyListed(domain) }
        allowedDomains.append(domain)
        userDefaults.set(allowedDomains, forKey: Keys.allowedDomains)
        if isEnabled { blocklist.replaceAllowed(normalized: Set(allowedDomains)) }
        return .added(domain)
    }

    public func removeAllowedDomain(_ domain: String) {
        guard let index = allowedDomains.firstIndex(of: domain) else { return }
        allowedDomains.remove(at: index)
        userDefaults.set(allowedDomains, forKey: Keys.allowedDomains)
        if isEnabled { blocklist.replaceAllowed(normalized: Set(allowedDomains)) }
    }

    // MARK: - Imported list

    /// Reads a hosts file or domain list and uses it from now on, in place of any list imported before.
    /// - Returns: How many domains it holds.
    @discardableResult
    public func importList(from url: URL) throws -> Int {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= Self.maxListFileBytes else { throw TrackerListImportError.tooLarge }
        guard let data = try? Data(contentsOf: url) else { throw TrackerListImportError.unreadable }
        guard data.count <= Self.maxListFileBytes else { throw TrackerListImportError.tooLarge }

        let domains = TrackerBlocklist.parseList(String(decoding: data, as: UTF8.self))
        guard !domains.isEmpty else { throw TrackerListImportError.noDomains }

        do {
            try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
            try domains.joined(separator: "\n").write(
                to: storageDirectory.appendingPathComponent(Self.importedFileName),
                atomically: true,
                encoding: .utf8
            )
        } catch {
            throw TrackerListImportError.unreadable
        }

        importedDomains = Set(domains)
        importedDomainCount = domains.count
        importedListName = url.lastPathComponent
        userDefaults.set(url.lastPathComponent, forKey: Keys.importedListName)
        applyToBlocklist()
        return domains.count
    }

    public func removeImportedList() {
        try? FileManager.default.removeItem(at: storageDirectory.appendingPathComponent(Self.importedFileName))
        userDefaults.removeObject(forKey: Keys.importedListName)
        importedDomains = []
        importedDomainCount = 0
        importedListName = nil
        applyToBlocklist()
    }

    // MARK: - Internals

    private func applyToBlocklist() {
        if isEnabled {
            // Every part is already normalized: the built-in list is checked by a test, the imported one when it was
            // read, and the user's entries when they were added. Nothing here is cleaned again.
            blocklist.replace(
                normalizedBlocked: Self.builtInSet.union(importedDomains).union(customDomains),
                normalizedAllowed: Set(allowedDomains)
            )
        } else {
            blocklist.replace(normalizedBlocked: [], normalizedAllowed: [])
        }
    }

    private static let builtInSet: Set<String> = Set(TrackerBlocklist.builtInDomains.compactMap(TrackerBlocklist.normalize))

    private static func cleaned(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.compactMap(TrackerBlocklist.normalize).filter { seen.insert($0).inserted }
    }

    private static func readImportedFile(in directory: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(importedFileName)),
              data.count <= maxListFileBytes else { return [] }
        return Set(TrackerBlocklist.parseList(String(decoding: data, as: UTF8.self)))
    }
}
