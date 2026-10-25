import AppKit
import SwiftUI
import Combine
import ZenithCore

/// Dedicated floating panel hosting `IslandItemPreviewCard`.
public final class IslandPreviewPanel: NSPanel {
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }

    public init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.isFloatingPanel = true
        self.level = .mainMenu + 2
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.isReleasedWhenClosed = false
        self.acceptsMouseMovedEvents = true
        self.animationBehavior = .utilityWindow
    }
}

/// Orchestrates the lifecycle, positioning, and keyboard/mouse interaction
/// of the Dynamic Island item preview window.
@MainActor
public final class IslandPreviewWindowController: NSObject {
    public static let shared = IslandPreviewWindowController()

    private var panel: IslandPreviewPanel?
    private var globalMouseMonitor: Any?
    private var localKeyMonitor: Any?
    private(set) public var currentFrame: CGRect?

    override private init() {
        super.init()
    }

    /// Presents the preview card for the specified drop shelf item directly beneath the Dynamic Island.
    public func show(for item: IslandDropItem, relativeTo geometry: ZenithIslandGeometry) {
        let cardWidth: CGFloat = 320
        let cardHeight: CGFloat = item.isImageFile ? 320 : (item.isTextOrCodeFile ? 280 : 250)

        let x = geometry.notchRect.midX - (cardWidth / 2)
        let y = geometry.expandedFrame.minY - cardHeight - 8
        let targetFrame = NSRect(x: x, y: y, width: cardWidth, height: cardHeight)
        self.currentFrame = targetFrame

        let islandPreviewCard = IslandItemPreviewCard(
            item: item,
            onClose: { [weak self] in
                self?.dismiss()
            },
            onCopy: {
                Self.copyItemToClipboard(item)
            },
            onRemove: { [weak self] in
                ZenithIslandState.shared.removeItem(id: item.id)
                self?.dismiss()
            }
        )

        let hostingView = NSHostingView(rootView: islandPreviewCard)
        hostingView.autoresizingMask = [.width, .height]

        if let existingPanel = panel {
            existingPanel.contentView = hostingView
            existingPanel.setFrame(targetFrame, display: true, animate: true)
            existingPanel.orderFrontRegardless()
        } else {
            let newPanel = IslandPreviewPanel(contentRect: targetFrame)
            newPanel.contentView = hostingView
            newPanel.setFrame(targetFrame, display: true)
            newPanel.orderFrontRegardless()
            self.panel = newPanel
        }

        setupMonitors(relativeTo: geometry)
    }

    /// Dismisses the preview window and resets active preview state.
    public func dismiss() {
        tearDownMonitors()
        self.currentFrame = nil
        panel?.orderOut(nil)
        if ZenithIslandState.shared.previewItem != nil {
            ZenithIslandState.shared.dismissPreview()
        }
    }

    // MARK: - Event Monitors (Escape, Spacebar, Outside Clicks)

    private func setupMonitors(relativeTo geometry: ZenithIslandGeometry) {
        tearDownMonitors()

        // 1. Outside click dismissal
        self.globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self else { return }
            let mouseLoc = NSEvent.mouseLocation
            let previewBounds = self.panel?.frame ?? .zero
            let islandBounds = geometry.expandedFrame

            // Dismiss if click is outside both the preview card and the Dynamic Island
            if !previewBounds.contains(mouseLoc) && !islandBounds.contains(mouseLoc) {
                Task { @MainActor [weak self] in
                    self?.dismiss()
                }
            }
        }

        // 2. Keyboard shortcuts when active (Esc to close, Space to launch Quick Look)
        self.localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.panel?.isVisible == true else { return event }

            // Escape key (53)
            if event.keyCode == 53 {
                self.dismiss()
                return nil
            }

            // Spacebar (49)
            if event.keyCode == 49, let currentItem = ZenithIslandState.shared.previewItem, let url = currentItem.fileURL {
                IslandQuickLookCoordinator.shared.openQuickLook(for: url)
                return nil
            }

            return event
        }
    }

    private func tearDownMonitors() {
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            self.globalMouseMonitor = nil
        }
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            self.localKeyMonitor = nil
        }
    }

    private static func copyItemToClipboard(_ item: IslandDropItem) {
        let pboard = NSPasteboard.general
        pboard.clearContents()
        if let url = item.fileURL {
            pboard.writeObjects([url as NSURL, url.path as NSString])
            ToastHUDController.shared.show(message: "Copied \(item.name)", icon: "doc.on.clipboard")
        } else if let text = item.textContent {
            pboard.setString(text, forType: .string)
            ToastHUDController.shared.show(message: "Copied to Clipboard", icon: "doc.on.clipboard")
        }
    }
}
