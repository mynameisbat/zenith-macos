import Foundation

/// The set of ad and tracker domains Privacy Shield refuses to connect to, and the domains the user never wants
/// blocked. Safe to read from the proxy's connection threads while the settings change it.
///
/// A listed domain blocks itself and every subdomain (`doubleclick.net` blocks `stats.g.doubleclick.net`). A domain
/// on the never-block list wins over any block entry, and it covers its subdomains too: never-blocking `example.com`
/// lets `ads.example.com` through even if that is listed. Never-block a narrower name to keep the rest blocked.
public final class TrackerBlocklist: @unchecked Sendable {
    private let lock = NSLock()
    private var blocked: Set<String> = []
    private var allowed: Set<String> = []

    public init(blocked: [String] = [], allowed: [String] = []) {
        update(blocked: blocked, allowed: allowed)
    }

    /// Replaces both lists. Entries that are not valid domains are dropped (see `normalize`).
    public func update(blocked newBlocked: [String], allowed newAllowed: [String]) {
        let blockedSet = Set(newBlocked.compactMap(Self.normalize))
        let allowedSet = Set(newAllowed.compactMap(Self.normalize))
        lock.lock()
        blocked = blockedSet
        allowed = allowedSet
        lock.unlock()
    }

    /// Replaces both lists with sets that are already clean (every entry went through `normalize`). A big imported list
    /// is cleaned once, when it is read; going through `update` again on every change made by hand would clean its
    /// 200 000 names each time.
    public func replace(normalizedBlocked: Set<String>, normalizedAllowed: Set<String>) {
        lock.lock()
        blocked = normalizedBlocked
        allowed = normalizedAllowed
        lock.unlock()
    }

    /// Adds one already-clean domain to the blocked set (a change by hand, which must not copy a huge list).
    public func insertBlocked(normalized domain: String) {
        lock.lock()
        blocked.insert(domain)
        lock.unlock()
    }

    /// Replaces only the never-block set with an already-clean one.
    public func replaceAllowed(normalized newAllowed: Set<String>) {
        lock.lock()
        allowed = newAllowed
        lock.unlock()
    }

