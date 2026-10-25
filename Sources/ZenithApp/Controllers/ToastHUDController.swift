import AppKit
import SwiftUI
import ZenithCore

/// Non-activating floating panel used for ephemeral toast notifications.
public final class ToastHUDPanel: NSPanel {
    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }
}

/// Controller presenting ephemeral mini HUD notifications (e.g. "Copied to Clipboard!", "Saved to Disk!")
/// that automatically fade out after 1.5 seconds without stealing focus.
@MainActor
public final class ToastHUDController: NSObject {
    public static let shared = ToastHUDController()

    private var panel: ToastHUDPanel?
    private var dismissWorkItem: DispatchWorkItem?

    override private init() {
        super.init()
    }

    /// Shows the ephemeral HUD with message and SF Symbol icon.
    /// When Dynamic Island is enabled, alerts are routed exclusively through the Dynamic Island capsule
    /// to eliminate duplicate notifications. Otherwise, falls back to the floating toast panel.
    public func show(message: String, icon: String = "checkmark.circle.fill", subtitle: String? = nil) {
        dismissWorkItem?.cancel()

        if ZenithIslandState.shared.isEnabled {
            ZenithIslandState.shared.triggerAlert(icon: icon, title: message, subtitle: subtitle)
            if let panel = panel, panel.isVisible {
                panel.orderOut(nil)
            }
            return
        }

        if panel == nil {
            let toastPanel = ToastHUDPanel(
                contentRect: NSRect(x: 0, y: 0, width: 220, height: 44),
                styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            toastPanel.isFloatingPanel = true
            toastPanel.level = .floating
            toastPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            toastPanel.isOpaque = false
            toastPanel.backgroundColor = .clear
            toastPanel.hasShadow = true
            toastPanel.isReleasedWhenClosed = false
            toastPanel.ignoresMouseEvents = true
            self.panel = toastPanel
        }

        guard let panel = panel else { return }

        let contentView = ToastHUDContentView(message: message, icon: icon)
        let hosted = NSHostingView(rootView: contentView)
        hosted.autoresizingMask = [.width, .height]
        panel.contentView = hosted

        // Position at top center of main display
        let screen = NSScreen.main ?? NSScreen.screens.first
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let toastWidth: CGFloat = max(220, min(420, CGFloat(message.count * 8 + 60)))
        let x = vf.midX - toastWidth / 2
        let y = vf.maxY - 70
        panel.setFrame(NSRect(x: x, y: y, width: toastWidth, height: 44), display: true)

        panel.alphaValue = 0.0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1.0
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.dismiss()
        }
        self.dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
    }

    /// Fades out and dismisses the HUD.
    public func dismiss() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil

        if ZenithIslandState.shared.isEnabled {
            ZenithIslandState.shared.dismissAlert()
        }
        guard let panel = panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.20
            panel.animator().alphaValue = 0.0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.panel?.orderOut(nil)
            }
        }
    }
}

/// Visual content for the Toast HUD.
public struct ToastHUDContentView: View {
    public let message: String
    public let icon: String

    public init(message: String, icon: String = "checkmark.circle.fill") {
        self.message = message
        self.icon = icon
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.accentColor)
            Text(message)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .zenithMaterial(cornerRadius: 8)
    }
}
