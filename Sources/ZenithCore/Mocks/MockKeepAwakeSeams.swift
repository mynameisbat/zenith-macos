import Foundation

/// Hands out made-up assertion identifiers and remembers which are held. Never touches IOKit.
@MainActor
public final class RecordingPowerAssertionProvider: PowerAssertionProviding {
    public private(set) var active: [UInt32: PowerAssertionKind] = [:]
    public private(set) var createdCount = 0
    public private(set) var lastReason: String?
    /// When true, every request is refused (as the system can).
    public var refuses = false
    private var nextID: UInt32 = 100

    public init() {}

    public var activeKinds: [PowerAssertionKind] { Array(active.values) }

    public func createAssertion(_ kind: PowerAssertionKind, reason: String) -> UInt32? {
        guard !refuses else { return nil }
        nextID += 1
        createdCount += 1
        lastReason = reason
        active[nextID] = kind
        return nextID
    }

    public func releaseAssertion(_ id: UInt32) {
        active[id] = nil
    }
}

/// Running apps the test sets by hand; `launch`/`quit` notify like `NSWorkspace` would.
@MainActor
public final class FakeRunningApplications: RunningApplicationsProviding {
    public var apps: [KeepAwakeApp]
    public private(set) var isObserving = false
    private var onChange: (@MainActor () -> Void)?

    public init(apps: [KeepAwakeApp] = []) {
        self.apps = apps
    }

    public func runningBundleIdentifiers() -> Set<String> { Set(apps.map(\.bundleIdentifier)) }
    public func runningApplications() -> [KeepAwakeApp] { apps }

    public func startObserving(_ onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        isObserving = true
    }

    public func stopObserving() {
        onChange = nil
        isObserving = false
    }

    public func launch(_ app: KeepAwakeApp) {
        apps.append(app)
        onChange?()
    }

    public func quit(_ bundleIdentifier: String) {
        apps.removeAll { $0.bundleIdentifier == bundleIdentifier }
        onChange?()
    }
}

/// A power source the test plugs and unplugs.
@MainActor
public final class FakePowerSource: PowerSourceProviding {
    public var isOnACPower: Bool {
        didSet { if oldValue != isOnACPower { onChange?() } }
    }
    public private(set) var isObserving = false
    private var onChange: (@MainActor () -> Void)?

    public init(isOnACPower: Bool = true) {
        self.isOnACPower = isOnACPower
    }

    public func startObserving(_ onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        isObserving = true
    }

    public func stopObserving() {
        onChange = nil
        isObserving = false
    }
}
