import Foundation
import IOKit
import IOKit.ps
import Darwin

/// Individual process resource footprint.
public struct ProcessTelemetry: Identifiable, Sendable, Equatable {
    public let id: Int // pid
    public let pid: Int
    public let ppid: Int
    public let name: String
    public let command: String
    public let cpuPercent: Double
    public let memoryPercent: Double
    public let memoryBytes: Int64
    public let state: String
    public let isZombie: Bool

    public init(
        pid: Int,
        ppid: Int = 1,
        name: String,
        command: String = "",
        cpuPercent: Double = 0.0,
        memoryPercent: Double = 0.0,
        memoryBytes: Int64 = 0,
        state: String = "S",
        isZombie: Bool = false
    ) {
        self.id = pid
        self.pid = pid
        self.ppid = ppid
        self.name = name
        self.command = command
        self.cpuPercent = cpuPercent
        self.memoryPercent = memoryPercent
        self.memoryBytes = memoryBytes
        self.state = state
        self.isZombie = isZombie
    }
}

/// CPU utilization and top resource consumers.
public struct CPUTelemetry: Sendable, Equatable {
    public let totalUsagePercent: Double
    public let userPercent: Double
    public let systemPercent: Double
    public let idlePercent: Double
    public let coreCount: Int
    public let topHogs: [ProcessTelemetry]
    public let zombieProcesses: [ProcessTelemetry]

    public init(
        totalUsagePercent: Double = 0.0,
        userPercent: Double = 0.0,
        systemPercent: Double = 0.0,
        idlePercent: Double = 100.0,
        coreCount: Int = ProcessInfo.processInfo.activeProcessorCount,
        topHogs: [ProcessTelemetry] = [],
        zombieProcesses: [ProcessTelemetry] = []
    ) {
        self.totalUsagePercent = totalUsagePercent
        self.userPercent = userPercent
        self.systemPercent = systemPercent
        self.idlePercent = idlePercent
        self.coreCount = coreCount
        self.topHogs = topHogs
        self.zombieProcesses = zombieProcesses
    }
}

/// macOS Darwin VM memory pressure level.
public enum MemoryPressureLevel: String, Sendable, Equatable {
    case normal = "Normal"
    case warning = "Warning"
    case critical = "Critical"
}

/// RAM utilization and pressure metrics.
public struct MemoryTelemetry: Sendable, Equatable {
    public let totalBytes: Int64
    public let usedBytes: Int64
    public let freeBytes: Int64
    public let activeBytes: Int64
    public let wiredBytes: Int64
    public let compressedBytes: Int64
    public let usedPercent: Double
    public let pressureLevel: MemoryPressureLevel

    public init(
        totalBytes: Int64 = 0,
        usedBytes: Int64 = 0,
        freeBytes: Int64 = 0,
        activeBytes: Int64 = 0,
        wiredBytes: Int64 = 0,
        compressedBytes: Int64 = 0,
        usedPercent: Double = 0.0,
        pressureLevel: MemoryPressureLevel = .normal
    ) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.freeBytes = freeBytes
        self.activeBytes = activeBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.usedPercent = usedPercent
        self.pressureLevel = pressureLevel
    }
}

/// Battery status, wattage, and health metrics.
public struct BatteryTelemetry: Sendable, Equatable {
    public let hasBattery: Bool
    public let percentage: Int
    public let isCharging: Bool
    public let isPluggedIn: Bool
    public let cycleCount: Int?
    public let condition: String
    public let wattage: Double?
    public let healthPercent: Int?
    public let timeRemainingMinutes: Int?

