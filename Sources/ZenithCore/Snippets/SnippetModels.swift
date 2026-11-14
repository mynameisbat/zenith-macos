import Foundation
import Combine

/// The snippet menu: a search field over the snippets and a selection moved with the arrow keys.
@MainActor
public final class SnippetPickerModel: ObservableObject {
    @Published public var query: String = "" {
        didSet { if query != oldValue { selectedIndex = 0 } }
    }
    @Published public private(set) var selectedIndex: Int = 0

    private let library: SnippetLibrary
    private var cancellable: AnyCancellable?

    public init(library: SnippetLibrary = .shared) {
        self.library = library
        cancellable = library.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        }
    }

    public var results: [Snippet] {
        SnippetSearch.search(query, in: library.snippets)
    }

    public var selected: Snippet? {
        let list = results
        guard !list.isEmpty else { return nil }
        return list[min(max(selectedIndex, 0), list.count - 1)]
    }

    public func moveSelection(by step: Int) {
        let count = results.count
        guard count > 0 else { return }
        selectedIndex = min(max(min(selectedIndex, count - 1) + step, 0), count - 1)
    }

    public func select(_ snippet: Snippet) {
        if let index = results.firstIndex(where: { $0.id == snippet.id }) { selectedIndex = index }
    }

    /// Back to an empty search, for the next time the menu opens.
    public func reset() {
        query = ""
        selectedIndex = 0
    }
}

/// A snippet being added or edited in Settings, with its trigger problems and a preview of what it inserts.
@MainActor
public final class SnippetEditorModel: ObservableObject, Identifiable {
    public let id: UUID
    public let isNew: Bool
    @Published public var name: String
    @Published public var trigger: String
    @Published public var body: String

    private let library: SnippetLibrary
    private let preview: @MainActor (Snippet) -> SnippetExpansion

    public init(
        snippet: Snippet?,
        library: SnippetLibrary,
        preview: @escaping @MainActor (Snippet) -> SnippetExpansion
    ) {
        let draft = snippet ?? Snippet(name: "", trigger: "", body: "")
        self.id = draft.id
        self.isNew = snippet == nil
        self.name = draft.name
        self.trigger = draft.trigger
        self.body = draft.body
        self.library = library
        self.preview = preview
    }

    public var draft: Snippet {
        Snippet(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), trigger: trigger, body: body)
    }

    public var issues: [SnippetTriggerIssue] {
        let others = library.snippets.filter { $0.id != id }
        return SnippetTriggerRules.issues(for: draft, among: others + [draft])
    }

    /// A snippet needs text, and a trigger (if any) that can be typed.
    public var canSave: Bool {
        !body.isEmpty && !issues.contains { issue in
            switch issue {
            case .containsWhitespace, .tooLong, .duplicate: return true
            case .hidesLongerTrigger: return false
            }
        }
    }

    /// What the snippet would insert now, with `|` where the caret ends up.
    public var previewText: String {
        let expansion = preview(draft)
        guard expansion.caretOffsetFromEnd > 0 else { return expansion.text }
        var text = expansion.text
        let index = text.index(text.endIndex, offsetBy: -expansion.caretOffsetFromEnd)
        text.insert("|", at: index)
        return text
    }

    /// Adds `{name}` at the end of the body.
    public func appendVariable(_ name: String) {
        body += "{\(name)}"
    }

    @discardableResult
    public func save() -> Bool {
        guard canSave else { return false }
        library.update(draft)
        return true
    }
}
