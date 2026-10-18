import Foundation
import CoreGraphics
import Observation
import Combine

// MARK: - Fuzzy Search Engine

/// High-performance fuzzy and substring search engine.
/// Meets the <5ms SLA for 500 items via fast string scanning, pre-folded search tokens, and zero ICU collation overhead.
public struct FuzzySearchEngine: Sendable {
    public init() {}

    /// Filters and ranks items according to the query.
    public func search(query: String, in items: [ClipboardItem]) -> [ClipboardItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }
        guard !items.isEmpty else { return [] }

        // Short-circuit pathological queries exceeding content window
        if trimmed.count > 4000 { return [] }

        // Upfront query sanitation & length clamping
        let clamped = trimmed.count > 120 ? String(trimmed.prefix(120)) : trimmed
        let queryHasNonASCII = clamped.utf8.contains(where: { $0 >= 0x80 })
        let lowerQuery = clamped.lowercased()
        let foldedQuery = queryHasNonASCII ? clamped.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased() : lowerQuery
        let queryLen = lowerQuery.count

        let spaceQuery = " " + lowerQuery
        let newlineQuery = "\n" + lowerQuery
        let spaceFolded = " " + foldedQuery
        let newlineFolded = "\n" + foldedQuery

        let typeScoreQuery = queryLen <= 8 ? lowerQuery : nil
        let queryBytes = Array(lowerQuery.utf8)
        let queryScalars = (queryLen >= 2 && queryLen <= 4 && queryHasNonASCII) ? Array(foldedQuery.unicodeScalars) : nil

        var scored: [(item: ClipboardItem, score: Int)] = []
        scored.reserveCapacity(items.count)

        for item in items {
            if let score = calculateScore(
                lowerQuery: lowerQuery,
                foldedQuery: foldedQuery,
                queryLen: queryLen,
                spaceQuery: spaceQuery,
                newlineQuery: newlineQuery,
                spaceFolded: spaceFolded,
                newlineFolded: newlineFolded,
                queryHasNonASCII: queryHasNonASCII,
                typeScoreQuery: typeScoreQuery,
                queryBytes: queryBytes,
                queryScalars: queryScalars,
                item: item
            ) {
                scored.append((item, score))
            }
        }

