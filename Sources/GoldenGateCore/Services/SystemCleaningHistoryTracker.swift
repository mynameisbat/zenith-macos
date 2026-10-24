import Foundation
import Combine

/// A single recorded cleaning operation.
public struct CleaningRecord: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let operationName: String
    public let bytesFreed: Int64
    public let itemCount: Int

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        operationName: String,
        bytesFreed: Int64,
        itemCount: Int = 1
    ) {
        self.id = id
        self.timestamp = timestamp
        self.operationName = operationName
        self.bytesFreed = bytesFreed
        self.itemCount = itemCount
    }
}

/// Tracks historical space savings, cleaning sessions, and audit log metrics across Zenith.
public final class SystemCleaningHistoryTracker: ObservableObject, @unchecked Sendable {
    public static let shared = SystemCleaningHistoryTracker()

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let recordsKey = "zenith_cleaning_history_records"
    private let totalBytesKey = "zenith_cleaning_history_total_bytes"
    private let totalSessionsKey = "zenith_cleaning_history_total_sessions"

    @Published public private(set) var totalBytesFreed: Int64 = 0
    @Published public private(set) var totalSessions: Int = 0
    @Published public private(set) var recentRecords: [CleaningRecord] = []

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadHistory()
    }

    /// Records a new completed cleaning operation and updates persistent metrics.
    public func record(operationName: String, bytesFreed: Int64, itemCount: Int = 1) {
        guard bytesFreed > 0 else { return }

        lock.lock()
        defer { lock.unlock() }

        let newRecord = CleaningRecord(
            operationName: operationName,
            bytesFreed: bytesFreed,
            itemCount: itemCount
        )

        var current = recentRecords
        current.insert(newRecord, at: 0)
        // Retain last 100 historical sessions
        if current.count > 100 {
            current = Array(current.prefix(100))
        }

        let newTotal = totalBytesFreed + bytesFreed
        let newSessions = totalSessions + 1

        recentRecords = current
        totalBytesFreed = newTotal
        totalSessions = newSessions

        // Persist
        defaults.set(newTotal, forKey: totalBytesKey)
        defaults.set(newSessions, forKey: totalSessionsKey)
        if let data = try? JSONEncoder().encode(current) {
            defaults.set(data, forKey: recordsKey)
        }
    }

    /// Clears historical audit records while preserving cumulative space freed metrics.
    public func clearHistory(resetCumulative: Bool = false) {
        lock.lock()
        defer { lock.unlock() }

        recentRecords = []
        defaults.removeObject(forKey: recordsKey)

        if resetCumulative {
            totalBytesFreed = 0
            totalSessions = 0
            defaults.removeObject(forKey: totalBytesKey)
            defaults.removeObject(forKey: totalSessionsKey)
        }
    }

    // MARK: - Formatters

    public var formattedTotalFreed: String {
        formatBytes(totalBytesFreed)
    }

    public var summaryHeadline: String {
        if totalSessions == 0 {
            return "No cleaning sessions recorded yet"
        }
        return "Zenith has freed \(formattedTotalFreed) on this Mac across \(totalSessions) session\(totalSessions == 1 ? "" : "s")"
    }

    public func formatBytes(_ bytes: Int64) -> String {
        let bcf = ByteCountFormatter()
        bcf.allowedUnits = [.useAll]
        bcf.countStyle = .file
        return bcf.string(fromByteCount: bytes)
    }

    private func loadHistory() {
        lock.lock()
        defer { lock.unlock() }

        totalBytesFreed = defaults.object(forKey: totalBytesKey) as? Int64 ?? 0
        totalSessions = defaults.integer(forKey: totalSessionsKey)

        if let data = defaults.data(forKey: recordsKey),
           let decoded = try? JSONDecoder().decode([CleaningRecord].self, from: data) {
            recentRecords = decoded
        } else {
            recentRecords = []
        }
    }
}
