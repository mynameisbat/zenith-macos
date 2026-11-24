import AppKit
import Combine
import Foundation

/// How a display's brightness is changed.
public enum DisplayBackend: String, Sendable, Equatable {
    /// DDC/CI over the display's cable: the monitor's own backlight.
    case ddc
    /// DisplayServices: the built-in display and Apple displays.
    case appleNative
    /// Software: the picture's gamma table is scaled down. The backlight stays as it is.
    case gamma
    /// Nothing works on this display.
    case none
}

/// Which backend a display gets, from what it turned out to support: its own brightness control first, then DDC, then
/// software dimming.
public enum DisplayBackendPolicy {
    public static func choose(nativeCanChange: Bool, ddcBrightnessReadable: Bool, gammaAvailable: Bool) -> DisplayBackend {
        if nativeCanChange { return .appleNative }
        if ddcBrightnessReadable { return .ddc }
        return gammaAvailable ? .gamma : .none
    }
}

/// One display as the Displays page shows it.
public struct ControlledDisplay: Identifiable, Equatable, Sendable {
    /// The `CGDirectDisplayID`.
    public let id: UInt32
    public var name: String
    public var isBuiltIn: Bool
    public var backend: DisplayBackend
    /// Still finding out what the display supports (a DDC read takes a moment).
    public var isProbing: Bool
    /// 0...1.
    public var brightness: Double
    /// 0...1 when the display takes volume over DDC, else `nil`.
    public var volume: Double?

    public init(id: UInt32, name: String, isBuiltIn: Bool, backend: DisplayBackend, isProbing: Bool = false, brightness: Double = 1, volume: Double? = nil) {
        self.id = id
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.backend = backend
        self.isProbing = isProbing
        self.brightness = brightness
        self.volume = volume
    }
}

/// Changes the brightness (and, over DDC, the volume) of every display.
///
/// Three backends, picked per display (`DisplayBackendPolicy`): DisplayServices for the built-in display and Apple
/// displays, DDC/CI for other monitors, and a gamma-table fallback. Everything that blocks (the DDC bus takes tens of
/// milliseconds per call) runs on a serial queue of its own for each display, never on the main thread; a slider's
/// values are coalesced (`CoalescedWriter`) so a drag sends about ten a second and the last one.
///
/// Values are read when a display shows up and when the page opens; the list is refreshed when the screen
/// configuration changes (`startObservingScreenChanges`). Nothing polls.
@MainActor
public final class DisplayBrightnessService: ObservableObject {
    public static let shared = DisplayBrightnessService()

    @Published public private(set) var displays: [ControlledDisplay] = []
    /// Whether the displays have been looked for once.
    @Published public private(set) var hasLoaded = false

    /// DDC commands per second while a slider is dragged: one every tenth of a second.
    public static let ddcWriteInterval: TimeInterval = 0.1

    private final class Runtime {
        let id: UInt32
        let queue: DispatchQueue
        var ddc: DDCDevice?
        var ddcBrightnessMaximum: UInt16 = 100
        var ddcVolumeMaximum: UInt16 = 100
        var brightnessWriter: CoalescedWriter<Double>?
        var volumeWriter: CoalescedWriter<Double>?
        /// Bumped by every change the user makes, so a read that started before it does not undo it.
        var epoch = 0

        init(id: UInt32) {
            self.id = id
            queue = DispatchQueue(label: "app.zenith.display.\(id)", qos: .userInitiated)
        }

        func resetControl() {
            ddc = nil
            brightnessWriter = nil
            volumeWriter = nil
        }
    }

    private let inventory: any DisplayInventory
    private let native: any DisplayServicesControlling
    private let dimmer: GammaDimmer
    private let timing: DDCTiming
    private let writeInterval: TimeInterval
    private let inventoryQueue = DispatchQueue(label: "app.zenith.display.inventory", qos: .userInitiated)
    private let isPreview: Bool

    private var runtimes: [UInt32: Runtime] = [:]
    private var generation = 0
    private var pendingOperations = 0
    private var chipMemory: [String: UInt8] = [:]
    private var screenObserver: NSObjectProtocol?
    private var refreshTask: Task<Void, Never>?

