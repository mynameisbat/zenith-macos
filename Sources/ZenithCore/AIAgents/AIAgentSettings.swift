import Foundation
import Combine

/// Settings → Dynamic Island → AI Agents. Everything is off until the user turns the feature on.
@MainActor
public final class AIAgentSettings: ObservableObject {
    public static let shared = AIAgentSettings()

    public enum Keys {
        public static let enabled = "zenith_ai_agents_enabled"
        public static let notifyWhenFinished = "zenith_ai_agents_notify_finished"
        public static let longTaskMinutes = "zenith_ai_agents_long_task_minutes"
        public static func tool(_ kind: AIAgentKind) -> String { "zenith_ai_agents_tool_\(kind.rawValue)" }
    }

    public static let longTaskRange = 1...60
    public static let defaultLongTaskMinutes = 2

    /// The whole feature. Off by default: nothing is read until the user turns it on.
    @Published public var isEnabled: Bool {
        didSet { userDefaults.set(isEnabled, forKey: Keys.enabled) }
    }

    /// Tools the user left on (each on by default, so turning the feature on shows every tool that is installed).
    @Published public private(set) var enabledTools: Set<AIAgentKind>

    /// A notice on the island when a long piece of work ends.
    @Published public var notifyWhenFinished: Bool {
        didSet { userDefaults.set(notifyWhenFinished, forKey: Keys.notifyWhenFinished) }
    }

    /// Work at least this long gets a notice when it ends.
    @Published public var longTaskMinutes: Int {
        didSet {
            let clamped = Self.clampedMinutes(longTaskMinutes)
            if clamped != longTaskMinutes { longTaskMinutes = clamped }
            userDefaults.set(clamped, forKey: Keys.longTaskMinutes)
        }
    }

    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.isEnabled = userDefaults.object(forKey: Keys.enabled) as? Bool ?? false
        self.notifyWhenFinished = userDefaults.object(forKey: Keys.notifyWhenFinished) as? Bool ?? true
        let minutes = userDefaults.object(forKey: Keys.longTaskMinutes) as? Int ?? Self.defaultLongTaskMinutes
        self.longTaskMinutes = Self.clampedMinutes(minutes)
        self.enabledTools = Set(AIAgentKind.allCases.filter { userDefaults.object(forKey: Keys.tool($0)) as? Bool ?? true })
    }

    public static func clampedMinutes(_ minutes: Int) -> Int {
        min(max(minutes, longTaskRange.lowerBound), longTaskRange.upperBound)
    }

    public func isToolEnabled(_ kind: AIAgentKind) -> Bool {
        enabledTools.contains(kind)
    }

    public func setTool(_ kind: AIAgentKind, enabled: Bool) {
        guard enabledTools.contains(kind) != enabled else { return }
        if enabled { enabledTools.insert(kind) } else { enabledTools.remove(kind) }
        userDefaults.set(enabled, forKey: Keys.tool(kind))
    }

    /// The tools to watch now: none while the feature is off.
    public var activeTools: Set<AIAgentKind> {
        isEnabled ? enabledTools : []
    }

    public var longTaskThreshold: TimeInterval {
        TimeInterval(longTaskMinutes * 60)
    }

    public func resetToDefaults() {
        isEnabled = false
        notifyWhenFinished = true
        longTaskMinutes = Self.defaultLongTaskMinutes
        for kind in AIAgentKind.allCases { setTool(kind, enabled: true) }
    }
}
