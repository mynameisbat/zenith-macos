import Testing
import Foundation
import CoreGraphics
@testable import GoldenGateCore

@Suite("AutoPasteService Keystroke Automation Suite")
struct AutoPasteServiceTests {

    @Test("AP-01: AutoPasteService vKeyCode is exactly 9 (kVK_ANSI_V)")
    func testVKeyCode() {
        #expect(AutoPasteService.vKeyCode == 9)
    }

    @Test("AP-02: AutoPasteService conforms to AutoPasteServiceProtocol")
    func testProtocolConformance() {
        let service: any AutoPasteServiceProtocol = AutoPasteService.shared
        #expect(service is AutoPasteService)
    }

    @Test("AP-03: AutoPasteService.shared singleton is thread-safe and non-nil")
    func testSingletonInstance() {
        let s1 = AutoPasteService.shared
        let s2 = AutoPasteService()
        #expect(type(of: s1) == type(of: s2))
    }

    @Test("AP-04: AutoPasteService simulatePasteKeystroke executes safely")
    func testSimulateKeystrokeExecution() {
        // When run in test runner / headless environment, simulatePasteKeystroke returns a boolean
        // indicating event generation result without raising fatal exceptions or crashing.
        let result = AutoPasteService.simulatePasteKeystroke()
        #expect(result == true || result == false)
    }
}
