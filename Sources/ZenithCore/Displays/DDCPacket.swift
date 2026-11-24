import Foundation

/// The VCP feature codes (VESA MCCS) Zenith uses.
public enum VCPCode {
    public static let brightness: UInt8 = 0x10
    public static let contrast: UInt8 = 0x12
    public static let volume: UInt8 = 0x62
}

/// What a display answered to "Get VCP Feature".
public enum DDCReply: Equatable, Sendable {
    /// The feature's current and maximum value.
    case value(current: UInt16, maximum: UInt16)
    /// A well-formed answer saying the display does not have this feature.
    case unsupported
    /// The DDC "null message" (`6E 80 BE`): the display heard nothing it could answer, which is also what the wrong
    /// I2C chip address produces.
    case nullMessage
    /// Anything else: empty, an echo of the request, a shifted frame, a failed checksum.
    case invalid
}

/// DDC/CI packets, as bytes: the frames sent to a display and the reading of what it answers. Pure functions, so every
/// byte is testable without a display.
///
/// The framing and checksums follow the DDC/CI protocol as m1ddc (MIT, Copyright (c) 2021 waydabber) implements them
/// for Apple silicon; see THIRD_PARTY_NOTICES.md.
public enum DDCPacket {
    /// The host's source address, the first byte of every checksum.
    public static let hostAddress: UInt8 = 0x6E
    /// The data address (offset) a DDC/CI frame is written to and read from.
    public static let dataAddress: UInt8 = 0x51
    /// A "Get VCP Feature Reply" is 11 bytes.
    public static let replyLength = 11

    /// "Get VCP Feature": `[0x82, 0x01, code, checksum]`.
    public static func getRequest(code: UInt8) -> [UInt8] {
        var bytes: [UInt8] = [0x82, 0x01, code]
        bytes.append(checksum(of: bytes))
        return bytes
    }

    /// "Set VCP Feature": `[0x84, 0x03, code, high, low, checksum]`.
    public static func setRequest(code: UInt8, value: UInt16) -> [UInt8] {
        var bytes: [UInt8] = [0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)]
        bytes.append(checksum(of: bytes))
        return bytes
    }

    /// The checksum of a frame written to the display: the host address and the data address XORed with every byte.
    public static func checksum(of frame: [UInt8]) -> UInt8 {
        frame.reduce(hostAddress ^ dataAddress) { $0 ^ $1 }
    }

    /// Reads the bytes a display answered with to a "Get VCP Feature" for `code`.
    ///
    /// A valid reply is `6E 88 02 <result> <code> <type> <max hi> <max lo> <cur hi> <cur lo> <checksum>`, where the
    /// checksum is 0x50 XORed with the ten bytes before it. Result 0 carries a value, 1 says the feature is not
    /// supported.
    public static func decodeReply(_ bytes: [UInt8], code: UInt8) -> DDCReply {
        if bytes.count >= 3, bytes[0] == hostAddress, bytes[1] == 0x80, bytes[2] == 0xBE {
            return .nullMessage
        }
        guard bytes.count >= replyLength,
              bytes[0] == hostAddress, bytes[1] == 0x88, bytes[2] == 0x02, bytes[4] == code else {
            return .invalid
        }
        let expected = bytes[0..<10].reduce(UInt8(0x50)) { $0 ^ $1 }
        guard expected == bytes[10] else { return .invalid }
        switch bytes[3] {
        case 0x00:
            let maximum = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
            let current = UInt16(bytes[8]) << 8 | UInt16(bytes[9])
            return .value(current: current, maximum: maximum)
        case 0x01:
            return .unsupported
        default:
            return .invalid
        }
    }
}
