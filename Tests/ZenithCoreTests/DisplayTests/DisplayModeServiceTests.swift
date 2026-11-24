import Foundation
import Testing
@testable import ZenithCore

@Suite("Display Mode Service Suite")
@MainActor
struct DisplayModeServiceTests {
    private struct SimulatedInventory: DisplayInventory {
        let list: [DisplayDescriptor]
        @MainActor func onlineDisplays() -> [DisplayDescriptor] { list }
        func ddcLinks(for displays: [DisplayDescriptor]) -> [UInt32: DDCLink] { [:] }
    }

    private final class SimulatedConfiguring: DisplayConfiguring, @unchecked Sendable {
        var modesByDisplay: [UInt32: [DisplayModeDescriptor]]
        var currentByDisplay: [UInt32: DisplayModeDescriptor]
        var setCalls: [(mode: DisplayModeDescriptor, displayID: UInt32, permanently: Bool)] = []

        init(modes: [UInt32: [DisplayModeDescriptor]], current: [UInt32: DisplayModeDescriptor] = [:]) {
            self.modesByDisplay = modes
            self.currentByDisplay = current
        }

        func allModes(for displayID: UInt32) -> [DisplayModeDescriptor] {
            modesByDisplay[displayID] ?? []
        }

        func currentMode(for displayID: UInt32) -> DisplayModeDescriptor? {
            currentByDisplay[displayID]
        }

        func setMode(_ mode: DisplayModeDescriptor, for displayID: UInt32, permanently: Bool) -> Bool {
            setCalls.append((mode, displayID, permanently))
            currentByDisplay[displayID] = mode
            return true
        }
    }

    private let sampleModes: [DisplayModeDescriptor] = [
        DisplayModeDescriptor(id: 1, width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080, refreshRate: 60.0, isHiDPI: false, isCurrent: true),
        DisplayModeDescriptor(id: 2, width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080, refreshRate: 75.0, isHiDPI: false, isCurrent: false),
        DisplayModeDescriptor(id: 3, width: 2560, height: 1440, pixelWidth: 5120, pixelHeight: 2880, refreshRate: 60.0, isHiDPI: true, isCurrent: false),
        DisplayModeDescriptor(id: 4, width: 3840, height: 2160, pixelWidth: 3840, pixelHeight: 2160, refreshRate: 120.0, isHiDPI: false, isCurrent: false)
    ]

    @Test("DMS-01: DisplayModeDescriptor formats resolution, rate and titles properly")
    func testDescriptorFormatting() {
        let m1 = sampleModes[0]
        #expect(m1.resolutionString == "1920 × 1080")
        #expect(m1.refreshRateString == "60 Hz")
        #expect(m1.fullTitle == "1920 × 1080 @ 60 Hz")

        let m3 = sampleModes[2]
        #expect(m3.isHiDPI)
        #expect(m3.fullTitle.contains("Retina"))

        let m4 = sampleModes[3]
        #expect(m4.refreshRateString.contains("ProMotion"))
    }

    @Test("DMS-02: Service discovers displays and populates mode listings")
    func testDiscovery() {
        let disp = DisplayDescriptor(id: 10, name: "Test Monitor", isBuiltIn: false)
        let inv = SimulatedInventory(list: [disp])
        let conf = SimulatedConfiguring(modes: [10: sampleModes], current: [10: sampleModes[0]])

        let service = DisplayModeService(inventory: inv, configuring: conf)
        #expect(service.displays.count == 1)
        #expect(service.displays.first?.name == "Test Monitor")
        #expect(service.modes(for: 10).count == 4)
        #expect(service.currentMode(for: 10)?.id == 1)
    }