    public init(
        inventory: any DisplayInventory = SystemDisplayInventory(),
        native: any DisplayServicesControlling = DisplayServicesBridge(),
        dimmer: GammaDimmer = .shared,
        timing: DDCTiming = .standard,
        writeInterval: TimeInterval = DisplayBrightnessService.ddcWriteInterval
    ) {
        self.inventory = inventory
        self.native = native
        self.dimmer = dimmer
        self.timing = timing
        self.writeInterval = writeInterval
        self.isPreview = false
    }

    /// A service that shows `displays` as they are and talks to nothing (the screenshot renderer).
    public init(previewDisplays: [ControlledDisplay]) {
        inventory = SimulatedDisplayInventory(displays: [], links: [:])
        native = SimulatedDisplayServices()
        dimmer = GammaDimmer(control: SimulatedGamma())
        timing = .instant
        writeInterval = 0
        isPreview = true
        displays = previewDisplays
        hasLoaded = true
        IslandDisplaysPageSizing.displayCount = previewDisplays.count
    }

    // MARK: Looking for displays

    /// Called before the Displays page opens: the first time it looks for the displays, later it re-reads their values.
    public func pageWillOpen() {
        guard !isPreview else { return }
        if hasLoaded { reloadValues() } else { refresh() }
    }

    /// Follows the screen configuration: a display that comes or goes, or is reconfigured, is looked at again, once
    /// the displays have been looked at at all (nothing talks to a monitor before the page is first opened).
    public func startObservingScreenChanges() {
        guard screenObserver == nil, !isPreview else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenParametersChanged() }
        }
    }

    private func screenParametersChanged() {
        guard hasLoaded else { return }
        // A change arrives as a burst of notifications: look once, when it has settled.
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    /// Looks at every online display again: what backend it has, and its current values.
    public func refresh() {
        guard !isPreview else { return }
        generation &+= 1
        let current = generation
        let found = inventory.onlineDisplays()
        let known = Dictionary(displays.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let foundIDs = Set(found.map(\.id))
        for id in Array(runtimes.keys) where !foundIDs.contains(id) {
            dimmer.restore(id)
            runtimes[id] = nil
        }

        var next: [ControlledDisplay] = []
        var needsDDC: [DisplayDescriptor] = []
        var nativeIDs: [UInt32] = []
        var withoutDDC: [UInt32] = []
        for descriptor in found {
            let runtime = runtimes[descriptor.id] ?? Runtime(id: descriptor.id)
            runtimes[descriptor.id] = runtime
            runtime.resetControl()
            var entry = ControlledDisplay(
                id: descriptor.id, name: descriptor.name, isBuiltIn: descriptor.isBuiltIn, backend: .none,
                isProbing: true, brightness: known[descriptor.id]?.brightness ?? 1
            )
            if native.canChangeBrightness(of: descriptor.id) {
                entry.backend = .appleNative
                installNativeWriter(runtime)
                nativeIDs.append(descriptor.id)
            } else if descriptor.isBuiltIn {
                withoutDDC.append(descriptor.id)
            } else {
                needsDDC.append(descriptor)
            }
            next.append(entry)
        }
        displays = next
        hasLoaded = true
        IslandDisplaysPageSizing.displayCount = next.count

        for id in withoutDDC { settleWithoutDDC(id) }
        for id in nativeIDs { readNative(id, generation: current) }
        if !needsDDC.isEmpty { probeDDC(needsDDC, generation: current) }
    }

    /// Reads the values of the displays already known again (no new lookup).
    public func reloadValues() {
        guard !isPreview else { return }
        let current = generation
        for display in displays where !display.isProbing {
            guard let runtime = runtimes[display.id] else { continue }
            switch display.backend {
            case .appleNative:
                readNative(display.id, generation: current)
            case .ddc:
                guard let device = runtime.ddc else { continue }
                let id = display.id
                let epoch = runtime.epoch
                let hasVolume = display.volume != nil
                begin()
                runtime.queue.async { [weak self] in
                    let brightness = device.read(VCPCode.brightness).fraction
                    let volume = hasVolume ? device.read(VCPCode.volume).fraction : nil
                    Task { @MainActor in
                        self?.applyReload(id: id, epoch: epoch, generation: current, brightness: brightness, volume: volume)
                        self?.end()
                    }
                }
            case .gamma:
                let value = dimmer.value(for: display.id)
                update(display.id) { $0.brightness = value }
            case .none:
                break
            }
        }
    }

    // MARK: Changing values

    /// Sets a display's brightness, 0...1. While a slider is dragged pass `isFinal: false`; the value the drag ends on
    /// goes with `isFinal: true` and is sent without waiting for the interval.
    public func setBrightness(_ value: Double, for id: UInt32, isFinal: Bool = false) {
        guard let display = displays.first(where: { $0.id == id }), display.backend != .none, !display.isProbing else { return }
        let clamped = min(max(value, 0), 1)
        update(id) { $0.brightness = clamped }
        guard let runtime = runtimes[id] else { return }
        runtime.epoch += 1
        runtime.brightnessWriter?.submit(clamped, isFinal: isFinal)
    }

    /// Sets a display's volume over DDC, 0...1. Does nothing for a display without it.
    public func setVolume(_ value: Double, for id: UInt32, isFinal: Bool = false) {
        guard let display = displays.first(where: { $0.id == id }), display.backend == .ddc, display.volume != nil else { return }
        let clamped = min(max(value, 0), 1)
        update(id) { $0.volume = clamped }
        guard let runtime = runtimes[id] else { return }
        runtime.epoch += 1
        runtime.volumeWriter?.submit(clamped, isFinal: isFinal)
    }

    /// Puts every dimmed display's own gamma table back (the app also does it when it quits).
    public func restoreGamma() {
        dimmer.restoreAll()
        for display in displays where display.backend == .gamma {
            update(display.id) { $0.brightness = 1 }
        }
    }

    // MARK: Probing

    private func installNativeWriter(_ runtime: Runtime) {
        let native = native
        let id = runtime.id
        runtime.brightnessWriter = CoalescedWriter(queue: runtime.queue, minInterval: 0) { value in
            native.setBrightness(value, of: id)
        }
    }

    private func installGammaWriter(_ runtime: Runtime) {
        let dimmer = dimmer
        let id = runtime.id
        runtime.brightnessWriter = CoalescedWriter(queue: runtime.queue, minInterval: 0) { value in
            dimmer.setBrightness(value, for: id)
        }
    }

    private func installDDCWriters(_ runtime: Runtime, device: DDCDevice) {
        let brightnessMaximum = Double(runtime.ddcBrightnessMaximum)
        let volumeMaximum = Double(runtime.ddcVolumeMaximum)
        runtime.brightnessWriter = CoalescedWriter(queue: runtime.queue, minInterval: writeInterval) { value in
            device.write(VCPCode.brightness, value: UInt16((value * brightnessMaximum).rounded()))
        }
        runtime.volumeWriter = CoalescedWriter(queue: runtime.queue, minInterval: writeInterval) { value in
            device.write(VCPCode.volume, value: UInt16((value * volumeMaximum).rounded()))
        }
    }

    private func readNative(_ id: UInt32, generation current: Int) {
        guard let runtime = runtimes[id] else { return }
        let native = native
        let epoch = runtime.epoch
        begin()
        runtime.queue.async { [weak self] in
            let value = native.brightness(of: id)
            Task { @MainActor in
                self?.finishNativeRead(id: id, epoch: epoch, generation: current, value: value)
                self?.end()
            }
        }
    }

    private func finishNativeRead(id: UInt32, epoch: Int, generation current: Int, value: Double?) {
        guard current == generation, let runtime = runtimes[id] else { return }
        guard let value else {
            settleWithoutDDC(id)
            return
        }
        let keepsUserValue = runtime.epoch != epoch
        update(id) {
            $0.isProbing = false
            if !keepsUserValue { $0.brightness = value }
        }
    }

    private func probeDDC(_ descriptors: [DisplayDescriptor], generation current: Int) {
        let inventory = inventory
        begin()
        inventoryQueue.async { [weak self] in
            let links = inventory.ddcLinks(for: descriptors)
            Task { @MainActor in
                self?.startDDCReads(descriptors: descriptors, links: links, generation: current)
                self?.end()
            }
        }
    }

    private struct DDCProbe: Sendable {
        let device: DDCDevice
        let brightness: DDCReadResult
        let volume: DDCReadResult
    }

    private func startDDCReads(descriptors: [DisplayDescriptor], links: [UInt32: DDCLink], generation current: Int) {
        guard current == generation else { return }
        for descriptor in descriptors {
            guard let runtime = runtimes[descriptor.id], let link = links[descriptor.id] else {
                settleWithoutDDC(descriptor.id)
                continue
            }
            let chip = chipMemory[descriptor.key] ?? link.initialChip
            let device = DDCDevice(transport: link.transport, initialChip: chip, timing: timing)
            let epoch = runtime.epoch
            begin()
            runtime.queue.async { [weak self] in
                let brightness = device.read(VCPCode.brightness)
                // Volume only from a display that answers brightness: the chip is settled by then.
                let volume = brightness.fraction == nil ? DDCReadResult.failed : device.read(VCPCode.volume)
                let probe = DDCProbe(device: device, brightness: brightness, volume: volume)
                Task { @MainActor in
                    self?.finishDDCProbe(descriptor: descriptor, epoch: epoch, generation: current, probe: probe)
                    self?.end()
                }
            }
        }
    }

    private func finishDDCProbe(descriptor: DisplayDescriptor, epoch: Int, generation current: Int, probe: DDCProbe) {
        guard current == generation, let runtime = runtimes[descriptor.id] else { return }
        guard case let .value(_, maximum) = probe.brightness, let fraction = probe.brightness.fraction, maximum > 0 else {
            settleWithoutDDC(descriptor.id)
            return
        }
        if probe.device.isChipConfirmed { chipMemory[descriptor.key] = probe.device.chip }
        runtime.ddc = probe.device
        runtime.ddcBrightnessMaximum = maximum
        if case let .value(_, volumeMaximum) = probe.volume, volumeMaximum > 0 { runtime.ddcVolumeMaximum = volumeMaximum }
        installDDCWriters(runtime, device: probe.device)
        let keepsUserValue = runtime.epoch != epoch
        update(descriptor.id) {
            $0.backend = .ddc
            $0.isProbing = false
            if !keepsUserValue { $0.brightness = fraction }
            $0.volume = probe.volume.fraction
        }
    }

    private func applyReload(id: UInt32, epoch: Int, generation current: Int, brightness: Double?, volume: Double?) {
        guard current == generation, let runtime = runtimes[id], runtime.epoch == epoch else { return }
        update(id) {
            if let brightness { $0.brightness = brightness }
            if let volume, $0.volume != nil { $0.volume = volume }
        }
    }

    /// The display has no usable DisplayServices or DDC control: dim it in software if it has a gamma table.
    private func settleWithoutDDC(_ id: UInt32) {
        guard let runtime = runtimes[id] else { return }
        runtime.resetControl()
        let backend = DisplayBackendPolicy.choose(nativeCanChange: false, ddcBrightnessReadable: false, gammaAvailable: dimmer.isAvailable(for: id))
        if backend == .gamma {
            installGammaWriter(runtime)
            dimmer.reapply(id)
        }
        let value = backend == .gamma ? dimmer.value(for: id) : 1
        update(id) {
            $0.backend = backend
            $0.isProbing = false
            $0.volume = nil
            $0.brightness = value
        }
    }

    private func update(_ id: UInt32, _ change: (inout ControlledDisplay) -> Void) {
        guard let index = displays.firstIndex(where: { $0.id == id }) else { return }
        var copy = displays[index]
        change(&copy)
        if copy != displays[index] { displays[index] = copy }
    }

    // MARK: Waiting (tests)

    private func begin() { pendingOperations += 1 }
    private func end() { pendingOperations -= 1 }

    /// Returns once every lookup, read and write started so far is done.
    func waitUntilIdle() async {
        while pendingOperations > 0 {
            try? await Task.sleep(for: .milliseconds(2))
        }
        for runtime in Array(runtimes.values) {
            await runtime.brightnessWriter?.flush()
            await runtime.volumeWriter?.flush()
        }
    }
}
