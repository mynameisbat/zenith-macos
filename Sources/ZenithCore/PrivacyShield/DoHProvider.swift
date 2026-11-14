import Foundation

/// Supported DNS-over-HTTPS (DoH) encrypted providers.
public enum DoHProvider: Identifiable, Sendable, Codable, Equatable, Hashable, CaseIterable {
    case cloudflare
    case adguard
    case google
    case quad9
    case nextdns(profileID: String)
    case custom(url: URL, bootstrapIP: String?)

    public var id: String {
        switch self {
        case .cloudflare: return "cloudflare"
        case .adguard: return "adguard"
        case .google: return "google"
        case .quad9: return "quad9"
        case .nextdns(let id): return "nextdns_\(id)"
        case .custom(let url, let ip): return "custom_\(url.absoluteString)_\(ip ?? "")"
        }
    }

    public static var allCases: [DoHProvider] {
        [
            .cloudflare,
            .adguard,
            .google,
            .quad9,
            .nextdns(profileID: ""),
            .custom(url: URL(string: "https://dns.quad9.net/dns-query")!, bootstrapIP: "9.9.9.9")
        ]
    }

    /// Whether the resolver itself answers ad and tracker names with `0.0.0.0` / `::` (DNS filtering).
    /// A NextDNS profile filters only what the user turned on there; without a profile nothing is filtered.
    public var blocksAdsItself: Bool {
        switch self {
        case .adguard: return true
        case .nextdns(let profileID): return !profileID.isEmpty
        case .cloudflare, .google, .quad9, .custom: return false
        }
    }

    /// The resolver to ask for a name on the never-block list, so that "Never Block" also wins over a filtering
    /// resolver, without sending the name to a company the user did not choose when there is a choice: unfiltered
    /// resolvers are asked as they are; AdGuard has an unfiltered twin; NextDNS answers unfiltered without a profile.
    /// Only a custom resolver (which may filter, and has no known twin) falls back to Cloudflare.
    public var neverBlockResolver: DoHProvider {
        switch self {
        case .cloudflare, .google, .quad9:
            return self
        case .adguard:
            return .custom(url: URL(string: "https://unfiltered.adguard-dns.com/resolve")!, bootstrapIP: "94.140.14.140")
        case .nextdns:
            return .nextdns(profileID: "")
        case .custom:
            return .cloudflare
        }
    }

    public var displayName: String {
        switch self {
        case .cloudflare:
            return String(localized: "Cloudflare (1.1.1.1)")
        case .adguard:
            return String(localized: "AdGuard DNS (Ad & Tracker Blocking)")
        case .google:
            return String(localized: "Google DNS (8.8.8.8)")
        case .quad9:
            return String(localized: "Quad9 (Malware Blocking)")
        case .nextdns(let profileID):
            return profileID.isEmpty ? String(localized: "NextDNS") : String(localized: "NextDNS (\(profileID))")
        case .custom:
            return String(localized: "Custom DoH")
        }
    }

    public var subtitle: String {
        switch self {
        case .cloudflare:
            return String(localized: "Fast Anycast resolver with strict privacy")
        case .adguard:
            return String(localized: "Blocks ads, trackers, and malicious domains")
        case .google:
            return String(localized: "High availability, globally distributed infrastructure")
        case .quad9:
            return String(localized: "Protects against malware and phishing websites")
        case .nextdns(let profileID):
            return profileID.isEmpty ? String(localized: "Cloud-based personal firewall and filtering") : String(localized: "NextDNS profile ID: \(profileID)")
        case .custom(let url, _):
            return url.absoluteString
        }
    }

    /// How the endpoint wants to be asked. Google and AdGuard serve their JSON API under `/resolve` and nothing but
    /// the binary format under `/dns-query`; Quad9 has no JSON API at all. A custom URL is tried as JSON first and
    /// then as binary (see `DoHResolver`).
    enum QueryFormat {
        case json
        case wire
        case jsonThenWire
    }

    var queryFormat: QueryFormat {
        switch self {
        case .cloudflare, .adguard, .google, .nextdns: return .json
        case .quad9: return .wire
        case .custom: return .jsonThenWire
        }
    }

