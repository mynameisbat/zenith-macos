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

    public var displayName: String {
        switch self {
        case .cloudflare:
            return "Cloudflare (1.1.1.1)"
        case .adguard:
            return "AdGuard DNS (Ad & Tracker Blocking)"
        case .google:
            return "Google DNS (8.8.8.8)"
        case .quad9:
            return "Quad9 (Malware Blocking)"
        case .nextdns(let profileID):
            return profileID.isEmpty ? "NextDNS" : "NextDNS (\(profileID))"
        case .custom:
            return "Custom DoH"
        }
    }

    public var subtitle: String {
        switch self {
        case .cloudflare:
            return "Fast Anycast resolver with strict privacy"
        case .adguard:
            return "Blocks ads, trackers, and malicious domains"
        case .google:
            return "High availability, globally distributed infrastructure"
        case .quad9:
            return "Protects against malware and phishing websites"
        case .nextdns(let profileID):
            return profileID.isEmpty ? "Cloud-based personal firewall and filtering" : "NextDNS profile ID: \(profileID)"
        case .custom(let url, _):
            return url.absoluteString
        }
    }

    public var endpointURL: URL {
        switch self {
        case .cloudflare:
            return URL(string: "https://1.1.1.1/dns-query")!
        case .adguard:
            return URL(string: "https://dns.adguard-dns.com/dns-query")!
        case .google:
            return URL(string: "https://dns.google/dns-query")!
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
