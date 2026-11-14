import Foundation

/// What a keep-awake power assertion stops.
public enum PowerAssertionKind: String, Sendable, Equatable {
    /// The Mac does not go to sleep when idle; the display may still dim and turn off.
    case preventIdleSystemSleep
    /// The display stays on as well (which also keeps the Mac awake).
    case preventIdleDisplaySleep
}

/// Creates and releases IOKit power assertions. The real one is `IOKitPowerAssertionProvider`; tests use
/// `RecordingPowerAssertionProvider`, so they never keep the machine running them awake.
@MainActor
public protocol PowerAssertionProviding: AnyObject {
    /// Creates an assertion and returns its identifier, or nil when the system refused it.
    func createAssertion(_ kind: PowerAssertionKind, reason: String) -> UInt32?
    func releaseAssertion(_ id: UInt32)
}

/// An app the user can choose for "while these apps are running".
public struct KeepAwakeApp: Sendable, Equatable, Hashable, Codable, Identifiable {
    public let bundleIdentifier: String
    public let name: String

    public var id: String { bundleIdentifier }

    public init(bundleIdentifier: String, name: String) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
    }
}

/// Lists running apps and reports launches and quits. The real one is `WorkspaceRunningApplications`.
@MainActor
public protocol RunningApplicationsProviding: AnyObject {
    /// Bundle identifiers of every running process that has one.
    func runningBundleIdentifiers() -> Set<String>
    /// Running apps with a Dock icon, for the picker.
    func runningApplications() -> [KeepAwakeApp]
    /// Calls `onChange` after an app launches or quits, until `stopObserving()`.
    func startObserving(_ onChange: @escaping @MainActor () -> Void)
    func stopObserving()
}

/// Says whether the Mac runs on the power adapter and reports changes. The real one is `IOKitPowerSource`.
@MainActor
public protocol PowerSourceProviding: AnyObject {
    var isOnACPower: Bool { get }
    /// Calls `onChange` when the power source changes, until `stopObserving()`.
    func startObserving(_ onChange: @escaping @MainActor () -> Void)
    func stopObserving()
}
