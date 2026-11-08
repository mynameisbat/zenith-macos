import Testing
import Foundation
@testable import ZenithCore

/// A clock and a set of interface counters the tests move by hand.
private final class FakeNetwork: @unchecked Sendable {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
    var counters: [String: NetworkCounters]? = [:]
    func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
}

@Suite("Network speed: counters to bytes per second, and when it measures")
@MainActor
struct NetworkSpeedTests {
    private func monitor(_ network: FakeNetwork) -> NetworkSpeedMonitor {
        NetworkSpeedMonitor(reader: { network.counters }, now: { network.date }, autoTick: false)
    }

    private func counters(_ received: UInt64, _ sent: UInt64) -> NetworkCounters {
        NetworkCounters(receivedBytes: received, sentBytes: sent)
    }

    @Test("NS-01: Speed is the change in the counters divided by the time between readings")
    func testSpeedFromDeltas() {
        let speed = NetworkSpeed.between(
            previous: ["en0": counters(1_000, 500)],
            current: ["en0": counters(3_000, 1_500)],
            interval: 2
        )
        #expect(speed == NetworkSpeed(downloadBytesPerSecond: 1_000, uploadBytesPerSecond: 500))
    }

    @Test("NS-02: An interface that just appeared adds nothing; its history is not a burst")
    func testNewInterfaceIsIgnoredForOneInterval() {
        let speed = NetworkSpeed.between(
            previous: ["en0": counters(100, 100)],
            current: ["en0": counters(200, 100), "en5": counters(9_000_000_000, 9_000_000_000)],
            interval: 1
        )
        #expect(speed.downloadBytesPerSecond == 100)
        #expect(speed.uploadBytesPerSecond == 0)
    }

    @Test("NS-03: A counter that went backwards, or an interface that left, never makes the speed negative")
    func testCounterReset() {
        let speed = NetworkSpeed.between(
            previous: ["en0": counters(5_000, 5_000), "en5": counters(1_000, 1_000)],
            current: ["en0": counters(100, 6_000)],
            interval: 1
        )
        #expect(speed.downloadBytesPerSecond == 0)
        #expect(speed.uploadBytesPerSecond == 1_000)
    }

    @Test("NS-04: A zero or negative interval gives zero, not infinity")
    func testNonPositiveInterval() {
        let a = ["en0": counters(0, 0)]
        let b = ["en0": counters(1_000, 1_000)]
        #expect(NetworkSpeed.between(previous: a, current: b, interval: 0) == .zero)
        #expect(NetworkSpeed.between(previous: a, current: b, interval: -3) == .zero)
    }

    @Test("NS-05: Rates are written with the right unit and no pointless decimals")
    func testFormatting() {
        let en = Locale(identifier: "en_US")
        #expect(NetworkSpeed.format(0, locale: en) == "0 B/s")
        #expect(NetworkSpeed.format(999, locale: en) == "999 B/s")
        #expect(NetworkSpeed.format(1_000, locale: en) == "1.0 KB/s")
        #expect(NetworkSpeed.format(340_000, locale: en) == "340 KB/s")
        #expect(NetworkSpeed.format(1_240_000, locale: en) == "1.2 MB/s")
        #expect(NetworkSpeed.format(48_600_000, locale: en) == "49 MB/s")
        #expect(NetworkSpeed.format(2_500_000_000, locale: en) == "2.5 GB/s")
        #expect(NetworkSpeed.format(-5, locale: en) == "0 B/s")
        // The decimal separator follows the language (Vietnamese writes "1,2").
        #expect(NetworkSpeed.format(1_240_000, locale: Locale(identifier: "vi_VN")) == "1,2 MB/s")
    }

    @Test("NS-06: Only Wi-Fi, Ethernet and cellular interfaces count; tunnels and loopback would double-count")
    func testInterfacePolicy() {
        for name in ["en0", "en1", "en12", "pdp_ip0"] {
            #expect(NetworkInterfaceReader.countsTowardTraffic(name: name), "\(name)")
        }
        for name in ["lo0", "utun3", "bridge0", "awdl0", "llw0", "gif0", "stf0", "ap1", "anpi0", "en", "enx", "en0x", ""] {
            #expect(!NetworkInterfaceReader.countsTowardTraffic(name: name), "\(name)")
        }
    }

