import Testing
import Foundation
@testable import ZenithCore

/// An inventory whose displays can change between two `refresh()` calls, as when a monitor is unplugged.
private final class ChangingInventory: DisplayInventory, @unchecked Sendable {
    private let lock = NSLock()
    private var displays: [DisplayDescriptor]
    private var links: [UInt32: DDCLink]

    init(displays: [DisplayDescriptor], links: [UInt32: DDCLink] = [:]) {
        self.displays = displays
        self.links = links
    }

    func replace(displays: [DisplayDescriptor]) { lock.withLock { self.displays = displays } }

    @MainActor func onlineDisplays() -> [DisplayDescriptor] { lock.withLock { displays } }

    func ddcLinks(for requested: [DisplayDescriptor]) -> [UInt32: DDCLink] {
        lock.withLock { links.filter { id, _ in requested.contains { $0.id == id } } }
    }
}

private let laptop = DisplayDescriptor(id: 1, name: "Built-in Display", isBuiltIn: true, vendor: 0x0610, model: 0xA050, serial: 0)
private let monitor = DisplayDescriptor(id: 2, name: "Desk Monitor", isBuiltIn: false, vendor: 0x0443, model: 0x1234, serial: 7)
private let projector = DisplayDescriptor(id: 3, name: "Projector", isBuiltIn: false, vendor: 0x0443, model: 0x4321, serial: 9)

/// What the service does with the displays, using only simulated buses, DisplayServices and gamma: nothing here touches
/// this Mac's displays.
@Suite("Display Brightness Suite")
@MainActor
struct DisplayBrightnessServiceTests {
    private func makeService(
        displays: [DisplayDescriptor],
        links: [UInt32: DDCLink] = [:],
        native: SimulatedDisplayServices = SimulatedDisplayServices(),
        gamma: SimulatedGamma = SimulatedGamma(),
        writeInterval: TimeInterval = 0
    ) -> (service: DisplayBrightnessService, dimmer: GammaDimmer, inventory: ChangingInventory) {
        let inventory = ChangingInventory(displays: displays, links: links)
        let dimmer = GammaDimmer(control: gamma)
        let service = DisplayBrightnessService(
            inventory: inventory, native: native, dimmer: dimmer, timing: .instant, writeInterval: writeInterval
        )
        return (service, dimmer, inventory)
    }

    private func ddcLink(_ bus: SimulatedDDCMonitor, chip: UInt8 = DDCChip.standard) -> DDCLink {
        DDCLink(transport: bus, initialChip: chip, edid: nil)
    }

    // MARK: Backend choice

    @Test("DB-01: Its own brightness control wins, then DDC, then software dimming, then nothing")
    func testBackendPolicy() {
        typealias P = DisplayBackendPolicy
        #expect(P.choose(nativeCanChange: true, ddcBrightnessReadable: true, gammaAvailable: true) == .appleNative)
        #expect(P.choose(nativeCanChange: false, ddcBrightnessReadable: true, gammaAvailable: true) == .ddc)
        #expect(P.choose(nativeCanChange: false, ddcBrightnessReadable: false, gammaAvailable: true) == .gamma)
        #expect(P.choose(nativeCanChange: false, ddcBrightnessReadable: false, gammaAvailable: false) == .none)
    }

    @Test("DB-02: The built-in display uses DisplayServices, the monitor DDC with its volume, and a monitor with no DDC is dimmed in software")
    func testEachDisplayGetsItsBackend() async {
        let bus = SimulatedDDCMonitor(acceptedChip: DDCChip.standard)
        let native = SimulatedDisplayServices(controllable: [1: 0.5])
        let gamma = SimulatedGamma(displays: [3])
        let (service, _, _) = makeService(displays: [laptop, monitor, projector], links: [2: ddcLink(bus)], native: native, gamma: gamma)
        #expect(!service.hasLoaded)
        service.refresh()
        #expect(service.hasLoaded && service.displays.count == 3)
        // Before the bus has answered, the external ones are still being looked at.
        #expect(service.displays.first { $0.id == 2 }?.isProbing == true)
        await service.waitUntilIdle()

        let byID = Dictionary(uniqueKeysWithValues: service.displays.map { ($0.id, $0) })
        #expect(byID[1]?.backend == .appleNative && byID[1]?.brightness == 0.5 && byID[1]?.volume == nil)
        #expect(byID[2]?.backend == .ddc && byID[2]?.brightness == 0.7 && byID[2]?.volume == 0.3)
        #expect(byID[3]?.backend == .gamma && byID[3]?.brightness == 1)
        #expect(service.displays.allSatisfy { !$0.isProbing })
        #expect(byID[1]?.isBuiltIn == true && byID[2]?.name == "Desk Monitor")
    }

