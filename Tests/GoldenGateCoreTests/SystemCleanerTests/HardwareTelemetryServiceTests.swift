import Testing
import Foundation
@testable import GoldenGateCore

@Suite("Hardware Telemetry Service Suite")
struct HardwareTelemetryServiceTests {

    @Test("HW-01: Live hardware snapshot retrieves valid disk and battery metrics")
    func testHardwareSnapshot() {
        let service = HardwareTelemetryService()
        let snapshot = service.fetchSnapshot()

        // Disk must be readable on macOS
        #expect(snapshot.disk.totalBytes > 0)
        #expect(snapshot.disk.freeBytes > 0)
        #expect(!snapshot.disk.volumeName.isEmpty)
        #expect(snapshot.disk.usedPercent >= 0.0 && snapshot.disk.usedPercent <= 100.0)

        // Battery: either laptop (hasBattery=true, percentage 0-100) or desktop (hasBattery=false)
        if snapshot.battery.hasBattery {
            #expect(snapshot.battery.percentage >= 0 && snapshot.battery.percentage <= 100)
            if let cycles = snapshot.battery.cycleCount {
                #expect(cycles >= 0)
            }
        } else {
            #expect(snapshot.battery.percentage == 100)
        }
    }

    @Test("HW-02: Bluetooth device model assigns correct system SF Symbols")
    func testBluetoothPeripheralIcons() {
        let airpods = BluetoothDeviceTelemetry(name: "Bat's AirPods Pro", batteryPercent: 92)
        #expect(airpods.icon == "headphones")

        let mouse = BluetoothDeviceTelemetry(name: "MX Master 3 Mouse", batteryPercent: 65)
        #expect(mouse.icon == "mouse.fill")

        let keyboard = BluetoothDeviceTelemetry(name: "Keychron K2 Keyboard", batteryPercent: 80)
        #expect(keyboard.icon == "keyboard.fill")

        let trackpad = BluetoothDeviceTelemetry(name: "Magic Trackpad", batteryPercent: 88)
        #expect(trackpad.icon == "hand.draw.fill")
    }

    @Test("HW-03: CPU telemetry collects core count and top hogs accurately")
    func testCPUTelemetry() {
        let service = HardwareTelemetryService()
        let cpu = service.readCPUTelemetry(topLimit: 5)

        #expect(cpu.coreCount > 0)
        #expect(cpu.totalUsagePercent >= 0.0 && cpu.totalUsagePercent <= 100.0)
        #expect(cpu.idlePercent >= 0.0 && cpu.idlePercent <= 100.0)

        // On a running Mac, top hogs must be discovered
        #expect(!cpu.topHogs.isEmpty)
        for hog in cpu.topHogs {
            #expect(hog.pid > 0)
            #expect(!hog.name.isEmpty)
            #expect(hog.cpuPercent >= 0.0)
            #expect(hog.memoryBytes >= 0)
        }
    }

    @Test("HW-04: Memory telemetry measures physical RAM and memory pressure level")
    func testMemoryTelemetry() {
        let service = HardwareTelemetryService()
        let mem = service.readMemoryTelemetry()

        #expect(mem.totalBytes > 0)
        #expect(mem.usedBytes > 0)
        #expect(mem.usedPercent > 0.0 && mem.usedPercent <= 100.0)
        #expect(mem.pressureLevel == .normal || mem.pressureLevel == .warning || mem.pressureLevel == .critical)
    }

    @Test("HW-05: Process output parser correctly distinguishes active and zombie processes")
    func testProcessOutputParsing() {
        let service = HardwareTelemetryService()
        let sampleOutput = """
         1234     1 R     45.2  2.1  250000 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
         5678  1234 Z      0.0  0.0       0 (defunct_worker)
          888     1 S      8.5  1.2  120000 WindowServer
        """

        let (hogs, zombies) = service.parseProcessOutput(sampleOutput, topLimit: 5)

        #expect(hogs.count == 2)
        #expect(hogs[0].pid == 1234)
        #expect(hogs[0].name == "Google Chrome")
        #expect(hogs[0].cpuPercent == 45.2)
        #expect(hogs[0].isZombie == false)

        #expect(zombies.count == 1)
        #expect(zombies[0].pid == 5678)
        #expect(zombies[0].isZombie == true)
    }
}
