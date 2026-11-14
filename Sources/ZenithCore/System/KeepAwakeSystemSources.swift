import AppKit
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

/// Power assertions through `IOPMAssertionCreateWithName`. macOS also drops them if the process dies.
@MainActor
public final class IOKitPowerAssertionProvider: PowerAssertionProviding {
    public init() {}

    public func createAssertion(_ kind: PowerAssertionKind, reason: String) -> UInt32? {
        let type: String
        switch kind {
        case .preventIdleSystemSleep: type = "PreventUserIdleSystemSleep"     // kIOPMAssertionTypePreventUserIdleSystemSleep
        case .preventIdleDisplaySleep: type = "PreventUserIdleDisplaySleep"   // kIOPMAssertionTypePreventUserIdleDisplaySleep
        }
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )
        guard result == kIOReturnSuccess else {
            NSLog("[Zenith] Keep awake: the power assertion was refused (\(result)).")
            return nil
        }
        return id
    }

    public func releaseAssertion(_ id: UInt32) {
        IOPMAssertionRelease(IOPMAssertionID(id))
    }
}

/// Running apps from `NSWorkspace`, with its launch and quit notifications (no polling).
@MainActor
public final class WorkspaceRunningApplications: RunningApplicationsProviding {
    private var observers: [NSObjectProtocol] = []

    public init() {}

    public func runningBundleIdentifiers() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    public func runningApplications() -> [KeepAwakeApp] {
        let ownID = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> KeepAwakeApp? in
                guard let id = app.bundleIdentifier, id != ownID, seen.insert(id).inserted else { return nil }
                return KeepAwakeApp(bundleIdentifier: id, name: app.localizedName ?? id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func startObserving(_ onChange: @escaping @MainActor () -> Void) {
        stopObserving()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { onChange() }
            })
        }
    }

    public func stopObserving() {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver)
        observers.removeAll()
    }
}

/// The power source from IOKit's power-sources API, with its run-loop notification (no polling).
@MainActor
public final class IOKitPowerSource: PowerSourceProviding {
    private var runLoopSource: CFRunLoopSource?
    private var onChange: (@MainActor () -> Void)?

    public init() {}

    /// A Mac without a battery reports "AC Power" too.
    public var isOnACPower: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else {
            return true
        }
        return (type as String) == kIOPMACPowerKey
    }

    public func startObserving(_ onChange: @escaping @MainActor () -> Void) {
        stopObserving()
        self.onChange = onChange
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            // Added to the main run loop below, so this runs on the main thread.
            MainActor.assumeIsolated {
                Unmanaged<IOKitPowerSource>.fromOpaque(context).takeUnretainedValue().onChange?()
            }
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        runLoopSource = source
    }

    public func stopObserving() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        onChange = nil
    }
}
