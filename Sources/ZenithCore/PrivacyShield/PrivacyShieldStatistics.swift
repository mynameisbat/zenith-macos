import Foundation
import Combine

/// Request bypass and routing status.
public enum PrivacyRequestStatus: String, Sendable, Codable {
    case shielded = "SHIELDED"
    case plain = "DIRECT"
    case failed = "FAILED"
}

/// In-memory diagnostic log entry representing a single routed request through Privacy Shield.
public struct PrivacyRequestLogRecord: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let domain: String
    public let port: UInt16
    public let protocolType: String
    public let resolvedIP: String?
    public let chunkSize: Int
    public let bytes: Int64
    public let status: PrivacyRequestStatus

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        domain: String,
        port: UInt16 = 443,
        protocolType: String = "HTTPS",
        resolvedIP: String? = nil,
        chunkSize: Int = 2,
        bytes: Int64 = 0,
        status: PrivacyRequestStatus = .shielded
    ) {
        self.id = id
        self.timestamp = timestamp
        self.domain = domain
        self.port = port
        self.protocolType = protocolType
        self.resolvedIP = resolvedIP
        self.chunkSize = chunkSize
        self.bytes = bytes
        self.status = status
    }

    public var formattedTime: String {
        Self.timeFormatter.string(from: timestamp)
    }

    public var formattedBytes: String {
        if bytes < 1024 {
            return "\(bytes) B"
        }
        let kb = Double(bytes) / 1024.0
        if kb < 1024 {
            return String(format: "%.1f KB", kb)
        }
        let mb = kb / 1024.0
        return String(format: "%.1f MB", mb)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

/// Real-time live statistics and telemetry for Privacy Shield DPI bypass activity.
@MainActor
public final class PrivacyShieldStatistics: ObservableObject {
    public static let shared = PrivacyShieldStatistics()
    public static let maxRecentRequestsCapacity: Int = 100

    @Published public var isActive: Bool = false
    @Published public var selectedProvider: DoHProvider = .cloudflare
    @Published public var port: Int = 8080
    @Published public var totalRequestsProtected: Int = 0
    @Published public var totalBytesShielded: Int64 = 0
    @Published public var lastProtectedDomain: String? = nil
    @Published public var lastChunkSize: Int = 2
    @Published public var dohLatencyMs: Int = 0
    @Published public var lastVerifiedAt: Date? = nil

    /// Bounded in-memory ring buffer of recent routed requests (max 100).
    @Published public var recentRequests: [PrivacyRequestLogRecord] = []
    @Published public var isRecordingEnabled: Bool = true

    public init() {}

    public func reset() {
        totalRequestsProtected = 0
        totalBytesShielded = 0
        lastProtectedDomain = nil
        dohLatencyMs = 0
        lastVerifiedAt = nil
        recentRequests.removeAll()
    }

    public func clearRecentRequests() {
        recentRequests.removeAll()
    }

    public func toggleRecording() {
        isRecordingEnabled.toggle()
    }

    public func recordProtectedRequest(
        domain: String,
        bytes: Int64,
        chunkSize: Int,
        port: UInt16 = 443,
        protocolType: String = "HTTPS",
        resolvedIP: String? = nil,
        status: PrivacyRequestStatus = .shielded
    ) {
        totalRequestsProtected += 1
        totalBytesShielded += bytes
        lastProtectedDomain = domain
        lastChunkSize = chunkSize

        if isRecordingEnabled {
            let record = PrivacyRequestLogRecord(
                domain: domain,
                port: port,
                protocolType: protocolType,
                resolvedIP: resolvedIP,
                chunkSize: chunkSize,
                bytes: bytes,
                status: status
            )
            recentRequests.insert(record, at: 0)
            if recentRequests.count > Self.maxRecentRequestsCapacity {
                recentRequests.removeLast(recentRequests.count - Self.maxRecentRequestsCapacity)
            }
        }
    }

    public func recordFailedRequest(
        domain: String,
        port: UInt16 = 443,
        protocolType: String = "HTTPS"
    ) {
        if isRecordingEnabled {
            let record = PrivacyRequestLogRecord(
                domain: domain,
                port: port,
                protocolType: protocolType,
                resolvedIP: nil,
                chunkSize: 0,
                bytes: 0,
                status: .failed
            )
            recentRequests.insert(record, at: 0)
            if recentRequests.count > Self.maxRecentRequestsCapacity {
                recentRequests.removeLast(recentRequests.count - Self.maxRecentRequestsCapacity)
            }
        }
    }

    public func updateLatency(_ ms: Int) {
        dohLatencyMs = ms
    }

    public func markVerified() {
        lastVerifiedAt = Date()
    }

    public var formattedShieldedBytes: String {
        if totalBytesShielded < 1024 {
            return "\(totalBytesShielded) B"
        }
        let kb = Double(totalBytesShielded) / 1024.0
        if kb < 1024 {
            return String(format: "%.1f KB", kb)
        }
        let mb = kb / 1024.0
        return String(format: "%.1f MB", mb)
    }
}