    public init(
        hasBattery: Bool = false,
        percentage: Int = 100,
        isCharging: Bool = false,
        isPluggedIn: Bool = true,
        cycleCount: Int? = nil,
        condition: String = "Normal",
        wattage: Double? = nil,
        healthPercent: Int? = nil,
        timeRemainingMinutes: Int? = nil
    ) {
        self.hasBattery = hasBattery
        self.percentage = percentage
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
        self.cycleCount = cycleCount
        self.condition = condition
        self.wattage = wattage
        self.healthPercent = healthPercent
        self.timeRemainingMinutes = timeRemainingMinutes
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
    public let cpu: CPUTelemetry
    public let memory: MemoryTelemetry
    public let bluetoothDevices: [BluetoothDeviceTelemetry]
    public let thermalState: String
    public let timestamp: Date

    public init(
        battery: BatteryTelemetry,
        disk: DiskTelemetry,
        bluetoothDevices: [BluetoothDeviceTelemetry] = [],
        timestamp: Date = Date()
    ) {
        self.battery = battery
        self.disk = disk
        self.cpu = CPUTelemetry()
        self.memory = MemoryTelemetry()
        self.bluetoothDevices = bluetoothDevices
        self.thermalState = "Nominal"
        self.timestamp = timestamp
    }

    public init(
        battery: BatteryTelemetry,
        disk: DiskTelemetry,
        cpu: CPUTelemetry,
        memory: MemoryTelemetry,
        bluetoothDevices: [BluetoothDeviceTelemetry] = [],
        thermalState: String = "Nominal",
        timestamp: Date = Date()
    ) {
        self.battery = battery
        self.disk = disk
        self.cpu = cpu
        self.memory = memory
        self.bluetoothDevices = bluetoothDevices
        self.thermalState = thermalState
        self.timestamp = timestamp
    }
}

/// Service providing real-time hardware telemetry: CPU load & Top Hogs, RAM & Pressure,
/// Battery health & Wattage, SSD capacity, and connected Bluetooth device levels.
public final class HardwareTelemetryService: @unchecked Sendable {
    public static let shared = HardwareTelemetryService()

    public static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var previousCPUTicks: host_cpu_load_info?

    public init() {}

    /// Fetches a live snapshot of hardware metrics.
    public func fetchSnapshot() -> HardwareSnapshot {
        let battery = readBatteryTelemetry()
        let disk = readDiskTelemetry()
        let cpu = readCPUTelemetry()
        let memory = readMemoryTelemetry()
        let btDevices = readBluetoothPeripherals()
        let thermal = readThermalState()

        return HardwareSnapshot(
            battery: battery,
            disk: disk,
            cpu: cpu,
            memory: memory,
            bluetoothDevices: btDevices,
            thermalState: thermal,
            timestamp: Date()
        )
    }

    // MARK: - CPU & Process Telemetry

    public func readCPUTelemetry(topLimit: Int = 5) -> CPUTelemetry {
        let (totalPercent, userPercent, sysPercent, idlePercent) = sampleCPULoad()
        let (hogs, zombies) = sampleProcesses(topLimit: topLimit)

        return CPUTelemetry(
            totalUsagePercent: totalPercent,
            userPercent: userPercent,
            systemPercent: sysPercent,
            idlePercent: idlePercent,
            coreCount: ProcessInfo.processInfo.activeProcessorCount,
            topHogs: hogs,
            zombieProcesses: zombies
        )
    }

    private func sampleCPULoad() -> (total: Double, user: Double, system: Double, idle: Double) {
        var cpuInfo = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)

        let kerr = withUnsafeMutablePointer(to: &cpuInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }

        guard kerr == KERN_SUCCESS else {
            return (0.0, 0.0, 0.0, 100.0)
        }

        guard let prev = previousCPUTicks else {
            previousCPUTicks = cpuInfo
            return (0.0, 0.0, 0.0, 100.0)
        }

        let userTicks = Double(cpuInfo.cpu_ticks.0 - prev.cpu_ticks.0)
        let sysTicks = Double(cpuInfo.cpu_ticks.1 - prev.cpu_ticks.1)
        let idleTicks = Double(cpuInfo.cpu_ticks.2 - prev.cpu_ticks.2)
        let niceTicks = Double(cpuInfo.cpu_ticks.3 - prev.cpu_ticks.3)

        previousCPUTicks = cpuInfo

        let totalTicks = userTicks + sysTicks + idleTicks + niceTicks
        guard totalTicks > 0 else {
            return (0.0, 0.0, 0.0, 100.0)
        }

        let userPct = ((userTicks + niceTicks) / totalTicks) * 100.0
        let sysPct = (sysTicks / totalTicks) * 100.0
        let totalPct = userPct + sysPct
        let idlePct = (idleTicks / totalTicks) * 100.0

        return (
            min(100.0, max(0.0, totalPct)),
            min(100.0, max(0.0, userPct)),
            min(100.0, max(0.0, sysPct)),
            min(100.0, max(0.0, idlePct))
        )
    }

