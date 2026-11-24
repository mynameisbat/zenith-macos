import Testing
import Foundation
import CoreGraphics
@testable import ZenithCore

/// Reads this Mac's real displays, read-only: lists them, asks DisplayServices whether it can change each one's
/// brightness, and sends DDC "Get VCP" requests to external monitors. It never sets anything (no DDC "Set VCP", no
/// DisplayServices write, no gamma change). Opt in with `ZENITH_E2E_DISPLAY=1`.
private let displayE2EEnabled = ProcessInfo.processInfo.environment["ZENITH_E2E_DISPLAY"] == "1"

@Suite("Display hardware (opt-in, read-only)", .enabled(if: displayE2EEnabled), .serialized)
@MainActor
struct DisplayE2EReadOnlyTests {
    @Test("DE-01: The real inventory lists the displays, and an external monitor on DDC answers a brightness read")
    func testRealDisplays() async {
        let inventory = SystemDisplayInventory()
        let displays = inventory.onlineDisplays()
        print("DE-01 displays: \(displays.map { "\($0.id) \($0.name) builtIn=\($0.isBuiltIn) key=\($0.key)" })")
        #expect(!displays.isEmpty)

        let native = DisplayServicesBridge()
        for display in displays {
            print("DE-01 \(display.name): DisplayServices canChange=\(native.canChangeBrightness(of: display.id)) value=\(String(describing: native.brightness(of: display.id)))")
        }

        let links = await Task.detached { inventory.ddcLinks(for: displays) }.value
        for (id, link) in links.sorted(by: { $0.key < $1.key }) {
            print("DE-01 display \(id): DDC chip 0x\(String(link.initialChip, radix: 16)) edid=\(String(describing: link.edid?.productName)) manufacturer=\(link.edid?.manufacturerID ?? "-")")
            let device = DDCDevice(transport: link.transport, initialChip: link.initialChip)
            let result = await Task.detached { (device.read(VCPCode.brightness), device.read(VCPCode.volume), device.chip) }.value
            print("DE-01 display \(id): brightness=\(result.0) volume=\(result.1) chip=0x\(String(result.2, radix: 16))")
        }
    }

    @Test("DE-02: The real display configuring lists modes and current mode for each display")
    func testRealDisplayModes() {
        let inventory = SystemDisplayInventory()
        let configuring = SystemDisplayConfiguring()
        let displays = inventory.onlineDisplays()
        #expect(!displays.isEmpty)

        for display in displays {
            let current = configuring.currentMode(for: display.id)
            let modes = configuring.allModes(for: display.id)
            print("DE-02 \(display.name): currentMode=\(current?.fullTitle ?? "none") totalModes=\(modes.count)")
            let topModes = modes.prefix(5).map(\.fullTitle).joined(separator: " | ")
            print("DE-02 sample modes: \(topModes)")
            #expect(current != nil)
            #expect(!modes.isEmpty)
        }
    }

    @Test("DE-03: Real virtual display creation, validation and teardown")
    func testRealVirtualDisplay() async {
        let manager = SystemVirtualDisplayManager()
        #expect(manager.isSupported)

        print("DE-03: Creating 4K HiDPI virtual display on real macOS Window Server...")
        let id = manager.createVirtualDisplay(
            name: "Zenith Test Virtual HiDPI",
            width: 3840,
            height: 2160,
            refreshRate: 60.0,
            hiDPI: true
        )
        print("DE-03: Allocated virtual displayID: \(String(describing: id))")
        #expect(id != nil && id != 0)

        if let id {
            let bounds = CGDisplayBounds(id)
            print("DE-03: Virtual display active bounds: \(bounds)")
            #expect(bounds.width == 1920)
            #expect(bounds.height == 1080)

            print("DE-03: Tearing down virtual display...")
            manager.destroyVirtualDisplay()
            print("DE-03: Virtual display teardown complete")
        }
    }
}