    @Test("DB-03: A monitor that does not answer brightness falls back to gamma, or to nothing without a table")
    func testFallbacks() async {
        let silent = SimulatedDDCMonitor(behavior: .alwaysNull)
        let noBrightness = SimulatedDDCMonitor(features: [VCPCode.volume: .init(current: 5, maximum: 100)], unsupported: [VCPCode.brightness])
        let (service, _, _) = makeService(
            displays: [monitor, projector], links: [2: ddcLink(silent), 3: ddcLink(noBrightness)], gamma: SimulatedGamma(displays: [2])
        )
        service.refresh()
        await service.waitUntilIdle()
        #expect(service.displays.first { $0.id == 2 }?.backend == .gamma)
        // Display 3 has no gamma table in the simulation either.
        let third = service.displays.first { $0.id == 3 }
        #expect(third?.backend == DisplayBackend.none && third?.isProbing == false && third?.volume == nil)
    }

    @Test("DB-04: An external display with no DDC connection at all is dimmed in software; the built-in one without DisplayServices too")
    func testNoLink() async {
        let (service, _, _) = makeService(displays: [laptop, projector], gamma: SimulatedGamma(displays: [1, 3]))
        service.refresh()
        await service.waitUntilIdle()
        #expect(service.displays.map(\.backend) == [.gamma, .gamma])
    }

    @Test("DB-05: The chip that worked is remembered for the display across a refresh")
    func testChipIsRemembered() async {
        let bus = SimulatedDDCMonitor(acceptedChip: DDCChip.bridge)
        let (service, _, _) = makeService(displays: [monitor], links: [2: ddcLink(bus, chip: DDCChip.standard)])
        service.refresh()
        await service.waitUntilIdle()
        #expect(service.displays.first?.backend == .ddc)
        #expect(bus.readChips.first == DDCChip.standard)
        let readsBefore = bus.readChips.count
        service.refresh()
        await service.waitUntilIdle()
        // The second look starts at 0xB7 and does not need the fallback.
        #expect(bus.readChips.dropFirst(readsBefore).first == DDCChip.bridge)
        #expect(service.displays.first?.backend == .ddc)
    }

    // MARK: Changing values

    @Test("DB-06: DisplayServices gets the value, clamped, and the display reads back what was set")
    func testNativeWrite() async {
        let native = SimulatedDisplayServices(controllable: [1: 0.5])
        let (service, _, _) = makeService(displays: [laptop], native: native)
        service.refresh()
        await service.waitUntilIdle()
        service.setBrightness(0.25, for: 1, isFinal: true)
        service.setBrightness(1.7, for: 1, isFinal: true)
        await service.waitUntilIdle()
        #expect(service.displays.first?.brightness == 1)
        #expect(native.setCalls.last?.value == 1 && native.setCalls.last?.display == 1)
        service.setBrightness(-3, for: 1, isFinal: true)
        await service.waitUntilIdle()
        #expect(service.displays.first?.brightness == 0)
        #expect(native.brightness(of: 1) == 0)
    }

    @Test("DB-07: A DDC brightness and volume change reaches the monitor as raw values scaled to its maximum")
    func testDDCWrite() async {
        let bus = SimulatedDDCMonitor(acceptedChip: DDCChip.standard, features: [
            VCPCode.brightness: .init(current: 70, maximum: 100), VCPCode.volume: .init(current: 30, maximum: 255)
        ])
        let (service, _, _) = makeService(displays: [monitor], links: [2: ddcLink(bus)])
        service.refresh()
        await service.waitUntilIdle()
        #expect(service.displays.first?.volume == 30.0 / 255.0)

        service.setBrightness(0.4, for: 2, isFinal: true)
        service.setVolume(0.5, for: 2, isFinal: true)
        await service.waitUntilIdle()
        #expect(bus.feature(VCPCode.brightness)?.current == 40)
        #expect(bus.feature(VCPCode.volume)?.current == 128)  // 0.5 of 255, rounded
        #expect(service.displays.first?.brightness == 0.4)
    }