    @Test("NS-07: The kernel can be read, and loopback never shows up in it")
    func testRealCounters() throws {
        let counters = try #require(NetworkInterfaceReader.readCounters())
        for name in counters.keys {
            #expect(NetworkInterfaceReader.countsTowardTraffic(name: name))
        }
    }

    @Test("NS-08: The first reading is only a baseline; the speed arrives with the second")
    func testMonitorNeedsTwoReadings() {
        let network = FakeNetwork()
        network.counters = ["en0": counters(1_000, 0)]
        let monitor = monitor(network)

        monitor.acquire()
        #expect(monitor.speed == .zero)

        network.advance(1)
        network.counters = ["en0": counters(251_000, 50_000)]
        monitor.sample()
        #expect(monitor.speed == NetworkSpeed(downloadBytesPerSecond: 250_000, uploadBytesPerSecond: 50_000))
    }

    @Test("NS-09: It measures only while someone is showing it, and starts over after a pause")
    func testAcquireAndRelease() {
        let network = FakeNetwork()
        network.counters = ["en0": counters(0, 0)]
        let monitor = monitor(network)
        #expect(!monitor.isSampling)

        monitor.acquire()
        monitor.acquire() // two views at once: still one measurement
        #expect(monitor.isSampling)
        network.advance(1)
        network.counters = ["en0": counters(1_000, 0)]
        monitor.sample()
        #expect(monitor.speed.downloadBytesPerSecond == 1_000)

        monitor.release()
        #expect(monitor.isSampling)
        monitor.release()
        #expect(!monitor.isSampling)
        #expect(monitor.speed == .zero)

        // A long time later, the old reading must not turn into one huge average.
        network.advance(3_600)
        network.counters = ["en0": counters(900_000_000, 0)]
        monitor.acquire()
        #expect(monitor.speed == .zero)
        monitor.release()
    }

    @Test("NS-10: Releasing more often than acquiring does nothing")
    func testUnbalancedRelease() {
        let monitor = monitor(FakeNetwork())
        monitor.release()
        monitor.release()
        #expect(!monitor.isSampling)
        monitor.acquire()
        #expect(monitor.isSampling)
        monitor.release()
    }

    @Test("NS-11: When the counters cannot be read the speed is zero, not stale")
    func testUnreadableCounters() {
        let network = FakeNetwork()
        network.counters = ["en0": counters(0, 0)]
        let monitor = monitor(network)
        monitor.acquire()
        network.advance(1)
        network.counters = ["en0": counters(5_000, 0)]
        monitor.sample()
        #expect(monitor.speed.downloadBytesPerSecond == 5_000)

        network.advance(1)
        network.counters = nil
        monitor.sample()
        #expect(monitor.speed == .zero)
        monitor.release()
    }

    @Test("NS-12: A pinned speed (the screenshots) is not overwritten by real traffic")
    func testPinned() {
        let network = FakeNetwork()
        network.counters = ["en0": counters(0, 0)]
        let monitor = monitor(network)
        let fixed = NetworkSpeed(downloadBytesPerSecond: 2_400_000, uploadBytesPerSecond: 180_000)
        monitor.pin(fixed)
        monitor.acquire()
        network.advance(1)
        network.counters = ["en0": counters(99_000_000, 99_000_000)]
        monitor.sample()
        #expect(monitor.speed == fixed)
        monitor.release()
        #expect(monitor.speed == fixed)
    }

    @Test("NS-13: A lease asks for measuring once, however often begin and end are called, and never takes another's count")
    func testLease() {
        let monitor = monitor(FakeNetwork())
        let first = NetworkSpeedLease(monitor: monitor)
        let second = NetworkSpeedLease(monitor: monitor)

        first.begin()
        first.begin()          // a view that appears twice
        second.begin()
        first.end()
        first.end()            // a popover closed twice
        #expect(monitor.isSampling, "the second viewer is still showing it")
        second.end()
        #expect(!monitor.isSampling)

        second.end()           // never began again: gives back nothing
        first.begin()
        #expect(monitor.isSampling)
        first.end()
        #expect(!monitor.isSampling)
    }
}
