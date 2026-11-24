import AppKit
import CoreGraphics
import Foundation
import ZenithDisplayPrivate

/// Presets for virtual HiDPI displays.
public enum VirtualDisplayResolution: String, CaseIterable, Identifiable, Sendable {
    case fourK = "4K UHD (3840 × 2160)"
    case fiveK = "5K UHD (5120 × 2880)"
    case twoK = "2K QHD (2560 × 1440)"

    public var id: String { rawValue }

    public var width: Int {
        switch self {
        case .fourK: return 3840
        case .fiveK: return 5120
        case .twoK: return 2560
        }
    }

    public var height: Int {
        switch self {
        case .fourK: return 2160
        case .fiveK: return 2880
        case .twoK: return 1440
        }
    }

    public var descriptionTitle: String {
        switch self {
        case .fourK: return String(localized: "4K UHD (3840 × 2160)")
        case .fiveK: return String(localized: "5K UHD (5120 × 2880)")
        case .twoK: return String(localized: "2K QHD (2560 × 1440)")
        }
    }
}

/// Seam protocol for virtual display management, allowing hermetic unit testing.
public protocol VirtualDisplayManaging: Sendable {
    var isSupported: Bool { get }
    func createVirtualDisplay(name: String, width: Int, height: Int, refreshRate: Double, hiDPI: Bool) -> UInt32?
    func destroyVirtualDisplay()
}

/// The system implementation calling ZenithVirtualDisplayBridge.
public final class SystemVirtualDisplayManager: VirtualDisplayManaging, @unchecked Sendable {
    private var bridge: ZenithVirtualDisplayBridge?

    public init() {}

    public var isSupported: Bool {
        ZenithVirtualDisplayBridge.isSupported()
    }

    public func createVirtualDisplay(name: String, width: Int, height: Int, refreshRate: Double, hiDPI: Bool) -> UInt32? {
        bridge?.destroy()
        let b = ZenithVirtualDisplayBridge(name: name, width: UInt(width), height: UInt(height), refreshRate: refreshRate, hiDPI: hiDPI)
        guard let b, b.displayID != 0 else {
            return nil
        }
        self.bridge = b
        return b.displayID
    }

    public func destroyVirtualDisplay() {
        bridge?.destroy()
        bridge = nil
    }
}

/// Service managing virtual displays and HiDPI simulation (Phase 3).
@MainActor
public final class VirtualDisplayService: ObservableObject {
    public static let shared = VirtualDisplayService()

    @Published public private(set) var isActive: Bool = false
    @Published public private(set) var displayID: UInt32 = 0
    @Published public var resolution: VirtualDisplayResolution = .fourK

    private let manager: any VirtualDisplayManaging

    public init(manager: any VirtualDisplayManaging = SystemVirtualDisplayManager()) {
        self.manager = manager
    }

    public var isSupported: Bool {
        manager.isSupported
    }

    @discardableResult
    public func start() -> Bool {
        guard manager.isSupported else { return false }
        objectWillChange.send()
        if let id = manager.createVirtualDisplay(
            name: "Zenith Virtual HiDPI Display",
            width: resolution.width,
            height: resolution.height,
            refreshRate: 60.0,
            hiDPI: true
        ) {
            self.displayID = id
            self.isActive = true
            return true
        }
        return false
    }

    public func stop() {
        guard isActive else { return }
        objectWillChange.send()
        manager.destroyVirtualDisplay()
        self.displayID = 0
        self.isActive = false
    }

    public func toggle() {
        if isActive {
            stop()
        } else {
            start()
        }
    }
}
