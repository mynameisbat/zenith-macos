import Foundation
import CoreGraphics

/// A full page the island grows into: one of Zenith's tools, drawn inside the island instead of in a window.
///
/// A page is opened from the dock or from the Tools page (`ZenithIslandState.openPage`) and stays open until it is closed: by its
/// close button, Escape or a click anywhere else. Leaving it with the pointer does not close it, because a page is
/// something to work in (lists to scroll, fields to type in, confirmations that appear elsewhere on screen).
public enum IslandPage: String, CaseIterable, Sendable, Identifiable {
    /// What the machine is doing: running apps, CPU, memory, storage and network speed.
    case system
    /// The cleaner with its tools, the uninstaller among them.
    case cleaner
    case ports
    case homebrew
    case settings
    /// Every tool, in groups (`IslandTool.groups`): what the dock's last button opens.
    case tools

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: return String(localized: "System")
        case .cleaner: return String(localized: "Cleaner")
        case .ports: return String(localized: "Ports")
        case .homebrew: return String(localized: "Homebrew")
        case .settings: return String(localized: "Settings")
        case .tools: return String(localized: "Tools")
        }
    }

    public var icon: String {
        switch self {
        case .system: return "cpu"
        case .cleaner: return "sparkles"
        case .ports: return "network"
        case .homebrew: return "shippingbox.fill"
        case .settings: return "gearshape.fill"
        case .tools: return "square.grid.2x2.fill"
        }
    }

    /// The size the page's content wants, below the island's top strip. A small display gets less
    /// (`ZenithIslandGeometry.expandedSize`). No page is narrower than 420 pt: beside a notch its top strip has to
    /// hold the back button on one side and the page's name and the close button on the other.
    public var contentSize: CGSize {
        switch self {
        case .system: return CGSize(width: 420, height: 392)
        case .cleaner: return CGSize(width: 580, height: 480)
        case .ports: return CGSize(width: 580, height: 440)
        case .homebrew: return CGSize(width: 620, height: 480)
        case .settings: return CGSize(width: 720, height: 500)
        case .tools: return CGSize(width: 520, height: 264)
        }
    }
}

/// One of Zenith's tools as the island offers it: a button of the dock under the open island, and a labelled tile of
/// the Tools page (`IslandPage.tools`), where every tool is, in groups.
///
/// A tool starts something and nothing more: it opens its page in the island, flips a switch (Privacy Shield, Keep
/// Awake), or runs the same code the Command Hub's button did, with the same confirmations. Nothing here runs in
/// the background.
public enum IslandTool: String, CaseIterable, Sendable, Identifiable {
    case area, screen, record, ocr
    case clipboard, cleaning, privacyShield, keepAwake
    case clean, uninstall, cleaner, boost
    case system, ports, homebrew
    case settings, quit, allTools

    public var id: String { rawValue }

    /// A named group of the Tools page.
    public struct Group: Identifiable, Sendable {
        public let id: String
        public let title: String
        public let tools: [IslandTool]
    }

    /// Every tool that does something, by what it is for. Settings and Quit are not in a group: the Tools page
    /// keeps them apart, in its top strip, so nobody quits Zenith reaching for a tool.
    public static var groups: [Group] {
        [
            Group(id: "capture", title: String(localized: "Capture"), tools: [.area, .screen, .record, .ocr]),
            Group(id: "everyday", title: String(localized: "Everyday"), tools: [.clipboard, .cleaning, .privacyShield, .keepAwake]),
            Group(id: "cleanup", title: String(localized: "Clean Up"), tools: [.clean, .uninstall, .cleaner, .boost]),
            Group(id: "system", title: String(localized: "System"), tools: [.system, .ports, .homebrew])
        ]
    }

    /// The Command Hub action this tool stands for, if it is one of them.
    public var hubAction: ZenithHubAction? {
        switch self {
        case .area: return .area
        case .screen: return .screen
        case .record: return .record
        case .ocr: return .ocr
        case .clipboard: return .clipboard
        case .cleaning: return .cleaning
        default: return nil
        }
    }

