import Testing
import Foundation
@testable import ZenithCore

/// DDC/CI frames and EDIDs as bytes: what is sent to a display, how its answer is read, and how a display on the
/// screen is paired with the connection it hangs on. No display is involved.
@Suite("DDC Packet Suite")
struct DDCPacketTests {
    /// A "Get VCP Feature Reply" built here, not by the simulated monitor, so the two cannot agree on a mistake.
    private func reply(code: UInt8, result: UInt8 = 0, maximum: UInt16, current: UInt16) -> [UInt8] {
        var bytes: [UInt8] = [0x6E, 0x88, 0x02, result, code, 0x00,
                              UInt8(maximum >> 8), UInt8(maximum & 0xFF), UInt8(current >> 8), UInt8(current & 0xFF)]
        var checksum: UInt8 = 0x50
        for byte in bytes { checksum ^= byte }
        bytes.append(checksum)
        return bytes
    }

    @Test("DDC-01: 'Get VCP' is 82 01 code and a checksum over 6E, 51 and the frame")
    func testGetRequest() {
        #expect(DDCPacket.getRequest(code: VCPCode.brightness) == [0x82, 0x01, 0x10, 0xAC])
        let volumeChecksum: UInt8 = 0x6E ^ 0x51 ^ 0x82 ^ 0x01 ^ 0x62
        let expectedVolumeRequest: [UInt8] = [0x82, 0x01, 0x62, volumeChecksum]
        #expect(DDCPacket.getRequest(code: VCPCode.volume) == expectedVolumeRequest)
        #expect(VCPCode.brightness == 0x10 && VCPCode.contrast == 0x12 && VCPCode.volume == 0x62)
    }

    @Test("DDC-02: 'Set VCP' is 84 03 code high low and a checksum over all five bytes")
    func testSetRequest() {
        #expect(DDCPacket.setRequest(code: VCPCode.brightness, value: 70) == [0x84, 0x03, 0x10, 0x00, 0x46, 0xEE])
        // The value is big-endian.
        #expect(DDCPacket.setRequest(code: VCPCode.volume, value: 0x1234) == [0x84, 0x03, 0x62, 0x12, 0x34, 0xFC])
        #expect(DDCPacket.setRequest(code: 0x10, value: 0).count == 6)
        #expect(DDCPacket.setRequest(code: 0x10, value: .max)[3...4] == [0xFF, 0xFF])
    }

    @Test("DDC-03: A valid reply gives the current and maximum value, big-endian")
    func testDecodeValue() {
        #expect(DDCPacket.decodeReply(reply(code: 0x10, maximum: 100, current: 70), code: 0x10) == .value(current: 70, maximum: 100))
        #expect(DDCPacket.decodeReply(reply(code: 0x62, maximum: 0x0100, current: 0x0203), code: 0x62) == .value(current: 0x0203, maximum: 0x0100))
        // A longer buffer than the reply is fine: the read asks for more than it needs.
        #expect(DDCPacket.decodeReply(reply(code: 0x10, maximum: 100, current: 5) + [0, 0], code: 0x10) == .value(current: 5, maximum: 100))
    }

    @Test("DDC-04: Result code 1 means the display does not support the feature")
    func testDecodeUnsupported() {
        #expect(DDCPacket.decodeReply(reply(code: 0x62, result: 1, maximum: 0, current: 0), code: 0x62) == .unsupported)
        // Any other result code is not an answer.
        #expect(DDCPacket.decodeReply(reply(code: 0x62, result: 2, maximum: 0, current: 0), code: 0x62) == .invalid)
    }

    @Test("DDC-05: The null message is told apart from other bad replies")
    func testDecodeNullMessage() {
        #expect(DDCPacket.decodeReply([0x6E, 0x80, 0xBE, 0, 0, 0, 0, 0, 0, 0, 0], code: 0x10) == .nullMessage)
        #expect(DDCPacket.decodeReply([0x6E, 0x80, 0xBE], code: 0x10) == .nullMessage)
        #expect(DDCPacket.decodeReply([UInt8](repeating: 0, count: 11), code: 0x10) == .invalid)
        #expect(DDCPacket.decodeReply([], code: 0x10) == .invalid)
    }

    @Test("DDC-06: A wrong checksum, a shifted frame, another feature's answer or a truncated reply is invalid")
    func testDecodeInvalid() {
        var badChecksum = reply(code: 0x10, maximum: 100, current: 70)
        badChecksum[10] ^= 0x01
        #expect(DDCPacket.decodeReply(badChecksum, code: 0x10) == .invalid)

        #expect(DDCPacket.decodeReply([0x00] + reply(code: 0x10, maximum: 100, current: 70), code: 0x10) == .invalid)
        // Asked for brightness, answered for contrast.
        #expect(DDCPacket.decodeReply(reply(code: 0x12, maximum: 100, current: 60), code: 0x10) == .invalid)
        #expect(DDCPacket.decodeReply(Array(reply(code: 0x10, maximum: 100, current: 70).prefix(10)), code: 0x10) == .invalid)
        // An echo of the request is not an answer.
        #expect(DDCPacket.decodeReply(DDCPacket.getRequest(code: 0x10) + [UInt8](repeating: 0, count: 7), code: 0x10) == .invalid)
    }

    @Test("DDC-07: A read result's fraction is the value over the maximum, kept within 0 and 1")
    func testFraction() {
        #expect(DDCReadResult.value(current: 70, maximum: 100).fraction == 0.7)
        #expect(DDCReadResult.value(current: 200, maximum: 100).fraction == 1)
        #expect(DDCReadResult.value(current: 5, maximum: 0).fraction == nil)
        #expect(DDCReadResult.unsupported.fraction == nil && DDCReadResult.failed.fraction == nil)
    }

