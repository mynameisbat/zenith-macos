import Foundation

/// The identity a display announces in its EDID base block (128 bytes, VESA E-EDID 1.3/1.4 layout).
///
/// `vendor`, `model` and `serial` are the values CoreGraphics reports as `CGDisplayVendorNumber`,
/// `CGDisplayModelNumber` and `CGDisplaySerialNumber`, which is how a display on the screen is matched to the DDC
/// connection it hangs on. The parsing follows m1ddc's `avservice.m` (MIT, Copyright (c) 2021 waydabber).
public struct EDID: Equatable, Sendable {
    public static let length = 128

    /// The three-letter manufacturer code packed into bytes 8 and 9, as one 16-bit number.
    public let vendor: UInt32
    public let model: UInt32
    public let serial: UInt32
    /// The product name (descriptor tag 0xFC), if the display has one.
    public let productName: String?

    public init(vendor: UInt32, model: UInt32, serial: UInt32, productName: String?) {
        self.vendor = vendor
        self.model = model
        self.serial = serial
        self.productName = productName
    }

    /// `nil` unless `bytes` starts with a base block: the 8-byte header and a sum of 0 modulo 256.
    public init?(bytes: [UInt8]) {
        guard bytes.count >= Self.length else { return nil }
        let block = Array(bytes[0..<Self.length])
        guard Array(block[0..<8]) == [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00],
              block.reduce(UInt8(0), { $0 &+ $1 }) == 0 else { return nil }
        vendor = UInt32(block[8]) << 8 | UInt32(block[9])
        model = UInt32(block[10]) | UInt32(block[11]) << 8
        serial = UInt32(block[12]) | UInt32(block[13]) << 8 | UInt32(block[14]) << 16 | UInt32(block[15]) << 24
        productName = Self.descriptorText(in: block, tag: 0xFC)
    }

    /// The manufacturer as the three letters it is registered under ("GSM", "DEL").
    public var manufacturerID: String {
        let letters = [(vendor >> 10) & 0x1F, (vendor >> 5) & 0x1F, vendor & 0x1F].map { code -> Character in
            Character(Unicode.Scalar(UInt8(truncatingIfNeeded: 64 + code)))
        }
        return String(letters)
    }

    /// Whether this is the display CoreGraphics knows by these three numbers.
    public func matches(vendor: UInt32, model: UInt32, serial: UInt32) -> Bool {
        self.vendor == vendor && self.model == model && self.serial == serial
    }

    /// The text of the 18-byte descriptor (at 54, 72, 90 or 108) whose tag is `tag`: ASCII up to a line feed,
    /// without the padding.
    private static func descriptorText(in block: [UInt8], tag: UInt8) -> String? {
        for start in stride(from: 54, through: 108, by: 18) {
            guard block[start] == 0, block[start + 1] == 0, block[start + 2] == 0, block[start + 3] == tag else { continue }
            let text = block[(start + 5)..<(start + 18)].prefix { $0 != 0x0A }
            let name = String(decoding: text, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
        return nil
    }
}