        // Sort descending by score, tie-break by newer timestamp first
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            return lhs.item.timestamp > rhs.item.timestamp
        }

        return scored.map(\.item)
    }

    private func calculateScore(
        lowerQuery: String,
        foldedQuery: String,
        queryLen: Int,
        spaceQuery: String,
        newlineQuery: String,
        spaceFolded: String,
        newlineFolded: String,
        queryHasNonASCII: Bool,
        typeScoreQuery: String?,
        queryBytes: [UInt8],
        queryScalars: [UnicodeScalar]?,
        item: ClipboardItem
    ) -> Int? {
        var score = 0
        let normPreview = item.normalizedPreview
        let isPureASCII = !queryHasNonASCII && item.isASCIIOnly
        let previewLen = item.previewCount

        // 1. Preview matching rules (skipped if query is longer than candidate preview)
        if queryLen <= previewLen {
            if isPureASCII {
                // Pure ASCII Fast-Path
                if normPreview == lowerQuery {
                    score = 1000
                } else if normPreview.hasPrefix(lowerQuery) {
                    score = 500
                } else if let range = normPreview.range(of: lowerQuery) {
                    let isWordBoundary: Bool = {
                        if range.lowerBound == normPreview.startIndex { return true }
                        let prevChar = normPreview[normPreview.index(before: range.lowerBound)]
                        return prevChar == " " || prevChar == "\n" || prevChar == "\t"
                    }()
                    if isWordBoundary {
                        score = 350
                    } else {
                        let distance = normPreview.utf8.distance(from: normPreview.utf8.startIndex, to: range.lowerBound.samePosition(in: normPreview.utf8) ?? normPreview.utf8.startIndex)
                        score = 250 + max(0, 50 - distance)
                    }
                }
            } else {
                // Unicode / Diacritic Fast-Path (Pre-folded, Zero ICU calls)
                let foldedPreview = item.foldedPreview
                if foldedPreview == foldedQuery {
                    score = 1000
                } else if foldedPreview.hasPrefix(foldedQuery) {
                    score = 500
                } else if let range = foldedPreview.range(of: foldedQuery) {
                    let isWordBoundary: Bool = {
                        if range.lowerBound == foldedPreview.startIndex { return true }
                        let prevChar = foldedPreview[foldedPreview.index(before: range.lowerBound)]
                        return prevChar == " " || prevChar == "\n" || prevChar == "\t"
                    }()
                    if isWordBoundary {
                        score = 350
                    } else {
                        let distance = foldedPreview.utf8.distance(from: foldedPreview.utf8.startIndex, to: range.lowerBound.samePosition(in: foldedPreview.utf8) ?? foldedPreview.utf8.startIndex)
                        score = 250 + max(0, 50 - distance)
                    }
                }
            }
        }

        // 2. Explicit type query search
        var typeScore = 0
        if let tq = typeScoreQuery {
            typeScore = calculateTypeScore(query: tq, itemType: item.itemType)
            score += typeScore
        }

        // 3. Substring in body content (only if preview didn't match and content exists)
        if score == 0, let contentPrefix = item.searchContentPrefix, queryLen <= item.searchContentPrefixCount {
            if isPureASCII {
                if let range = contentPrefix.range(of: lowerQuery) {
                    let distance = contentPrefix.utf8.distance(from: contentPrefix.utf8.startIndex, to: range.lowerBound.samePosition(in: contentPrefix.utf8) ?? contentPrefix.utf8.startIndex)
                    score = 150 + max(0, 30 - distance)
                }
            } else if let foldedContent = item.foldedContentPrefix {
                if let range = foldedContent.range(of: foldedQuery) {
                    let distance = foldedContent.utf8.distance(from: foldedContent.utf8.startIndex, to: range.lowerBound.samePosition(in: foldedContent.utf8) ?? foldedContent.utf8.startIndex)
                    score = 150 + max(0, 30 - distance)
                }
            }
        }

        // 4. Fuzzy subsequence match (short queries 2...4 chars when no other match)
        if score == 0 && queryLen >= 2 && queryLen <= 4 && typeScore == 0 && queryLen <= previewLen {
            if isPureASCII {
                if let subseq = fuzzySubsequenceScoreASCII(queryBytes: queryBytes, target: normPreview) {
                    score = subseq
                }
            } else if let scalars = queryScalars {
                if let subseq = fuzzySubsequenceScoreUnicode(queryScalars: scalars, target: item.foldedPreview) {
                    score = subseq
                }
            }
        }

        // 5. Pinned item affinity bonus
        if score > 0 && item.isPinned {
            score += 15
        }

        return score > 0 ? score : nil
    }

    private func calculateTypeScore(query: String, itemType: ClipboardItemType) -> Int {
        switch itemType {
        case .image:
            if ["image", "img", "picture", "png", "tiff"].contains(query) { return 300 }
        case .richText:
            if ["rtf", "rich", "richtext"].contains(query) { return 300 }
        case .plainText:
            if ["text", "txt", "plain"].contains(query) { return 300 }
        }
        return 0
    }

    private func fuzzySubsequenceScoreASCII(queryBytes: [UInt8], target: String) -> Int? {
        var qIdx = 0
        let qLen = queryBytes.count
        var consecutive = 0
        var score = 50
        var lastTargetOffset = 0
        var currentTargetOffset = 0

        for byte in target.utf8 {
            if byte == queryBytes[qIdx] {
                let gap = currentTargetOffset - lastTargetOffset - 1
                if gap > 0 {
                    score -= min(gap, 10)
                    consecutive = 0
                } else {
                    consecutive += 1
                    score += (consecutive * 15)
                }
                lastTargetOffset = currentTargetOffset
                qIdx += 1
                if qIdx == qLen {
                    return max(1, score)
                }
            }
            currentTargetOffset += 1
        }
        return nil
    }

    private func fuzzySubsequenceScoreUnicode(queryScalars: [UnicodeScalar], target: String) -> Int? {
        var qIdx = 0
        let qLen = queryScalars.count
        var consecutive = 0
        var score = 50
        var lastTargetOffset = 0
        var currentTargetOffset = 0

        for scalar in target.unicodeScalars {
            if scalar == queryScalars[qIdx] {
                let gap = currentTargetOffset - lastTargetOffset - 1
                if gap > 0 {
                    score -= min(gap, 10)
                    consecutive = 0
                } else {
                    consecutive += 1
                    score += (consecutive * 15)
                }
                lastTargetOffset = currentTargetOffset
                qIdx += 1
                if qIdx == qLen {
                    return max(1, score)
                }
            }
            currentTargetOffset += 1
        }
        return nil
    }
}

// MARK: - Clipboard Store