    @Test("DB-08: A slider drag sends far fewer commands than values, and always the last one")
    func testServiceCoalescing() async {
        let bus = SimulatedDDCMonitor(acceptedChip: DDCChip.standard)
        let (service, _, _) = makeService(displays: [monitor], links: [2: ddcLink(bus)], writeInterval: 0.05)
        service.refresh()
        await service.waitUntilIdle()
        for step in 1...60 { service.setBrightness(Double(step) / 100, for: 2) }
        service.setBrightness(0.9, for: 2, isFinal: true)
        await service.waitUntilIdle()
        // Each command is written twice (a monitor sometimes misses one).
        let commands = bus.setCommands.count / 2
        #expect(commands >= 1 && commands <= 4, "\(commands) commands for 61 values")
        #expect(bus.feature(VCPCode.brightness)?.current == 90)
        #expect(service.displays.first?.brightness == 0.9)
    }

    @Test("DB-09: Volume is refused where the display has none, and setting a probing or unusable display does nothing")
    func testRefusedChanges() async {
        let bus = SimulatedDDCMonitor(unsupported: [VCPCode.volume])
        let (service, _, _) = makeService(displays: [monitor, projector], links: [2: ddcLink(bus)])
        service.refresh()
        service.setBrightness(0.1, for: 2)  // still being looked at
        #expect(service.displays.first { $0.id == 2 }?.brightness == 1)
        await service.waitUntilIdle()
        #expect(service.displays.first { $0.id == 2 }?.volume == nil)
        service.setVolume(0.9, for: 2, isFinal: true)
        service.setBrightness(0.5, for: 3, isFinal: true)  // no control at all
        service.setBrightness(0.5, for: 99, isFinal: true)  // unknown
        await service.waitUntilIdle()
        #expect(bus.setCommands.isEmpty)
        #expect(service.displays.first { $0.id == 3 }?.backend == DisplayBackend.none)
        #expect(service.displays.first { $0.id == 3 }?.brightness == 1)
    }

    @Test("DB-10: Opening the page again reads the current values; a value the user set in the meantime is kept")
    func testReload() async {
        let bus = SimulatedDDCMonitor(acceptedChip: DDCChip.standard)
        let native = SimulatedDisplayServices(controllable: [1: 0.5])
        let (service, _, _) = makeService(displays: [laptop, monitor], links: [2: ddcLink(bus)], native: native)
        service.pageWillOpen()  // the first time: a full look
        await service.waitUntilIdle()
        #expect(service.displays.map(\.backend) == [.appleNative, .ddc])

        // Changed with the monitor's own buttons and the keyboard.
        _ = bus.write(chip: DDCChip.standard, offset: 0x51, bytes: DDCPacket.setRequest(code: VCPCode.brightness, value: 20))
        native.setBrightness(0.9, of: 1)
        service.pageWillOpen()
        await service.waitUntilIdle()
        #expect(service.displays.map(\.brightness) == [0.9, 0.2])

        // A read that started before a change of the user's must not undo it.
        service.reloadValues()
        service.setBrightness(0.6, for: 2, isFinal: true)
        await service.waitUntilIdle()
        #expect(service.displays.last?.brightness == 0.6)
    }

    // MARK: Gamma

    @Test("DB-11: Software dimming scales the display's own table and 100% puts the original back")
    func testGammaDimAndRestore() {
        let gamma = SimulatedGamma(displays: [3])
        let original = gamma.table(for: 3)
        let dimmer = GammaDimmer(control: gamma)
        #expect(dimmer.isAvailable(for: 3) && !dimmer.isAvailable(for: 4))

        #expect(dimmer.setBrightness(0.5, for: 3))
        let scale = GammaDimmer.floor + (1 - GammaDimmer.floor) * 0.5
        #expect(gamma.table(for: 3) == original?.scaled(by: scale))
        #expect(dimmer.value(for: 3) == 0.5 && dimmer.dimmedDisplays == [3])
        // Dimming again scales the original, not the already dimmed table.
        #expect(dimmer.setBrightness(0.5, for: 3))
        #expect(gamma.table(for: 3) == original?.scaled(by: scale))

        // Never fully black.
        #expect(dimmer.setBrightness(0, for: 3))
        #expect(gamma.table(for: 3) == original?.scaled(by: GammaDimmer.floor))

        #expect(dimmer.setBrightness(1, for: 3))
        #expect(gamma.table(for: 3) == original)
        #expect(dimmer.dimmedDisplays.isEmpty && dimmer.value(for: 3) == 1)
        #expect(!dimmer.setBrightness(0.5, for: 4), "a display with no table cannot be dimmed")
    }

