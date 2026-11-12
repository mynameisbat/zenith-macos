import Foundation

/// A release version such as `2.4.0`, parsed strictly because the text comes from the network.
///
/// Accepted: one optional leading `v`/`V`, then 1 to 4 dot-separated components of 1 to 6 ASCII digits each, 32
/// characters at most. Everything else (`2.4.0-beta`, `2.4.0 `, `２.4`, `2..4`, `+1`) is rejected rather than guessed
/// at. Missing components count as 0, so `2.4` == `2.4.0`, and comparison is numeric per component (2.10.0 > 2.9.9).
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public static let maximumLength = 32
    public static let maximumComponents = 4
    public static let maximumDigitsPerComponent = 6

    /// The numbers as written (`[2, 4, 0]`).
    public let components: [Int]

    public init?(_ text: String) {
        guard !text.isEmpty, text.utf8.count <= Self.maximumLength else { return nil }
        var body = Substring(text)
        if let first = body.first, first == "v" || first == "V" { body = body.dropFirst() }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...Self.maximumComponents).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            // ASCII digits only: `Character.isNumber` would also let through other scripts' digits.
            guard (1...Self.maximumDigitsPerComponent).contains(part.utf8.count),
                  part.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
                  let number = Int(part) else { return nil }
            numbers.append(number)
        }
        components = numbers
    }

    /// The version of the code that is running.
    public static var running: AppVersion {
        // `ZenithVersion.current` is a literal in this repository; a malformed one is a build mistake.
        AppVersion(ZenithVersion.current) ?? AppVersion(components: [0])
    }

    private init(components: [Int]) {
        self.components = components
    }

    /// Components without trailing zeros, so `2.4` and `2.4.0` are equal and hash alike.
    private var normalized: [Int] {
        var trimmed = components
        while trimmed.count > 1, trimmed.last == 0 { trimmed.removeLast() }
        return trimmed
    }

    /// `2.4.0`: digits and dots only, safe to show (never digit-grouped) and to build a file name from.
    public var description: String {
        components.map { String($0) }.joined(separator: ".")
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        lhs.normalized == rhs.normalized
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(normalized)
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}
