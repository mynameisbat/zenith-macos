import Foundation

/// What one card of the clipboard strip shows: the preview, the kind's name, the small line under it and the short
/// label of the Paste button. Worked out once per item (`ClipboardCardContentCache`), never per redraw: counting a
/// large text's characters or lines on every frame of a scrolling row would be wasted.
public struct ClipboardCardContent: Sendable, Equatable {
    public enum Preview: Sendable, Equatable {
        case text(String)
        case code(String)
        /// The host, and the rest of the address (path and query) when there is one.
        case link(host: String, path: String)
        case color(hex: String, red: Double, green: Double, blue: Double, alpha: Double)
        case image(width: Int, height: Int)
    }

    public let preview: Preview
    /// "Text", "Link", "Image", "Color", "Rich Text", or "Code" for text that reads like a command or source code.
    public let kindTitle: String
    public let symbolName: String
    /// Size, character or line count, host or dimensions: whatever says most about this kind of item.
    public let meta: String
    /// A few words for the Paste button ("Meeting notes…", "#0F62FE", "Image 1280 × 720").
    public let shortTitle: String

    /// Most characters of a text kept for its card (a card shows about eight lines).
    public static let maxSnippetCharacters = 600
    /// Longest `shortTitle`, in characters, before an ellipsis.
    public static let maxShortTitleCharacters = 18

    public static func make(for item: ClipboardItem) -> ClipboardCardContent {
        switch item.contentKind {
        case .image:
            guard case .image(_, let width, let height) = item.payload else { return fallback(for: item) }
            let title = String(localized: "Image \(String(width)) × \(String(height))")
            let dimensions = "\(width) × \(height)"
            let size = SystemCleanerService.formatBytes(Int64(item.byteSize))
            return ClipboardCardContent(
                preview: .image(width: width, height: height),
                kindTitle: ClipboardContentKind.image.title,
                symbolName: ClipboardContentKind.image.symbolName,
                meta: "\(dimensions) · \(size)",
                shortTitle: title
            )

        case .color:
            guard let hex = item.colorHex, let rgba = item.colorComponents else { return fallback(for: item) }
            let rgb = String(format: "RGB %d %d %d", Int((rgba.red * 255).rounded()), Int((rgba.green * 255).rounded()), Int((rgba.blue * 255).rounded()))
            return ClipboardCardContent(
                preview: .color(hex: hex, red: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha),
                kindTitle: ClipboardContentKind.color.title,
                symbolName: ClipboardContentKind.color.symbolName,
                meta: rgb,
                shortTitle: hex
            )

        case .link:
            guard let url = item.linkURL, let host = url.host else { return fallback(for: item) }
            var rest = url.path == "/" ? "" : url.path
            if let query = url.query, !query.isEmpty { rest += "?" + query }
            return ClipboardCardContent(
                preview: .link(host: host, path: rest),
                kindTitle: ClipboardContentKind.link.title,
                symbolName: ClipboardContentKind.link.symbolName,
                meta: host,
                shortTitle: shorten(host + rest)
            )

        case .text, .richText:
            return textContent(for: item)
        }
    }

    // MARK: Text

    private static func textContent(for item: ClipboardItem) -> ClipboardCardContent {
        let kind = item.contentKind
        let full = item.plainTextContent ?? item.previewText
        let isCode = item.looksLikeCode
        var snippet = String(full.prefix(maxSnippetCharacters)).trimmingCharacters(in: .whitespacesAndNewlines)
        if snippet.isEmpty { snippet = item.previewText }

        let title = shorten(Self.titleLine(of: snippet))

        let meta: String
        if full.utf8.count > ClipboardItem.maxStatsByteCount {
            // Too big to count cheaply: the size says enough.
            meta = SystemCleanerService.formatBytes(Int64(item.byteSize))
        } else if isCode {
            let lines = full.isEmpty ? 0 : full.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
            meta = lines == 1 ? String(localized: "1 line") : String(localized: "\(lines.formatted()) lines")
        } else {
            let characters = full.count
            meta = characters == 1 ? String(localized: "1 character") : String(localized: "\(characters.formatted()) characters")
        }

        return ClipboardCardContent(
            preview: isCode ? .code(snippet) : .text(snippet),
            kindTitle: isCode ? String(localized: "Code") : kind.title,
            symbolName: isCode ? "chevron.left.forwardslash.chevron.right" : kind.symbolName,
            meta: meta,
            shortTitle: title
        )
    }

