import Foundation

/// Result of evaluating an incoming TCP payload for TLS ClientHello packet mangling.
public struct TLSChunkingResult: Sendable, Equatable {
    public let isTLSClientHello: Bool
    public let firstChunk: Data
    public let secondChunk: Data?
}

/// Utility for detecting and fragmenting TLS ClientHello packets to circumvent Deep Packet Inspection (DPI).
public struct TLSClientHelloChunker: Sendable {
    public static let defaultChunkSize: Int = 2

    /// Inspects raw packet bytes. If it matches a TLS ClientHello handshake, splits it into two segments.
    public static func chunkPayload(_ data: Data, chunkSize: Int = defaultChunkSize) -> TLSChunkingResult {
        guard isTLSClientHello(data) else {
            return TLSChunkingResult(isTLSClientHello: false, firstChunk: data, secondChunk: nil)
        }

        let clampedChunkSize = max(1, min(chunkSize, data.count - 1))
        let first = data.prefix(clampedChunkSize)
        let second = data.dropFirst(clampedChunkSize)

        return TLSChunkingResult(
            isTLSClientHello: true,
            firstChunk: Data(first),
            secondChunk: Data(second)
        )
    }

    /// Validates whether the given data payload starts with a TLS Record Handshake (0x16) and ClientHello (0x01).
    public static func isTLSClientHello(_ data: Data) -> Bool {
        // Need at least 6 bytes:
        // Byte 0: ContentType (0x16 = Handshake)
        // Byte 1-2: Version (0x03, 0x01 ... 0x03, 0x03)
        // Byte 3-4: Length
        // Byte 5: HandshakeType (0x01 = ClientHello)
        guard data.count >= 6 else { return false }

        let contentType = data[data.startIndex]
        let versionMajor = data[data.startIndex + 1]
        let handshakeType = data[data.startIndex + 5]

        return contentType == 0x16 && versionMajor == 0x03 && handshakeType == 0x01
    }
}
