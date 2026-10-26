import Foundation
import IOKit.ps
import Combine

/// Real-time power source and battery health monitor providing instant
/// Dynamic Island alerts for MagSafe / USB-C charging events and low battery warnings.
@MainActor
public final class PowerSourceMonitorService: ObservableObject {
    public static let shared = PowerSourceMonitorService()

    @Published public var lastKnownBattery: BatteryTelemetry?
    @Published public var isMonitoring: Bool = false

    private var runLoopSource: CFRunLoopSource?
    private var lastPluggedIn: Bool?
    private var lastLowBatteryAlertTime: Date?
    private var lastFullBatteryAlertTime: Date?
    private var knownBluetoothDeviceNames = Set<String>()

    public init() {}

    /// Starts native OS-level power source monitoring via IOKit run loop notifications.
    public func startMonitoring() {
        guard !isMonitoring else { return }
        self.isMonitoring = true

        // Capture initial battery state
        let initial = HardwareTelemetryService.shared.readBatteryTelemetry()
        self.lastKnownBattery = initial
        self.lastPluggedIn = initial.isPluggedIn

        // Capture initial connected Bluetooth accessories
        let initialDevices = HardwareTelemetryService.shared.readBluetoothPeripherals()
        self.knownBluetoothDeviceNames = Set(initialDevices.map { $0.name })

        // Register IOKit notification callback without polling
        let source = IOPSNotificationCreateRunLoopSource({ _ in
            Task { @MainActor in
                PowerSourceMonitorService.shared.evaluatePowerSourceChange()
            }
        }, nil)?.takeRetainedValue()

        if let source = source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            self.runLoopSource = source
        }
    }

    /// Stops monitoring and unregisters run loop source.
    public func stopMonitoring() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            self.runLoopSource = nil
        }
        self.isMonitoring = false
    }

    /// Evaluates power source state change and triggers relevant Dynamic Island HUD alerts.
    public func evaluatePowerSourceChange() {
        let current = HardwareTelemetryService.shared.readBatteryTelemetry()
        guard current.hasBattery else { return }

        let prevPlugged = lastPluggedIn
        self.lastPluggedIn = current.isPluggedIn
        self.lastKnownBattery = current

        // 1. MagSafe / USB-C Plugged In Event
        if prevPlugged == false && current.isPluggedIn {
            let wattStr = (current.wattage != nil && current.wattage! > 0) ? "\(Int(current.wattage!))W Charger" : "Power Connected"
            ZenithIslandState.shared.triggerAlert(
                icon: "bolt.fill",
                title: "Charging • \(current.percentage)%",
                subtitle: wattStr,
                duration: 2.8
            )
            return
        }

        // 2. Unplugged / Running on Battery Event
        if prevPlugged == true && !current.isPluggedIn {
            let timeStr: String
            if let mins = current.timeRemainingMinutes, mins > 0 {
                timeStr = "\(mins / 60)h \(mins % 60)m Remaining"
            } else {
                timeStr = "Running on Battery"
            }
            ZenithIslandState.shared.triggerAlert(
                icon: "bolt.slash.fill",
                title: "On Battery • \(current.percentage)%",
                subtitle: timeStr,
                duration: 2.4
            )
            return
        }

        // 3. Low Battery Warning (<= 20% and unplugged)
        if !current.isPluggedIn && current.percentage <= 20 {
            let canAlert: Bool = {
                guard let last = lastLowBatteryAlertTime else { return true }
                return Date().timeIntervalSince(last) > 300 // Alert at most once every 5 minutes
            }()
            if canAlert {
                self.lastLowBatteryAlertTime = Date()
                ZenithIslandState.shared.triggerAlert(
                    icon: "battery.25",
                    title: "Low Battery (\(current.percentage)%)",
                    subtitle: "Connect charger soon",
                    duration: 3.5
                )
            }
        }

        // 4. Battery Charged (100% or 80% optimized charging threshold)
        if current.isPluggedIn && (current.percentage == 100 || current.percentage == 80) {
            let canAlert: Bool = {
                guard let last = lastFullBatteryAlertTime else { return true }
                return Date().timeIntervalSince(last) > 1800 // Alert at most once every 30 minutes
            }()
            if canAlert {
                self.lastFullBatteryAlertTime = Date()
                let subtitle: String
                if let health = current.maximumCapacityPercent {
                    subtitle = "Health: \(health)% Maximum Capacity"
                } else {
                    subtitle = "Optimal charge reached"
                }
                ZenithIslandState.shared.triggerAlert(
                    icon: "battery.100.bolt",
                    title: "Battery Charged (\(current.percentage)%)",
                    subtitle: subtitle,
                    duration: 3.0
                )
            }
        }

        // 5. Check for newly connected Bluetooth accessories
        let devices = HardwareTelemetryService.shared.readBluetoothPeripherals()
        for device in devices {
            if !knownBluetoothDeviceNames.contains(device.name) {
                knownBluetoothDeviceNames.insert(device.name)
                ZenithIslandState.shared.triggerAlert(
                    icon: device.icon,
                    title: "\(device.name) (\(device.batteryPercent)%)",
                    subtitle: "Connected Accessory",
                    duration: 2.5
                )
            }
        }
    }
}