    // MARK: EDID

    @Test("DDC-08: A made-up EDID gives its vendor, model, serial and name")
    func testEDIDParse() throws {
        let bytes = SimulatedEDID.make(vendorLetters: "ABC", model: 0x1234, serial: 0x0102_0304, name: "Test Monitor")
        #expect(bytes.count == 128 && bytes.reduce(UInt8(0), { $0 &+ $1 }) == 0)
        let edid = try #require(EDID(bytes: bytes))
        #expect(edid.vendor == 0x0443)  // A=1, B=2, C=3 packed in 5 bits each
        #expect(edid.manufacturerID == "ABC")
        #expect(edid.model == 0x1234)
        #expect(edid.serial == 0x0102_0304)
        #expect(edid.productName == "Test Monitor")
        #expect(edid.matches(vendor: 0x0443, model: 0x1234, serial: 0x0102_0304))
        #expect(!edid.matches(vendor: 0x0443, model: 0x1234, serial: 1))
    }

    @Test("DDC-09: An EDID with a bad header, a bad sum or too few bytes is refused")
    func testEDIDInvalid() {
        let good = SimulatedEDID.make()
        var header = good
        header[1] = 0x00
        #expect(EDID(bytes: header) == nil)
        var sum = good
        sum[20] &+= 1
        #expect(EDID(bytes: sum) == nil)
        #expect(EDID(bytes: Array(good.prefix(127))) == nil)
        #expect(EDID(bytes: []) == nil)
        // A longer block (with an extension) is read by its first 128 bytes.
        #expect(EDID(bytes: good + [UInt8](repeating: 0, count: 128)) != nil)
    }

    @Test("DDC-10: The name is trimmed, and a missing name descriptor reads as nil")
    func testEDIDName() throws {
        let padded = try #require(EDID(bytes: SimulatedEDID.make(name: "LG")))
        #expect(padded.productName == "LG")
        var bytes = SimulatedEDID.make()
        bytes[57] = 0xFF  // a serial-number descriptor, not a name
        bytes[127] = 0 &- bytes[0..<127].reduce(UInt8(0), { $0 &+ $1 })
        #expect(EDID(bytes: bytes)?.productName == nil)
    }

    // MARK: Pairing

    private struct NoBus: DDCTransport {
        func write(chip: UInt8, offset: UInt8, bytes: [UInt8]) -> Bool { false }
        func read(chip: UInt8, offset: UInt8, count: Int) -> [UInt8]? { nil }
    }

    private func link(_ edid: EDID?, chip: UInt8 = DDCChip.standard) -> DDCLink {
        DDCLink(transport: NoBus(), initialChip: chip, edid: edid)
    }

    private func edid(model: UInt16, serial: UInt32) throws -> EDID {
        try #require(EDID(bytes: SimulatedEDID.make(model: model, serial: serial)))
    }

    @Test("DDC-11: Connections are paired with displays by vendor, model and serial; the built-in display gets none")
    func testMatchByEDID() throws {
        let builtIn = DisplayDescriptor(id: 1, name: "Built-in", isBuiltIn: true, vendor: 0x0610, model: 1, serial: 0)
        let first = DisplayDescriptor(id: 2, name: "A", isBuiltIn: false, vendor: 0x0443, model: 0x10, serial: 111)
        let second = DisplayDescriptor(id: 3, name: "B", isBuiltIn: false, vendor: 0x0443, model: 0x20, serial: 222)
        // Found in the opposite order.
        let links = [link(try edid(model: 0x20, serial: 222), chip: DDCChip.bridge), link(try edid(model: 0x10, serial: 111))]
        let matched = DDCLinkMatcher.match(displays: [builtIn, first, second], links: links)
        #expect(matched.keys.sorted() == [2, 3])
        #expect(matched[2]?.initialChip == DDCChip.standard)
        #expect(matched[3]?.initialChip == DDCChip.bridge)
        #expect(matched[1] == nil)
    }

    @Test("DDC-12: One external display and one connection are paired even if the EDID does not match or cannot be read")
    func testMatchSingle() throws {
        let display = DisplayDescriptor(id: 9, name: "Only", isBuiltIn: false, vendor: 0x0443, model: 1, serial: 1)
        #expect(DDCLinkMatcher.match(displays: [display], links: [link(nil)]).keys.sorted() == [9])
        #expect(DDCLinkMatcher.match(displays: [display], links: [link(try edid(model: 99, serial: 99))]).keys.sorted() == [9])
        // Two connections for one display, neither matching: no guess.
        #expect(DDCLinkMatcher.match(displays: [display], links: [link(nil), link(nil)]).isEmpty)
        #expect(DDCLinkMatcher.match(displays: [display], links: []).isEmpty)
    }

    @Test("DDC-13: Two identical monitors are each given one connection, none twice")
    func testMatchIdentical() throws {
        let one = DisplayDescriptor(id: 2, name: "A", isBuiltIn: false, vendor: 0x0443, model: 5, serial: 0)
        let two = DisplayDescriptor(id: 3, name: "A", isBuiltIn: false, vendor: 0x0443, model: 5, serial: 0)
        let same = try edid(model: 5, serial: 0)
        let matched = DDCLinkMatcher.match(displays: [one, two], links: [link(same), link(same, chip: DDCChip.bridge)])
        #expect(matched.count == 2)
        #expect(Set(matched.values.map(\.initialChip)) == [DDCChip.standard, DDCChip.bridge])
    }
}