    @Test("DB-12: Every dimmed display gets its original table back at once (what quitting does), and a reset display is dimmed again")
    func testGammaRestoreAllAndReapply() {
        let gamma = SimulatedGamma(displays: [2, 3])
        let originals = [gamma.table(for: 2), gamma.table(for: 3)]
        let dimmer = GammaDimmer(control: gamma)
        dimmer.setBrightness(0.3, for: 2)
        dimmer.setBrightness(0.6, for: 3)
        let dimmed = gamma.table(for: 2)

        // The system reset display 2's table (a display reconfiguration does that).
        gamma.apply(originals[0]!, to: 2)
        dimmer.reapply(2)
        #expect(gamma.table(for: 2) == dimmed)

        dimmer.restoreAll()
        #expect([gamma.table(for: 2), gamma.table(for: 3)] == originals)
        #expect(dimmer.dimmedDisplays.isEmpty)
        dimmer.restoreAll()  // nothing left: no further writes
        #expect(gamma.appliedTables.count == 6)
    }

    @Test("DB-13: Through the service, a gamma display dims, and restoreGamma brings it back to 100%")
    func testServiceGamma() async {
        let gamma = SimulatedGamma(displays: [3])
        let original = gamma.table(for: 3)
        let (service, dimmer, _) = makeService(displays: [projector], gamma: gamma)
        service.refresh()
        await service.waitUntilIdle()
        service.setBrightness(0.4, for: 3, isFinal: true)
        await service.waitUntilIdle()
        #expect(gamma.table(for: 3) != original && dimmer.value(for: 3) == 0.4)

        service.restoreGamma()
        #expect(gamma.table(for: 3) == original)
        #expect(service.displays.first?.brightness == 1)
    }

    @Test("DB-14: A display that disappears gets its table restored and is forgotten; one that stays keeps its dimming across a refresh")
    func testGammaWhenDisplaysChange() async {
        let gamma = SimulatedGamma(displays: [2, 3])
        let original3 = gamma.table(for: 3)
        let (service, dimmer, inventory) = makeService(displays: [monitor, projector], gamma: gamma)
        service.refresh()
        await service.waitUntilIdle()
        service.setBrightness(0.5, for: 2, isFinal: true)
        service.setBrightness(0.5, for: 3, isFinal: true)
        await service.waitUntilIdle()

        inventory.replace(displays: [monitor])
        service.refresh()
        await service.waitUntilIdle()
        #expect(service.displays.map(\.id) == [2])
        #expect(gamma.table(for: 3) == original3)
        #expect(dimmer.dimmedDisplays == [2])
        #expect(service.displays.first?.brightness == 0.5, "the dimming of a display that stayed is shown again")
    }

    // MARK: The service

    @Test("DB-15: A preview service shows its displays and never talks to anything")
    func testPreview() async {
        let service = DisplayBrightnessService(previewDisplays: [
            ControlledDisplay(id: 1, name: "A", isBuiltIn: true, backend: .appleNative, brightness: 0.4),
            ControlledDisplay(id: 2, name: "B", isBuiltIn: false, backend: .ddc, brightness: 0.8, volume: 0.2)
        ])
        #expect(service.hasLoaded && service.displays.count == 2)
        service.refresh()
        service.pageWillOpen()
        service.setBrightness(0.1, for: 1, isFinal: true)
        service.setVolume(0.9, for: 2, isFinal: true)
        await service.waitUntilIdle()
        #expect(service.displays.map(\.id) == [1, 2])
        #expect(service.displays[0].brightness == 0.1 && service.displays[1].volume == 0.9)
    }

    @Test("DB-16: Every change to the list is published")
    func testPublishes() async {
        let (service, _, _) = makeService(displays: [projector], gamma: SimulatedGamma(displays: [3]))
        var changes = 0
        let subscription = service.objectWillChange.sink { changes += 1 }
        service.refresh()
        let afterRefresh = changes
        #expect(afterRefresh > 0)
        await service.waitUntilIdle()
        service.setBrightness(0.5, for: 3)
        #expect(changes > afterRefresh)
        subscription.cancel()
    }
}

