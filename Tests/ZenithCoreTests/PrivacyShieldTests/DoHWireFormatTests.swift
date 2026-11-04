import Testing
import Foundation
@testable import ZenithCore

/// Answers DoH requests from memory, speaking JSON or the binary format depending on the host:
/// `wire-only.test` rejects JSON queries with 400 (as Quad9 does), `json-only.test` rejects binary ones.
final class StubWireDoHProtocol: URLProtocol {
    static let paths = PathLog()

    final class PathLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        func record(_ entry: String) { lock.withLock { entries.append(entry) } }
        func all() -> [String] { lock.withLock { entries } }
    }

    /// A response message for `question` (the query bytes) with one answer of `type` carrying `rdata`.
    static func message(for question: Data, type: UInt16, rdata: [UInt8]) -> Data {
        var bytes: [UInt8] = [0x00, 0x00, 0x81, 0x80, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]
        bytes.append(contentsOf: question.dropFirst(12))                                   // the question, echoed
        bytes.append(contentsOf: [0xC0, 0x0C])                                             // name: pointer to the question
        let typeBytes: [UInt8] = [UInt8(type >> 8), UInt8(type & 0xFF)]
        bytes.append(contentsOf: typeBytes)
        bytes.append(contentsOf: [0x00, 0x01] as [UInt8])
        bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x3C])                                 // TTL 60
        bytes.append(contentsOf: [0x00, UInt8(rdata.count)])
        bytes.append(contentsOf: rdata)
        return Data(bytes)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        // The server a request is really for: the Host header when the connection goes to a bootstrap address.
        let host = request.value(forHTTPHeaderField: "Host") ?? url.host ?? ""
        Self.paths.record("\(host)\(url.path)?\(items.first?.name ?? "")|\(url.host ?? "")")

        var status = 200
        var body = Data()
        if let dns = items.first(where: { $0.name == "dns" })?.value {
            if host == "json-only.test" {
                status = 400
            } else {
                var padded = dns.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                while padded.count % 4 != 0 { padded += "=" }
                let question = Data(base64Encoded: padded) ?? Data()
                // The question ends with the type (2 bytes) and the class (2 bytes).
                let tail = [UInt8](question.suffix(4))
                let type: UInt16 = tail.count == 4 ? UInt16(tail[0]) * 256 + UInt16(tail[1]) : 1
                body = type == 28
                    ? Self.message(for: question, type: 28, rdata: [0x26, 0x06, 0x47, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0x68, 0x10, 0x84, 0xE5])
                    : Self.message(for: question, type: 1, rdata: [93, 184, 216, 34])
            }
        } else if host == "wire-only.test" {
            status = 400
            body = Data("no 'dns' query parameter found".utf8)
        } else {
            body = Data(#"{"Status":0,"Answer":[{"name":"x","type":1,"TTL":60,"data":"203.0.113.7"}]}"#.utf8)
        }

        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("DoH Binary Format and Provider Endpoints Suite")
struct DoHWireFormatTests {

    private func makeResolver() -> DoHResolver {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubWireDoHProtocol.self]
        return DoHResolver(session: URLSession(configuration: config))
    }

    @Test("DOHW-01: A query is a well-formed DNS message: header, labels, type, class")
    func testQueryEncoding() throws {
        let query = try #require(DoHWireFormat.makeQuery(domain: "www.example.com", recordType: 28))
        let header: [UInt8] = [0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0]
        // Spelled out step by step: one long `+` chain is more than Swift 6.1's type checker will take.
        var question: [UInt8] = []
        question.append(3)
        question.append(contentsOf: Array("www".utf8))
        question.append(7)
        question.append(contentsOf: Array("example".utf8))
        question.append(3)
        question.append(contentsOf: Array("com".utf8))
        question.append(contentsOf: [0, 0, 28, 0, 1] as [UInt8])
        #expect([UInt8](query.prefix(12)) == header)
        #expect([UInt8](query.dropFirst(12)) == question)
        #expect(DoHWireFormat.base64URL(Data([0xFB, 0xFF, 0xFE])) == "-__-")
        #expect(DoHWireFormat.makeQuery(domain: "", recordType: 1) == nil)
        #expect(DoHWireFormat.makeQuery(domain: String(repeating: "a", count: 64) + ".com", recordType: 1) == nil)
    }

    @Test("DOHW-02: Addresses are read out of a response, through name compression")
    func testResponseParsing() throws {
        let query = try #require(DoHWireFormat.makeQuery(domain: "example.com", recordType: 1))
        let v4 = StubWireDoHProtocol.message(for: query, type: 1, rdata: [93, 184, 216, 34])
        #expect(DoHWireFormat.firstAddress(in: v4, recordType: 1) == "93.184.216.34")
        #expect(DoHWireFormat.firstAddress(in: v4, recordType: 28) == nil)

        let v6 = StubWireDoHProtocol.message(for: query, type: 28, rdata: [0x26, 0x06, 0x47, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x68, 0x10, 0x84, 0xE5])
        #expect(DoHWireFormat.firstAddress(in: v6, recordType: 28) == "2606:4700::6810:84e5")
    }

    @Test("DOHW-03: Errors and damaged messages give no address instead of crashing")
    func testMalformedResponses() throws {
        let query = try #require(DoHWireFormat.makeQuery(domain: "example.com", recordType: 1))
        var good = [UInt8](StubWireDoHProtocol.message(for: query, type: 1, rdata: [1, 2, 3, 4]))

        var nxdomain = good
        nxdomain[3] = 0x83                                                   // rcode 3
        #expect(DoHWireFormat.firstAddress(in: Data(nxdomain), recordType: 1) == nil)

        for cut in [0, 5, 11, 12, 20, good.count - 3, good.count - 1] {       // truncated anywhere
            #expect(DoHWireFormat.firstAddress(in: Data(good.prefix(cut)), recordType: 1) == nil)
        }

        good[good.count - 5] = 0x40                                          // an rdata length longer than the message
        #expect(DoHWireFormat.firstAddress(in: Data(good), recordType: 1) == nil)
        #expect(DoHWireFormat.firstAddress(in: Data([UInt8](repeating: 0xC0, count: 64)), recordType: 1) == nil)
    }

    @Test("DOHW-04: Google and AdGuard are asked on /resolve, where their JSON API is; Quad9 in binary")
    func testProviderEndpoints() {
        #expect(DoHProvider.google.endpointURL.absoluteString == "https://dns.google/resolve")
        #expect(DoHProvider.adguard.endpointURL.absoluteString == "https://dns.adguard-dns.com/resolve")
        #expect(DoHProvider.cloudflare.endpointURL.absoluteString == "https://1.1.1.1/dns-query")
        #expect(DoHProvider.quad9.queryFormat == .wire)
        #expect(DoHProvider.cloudflare.queryFormat == .json)
        #expect(DoHProvider.custom(url: URL(string: "https://x.test/dns-query")!, bootstrapIP: nil).queryFormat == .jsonThenWire)
    }

    @Test("DOHW-05: A binary-only endpoint is resolved (A, then AAAA) without any JSON query")
    func testBinaryOnlyProvider() async throws {
        let resolver = makeResolver()
        let provider = DoHProvider.custom(url: URL(string: "https://json-only.test/dns-query")!, bootstrapIP: nil)
        _ = provider
        let address = try await resolver.resolve(domain: "wire-direct.test", provider: .quad9)
        #expect(address == "93.184.216.34")
        #expect(StubWireDoHProtocol.paths.all().contains("dns.quad9.net/dns-query?dns|9.9.9.9"))
    }

    @Test("DOHW-06: A custom endpoint that only speaks binary is retried in binary after JSON is refused")
    func testCustomFallsBackToBinary() async throws {
        let resolver = makeResolver()
        let provider = DoHProvider.custom(url: URL(string: "https://wire-only.test/dns-query")!, bootstrapIP: nil)
        let address = try await resolver.resolve(domain: "fallback.test", provider: provider)
        #expect(address == "93.184.216.34")
    }

    @Test("DOHW-07: A custom endpoint that only speaks JSON is answered in JSON, with no binary query")
    func testCustomJSONStaysJSON() async throws {
        let resolver = makeResolver()
        let provider = DoHProvider.custom(url: URL(string: "https://json-only.test/dns-query")!, bootstrapIP: nil)
        let address = try await resolver.resolve(domain: "plain-json.test", provider: provider)
        #expect(address == "203.0.113.7")
        #expect(!StubWireDoHProtocol.paths.all().contains { $0.hasPrefix("json-only.test/dns-query?dns") })
    }

    @Test("DOHW-08: With a bootstrap address the request goes to the address, naming the server in Host")
    func testBootstrapAddressIsConnectedTo() async throws {
        let resolver = makeResolver()
        let provider = DoHProvider.custom(url: URL(string: "https://json-only.test/dns-query")!, bootstrapIP: "198.51.100.9")
        _ = try await resolver.resolve(domain: "bootstrap.test", provider: provider)
        #expect(StubWireDoHProtocol.paths.all().contains("json-only.test/dns-query?name|198.51.100.9"))

        // Without one (and for Cloudflare, whose endpoint already is an address) the host name is used as is.
        let plain = DoHProvider.custom(url: URL(string: "https://json-only.test/dns-query")!, bootstrapIP: nil)
        _ = try await resolver.resolve(domain: "plain.test", provider: plain)
        #expect(StubWireDoHProtocol.paths.all().contains("json-only.test/dns-query?name|json-only.test"))
        #expect(DoHProvider.cloudflare.bootstrapAddress == nil)
    }

    @Test("DOHW-09: Built-in providers with a host name have a bootstrap address; so does a custom one, unless blank")
    func testBootstrapAddresses() {
        #expect(DoHProvider.google.bootstrapAddress == "8.8.8.8")
        #expect(DoHProvider.quad9.bootstrapAddress == "9.9.9.9")
        #expect(DoHProvider.custom(url: URL(string: "https://x.test/q")!, bootstrapIP: " 10.1.2.3 ").bootstrapAddress == "10.1.2.3")
        #expect(DoHProvider.custom(url: URL(string: "https://x.test/q")!, bootstrapIP: "  ").bootstrapAddress == nil)
        #expect(DoHProvider.custom(url: URL(string: "https://x.test/q")!, bootstrapIP: nil).bootstrapAddress == nil)
    }
}
