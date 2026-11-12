import Foundation

/// Removes tracking parameters (`utm_source`, `fbclid`, `gclid`, …) from a web link.
///
/// It works on the text itself rather than through `URLComponents`, so nothing it keeps is decoded or re-encoded: every
/// other parameter stays byte for byte and in its order, and the fragment is kept as it is (a query inside the
/// fragment, as single-page apps use, is not touched). Anything that is not one http(s) link comes back unchanged,
/// and cleaning a cleaned link changes nothing.
public enum TrackingLinkCleaner {
    /// Parameter names removed on every host (compared without case, after percent-decoding the name).
    public static let trackingParameters: Set<String> = [
        // Google Ads / Analytics
        "gclid", "gclsrc", "dclid", "wbraid", "gbraid", "_ga", "_gl", "srsltid",
        // Meta / Instagram
        "fbclid", "igshid", "igsh",
        // Microsoft, Yandex, X, TikTok, LinkedIn, Pinterest, Reddit
        "msclkid", "yclid", "twclid", "ttclid", "li_fat_id", "epik", "rdt_cid",
        // Mailchimp, HubSpot, Marketo, Vero, Openstat, Olytics
        "mc_cid", "mc_eid", "_hsenc", "_hsmi", "mkt_tok", "vero_id", "vero_conv", "_openstat",
        "oly_anon_id", "oly_enc_id"
    ]

    /// Prefixes removed on every host (`utm_source`, `utm_medium`, `utm_campaign`, …).
    public static let trackingPrefixes: [String] = ["utm_"]

    /// Parameters that are tracking only on some sites: elsewhere the same name can mean something.
    public static let hostSpecificParameters: [(domains: [String], names: Set<String>)] = [
        (["youtube.com", "youtu.be", "spotify.com", "spotify.link"], ["si"]),
        (["twitter.com", "x.com"], ["ref_src", "ref_url"])
    ]

    /// `string` without its tracking parameters, or `string` itself when there is nothing to remove or it is not a
    /// single http(s) link.
    public static func clean(_ string: String) -> String {
        cleanedIfChanged(string) ?? string
    }

    /// Whether `string` is an http(s) link with at least one tracking parameter.
    public static func containsTracking(_ string: String) -> Bool {
        cleanedIfChanged(string) != nil
    }

    /// The cleaned link, or nil when cleaning would change nothing.
    public static func cleanedIfChanged(_ string: String) -> String? {
        guard let host = webHost(of: string) else { return nil }

        // The fragment starts at the first "#"; the query is between the first "?" before it and the fragment.
        let fragmentStart = string.firstIndex(of: "#") ?? string.endIndex
        guard let questionMark = string[..<fragmentStart].firstIndex(of: "?") else { return nil }

        let base = string[..<questionMark]
        let query = string[string.index(after: questionMark)..<fragmentStart]
        let fragment = string[fragmentStart...]

        let pieces = query.split(separator: "&", omittingEmptySubsequences: false)
        let kept = pieces.filter { !isTracking(piece: $0, host: host) }
        guard kept.count != pieces.count else { return nil }

        var result = String(base)
        // Nothing meaningful left: drop the "?" too.
        if kept.contains(where: { !$0.isEmpty }) {
            result += "?" + kept.joined(separator: "&")
        }
        result += fragment
        return result
    }

    /// Whether `name` is a tracking parameter on `host` (a lowercased host name).
    public static func isTrackingParameter(_ name: String, host: String) -> Bool {
        let decoded = (name.removingPercentEncoding ?? name).lowercased()
        guard !decoded.isEmpty else { return false }
        if trackingParameters.contains(decoded) { return true }
        if trackingPrefixes.contains(where: { decoded.hasPrefix($0) && decoded.count > $0.count }) { return true }
        for rule in hostSpecificParameters where rule.names.contains(decoded) {
            if rule.domains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return true }
        }
        return false
    }

    private static func isTracking(piece: Substring, host: String) -> Bool {
        let name = piece.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first ?? piece
        return isTrackingParameter(String(name), host: host)
    }

    /// The lowercased host when `string` is one http(s) link (no spaces, a host after "//"), else nil.
    /// Parsed by hand: `URL(string:)` accepts different things on different macOS versions (non-ASCII hosts).
    static func webHost(of string: String) -> String? {
        guard string.utf8.count <= 8_192,
              string.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        let lower = string.lowercased()
        let afterScheme: String.Index
        if lower.hasPrefix("https://") {
            afterScheme = string.index(string.startIndex, offsetBy: 8)
        } else if lower.hasPrefix("http://") {
            afterScheme = string.index(string.startIndex, offsetBy: 7)
        } else {
            return nil
        }
        let rest = string[afterScheme...]
        let authorityEnd = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? rest.endIndex
        var authority = rest[..<authorityEnd]
        if let at = authority.lastIndex(of: "@") {
            authority = authority[authority.index(after: at)...]
        }
        // Drop a port, but not the colons of an IPv6 literal ("[::1]:8080").
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return nil }
            authority = authority[...close]
        } else if let colon = authority.firstIndex(of: ":") {
            authority = authority[..<colon]
        }
        let host = authority.lowercased()
        return host.isEmpty ? nil : host
    }
}
