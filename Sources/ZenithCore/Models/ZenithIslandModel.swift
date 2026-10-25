import AppKit
import Foundation
import Combine
import SwiftUI

/// Hardware-aware geometry calculation for Zenith Dynamic Island.
public struct ZenithIslandGeometry: Sendable, Equatable {
    public let hasNotch: Bool
    public let notchRect: CGRect
    public let idleWidth: CGFloat
    public let idleHeight: CGFloat
    public let expandedWidth: CGFloat
    public let expandedHeight: CGFloat
    public let alertWidth: CGFloat
    public let alertHeight: CGFloat
    public let screenFrame: CGRect

    public init(screen: NSScreen? = nil) {
        let defaultScreen: NSScreen? = {
            if let notchScreen = NSScreen.screens.first(where: { s in
                if let left = s.auxiliaryTopLeftArea, let right = s.auxiliaryTopRightArea {
                    return right.origin.x > left.maxX
                }
                return false
            }) {
                return notchScreen
            }
            return NSScreen.screens.first ?? NSScreen.main
        }()
        let resolvedScreen = screen ?? defaultScreen
        let frame = resolvedScreen?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        self.screenFrame = frame
        if let s = resolvedScreen,
           let left = s.auxiliaryTopLeftArea,
           let right = s.auxiliaryTopRightArea,
           right.origin.x > left.maxX {
            self.hasNotch = true
            let notchW = right.origin.x - left.maxX
            let notchH = left.height
            let notchX = left.maxX
            let notchY = frame.maxY - notchH
            self.notchRect = CGRect(x: notchX, y: notchY, width: notchW, height: notchH)
            self.idleWidth = notchW
            self.idleHeight = notchH
        } else {
            self.hasNotch = false
            let idleW: CGFloat = 110
            let idleH: CGFloat = 8
            let notchX = frame.midX - idleW / 2
            let notchY = frame.maxY - idleH
            self.notchRect = CGRect(x: notchX, y: notchY, width: idleW, height: idleH)
            self.idleWidth = idleW
            self.idleHeight = idleH
        }

        self.expandedWidth = 380
        self.expandedHeight = 96
        self.alertWidth = 280
        self.alertHeight = 36
    }

    /// Computes the exact window frame in screen coordinates.
    public func windowFrame(isExpanded: Bool) -> CGRect {
        let width = isExpanded ? expandedWidth : idleWidth
        let height = isExpanded ? expandedHeight : idleHeight
        let x = notchRect.midX - width / 2
        let y = screenFrame.maxY - height
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Effective vertical height of the alert HUD (accommodating hardware notch cutout).
    public var effectiveAlertHeight: CGFloat {
        hasNotch ? (notchRect.height + alertHeight) : alertHeight
    }

    /// Computes the window frame for the transient alert capsule.
    public var alertFrame: CGRect {
        let h = effectiveAlertHeight
        let x = notchRect.midX - alertWidth / 2
        let y = screenFrame.maxY - h
        return CGRect(x: x, y: y, width: alertWidth, height: h)
    }

    /// Computes the window frame for the idle notch indicator.
    public var idleFrame: CGRect {
        let h = hasNotch ? idleHeight : max(idleHeight, 22)
        let x = notchRect.midX - idleWidth / 2
        let y = screenFrame.maxY - h
        return CGRect(x: x, y: y, width: idleWidth, height: h)
    }

    /// Computes the window frame for the expanded drop shelf.
    public var expandedFrame: CGRect {
        windowFrame(isExpanded: true)
    }
}

/// Represents an item stored in the Dynamic Island's Drop Shelf.
public struct IslandDropItem: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let fileURL: URL?
    public let textContent: String?
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        name: String,
        fileURL: URL? = nil,
        textContent: String? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.fileURL = fileURL
        self.textContent = textContent
        self.timestamp = timestamp
    }

    public static func == (lhs: IslandDropItem, rhs: IslandDropItem) -> Bool {
        lhs.id == rhs.id
    }
}

/// Represents a transient alert HUD shown inside the notch capsule.
public struct IslandAlert: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let icon: String
    public let title: String
    public let subtitle: String?
    public let timestamp: Date

    public init(id: UUID = UUID(), icon: String, title: String, subtitle: String? = nil, timestamp: Date = Date()) {
        self.id = id
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.timestamp = timestamp
    }
}

/// State controller managing Dynamic Island expansion, hover timers, and drop shelf items.
@MainActor
public final class ZenithIslandState: ObservableObject {
    public static let shared = ZenithIslandState()

    @Published public var isExpanded: Bool = false
    @Published public var isHovered: Bool = false
    @Published public var isDropTargeted: Bool = false
    @Published public var isDraggingOut: Bool = false
    @Published public var isEnabled: Bool = true
    @Published public var isRimLightVisible: Bool = false
    @Published public var droppedItems: [IslandDropItem] = []
    @Published public var activeAlert: IslandAlert? = nil

    private var collapseTimer: Task<Void, Never>?
    private var dragOutTimer: Task<Void, Never>?
    private var rimLightFadeTask: Task<Void, Never>?
    private var alertDismissTask: Task<Void, Never>?
    private var alertDismissWorkItem: DispatchWorkItem?

