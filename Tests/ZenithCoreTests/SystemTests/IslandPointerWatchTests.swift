import Testing
import Foundation
import CoreGraphics
@testable import ZenithCore

@Suite("Island Pointer Watch Suite")
struct IslandPointerWatchTests {
    private let zone = IslandPointerWatch.zone(around: CGRect(x: 500, y: 900, width: 380, height: 96))
    private let far = CGPoint(x: 100, y: 100)
    private let near = CGPoint(x: 690, y: 880)

    @Test("IPW-01: Event monitors are wanted only near the island or while it is engaged")
    func testMonitorsOnlyNearOrEngaged() {
        var watch = IslandPointerWatch()
        #expect(!watch.sample(location: far, zone: zone, isEngaged: false, now: 0).wantsEventMonitors)
        #expect(watch.sample(location: near, zone: zone, isEngaged: false, now: 0.1).wantsEventMonitors)
        #expect(watch.sample(location: far, zone: zone, isEngaged: true, now: 0.2).wantsEventMonitors)
        #expect(!watch.sample(location: far, zone: zone, isEngaged: false, now: 0.3).wantsEventMonitors)
    }

    @Test("IPW-02: The zone reaches past the panel by the margin on every side")
    func testZoneMargin() {
        let m = IslandPointerWatch.zoneMargin
        #expect(zone == CGRect(x: 500 - m, y: 900 - m, width: 380 + 2 * m, height: 96 + 2 * m))
    }

    @Test("IPW-03: A moving pointer is read at the fast rate, a rested one at the slow rate, and moving again speeds it up")
    func testIntervals() {
        var watch = IslandPointerWatch()
        let first = watch.sample(location: far, zone: zone, isEngaged: false, now: 10)
        #expect(first.moved)
        #expect(first.nextInterval == IslandPointerWatch.movingInterval)

        let still = watch.sample(location: far, zone: zone, isEngaged: false, now: 11)
        #expect(!still.moved)
        #expect(still.nextInterval == IslandPointerWatch.movingInterval)

        let rested = watch.sample(location: far, zone: zone, isEngaged: false, now: 10 + IslandPointerWatch.restAfter)
        #expect(rested.nextInterval == IslandPointerWatch.restingInterval)

        let again = watch.sample(location: CGPoint(x: 101, y: 100), zone: zone, isEngaged: false, now: 60)
        #expect(again.moved)
        #expect(again.nextInterval == IslandPointerWatch.movingInterval)
    }
}