    private static func fallback(for item: ClipboardItem) -> ClipboardCardContent {
        ClipboardCardContent(
            preview: .text(item.previewText),
            kindTitle: item.contentKind.title,
            symbolName: item.contentKind.symbolName,
            meta: SystemCleanerService.formatBytes(Int64(item.byteSize)),
            shortTitle: shorten(item.previewText)
        )
    }

    /// The line of a text that names it on the Paste button: the first one with a letter in it, trimmed. A multi-line OCR result starts with things like "- 6" or "•"
    /// that say nothing; when no line has a letter, the first line that is not empty is used.
    public static func titleLine(of text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let meaningful = lines.first(where: { line in line.contains(where: \.isLetter) }) { return meaningful }
        return lines.first ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cuts at a word when there is one in the last part of the limit ("Meeting notes:…"), else mid-word.
    private static func shorten(_ text: String) -> String {
        guard text.count > maxShortTitleCharacters else { return text }
        let head = String(text.prefix(maxShortTitleCharacters))
        if let space = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: space) >= 8 {
            return String(head[..<space]) + "…"
        }
        return head + "…"
    }

    // MARK: Colour

    /// A swatch this light wants dark text on it.
    public var prefersDarkTextOnPreview: Bool {
        guard case .color(_, let red, let green, let blue, let alpha) = preview else { return false }
        // Perceived brightness of the color itself; a mostly see-through one shows the card, so keep white text on it.
        let luminance = 0.299 * red + 0.587 * green + 0.114 * blue
        return alpha > 0.5 && luminance > 0.62
    }

    // MARK: Time

    nonisolated(unsafe) private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .named
        return formatter
    }()

    /// "2 min. ago", "yesterday": how long ago `date` was, in the user's language. Call on the main thread.
    public static func relativeTime(of date: Date, now: Date = Date()) -> String {
        // Inside the first seconds the formatter would say "in 0 sec."; a copy is never from the future.
        relativeFormatter.localizedString(for: min(date, now), relativeTo: now)
    }
}

// MARK: - Code

public extension ClipboardItem {
    /// Shell commands and source code read better in a monospaced font, and get the "Code" label on the card.
    /// A guess from the first 400 characters: a known command at the start, or two code marks anywhere in it.
    var looksLikeCode: Bool {
        guard contentKind == .text || contentKind == .richText, let text = plainTextContent?.prefix(400) else { return false }
        let commandPrefixes = ["$ ", "swift ", "git ", "brew ", "npm ", "yarn ", "cd ", "sudo ", "curl ", "docker ", "python", "pip ", "./"]
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if commandPrefixes.contains(where: { trimmed.hasPrefix($0) }) { return true }
        let codeMarks = ["{", "}", ";", "=>", "->", "</", "()", "==", "func ", "let ", "const ", "import "]
        return codeMarks.filter { text.contains($0) }.count >= 2
    }
}

// MARK: - Cache

/// `ClipboardCardContent` for every item the strip has drawn, by item id. An item never changes its content (pinning
/// and re-copying keep id and payload), so an entry stays right until it is evicted.
public final class ClipboardCardContentCache: @unchecked Sendable {
    public static let shared = ClipboardCardContentCache()

    private final class Box {
        let content: ClipboardCardContent
        init(_ content: ClipboardCardContent) { self.content = content }
    }

    private let cache = NSCache<NSUUID, Box>()

    public init(countLimit: Int = 300) {
        cache.countLimit = countLimit
    }

    public func content(for item: ClipboardItem) -> ClipboardCardContent {
        if let box = cache.object(forKey: item.id as NSUUID) { return box.content }
        let content = ClipboardCardContent.make(for: item)
        cache.setObject(Box(content), forKey: item.id as NSUUID)
        return content
    }

    public func cachedContent(for id: UUID) -> ClipboardCardContent? {
        cache.object(forKey: id as NSUUID)?.content
    }

    public func removeAll() {
        cache.removeAllObjects()
    }
}
