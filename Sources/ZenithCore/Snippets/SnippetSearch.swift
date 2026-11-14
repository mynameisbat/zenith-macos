import Foundation

/// Ranks snippets for the snippet menu: a trigger or name that starts with the query first, then ones containing it,
/// then fuzzy matches (the query's letters in order) in the name, trigger or body. Case and accents are ignored.
public enum SnippetSearch {
    public static func search(_ query: String, in snippets: [Snippet]) -> [Snippet] {
        let needle = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return snippets }
        return snippets.enumerated()
            .compactMap { offset, snippet in score(needle, snippet).map { (snippet, $0, offset) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }
            .map(\.0)
    }

    static func score(_ needle: String, _ snippet: Snippet) -> Int? {
        let name = fold(snippet.displayName)
        let trigger = fold(snippet.trigger)
        let body = fold(snippet.body)
        if trigger == needle || name == needle { return 1000 }
        if trigger.hasPrefix(needle) || name.hasPrefix(needle) { return 800 }
        if name.contains(needle) || trigger.contains(needle) { return 600 }
        if body.contains(needle) { return 400 }
        if let gaps = subsequenceGaps(needle, in: name) { return 300 - min(gaps, 200) }
        if let gaps = subsequenceGaps(needle, in: body) { return 50 - min(gaps, 49) }
        return nil
    }

    /// How many characters lie between the query's letters when they appear in order, or nil if they do not.
    static func subsequenceGaps(_ needle: String, in haystack: String) -> Int? {
        var gaps = 0
        var started = false
        var iterator = needle.makeIterator()
        guard var wanted = iterator.next() else { return 0 }
        for character in haystack {
            if character == wanted {
                started = true
                guard let next = iterator.next() else { return gaps }
                wanted = next
            } else if started {
                gaps += 1
            }
        }
        return nil
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
