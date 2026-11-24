import Foundation
import CoreGraphics

// MARK: - DisplayServices (built-in and Apple displays)

/// Brightness through DisplayServices, the framework behind the brightness keys on a MacBook and an Apple display.
public protocol DisplayServicesControlling: Sendable {
    /// Whether DisplayServices can change this display's brightness (it cannot for most third-party monitors).
    func canChangeBrightness(of display: UInt32) -> Bool
    /// The brightness, 0...1.
    func brightness(of display: UInt32) -> Double?
    @discardableResult
    func setBrightness(_ value: Double, of display: UInt32) -> Bool
}

/// The real thing: the private DisplayServices.framework, resolved at run time. Missing symbols read as "cannot
/// change". The calls are the ones MonitorControl uses (MIT, Copyright © 2017 MonitorControl; see
/// THIRD_PARTY_NOTICES.md).
public struct DisplayServicesBridge: DisplayServicesControlling {
    private typealias CanChange = @convention(c) (UInt32) -> Bool
    private typealias Get = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias Put = @convention(c) (UInt32, Float) -> Int32

    private struct Functions: @unchecked Sendable {
        let canChange: CanChange
        let get: Get
        let set: Put
    }

    private static let functions: Functions? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let canChange = dlsym(handle, "DisplayServicesCanChangeBrightness"),
              let get = dlsym(handle, "DisplayServicesGetBrightness"),
              let set = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
        return Functions(
            canChange: unsafeBitCast(canChange, to: CanChange.self),
            get: unsafeBitCast(get, to: Get.self),
            set: unsafeBitCast(set, to: Put.self)
        )
    }()

    public init() {}

    public func canChangeBrightness(of display: UInt32) -> Bool {
        Self.functions?.canChange(display) ?? false
    }

    public func brightness(of display: UInt32) -> Double? {
        guard let functions = Self.functions else { return nil }
        var value: Float = 0
        guard functions.get(display, &value) == 0, value.isFinite else { return nil }
        return min(max(Double(value), 0), 1)
    }

    @discardableResult
    public func setBrightness(_ value: Double, of display: UInt32) -> Bool {
        guard let functions = Self.functions else { return false }
        return functions.set(display, Float(min(max(value, 0), 1))) == 0
    }
}

// MARK: - Gamma (software dimming)

/// A display's colour transfer table: what the picture's levels are mapped through before they reach the panel.
public struct GammaTable: Equatable, Sendable {
    public var red: [Float]
    public var green: [Float]
    public var blue: [Float]

    public init(red: [Float], green: [Float], blue: [Float]) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Every entry times `factor`: the same picture, darker.
    public func scaled(by factor: Float) -> GammaTable {
        GammaTable(red: red.map { $0 * factor }, green: green.map { $0 * factor }, blue: blue.map { $0 * factor })
    }
}

/// Reads and writes a display's transfer table.
public protocol GammaControlling: Sendable {
    /// The table in effect now, `nil` if the display has none to read.
    func table(for display: UInt32) -> GammaTable?
    @discardableResult
    func apply(_ table: GammaTable, to display: UInt32) -> Bool
}

/// CoreGraphics' own calls (`CGGetDisplayTransferByTable` / `CGSetDisplayTransferByTable`): public API, no permission.
/// The scaling approach is the one MonitorControl uses for its software dimming (MIT, Copyright © 2017
/// MonitorControl; see THIRD_PARTY_NOTICES.md).
public struct CoreGraphicsGamma: GammaControlling {
    private static let capacity: UInt32 = 256

    public init() {}

    public func table(for display: UInt32) -> GammaTable? {
        var red = [CGGammaValue](repeating: 0, count: Int(Self.capacity))
        var green = red
        var blue = red
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(display, Self.capacity, &red, &green, &blue, &count) == .success, count > 0 else {
            return nil
        }
        let used = Int(count)
        return GammaTable(red: Array(red.prefix(used)), green: Array(green.prefix(used)), blue: Array(blue.prefix(used)))
    }

    @discardableResult
    public func apply(_ table: GammaTable, to display: UInt32) -> Bool {
        let count = min(table.red.count, table.green.count, table.blue.count)
        guard count > 0 else { return false }
        return CGSetDisplayTransferByTable(display, UInt32(count), table.red, table.green, table.blue) == .success
    }
}

/// Software dimming on top of a `GammaControlling`: scales the table the display had when it was first dimmed, and puts
/// that table back when the brightness is back to 100%, when the display goes, and when the app quits.
public final class GammaDimmer: @unchecked Sendable {
    /// The dimmest the picture gets (as a share of its normal level): fully black would leave nothing to find the
    /// slider by. MonitorControl uses the same floor.
    public static let floor: Float = 0.15
    /// The one the app uses.
    public static let shared = GammaDimmer(control: CoreGraphicsGamma())

    private let control: any GammaControlling
    private let lock = NSLock()
    private var originals: [UInt32: GammaTable] = [:]
    private var values: [UInt32: Double] = [:]

    public init(control: any GammaControlling) {
        self.control = control
    }

    /// Whether the display has a table to scale.
    public func isAvailable(for display: UInt32) -> Bool {
        lock.withLock { originals[display] != nil } || control.table(for: display) != nil
    }

    /// The brightness set through here, 1 if none.
    public func value(for display: UInt32) -> Double {
        lock.withLock { values[display] ?? 1 }
    }

    public var dimmedDisplays: [UInt32] {
        lock.withLock { values.keys.sorted() }
    }

    /// Sets the brightness, 0...1. At 1 the original table goes back and is forgotten. Returns false if the display
    /// has no table.
    @discardableResult
    public func setBrightness(_ value: Double, for display: UInt32) -> Bool {
        let clamped = min(max(value, 0), 1)
        return lock.withLock {
            if clamped >= 0.999 {
                restoreLocked(display)
                return true
            }
            guard let original = originals[display] ?? control.table(for: display) else { return false }
            originals[display] = original
            let scale = Self.floor + (1 - Self.floor) * Float(clamped)
            guard control.apply(original.scaled(by: scale), to: display) else { return false }
            values[display] = clamped
            return true
        }
    }

    /// Puts the display's own table back.
    public func restore(_ display: UInt32) {
        lock.withLock { restoreLocked(display) }
    }

    public func restoreAll() {
        lock.withLock {
            for display in Array(originals.keys) { restoreLocked(display) }
        }
    }

    /// Writes the dimmed table again (a display change may have reset it).
    public func reapply(_ display: UInt32) {
        lock.withLock {
            guard let original = originals[display], let value = values[display] else { return }
            control.apply(original.scaled(by: Self.floor + (1 - Self.floor) * Float(value)), to: display)
        }
    }

    private func restoreLocked(_ display: UInt32) {
        if let original = originals[display] { control.apply(original, to: display) }
        originals[display] = nil
        values[display] = nil
    }
}
