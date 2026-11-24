import Foundation
import Testing
@testable import ZenithCore

@Suite("Virtual Display Service Suite")
@MainActor
struct VirtualDisplayServiceTests {
    private final class MockVirtualDisplayManager: VirtualDisplayManaging, @unchecked Sendable {
        var isSupported: Bool = true
        var createdName: String?
        var createdWidth: Int?
        var createdHeight: Int?
        var createdRate: Double?
        var createdHiDPI: Bool?
        var nextDisplayID: UInt32? = 99
        var destroyCallCount: Int = 0

        func createVirtualDisplay(name: String, width: Int, height: Int, refreshRate: Double, hiDPI: Bool) -> UInt32? {
            self.createdName = name
            self.createdWidth = width
            self.createdHeight = height
            self.createdRate = refreshRate
            self.createdHiDPI = hiDPI
            return nextDisplayID
        }

        func destroyVirtualDisplay() {
            destroyCallCount += 1
        }
    }

    @Test("VDS-01: Presets define correct pixel dimensions")
    func testPresets() {
        #expect(VirtualDisplayResolution.fourK.width == 3840)
        #expect(VirtualDisplayResolution.fourK.height == 2160)

        #expect(VirtualDisplayResolution.fiveK.width == 5120)
        #expect(VirtualDisplayResolution.fiveK.height == 2880)

        #expect(VirtualDisplayResolution.twoK.width == 2560)
        #expect(VirtualDisplayResolution.twoK.height == 1440)
    }

    @Test("VDS-02: Starting virtual display passes configuration and marks active")
    func testStartVirtualDisplay() {
        let mock = MockVirtualDisplayManager()
        let service = VirtualDisplayService(manager: mock)

        #expect(!service.isActive)
        #expect(service.displayID == 0)

        service.resolution = .fourK
        let ok = service.start()
        #expect(ok)
        #expect(service.isActive)
        #expect(service.displayID == 99)
        #expect(mock.createdWidth == 3840)
        #expect(mock.createdHeight == 2160)
        #expect(mock.createdHiDPI == true)
    }

    @Test("VDS-03: Stopping virtual display invokes destroy and resets state")
    func testStopVirtualDisplay() {
        let mock = MockVirtualDisplayManager()
        let service = VirtualDisplayService(manager: mock)

        service.start()
        #expect(service.isActive)

        service.stop()
        #expect(!service.isActive)
        #expect(service.displayID == 0)
        #expect(mock.destroyCallCount == 1)
    }

    @Test("VDS-04: Toggling switches virtual display on and off")
    func testToggle() {
        let mock = MockVirtualDisplayManager()
        let service = VirtualDisplayService(manager: mock)

        service.toggle()
        #expect(service.isActive)

        service.toggle()
        #expect(!service.isActive)
    }

    @Test("VDS-05: Returns false when manager is unsupported")
    func testUnsupportedManager() {
        let mock = MockVirtualDisplayManager()
        mock.isSupported = false
        let service = VirtualDisplayService(manager: mock)

        let ok = service.start()
        #expect(!ok)
        #expect(!service.isActive)
    }
}
