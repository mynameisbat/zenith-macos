import Foundation

/// Whether a typed trigger may expand where the user is typing.
public enum SnippetExpansionDecision: Equatable, Sendable {
    case expand
    /// Typed expansion is switched off.
    case disabled
    /// A password field (or another app) has turned on secure keyboard input.
    case secureInput
    /// The app in front is on the clipboard's ignore list (password managers by default).
    case clipboardIgnoredApp(String)
    /// The user excluded the app in front for snippets.
    case excludedApp(String)
    /// Zenith itself is in front: typing a trigger into the snippet editor must not expand it.
    case zenith
}

/// The rules, as a pure function of what the event tap sees.
public enum SnippetExpansionGate {
    public static func decide(
        isEnabled: Bool,
        isSecureInputOn: Bool,
        frontmostBundleIdentifier: String?,
        ownBundleIdentifier: String?,
        clipboardIgnoredApps: [String],
        snippetExcludedApps: [String]
    ) -> SnippetExpansionDecision {
        guard isEnabled else { return .disabled }
        if isSecureInputOn { return .secureInput }
        guard let app = frontmostBundleIdentifier else { return .expand }
        let key = app.lowercased()
        if let own = ownBundleIdentifier, own.lowercased() == key { return .zenith }
        if clipboardIgnoredApps.contains(where: { $0.lowercased() == key }) { return .clipboardIgnoredApp(app) }
        if snippetExcludedApps.contains(where: { $0.lowercased() == key }) { return .excludedApp(app) }
        return .expand
    }
}
