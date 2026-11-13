import Foundation
import AppKit
import Combine
import Carbon.HIToolbox

/// What the service inserts with. `SnippetInserter` is the real one.
@MainActor
public protocol SnippetInserting: AnyObject {
    @discardableResult
    func insert(_ expansion: SnippetExpansion, deletingCharacters deleteCount: Int) -> SnippetInsertionResult
    /// The text on the user's clipboard, even while a snippet sits there waiting for the clipboard to be put back.
    func userClipboardText() -> String?
    /// Puts the user's clipboard back at once if a snippet is still waiting on it.
    func restoreNow()
}

extension SnippetInserter: SnippetInserting {
    public func userClipboardText() -> String? {
        if let text = pendingClipboardText { return text }
        return pasteboard.string(forType: .string)
    }
}

/// Expands triggers as the user types, and inserts snippets chosen from the menu.
///
/// Typed expansion runs only while `SnippetSettings.isTypedExpansionEnabled` is on and the key source could start
/// (Accessibility). Each key goes to `SnippetMatcher`; a completed trigger is checked against `SnippetExpansionGate`
/// (secure input, clipboard-ignored apps, apps excluded for snippets, Zenith itself) and then expanded on the next
/// turn of the main loop, after the key that completed it has reached the app.
@MainActor
public final class SnippetExpansionService: ObservableObject {
    public static let shared: SnippetExpansionService = makeShared()

    /// Every argument spelled out: Swift 6.1 (CI) crashes while compiling a static initializer that evaluates
    /// main-actor default arguments.
    private static func makeShared() -> SnippetExpansionService {
        let inserter = SnippetInserter(
            pasteboard: NSPasteboard.general,
            paster: AutoPasteService.shared,
            keys: SystemSnippetKeyPoster(),
            isTrusted: { SystemPermissions.checkAccessibilityPermission() },
            scheduler: MainQueueClipboardScheduler(),
            onOwnWrite: { PasteboardMonitor.shared.markOwnWrite(changeCount: $0) }
        )
        return SnippetExpansionService(
            library: SnippetLibrary.shared,
            settings: SnippetSettings.shared,
            keySource: EventTapSnippetKeySource(),
            inserter: inserter,
            frontmostBundleIdentifier: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
            isSecureInputOn: { IsSecureEventInputEnabled() },
            clipboardIgnoredApps: { ClipboardPrivacySettings.shared.ignoredAppBundleIdentifiers },
            ownBundleIdentifier: Bundle.main.bundleIdentifier,
            now: { Date() },
            deferExpansion: true
        )
    }

    /// Whether the key source is running (typed expansion is on and allowed).
    @Published public private(set) var isListening = false
    /// Typed expansion is on but the key source could not start: Accessibility is missing.
    @Published public private(set) var needsAccessibility = false
    /// The last decision for a typed trigger, for tests and diagnostics.
    public private(set) var lastDecision: SnippetExpansionDecision?

    public let library: SnippetLibrary
    public let settings: SnippetSettings

    private let keySource: SnippetKeySource
    private let inserter: SnippetInserting
    private let frontmostBundleIdentifier: @MainActor () -> String?
    private let isSecureInputOn: @MainActor () -> Bool
    private let clipboardIgnoredApps: @MainActor () -> [String]
    private let ownBundleIdentifier: String?
    private let now: @Sendable () -> Date
    private let deferExpansion: Bool

    private var matcher = SnippetMatcher()
    private var cancellables = Set<AnyCancellable>()

    /// - Parameter deferExpansion: true in the app, so the key that completed a trigger reaches the app before the
    ///   trigger is deleted; tests pass false and see the insertion at once.
    public init(
        library: SnippetLibrary = .shared,
        settings: SnippetSettings = .shared,
        keySource: SnippetKeySource,
        inserter: SnippetInserting,
        frontmostBundleIdentifier: @escaping @MainActor () -> String?,
        isSecureInputOn: @escaping @MainActor () -> Bool,
        clipboardIgnoredApps: @escaping @MainActor () -> [String],
        ownBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        now: @escaping @Sendable () -> Date = { Date() },
        deferExpansion: Bool = true
    ) {
        self.library = library
        self.settings = settings
        self.keySource = keySource
        self.inserter = inserter
        self.frontmostBundleIdentifier = frontmostBundleIdentifier
        self.isSecureInputOn = isSecureInputOn
        self.clipboardIgnoredApps = clipboardIgnoredApps
        self.ownBundleIdentifier = ownBundleIdentifier
        self.now = now
        self.deferExpansion = deferExpansion
        matcher.update(snippets: library.snippets)

        library.$snippets
            .dropFirst()
            .sink { [weak self] snippets in
                MainActor.assumeIsolated { self?.matcher.update(snippets: snippets) }
            }
            .store(in: &cancellables)
        settings.$isTypedExpansionEnabled
            .dropFirst()
            .sink { [weak self] _ in
                // `$` publishes before the property is set: look again on the next turn.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.refresh() } }
            }
            .store(in: &cancellables)
    }

    /// Starts or stops listening to match the setting. Call it again after Accessibility may have been granted.
    public func refresh() {
        let wanted = settings.isTypedExpansionEnabled
        if wanted, !keySource.isRunning {
            let started = keySource.start { [weak self] input in self?.handle(input) }
            setState(listening: started, needsAccessibility: !started)
        } else if !wanted, keySource.isRunning {
            keySource.stop()
            _ = matcher.handle(.reset)
            setState(listening: false, needsAccessibility: false)
        } else {
            setState(listening: keySource.isRunning, needsAccessibility: wanted && !keySource.isRunning)
        }
    }

    /// Stops listening and puts the user's clipboard back if a snippet still sits on it (before quitting).
    public func stop() {
        keySource.stop()
        inserter.restoreNow()
        setState(listening: false, needsAccessibility: false)
    }

    private func setState(listening: Bool, needsAccessibility: Bool) {
        if isListening != listening { isListening = listening }
        if self.needsAccessibility != needsAccessibility { self.needsAccessibility = needsAccessibility }
    }

    // MARK: Typing

    func handle(_ input: SnippetKeyInput) {
        guard let match = matcher.handle(input) else { return }
        let decision = SnippetExpansionGate.decide(
            isEnabled: settings.isTypedExpansionEnabled,
            isSecureInputOn: isSecureInputOn(),
            frontmostBundleIdentifier: frontmostBundleIdentifier(),
            ownBundleIdentifier: ownBundleIdentifier,
            clipboardIgnoredApps: clipboardIgnoredApps(),
            snippetExcludedApps: settings.excludedAppBundleIdentifiers
        )
        lastDecision = decision
        guard decision == .expand else { return }
        let expansion = expand(match.snippet)
        if deferExpansion {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    _ = self?.inserter.insert(expansion, deletingCharacters: match.deleteCount)
                }
            }
        } else {
            inserter.insert(expansion, deletingCharacters: match.deleteCount)
        }
    }

    // MARK: Menu and preview

    /// The snippet's text as it would be inserted now.
    public func expand(_ snippet: Snippet) -> SnippetExpansion {
        let clipboard = inserter.userClipboardText()
        return SnippetExpander(now: now, clipboardText: { clipboard }).expand(snippet.body)
    }

    /// Inserts a snippet chosen from the menu where the user was typing (no trigger to delete).
    @discardableResult
    public func insertFromMenu(_ snippet: Snippet) -> SnippetInsertionResult {
        _ = matcher.handle(.reset)
        return inserter.insert(expand(snippet), deletingCharacters: 0)
    }
}
