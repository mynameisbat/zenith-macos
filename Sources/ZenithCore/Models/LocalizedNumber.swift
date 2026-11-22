import Foundation

/// Numbers shown to the user, written with the decimal separator of the user's region.
///
/// `String(format: "%.1f")` always writes a dot, while `ByteCountFormatter` follows the region, so one screen showed
/// "2,4 GB" beside "38.5%" on a Mac set to Vietnam. Use these instead of `String(format:)` for anything a person reads
/// (`String(format:locale: en_US_POSIX)` stays right for text another program parses, such as the adapter's `seek`).
public enum LocalizedNumber {
    /// `value` with exactly `fractionDigits` decimals and no digit grouping ("1023,5", never "1.023,5").
    public static func decimal(_ value: Double, fractionDigits: Int, locale: Locale = .autoupdatingCurrent) -> String {
        value.formatted(.number.precision(.fractionLength(fractionDigits)).grouping(.never).locale(locale))
    }

    /// A percentage given as 0–100 (`38.5` → "38.5%" / "38,5%" / "38,5 %"), the way the region writes it.
    public static func percent(_ value: Double, fractionDigits: Int = 1, locale: Locale = .autoupdatingCurrent) -> String {
        (value / 100).formatted(.percent.precision(.fractionLength(fractionDigits)).grouping(.never).locale(locale))
    }
}
