import Foundation

/// The waits DDC/CI needs between its steps, in seconds.
public struct DDCTiming: Sendable, Equatable {
    /// Before a request is written.
    public var beforeWrite: TimeInterval
    /// Between writing "Get VCP" and reading the answer (the standard asks for at least 40 ms).
    public var beforeRead: TimeInterval
    /// Between the repeats of a "Set VCP" (a display sometimes misses the first).
    public var betweenSets: TimeInterval
    /// How many times a "Set VCP" is written.
    public var setRepeats: Int
    /// How many times a read is tried before it is given up.
    public var readAttempts: Int

    public init(beforeWrite: TimeInterval, beforeRead: TimeInterval, betweenSets: TimeInterval, setRepeats: Int = 2, readAttempts: Int = 4) {
        self.beforeWrite = beforeWrite
        self.beforeRead = beforeRead
        self.betweenSets = betweenSets
        self.setRepeats = setRepeats
        self.readAttempts = readAttempts
    }

    public static let standard = DDCTiming(beforeWrite: 0.010, beforeRead: 0.050, betweenSets: 0.010)
    /// No waiting, for tests.
    public static let instant = DDCTiming(beforeWrite: 0, beforeRead: 0, betweenSets: 0)
}

/// What reading one VCP feature came to.
public enum DDCReadResult: Equatable, Sendable {
    case value(current: UInt16, maximum: UInt16)
    case unsupported
    /// No valid answer after every attempt.
    case failed

    /// The value as a share of the maximum, 0...1.
    public var fraction: Double? {
        guard case let .value(current, maximum) = self, maximum > 0 else { return nil }
        return min(max(Double(current) / Double(maximum), 0), 1)
    }
}

/// One display's DDC/CI conversation: reads and writes VCP features through a `DDCTransport`, choosing the I2C chip
/// address and falling back to the other one when the first only gets the null message.
///
/// Every call blocks (waits between steps and the bus itself): call them from a background queue, one at a time per
/// display. The chip that worked is remembered (`chip`, `isChipConfirmed`) so a later conversation starts right.
public final class DDCDevice: @unchecked Sendable {
    private let transport: any DDCTransport
    private let timing: DDCTiming
    private let lock = NSLock()
    private var currentChip: UInt8
    private var confirmed = false

    public init(transport: any DDCTransport, initialChip: UInt8, timing: DDCTiming = .standard) {
        self.transport = transport
        self.currentChip = initialChip
        self.timing = timing
    }

    /// The chip the next request is written to.
    public var chip: UInt8 { lock.withLock { currentChip } }
    /// Whether a real answer has come from `chip`.
    public var isChipConfirmed: Bool { lock.withLock { confirmed } }

    /// The display's EDID, if the bus gives a valid one.
    public func readEDID() -> EDID? {
        transport.read(chip: DDCChip.edid, offset: 0, count: EDID.length).flatMap { EDID(bytes: $0) }
    }

    /// Reads feature `code`: up to `timing.readAttempts` tries, until a value or "unsupported" comes back. While no
    /// chip has answered yet, each null message switches to the other chip (a sleeping monitor can answer null on the
    /// right one, so it may switch back); once a chip has answered it is never switched.
    public func read(_ code: UInt8) -> DDCReadResult {
        for _ in 0..<max(timing.readAttempts, 1) {
            let chip = self.chip
            pause(timing.beforeWrite)
            guard transport.write(chip: chip, offset: DDCPacket.dataAddress, bytes: DDCPacket.getRequest(code: code)) else {
                continue
            }
            pause(timing.beforeRead)
            guard let bytes = transport.read(chip: chip, offset: DDCPacket.dataAddress, count: DDCPacket.replyLength) else {
                continue
            }
            switch DDCPacket.decodeReply(bytes, code: code) {
            case let .value(current, maximum):
                lock.withLock { confirmed = true }
                return .value(current: current, maximum: maximum)
            case .unsupported:
                lock.withLock { confirmed = true }
                return .unsupported
            case .nullMessage:
                swapChipIfUnconfirmed()
            case .invalid:
                break
            }
        }
        return .failed
    }

    /// Writes `value` to feature `code` (repeated, as monitors sometimes miss one). Returns whether the bus took
    /// every write; it cannot say whether the display acted on it.
    @discardableResult
    public func write(_ code: UInt8, value: UInt16) -> Bool {
        let request = DDCPacket.setRequest(code: code, value: value)
        var accepted = true
        for attempt in 0..<max(timing.setRepeats, 1) {
            pause(attempt == 0 ? timing.beforeWrite : timing.betweenSets)
            if !transport.write(chip: chip, offset: DDCPacket.dataAddress, bytes: request) { accepted = false }
        }
        return accepted
    }

    private func swapChipIfUnconfirmed() {
        lock.withLock {
            guard !confirmed else { return }
            currentChip = DDCChip.alternative(to: currentChip)
        }
    }

    private func pause(_ seconds: TimeInterval) {
        if seconds > 0 { Thread.sleep(forTimeInterval: seconds) }
    }
}
