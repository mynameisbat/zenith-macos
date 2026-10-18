import Foundation

/// Discriminated category of clipboard content.
public enum ClipboardItemType: String, Sendable, Codable, CaseIterable {
    case plainText
    case richText
    case image
}

/// Strongly typed payload variants for clipboard items.
public enum ClipboardPayload: Sendable, Codable, Equatable, Hashable {
    case plainText(String)
    case richText(rtfData: Data, plainText: String)
    case image(data: Data, width: Int, height: Int)
}

/// Immutable domain model representing a single historical clipboard entry.
public struct ClipboardItem: Identifiable, Sendable, Equatable, Hashable, Codable {
    /// Unique identifier for the item.
    public let id: UUID
    
    /// Capture timestamp when the item was copied.
    public let timestamp: Date
    
    /// Category indicator for filtering and icon display.
    public let itemType: ClipboardItemType
    
    /// Typed content payload.
    public let payload: ClipboardPayload
    
    /// Compact text preview (up to 100 characters) for list row presentation.
    public let previewText: String
    
    /// Approximate byte size in memory.
    public let byteSize: Int
    
    /// Pinned items are exempt from FIFO capacity eviction.
    public var isPinned: Bool

    // MARK: - Pre-computed Search Metadata (Zero-Allocation Search)
    public let normalizedPreview: String
    public let isASCIIOnly: Bool
    public let foldedPreview: String
    public let previewCount: Int
    public let searchContentPrefix: String?
    public let foldedContentPrefix: String?
    public let searchContentPrefixCount: Int

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        itemType: ClipboardItemType,
        payload: ClipboardPayload,
        previewText: String,
        byteSize: Int,
        isPinned: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.itemType = itemType
        self.payload = payload
        self.previewText = previewText
        self.byteSize = byteSize
        self.isPinned = isPinned

        // 1. Precompute normalized preview and count
        let lowerPreview = previewText.lowercased()
        self.normalizedPreview = lowerPreview
        let isAscii = previewText.utf8.allSatisfy { $0 < 0x80 }
        self.isASCIIOnly = isAscii
        self.foldedPreview = isAscii ? lowerPreview : previewText.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
        self.previewCount = previewText.count

        // 2. Extract content string without 15MB grapheme cluster walk
        let contentStr: String?
        switch payload {
        case .plainText(let text): contentStr = text
        case .richText(_, let text): contentStr = text
        case .image: contentStr = nil
        }

        if let str = contentStr {
            // Check if content extends beyond previewText using bounded index stepping
            let previewLen = self.previewCount
            let hasMore = str.index(str.startIndex, offsetBy: previewLen, limitedBy: str.endIndex) != nil && str != previewText
            if hasMore {
                let bounded = String(str.prefix(4000))
                let boundedLower = bounded.lowercased()
                self.searchContentPrefix = boundedLower
                self.searchContentPrefixCount = boundedLower.count
                let bodyIsAscii = bounded.utf8.allSatisfy { $0 < 0x80 }
                self.foldedContentPrefix = bodyIsAscii ? boundedLower : bounded.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
            } else {
                self.searchContentPrefix = nil
                self.foldedContentPrefix = nil
                self.searchContentPrefixCount = 0
            }
        } else {
            self.searchContentPrefix = nil
            self.foldedContentPrefix = nil
            self.searchContentPrefixCount = 0
        }
    }

    // MARK: - Codable Custom Synthesis
    enum CodingKeys: String, CodingKey {
        case id, timestamp, itemType, payload, previewText, byteSize, isPinned
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let timestamp = try container.decode(Date.self, forKey: .timestamp)
        let itemType = try container.decode(ClipboardItemType.self, forKey: .itemType)
        let payload = try container.decode(ClipboardPayload.self, forKey: .payload)
        let previewText = try container.decode(String.self, forKey: .previewText)
        let byteSize = try container.decode(Int.self, forKey: .byteSize)
        let isPinned = try container.decode(Bool.self, forKey: .isPinned)

        self.init(
            id: id,
            timestamp: timestamp,
            itemType: itemType,
            payload: payload,
            previewText: previewText,
            byteSize: byteSize,
            isPinned: isPinned
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(itemType, forKey: .itemType)
        try container.encode(payload, forKey: .payload)
        try container.encode(previewText, forKey: .previewText)
        try container.encode(byteSize, forKey: .byteSize)
        try container.encode(isPinned, forKey: .isPinned)
    }

    /// Convenience factory for plain text items.
    public static func text(_ string: String, id: UUID = UUID(), timestamp: Date = Date(), isPinned: Bool = false) -> ClipboardItem {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = trimmed.count > 100 ? String(trimmed.prefix(100)) + "..." : trimmed
        return ClipboardItem(
            id: id,
            timestamp: timestamp,
            itemType: .plainText,
            payload: .plainText(string),
            previewText: preview.isEmpty ? "(Empty Text)" : preview,
            byteSize: string.utf8.count,
            isPinned: isPinned
        )
    }

    /// Convenience factory for rich text items.
    public static func richText(rtfData: Data, plainText: String, id: UUID = UUID(), timestamp: Date = Date(), isPinned: Bool = false) -> ClipboardItem {
        let trimmed = plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = trimmed.count > 100 ? String(trimmed.prefix(100)) + "..." : trimmed
        return ClipboardItem(
            id: id,
            timestamp: timestamp,
            itemType: .richText,
            payload: .richText(rtfData: rtfData, plainText: plainText),
            previewText: preview.isEmpty ? "(Rich Text)" : preview,
            byteSize: rtfData.count,
            isPinned: isPinned
        )
    }

    /// Convenience factory for image items.
    public static func image(data: Data, width: Int, height: Int, id: UUID = UUID(), timestamp: Date = Date(), isPinned: Bool = false) -> ClipboardItem {
        ClipboardItem(
            id: id,
            timestamp: timestamp,
            itemType: .image,
            payload: .image(data: data, width: width, height: height),
            previewText: "Image (\(width) × \(height))",
            byteSize: data.count,
            isPinned: isPinned
        )
    }

    /// Helper accessor for plain text representation across text types.
    public var plainTextContent: String? {
        switch payload {
        case .plainText(let text):
            return text
        case .richText(_, let text):
            return text
        case .image:
            return nil
        }
    }

    /// Helper accessor for raw image data.
    public var rawImageData: Data? {
        switch payload {
        case .image(let data, _, _):
            return data
        default:
            return nil
        }
    }
}
