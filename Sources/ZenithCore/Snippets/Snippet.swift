import Foundation

/// A piece of text the user types often. Typing its trigger (for example `;sig`) replaces the trigger with the body,
/// and the snippet menu inserts it by name. The body may hold variables (`SnippetExpander`).
public struct Snippet: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// What the user types to expand it. Empty means the snippet is only inserted from the menu.
    public var trigger: String
    public var body: String

    public init(id: UUID = UUID(), name: String, trigger: String, body: String) {
        self.id = id
        self.name = name
        self.trigger = trigger
        self.body = body
    }

    private enum CodingKeys: String, CodingKey { case id, name, trigger, body }

    /// Lenient, so a file written by hand imports: a missing id gets a new one, a missing name or trigger is empty.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? container.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.trigger = try container.decodeIfPresent(String.self, forKey: .trigger) ?? ""
        self.body = try container.decode(String.self, forKey: .body)
    }

    /// The name to show: the name, or the trigger, or the start of the body.
    public var displayName: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty { return trimmedName }
        if !trigger.isEmpty { return trigger }
        let firstLine = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return String(firstLine.prefix(40))
    }
}

/// The JSON file the snippets are saved in, and the format of an export.
public struct SnippetLibraryFile: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var snippets: [Snippet]

    public init(version: Int = SnippetLibraryFile.currentVersion, snippets: [Snippet]) {
        self.version = version
        self.snippets = snippets
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Reads a library file, or a bare array of snippets (what other tools and hand-written files often are).
    public static func decode(_ data: Data) throws -> [Snippet] {
        let decoder = JSONDecoder()
        if let file = try? decoder.decode(SnippetLibraryFile.self, from: data) {
            return file.snippets
        }
        return try decoder.decode([Snippet].self, from: data)
    }
}

// MARK: - Trigger rules

/// Something wrong with a snippet's trigger, shown next to it in Settings.
public enum SnippetTriggerIssue: Equatable, Sendable {
    /// It contains a space, tab or line break: typing it would be cut by those keys, which reset the matcher.
    case containsWhitespace
    /// Another snippet has the same trigger. Only the first one expands.
    case duplicate(of: String)
    /// Another trigger starts with this one, so typing that longer trigger always expands this one first.
    case hidesLongerTrigger(String)
    /// Longer than the matcher remembers.
    case tooLong

    public var message: String {
        switch self {
        case .containsWhitespace:
            return String(localized: "A trigger cannot contain spaces or line breaks.")
        case .duplicate(let name):
            return String(localized: "\(name) already uses this trigger.")
        case .hidesLongerTrigger(let trigger):
            return String(localized: "\(trigger) starts with this trigger, so it can never be typed.")
        case .tooLong:
            return String(localized: "A trigger can be at most \(SnippetMatcher.maximumTriggerLength) characters long.")
        }
    }
}

public enum SnippetTriggerRules {
    /// Problems with `snippet`'s trigger among `all` (which may contain `snippet` itself).
    public static func issues(for snippet: Snippet, among all: [Snippet]) -> [SnippetTriggerIssue] {
        let trigger = snippet.trigger
        guard !trigger.isEmpty else { return [] }
        var result: [SnippetTriggerIssue] = []
        if trigger.contains(where: { $0.isWhitespace || $0.isNewline }) {
            result.append(.containsWhitespace)
        }
        if trigger.count > SnippetMatcher.maximumTriggerLength {
            result.append(.tooLong)
        }
        let others = all.filter { $0.id != snippet.id && !$0.trigger.isEmpty }
        if let first = all.first(where: { $0.trigger == trigger }), first.id != snippet.id {
            result.append(.duplicate(of: first.displayName))
        }
        if let longer = others.first(where: { $0.trigger.count > trigger.count && $0.trigger.hasPrefix(trigger) }) {
            result.append(.hidesLongerTrigger(longer.trigger))
        }
        return result
    }
}
