import Foundation

/// JSON response schema returned by DNS-over-HTTPS endpoints (RFC 8427 / Cloudflare / Google / AdGuard).
public struct DoHJSONResponse: Codable, Sendable {
    public struct Answer: Codable, Sendable {
        public let name: String
        public let type: Int
        public let TTL: Int?
        public let data: String
    }

    public let Status: Int
    public let Answer: [Answer]?
}

/// Thread-safe in-memory DNS cache actor for Swift 6 strict concurrency.
actor DNSCache {
    private var entries: [String: (ip: String, expiry: Date)] = [:]
    private let maxEntries: Int

    /// A long-running shield resolves a new name for every site visited; without a bound the cache only grows.
    init(maxEntries: Int = 2048) {
        self.maxEntries = maxEntries
    }

    var count: Int { entries.count }

    func get(domain: String) -> String? {
        if let cached = entries[domain], cached.expiry > Date() {
            return cached.ip
        }
        return nil
    }

    func set(domain: String, ip: String, ttl: TimeInterval = 300) {
        entries[domain] = (ip: ip, expiry: Date().addingTimeInterval(ttl))
        if entries.count > maxEntries {
            evictOverflow()
        }
    }

    /// Drops expired entries, then the ones closest to expiring, until the cache fits again.
    private func evictOverflow() {
        let now = Date()
        entries = entries.filter { $0.value.expiry > now }
        let overflow = entries.count - maxEntries
        guard overflow > 0 else { return }
        for key in entries.sorted(by: { $0.value.expiry < $1.value.expiry }).prefix(overflow).map(\.key) {
            entries.removeValue(forKey: key)
        }
    }

    func clear() {
        entries.removeAll()
    }
}

/// Protocol defining DNS-over-HTTPS asynchronous hostname resolution.
public protocol DoHResolverProtocol: Sendable {
    func resolve(domain: String, provider: DoHProvider) async throws -> String
}

/// Thread-safe DoH resolver that shields domain lookups from ISP surveillance.
public final class DoHResolver: DoHResolverProtocol, Sendable {
    public static let shared = DoHResolver()

    private let session: URLSession
    private let cache = DNSCache()
    private let allowsHostNameFallback: Bool

    /// - Parameter allowsHostNameFallback: When a request to a provider's bootstrap address fails to connect, retry
    ///   it by host name (which uses the system resolver). Tests turn it off to prove the address alone is enough.
    public init(session: URLSession? = nil, allowsHostNameFallback: Bool = true) {
        self.allowsHostNameFallback = allowsHostNameFallback
        if let session = session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.connectionProxyDictionary = [:] // Explicitly bypass all system proxies
            config.timeoutIntervalForRequest = 4.0
            config.timeoutIntervalForResource = 8.0
            self.session = URLSession(configuration: config)
        }

