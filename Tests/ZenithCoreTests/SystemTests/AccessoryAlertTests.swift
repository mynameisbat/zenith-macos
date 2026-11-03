import Testing
import Foundation
@testable import ZenithCore

final class AccessoryFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var _devices: [BluetoothDeviceTelemetry]

    init(_ devices: [BluetoothDeviceTelemetry] = []) { _devices = devices }

    var devices: [BluetoothDeviceTelemetry] {
        get { lock.withLock { _devices } }
        set { lock.withLock { _devices = newValue } }
    }

    static let keyboard = BluetoothDeviceTelemetry(name: "Magic Keyboard", batteryPercent: 80)
    static let mouse = BluetoothDeviceTelemetry(name: "Magic Mouse", batteryPercent: 55)
}

@Suite("Bluetooth Accessory Alert Suite")
struct AccessoryAlertTests {

    @Test("ACC-01: A newly connected accessory is announced once, and again each time it comes back")
    @MainActor
    func testAnnouncesNewAccessories() {
        let fixture = AccessoryFixture([AccessoryFixture.keyboard])
        let island = ZenithIslandState()
        let monitor = PowerSourceMonitorService(islandState: island, bluetoothProvider: { fixture.devices })
        monitor.startMonitoring()                    // what is already connected is learned silently
        defer { monitor.stopMonitoring() }

        monitor.evaluateBluetoothAccessories()
        #expect(island.activeAlert == nil)

        fixture.devices = [AccessoryFixture.keyboard, AccessoryFixture.mouse]
        monitor.evaluateBluetoothAccessories()
        let announced = island.activeAlert
        #expect(announced?.title == "Magic Mouse (55%)")
        #expect(announced?.subtitle == "Connected Accessory")

        monitor.evaluateBluetoothAccessories()
        #expect(island.activeAlert?.id == announced?.id)             // not announced twice

        fixture.devices = [AccessoryFixture.keyboard]                // the mouse goes away…
        monitor.evaluateBluetoothAccessories()
        fixture.devices = [AccessoryFixture.keyboard, AccessoryFixture.mouse]   // …and returns
        monitor.evaluateBluetoothAccessories()
        #expect(island.activeAlert?.id != announced?.id)
        #expect(island.activeAlert?.title == "Magic Mouse (55%)")
    }

    @Test("ACC-02: A registry change reads the accessories shortly afterwards, without any power event")
    @MainActor
    func testRegistryChangeTriggersEvaluation() async throws {
        let fixture = AccessoryFixture()
        let island = ZenithIslandState()
        let monitor = PowerSourceMonitorService(islandState: island, bluetoothProvider: { fixture.devices }, accessorySettleDelay: 0.05)
        monitor.startMonitoring()
        defer { monitor.stopMonitoring() }

        fixture.devices = [AccessoryFixture.mouse]
        monitor.accessoryRegistryChanged()
        for _ in 0..<40 where island.activeAlert == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(island.activeAlert?.title == "Magic Mouse (55%)")
    }

    @Test("ACC-03: Monitoring can be started and stopped repeatedly without leaking registry subscriptions")
    @MainActor
    func testStartStopIsRepeatable() {
        let monitor = PowerSourceMonitorService(islandState: ZenithIslandState(), bluetoothProvider: { [] })
        for _ in 0..<20 {
            monitor.startMonitoring()
            monitor.stopMonitoring()
        }
        #expect(!monitor.isMonitoring)
    }
}
