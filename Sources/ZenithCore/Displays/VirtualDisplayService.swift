import AppKit
import CoreGraphics
import Foundation
import ObjectiveC
#if canImport(ZenithDisplayPrivate)
import ZenithDisplayPrivate
#endif

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

/// The system implementation managing CGVirtualDisplay via dynamic runtime invocation.
public final class SystemVirtualDisplayManager: VirtualDisplayManaging, @unchecked Sendable {
    private var activeDisplay: AnyObject?

    public init() {}

    public var isSupported: Bool {
        NSClassFromString("CGVirtualDisplay") != nil
    }

    public func createVirtualDisplay(name: String, width: Int, height: Int, refreshRate: Double, hiDPI: Bool) -> UInt32? {
        destroyVirtualDisplay()

        guard let descClass = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
              let dispClass = NSClassFromString("CGVirtualDisplay") as? NSObject.Type,
              let modeClass = NSClassFromString("CGVirtualDisplayMode") as? NSObject.Type,
              let settClass = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type else {
            return nil
        }

        let desc = descClass.init()
        desc.setValue(name, forKey: "name")
        desc.setValue(UInt32(width), forKey: "maxPixelsWide")
        desc.setValue(UInt32(height), forKey: "maxPixelsHigh")
        desc.setValue(CGSize(width: 527, height: 296), forKey: "sizeInMillimeters")
        desc.setValue(UInt32(0x3456), forKey: "vendorID")
        desc.setValue(UInt32(0x1234), forKey: "productID")
        desc.setValue(UInt32(1), forKey: "serialNum")
        desc.setValue(DispatchQueue.main, forKey: "queue")

        typealias ModeInitFn = @convention(c) (AnyObject, Selector, UInt32, UInt32, Double) -> AnyObject
        let modeInit = unsafeBitCast(class_getMethodImplementation(modeClass, NSSelectorFromString("initWithWidth:height:refreshRate:")), to: ModeInitFn.self)

        var modes: [AnyObject] = []
        if hiDPI && width >= 2 && height >= 2 {
            if let hidpiAlloc = modeClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() {
                let hidpi = modeInit(hidpiAlloc, NSSelectorFromString("initWithWidth:height:refreshRate:"), UInt32(width / 2), UInt32(height / 2), refreshRate)
                modes.append(hidpi)
            }
        }
        if let nativeAlloc = modeClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() {
            let native = modeInit(nativeAlloc, NSSelectorFromString("initWithWidth:height:refreshRate:"), UInt32(width), UInt32(height), refreshRate)
            modes.append(native)
        }

        let sett = settClass.init()
        sett.setValue(modes, forKey: "modes")
        sett.setValue(UInt32(hiDPI ? 1 : 0), forKey: "hiDPI")

        guard let dispAlloc = dispClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() else { return nil }
        typealias DispInitFn = @convention(c) (AnyObject, Selector, AnyObject) -> AnyObject?
        let dispInit = unsafeBitCast(class_getMethodImplementation(dispClass, NSSelectorFromString("initWithDescriptor:")), to: DispInitFn.self)
        guard let display = dispInit(dispAlloc, NSSelectorFromString("initWithDescriptor:"), desc) else { return nil }

        typealias ApplyFn = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        let apply = unsafeBitCast(class_getMethodImplementation(dispClass, NSSelectorFromString("applySettings:")), to: ApplyFn.self)
        guard apply(display, NSSelectorFromString("applySettings:"), sett) else { return nil }

        self.activeDisplay = display
        let id = (display.value(forKey: "displayID") as? UInt32) ?? 0
        return id != 0 ? id : nil
    }

    public func destroyVirtualDisplay() {
        activeDisplay = nil
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