    public var endpointURL: URL {
        switch self {
        case .cloudflare:
            return URL(string: "https://1.1.1.1/dns-query")!
        case .adguard:
            return URL(string: "https://dns.adguard-dns.com/resolve")!
        case .google:
            return URL(string: "https://dns.google/resolve")!
        case .quad9:
            return URL(string: "https://dns.quad9.net/dns-query")!
        case .nextdns(let profileID):
            let trimmed = profileID.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return URL(string: "https://dns.nextdns.io/dns-query")!
            }
            if let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
               let url = URL(string: "https://dns.nextdns.io/\(encoded)") {
                return url
            }
            return URL(string: "https://dns.nextdns.io/dns-query")!
        case .custom(let url, _):
            return url
        }
    }

    /// The address to connect to instead of looking up the endpoint's host name, or `nil` when the endpoint is already
    /// an address (Cloudflare) or no address is known. Looking the name up would send it to the system resolver in
    /// plain text, which defeats DoH for the lookup that matters most and fails on a network that blocks it.
    var bootstrapAddress: String? {
        switch self {
        case .cloudflare:
            return nil
        case .custom(_, let bootstrapIP):
            let trimmed = bootstrapIP?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        case .adguard, .google, .quad9, .nextdns:
            return directIP
        }
    }

    public var directIP: String {
        switch self {
        case .cloudflare:
            return "1.1.1.1"
        case .adguard:
            return "94.140.14.14"
        case .google:
            return "8.8.8.8"
        case .quad9:
            return "9.9.9.9"
        case .nextdns:
            return "45.90.28.0"
        case .custom(let url, let bootstrapIP):
            if let ip = bootstrapIP, !ip.isEmpty {
                return ip
            }
            if let host = url.host, !host.isEmpty {
                return host
            }
            return "1.1.1.1"
        }
    }

    // MARK: - Provider from what the user typed

    /// A custom provider from typed text, or nil when it cannot work: the address must be an `https` URL with a host
    /// (plain `http` would send the questions in the clear, which is what this feature exists to prevent), and a
    /// bootstrap address, when given, must be an IP address.
    public static func custom(urlString: String, bootstrapIP: String) -> DoHProvider? {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else { return nil }
        let bootstrap = bootstrapIP.trimmingCharacters(in: .whitespacesAndNewlines)
        if !bootstrap.isEmpty {
            var v4 = in_addr(), v6 = in6_addr()
            guard inet_pton(AF_INET, bootstrap, &v4) == 1 || inet_pton(AF_INET6, bootstrap, &v6) == 1 else { return nil }
        }
        return .custom(url: url, bootstrapIP: bootstrap.isEmpty ? nil : bootstrap)
    }

    /// A NextDNS provider from a typed profile ID, or nil when the ID has characters a profile ID never has (it goes
    /// into the URL path). An empty ID means NextDNS's generic endpoint.
    public static func nextDNS(profileID: String) -> DoHProvider? {
        let trimmed = profileID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return .nextdns(profileID: trimmed)
    }

    // MARK: - Codable Conformance with Legacy Fallback

    private enum CodingKeys: String, CodingKey {
        case cloudflare, adguard, google, quad9, nextdns, custom
    }

    private struct NextDNSPayload: Codable {
        let profileID: String
    }

    private struct CustomPayload: Codable {
        let url: URL
        let bootstrapIP: String?
    }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let str = try? single.decode(String.self) {
            switch str.lowercased() {
            case "cloudflare": self = .cloudflare; return
            case "adguard": self = .adguard; return
            case "google": self = .google; return
            case "quad9": self = .quad9; return
            default: break
            }
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.cloudflare) { self = .cloudflare }
        else if container.contains(.adguard) { self = .adguard }
        else if container.contains(.google) { self = .google }
        else if container.contains(.quad9) { self = .quad9 }
        else if let payload = try? container.decode(NextDNSPayload.self, forKey: .nextdns) {
            self = .nextdns(profileID: payload.profileID)
        } else if let payload = try? container.decode(CustomPayload.self, forKey: .custom) {
            self = .custom(url: payload.url, bootstrapIP: payload.bootstrapIP)
        } else {
            self = .cloudflare
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .cloudflare: try container.encodeNil(forKey: .cloudflare)
        case .adguard: try container.encodeNil(forKey: .adguard)
        case .google: try container.encodeNil(forKey: .google)
        case .quad9: try container.encodeNil(forKey: .quad9)
        case .nextdns(let profileID):
            try container.encode(NextDNSPayload(profileID: profileID), forKey: .nextdns)
        case .custom(let url, let bootstrapIP):
            try container.encode(CustomPayload(url: url, bootstrapIP: bootstrapIP), forKey: .custom)
        }
    }
}
