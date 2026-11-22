import Foundation

/// How worried a Command Hub gauge looks. The view maps it to a colour; the thresholds live here so they can be tested.
public enum HubGaugeLevel: Sendable, Equatable {
    case normal, warning, critical

    /// CPU: busy above 40 %, critical above 75 %.
    public static func cpu(percent: Double) -> HubGaugeLevel {
        percent > 75 ? .critical : (percent > 40 ? .warning : .normal)
    }

    /// Memory follows macOS's own pressure level, not the used percentage (a full cache is not a problem).
    public static func memory(pressure: MemoryPressureLevel) -> HubGaugeLevel {
        switch pressure {
        case .critical: return .critical
        case .warning: return .warning
        case .normal: return .normal
        }
    }

    /// The disk is critical above 90 % used.
    public static func disk(usedPercent: Double) -> HubGaugeLevel {
        usedPercent > 90 ? .critical : .normal
    }

    /// A running app's CPU use: orange above 20 %, red above 50 % (the same colours the list always used).
    public static func process(cpuPercent: Double) -> HubGaugeLevel {
        cpuPercent > 50 ? .critical : (cpuPercent > 20 ? .warning : .normal)
    }
}

/// The numbers and lines the Command Hub's Control Center-style tiles and gauges show.
public enum HubStatus {
    /// A ring's fill: a percentage turned into 0...1.
    public static func ringFraction(percent: Double) -> Double {
        guard percent.isFinite else { return 0 }
        return min(max(percent / 100, 0), 1)
    }

    /// A running app's thin bar. One core is 100 %, so it is drawn against two cores' worth (an app that uses more
    /// than that fills the bar), which keeps ordinary values readable.
    public static func processBarFraction(cpuPercent: Double) -> Double {
        guard cpuPercent.isFinite else { return 0 }
        return min(max(cpuPercent / 200, 0), 1)
    }

    /// A running app's CPU figure. Summed across cores it can pass 100 %, and "155,5%" is too wide for its column, so
    /// from 100 % up the decimal goes ("156%"); below that it keeps one ("9,5%"). Written the way the region writes a
    /// percentage; a bad number reads as 0.
    public static func processCPUText(percent: Double, locale: Locale = .autoupdatingCurrent) -> String {
        guard percent.isFinite, percent > 0 else { return LocalizedNumber.percent(0, fractionDigits: 0, locale: locale) }
        let rounded = (percent * 10).rounded() / 10
        return LocalizedNumber.percent(rounded, fractionDigits: rounded >= 100 ? 0 : 1, locale: locale)
    }

    /// The line under "Privacy Shield": off, or on with the number of requests it has blocked so far (real count).
    public static func privacyShieldStatus(isOn: Bool, blockedRequests: Int) -> String {
        guard isOn else { return String(localized: "Off") }
        guard blockedRequests > 0 else { return String(localized: "On") }
        return String(localized: "\(blockedRequests) blocked")
    }

    /// The line under "Keep Awake": off, or what the service says (time left, or what it waits for).
    public static func keepAwakeStatus(_ snapshot: KeepAwakeSnapshot?) -> String {
        snapshot?.statusText ?? String(localized: "Off")
    }

    /// A size short enough for the 60 pt ring (decimal units, as Finder shows them): one decimal below 10 GB or 10 TB
    /// ("0.5 GB", "9.9 GB", "1.2 TB"), whole numbers above ("389 GB", "12 TB"), whole MB below 0.1 GB, never grouped,
    /// with the locale's decimal separator. A value that rounds up to the next unit moves to it ("999.9 GB" is "1.0 TB").
    public static func compactSize(bytes: Int64, locale: Locale = .autoupdatingCurrent) -> String {
        let value = Double(max(bytes, 0))
        let gb = value / 1_000_000_000
        let tb = gb / 1000
        func text(_ number: Double, _ digits: Int, _ unit: String) -> String {
            "\(LocalizedNumber.decimal(number, fractionDigits: digits, locale: locale)) \(unit)"
        }
        if tb >= 1 || gb.rounded() >= 1000 {
            return (tb * 10).rounded() >= 100 ? text(tb, 0, "TB") : text(tb, 1, "TB")
        }
        if gb >= 10 { return text(gb, 0, "GB") }
        if gb >= 0.1 {
            // 9.96 GB would print "10.0 GB": show it whole instead.
            return (gb * 10).rounded() >= 100 ? text(gb, 0, "GB") : text(gb, 1, "GB")
        }
        return text((value / 1_000_000).rounded(), 0, "MB")
    }
}
