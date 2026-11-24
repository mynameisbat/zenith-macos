import Foundation

/// The I2C chip addresses a DDC/CI conversation uses.
public enum DDCChip {
    /// The standard DDC/CI address (the 7-bit 0x37 with the write bit).
    public static let standard: UInt8 = 0x37
    /// The address on a DisplayPort-to-HDMI bridge (Apple's `AppleDCPMCDP29XX`, the HDMI port of a MacBook Pro).
    public static let bridge: UInt8 = 0xB7
    /// Where a display keeps its EDID.
    public static let edid: UInt8 = 0x50

    /// The one to try when the first got no answer.
    public static func alternative(to chip: UInt8) -> UInt8 {
        chip == bridge ? standard : bridge
    }
}

/// A way to write bytes to, and read bytes from, an I2C device behind a display. The real one is
/// `IOAVServiceTransport`; tests use `SimulatedDDCMonitor`.
///
/// Both calls block for the time the bus needs (tens of milliseconds): never call them on the main thread.
public protocol DDCTransport: Sendable {
    /// Writes `bytes` to the device at `chip`, at `offset`. Returns whether the bus accepted them.
    func write(chip: UInt8, offset: UInt8, bytes: [UInt8]) -> Bool
    /// Reads `count` bytes from the device at `chip`, starting at `offset`; `nil` if the bus failed.
    func read(chip: UInt8, offset: UInt8, count: Int) -> [UInt8]?
}
