import Foundation

/// A monitor on the DDC bus, in memory: it answers "Get VCP" like a real one and records every write, so the DDC code
/// is tested without touching a display.
///
/// It answers only at `acceptedChip`; at the other chip it returns the null message (`6E 80 BE`), as a real monitor
/// behind the wrong bridge does. `behavior` makes it misbehave on purpose.
public final class SimulatedDDCMonitor: DDCTransport, @unchecked Sendable {
    public enum Behavior: Equatable, Sendable {
        case normal
        /// Every read is the null message, whatever the chip.
        case alwaysNull
        /// Every read is zeros.
        case silent
        /// Replies carry a wrong checksum.
        case badChecksum
        /// Replies come one byte late (a stray leading byte).
        case shifted
        /// The first `count` reads are the null message, then it behaves normally.
        case nullFirst(count: Int)
        /// The bus refuses every write.
        case refusesWrites
    }

    public struct Feature: Equatable, Sendable {
        public var current: UInt16
        public var maximum: UInt16
        public init(current: UInt16, maximum: UInt16) {
            self.current = current
            self.maximum = maximum
        }
    }

    public struct Write: Equatable, Sendable {
        public let chip: UInt8
        public let offset: UInt8
        public let bytes: [UInt8]
    }

    private let lock = NSLock()
    private var features: [UInt8: Feature]
    private var unsupported: Set<UInt8>
    private var behavior: Behavior
    private var edidBytes: [UInt8]?
    private var pendingCode: UInt8?
    private var nullsLeft = 0
    private var recordedWrites: [Write] = []
    private var recordedReadChips: [UInt8] = []
    private var appliedSets: [(code: UInt8, value: UInt16)] = []

    /// A monitor with brightness 70/100, contrast 60/100 and volume 30/100, answering at `acceptedChip`.
    public init(
        acceptedChip: UInt8 = DDCChip.standard,
        features: [UInt8: Feature] = [
            VCPCode.brightness: Feature(current: 70, maximum: 100),
            VCPCode.contrast: Feature(current: 60, maximum: 100),
            VCPCode.volume: Feature(current: 30, maximum: 100)
        ],
        unsupported: Set<UInt8> = [],
        behavior: Behavior = .normal,
        edid: [UInt8]? = nil
    ) {
        self.acceptedChip = acceptedChip
        self.features = features
        self.unsupported = unsupported
        self.behavior = behavior
        self.edidBytes = edid
        if case let .nullFirst(count) = behavior { nullsLeft = count }
    }

    public let acceptedChip: UInt8

    public var writes: [Write] { lock.withLock { recordedWrites } }
    /// The chip of every read, in order.
    public var readChips: [UInt8] { lock.withLock { recordedReadChips } }
    /// Every "Set VCP" the monitor accepted (right chip, valid checksum), in order.
    public var setCommands: [(code: UInt8, value: UInt16)] { lock.withLock { appliedSets } }

    public func feature(_ code: UInt8) -> Feature? { lock.withLock { features[code] } }

    public func setBehavior(_ behavior: Behavior) {
        lock.withLock {
            self.behavior = behavior
            if case let .nullFirst(count) = behavior { nullsLeft = count }
        }
    }

    public func write(chip: UInt8, offset: UInt8, bytes: [UInt8]) -> Bool {
        lock.withLock {
            recordedWrites.append(Write(chip: chip, offset: offset, bytes: bytes))
            if behavior == .refusesWrites { return false }
            guard chip == acceptedChip, offset == DDCPacket.dataAddress, bytes.count >= 4 else { return true }
            let frame = Array(bytes.dropLast())
            guard DDCPacket.checksum(of: frame) == bytes.last else { return true }
            switch (bytes[0], bytes[1]) {
            case (0x82, 0x01):
                pendingCode = bytes[2]
            case (0x84, 0x03) where bytes.count == 6:
                let value = UInt16(bytes[3]) << 8 | UInt16(bytes[4])
                appliedSets.append((bytes[2], value))
                features[bytes[2]]?.current = value
            default:
                break
            }
            return true
        }
    }

    public func read(chip: UInt8, offset: UInt8, count: Int) -> [UInt8]? {
        lock.withLock {
            if chip == DDCChip.edid {
                guard let edidBytes else { return nil }
                return Array((edidBytes + [UInt8](repeating: 0, count: count)).prefix(count))
            }
            recordedReadChips.append(chip)
            let null: [UInt8] = [0x6E, 0x80, 0xBE] + [UInt8](repeating: 0, count: max(count - 3, 0))
            switch behavior {
            case .alwaysNull:
                return null
            case .silent:
                return [UInt8](repeating: 0, count: count)
            case .nullFirst where nullsLeft > 0:
                nullsLeft -= 1
                return null
            default:
                break
            }
            guard chip == acceptedChip, let code = pendingCode else { return null }
            var reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, code, 0x00, 0, 0, 0, 0]
            if unsupported.contains(code) || features[code] == nil {
                reply[3] = 0x01
            } else if let feature = features[code] {
                reply[6] = UInt8(feature.maximum >> 8)
                reply[7] = UInt8(feature.maximum & 0xFF)
                reply[8] = UInt8(feature.current >> 8)
                reply[9] = UInt8(feature.current & 0xFF)
            }
            var checksum: UInt8 = 0x50
            reply.forEach { checksum ^= $0 }
            reply.append(behavior == .badChecksum ? checksum ^ 0xFF : checksum)
            if behavior == .shifted { reply.insert(0x00, at: 0) }
            return Array((reply + [UInt8](repeating: 0, count: count)).prefix(count))
        }
    }
}

