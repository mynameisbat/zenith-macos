import Foundation
import Combine
import Darwin

/// Supported quick action item IDs in the Zenith Command Hub action list.
public enum ZenithHubAction: String, CaseIterable, Sendable {
    case area = "area"
    case screen = "screen"
    case ocr = "ocr"
    case clipboard = "clipboard"
    case cleaning = "cleaning"

    public var title: String {
        switch self {
        case .area: return String(localized: "Capture Area")
        case .screen: return String(localized: "Capture Screen")
        case .ocr: return String(localized: "Copy Text")
        case .clipboard: return String(localized: "Clipboard")
        case .cleaning: return String(localized: "Cleaning Mode")
        }
    }

    /// What the action does, for tooltips and VoiceOver.
    public var detail: String {
        switch self {
        case .area: return String(localized: "Capture part of the screen and annotate it")
        case .screen: return String(localized: "Capture the whole screen and annotate it")
        case .ocr: return String(localized: "Select an area and copy its text, QR code or barcode")
        case .clipboard: return String(localized: "Open clipboard history")
        case .cleaning: return String(localized: "Block the keyboard and trackpad for a moment to wipe them")
        }
    }

    public var icon: String {
        switch self {
        case .area: return "crop"
        case .screen: return "macwindow"
        case .ocr: return "text.viewfinder"
        case .clipboard: return "list.clipboard"
        case .cleaning: return "keyboard"
        }
    }

    /// The built-in shortcut. The one to show is `SettingsStore.effectiveHotkey(for: hotKeyId)`, which the user may
    /// have changed in Settings → Shortcuts.
    public var shortcut: String {
        switch self {
        case .area: return "⌘⇧2"
        case .screen: return "⌘⇧1"
        case .ocr: return HotKeyDefinition.defaultOCR.keyEquivalent
        case .clipboard: return HotKeyDefinition.defaultClipboard.keyEquivalent
        case .cleaning: return HotKeyDefinition.defaultCleaningMode.keyEquivalent
        }
    }

    /// The identifier of the global shortcut that runs the same action.
    public var hotKeyId: String {
        switch self {
        case .area: return HotKeyDefinition.captureAreaId
        case .screen: return HotKeyDefinition.captureFullscreenId
        case .ocr: return HotKeyDefinition.captureOCRId
        case .clipboard: return HotKeyDefinition.clipboardToggleId
        case .cleaning: return HotKeyDefinition.cleaningModeId
        }
    }

    public var keywords: [String] {
        switch self {
        case .area:
            return ["area", "capture", "snip", "snipping", "crop", "selection", "region", "box", "partial"]
        case .screen:
            return ["screen", "capture", "fullscreen", "full", "window", "display", "monitor", "screenshot", "desktop", "whole"]
        case .ocr:
            return ["ocr", "text", "recognize", "recognise", "read", "extract", "qr", "barcode", "vision"]
        case .clipboard:
            return ["clipboard", "history", "paste", "clips", "pasteboard"]
        case .cleaning:
            return ["cleaning", "clean", "wipe", "keyboard", "trackpad", "block", "lock", "dust"]
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
    @Published public var hoveredProcessId: Int? = nil
    @Published public var hoveredFooterId: String? = nil
    @Published public var quickLookItem: ClipboardItem? = nil
    @Published public var presentationID: UUID = UUID()
    @Published public var hardwareSnapshot: HardwareSnapshot = HardwareSnapshot()
    @Published public var showTopHogs: Bool = true

    private let optimizer: SystemOptimizerService

    /// Where a refresh gets its numbers. The real machine by default; screenshots and tests supply made-up ones.
    public var snapshotProvider: @Sendable () -> HardwareSnapshot = { HardwareTelemetryService.shared.fetchSnapshot() }

    /// How a process is asked to quit. A polite SIGTERM by default; tests substitute a recorder.
    public var processTerminator: @Sendable (Int) -> Void = { HardwareTelemetryService.shared.killProcess(pid: $0, force: false) }

    public init(optimizer: SystemOptimizerService = .shared) {
        self.optimizer = optimizer
    }

    public var filteredTopHogs: [ProcessTelemetry] {
        let allHogs = hardwareSnapshot.cpu.topHogs
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty || query == "/boost" || query == "boost" {
            return Array(allHogs.prefix(5))
        }
        let matched = allHogs.filter { hog in
            hog.name.lowercased().contains(query) ||
            hog.command.lowercased().contains(query) ||
            String(hog.pid).contains(query)
        }
        return Array(matched.prefix(5))
    }

    public func refreshHardwareSnapshot(sync: Bool = false) {
        let provider = snapshotProvider
        if sync {
            hardwareSnapshot = provider()
            return
        }
        Task.detached(priority: .utility) { [weak self] in
            let snapshot = provider()
            await MainActor.run { [weak self] in
                self?.hardwareSnapshot = snapshot
            }
        }
    }

    public func toggleTopHogs() {
        showTopHogs.toggle()
        refreshHardwareSnapshot(sync: true)
    }

    public func killProcess(pid: Int) {
        processTerminator(pid)
        refreshHardwareSnapshot(sync: true)
    }

    /// What the confirmation says before a process is asked to quit.
    public func terminationConfirmation(for process: ProcessTelemetry) -> (title: String, message: String, actionTitle: String) {
        (
            title: String(localized: "Quit \(process.name)?"),
            message: String(localized: "Zenith will ask \(process.name) (PID \(String(process.pid))) to quit. Anything in it that is not saved may be lost."),
            actionTitle: String(localized: "Quit")
        )
    }

    /// Asks `confirm` first and quits the process only if it says yes. Every way of quitting an app from the hub (the
    /// button, ⌘1–⌘4) goes through here; nothing quits an app without being asked.
    /// - Returns: Whether the process was asked to quit.
    @discardableResult
    public func terminate(_ process: ProcessTelemetry, confirm: @MainActor (String, String, String) -> Bool) -> Bool {
        let text = terminationConfirmation(for: process)
        guard confirm(text.title, text.message, text.actionTitle) else { return false }
        killProcess(pid: process.pid)
        return true
    }

    /// Performs a full system and memory boost: flushes DNS, purges zombie processes,
    /// releases thumbnail cache, and triggers Darwin VM malloc pressure relief.
    public func boostSystem() {
        ImageThumbnailService.shared.clearCache()
        malloc_zone_pressure_relief(nil, 0)
        HardwareTelemetryService.shared.invalidateProcessCache()
        refreshHardwareSnapshot(sync: true)

        let optimizer = self.optimizer
        Task.detached(priority: .utility) { [weak self] in
            _ = try? optimizer.execute(taskId: .quickLookCacheRefresh)
            _ = try? optimizer.execute(taskId: .dnsCacheFlush)
            _ = try? optimizer.execute(taskId: .zombieProcessCleanup)
            await MainActor.run { [weak self] in
                self?.refreshHardwareSnapshot(sync: true)
            }
        }
    }

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

    public func setHoveredProcess(_ id: Int?) {
        hoveredProcessId = id
    }

    public func clearHoveredProcess(ifCurrent id: Int) {
        if hoveredProcessId == id {
            hoveredProcessId = nil
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
        hoveredProcessId = nil
        hoveredFooterId = nil
        quickLookItem = nil
        presentationID = UUID()
    }
}
