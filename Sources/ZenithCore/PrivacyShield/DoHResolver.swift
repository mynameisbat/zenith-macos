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

    public init(session: URLSession? = nil) {
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

        // 2. Check local in-memory cache
        if let cachedIP = await cache.get(domain: cleanDomain) {
            return cachedIP
        }

        // 3. Query DoH endpoint
        let resolvedIP = try await queryDoH(domain: cleanDomain, provider: provider)

        // 4. Cache valid resolution for 5 minutes (300 seconds default TTL)
        await cache.set(domain: cleanDomain, ip: resolvedIP, ttl: 300)

        return resolvedIP
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
        // Construct DoH JSON endpoint URL
        var components = URLComponents(url: provider.endpointURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "name", value: domain),
            URLQueryItem(name: "type", value: recordType == 28 ? "AAAA" : "A")
        ]

        guard let queryURL = components?.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: queryURL)
        request.httpMethod = "GET"
        request.setValue("application/dns-json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 4.0

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
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
