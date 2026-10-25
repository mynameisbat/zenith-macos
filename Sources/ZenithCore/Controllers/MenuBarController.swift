import AppKit
import Foundation

/// Standard identifiers for MenuBar items.
public enum MenuBarItemIdentifier {
    public static let clipboardHistory = NSUserInterfaceItemIdentifier("menuBar.clipboardHistory")
    public static let captureArea = NSUserInterfaceItemIdentifier("menuBar.captureArea")
    public static let captureFullscreen = NSUserInterfaceItemIdentifier("menuBar.captureFullscreen")
    public static let liveStatistics = NSUserInterfaceItemIdentifier("menuBar.liveStatistics")
    public static let clearHistory = NSUserInterfaceItemIdentifier("menuBar.clearHistory")
    public static let privacyShieldToggle = NSUserInterfaceItemIdentifier("menuBar.privacyShieldToggle")
    public static let privacyShieldStats = NSUserInterfaceItemIdentifier("menuBar.privacyShieldStats")
    public static let preferences = NSUserInterfaceItemIdentifier("menuBar.preferences")
    public static let quit = NSUserInterfaceItemIdentifier("menuBar.quit")
}

/// Standard tags for MenuBar items.
public enum MenuBarItemTag: Int, CaseIterable, Sendable {
    case clipboardHistory = 1001
    case captureArea = 1002
    case captureFullscreen = 1003
    case liveStatistics = 1004
    case clearHistory = 1005
    case privacyShieldToggle = 1008
    case privacyShieldStats = 1009
    case preferences = 1006
    case quit = 1007
}

/// Menu Bar status item controller and dropdown menu coordinator (Features F42, F43).
@MainActor
public final class MenuBarController: NSObject, NSMenuDelegate {
    public static let shared = MenuBarController()

    // MARK: - Properties

    public private(set) var statusItem: NSStatusItem?
    public private(set) var menu: NSMenu?
    private weak var currentStatusBar: NSStatusBar?

    public var clipboardStore: ClipboardStore

    // Action handlers (injectable / customizable)
    public var onClipboardHistory: (@MainActor () -> Void)?
    public var onCaptureArea: (@MainActor () -> Void)?
    public var onCaptureFullscreen: (@MainActor () -> Void)?
    public var onClearHistory: (@MainActor () -> Void)?
    public var onTogglePrivacyShield: (@MainActor () -> Void)?
    public var onShowPreferences: (@MainActor () -> Void)?
    public var onQuit: (@MainActor () -> Void)?
    public var onStatusItemClick: (@MainActor (NSStatusBarButton) -> Void)?

    // MARK: - Initialization

    public init(clipboardStore: ClipboardStore = .shared) {
        self.clipboardStore = clipboardStore
        super.init()
    }

    // MARK: - Lifecycle

