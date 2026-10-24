import Foundation
import IOKit
import IOKit.ps

/// Battery status and health metrics.
public struct BatteryTelemetry: Sendable, Equatable {
    public let hasBattery: Bool
    public let percentage: Int
    public let isCharging: Bool
    public let isPluggedIn: Bool
    public let cycleCount: Int?
    public let condition: String

    public init(
        hasBattery: Bool = false,
        percentage: Int = 100,
        isCharging: Bool = false,
        isPluggedIn: Bool = true,
        cycleCount: Int? = nil,
        condition: String = "Normal"
    ) {
        self.hasBattery = hasBattery
        self.percentage = percentage
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
        self.cycleCount = cycleCount
        self.condition = condition
    }
}

/// Primary storage volume telemetry.
public struct DiskTelemetry: Sendable, Equatable {
    public let volumeName: String
    public let totalBytes: Int64
    public let freeBytes: Int64
    public let usedBytes: Int64
    public let usedPercent: Double

    public init(
        volumeName: String = "Macintosh HD",
        totalBytes: Int64 = 0,
        freeBytes: Int64 = 0,
        usedBytes: Int64 = 0,
        usedPercent: Double = 0.0
    ) {
        self.volumeName = volumeName
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.usedBytes = usedBytes
        self.usedPercent = usedPercent
    }
}

/// Connected Bluetooth peripheral battery telemetry.
public struct BluetoothDeviceTelemetry: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let batteryPercent: Int
    public let deviceType: String
    public let isConnected: Bool

    public init(
        id: String = UUID().uuidString,
        name: String,
        batteryPercent: Int,
        deviceType: String = "accessory",
        isConnected: Bool = true
    ) {
        self.id = id
        self.name = name
        self.batteryPercent = batteryPercent
        self.deviceType = deviceType
        self.isConnected = isConnected
    }

    public var icon: String {
        let lower = name.lowercased()
        if lower.contains("airpod") || lower.contains("headphone") || lower.contains("wh-") || lower.contains("buds") {
            return "headphones"
        } else if lower.contains("mouse") {
            return "mouse.fill"
        } else if lower.contains("keyboard") || lower.contains("keychron") {
            return "keyboard.fill"
        } else if lower.contains("trackpad") {
            return "hand.draw.fill"
        }
        return "wave.3.right.circle.fill"
    }
}

/// Consolidated snapshot of Mac hardware status.
public struct HardwareSnapshot: Sendable, Equatable {
    public let battery: BatteryTelemetry
    public let disk: DiskTelemetry
    public let bluetoothDevices: [BluetoothDeviceTelemetry]
    public let timestamp: Date

    public init(
        battery: BatteryTelemetry,
        disk: DiskTelemetry,
        bluetoothDevices: [BluetoothDeviceTelemetry] = [],
        timestamp: Date = Date()
    ) {
        self.battery = battery
        self.disk = disk
        self.bluetoothDevices = bluetoothDevices
        self.timestamp = timestamp
    }
}

/// Service providing real-time hardware telemetry: Battery health, SSD capacity,
/// and connected Bluetooth device levels via direct Darwin kernel and IOKit APIs.
public final class HardwareTelemetryService: @unchecked Sendable {
    public static let shared = HardwareTelemetryService()

    public init() {}

    /// Fetches a live snapshot of hardware metrics.
    public func fetchSnapshot() -> HardwareSnapshot {
        let battery = readBatteryTelemetry()
        let disk = readDiskTelemetry()
        let btDevices = readBluetoothPeripherals()
        return HardwareSnapshot(
            battery: battery,
            disk: disk,
            bluetoothDevices: btDevices,
            timestamp: Date()
        )
    }

    // MARK: - Battery Telemetry

    public func readBatteryTelemetry() -> BatteryTelemetry {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              !sources.isEmpty else {
            // Desktop Mac (e.g. Mac mini, Mac Studio, Mac Pro) with no battery
            return BatteryTelemetry(hasBattery: false, percentage: 100, isCharging: false, isPluggedIn: true, cycleCount: nil, condition: "N/A")
        }

        var percent = 100
        var isCharging = false
        var isPlugged = true
        var condition = "Normal"

        for s in sources {
            if let desc = IOPSGetPowerSourceDescription(snapshot, s)?.takeUnretainedValue() as? [String: Any] {
                if let cur = desc[kIOPSCurrentCapacityKey] as? Int {
                    percent = cur
                }
                if let charging = desc[kIOPSIsChargingKey] as? Bool {
                    isCharging = charging
                } else if let chargingInt = desc[kIOPSIsChargingKey] as? Int {
                    isCharging = (chargingInt != 0)
                }
                if let state = desc[kIOPSPowerSourceStateKey] as? String {
                    isPlugged = (state == kIOPSACPowerValue)
                }
                if let cond = desc[kIOPSBatteryHealthKey] as? String {
                    condition = cond
                }
            }
        }

        // Query IOKit AppleSmartBattery for CycleCount
        var cycleCount: Int? = nil
        var iterator = io_iterator_t()
        let matching = IOServiceMatching("AppleSmartBattery")
        if IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS {
            let service = IOIteratorNext(iterator)
            if service != 0 {
                var props: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                   let dict = props?.takeRetainedValue() as? [String: Any] {
                    if let cycles = dict["CycleCount"] as? Int {
                        cycleCount = cycles
                    }
                }
                IOObjectRelease(service)
            }
            IOObjectRelease(iterator)
        }

        return BatteryTelemetry(
            hasBattery: true,
            percentage: percent,
            isCharging: isCharging,
            isPluggedIn: isPlugged,
            cycleCount: cycleCount,
            condition: condition
        )
    }

    // MARK: - Disk Telemetry

    public func readDiskTelemetry(rootPath: String = "/") -> DiskTelemetry {
        let url = URL(fileURLWithPath: rootPath)
        guard let vals = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeNameKey
        ]) else {
            return DiskTelemetry()
        }

        let total = Int64(vals.volumeTotalCapacity ?? 0)
        let free = Int64(vals.volumeAvailableCapacityForImportantUsage ?? 0)
        let used = max(0, total - free)
        let percent = total > 0 ? (Double(used) / Double(total)) * 100.0 : 0.0
        let name = vals.volumeName ?? "Macintosh HD"

        return DiskTelemetry(
            volumeName: name,
            totalBytes: total,
            freeBytes: free,
            usedBytes: used,
            usedPercent: percent
        )
    }

    // MARK: - Bluetooth Peripherals

    public func readBluetoothPeripherals() -> [BluetoothDeviceTelemetry] {
        var devices: [BluetoothDeviceTelemetry] = []

        var iterator = io_iterator_t()
        // Query AppleDeviceManagementHIDEventService for connected accessories
        let matching = IOServiceMatching("AppleDeviceManagementHIDEventService")
        if IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS {
            var service = IOIteratorNext(iterator)
            while service != 0 {
                var props: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                   let dict = props?.takeRetainedValue() as? [String: Any] {
                    if let name = dict["Product"] as? String,
                       let battery = dict["BatteryPercent"] as? Int {
                        devices.append(BluetoothDeviceTelemetry(
                            name: name,
                            batteryPercent: battery,
                            isConnected: true
                        ))
                    }
                }
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            IOObjectRelease(iterator)
        }

        return devices
    }
}
