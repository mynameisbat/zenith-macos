import Foundation

/// What a key press means to the matcher. The event tap translates each key-down into one of these.
public enum SnippetKeyInput: Equatable, Sendable {
    /// Characters the key typed (usually one).
    case characters(String)
    /// The delete key: the last typed character goes.
    case backspace
    /// Something that moves the caret or leaves the text: a click, an arrow, Return, Tab, Escape, a ⌘ or ⌃ shortcut,
    /// another app coming to the front. What was typed before can no longer be trusted to sit before the caret.
    case reset
}

/// A trigger was typed.
public struct SnippetMatch: Equatable, Sendable {
    public let snippet: Snippet
    /// How many characters to delete before inserting (the trigger's length).
    public let deleteCount: Int
}

/// Remembers the last characters typed and says when they end with a snippet's trigger. Pure: no events, no clock.
///
/// When several triggers match (`;sig` and `sig` after typing `;sig`), the longest one wins. A trigger that another
/// starts with (`;s` and `;sig`) fires as soon as it is typed; Settings warns about that (`SnippetTriggerRules`).
public struct SnippetMatcher: Sendable {
    /// Longest trigger, in characters. The buffer never holds more than this.
    public static let maximumTriggerLength = 32

    /// Triggers, longest first, so the first one the buffer ends with is the longest match.
    private var triggers: [(trigger: String, snippet: Snippet)] = []
    private(set) public var buffer: String = ""
    private var capacity = 0

    public init(snippets: [Snippet] = []) {
        update(snippets: snippets)
    }

    /// Replaces the snippets. Empty triggers, and triggers with whitespace or too long to match, are left out;
    /// for a trigger used twice, the first snippet keeps it.
    public mutating func update(snippets: [Snippet]) {
        var seen = Set<String>()
        var list: [(String, Snippet)] = []
        for snippet in snippets {
            let trigger = snippet.trigger
            guard !trigger.isEmpty,
                  trigger.count <= Self.maximumTriggerLength,
                  !trigger.contains(where: { $0.isWhitespace || $0.isNewline }),
                  seen.insert(trigger).inserted else { continue }
            list.append((trigger, snippet))
        }
        triggers = list.sorted { $0.0.count > $1.0.count }
        capacity = triggers.first?.trigger.count ?? 0
        trim()
    }

    public var isEmpty: Bool { triggers.isEmpty }

    /// Feeds one key press. Returns the snippet to expand, if this press completed its trigger; the buffer is then
    /// emptied, so the expanded text never takes part in the next match.
    public mutating func handle(_ input: SnippetKeyInput) -> SnippetMatch? {
        switch input {
        case .reset:
            buffer = ""
            return nil
        case .backspace:
            if !buffer.isEmpty { buffer.removeLast() }
            return nil
        case .characters(let typed):
            guard !typed.isEmpty, capacity > 0 else { return nil }
            // A line break or tab typed as a character (some keyboards and input methods) also cuts the buffer.
            if typed.contains(where: \.isNewline) {
                buffer = ""
                return nil
            }
            buffer += typed
            trim()
            for entry in triggers where buffer.hasSuffix(entry.trigger) {
                buffer = ""
                return SnippetMatch(snippet: entry.snippet, deleteCount: entry.trigger.count)
            }
            return nil
        }
    }

    private mutating func trim() {
        if buffer.count > capacity {
            buffer = String(buffer.suffix(capacity))
        }
    }
}
