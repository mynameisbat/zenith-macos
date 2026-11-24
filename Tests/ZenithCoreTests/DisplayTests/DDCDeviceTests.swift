import Testing
import Foundation
@testable import ZenithCore

/// The DDC conversation against a simulated monitor: which chip it is written to, what happens on a null message, and
/// what the writes look like on the bus.
@Suite("DDC Device Suite")
struct DDCDeviceTests {
    private func device(_ monitor: SimulatedDDCMonitor, startingAt chip: UInt8) -> DDCDevice {
        DDCDevice(transport: monitor, initialChip: chip, timing: .instant)
    }

    @Test("DDC-20: A monitor on the standard chip is read on the first try")
    func testStandardChip() {
        let monitor = SimulatedDDCMonitor(acceptedChip: DDCChip.standard)
        let device = device(monitor, startingAt: DDCChip.standard)
        #expect(device.read(VCPCode.brightness) == .value(current: 70, maximum: 100))
        #expect(monitor.readChips == [DDCChip.standard])
        #expect(device.isChipConfirmed)
    }

    @Test("DDC-21: Behind a DisplayPort-to-HDMI bridge the null message on 0x37 moves it to 0xB7, and 0xB7 is kept")
    func testChipFallback() {
        let monitor = SimulatedDDCMonitor(acceptedChip: DDCChip.bridge)
        let device = device(monitor, startingAt: DDCChip.standard)
        #expect(!device.isChipConfirmed)
        #expect(device.read(VCPCode.brightness) == .value(current: 70, maximum: 100))
        #expect(monitor.readChips == [DDCChip.standard, DDCChip.bridge])
        #expect(device.chip == DDCChip.bridge && device.isChipConfirmed)
        // The next read goes straight to the chip that worked.
        #expect(device.read(VCPCode.volume) == .value(current: 30, maximum: 100))
        #expect(monitor.readChips.suffix(1) == [DDCChip.bridge])
    }

    @Test("DDC-22: The other direction works too: a monitor on 0x37 reached from 0xB7")
    func testChipFallbackBackwards() {
        let monitor = SimulatedDDCMonitor(acceptedChip: DDCChip.standard)
        let device = device(monitor, startingAt: DDCChip.bridge)
        #expect(device.read(VCPCode.contrast) == .value(current: 60, maximum: 100))
        #expect(device.chip == DDCChip.standard)
    }

    @Test("DDC-23: A monitor that only ever sends the null message fails after four tries, alternating chips")
    func testAlwaysNull() {
        let monitor = SimulatedDDCMonitor(behavior: .alwaysNull)
        let device = device(monitor, startingAt: DDCChip.standard)
        #expect(device.read(VCPCode.brightness) == .failed)
        #expect(monitor.readChips == [DDCChip.standard, DDCChip.bridge, DDCChip.standard, DDCChip.bridge])
        #expect(!device.isChipConfirmed)
    }

    @Test("DDC-24: Two nulls from a monitor still waking up on the right chip do not strand the device on the wrong one")
    func testTransientNulls() {
        let monitor = SimulatedDDCMonitor(acceptedChip: DDCChip.standard, behavior: .nullFirst(count: 2))
        let device = device(monitor, startingAt: DDCChip.standard)
        #expect(device.read(VCPCode.brightness) == .value(current: 70, maximum: 100))
        #expect(device.chip == DDCChip.standard)
    }

    @Test("DDC-25: Once a chip has answered, a later null message never switches it")
    func testConfirmedChipStays() {
        let monitor = SimulatedDDCMonitor(acceptedChip: DDCChip.bridge)
        let device = device(monitor, startingAt: DDCChip.bridge)
        #expect(device.read(VCPCode.brightness) != .failed)
        monitor.setBehavior(.alwaysNull)
        #expect(device.read(VCPCode.brightness) == .failed)
        #expect(device.chip == DDCChip.bridge)
        #expect(monitor.readChips.suffix(4).allSatisfy { $0 == DDCChip.bridge })
    }

    @Test("DDC-26: A feature the monitor lacks reads as unsupported, at once")
    func testUnsupported() {
        let monitor = SimulatedDDCMonitor(unsupported: [VCPCode.volume])
        let device = device(monitor, startingAt: DDCChip.standard)
        #expect(device.read(VCPCode.volume) == .unsupported)
        #expect(monitor.readChips.count == 1)
    }

    @Test("DDC-27: A wrong checksum, a shifted frame and silence are never taken for a value")
    func testBadReplies() {
        for behavior in [SimulatedDDCMonitor.Behavior.badChecksum, .shifted, .silent] {
            let monitor = SimulatedDDCMonitor(behavior: behavior)
            #expect(device(monitor, startingAt: DDCChip.standard).read(VCPCode.brightness) == .failed, "\(behavior)")
            #expect(monitor.readChips.count == 4, "\(behavior)")
        }
    }

    @Test("DDC-28: A bus that refuses the request is tried again, and reported as failed")
    func testBusRefuses() {
        let monitor = SimulatedDDCMonitor(behavior: .refusesWrites)
        #expect(device(monitor, startingAt: DDCChip.standard).read(VCPCode.brightness) == .failed)
        #expect(monitor.writes.count == 4)
        #expect(monitor.readChips.isEmpty)
    }

    @Test("DDC-29: 'Set VCP' goes to the data address as the frame with its checksum, twice")
    func testWrite() {
        let monitor = SimulatedDDCMonitor(acceptedChip: DDCChip.bridge)
        let device = device(monitor, startingAt: DDCChip.bridge)
        #expect(device.write(VCPCode.brightness, value: 40))
        #expect(monitor.writes.count == 2)
        for write in monitor.writes {
            #expect(write.chip == DDCChip.bridge && write.offset == 0x51)
            #expect(write.bytes == DDCPacket.setRequest(code: 0x10, value: 40))
        }
        #expect(monitor.setCommands.map(\.value) == [40, 40])
        #expect(monitor.feature(VCPCode.brightness)?.current == 40)
    }

    @Test("DDC-30: A write to the wrong chip is accepted by the bus but changes nothing")
    func testWriteWrongChip() {
        let monitor = SimulatedDDCMonitor(acceptedChip: DDCChip.bridge)
        let device = device(monitor, startingAt: DDCChip.standard)
        #expect(device.write(VCPCode.brightness, value: 10))
        #expect(monitor.setCommands.isEmpty)
        #expect(monitor.feature(VCPCode.brightness)?.current == 70)
        #expect(!DDCDevice(transport: SimulatedDDCMonitor(behavior: .refusesWrites), initialChip: 0x37, timing: .instant).write(0x10, value: 1))
    }

    @Test("DDC-31: The EDID is read from chip 0x50 and parsed; a monitor without one gives nil")
    func testReadEDID() {
        let withEDID = SimulatedDDCMonitor(edid: SimulatedEDID.make(name: "Desk Monitor"))
        #expect(device(withEDID, startingAt: 0x37).readEDID()?.productName == "Desk Monitor")
        #expect(device(SimulatedDDCMonitor(), startingAt: 0x37).readEDID() == nil)
    }
}