    public init() {}

    // MARK: - Encapsulated State Predicates (Clean Code G28, G29)

    /// True when the user is actively interacting with the island via hover, drag, or drop.
    public var isActivelyEngaged: Bool {
        isHovered || isDropTargeted || isDraggingOut
    }

    /// True when the island has no active hover, drag, or drop gestures.
    public var isCompletelyIdle: Bool {
        !isActivelyEngaged
    }

    /// True when the island is eligible to expand purely by hovering.
    public var isEligibleForHoverExpansion: Bool {
        isHovered && !isDropTargeted && !isDraggingOut
    }

    /// Displays a transient alert HUD directly in the notch capsule for 1.8 seconds, then smoothly collapses back.
    public func triggerAlert(icon: String, title: String, subtitle: String? = nil, duration: TimeInterval = 1.8) {
        guard isEnabled else { return }
        alertDismissWorkItem?.cancel()
        alertDismissTask?.cancel()
        let alert = IslandAlert(icon: icon, title: title, subtitle: subtitle)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            self.activeAlert = alert
            self.isRimLightVisible = true
        }

        let delay = max(0.05, duration)
        if duration <= 0.5 {
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    self.activeAlert = nil
                    if !self.isExpanded {
                        self.isRimLightVisible = false
                    }
                }
            }
            self.alertDismissWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        } else {
            let nanos = UInt64(delay * 1_000_000_000)
            alertDismissTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: nanos)
                guard let self = self, !Task.isCancelled else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    self.activeAlert = nil
                    if !self.isExpanded {
                        self.isRimLightVisible = false
                    }
                }
            }
        }
    }

    /// Immediately cancels and dismisses any active transient alert HUD.
    public func dismissAlert() {
        alertDismissWorkItem?.cancel()
        alertDismissWorkItem = nil
        alertDismissTask?.cancel()
        alertDismissTask = nil
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            self.activeAlert = nil
            if !self.isExpanded {
                self.isRimLightVisible = false
            }
        }
    }

    public func onMouseEnter() {
        collapseTimer?.cancel()
        collapseTimer = nil
        rimLightFadeTask?.cancel()
        rimLightFadeTask = nil
        isHovered = true

        if !isExpanded {
            isRimLightVisible = false
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                isExpanded = true
            }
            // Delay rim light fade-in until expansion morph has fully settled (280ms)
            // This ensures NO border is ever exposed or visible during the morph or on quick re-hover
            rimLightFadeTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 280_000_000)
                guard let self = self, !Task.isCancelled, self.isExpanded else { return }
                withAnimation(.easeInOut(duration: 0.22)) {
                    self.isRimLightVisible = true
                }
            }
        } else if !isRimLightVisible {
            rimLightFadeTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 280_000_000)
                guard let self = self, !Task.isCancelled, self.isExpanded else { return }
                withAnimation(.easeInOut(duration: 0.22)) {
                    self.isRimLightVisible = true
                }
            }
        }
    }

    public func onMouseLeave() {
        isHovered = false
        // Instantly hide rim light when leaving so border never leaks or flashes on rapid re-hover
        rimLightFadeTask?.cancel()
        rimLightFadeTask = nil
        withAnimation(.linear(duration: 0.04)) {
            isRimLightVisible = false
        }

        // Delay collapse slightly to prevent jitter when cursor skims edges
        collapseTimer?.cancel()
        collapseTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms grace period
            guard let self = self, !Task.isCancelled else { return }
            if self.isCompletelyIdle && self.isExpanded {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    self.isExpanded = false
                }
            }
        }
    }

    public func beginDragOut() {
        collapseTimer?.cancel()
        collapseTimer = nil
        dragOutTimer?.cancel()
        isDraggingOut = true
        // Keep the shelf securely open during the drag-and-drop gesture across screens/apps
        dragOutTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000) // 4 seconds window
            guard let self = self, !Task.isCancelled else { return }
            self.isDraggingOut = false
            if !self.isHovered && !self.isDropTargeted {
                if self.isExpanded {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        self.isExpanded = false
                    }
                }
            }
        }
    }

    public func endDragOut() {
        dragOutTimer?.cancel()
        dragOutTimer = nil
        isDraggingOut = false
        if !isHovered && !self.isDropTargeted {
            rimLightFadeTask?.cancel()
            withAnimation(.linear(duration: 0.04)) {
                isRimLightVisible = false
            }
            if isExpanded {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded = false
                }
            }
        }
    }

    public func toggleExpanded() {
        if isExpanded {
            rimLightFadeTask?.cancel()
            isRimLightVisible = false
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                isExpanded = false
            }
        } else {
            onMouseEnter()
        }
    }

    public func addItem(name: String, fileURL: URL? = nil, textContent: String? = nil) {
        let item = IslandDropItem(name: name, fileURL: fileURL, textContent: textContent)
        droppedItems.insert(item, at: 0)
        // Keep shelf lean (max 8 items)
        if droppedItems.count > 8 {
            droppedItems.removeLast()
        }
    }

    public func removeItem(id: UUID) {
        droppedItems.removeAll { $0.id == id }
    }

    public func clearAll() {
        droppedItems.removeAll()
    }
}