    /// Sets up the NSStatusItem and dropdown NSMenu in the specified NSStatusBar.
    public func setup(statusBar: NSStatusBar = .system) {
        guard statusItem == nil else { return }
        self.currentStatusBar = statusBar

        let item = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let symbolImage = makeZenithStatusIcon()
            button.image = symbolImage
            button.imagePosition = .imageOnly
            button.toolTip = "Zenith"
            button.setAccessibilityLabel("Zenith")
            button.setAccessibilityTitle("Zenith")
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let dropdownMenu = buildMenu()
        self.menu = dropdownMenu
        if onStatusItemClick == nil {
            item.menu = dropdownMenu
        }
        self.statusItem = item
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            if let menu = self.menu {
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
            }
        } else if let onClick = onStatusItemClick {
            onClick(sender)
        } else if let menu = self.menu {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
        }
    }

    /// Teardowns and removes the status item from the status bar.
    public func teardown(statusBar: NSStatusBar? = nil) {
        let bar = statusBar ?? currentStatusBar ?? .system
        if let item = statusItem {
            bar.removeStatusItem(item)
        }
        statusItem?.menu = nil
        menu?.delegate = nil
        menu = nil
        statusItem = nil
        currentStatusBar = nil
    }

    // MARK: - Menu Construction

    public func buildMenu() -> NSMenu {
        let menu = NSMenu(title: "Zenith")
        menu.delegate = self
        menu.autoenablesItems = false

        // 1. Clipboard History (⌘⇧V)
        let clipboardItem = NSMenuItem(
            title: "Clipboard History",
            action: #selector(clipboardHistoryAction(_:)),
            keyEquivalent: "v"
        )
        clipboardItem.keyEquivalentModifierMask = [.command, .shift]
        clipboardItem.target = self
        clipboardItem.tag = MenuBarItemTag.clipboardHistory.rawValue
        clipboardItem.identifier = MenuBarItemIdentifier.clipboardHistory
        menu.addItem(clipboardItem)

        // 2. Capture Area (⌘⇧2)
        let captureAreaItem = NSMenuItem(
            title: "Capture Area",
            action: #selector(captureAreaAction(_:)),
            keyEquivalent: "2"
        )
        captureAreaItem.keyEquivalentModifierMask = [.command, .shift]
        captureAreaItem.target = self
        captureAreaItem.tag = MenuBarItemTag.captureArea.rawValue
        captureAreaItem.identifier = MenuBarItemIdentifier.captureArea
        menu.addItem(captureAreaItem)

        // 3. Capture Fullscreen (⌘⇧1)
        let captureFullscreenItem = NSMenuItem(
            title: "Capture Fullscreen",
            action: #selector(captureFullscreenAction(_:)),
            keyEquivalent: "1"
        )
        captureFullscreenItem.keyEquivalentModifierMask = [.command, .shift]
        captureFullscreenItem.target = self
        captureFullscreenItem.tag = MenuBarItemTag.captureFullscreen.rawValue
        captureFullscreenItem.identifier = MenuBarItemIdentifier.captureFullscreen
        menu.addItem(captureFullscreenItem)

        // 4. Separator
        menu.addItem(NSMenuItem.separator())

        // 5. Dynamic status row: "Clipboard: X items" (disabled, non-selectable)
        let statsItem = NSMenuItem(
            title: statisticsTitle(for: clipboardStore.items.count),
            action: nil,
            keyEquivalent: ""
        )
        statsItem.isEnabled = false
        statsItem.tag = MenuBarItemTag.liveStatistics.rawValue
        statsItem.identifier = MenuBarItemIdentifier.liveStatistics
        menu.addItem(statsItem)

        // 6. Clear History
        let clearHistoryItem = NSMenuItem(
            title: "Clear History",
            action: #selector(clearHistoryAction(_:)),
            keyEquivalent: ""
        )
        clearHistoryItem.target = self
        clearHistoryItem.tag = MenuBarItemTag.clearHistory.rawValue
        clearHistoryItem.identifier = MenuBarItemIdentifier.clearHistory
        clearHistoryItem.isEnabled = !clipboardStore.items.isEmpty
        menu.addItem(clearHistoryItem)

        // 7. Separator
        menu.addItem(NSMenuItem.separator())

        // Privacy Shield Toggle
        let privacyShieldItem = NSMenuItem(
            title: "Privacy Shield: Inactive",
            action: #selector(privacyShieldToggleAction(_:)),
            keyEquivalent: "p"
        )
        privacyShieldItem.keyEquivalentModifierMask = [.command, .option]
        privacyShieldItem.target = self
        privacyShieldItem.tag = MenuBarItemTag.privacyShieldToggle.rawValue
        privacyShieldItem.identifier = MenuBarItemIdentifier.privacyShieldToggle
        menu.addItem(privacyShieldItem)

        // Privacy Shield Dynamic Telemetry Row
        let privacyStatsItem = NSMenuItem(
            title: "Privacy Shield: Inactive (Click to enable)",
            action: nil,
            keyEquivalent: ""
        )
        privacyStatsItem.isEnabled = false
        privacyStatsItem.tag = MenuBarItemTag.privacyShieldStats.rawValue
        privacyStatsItem.identifier = MenuBarItemIdentifier.privacyShieldStats
        menu.addItem(privacyStatsItem)

        // 8. Separator
        menu.addItem(NSMenuItem.separator())

        // 9. Preferences... (⌘,)
        let preferencesItem = NSMenuItem(
            title: "Preferences...",
            action: #selector(preferencesAction(_:)),
            keyEquivalent: ","
        )
        preferencesItem.keyEquivalentModifierMask = [.command]
        preferencesItem.target = self
        preferencesItem.tag = MenuBarItemTag.preferences.rawValue
        preferencesItem.identifier = MenuBarItemIdentifier.preferences
        menu.addItem(preferencesItem)

        // 9. Quit Zenith (⌘Q)
        let quitItem = NSMenuItem(
            title: "Quit Zenith",
            action: #selector(quitAction(_:)),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        quitItem.tag = MenuBarItemTag.quit.rawValue
        quitItem.identifier = MenuBarItemIdentifier.quit
        menu.addItem(quitItem)

        return menu
    }

    // MARK: - NSMenuDelegate (Dynamic Updates)

    public func menuWillOpen(_ menu: NSMenu) {
        updateDynamicItems(in: menu)
    }

    public func updateDynamicItems(in menu: NSMenu) {
        let itemCount = clipboardStore.items.count

        // Update dynamic statistics row
        if let statsItem = menu.item(withTag: MenuBarItemTag.liveStatistics.rawValue) {
            statsItem.title = statisticsTitle(for: itemCount)
            statsItem.isEnabled = false
        }

        // Update clear history enablement
        if let clearItem = menu.item(withTag: MenuBarItemTag.clearHistory.rawValue) {
            clearItem.isEnabled = (itemCount > 0)
        }

        // Update Privacy Shield status and telemetry
        let shieldStats = PrivacyShieldStatistics.shared
        if let privacyItem = menu.item(withTag: MenuBarItemTag.privacyShieldToggle.rawValue) {
            privacyItem.state = shieldStats.isActive ? .on : .off
            privacyItem.title = shieldStats.isActive ? "Privacy Shield: Active" : "Privacy Shield: Inactive"
        }
        if let privacyStatsItem = menu.item(withTag: MenuBarItemTag.privacyShieldStats.rawValue) {
            if shieldStats.isActive {
                let pingStr = shieldStats.dohLatencyMs > 0 ? "\(shieldStats.dohLatencyMs)ms" : "OK"
                privacyStatsItem.title = "DoH: \(shieldStats.selectedProvider.displayName) • \(pingStr)"
            } else {
                privacyStatsItem.title = "Privacy Shield: Inactive (Click to enable)"
            }
            privacyStatsItem.isEnabled = false
        }
    }

    /// Dynamically updates the menu bar status button tooltip and optional title with live CPU and RAM telemetry.
    public func updateStatusBarTelemetry(showInTitle: Bool = false) {
        guard let button = statusItem?.button else { return }
        let snap = HardwareTelemetryService.shared.fetchSnapshot()
        let cpu = Int(round(snap.cpu.totalUsagePercent))
        let ram = Int(round(snap.memory.usedPercent))

        if showInTitle {
            button.imagePosition = .imageLeft
            button.title = "\(cpu)% CPU • \(ram)% RAM"
        } else {
            button.imagePosition = .imageOnly
            button.title = ""
        }

        var tip = "Zenith\nCPU: \(cpu)% • RAM: \(ram)%"
        if snap.battery.hasBattery {
            tip += "\nBattery: \(snap.battery.percentage)%"
            if let cycles = snap.battery.cycleCount {
                tip += " (Cycles: \(cycles))"
            }
        }
        if let topHog = snap.cpu.topHogs.first {
            tip += "\nTop Hog: \(topHog.name) (\(String(format: "%.1f", topHog.cpuPercent))%)"
        }
        button.toolTip = tip
    }

    public func statisticsTitle(for count: Int) -> String {
        if count == 0 {
            return "Clipboard: Empty"
        } else if count == 1 {
            return "Clipboard: 1 item"
        } else {
            return "Clipboard: \(count) items"
        }
    }

    // MARK: - Action Selectors

    @objc public func clipboardHistoryAction(_ sender: Any?) {
        onClipboardHistory?()
    }

    @objc public func captureAreaAction(_ sender: Any?) {
        onCaptureArea?()
    }

    @objc public func captureFullscreenAction(_ sender: Any?) {
        onCaptureFullscreen?()
    }

    @objc public func clearHistoryAction(_ sender: Any?) {
        if let customClear = onClearHistory {
            customClear()
        } else {
            clipboardStore.clear()
        }
        if let menu = menu {
            updateDynamicItems(in: menu)
        }
    }

    @objc public func privacyShieldToggleAction(_ sender: Any?) {
        onTogglePrivacyShield?()
        if let menu = menu {
            updateDynamicItems(in: menu)
        }
    }

    @objc public func preferencesAction(_ sender: Any?) {
        onShowPreferences?()
    }

    @objc public func quitAction(_ sender: Any?) {
        if let customQuit = onQuit {
            customQuit()
        } else {
            NSApp.terminate(nil)
        }
    }

    // MARK: - Helpers
 
    /// Generates the crisp, native Zenith Apex Aperture Diamond emblem for the macOS Menu Bar.
    public func makeZenithStatusIcon() -> NSImage {
        let size: CGFloat = 18
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            let center = CGPoint(x: size / 2, y: size / 2)

            // 1. Draw outer rotated Zenith squircle (45-degree diamond)
            ctx.saveGState()
            ctx.translateBy(x: center.x, y: center.y)
            ctx.rotate(by: CGFloat.pi / 4)

            let diamondSize: CGFloat = 10.5
            let cornerRadius: CGFloat = 2.4

            let boxRect = CGRect(x: -diamondSize / 2, y: -diamondSize / 2, width: diamondSize, height: diamondSize)
            let path = CGPath(roundedRect: boxRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
            ctx.addPath(path)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath()

            // 2. Cutout inner aperture window
            let innerSize: CGFloat = 4.4
            let innerRect = CGRect(x: -innerSize / 2, y: -innerSize / 2, width: innerSize, height: innerSize)
            let innerPath = CGPath(roundedRect: innerRect, cornerWidth: 0.9, cornerHeight: 0.9, transform: nil)
            ctx.addPath(innerPath)
            ctx.setBlendMode(.clear)
            ctx.fillPath()

            ctx.restoreGState()
            return true
        }
        image.isTemplate = true
        return image
    }

    private func makeFallbackIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.black.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.move(to: NSPoint(x: 3, y: 3))
        path.line(to: NSPoint(x: 15, y: 15))
        path.move(to: NSPoint(x: 3, y: 15))
        path.line(to: NSPoint(x: 15, y: 3))
        path.stroke()
        img.unlockFocus()
        img.isTemplate = true
        return img
    }
}

/// Architectural typealias specified in PROJECT.md (Line 87).
public typealias StatusBarController = MenuBarController