    @Test("DMS-03: Applying a mode applies forSession and sets up 15-second pending revert")
    func testApplyMode() {
        let disp = DisplayDescriptor(id: 10, name: "Test Monitor", isBuiltIn: false)
        let conf = SimulatedConfiguring(modes: [10: sampleModes], current: [10: sampleModes[0]])
        let service = DisplayModeService(inventory: SimulatedInventory(list: [disp]), configuring: conf)

        let target = sampleModes[1]
        let ok = service.applyMode(target, for: 10)
        #expect(ok)
        #expect(conf.setCalls.count == 1)
        #expect(conf.setCalls[0].mode.id == 2)
        #expect(!conf.setCalls[0].permanently) // Must be temporary first!

        #expect(service.pendingRevert != nil)
        #expect(service.pendingRevert?.secondsLeft == 15)
        #expect(service.pendingRevert?.originalMode.id == 1)
        #expect(service.pendingRevert?.targetMode.id == 2)
        #expect(service.currentMode(for: 10)?.id == 2)
    }

    @Test("DMS-04: Confirming keep changes commits permanently and dismisses pending state")
    func testConfirmKeepChanges() {
        let disp = DisplayDescriptor(id: 10, name: "Test Monitor", isBuiltIn: false)
        let conf = SimulatedConfiguring(modes: [10: sampleModes], current: [10: sampleModes[0]])
        let service = DisplayModeService(inventory: SimulatedInventory(list: [disp]), configuring: conf)

        service.applyMode(sampleModes[1], for: 10)
        service.confirmKeepChanges()

        #expect(service.pendingRevert == nil)
        #expect(conf.setCalls.count == 2)
        #expect(conf.setCalls[1].permanently) // Second call commits permanently
        #expect(conf.setCalls[1].mode.id == 2)
        #expect(service.currentMode(for: 10)?.id == 2)
    }

    @Test("DMS-05: Reverting changes restores original mode permanently")
    func testRevertChanges() {
        let disp = DisplayDescriptor(id: 10, name: "Test Monitor", isBuiltIn: false)
        let conf = SimulatedConfiguring(modes: [10: sampleModes], current: [10: sampleModes[0]])
        let service = DisplayModeService(inventory: SimulatedInventory(list: [disp]), configuring: conf)

        service.applyMode(sampleModes[1], for: 10)
        service.revertChanges()

        #expect(service.pendingRevert == nil)
        #expect(conf.setCalls.count == 2)
        #expect(conf.setCalls[1].permanently)
        #expect(conf.setCalls[1].mode.id == 1) // Reverted back to original id 1
        #expect(service.currentMode(for: 10)?.id == 1)
    }

    @Test("DMS-06: Countdown ticks down and automatically reverts when time reaches zero")
    func testCountdownAutomaticReversion() {
        let disp = DisplayDescriptor(id: 10, name: "Test Monitor", isBuiltIn: false)
        let conf = SimulatedConfiguring(modes: [10: sampleModes], current: [10: sampleModes[0]])
        let service = DisplayModeService(inventory: SimulatedInventory(list: [disp]), configuring: conf)

        service.applyMode(sampleModes[1], for: 10)
        #expect(service.pendingRevert?.secondsLeft == 15)

        // Tick 14 times
        for _ in 1...14 {
            service.tickCountdown()
        }
        #expect(service.pendingRevert?.secondsLeft == 1)
        #expect(service.currentMode(for: 10)?.id == 2)

        // Final tick
        service.tickCountdown()
        #expect(service.pendingRevert == nil) // Automatically reverted
        #expect(service.currentMode(for: 10)?.id == 1) // Back to original!
    }

    @Test("DMS-07: Switching mode while one is pending reverts first before applying second")
    func testSwitchWhilePendingRevert() {
        let disp = DisplayDescriptor(id: 10, name: "Test Monitor", isBuiltIn: false)
        let conf = SimulatedConfiguring(modes: [10: sampleModes], current: [10: sampleModes[0]])
        let service = DisplayModeService(inventory: SimulatedInventory(list: [disp]), configuring: conf)

        service.applyMode(sampleModes[1], for: 10)
        #expect(service.pendingRevert?.targetMode.id == 2)

        // Apply mode 3
        service.applyMode(sampleModes[2], for: 10)
        #expect(service.pendingRevert?.targetMode.id == 3)
        #expect(service.pendingRevert?.originalMode.id == 1)
    }
}
