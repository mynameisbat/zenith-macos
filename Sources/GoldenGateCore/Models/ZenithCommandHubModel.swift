import Foundation
import Combine

/// Supported quick action item IDs in the Zenith Command Hub action list.
public enum ZenithHubAction: String, CaseIterable, Sendable {
    case area = "area"
    case screen = "screen"

    public var title: String {
        switch self {
        case .area: return "Capture Area"
        case .screen: return "Capture Screen"
        }
    }

    public var icon: String {
        switch self {
        case .area: return "crop"
        case .screen: return "macwindow"
        }
    }

    public var shortcut: String {
        switch self {
        case .area: return "⌘⇧2"
        case .screen: return "⌘⇧1"
        }
    }

    public var keywords: [String] {
        switch self {
        case .area:
            return ["area", "capture", "snip", "snipping", "crop", "selection", "region", "box", "partial"]
        case .screen:
            return ["screen", "capture", "fullscreen", "full", "window", "display", "monitor", "screenshot", "desktop", "whole"]
        }
    }

    /// Evaluates if the action matches a search query string.
    public func matches(query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return true }

        let titleLower = title.lowercased()
        let rawLower = rawValue.lowercased()

        if titleLower.contains(trimmed) || rawLower.contains(trimmed) {
            return true
        }

        let tokens = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return true }

        let allTerms = [titleLower, rawLower] + keywords
        return tokens.allSatisfy { token in
            allTerms.contains { term in
                term.contains(token) || token.contains(term)
            }
        }
    }
}

/// A row in the Command Hub that can be reached with the arrow keys.
public enum ZenithHubEntry: Equatable, Sendable {
    case action(ZenithHubAction)
    case clip(ClipboardItem)
}

/// Potentially destructive Command Hub operations that require an inline confirmation before running.
public enum ZenithHubConfirmation: Equatable, Sendable {
    case cleanJunk(formattedSize: String)
    case optimizeSystem
    case terminateProcess(pid: Int, name: String)
    case purgeZombies(count: Int)

    public var title: String {
        switch self {
        case .cleanJunk(let formattedSize): return "Clean \(formattedSize) of junk?"
        case .optimizeSystem: return "Run system maintenance?"
        case .terminateProcess(_, let name): return "Quit \(name)?"
        case .purgeZombies(let count): return "Purge \(count) zombie process\(count == 1 ? "" : "es")?"
        }
    }

    public var message: String {
        switch self {
        case .cleanJunk: return "Selected caches and logs will be permanently deleted."
        case .optimizeSystem: return "Flushes DNS, refreshes QuickLook and stops .DS_Store on network drives."
        case .terminateProcess(let pid, _): return "Unsaved work in this app may be lost (PID \(pid))."
        case .purgeZombies: return "Signals the parent processes to reap defunct children."
        }
    }

    public var confirmTitle: String {
        switch self {
        case .cleanJunk: return "Clean"
        case .optimizeSystem: return "Run"
        case .terminateProcess: return "Quit Process"
        case .purgeZombies: return "Purge"
        }
    }

    public var icon: String {
        switch self {
        case .cleanJunk: return "broom.fill"
        case .optimizeSystem: return "sparkles"
        case .terminateProcess: return "xmark.octagon.fill"
        case .purgeZombies: return "bolt.fill"
        }
    }

    public var isDestructive: Bool {
        switch self {
        case .optimizeSystem: return false
        default: return true
        }
    }
}

/// State controller for hover states, active search query, and selections in Zenith Command Hub.
@MainActor
public final class ZenithCommandHubState: ObservableObject {
    public static let shared = ZenithCommandHubState()

