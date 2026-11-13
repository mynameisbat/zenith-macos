import Foundation
import AppKit

// MARK: - Frontmost App

/// Tells which app is in front, so a copy can be attributed to it. The monitor asks it when it sees a change;
/// tests pass `MockFrontmostApplicationProvider` and never depend on what is really in front.
public protocol FrontmostApplicationProviding: Sendable {
    /// The bundle identifier of the frontmost app, or nil when unknown. Called on the main thread.
    func frontmostBundleIdentifier() -> String?
}

/// The real one: `NSWorkspace.frontmostApplication`.
public struct WorkspaceFrontmostApplicationProvider: FrontmostApplicationProviding {
    public init() {}

    public func frontmostBundleIdentifier() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
}

// MARK: - What the monitor is told to do

/// The clipboard settings the pasteboard monitor applies while it reads a copy. Pushed in by `ClipboardPrivacySettings`.
public struct ClipboardCaptureOptions: Sendable, Equatable {
    /// Bundle identifiers (compared without case) of apps whose copies are not kept.
    public var ignoredBundleIdentifiers: Set<String>
    /// Rewrite a copied web link without its tracking parameters.
    public var cleanLinksOnCopy: Bool

    public init(ignoredBundleIdentifiers: Set<String> = [], cleanLinksOnCopy: Bool = false) {
        self.ignoredBundleIdentifiers = Set(ignoredBundleIdentifiers.map { $0.lowercased() })
        self.cleanLinksOnCopy = cleanLinksOnCopy
    }
}

/// Whether a copy goes into the history.
public enum ClipboardCaptureDecision: Equatable, Sendable {
    case record
    /// The copying app marked it as a password, temporary or generated (`org.nspasteboard.ConcealedType`, …).
    case skipSensitive
    /// It was copied while an ignored app was in front.
    case skipIgnoredApp(String)
}

public enum ClipboardCapturePolicy {
    /// Decides from the pasteboard's types (all of them, and each item's) and the frontmost app.
    public static func decide(
        types: [String],
        itemTypes: [[String]] = [],
        frontmostBundleIdentifier: String?,
        options: ClipboardCaptureOptions
    ) -> ClipboardCaptureDecision {
        if SensitivePasteboardMarker.isSensitive(types: types)
            || itemTypes.contains(where: { SensitivePasteboardMarker.isSensitive(types: $0) }) {
            return .skipSensitive
        }
        if let bundleID = frontmostBundleIdentifier,
           options.ignoredBundleIdentifiers.contains(bundleID.lowercased()) {
            return .skipIgnoredApp(bundleID)
        }
        return .record
    }

    // MARK: Cleaning a copied link

    /// Types a copied link may carry and still be rewritten without losing anything: plain text and URL flavors.
    /// Anything else (rich text, HTML, a file, an image, an app's private type) leaves the copy alone.
    public static let rewritableLinkTypes: Set<String> = [
        "public.utf8-plain-text", "public.utf16-plain-text", "public.utf16-external-plain-text",
        "public.plain-text", "NSStringPboardType",
        "public.url", "public.url-name", "NSURLPboardType", "Apple URL pasteboard type",
        "CorePasteboardFlavorType 0x75726C20", "CorePasteboardFlavorType 0x75726C6E"
    ]

    /// The text to write back when the copy is exactly one http(s) link with tracking parameters and holds nothing
    /// that a rewrite would lose; nil to leave the clipboard as it is. Whitespace around the link is kept.
    /// `types` are the types declared on the copy's single pasteboard item.
    public static func cleanedLinkRewrite(types: [String], string: String?) -> String? {
        guard let string, !types.isEmpty,
              types.allSatisfy({ rewritableLinkTypes.contains($0) }) else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let cleaned = TrackingLinkCleaner.cleanedIfChanged(trimmed),
              let range = string.range(of: trimmed) else { return nil }
        return string.replacingCharacters(in: range, with: cleaned)
    }
}
