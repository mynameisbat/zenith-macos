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
}