/// Concurrency-safe history store managing historical clipboard items.
/// Conforms to @Observable (macOS 14+ SwiftUI) and ObservableObject (AppKit/Combine).
@Observable
public final class ClipboardStore: ObservableObject, @unchecked Sendable {
    public static let shared = ClipboardStore()

    @ObservationIgnored
    private let lock = NSLock()

    @ObservationIgnored
    private let pasteboardService: PasteboardServiceProtocol

    @ObservationIgnored
    private let settingsStore: SettingsStore

    @ObservationIgnored
    private var _capacityOverride: Int?

    @ObservationIgnored
    private var _items: [ClipboardItem] = []

    @ObservationIgnored
    private var _searchQuery: String = ""

    @ObservationIgnored
    private let searchEngine = FuzzySearchEngine()

    // MARK: - Initializers

    public init(
        pasteboardService: PasteboardServiceProtocol = PasteboardMonitor.shared,
        settingsStore: SettingsStore = .shared,
        initialItems: [ClipboardItem] = []
    ) {
        self.pasteboardService = pasteboardService
        self.settingsStore = settingsStore
        self._items = initialItems
        self._capacityOverride = nil
    }

    /// Convenience initializer for unit tests with a fixed capacity limit.
    public convenience init(capacity: Int) {
        self.init(initialItems: [])
        self._capacityOverride = capacity
    }

    // MARK: - Observable Properties

    /// Ordered historical items (newest at index 0).
    public var items: [ClipboardItem] {
        get {
            access(keyPath: \.items)
            lock.lock()
            defer { lock.unlock() }
            return _items
        }
        set {
            withMutation(keyPath: \.items) {
                lock.lock()
                _items = newValue
                lock.unlock()
                notifyChange()
            }
        }
    }

    /// Current search query string.
    public var searchQuery: String {
        get {
            access(keyPath: \.searchQuery)
            lock.lock()
            defer { lock.unlock() }
            return _searchQuery
        }
        set {
            withMutation(keyPath: \.searchQuery) {
                lock.lock()
                _searchQuery = newValue
                lock.unlock()
                notifyChange()
            }
        }
    }

    /// Filtered items matching current search query.
    public var filteredItems: [ClipboardItem] {
        access(keyPath: \.searchQuery)
        access(keyPath: \.items)
        lock.lock()
        let query = _searchQuery
        let currentItems = _items
        lock.unlock()

        return searchEngine.search(query: query, in: currentItems)
    }

    /// Capacity bound currently in effect.
    public var capacity: Int {
        lock.lock()
        defer { lock.unlock() }
        return _capacityOverride ?? settingsStore.historyLimit
    }

    // MARK: - Monitoring Control

    /// Connects to the pasteboard service and begins ingestion.
    public func startMonitoring() {
        pasteboardService.startMonitoring { [weak self] item in
            self?.ingest(item)
        }
    }

    /// Stops monitoring the pasteboard service.
    public func stopMonitoring() {
        pasteboardService.stopMonitoring()
    }

    // MARK: - Ingestion & Mutation

    /// Ingests a new clipboard item with deduplication and capacity eviction.
    public func add(_ item: ClipboardItem) {
        lock.lock()

        // 1. Consecutive deduplication: update timestamp of front item
        if let first = _items.first, first.payload == item.payload {
            _items[0] = ClipboardItem(
                id: first.id,
                timestamp: Date(),
                itemType: first.itemType,
                payload: first.payload,
                previewText: first.previewText,
                byteSize: first.byteSize,
                isPinned: first.isPinned
            )
            lock.unlock()
            notifyChange()
            if case .image(let data, _, _) = item.payload {
                ImageThumbnailService.shared.preloadThumbnail(for: item.id, data: data)
            }
            return
        }

        // 2. Non-consecutive duplicate: promote existing entry to front
        if let existingIndex = _items.firstIndex(where: { $0.payload == item.payload }) {
            let existing = _items.remove(at: existingIndex)
            let promoted = ClipboardItem(
                id: existing.id,
                timestamp: Date(),
                itemType: existing.itemType,
                payload: existing.payload,
                previewText: existing.previewText,
                byteSize: existing.byteSize,
                isPinned: existing.isPinned
            )
            _items.insert(promoted, at: 0)
            enforceCapacityLocked(preserveFrontItem: true)
            lock.unlock()
            notifyChange()
            if case .image(let data, _, _) = item.payload {
                ImageThumbnailService.shared.preloadThumbnail(for: item.id, data: data)
            }
            return
        }

        // 3. New item insertion at front
        _items.insert(item, at: 0)

        // 4. FIFO capacity eviction protecting newly added item at index 0
        enforceCapacityLocked(preserveFrontItem: true)

        lock.unlock()
        notifyChange()

        // Proactively prewarm thumbnail cache for image items
        if case .image(let data, _, _) = item.payload {
            ImageThumbnailService.shared.preloadThumbnail(for: item.id, data: data)
        }
    }

