import Quartz
import AppKit
import Foundation

/// Concurrency-safe coordinator managing native macOS Quick Look panel (`QLPreviewPanel`)
/// for Dynamic Island drop shelf items.
@MainActor
public final class IslandQuickLookCoordinator: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    public static let shared = IslandQuickLookCoordinator()

    private var currentURL: URL?

    public override init() {
        super.init()
    }

    /// Opens or updates the native macOS Quick Look panel for the specified file URL.
    public func openQuickLook(for url: URL) {
        self.currentURL = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Toggles the native macOS Quick Look panel for the specified file URL.
    public func toggleQuickLook(for url: URL) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible && currentURL == url {
            panel.orderOut(nil)
        } else {
            openQuickLook(for: url)
        }
    }

    // MARK: - QLPreviewPanelDataSource

    nonisolated public func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated {
            currentURL != nil ? 1 : 0
        }
    }

    nonisolated public func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated {
            (currentURL as NSURL?) ?? (NSURL(fileURLWithPath: "/"))
        }
    }

    // MARK: - QLPreviewPanelDelegate

    nonisolated public func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        // Allow Space bar or Escape key to dismiss Quick Look
        if event.type == .keyDown && (event.keyCode == 49 || event.keyCode == 53) {
            MainActor.assumeIsolated {
                panel.orderOut(nil)
            }
            return true
        }
        return false
    }
}