    @Published public var searchText: String = ""
    @Published public var hoveredActionId: String? = nil
    @Published public var hoveredClipId: UUID? = nil
    @Published public var hoveredFooterId: String? = nil
    @Published public var quickLookItem: ClipboardItem? = nil
    @Published public var presentationID: UUID = UUID()
    @Published public var hardwareSnapshot: HardwareSnapshot = HardwareTelemetryService.shared.fetchSnapshot()
    @Published public var showTopHogs: Bool = false
    /// Keyboard (arrow key) selection into `entries(in:)`; nil when nothing is selected.
    @Published public var selectedEntryIndex: Int? = nil
    @Published public var pendingConfirmation: ZenithHubConfirmation? = nil

    public init() {}

    // MARK: - Visible Content

    public var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var matchingActions: [ZenithHubAction] {
        let query = trimmedQuery
        if query.isEmpty {
            return ZenithHubAction.allCases
        }
        return ZenithHubAction.allCases.filter { $0.matches(query: query) }
    }

    /// All clips matching the current query (empty when there is no query).
    public func allMatchedClips(in items: [ClipboardItem]) -> [ClipboardItem] {
        let query = trimmedQuery
        guard !query.isEmpty else { return [] }
        return FuzzySearchEngine().search(query: query, in: items)
    }

    /// Clips shown in the hub: the 4 most recent, or the top 5 search results.
    public func visibleClips(in items: [ClipboardItem]) -> [ClipboardItem] {
        if trimmedQuery.isEmpty {
            return Array(items.prefix(4))
        }
        return Array(allMatchedClips(in: items).prefix(5))
    }

    /// Rows reachable with the arrow keys, in on-screen order.
    public func entries(in items: [ClipboardItem]) -> [ZenithHubEntry] {
        matchingActions.map { ZenithHubEntry.action($0) } + visibleClips(in: items).map { ZenithHubEntry.clip($0) }
    }

    // MARK: - Keyboard Selection

    /// Moves the arrow-key selection, wrapping around at both ends.
    public func moveSelection(by delta: Int, entryCount: Int) {
        guard entryCount > 0 else {
            selectedEntryIndex = nil
            return
        }
        guard let current = selectedEntryIndex, current < entryCount else {
            selectedEntryIndex = delta >= 0 ? 0 : entryCount - 1
            return
        }
        selectedEntryIndex = ((current + delta) % entryCount + entryCount) % entryCount
    }

    public func clearSelection() {
        selectedEntryIndex = nil
    }

    // MARK: - Confirmation

    public func requestConfirmation(_ confirmation: ZenithHubConfirmation) {
        pendingConfirmation = confirmation
    }

    public func cancelConfirmation() {
        pendingConfirmation = nil
    }

    public func refreshHardwareSnapshot() {
        hardwareSnapshot = HardwareTelemetryService.shared.fetchSnapshot()
    }

    public func toggleTopHogs() {
        showTopHogs.toggle()
        refreshHardwareSnapshot()
    }

    public func killProcess(pid: Int) {
        HardwareTelemetryService.shared.killProcess(pid: pid, force: false)
        refreshHardwareSnapshot()
    }

    public func setSearchText(_ text: String) {
        searchText = text
        selectedEntryIndex = nil
    }

    public func setHoveredAction(_ id: String?) {
        hoveredActionId = id
    }

    public func clearHoveredAction(ifCurrent id: String) {
        if hoveredActionId == id {
            hoveredActionId = nil
        }
    }

    public func setHoveredClip(_ id: UUID?) {
        hoveredClipId = id
    }

    public func clearHoveredClip(ifCurrent id: UUID) {
        if hoveredClipId == id {
            hoveredClipId = nil
        }
    }

    public func setHoveredFooter(_ id: String?) {
        hoveredFooterId = id
    }

    public func clearHoveredFooter(ifCurrent id: String) {
        if hoveredFooterId == id {
            hoveredFooterId = nil
        }
    }

    public func reset() {
        searchText = ""
        hoveredActionId = nil
        hoveredClipId = nil
        hoveredFooterId = nil
        quickLookItem = nil
        selectedEntryIndex = nil
        pendingConfirmation = nil
        presentationID = UUID()
    }
}
