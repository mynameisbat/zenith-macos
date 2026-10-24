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

    public init() {}

    public func setSearchText(_ text: String) {
        searchText = text
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
        presentationID = UUID()
    }
}
