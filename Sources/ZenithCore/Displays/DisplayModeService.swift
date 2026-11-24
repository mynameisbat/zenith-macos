import AppKit
import Combine
import CoreGraphics
import Foundation

// MARK: - Display Mode Descriptor

/// A resolution and refresh rate a display can run at.
public struct DisplayModeDescriptor: Equatable, Hashable, Sendable, Identifiable {
    public let id: Int32
    public let width: Int
    public let height: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let refreshRate: Double
    public let isHiDPI: Bool
    public var isCurrent: Bool

    public init(
        id: Int32,
        width: Int,
        height: Int,
        pixelWidth: Int,
        pixelHeight: Int,
        refreshRate: Double,
        isHiDPI: Bool,
        isCurrent: Bool = false
    ) {
        self.id = id
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate
        self.isHiDPI = isHiDPI
        self.isCurrent = isCurrent
    }

    /// E.g. "1920 × 1080".
    public var resolutionString: String {
        "\(width) × \(height)"
    }

    /// E.g. "60 Hz", "75 Hz", "120 Hz (ProMotion)".
    public var refreshRateString: String {
        if refreshRate <= 0.1 {
            return String(localized: "Default")
        }
        let rounded = Int(refreshRate.rounded())
        if refreshRate >= 119.5 {
            return "\(rounded) Hz (ProMotion)"
        }
        return "\(rounded) Hz"
    }

    /// E.g. "1920 × 1080 @ 60 Hz (Retina)".
    public var fullTitle: String {
        var text = resolutionString
        if refreshRate > 0.1 {
            text += " @ \(Int(refreshRate.rounded())) Hz"
        }
        if isHiDPI {
            text += " (" + String(localized: "Retina") + ")"
        }
        return text
    }
}

// MARK: - Display Configuring Seam

/// Abstracts CoreGraphics display configuration calls so tests can run hermetically without altering screens.
public protocol DisplayConfiguring: Sendable {
    func allModes(for displayID: UInt32) -> [DisplayModeDescriptor]
    func currentMode(for displayID: UInt32) -> DisplayModeDescriptor?
    func setMode(_ mode: DisplayModeDescriptor, for displayID: UInt32, permanently: Bool) -> Bool
}

/// The production implementation using CoreGraphics public APIs.
public struct SystemDisplayConfiguring: DisplayConfiguring {
    public init() {}

    public func allModes(for displayID: UInt32) -> [DisplayModeDescriptor] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let list = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else {
            return []
        }
        let current = CGDisplayCopyDisplayMode(displayID)
        let currentID = current?.ioDisplayModeID

        var seen = Set<String>()
        var result: [DisplayModeDescriptor] = []

        for mode in list {
            guard mode.isUsableForDesktopGUI() else { continue }
            let w = mode.width
            let h = mode.height
            let pw = mode.pixelWidth
            let ph = mode.pixelHeight
            let rate = mode.refreshRate
            let isHiDPI = pw > w || ph > h
            let isCurrent = mode.ioDisplayModeID == currentID

            // De-duplicate identical resolution, rate and HiDPI flags to keep UI clean
            let key = "\(w)x\(h)@\(Int(rate.rounded()))-\(isHiDPI)"
            if seen.insert(key).inserted || isCurrent {
                result.append(
                    DisplayModeDescriptor(
                        id: mode.ioDisplayModeID,
                        width: w,
                        height: h,
                        pixelWidth: pw,
                        pixelHeight: ph,
                        refreshRate: rate,
                        isHiDPI: isHiDPI,
                        isCurrent: isCurrent
                    )
                )
            }
        }
        return result
    }

    public func currentMode(for displayID: UInt32) -> DisplayModeDescriptor? {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return nil }
        let w = mode.width
        let h = mode.height
        let pw = mode.pixelWidth
        let ph = mode.pixelHeight
        return DisplayModeDescriptor(
            id: mode.ioDisplayModeID,
            width: w,
            height: h,
            pixelWidth: pw,
            pixelHeight: ph,
            refreshRate: mode.refreshRate,
            isHiDPI: pw > w || ph > h,
            isCurrent: true
        )
    }

    public func setMode(_ mode: DisplayModeDescriptor, for displayID: UInt32, permanently: Bool) -> Bool {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let list = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode],
              let target = list.first(where: { $0.ioDisplayModeID == mode.id }) else {
            return false
        }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        guard CGConfigureDisplayWithDisplayMode(config, displayID, target, nil) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        let option: CGConfigureOption = permanently ? .permanently : .forSession
        return CGCompleteDisplayConfiguration(config, option) == .success
    }
}

// MARK: - Safety Revert State

/// Holds the temporary mode switch countdown so bad resolutions safely revert.
public struct PendingRevertState: Equatable, Sendable {
    public let displayID: UInt32
    public let targetMode: DisplayModeDescriptor
    public let originalMode: DisplayModeDescriptor
    public var secondsLeft: Int

