import Foundation
import Combine
import Darwin

/// Bytes an interface has received and sent since it came up.
public struct NetworkCounters: Sendable, Equatable {
    public var receivedBytes: UInt64
    public var sentBytes: UInt64

    public init(receivedBytes: UInt64, sentBytes: UInt64) {
        self.receivedBytes = receivedBytes
        self.sentBytes = sentBytes
    }
}

/// How fast data is moving in and out of the Mac, in bytes per second.
public struct NetworkSpeed: Sendable, Equatable {
    public var downloadBytesPerSecond: Double
    public var uploadBytesPerSecond: Double

    public static let zero = NetworkSpeed(downloadBytesPerSecond: 0, uploadBytesPerSecond: 0)

    public init(downloadBytesPerSecond: Double, uploadBytesPerSecond: Double) {
        self.downloadBytesPerSecond = downloadBytesPerSecond
        self.uploadBytesPerSecond = uploadBytesPerSecond
    }

    /// The speed between two readings of the per-interface counters.
    ///
    /// Each interface is compared with itself, so an interface that appears (a dock, a USB adapter) does not add its
    /// whole history as one burst, one that disappears does not make the speed negative, and a counter that went
    /// backwards (the interface was reset) counts as nothing for that interval.
    public static func between(
        previous: [String: NetworkCounters],
        current: [String: NetworkCounters],
        interval: TimeInterval
    ) -> NetworkSpeed {
        guard interval > 0 else { return .zero }
        var received: UInt64 = 0
        var sent: UInt64 = 0
        for (name, now) in current {
            guard let before = previous[name] else { continue }
            if now.receivedBytes >= before.receivedBytes { received += now.receivedBytes - before.receivedBytes }
            if now.sentBytes >= before.sentBytes { sent += now.sentBytes - before.sentBytes }
        }
        return NetworkSpeed(
            downloadBytesPerSecond: Double(received) / interval,
            uploadBytesPerSecond: Double(sent) / interval
        )
    }

    /// A rate for display: `0 B/s`, `340 KB/s`, `1.2 MB/s`. Decimal units, as Finder uses.
    public static func format(_ bytesPerSecond: Double, locale: Locale = .current) -> String {
        let value = max(0, bytesPerSecond)
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var scaled = value
        var unit = 0
        while scaled >= 1000, unit < units.count - 1 {
            scaled /= 1000
            unit += 1
        }
        // Whole bytes never need a decimal; a small number of the larger units does ("1.2 MB/s", "340 KB/s").
        let digits = (unit > 0 && scaled < 10) ? 1 : 0
        let number = String(format: "%.\(digits)f", locale: locale, scaled)
        return "\(number) \(units[unit])"
    }

    public var formattedDownload: String { Self.format(downloadBytesPerSecond) }
    public var formattedUpload: String { Self.format(uploadBytesPerSecond) }
}

/// Reads the byte counters the kernel keeps for each network interface.
public enum NetworkInterfaceReader {
    /// Whether an interface's traffic is real traffic on the wire. Wi-Fi and Ethernet (`en0`, `en5`, …) and cellular
    /// tethering (`pdp_ip0`) are; the rest would count the same bytes twice (VPN tunnels `utun*` carry what `en0`
    /// already counted, `bridge*` holds `en*` members) or are not the network at all (`lo0`, `awdl0`, `llw0`).
    public static func countsTowardTraffic(name: String) -> Bool {
        if name.hasPrefix("pdp_ip") { return true }
        guard name.hasPrefix("en") else { return false }
        let rest = name.dropFirst(2)
        return !rest.isEmpty && rest.allSatisfy(\.isNumber)
    }