/// The writer behind a slider drag, on its own.
@Suite("Coalesced Writer Suite")
struct CoalescedWriterTests {
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int] = []
        private var times: [DispatchTime] = []
        func add(_ value: Int) { lock.withLock { values.append(value); times.append(.now()) } }
        var all: [Int] { lock.withLock { values } }
        var starts: [DispatchTime] { lock.withLock { times } }
    }

    @Test("CW-01: While a write is in flight, only the newest of the values submitted after it is sent next")
    func testLatestWins() async {
        let queue = DispatchQueue(label: "test.coalesce")
        let log = Log()
        let gate = DispatchSemaphore(value: 0)
        let writer = CoalescedWriter<Int>(queue: queue, minInterval: 0) { value in
            if log.all.isEmpty { gate.wait() }  // the first write is slow
            log.add(value)
        }
        writer.submit(1)
        // Wait until the first write is running, then pile up values behind it.
        try? await Task.sleep(for: .milliseconds(50))
        for value in 2...100 { writer.submit(value) }
        gate.signal()
        await writer.flush()
        #expect(log.all == [1, 100])
    }

    @Test("CW-02: Writes are at least the interval apart")
    func testInterval() async {
        let queue = DispatchQueue(label: "test.interval")
        let log = Log()
        let writer = CoalescedWriter<Int>(queue: queue, minInterval: 0.08) { log.add($0) }
        for value in 1...5 {
            writer.submit(value)
            try? await Task.sleep(for: .milliseconds(10))
        }
        await writer.flush()
        let starts = log.starts
        #expect(log.all.first == 1 && log.all.last == 5)
        #expect(log.all.count >= 2 && log.all.count <= 3, "\(log.all)")
        for (earlier, later) in zip(starts, starts.dropFirst()) {
            #expect(Double(later.uptimeNanoseconds - earlier.uptimeNanoseconds) / 1e9 >= 0.07)
        }
    }

    @Test("CW-03: A final value does not wait out the interval")
    func testFinalSkipsInterval() async {
        let queue = DispatchQueue(label: "test.final")
        let log = Log()
        let writer = CoalescedWriter<Int>(queue: queue, minInterval: 5) { log.add($0) }
        writer.submit(1)
        try? await Task.sleep(for: .milliseconds(30))
        writer.submit(2)  // would wait 5 s
        writer.submit(3, isFinal: true)
        await writer.flush()
        #expect(log.all == [1, 3])
    }

    @Test("CW-04: Nothing pending means flush returns at once, and a writer can be used again afterwards")
    func testIdleAndReuse() async {
        let queue = DispatchQueue(label: "test.idle")
        let log = Log()
        let writer = CoalescedWriter<Int>(queue: queue, minInterval: 0) { log.add($0) }
        await writer.flush()
        writer.submit(7)
        await writer.flush()
        writer.submit(8)
        await writer.flush()
        #expect(log.all == [7, 8])
    }
}

/// The Displays page's place among the island's tools and pages.
@Suite("Displays Page Suite", .serialized)
struct DisplaysPageTests {
    @Test("DP-01: Displays is a tool of the System group that opens its own page, and can be pinned to the dock")
    func testTool() {
        let system = IslandTool.groups.first { $0.id == "system" }
        #expect(system?.tools == [.system, .ports, .homebrew, .displays])
        #expect(IslandTool.displays.page == .displays && !IslandTool.displays.opensSettingsWindow && !IslandTool.displays.isToggle)
        #expect(IslandTool.displays.title == "Displays" && !IslandTool.displays.detail.isEmpty && !IslandTool.displays.icon.isEmpty)
        #expect(IslandDockLayout.canPin(.displays))
        var dock = IslandDockLayout(pinned: [.area])
        #expect(dock.pin(.displays) && dock.tools == [.area, .displays, .allTools])
    }

    @Test("DP-02: The page is as wide as the island and as tall as its cards, within bounds")
    func testPageSize() {
        let saved = IslandDisplaysPageSizing.displayCount
        defer { IslandDisplaysPageSizing.displayCount = saved }
        var heights: [CGFloat] = []
        for count in 0...6 {
            IslandDisplaysPageSizing.displayCount = count
            let size = IslandPage.displays.contentSize
            #expect(size.width == ZenithIslandGeometry.expandedWidth)
            heights.append(size.height)
        }
        #expect(heights[0] > 0 && heights[0] < heights[1])
        #expect(heights[1] < heights[2] && heights[2] < heights[3] && heights[3] < heights[4])
        // More than four displays scroll instead of growing the island.
        #expect(heights[5] == heights[4] && heights[6] == heights[4])
        #expect(heights[4] <= IslandPage.system.contentSize.height)
        #expect(IslandPage.displays.title == "Displays" && !IslandPage.displays.icon.isEmpty)
        IslandDisplaysPageSizing.displayCount = -3
        #expect(IslandDisplaysPageSizing.displayCount == 0)
    }

    @Test("DP-03: A small screen gets a smaller page, never a wider one")
    func testSmallScreen() {
        IslandDisplaysPageSizing.displayCount = 4
        defer { IslandDisplaysPageSizing.displayCount = 0 }
        let small = ZenithIslandGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1024, height: 500), notch: nil)
        let content = small.pageContentSize(for: .displays)
        #expect(content.width <= ZenithIslandGeometry.expandedWidth)
        #expect(content.height <= 500 - small.pageHeaderHeight - 90)
    }
}