        // Bootstrap known DoH server domain names with their direct Anycast IPs
        Task {
            await bootstrapKnownEndpoints()
        }
    }

    /// Clears the in-memory DNS cache and re-bootstraps known endpoints.
    public func clearCache() async {
        await cache.clear()
        await bootstrapKnownEndpoints()
    }

    private func bootstrapKnownEndpoints() async {
        await cache.set(domain: "cloudflare-dns.com", ip: "1.1.1.1", ttl: 86400)
        await cache.set(domain: "one.one.one.one", ip: "1.1.1.1", ttl: 86400)
        await cache.set(domain: "dns.google", ip: "8.8.8.8", ttl: 86400)
        await cache.set(domain: "dns.quad9.net", ip: "9.9.9.9", ttl: 86400)
        await cache.set(domain: "dns.adguard-dns.com", ip: "94.140.14.14", ttl: 86400)
        await cache.set(domain: "dns.nextdns.io", ip: "45.90.28.0", ttl: 86400)
    }

    /// Resolves a domain name to an IPv4 address string (or an IPv6 one for hosts with no A record)
    /// using the designated DoH provider.
    public func resolve(domain: String, provider: DoHProvider = .cloudflare) async throws -> String {
        let cleanDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if case .custom(let url, let bootstrapIP) = provider, let ip = bootstrapIP, let host = url.host {
            await cache.set(domain: host, ip: ip, ttl: 86400)
        }

        // 1. Direct return if hostname is already a literal IP address
        if isIPAddress(cleanDomain) {
            return cleanDomain
        }

        // 2. Check local in-memory cache: the resolvers' own addresses (bootstrap, any provider), then this
        // provider's answers. Answers are kept per provider because they differ: a filtering resolver answers
        // `0.0.0.0` for a name another one resolves, and a never-blocked name is asked of an unfiltered one.
        if let bootstrapIP = await cache.get(domain: cleanDomain) {
            return bootstrapIP
        }
        let cacheKey = provider.id + "|" + cleanDomain
        if let cachedIP = await cache.get(domain: cacheKey) {
            return cachedIP
        }

        // 3. Query DoH endpoint
        let resolvedIP = try await queryDoH(domain: cleanDomain, provider: provider)

        // 4. Cache valid resolution for 5 minutes (300 seconds default TTL)
        await cache.set(domain: cacheKey, ip: resolvedIP, ttl: 300)

        return resolvedIP
    }

    /// Whether a resolver's answer means "blocked": filtering resolvers (AdGuard DNS, NextDNS) answer an ad or tracker
    /// name with the unspecified address, `0.0.0.0` or `::`. Connecting there would reach this Mac itself.
    public static func isBlockingAnswer(_ address: String) -> Bool {
        let clean = address.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).lowercased()
        var v4 = in_addr()
        if inet_pton(AF_INET, clean, &v4) == 1 {
            return v4.s_addr == 0
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, clean, &v6) == 1 {
            // `::`, and `::ffff:0.0.0.0` (the IPv4-mapped form of 0.0.0.0), which reaches this Mac just the same.
            return withUnsafeBytes(of: &v6) { bytes in
                bytes.allSatisfy { $0 == 0 }
                    || (bytes[0..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xff && bytes[11] == 0xff
                        && bytes[12..<16].allSatisfy { $0 == 0 })
            }
        }
        return false
    }

    private func queryDoH(domain: String, provider: DoHProvider) async throws -> String {
        // IPv4 first; hosts that only publish AAAA records (IPv6-only sites and networks) fall back to IPv6.
        if let ipv4 = try await queryRecord(domain: domain, provider: provider, recordType: 1) {
            return ipv4
        }
        if let ipv6 = try await queryRecord(domain: domain, provider: provider, recordType: 28) {
            return ipv6
        }

        throw NSError(
            domain: "DoHResolver",
            code: 404,
            userInfo: [NSLocalizedDescriptionKey: "No IPv4 or IPv6 address found for domain \(domain)"]
        )
    }

    /// Queries one record type (1 = A, 28 = AAAA) and returns the first valid address, or `nil` when there is none.
    private func queryRecord(domain: String, provider: DoHProvider, recordType: Int) async throws -> String? {
        switch provider.queryFormat {
        case .json:
            return try await queryJSON(domain: domain, provider: provider, recordType: recordType)
        case .wire:
            return try await queryWire(domain: domain, provider: provider, recordType: recordType)
        case .jsonThenWire:
            // A custom endpoint may speak either. Anything but a clean JSON answer (typically HTTP 400 from a
            // server that only knows the binary format) is retried in binary.
            do {
                return try await queryJSON(domain: domain, provider: provider, recordType: recordType)
            } catch is URLError {
                return try await queryWire(domain: domain, provider: provider, recordType: recordType)
            } catch is DecodingError {
                return try await queryWire(domain: domain, provider: provider, recordType: recordType)
            }
        }
    }

    private func queryJSON(domain: String, provider: DoHProvider, recordType: Int) async throws -> String? {
        // Construct DoH JSON endpoint URL
        var components = URLComponents(url: provider.endpointURL, resolvingAgainstBaseURL: false)
        var items = components?.queryItems ?? []
        items.append(URLQueryItem(name: "name", value: domain))
        items.append(URLQueryItem(name: "type", value: recordType == 28 ? "AAAA" : "A"))
        components?.queryItems = items

        guard let queryURL = components?.url else {
            throw URLError(.badURL)
        }

        let (data, httpResponse) = try await fetch(queryURL, provider: provider, accept: "application/dns-json")

        guard httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let decoded = try JSONDecoder().decode(DoHJSONResponse.self, from: data)

        // Type 1 is a DNS A record (IPv4), type 28 an AAAA record (IPv6)
        if let answers = decoded.Answer {
            for answer in answers where answer.type == recordType {
                let candidate = answer.data.trimmingCharacters(in: .whitespacesAndNewlines)
                if recordType == 28 ? isIPv6Address(candidate) : isIPv4Address(candidate) {
                    return candidate
                }
            }
        }
        return nil
    }

    /// Sends the GET. With a bootstrap address the connection goes to that address, the `Host` header names the real
    /// server and the certificate is checked against the real name, so no system DNS lookup of the server happens.
    private func fetch(_ url: URL, provider: DoHProvider, accept: String) async throws -> (Data, HTTPURLResponse) {
        func perform(_ url: URL, hostHeader: String?, delegate: URLSessionTaskDelegate?) async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue(accept, forHTTPHeaderField: "Accept")
            if let hostHeader { request.setValue(hostHeader, forHTTPHeaderField: "Host") }
            request.timeoutInterval = 4.0
            let (data, response) = try await session.data(for: request, delegate: delegate)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            return (data, http)
        }

        if let host = url.host, !isIPAddress(host), let address = provider.bootstrapAddress,
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.host = address
            if let addressURL = components.url {
                do {
                    return try await perform(addressURL, hostHeader: host, delegate: HostNameTrustDelegate(expectedHost: host))
                } catch let error as URLError where allowsHostNameFallback && error.code != .cancelled {
                    NSLog("[DoH] Bootstrap address %@ for %@ failed (%@); falling back to the host name", address, host, "\(error.code.rawValue)")
                } catch let error as URLError where allowsHostNameFallback && error.code == .cancelled {
                    // A certificate that does not match the name is reported as a cancelled challenge. That is a
                    // reason to stop, not to ask the system resolver for another address for the same name.
                    throw error
                }
            }
        }
        return try await perform(url, hostHeader: nil, delegate: nil)
    }

    /// RFC 8484 GET with the binary query in the `dns` parameter.
    private func queryWire(domain: String, provider: DoHProvider, recordType: Int) async throws -> String? {
        guard let message = DoHWireFormat.makeQuery(domain: domain, recordType: UInt16(recordType)) else {
            throw URLError(.badURL)
        }
        var components = URLComponents(url: provider.endpointURL, resolvingAgainstBaseURL: false)
        var items = components?.queryItems ?? []
        items.append(URLQueryItem(name: "dns", value: DoHWireFormat.base64URL(message)))
        components?.queryItems = items
        guard let queryURL = components?.url else {
            throw URLError(.badURL)
        }

        let (data, httpResponse) = try await fetch(queryURL, provider: provider, accept: "application/dns-message")
        guard httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return DoHWireFormat.firstAddress(in: data, recordType: UInt16(recordType))
    }

    /// Validates whether a given string is a literal IPv4 or IPv6 address.
    public func isIPAddress(_ str: String) -> Bool {
        isIPv4Address(str) || str.contains(":")
    }

    /// Validates standard IPv6 colon-hex notation.
    public func isIPv6Address(_ str: String) -> Bool {
        var sin6 = sockaddr_in6()
        return str.withCString { cstr in
            inet_pton(AF_INET6, cstr, &sin6.sin6_addr) == 1
        }
    }

    /// Validates standard IPv4 dotted notation.
    public func isIPv4Address(_ str: String) -> Bool {
        var sin = sockaddr_in()
        return str.withCString { cstr in
            inet_pton(AF_INET, cstr, &sin.sin_addr) == 1
        }
    }
}

/// Evaluates a server certificate against the host name the request is really for, when the connection was made to an
/// IP address. (The default evaluation would compare the certificate with the IP.)
final class HostNameTrustDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let expectedHost: String

    init(expectedHost: String) {
        self.expectedHost = expectedHost
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, expectedHost as CFString))
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else {
            return (.cancelAuthenticationChallenge, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}
