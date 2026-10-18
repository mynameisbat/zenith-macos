import AppKit
import SwiftUI
import GoldenGateCore

/// Re-export SettingsWindowController from GoldenGateCore.
public typealias SettingsWindowController = GoldenGateCore.SettingsWindowController

public extension SettingsWindowController {
    /// Configures the settings window controller with the modern ZenithPreferencesView.
    func configureDefaultContent() {
        if viewControllerProvider == nil {
            viewControllerProvider = {
                NSHostingController(rootView: ZenithPreferencesView())
            }
        }
        if let win = window {
            win.title = "Zenith Preferences"
            win.titlebarAppearsTransparent = true
            win.titleVisibility = .hidden
            win.isMovableByWindowBackground = true
            win.isOpaque = false
            win.backgroundColor = .clear
            win.setFrame(NSRect(origin: win.frame.origin, size: NSSize(width: 680, height: 490)), display: true)
            if let closeBtn = win.standardWindowButton(.closeButton) {
                closeBtn.target = self
                closeBtn.action = #selector(handleCloseButtonAction)
                closeBtn.isEnabled = true
                closeBtn.isHidden = false
            }
        }
    }
}
