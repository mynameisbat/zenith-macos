import Foundation
import Combine

/// What an import did.
public struct SnippetImportResult: Equatable, Sendable {
    public var added: Int
    public var replaced: Int

    public init(added: Int, replaced: Int) {
        self.added = added
        self.replaced = replaced
    }
}

public enum SnippetLibraryError: Error, Equatable, LocalizedError {
    case unreadable(String)
    case unwritable(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let detail):
            return String(localized: "The file is not a snippets file: \(detail)")
        case .unwritable(let detail):
            return String(localized: "Snippets could not be saved: \(detail)")
        }
    }
}

/// The user's snippets, saved as JSON (`Snippets.json` in Zenith's Application Support folder). Tests pass a
/// temporary folder.
@MainActor
public final class SnippetLibrary: ObservableObject {
    public static let shared = SnippetLibrary()
    public static let fileName = "Snippets.json"

    @Published public private(set) var snippets: [Snippet]
    /// The last save or load failure, for Settings to show; nil once a save works.
    @Published public private(set) var lastError: String?

    public let fileURL: URL

    public init(directory: URL? = nil) {
        let folder = directory ?? Self.defaultDirectory
        self.fileURL = folder.appendingPathComponent(Self.fileName)
        self.snippets = []
        self.lastError = nil
        load()
    }

    static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Zenith", isDirectory: true)
    }

    /// Snippets a first launch starts with, so the feature shows what it does.
    public static var examples: [Snippet] {
        [
            Snippet(name: String(localized: "Today's date"), trigger: ";date", body: "{date}"),
            Snippet(name: String(localized: "Email signature"), trigger: ";sig",
                    body: String(localized: "Best regards,\n{cursor}"))
        ]
    }

    // MARK: Editing

    public func add(_ snippet: Snippet) {
        snippets.append(snippet)
        save()
    }

    /// Replaces the snippet with the same id; adds it if there is none.
    public func update(_ snippet: Snippet) {
        if let index = snippets.firstIndex(where: { $0.id == snippet.id }) {
            guard snippets[index] != snippet else { return }
            snippets[index] = snippet
        } else {
            snippets.append(snippet)
        }
        save()
    }

    public func delete(id: UUID) {
        let before = snippets.count
        snippets.removeAll { $0.id == id }
        if snippets.count != before { save() }
    }

    public func snippet(id: UUID) -> Snippet? {
        snippets.first { $0.id == id }
    }

    // MARK: Import / export

    public func exportData() throws -> Data {
        try SnippetLibraryFile(snippets: snippets).encoded()
    }

    /// Adds the snippets in `data`. One with the id or the trigger of an existing snippet replaces it (keeping the
    /// existing id); everything else is added at the end.
    @discardableResult
    public func importSnippets(from data: Data) throws -> SnippetImportResult {
        let incoming: [Snippet]
        do {
            incoming = try SnippetLibraryFile.decode(data)
        } catch {
            throw SnippetLibraryError.unreadable(error.localizedDescription)
        }
        var result = SnippetImportResult(added: 0, replaced: 0)
        var updated = snippets
        for var snippet in incoming {
            if let index = updated.firstIndex(where: { $0.id == snippet.id })
                ?? (snippet.trigger.isEmpty ? nil : updated.firstIndex(where: { $0.trigger == snippet.trigger })) {
                snippet.id = updated[index].id
                updated[index] = snippet
                result.replaced += 1
            } else {
                updated.append(snippet)
                result.added += 1
            }
        }
        snippets = updated
        save()
        return result
    }

    // MARK: File

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            // No file yet: a first launch. Start with the examples, but do not write them until the user edits.
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                snippets = Self.examples
            }
            return
        }
        do {
            snippets = try SnippetLibraryFile.decode(data)
        } catch {
            // Keep the unreadable file as it is (no save happens until an edit), and say so.
            lastError = SnippetLibraryError.unreadable(error.localizedDescription).errorDescription
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try SnippetLibraryFile(snippets: snippets).encoded().write(to: fileURL, options: .atomic)
            if lastError != nil { lastError = nil }
        } catch {
            lastError = SnippetLibraryError.unwritable(error.localizedDescription).errorDescription
        }
    }
}

/// Typed expansion on/off and the apps it stays out of. Saved in `UserDefaults`.
@MainActor
public final class SnippetSettings: ObservableObject {
    public static let shared = SnippetSettings()

    public enum Keys {
        public static let typedExpansionEnabled = "zenith_snippets_typed_expansion"
        public static let excludedApps = "zenith_snippets_excluded_apps"
    }

    /// Expand a trigger as it is typed (needs Accessibility). Off by default: it watches every key press.
    @Published public var isTypedExpansionEnabled: Bool {
        didSet { userDefaults.set(isTypedExpansionEnabled, forKey: Keys.typedExpansionEnabled) }
    }

    /// Bundle identifiers of apps where triggers are never expanded, in the order they were added.
    @Published public private(set) var excludedAppBundleIdentifiers: [String] {
        didSet { userDefaults.set(excludedAppBundleIdentifiers, forKey: Keys.excludedApps) }
    }

    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.isTypedExpansionEnabled = userDefaults.object(forKey: Keys.typedExpansionEnabled) as? Bool ?? false
        self.excludedAppBundleIdentifiers = userDefaults.stringArray(forKey: Keys.excludedApps) ?? []
    }

    public func isExcluded(bundleIdentifier: String) -> Bool {
        let key = bundleIdentifier.lowercased()
        return excludedAppBundleIdentifiers.contains { $0.lowercased() == key }
    }

    /// Returns false for an empty identifier, one with spaces, or one already listed (any case).
    @discardableResult
    public func addExcludedApp(bundleIdentifier: String) -> Bool {
        let trimmed = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace), !isExcluded(bundleIdentifier: trimmed) else {
            return false
        }
        excludedAppBundleIdentifiers.append(trimmed)
        return true
    }

    public func removeExcludedApp(bundleIdentifier: String) {
        let key = bundleIdentifier.lowercased()
        excludedAppBundleIdentifiers.removeAll { $0.lowercased() == key }
    }
}
