import Testing
import Foundation
@testable import GoldenGateCore

@Suite("LaunchAtLogin Service & Protocol Contract Suite")
struct LaunchAtLoginTests {

    @Test("LAL-01: Protocol Contract Compliance and Initial States")
    func testInitialStates() {
        let disabledService = SimulatedLaunchAtLoginService(initialState: false)
        #expect(disabledService.isEnabled == false)
        #expect(disabledService.status == .notRegistered)
        #expect(disabledService.enableCallCount == 0)
        #expect(disabledService.disableCallCount == 0)

        let enabledService = SimulatedLaunchAtLoginService(initialState: true)
        #expect(enabledService.isEnabled == true)
        #expect(enabledService.status == .enabled)
    }

    @Test("LAL-02: State Transitions: Enable and Disable")
    func testStateTransitions() throws {
        let service = SimulatedLaunchAtLoginService(initialStatus: .notRegistered)
        #expect(service.isEnabled == false)

        try service.enable()
        #expect(service.isEnabled == true)
        #expect(service.status == .enabled)
        #expect(service.enableCallCount == 1)

        try service.disable()
        #expect(service.isEnabled == false)
        #expect(service.status == .notRegistered)
        #expect(service.disableCallCount == 1)
    }

    @Test("LAL-03: Idempotent Operations")
    func testIdempotency() throws {
        let service = SimulatedLaunchAtLoginService(initialStatus: .notRegistered)

        // Multiple enables
        try service.enable()
        try service.enable()
        #expect(service.isEnabled == true)
        #expect(service.status == .enabled)
        #expect(service.enableCallCount == 2)

        // Multiple disables
        try service.disable()
        try service.disable()
        #expect(service.isEnabled == false)
        #expect(service.status == .notRegistered)
        #expect(service.disableCallCount == 2)
    }

    @Test("LAL-04: Error Handling and Propagation")
    func testErrorPropagation() {
        let service = SimulatedLaunchAtLoginService(initialStatus: .notRegistered)

        // Error via shouldThrow
        service.shouldThrow = true
        #expect(throws: LaunchAtLoginError.self) {
            try service.enable()
        }
        #expect(throws: LaunchAtLoginError.self) {
            try service.disable()
        }
        service.shouldThrow = false

        // Error via shouldThrowOnEnable
        service.shouldThrowOnEnable = LaunchAtLoginError.requiresApproval
        #expect(throws: LaunchAtLoginError.requiresApproval) {
            try service.enable()
        }

        // Error descriptions validation
        let approvalErr = LaunchAtLoginError.requiresApproval
        #expect(approvalErr.errorDescription?.contains("approval") == true)

        let notFoundErr = LaunchAtLoginError.notFound
        #expect(notFoundErr.errorDescription?.contains("bundle") == true)

        let sysErr = LaunchAtLoginError.systemError("Mock failure")
        #expect(sysErr.errorDescription?.contains("Mock failure") == true)

        let regErr = LaunchAtLoginError.registrationFailed("Boom")
        #expect(regErr.errorDescription?.contains("Boom") == true)

        let osErr = LaunchAtLoginError.unsupportedOS
        #expect(osErr.errorDescription?.contains("macOS 13") == true)
    }

    @Test("LAL-05: Concurrency Torture: 60 Concurrent Tasks")
    func testConcurrencySafety() async {
        let service = SimulatedLaunchAtLoginService(initialStatus: .notRegistered)

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<60 {
                group.addTask {
                    if i % 2 == 0 {
                        try? service.enable()
                    } else {
                        try? service.disable()
                    }
                    _ = service.isEnabled
                    _ = service.status
                }
            }
        }

        #expect(service.enableCallCount + service.disableCallCount == 60)
    }

    @Test("LAL-06: SettingsStore Integration and State Persistence")
    func testSettingsStoreIntegration() {
        let suiteName = "LaunchAtLoginSettingsTests_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = SettingsStore(userDefaults: defaults)

        #expect(store.launchAtLoginEnabled == false)
        #expect(store.launchAtLogin == false)

        store.launchAtLoginEnabled = true
        #expect(store.launchAtLoginEnabled == true)
        #expect(store.launchAtLogin == true)
        #expect(defaults.bool(forKey: SettingsStore.Keys.launchAtLoginEnabled) == true)

        store.launchAtLogin = false
        #expect(store.launchAtLoginEnabled == false)
        #expect(defaults.bool(forKey: SettingsStore.Keys.launchAtLoginEnabled) == false)

        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    @Test("LAL-07: SystemLaunchAtLoginService Live Status Inspection")
    func testSystemLaunchAtLoginServiceSmoke() {
        let systemService = SystemLaunchAtLoginService.shared
        // In headless environment without a signed bundle, status can be .notRegistered or .notFound
        let status = systemService.status
        #expect([LaunchAtLoginStatus.notRegistered, .notFound, .enabled, .requiresApproval].contains(status))
    }
}
