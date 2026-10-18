import Darwin
import Foundation

/// Real-time macOS physical RAM telemetry sampled directly from Mach kernel VM statistics.
public struct SystemMemoryTelemetry: Sendable, Equatable {
    public let totalBytes: UInt64
    public let usedBytes: UInt64
    public let wiredBytes: UInt64
    public let activeBytes: UInt64
    public let inactiveBytes: UInt64
    public let compressedBytes: UInt64
    public let freeBytes: UInt64
    public let usedPercentage: Double

    public init(
        totalBytes: UInt64,
        usedBytes: UInt64,
        wiredBytes: UInt64,
        activeBytes: UInt64,
        inactiveBytes: UInt64,
        compressedBytes: UInt64,
        freeBytes: UInt64,
        usedPercentage: Double
    ) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.wiredBytes = wiredBytes
        self.activeBytes = activeBytes
        self.inactiveBytes = inactiveBytes
        self.compressedBytes = compressedBytes
        self.freeBytes = freeBytes
        self.usedPercentage = min(max(usedPercentage, 0.0), 1.0)
    }

    public var availableBytes: UInt64 {
        freeBytes + inactiveBytes
    }

    public var formattedTotal: String {
        SystemCleanerService.formatBytes(Int64(totalBytes))
    }

    public var formattedUsed: String {
        SystemCleanerService.formatBytes(Int64(usedBytes))
    }

    public var formattedAvailable: String {
        SystemCleanerService.formatBytes(Int64(availableBytes))
    }

    public var formattedFree: String {
        SystemCleanerService.formatBytes(Int64(freeBytes))
    }

    public var formattedPercentage: String {
        "\(Int(usedPercentage * 100))%"
    }

    /// Samples live physical RAM metrics from the Mach kernel host statistics.
    public static func current() -> SystemMemoryTelemetry {
        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let hostPort = mach_host_self()

        let kr = withUnsafeMutablePointer(to: &vmStats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(hostPort, HOST_VM_INFO64, intPtr, &count)
            }
        }

        var pageSize: vm_size_t = 0
        host_page_size(hostPort, &pageSize)
        let pageSize64 = UInt64(pageSize > 0 ? pageSize : 16384)
        let totalBytes = ProcessInfo.processInfo.physicalMemory

        guard kr == KERN_SUCCESS else {
            return SystemMemoryTelemetry(
                totalBytes: totalBytes,
                usedBytes: totalBytes / 2,
                wiredBytes: 0,
                activeBytes: totalBytes / 2,
                inactiveBytes: 0,
                compressedBytes: 0,
                freeBytes: totalBytes / 2,
                usedPercentage: 0.5
            )
        }

        // Note: Darwin SDK member is `wire_count`, NOT `wired_count`
        let wiredBytes = UInt64(vmStats.wire_count) * pageSize64
        let activeBytes = UInt64(vmStats.active_count) * pageSize64
        let inactiveBytes = UInt64(vmStats.inactive_count) * pageSize64
        let compressedBytes = UInt64(vmStats.compressor_page_count) * pageSize64
        let freeBytes = UInt64(vmStats.free_count) * pageSize64

        let usedBytes = min(totalBytes, wiredBytes + activeBytes + compressedBytes)
        let usedPercentage = totalBytes > 0 ? (Double(usedBytes) / Double(totalBytes)) : 0.0

        return SystemMemoryTelemetry(
            totalBytes: totalBytes,
            usedBytes: usedBytes,
            wiredBytes: wiredBytes,
            activeBytes: activeBytes,
            inactiveBytes: inactiveBytes,
            compressedBytes: compressedBytes,
            freeBytes: freeBytes,
            usedPercentage: usedPercentage
        )
    }
}
