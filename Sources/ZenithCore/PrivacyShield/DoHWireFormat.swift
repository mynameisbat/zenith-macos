import Foundation

/// The binary DNS message format of RFC 8484 ("application/dns-message"), which every DoH server speaks.
/// Some of them (Quad9, for one) offer nothing else; the JSON API is a convenience that only some provide.
enum DoHWireFormat {
    /// A query for one record type (1 = A, 28 = AAAA), ready for the `dns` parameter of a GET request.
    static func makeQuery(domain: String, recordType: UInt16) -> Data? {
        var message = Data([
            0x00, 0x00,                 // ID: 0, as RFC 8484 recommends for cacheability
            0x01, 0x00,                 // flags: recursion desired
            0x00, 0x01,                 // one question
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00
        ])
        let labels = domain.split(separator: ".", omittingEmptySubsequences: true)
        guard !labels.isEmpty else { return nil }
        for label in labels {
            let bytes = Array(label.utf8)
            guard !bytes.isEmpty, bytes.count <= 63 else { return nil }
            message.append(UInt8(bytes.count))
            message.append(contentsOf: bytes)
        }
        message.append(0x00)
        message.append(contentsOf: [UInt8(recordType >> 8), UInt8(recordType & 0xFF), 0x00, 0x01]) // type, class IN
        return message
    }

    /// `base64url` without padding, as the `dns` query parameter requires.
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The first address of the wanted type in a response, or `nil` if there is none or the message is malformed.
    static func firstAddress(in response: Data, recordType: UInt16) -> String? {
        let bytes = [UInt8](response)
        guard bytes.count >= 12, bytes[3] & 0x0F == 0 else { return nil }     // rcode 0 = no error
        let questionCount = Int(bytes[4]) << 8 | Int(bytes[5])
        let answerCount = Int(bytes[6]) << 8 | Int(bytes[7])

        var offset = 12
        for _ in 0..<questionCount {
            guard let next = skipName(bytes, offset), next + 4 <= bytes.count else { return nil }
            offset = next + 4
        }
        for _ in 0..<answerCount {
            guard let afterName = skipName(bytes, offset), afterName + 10 <= bytes.count else { return nil }
            let type = UInt16(bytes[afterName]) << 8 | UInt16(bytes[afterName + 1])
            let length = Int(bytes[afterName + 8]) << 8 | Int(bytes[afterName + 9])
            let dataStart = afterName + 10
            guard dataStart + length <= bytes.count else { return nil }
            if type == recordType {
                if recordType == 1, length == 4 {
                    return bytes[dataStart..<dataStart + 4].map(String.init).joined(separator: ".")
                }
                if recordType == 28, length == 16 {
                    var address = in6_addr()
                    withUnsafeMutableBytes(of: &address) { $0.copyBytes(from: bytes[dataStart..<dataStart + 16]) }
                    var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                    guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else { return nil }
                    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                }
            }
            offset = dataStart + length
        }
        return nil
    }

    /// The offset just past a (possibly compressed) domain name, or `nil` if it runs off the message.
    private static func skipName(_ bytes: [UInt8], _ start: Int) -> Int? {
        var offset = start
        while offset < bytes.count {
            let length = Int(bytes[offset])
            if length == 0 { return offset + 1 }
            if length & 0xC0 == 0xC0 { return offset + 2 <= bytes.count ? offset + 2 : nil }   // pointer ends the name
            offset += length + 1
        }
        return nil
    }
}
