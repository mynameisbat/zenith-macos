import Foundation
import AppKit

/// Mathematical positioning engine for floating panels across single and multi-display setups.
public struct PanelPositioner: Sendable {
    public static let margin: CGFloat = 12

    public enum PositioningMode: Sendable {
        case nearMouse
        case screenCenter
    }

    /// Pure function calculating clamped panel bounds for arbitrary screen geometries.
    public static func calculateFrame(
        mouseLocation: CGPoint,
        panelSize: CGSize,
        mode: PositioningMode,
        screens: [NSScreen] = NSScreen.screens
    ) -> NSRect {
        let activeScreen = screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
            ?? screens.first
            ?? NSScreen()

        let vf = activeScreen.visibleFrame
        let screenFrame = (vf.width > 0 && vf.height > 0) ? vf : NSRect(x: 0, y: 0, width: 1920, height: 1080)
        return calculateFrame(mouseLocation: mouseLocation, panelSize: panelSize, mode: mode, visibleFrame: screenFrame)
    }

    /// Pure calculation using an explicit visibleFrame.
    public static func calculateFrame(
        mouseLocation: CGPoint,
        panelSize: CGSize,
        mode: PositioningMode,
        visibleFrame: NSRect
    ) -> NSRect {
        let frame = (visibleFrame.width > 0 && visibleFrame.height > 0)
            ? visibleFrame
            : NSRect(x: 0, y: 0, width: 1920, height: 1080)

        var x: CGFloat
        var y: CGFloat

        switch mode {
        case .screenCenter:
            x = frame.midX - panelSize.width / 2
            y = frame.midY - panelSize.height / 2 + 30 // Slightly above true center for visual weight

        case .nearMouse:
            // Standard macOS popover placement: Anchor slightly below and to the right of cursor
            x = mouseLocation.x - 24
            y = mouseLocation.y - panelSize.height - 12

            // Clamping X bounds
            if x + panelSize.width > frame.maxX - margin {
                x = frame.maxX - margin - panelSize.width
            }
            if x < frame.minX + margin {
                x = frame.minX + margin
            }

            // Clamping Y bounds (if cursor is near screen bottom, flip above cursor)
            if y < frame.minY + margin {
                y = mouseLocation.y + 16
            }
            if y + panelSize.height > frame.maxY - margin {
                y = frame.maxY - margin - panelSize.height
            }
            if y < frame.minY + margin {
                y = frame.minY + margin
            }
        }

        // Final safety clamp for all modes
        if x + panelSize.width > frame.maxX - margin {
            x = frame.maxX - margin - panelSize.width
        }
        if x < frame.minX + margin {
            x = frame.minX + margin
        }
        if y + panelSize.height > frame.maxY - margin {
            y = frame.maxY - margin - panelSize.height
        }
        if y < frame.minY + margin {
            y = frame.minY + margin
        }

        return NSRect(x: x, y: y, width: panelSize.width, height: panelSize.height)
    }
    // MARK: - Docked panel

    /// A wide panel resting near the bottom of a screen, centred (the clipboard strip). The screen is the one the
    /// pointer is on, else the main one.
    public static func dockedFrame(
        mouseLocation: CGPoint,
        preferredSize: CGSize,
        screens: [NSScreen] = NSScreen.screens
    ) -> NSRect {
        let activeScreen = screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
            ?? screens.first
        let vf = activeScreen?.visibleFrame ?? .zero
        return dockedFrame(preferredSize: preferredSize, visibleFrame: vf)
    }

    /// Pure version: `visibleFrame` is the screen without the menu bar and the Dock, so the panel sits `bottomMargin`
    /// above the Dock. A narrow screen narrows the panel (never below `minimumWidth`, never off the screen) and a
    /// short one shortens it.
    public static func dockedFrame(
        preferredSize: CGSize,
        visibleFrame: NSRect,
        sideMargin: CGFloat = 40,
        bottomMargin: CGFloat = 32,
        minimumWidth: CGFloat = 640
    ) -> NSRect {
        let frame = (visibleFrame.width > 0 && visibleFrame.height > 0)
            ? visibleFrame
            : NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let available = frame.width - 2 * sideMargin
        let width = min(preferredSize.width, max(min(minimumWidth, frame.width), available))
        let height = min(preferredSize.height, max(0, frame.height - bottomMargin - 12))
        return NSRect(x: frame.midX - width / 2, y: frame.minY + bottomMargin, width: width, height: height)
    }
}