    public func sampleProcesses(topLimit: Int = 5) -> (topHogs: [ProcessTelemetry], zombies: [ProcessTelemetry]) {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Aceo", "pid=,ppid=,state=,pcpu=,pmem=,rss=,comm=", "-r"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else {
                return ([], [])
            }
            return parseProcessOutput(output, topLimit: topLimit)
        } catch {
            return ([], [])
        }
    }

    public func parseProcessOutput(_ output: String, topLimit: Int = 5) -> (topHogs: [ProcessTelemetry], zombies: [ProcessTelemetry]) {
        var hogs: [ProcessTelemetry] = []
        var zombies: [ProcessTelemetry] = []

        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 7 else { continue }

            guard let pid = Int(parts[0]),
                  let ppid = Int(parts[1]),
                  let cpu = Double(parts[3]),
                  let mem = Double(parts[4]),
                  let rssKB = Int64(parts[5]) else {
                continue
            }

            let state = String(parts[2])
            let commandParts = parts[6...]
            let rawCommand = commandParts.joined(separator: " ")
            let cleanName = (rawCommand as NSString).lastPathComponent

            let isZombie = state.contains("Z")

            let proc = ProcessTelemetry(
                pid: pid,
                ppid: ppid,
                name: cleanName,
                command: rawCommand,
                cpuPercent: cpu,
                memoryPercent: mem,
                memoryBytes: rssKB * 1024,
                state: state,
                isZombie: isZombie
            )

            if isZombie {
                zombies.append(proc)
            }

            if hogs.count < topLimit && !isZombie {
                hogs.append(proc)
            }
        }

        return (hogs, zombies)
    }

    /// Terminates a process by PID.
    @discardableResult
    public func killProcess(pid: Int, force: Bool = false) -> Bool {
        guard pid > 1 else { return false } // Guard against init / kernel
        let sig = force ? SIGKILL : SIGTERM
        return kill(pid_t(pid), sig) == 0
    }

    // MARK: - Memory Telemetry

    public func readMemoryTelemetry() -> MemoryTelemetry {
        let total = Int64(ProcessInfo.processInfo.physicalMemory)

        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)

        let kerr = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        let pageSize = Int64(getpagesize())

        var active: Int64 = 0
        var wired: Int64 = 0
        var compressed: Int64 = 0

        if kerr == KERN_SUCCESS {
            active = Int64(vmStats.active_count) * pageSize
            wired = Int64(vmStats.wire_count) * pageSize
            compressed = Int64(vmStats.compressor_page_count) * pageSize
        }

        let used = max(0, min(total, active + wired + compressed))
        let usedPercent = total > 0 ? (Double(used) / Double(total)) * 100.0 : 0.0

        var pressureVal: Int32 = 0
        var pSize = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &pressureVal, &pSize, nil, 0)

        let level: MemoryPressureLevel
        switch pressureVal {
        case 2: level = .warning
        case 4: level = .critical
        default: level = .normal
        }

        return MemoryTelemetry(
            totalBytes: total,
            usedBytes: used,
            freeBytes: max(0, total - used),
            activeBytes: active,
            wiredBytes: wired,
            compressedBytes: compressed,
            usedPercent: usedPercent,
            pressureLevel: level
        )
    }

    // MARK: - Thermal State

    public func readThermalState() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Nominal"
        }
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
        var timeRemaining: Int? = nil

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
                if let rem = desc[kIOPSTimeToEmptyKey] as? Int, rem > 0 {
                    timeRemaining = rem
                }
            }
        }

        // Query IOKit AppleSmartBattery for CycleCount, Voltage, Amperage, and Health
        var cycleCount: Int? = nil
        var wattage: Double? = nil
        var healthPct: Int? = nil

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
                    if let volt = dict["Voltage"] as? Int {
                        // Voltage is in mV, InstantAmperage or Amperage is in mA
                        let amp = (dict["InstantAmperage"] as? Int) ?? (dict["Amperage"] as? Int) ?? 0
                        let signedAmp = Int32(truncatingIfNeeded: amp)
                        let watts = abs(Double(signedAmp) * Double(volt)) / 1_000_000.0
                        if watts > 0 && watts < 200 {
                            wattage = (watts * 10).rounded() / 10
                        }
                    }
                    if let bData = dict["BatteryData"] as? [String: Any],
                       let nominal = bData["NominalChargeCapacity"] as? Int,
                       let design = bData["DesignCapacity"] as? Int, design > 0 {
                        healthPct = min(100, max(0, Int((Double(nominal) / Double(design)) * 100.0)))
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
            condition: condition,
            wattage: wattage,
            healthPercent: healthPct,
            timeRemainingMinutes: timeRemaining
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
