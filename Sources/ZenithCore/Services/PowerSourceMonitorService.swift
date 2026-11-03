import Foundation
import IOKit
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

    private let islandState: ZenithIslandState
    private let bluetoothProvider: @Sendable () -> [BluetoothDeviceTelemetry]

    /// Wakes the service when an accessory's HID service appears or disappears in the I/O Registry.
    private var accessoryNotificationPort: IONotificationPortRef?
    private var accessoryIterators: [io_iterator_t] = []

    /// How long to wait after an accessory shows up before reading it: the battery level is filled in a moment later.
    private let accessorySettleDelay: TimeInterval

    /// - Parameters:
    ///   - islandState: Where alerts are shown.
    ///   - bluetoothProvider: Lists the connected accessories; tests substitute a stand-in.
    ///   - accessorySettleDelay: Seconds to wait after the registry reports a change before reading the accessories.
    public init(
        islandState: ZenithIslandState = .shared,
        bluetoothProvider: @escaping @Sendable () -> [BluetoothDeviceTelemetry] = {
            HardwareTelemetryService.shared.readBluetoothPeripherals()
        },
        accessorySettleDelay: TimeInterval = 1.5
    ) {
        self.islandState = islandState
        self.bluetoothProvider = bluetoothProvider
        self.accessorySettleDelay = accessorySettleDelay
    }

    /// Starts native OS-level power source monitoring via IOKit run loop notifications.
    public func startMonitoring() {
        guard !isMonitoring else { return }
        self.isMonitoring = true

        // Capture initial battery state
        let initial = HardwareTelemetryService.shared.readBatteryTelemetry()
        self.lastKnownBattery = initial
        self.lastPluggedIn = initial.isPluggedIn

        // Capture initial connected Bluetooth accessories
        self.knownBluetoothDeviceNames = Set(bluetoothProvider().map { $0.name })

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

        startAccessoryNotifications()
    }

    /// Stops monitoring and unregisters run loop source.
    public func stopMonitoring() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            self.runLoopSource = nil
        }
        stopAccessoryNotifications()
        self.isMonitoring = false
    }

    // MARK: - Bluetooth Accessories

    /// Announces accessories that were not connected at the last check.
    ///
    /// This used to run only as part of a power-source change and was skipped by two early returns, so an accessory
    /// connecting on its own was usually never announced (and never at all on a Mac without a battery).
    public func evaluateBluetoothAccessories() {
        let devices = bluetoothProvider()
        for device in devices where !knownBluetoothDeviceNames.contains(device.name) {
            islandState.triggerAlert(
                icon: device.icon,
                title: "\(device.name) (\(device.batteryPercent)%)",
                subtitle: "Connected Accessory",
                duration: 2.5
            )
        }
        // Remember only what is connected now, so an accessory that left is announced again when it returns.
        knownBluetoothDeviceNames = Set(devices.map { $0.name })
    }

    /// Called when the I/O Registry reports a change among accessory HID services.
    func accessoryRegistryChanged() {
        let delay = UInt64(accessorySettleDelay * 1_000_000_000)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            self?.evaluateBluetoothAccessories()
        }
    }

    /// Subscribes to accessories appearing and disappearing, so no polling is needed.
    private func startAccessoryNotifications() {
        guard accessoryNotificationPort == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)

        let callback: IOServiceMatchingCallback = { _, iterator in
            // Walking the iterator is what re-arms the notification.
            while case let service = IOIteratorNext(iterator), service != 0 {
                IOObjectRelease(service)
            }
            Task { @MainActor in
                PowerSourceMonitorService.shared.accessoryRegistryChanged()
            }
        }

        var iterators: [io_iterator_t] = []
        for notificationType in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            let status = IOServiceAddMatchingNotification(
                port,
                notificationType,
                IOServiceMatching("AppleDeviceManagementHIDEventService"),
                callback,
                nil,
                &iterator
            )
            guard status == KERN_SUCCESS else { continue }
            while case let service = IOIteratorNext(iterator), service != 0 {   // the initial matches arm it
                IOObjectRelease(service)
            }
            iterators.append(iterator)
        }

        guard !iterators.isEmpty else {
            IONotificationPortDestroy(port)
            return
        }
        accessoryNotificationPort = port
        accessoryIterators = iterators
    }

    private func stopAccessoryNotifications() {
        for iterator in accessoryIterators {
            IOObjectRelease(iterator)
        }
        accessoryIterators.removeAll()
        if let port = accessoryNotificationPort {
            IONotificationPortDestroy(port)
            accessoryNotificationPort = nil
        }
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
            islandState.triggerAlert(
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
            islandState.triggerAlert(
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
                islandState.triggerAlert(
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
                islandState.triggerAlert(
                    icon: "battery.100.bolt",
                    title: "Battery Charged (\(current.percentage)%)",
                    subtitle: subtitle,
                    duration: 3.0
                )
            }
        }
    }
}