    public init(displayID: UInt32, targetMode: DisplayModeDescriptor, originalMode: DisplayModeDescriptor, secondsLeft: Int = 15) {
        self.displayID = displayID
        self.targetMode = targetMode
        self.originalMode = originalMode
        self.secondsLeft = secondsLeft
    }
}

// MARK: - Display Mode Service

/// Manages resolution and refresh rate configurations with automatic safety reversal (Phase 2).
@MainActor
public final class DisplayModeService: ObservableObject {
    public static let shared = DisplayModeService()

    @Published public private(set) var displays: [DisplayDescriptor] = []
    @Published public private(set) var modesByDisplay: [UInt32: [DisplayModeDescriptor]] = [:]
    @Published public private(set) var currentModes: [UInt32: DisplayModeDescriptor] = [:]
    @Published public private(set) var pendingRevert: PendingRevertState? = nil

    private let inventory: any DisplayInventory
    private let configuring: any DisplayConfiguring
    private var countdownTimer: AnyCancellable?

    public init(
        inventory: any DisplayInventory = SystemDisplayInventory(),
        configuring: any DisplayConfiguring = SystemDisplayConfiguring()
    ) {
        self.inventory = inventory
        self.configuring = configuring
        refreshDisplays()
    }

    /// Initializer for screenshot previews or unit tests.
    public init(
        previewDisplays: [DisplayDescriptor],
        previewModes: [UInt32: [DisplayModeDescriptor]],
        configuring: any DisplayConfiguring = SystemDisplayConfiguring()
    ) {
        self.inventory = SystemDisplayInventory()
        self.configuring = configuring
        self.displays = previewDisplays
        self.modesByDisplay = previewModes
        for (id, modes) in previewModes {
            if let current = modes.first(where: \.isCurrent) ?? modes.first {
                self.currentModes[id] = current
            }
        }
    }

    /// Refresh display list and their available modes.
    public func refreshDisplays() {
        objectWillChange.send()
        displays = inventory.onlineDisplays()
        var newModes: [UInt32: [DisplayModeDescriptor]] = [:]
        var newCurrent: [UInt32: DisplayModeDescriptor] = [:]

        for display in displays {
            let modes = configuring.allModes(for: display.id)
            newModes[display.id] = modes
            if let cur = configuring.currentMode(for: display.id) {
                newCurrent[display.id] = cur
            } else if let fallback = modes.first(where: \.isCurrent) ?? modes.first {
                newCurrent[display.id] = fallback
            }
        }
        modesByDisplay = newModes
        currentModes = newCurrent
    }

    /// Returns available modes for a specific display, sorted descending by pixel area and refresh rate.
    public func modes(for displayID: UInt32) -> [DisplayModeDescriptor] {
        modesByDisplay[displayID] ?? []
    }

    /// Returns the currently active mode for a display.
    public func currentMode(for displayID: UInt32) -> DisplayModeDescriptor? {
        currentModes[displayID]
    }

    /// Applies a mode temporarily with a 15-second countdown to keep or revert.
    @discardableResult
    public func applyMode(_ mode: DisplayModeDescriptor, for displayID: UInt32) -> Bool {
        objectWillChange.send()
        // If a pending revert is already active, revert or finalize it first
        if pendingRevert != nil {
            revertChanges()
        }

        let original = currentModes[displayID] ?? configuring.currentMode(for: displayID) ?? mode
        guard configuring.setMode(mode, for: displayID, permanently: false) else {
            return false
        }

        // Update current mode state
        var updated = mode
        updated.isCurrent = true
        currentModes[displayID] = updated

        // Start safety timer
        startRevertTimer(displayID: displayID, targetMode: mode, originalMode: original)
        return true
    }

    /// Confirms and commits the new mode permanently.
    public func confirmKeepChanges() {
        guard let pending = pendingRevert else { return }
        objectWillChange.send()
        stopRevertTimer()
        _ = configuring.setMode(pending.targetMode, for: pending.displayID, permanently: true)
        pendingRevert = nil
    }

    /// Reverts the display back to its original mode.
    public func revertChanges() {
        guard let pending = pendingRevert else { return }
        objectWillChange.send()
        stopRevertTimer()
        _ = configuring.setMode(pending.originalMode, for: pending.displayID, permanently: true)
        currentModes[pending.displayID] = pending.originalMode
        pendingRevert = nil
    }

    /// Advance safety countdown manually (used by tests or timer tick).
    public func tickCountdown() {
        guard var pending = pendingRevert else { return }
        objectWillChange.send()
        pending.secondsLeft -= 1
        if pending.secondsLeft <= 0 {
            revertChanges()
        } else {
            pendingRevert = pending
        }
    }

    private func startRevertTimer(displayID: UInt32, targetMode: DisplayModeDescriptor, originalMode: DisplayModeDescriptor) {
        pendingRevert = PendingRevertState(displayID: displayID, targetMode: targetMode, originalMode: originalMode, secondsLeft: 15)
        countdownTimer?.cancel()
        countdownTimer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.tickCountdown()
            }
    }

    private func stopRevertTimer() {
        countdownTimer?.cancel()
        countdownTimer = nil
    }
}
