import Foundation

/// What a clipboard item holds, as far as the panel shows it: plain text, rich text, a web link, a color code or an
/// image. Decided from the content, so a URL copied as plain text is still shown as a link.
public enum ClipboardContentKind: String, Sendable, CaseIterable {
    case text
    case richText
    case link
    case color
    case image

    public var title: String {
        switch self {
        case .text: return String(localized: "Text")
        case .richText: return String(localized: "Rich Text")
        case .link: return String(localized: "Link")
        case .color: return String(localized: "Color")
        case .image: return String(localized: "Image")
        }
    }

    public var symbolName: String {
        switch self {
        case .text: return "text.alignleft"
        case .richText: return "textformat"
        case .link: return "link"
        case .color: return "paintpalette"
        case .image: return "photo"
        }
    }
}

/// The filter chips above the clipboard list.
public enum ClipboardKindFilter: String, Sendable, CaseIterable {
    case all
    case text
    case links
    case images
    case pinned

    public var title: String {
        switch self {
        case .all: return String(localized: "All")
        case .text: return String(localized: "Text")
        case .links: return String(localized: "Links")
        case .images: return String(localized: "Images")
        case .pinned: return String(localized: "Pinned")
        }
    }

    public var symbolName: String {
        switch self {
        case .all: return "tray.full"
        case .text: return "text.alignleft"
        case .links: return "link"
        case .images: return "photo"
        case .pinned: return "pin"
        }
    }

    public func includes(_ item: ClipboardItem) -> Bool {
        switch self {
        case .all: return true
        case .text:
            switch item.contentKind {
            case .text, .richText, .color: return true
            case .link, .image: return false
            }
        case .links: return item.contentKind == .link
        case .images: return item.contentKind == .image
        case .pinned: return item.isPinned
        }
    }
}

/// Character, word and line counts of a text item.
public struct ClipboardTextStats: Sendable, Equatable {
    public let characters: Int
    public let words: Int
    public let lines: Int

    public init(characters: Int, words: Int, lines: Int) {
        self.characters = characters
        self.words = words
        self.lines = lines
    }
}

/// The day groups of the clipboard list.
public enum ClipboardDateBucket: Int, Sendable, Comparable {
    case today
    case yesterday
    case earlier

    public var title: String {
        switch self {
        case .today: return String(localized: "Today")
        case .yesterday: return String(localized: "Yesterday")
        case .earlier: return String(localized: "Earlier")
        }
    }

    public static func bucket(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> ClipboardDateBucket {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return .yesterday
        }
        return .earlier
    }

    public static func < (lhs: ClipboardDateBucket, rhs: ClipboardDateBucket) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public extension ClipboardItem {
    /// Longest text that is still looked at as a possible link or color (anything longer is just text).
    static let maxDetectableLength = 2048

    /// Largest text (in UTF-8 bytes) whose words and lines are counted; bigger items only show their size.
    static let maxStatsByteCount = 256 * 1024

    var contentKind: ClipboardContentKind {
        switch payload {
        case .image:
            return .image
        case .richText:
            return linkURL != nil ? .link : .richText
        case .plainText:
            if linkURL != nil { return .link }
            if colorHex != nil { return .color }
            return .text
        }
    }

    /// The web address when the whole item is one http(s) link.
    var linkURL: URL? {
        guard let text = plainTextContent, text.utf8.count <= Self.maxDetectableLength else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// The color as "#RRGGBB" or "#RRGGBBAA" when the item is one hex color code (#RGB, #RRGGBB or #RRGGBBAA).
    var colorHex: String? {
        guard let text = plainTextContent, text.utf8.count <= 16 else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#") else { return nil }
        let digits = trimmed.dropFirst()
        guard [3, 6, 8].contains(digits.count), digits.allSatisfy(\.isHexDigit) else { return nil }
        let expanded = digits.count == 3 ? digits.map { "\($0)\($0)" }.joined() : String(digits)
        return "#" + expanded.uppercased()
    }

    /// Red, green, blue and alpha (0...1) of `colorHex`.
    var colorComponents: (red: Double, green: Double, blue: Double, alpha: Double)? {
        guard let hex = colorHex else { return nil }
        let digits = Array(hex.dropFirst())
        func channel(_ index: Int) -> Double {
            Double(Int(String(digits[index * 2...index * 2 + 1]), radix: 16) ?? 0) / 255
        }
        return (channel(0), channel(1), channel(2), digits.count == 8 ? channel(3) : 1)
    }

    /// Counts for a text item; nil for images and for text over `maxStatsByteCount`.
    var textStats: ClipboardTextStats? {
        guard let text = plainTextContent, text.utf8.count <= Self.maxStatsByteCount else { return nil }
        var words = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            words += 1
        }
        let lines = text.isEmpty ? 0 : text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
        return ClipboardTextStats(characters: text.count, words: words, lines: lines)
    }
}