    /// How many domains are blocked.
    public var blockedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return blocked.count
    }

    /// Whether a connection to `host` should be refused.
    public func isBlocked(host: String) -> Bool {
        let name = host.trimmingCharacters(in: CharacterSet(charactersIn: "[] .")).lowercased()
        // Addresses and one-word names (`localhost`, a printer) are never ad domains.
        guard name.contains("."), !Self.looksLikeAddress(name) else { return false }

        lock.lock()
        defer { lock.unlock() }
        guard !blocked.isEmpty else { return false }

        // The host itself first, then each parent, stopping before the last label (`com`).
        var candidate = Substring(name)
        var matchedBlock = false
        while candidate.contains(".") {
            let key = String(candidate)
            if allowed.contains(key) { return false }
            if blocked.contains(key) { matchedBlock = true }
            guard let dot = candidate.firstIndex(of: ".") else { break }
            candidate = candidate[candidate.index(after: dot)...]
        }
        return matchedBlock
    }

    // MARK: - Domain names

    /// A lowercase, valid domain, or nil. Accepts a leading `*.` or `.` and a trailing dot.
    ///
    /// Refused on purpose: a name with no dot (blocking `com` would block the internet), and a public suffix such as
    /// `co.uk` or `com.vn` (it would block every site under it). There is no full public-suffix list here, so the
    /// second case is the pattern `co|com|net|org|gov|edu|ac` + a two-letter country code.
    public static func normalize(_ raw: String) -> String? {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name.hasPrefix("*.") { name.removeFirst(2) }
        while name.hasPrefix(".") { name.removeFirst() }
        while name.hasSuffix(".") { name.removeLast() }
        guard !name.isEmpty, name.count <= 253, name.contains(".") else { return nil }

        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.contains(where: \.isEmpty) else { return nil }
        for label in labels {
            guard label.count <= 63, label.allSatisfy({ Self.domainCharacters.contains($0) }) else { return nil }
            guard !label.hasPrefix("-"), !label.hasSuffix("-") else { return nil }
        }
        if looksLikeAddress(name) { return nil }

        if labels.count == 2, Self.suffixLabels.contains(String(labels[0])), labels[1].count == 2 { return nil }
        return name
    }

    private static let domainCharacters = Set("abcdefghijklmnopqrstuvwxyz0123456789-_")
    private static let suffixLabels: Set<String> = ["co", "com", "net", "org", "gov", "edu", "ac"]

    /// Names that hosts files list for the machine itself. Nothing to block there.
    private static let machineNames: Set<String> = ["localhost.localdomain", "local"]

    /// The options of an ad-blocker rule that still mean "this whole domain": `||ads.example.com^$third-party`.
    /// A rule with any other option (`$script`, `$domain=…`) only covers some requests, so it is not a domain.
    private static let wholeDomainOptions: Set<Substring> = ["third-party", "3p", "all", "important"]

    private static func looksLikeAddress(_ name: String) -> Bool {
        name.allSatisfy { $0.isNumber || $0 == "." || $0 == ":" || ("a"..."f").contains($0) } && (
            name.contains(":") || name.split(separator: ".").allSatisfy { $0.allSatisfy(\.isNumber) }
        )
    }

    // MARK: - Hosts and ad-blocker lists

    /// The domains in a list. Understands the hosts format (`0.0.0.0 ads.example.com`, `127.0.0.1 …`), one domain per
    /// line, and `||ads.example.com^` rules; `#` and `!` comments are ignored. Lines it does not understand are
    /// skipped, and so are `localhost` and friends.
    public static func parseList(_ text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("!") || line.hasPrefix("[") { continue }
            if let hash = line.firstIndex(of: "#") { line = String(line[..<hash]).trimmingCharacters(in: .whitespaces) }

            var candidates: [String] = []
            if line.hasPrefix("||") {
                // `||ads.example.com^`, optionally followed by options. A `/` in it makes it a path rule, which covers
                // one URL and not the whole site.
                let body = line.dropFirst(2)
                guard let caret = body.firstIndex(of: "^") else { continue }
                let options = body[body.index(after: caret)...]
                if !options.isEmpty {
                    guard options.hasPrefix("$"),
                          options.dropFirst().split(separator: ",").allSatisfy({ wholeDomainOptions.contains($0) })
                    else { continue }
                }
                candidates = [String(body[..<caret])]
            } else {
                let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                if fields.count == 1 {
                    candidates = [fields[0]]
                } else if fields.count >= 2, ["0.0.0.0", "127.0.0.1", "::", "::1", "0"].contains(fields[0]) {
                    candidates = Array(fields.dropFirst())
                }
            }
            for candidate in candidates {
                guard let domain = normalize(candidate), !machineNames.contains(domain),
                      seen.insert(domain).inserted else { continue }
                result.append(domain)
            }
        }
        return result
    }
}

// MARK: - Built-in list

public extension TrackerBlocklist {
    /// A small starting list: advertising networks, ad exchanges and analytics endpoints that exist to serve ads or
    /// follow people between sites. Nothing on it is a site people visit, and it leaves out the hosts that sites need
    /// to work (CDNs, sign-in, payment, tag managers). Import a larger list from Settings for more.
    static let builtInDomains: [String] = [
        // Google advertising and analytics
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "google-analytics.com",
        "adservice.google.com", "2mdn.net", "app-measurement.com",
        // Ad exchanges and networks
        "adnxs.com", "adsrvr.org", "rubiconproject.com", "pubmatic.com", "openx.net", "casalemedia.com",
        "criteo.com", "criteo.net", "taboola.com", "outbrain.com", "amazon-adsystem.com", "adform.net",
        "smartadserver.com", "advertising.com", "yieldmo.com", "sharethrough.com", "teads.tv", "33across.com",
        "indexww.com", "bidswitch.net", "contextweb.com", "lijit.com", "zedo.com", "revcontent.com", "mgid.com",
        "serving-sys.com", "mookie1.com", "moatads.com", "adsymptotic.com",
        // Audience measurement and data brokers
        "scorecardresearch.com", "quantserve.com", "demdex.net", "omtrdc.net", "everesttech.net", "2o7.net",
        "krxd.net", "rlcdn.com", "bluekai.com", "mathtag.com", "tapad.com", "agkn.com",
        // Social-network ad and pixel endpoints
        "ads-twitter.com", "analytics.tiktok.com", "px.ads.linkedin.com", "snap.licdn.com", "ct.pinterest.com",
        "an.facebook.com", "ads.yahoo.com", "analytics.yahoo.com", "bat.bing.com", "clarity.ms",
        // Session recording and product analytics endpoints
        "static.hotjar.com", "script.hotjar.com", "vars.hotjar.com", "insights.hotjar.com",
        "rs.fullstory.com", "edge.fullstory.com", "api.mixpanel.com", "api-js.mixpanel.com"
    ]
}