    /// The page this tool opens in the island, if it opens one.
    public var page: IslandPage? {
        switch self {
        case .uninstall, .cleaner: return .cleaner
        case .system: return .system
        case .ports: return .ports
        case .homebrew: return .homebrew
        case .settings: return .settings
        case .allTools: return .tools
        default: return nil
        }
    }

    /// A switch: it shows whether it is on, and a click flips it without closing the island.
    public var isToggle: Bool {
        self == .privacyShield || self == .keepAwake
    }

    /// The tool's name, in full ("Capture Area", not "Area"): it is all a new user has to go by.
    public var title: String {
        if let hubAction { return hubAction.title }
        switch self {
        case .privacyShield: return String(localized: "Privacy Shield")
        case .keepAwake: return String(localized: "Keep Awake")
        case .clean: return String(localized: "Quick Clean")
        case .uninstall: return String(localized: "Uninstall App")
        case .cleaner: return String(localized: "Cleaner")
        case .boost: return String(localized: "Boost")
        case .system: return String(localized: "System")
        case .ports: return String(localized: "Ports")
        case .homebrew: return String(localized: "Homebrew")
        case .settings: return String(localized: "Settings")
        case .quit: return String(localized: "Quit Zenith")
        default: return String(localized: "All Tools")
        }
    }

    /// What the tool does, for its tooltip and VoiceOver.
    public var detail: String {
        if let hubAction { return hubAction.detail }
        switch self {
        case .privacyShield: return String(localized: "Look sites up over encrypted DNS through a local proxy")
        case .keepAwake: return String(localized: "Keep the Mac from going to sleep on its own")
        case .clean: return String(localized: "Scan for system junk; you confirm what to delete before anything goes")
        case .uninstall: return String(localized: "Pick an app and move it and its files to the Trash")
        case .cleaner: return String(localized: "System junk, project build folders, old installers and leftovers")
        case .boost: return String(localized: "Free inactive memory and flush the DNS cache")
        case .system: return String(localized: "Running apps, CPU, memory, storage and network speed")
        case .ports: return String(localized: "Processes listening on network ports")
        case .homebrew: return String(localized: "Installed and outdated Homebrew packages")
        case .settings: return String(localized: "Open Zenith's settings")
        case .quit: return String(localized: "Quit Zenith")
        default: return String(localized: "Every tool, in groups")
        }
    }

    public var icon: String {
        if let hubAction { return hubAction.icon }
        switch self {
        case .privacyShield: return "lock.shield.fill"
        case .keepAwake: return "mug.fill"
        case .clean: return "sparkles"
        case .uninstall: return "trash.fill"
        case .cleaner: return "externaldrive.fill"
        case .boost: return "bolt.fill"
        case .system: return IslandPage.system.icon
        case .ports: return IslandPage.ports.icon
        case .homebrew: return IslandPage.homebrew.icon
        case .settings: return IslandPage.settings.icon
        case .quit: return "power"
        default: return IslandPage.tools.icon
        }
    }

    /// The global shortcut that does the same, for the tooltip.
    public var hotKeyId: String? { hubAction?.hotKeyId }
}

/// Which tools are on the dock under the open island, and in what order. The user arranges it (the Tools page's
/// "Edit" and the dock's context menu); `IslandWidgetSettings.dockLayout` saves it.
///
/// The rules live here so every way of editing obeys them: at most `maxPinned` tools, each once, only tools that have
/// a tile on the Tools page (so never Quit, which must not sit one click from a capture button), and All Tools always
/// last and never removable, because it is the way to everything that is not on the dock.
public struct IslandDockLayout: Equatable, Sendable {
    public static let maxPinned = 6
    public static let defaultPinned: [IslandTool] = [.area, .clipboard, .clean, .uninstall, .privacyShield, .keepAwake]

    /// The tools the user chose, in order, without the fixed last button.
    public private(set) var pinned: [IslandTool]

