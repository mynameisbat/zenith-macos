import Foundation

/// How a history item is put back on the clipboard.
public enum ClipboardPasteVariant: Sendable, Equatable, CaseIterable {
    /// As it was copied.
    case original
    /// Text only, without fonts, colors or links (rich text becomes its plain text).
    case plainText
    /// A web link without its tracking parameters.
    case cleanedLink
}

public extension ClipboardItem {
    /// What to write to the clipboard for `variant`, or nil when the variant does not apply to this item
    /// (an image has no plain text; a link without tracking parameters has nothing to clean).
    /// The item in the history is never changed.
    func pasteboardItem(for variant: ClipboardPasteVariant) -> ClipboardItem? {
        switch variant {
        case .original:
            return self
        case .plainText:
            switch payload {
            case .plainText:
                return self
            case .richText(_, let text):
                return ClipboardItem.text(text, id: id, timestamp: timestamp, isPinned: isPinned)
            case .image:
                return nil
            }
        case .cleanedLink:
            guard let cleaned = cleanedLinkText else { return nil }
            return ClipboardItem.text(cleaned, id: id, timestamp: timestamp, isPinned: isPinned)
        }
    }

    /// Whether `variant` gives something different from pasting the item as it is.
    func offersPasteVariant(_ variant: ClipboardPasteVariant) -> Bool {
        switch variant {
        case .original: return true
        case .plainText: return itemType == .richText
        case .cleanedLink: return cleanedLinkText != nil
        }
    }

    /// The item's link without tracking parameters, when it is one web link that has some.
    var cleanedLinkText: String? {
        guard linkURL != nil, let text = plainTextContent else { return nil }
        return TrackingLinkCleaner.cleanedIfChanged(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
