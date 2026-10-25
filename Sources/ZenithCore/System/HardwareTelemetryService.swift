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

    /// Maximum battery capacity percentage (Health), matching macOS System Settings.
    public var maximumCapacityPercent: Int? {
        healthPercent
    }

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
        battery: BatteryTelemetry = BatteryTelemetry(),
        disk: DiskTelemetry = DiskTelemetry(),
        cpu: CPUTelemetry = CPUTelemetry(),
        memory: MemoryTelemetry = MemoryTelemetry(),
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
    private let processCacheLock = NSLock()
    private var cachedProcesses: (topHogs: [ProcessTelemetry], zombies: [ProcessTelemetry])?
    private var lastProcessSampleTime: Date?

    public init() {}

    /// Fetches a live snapshot of hardware metrics.
    public func fetchSnapshot() -> HardwareSnapshot {
        let battery = readBatteryTelemetry()
        let disk = readDiskTelemetry()
        let cpu = readCPUTelemetry(topLimit: 15)
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

    public func sampleProcesses(topLimit: Int = 5, filterSafeOnly: Bool = true) -> (topHogs: [ProcessTelemetry], zombies: [ProcessTelemetry]) {
        processCacheLock.lock()
        if let cached = cachedProcesses,
           let lastTime = lastProcessSampleTime,
           Date().timeIntervalSince(lastTime) < 1.5 {
            let hogs = Array(cached.topHogs.prefix(topLimit))
            let zombies = cached.zombies
            processCacheLock.unlock()
            return (hogs, zombies)
        }
        processCacheLock.unlock()

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
            let (hogs, zombies) = parseProcessOutput(output, topLimit: max(25, topLimit), filterSafeOnly: filterSafeOnly)
            processCacheLock.lock()
            self.cachedProcesses = (hogs, zombies)
            self.lastProcessSampleTime = Date()
            processCacheLock.unlock()
            return (Array(hogs.prefix(topLimit)), zombies)
        } catch {
            return ([], [])
        }
    }

    /// Invalidates cached process telemetry so subsequent queries fetch fresh data.
    public func invalidateProcessCache() {
        processCacheLock.lock()
        cachedProcesses = nil
        lastProcessSampleTime = nil
        processCacheLock.unlock()
    }

    /// Determines whether a process is a user-facing application or user-space tool
    /// that can be safely terminated without destabilizing the macOS operating system.
    public static func isSafeToKillProcess(pid: Int, command: String = "") -> Bool {
        if pid <= 1 || pid == ProcessInfo.processInfo.processIdentifier {
            return false
        }

        var pathBuffer = [UInt8](repeating: 0, count: 4096)
        let length = pathBuffer.withUnsafeMutableBufferPointer { ptr in
            proc_pidpath(pid_t(pid), ptr.baseAddress, UInt32(ptr.count))
        }
        let path: String
        if length > 0 {
            let slice = pathBuffer.prefix(Int(length))
            path = String(decoding: slice, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        } else {
            path = command.trimmingCharacters(in: .whitespaces)
        }

        // 1. Critical system directories that must never be terminated
        let systemPrefixes = [
            "/System/",
            "/usr/libexec/",
            "/usr/sbin/",
            "/sbin/",
            "/Library/Apple/",
            "/Library/SystemExtensions/"
        ]
        if systemPrefixes.contains(where: { path.hasPrefix($0) }) {
            return false
        }

        // 2. Blacklisted core Apple system services & UI daemons
        let coreSystemNames: Set<String> = [
            "windowserver", "loginwindow", "dock", "finder", "systemuiserver",
            "controlcenter", "spotlight", "notificationcenter", "windowmanager",
            "coreaudiod", "bluetoothd", "wifid", "logd", "fseventsd", "powerd",
            "tccd", "trustd", "opendirectoryd", "securityd", "diskarbitrationd",
            "amfid", "syslogd", "notifyd", "kernelmanagerd", "hidd", "locationd",
            "sharingd", "airportd", "clocksyncd", "biomesyncd", "chronod",
            "distnoted", "cfprefsd", "nsurlsessiond", "containermanagerd",
            "runningboardd", "diagnosticd", "symptomd", "symptomsd", "contextstored",
            "rapportd", "identityservicesd", "secd", "accountsd", "callservicesd",
            "imagent", "suggestd", "coreduetd", "vtdecoderxpcservice",
            "vtencoderxpcservice", "mtlcompilerservice", "xprotectd", "bird",
            "cloudd", "fileproviderd", "geod", "passd", "pkd", "revisiond",
            "quicklookd", "spindump", "sysdiagnose", "secinitd", "neagent",
            "appleeventsd", "corespotlightd", "keychainsharingd", "usernoted",
            "viewbridgeauxiliary", "zenith", "goldengate"
        ]
        let nameLower = (path as NSString).lastPathComponent.lowercased()
        if coreSystemNames.contains(nameLower) || nameLower.hasPrefix("com.apple.") {
            return false
        }

        // 3. Positive verification: User applications, developer tools, or Homebrew binaries
        let userAllowedPrefixes = [
            "/Applications/",
            "/Users/",
            "/opt/homebrew/",
            "/usr/local/"
        ]
        if userAllowedPrefixes.contains(where: { path.hasPrefix($0) }) {
            return true
        }

        let safeDeveloperTools: Set<String> = [
            "node", "python", "python3", "ruby", "java", "cargo", "rustc", "go",
            "docker", "containerd", "language_server", "esbuild", "git", "ffmpeg",
            "dotnet", "ugrep", "rg", "npm", "yarn", "pnpm", "vite"
        ]
        if safeDeveloperTools.contains(nameLower) {
            return true
        }

        // Generic non-system executable not matching system keywords
        if !path.hasPrefix("/") && !nameLower.hasSuffix("d") && !nameLower.contains("system") && !nameLower.contains("apple") {
            return true
        }

        return false
    }

    public func parseProcessOutput(_ output: String, topLimit: Int = 5, filterSafeOnly: Bool = false) -> (topHogs: [ProcessTelemetry], zombies: [ProcessTelemetry]) {
        var activeProcs: [ProcessTelemetry] = []
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
            } else {
                if filterSafeOnly && !Self.isSafeToKillProcess(pid: pid, command: rawCommand) {
                    continue
                }
                activeProcs.append(proc)
            }
        }

        // Maintain top CPU hogs followed by heavy RAM consumers not already included
        var hogs: [ProcessTelemetry] = []
        var addedPIDs = Set<Int>()

        let topByCPU = activeProcs.sorted(by: { $0.cpuPercent > $1.cpuPercent })
        for proc in topByCPU {
            if hogs.count >= topLimit { break }
            hogs.append(proc)
            addedPIDs.insert(proc.pid)
        }

        let topByMem = activeProcs.sorted(by: { $0.memoryBytes > $1.memoryBytes })
        for proc in topByMem {
            if hogs.count >= topLimit { break }
            if !addedPIDs.contains(proc.pid) {
                hogs.append(proc)
                addedPIDs.insert(proc.pid)
            }
        }

        return (hogs, zombies)
    }

    /// Gracefully requests a process to terminate (SIGTERM).
    @discardableResult
    public func terminateProcess(pid: Int) -> Bool {
        invalidateProcessCache()
        return sendSignal(SIGTERM, toProcess: pid)
    }

    /// Forcefully terminates a process immediately (SIGKILL).
    @discardableResult
    public func forceKillProcess(pid: Int) -> Bool {
        invalidateProcessCache()
        return sendSignal(SIGKILL, toProcess: pid)
    }

    /// Terminates a process by PID with optional force flag (Clean Code F3 backwards-compatible facade).
    @discardableResult
    public func killProcess(pid: Int, force: Bool = false) -> Bool {
        force ? forceKillProcess(pid: pid) : terminateProcess(pid: pid)
    }

    private func sendSignal(_ signal: Int32, toProcess pid: Int) -> Bool {
        guard pid > 1 else { return false } // Guard against init / kernel
        return kill(pid_t(pid), signal) == 0
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

        // Query IOKit AppleSmartBatteryPack & AppleSmartBattery for CycleCount, Voltage, Amperage, and Maximum Capacity / Health
        var cycleCount: Int? = nil
        var wattage: Double? = nil
        var healthPct: Int? = nil

        // 1. Query AppleSmartBatteryPack first (Apple Silicon M1/M2/M3/M4 on macOS 12+) for precise Maximum Capacity
        var packIter = io_iterator_t()
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSmartBatteryPack"), &packIter) == KERN_SUCCESS {
            let packService = IOIteratorNext(packIter)
            if packService != 0 {
                var props: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(packService, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                   let dict = props?.takeRetainedValue() as? [String: Any],
                   let bData = dict["BatteryData"] as? [String: Any] {
                    let fcc = (bData["FccComp1"] as? Int) ?? (bData["NominalChargeCapacity"] as? Int) ?? (bData["FullChargeCapacity"] as? Int)
                    let design = bData["DesignCapacity"] as? Int
                    if let fcc = fcc, let design = design, design > 0 {
                        healthPct = min(100, max(0, Int((Double(fcc) / Double(design)) * 100.0)))
                    }
                }
                IOObjectRelease(packService)
            }
            IOObjectRelease(packIter)
        }

        // 2. Query AppleSmartBattery for CycleCount, Voltage, Amperage, and fallback Maximum Capacity
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
                    if healthPct == nil,
                       let bData = dict["BatteryData"] as? [String: Any] {
                        let fcc = (bData["NominalChargeCapacity"] as? Int) ?? (bData["FullChargeCapacity"] as? Int)
                        let design = bData["DesignCapacity"] as? Int
                        if let fcc = fcc, let design = design, design > 0 {
                            healthPct = min(100, max(0, Int((Double(fcc) / Double(design)) * 100.0)))
                        }
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