    public init(pinned: [IslandTool] = IslandDockLayout.defaultPinned) {
        self.pinned = Self.sanitized(pinned)
    }

    /// From what was saved: `nil` (nothing saved yet) gives the default; names this version does not know are
    /// dropped; an empty list is a dock the user emptied on purpose.
    public init(storedIdentifiers: [String]?) {
        guard let storedIdentifiers else {
            self.init()
            return
        }
        self.init(pinned: storedIdentifiers.compactMap(IslandTool.init(rawValue:)))
    }

    public var storedIdentifiers: [String] { pinned.map(\.rawValue) }

    /// What the dock draws: the chosen tools, then All Tools.
    public var tools: [IslandTool] { pinned + [.allTools] }

    public var isFull: Bool { pinned.count >= Self.maxPinned }

    public func contains(_ tool: IslandTool) -> Bool { pinned.contains(tool) }

    /// A tool can go on the dock if it has a tile on the Tools page.
    public static func canPin(_ tool: IslandTool) -> Bool {
        IslandTool.groups.contains { $0.tools.contains(tool) }
    }

    private static func sanitized(_ tools: [IslandTool]) -> [IslandTool] {
        var seen = Set<IslandTool>()
        return Array(tools.filter { canPin($0) && seen.insert($0).inserted }.prefix(maxPinned))
    }

    /// Adds `tool` at the end. Returns false, changing nothing, if it cannot be pinned, is there already, or the
    /// dock is full.
    @discardableResult
    public mutating func pin(_ tool: IslandTool) -> Bool {
        guard Self.canPin(tool), !contains(tool), !isFull else { return false }
        pinned.append(tool)
        return true
    }

    public mutating func unpin(_ tool: IslandTool) {
        pinned.removeAll { $0 == tool }
    }

    /// Removes `tool` if it is on the dock, else adds it. Returns whether anything changed (adding to a full dock
    /// does not).
    @discardableResult
    public mutating func toggle(_ tool: IslandTool) -> Bool {
        if contains(tool) {
            unpin(tool)
            return true
        }
        return pin(tool)
    }

    /// Puts `tool` at `index` among the chosen tools (clamped to the ends).
    public mutating func move(_ tool: IslandTool, to index: Int) {
        guard let current = pinned.firstIndex(of: tool) else { return }
        let target = min(max(index, 0), pinned.count - 1)
        guard target != current else { return }
        pinned.remove(at: current)
        pinned.insert(tool, at: target)
    }

    public func canMove(_ tool: IslandTool, by offset: Int) -> Bool {
        guard let current = pinned.firstIndex(of: tool) else { return false }
        return pinned.indices.contains(current + offset) && offset != 0
    }

    /// One step left (-1) or right (+1).
    public mutating func move(_ tool: IslandTool, by offset: Int) {
        guard canMove(tool, by: offset), let current = pinned.firstIndex(of: tool) else { return }
        move(tool, to: current + offset)
    }

    /// Where an icon dragged sideways belongs: it started at `startIndex` and has been moved `translation` points;
    /// each slot is `slotWidth` wide. Half a slot is enough to change places.
    public static func dragTargetIndex(startIndex: Int, translation: CGFloat, slotWidth: CGFloat, count: Int) -> Int {
        guard count > 0, slotWidth > 0, translation.isFinite else { return startIndex }
        let steps = Int((translation / slotWidth).rounded())
        return min(max(startIndex + steps, 0), count - 1)
    }

    /// Where the dragged icon is drawn, from the leading edge of the row: under the pointer, and no further than
    /// `overshoot` points past either end.
    public static func dragGhostOffset(
        startIndex: Int, translation: CGFloat, slotWidth: CGFloat, count: Int, overshoot: CGFloat = 8
    ) -> CGFloat {
        guard count > 0, translation.isFinite else { return CGFloat(startIndex) * slotWidth }
        let limit = CGFloat(count - 1) * slotWidth
        return min(max(CGFloat(startIndex) * slotWidth + translation, -overshoot), limit + overshoot)
    }
}