    /// Semantic alias for `add(_:)`.
    public func ingest(_ item: ClipboardItem) {
        add(item)
    }

    /// Restores a historical item to the system pasteboard.
    public func copyItemToPasteboard(_ item: ClipboardItem) {
        pasteboardService.copyItemToPasteboard(item)
    }

    /// Writes an image to the system pasteboard.
    public func writeImageToPasteboard(_ image: CGImage) {
        pasteboardService.writeImageToPasteboard(image)
    }

    /// Selects an item from history, updates its timestamp to front, and restores to pasteboard.
    public func selectAndRestoreItem(_ item: ClipboardItem) {
        lock.lock()
        if let index = _items.firstIndex(where: { $0.id == item.id }) {
            let existing = _items.remove(at: index)
            let bumped = ClipboardItem(
                id: existing.id,
                timestamp: Date(),
                itemType: existing.itemType,
                payload: existing.payload,
                previewText: existing.previewText,
                byteSize: existing.byteSize,
                isPinned: existing.isPinned
            )
            _items.insert(bumped, at: 0)
        }
        lock.unlock()
        notifyChange()
        pasteboardService.copyItemToPasteboard(item)
    }

    /// Toggles the pinned status of an item.
    public func togglePin(id: UUID) {
        lock.lock()
        if let index = _items.firstIndex(where: { $0.id == id }) {
            _items[index].isPinned.toggle()
        }
        lock.unlock()
        notifyChange()
    }

    /// Explicitly sets the pinned status of an item.
    public func setPinned(id: UUID, isPinned: Bool) {
        lock.lock()
        if let index = _items.firstIndex(where: { $0.id == id }) {
            _items[index].isPinned = isPinned
        }
        lock.unlock()
        notifyChange()
    }

    /// Removes a specific item from history.
    public func removeItem(id: UUID) {
        lock.lock()
        _items.removeAll(where: { $0.id == id })
        lock.unlock()
        notifyChange()
    }

    /// Semantic alias for `removeItem(id:)`.
    public func removeItem(by id: UUID) {
        removeItem(id: id)
    }

    /// Removes all unpinned items while strictly preserving pinned favorites.
    public func clearUnpinnedHistory() {
        lock.lock()
        _items.removeAll(where: { !$0.isPinned })
        lock.unlock()
        notifyChange()
    }

    /// Purges all items from history, including pinned items.
    public func clearAllHistory() {
        lock.lock()
        _items.removeAll()
        lock.unlock()
        notifyChange()
    }

    /// Clears history items.
    /// - Parameter includePinned: If false, pinned items remain; if true, all items are purged.
    public func clearHistory(includePinned: Bool = false) {
        if includePinned {
            clearAllHistory()
        } else {
            clearUnpinnedHistory()
        }
    }

    /// Clears unpinned history items (convenience alias).
    public func clear() {
        clearUnpinnedHistory()
    }

    /// Dynamically updates the capacity limit and triggers FIFO eviction of excess unpinned items.
    public func updateCapacity(_ newCapacity: Int) {
        lock.lock()
        _capacityOverride = newCapacity
        enforceCapacityLocked(preserveFrontItem: false)
        lock.unlock()
        notifyChange()
    }

    /// Public capacity enforcement trigger.
    public func enforceCapacityLimit() {
        lock.lock()
        enforceCapacityLocked(preserveFrontItem: false)
        lock.unlock()
        notifyChange()
    }

    // MARK: - Private Helpers

    private func enforceCapacityLocked(preserveFrontItem: Bool = false) {
        let currentCap = _capacityOverride ?? settingsStore.historyLimit
        guard _items.count > currentCap else { return }

        let minIndex = preserveFrontItem ? 1 : 0
        var index = _items.count - 1
        while _items.count > currentCap && index >= minIndex {
            if !_items[index].isPinned {
                _items.remove(at: index)
            }
            index -= 1
        }
    }

    private func notifyChange() {
        if Thread.isMainThread {
            withMutation(keyPath: \.items) {}
            objectWillChange.send()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.withMutation(keyPath: \.items) {}
                self?.objectWillChange.send()
            }
        }
    }
}