    /// The 64-bit counters of every interface that counts, by name. Nil when the kernel could not be asked.
    /// (`getifaddrs` would be simpler but its counters are 32-bit and wrap after 4 GB.)
    public static func readCounters() -> [String: NetworkCounters]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return nil }

        let rtmIfInfo2: UInt8 = 0x12 // RTM_IFINFO2 in <net/route.h>
        var result: [String: NetworkCounters] = [:]
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0, offset + messageLength <= length else { break }
                if header.ifm_type == rtmIfInfo2, messageLength >= MemoryLayout<if_msghdr2>.size {
                    let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(info.ifm_index), &nameBuffer) != nil {
                        let name = String(decoding: nameBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                        if countsTowardTraffic(name: name) {
                            result[name] = NetworkCounters(
                                receivedBytes: info.ifm_data.ifi_ibytes,
                                sentBytes: info.ifm_data.ifi_obytes
                            )
                        }
                    }
                }
                offset += messageLength
            }
        }
        return result
    }
}

/// Measures download and upload speed once a second, but only while something is showing it.
///
/// A view that shows the speed calls `acquire()` when it appears and `release()` when it goes; the sampling task
/// exists only between the first acquire and the last release, so a hidden Command Hub costs nothing.
@MainActor
public final class NetworkSpeedMonitor: ObservableObject {
    public static let shared = NetworkSpeedMonitor()

    @Published public private(set) var speed: NetworkSpeed = .zero

    private let reader: @Sendable () -> [String: NetworkCounters]?
    private let now: @Sendable () -> Date
    private let autoTick: Bool
    private let interval: TimeInterval

    private var previous: (counters: [String: NetworkCounters], date: Date)?
    private var clients = 0
    private var ticker: Task<Void, Never>?
    private var pinned = false

    /// - Parameters:
    ///   - reader: where the counters come from; the kernel by default, a stand-in in tests.
    ///   - autoTick: `false` in tests, which call `sample()` themselves.
    public init(
        reader: @escaping @Sendable () -> [String: NetworkCounters]? = { NetworkInterfaceReader.readCounters() },
        now: @escaping @Sendable () -> Date = { Date() },
        interval: TimeInterval = 1,
        autoTick: Bool = true
    ) {
        self.reader = reader
        self.now = now
        self.interval = interval
        self.autoTick = autoTick
    }

    /// Whether anything is asking for measurements right now.
    public var isSampling: Bool { clients > 0 }

    public func acquire() {
        clients += 1
        guard clients == 1 else { return }
        previous = nil
        sample() // the baseline; the first speed arrives with the next sample
        guard autoTick else { return }
        let seconds = interval
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if Task.isCancelled { break }
                self?.sample()
            }
        }
    }

    public func release() {
        guard clients > 0 else { return }
        clients -= 1
        guard clients == 0 else { return }
        ticker?.cancel()
        ticker = nil
        previous = nil
        if !pinned { speed = .zero }
    }

    /// Takes one reading and updates `speed`.
    public func sample() {
        guard !pinned else { return }
        guard let counters = reader() else {
            speed = .zero
            previous = nil
            return
        }
        let date = now()
        if let before = previous {
            speed = NetworkSpeed.between(
                previous: before.counters,
                current: counters,
                interval: date.timeIntervalSince(before.date)
            )
        }
        previous = (counters, date)
    }

    /// Shows a fixed speed and stops measuring. For the screenshots, which must not show this Mac's real traffic.
    public func pin(_ fixed: NetworkSpeed) {
        pinned = true
        speed = fixed
    }
}

/// One viewer's claim on `NetworkSpeedMonitor`. `begin()` and `end()` can be called in any order and any number of
/// times: only the first `begin()` after an `end()` asks for measuring, and only the first `end()` after a `begin()`
/// gives it back, so a view that appears twice, or a popover that is closed twice, never takes a count that is
/// someone else's.
@MainActor
public final class NetworkSpeedLease: ObservableObject {
    private let monitor: NetworkSpeedMonitor
    public private(set) var isHeld = false

    public init(monitor: NetworkSpeedMonitor = .shared) {
        self.monitor = monitor
    }

    public func begin() {
        guard !isHeld else { return }
        isHeld = true
        monitor.acquire()
    }

    public func end() {
        guard isHeld else { return }
        isHeld = false
        monitor.release()
    }
}