/// An EDID base block for tests, built from made-up numbers: the 8-byte header, the manufacturer, product code,
/// serial, a product-name descriptor, and the checksum byte that makes the 128 bytes sum to 0.
public enum SimulatedEDID {
    public static func make(vendorLetters: String = "ABC", model: UInt16 = 0x1234, serial: UInt32 = 0x0102_0304, name: String = "Test Monitor") -> [UInt8] {
        var block = [UInt8](repeating: 0, count: EDID.length)
        block.replaceSubrange(0..<8, with: [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00])
        let letters = vendorLetters.uppercased().utf8.prefix(3).map { UInt16($0 - 64) }
        let packed = letters.count == 3 ? letters[0] << 10 | letters[1] << 5 | letters[2] : 0
        block[8] = UInt8(packed >> 8)
        block[9] = UInt8(packed & 0xFF)
        block[10] = UInt8(model & 0xFF)
        block[11] = UInt8(model >> 8)
        block[12] = UInt8(serial & 0xFF)
        block[13] = UInt8((serial >> 8) & 0xFF)
        block[14] = UInt8((serial >> 16) & 0xFF)
        block[15] = UInt8(serial >> 24)
        // Descriptor at 54: tag 0xFC, the name, a line feed, then spaces.
        block[57] = 0xFC
        let text = Array(name.utf8.prefix(12)) + [0x0A]
        let padded = text + [UInt8](repeating: 0x20, count: 13 - text.count)
        block.replaceSubrange(59..<72, with: padded)
        block[127] = 0 &- block[0..<127].reduce(UInt8(0), { $0 &+ $1 })
        return block
    }
}

/// A fixed list of displays and the DDC connections they have, for tests and the screenshot renderer.
public struct SimulatedDisplayInventory: DisplayInventory {
    public var displays: [DisplayDescriptor]
    public var links: [UInt32: DDCLink]

    public init(displays: [DisplayDescriptor], links: [UInt32: DDCLink]) {
        self.displays = displays
        self.links = links
    }

    @MainActor
    public func onlineDisplays() -> [DisplayDescriptor] { displays }

    public func ddcLinks(for displays: [DisplayDescriptor]) -> [UInt32: DDCLink] {
        links.filter { id, _ in displays.contains { $0.id == id } }
    }
}

/// DisplayServices on made-up displays: it can change the brightness of the ones in `controllable`.
public final class SimulatedDisplayServices: DisplayServicesControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt32: Double]
    private var writes: [(display: UInt32, value: Double)] = []

    public init(controllable: [UInt32: Double] = [:]) {
        values = controllable
    }

    public var setCalls: [(display: UInt32, value: Double)] { lock.withLock { writes } }

    public func canChangeBrightness(of display: UInt32) -> Bool {
        lock.withLock { values[display] != nil }
    }

    public func brightness(of display: UInt32) -> Double? {
        lock.withLock { values[display] }
    }

    @discardableResult
    public func setBrightness(_ value: Double, of display: UInt32) -> Bool {
        lock.withLock {
            guard values[display] != nil else { return false }
            values[display] = value
            writes.append((display, value))
            return true
        }
    }
}

/// Gamma tables of made-up displays, in memory.
public final class SimulatedGamma: GammaControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var tables: [UInt32: GammaTable]
    private var applied: [(display: UInt32, table: GammaTable)] = []

    /// Each display in `displays` starts with a straight ramp of 256 entries.
    public init(displays: [UInt32] = []) {
        let ramp = (0..<256).map { Float($0) / 255 }
        tables = Dictionary(uniqueKeysWithValues: displays.map { ($0, GammaTable(red: ramp, green: ramp, blue: ramp)) })
    }

    public func table(for display: UInt32) -> GammaTable? { lock.withLock { tables[display] } }

    public var appliedTables: [(display: UInt32, table: GammaTable)] { lock.withLock { applied } }

    @discardableResult
    public func apply(_ table: GammaTable, to display: UInt32) -> Bool {
        lock.withLock {
            guard tables[display] != nil else { return false }
            tables[display] = table
            applied.append((display, table))
            return true
        }
    }
}
