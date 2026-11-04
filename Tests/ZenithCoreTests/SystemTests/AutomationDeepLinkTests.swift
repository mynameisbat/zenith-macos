import Testing
import Foundation
@testable import ZenithCore

@Suite("Permission Deep Link Suite")
struct AutomationDeepLinkTests {
    @Test("PERM-L1: The Automation link points at the Privacy & Security pane's Automation section")
    func testAutomationLink() {
        #expect(SystemPermissions.automationSettingsURL.absoluteString
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        #expect(SystemPermissions.accessibilitySettingsURL.absoluteString.hasSuffix("Privacy_Accessibility"))
        #expect(SystemPermissions.screenRecordingSettingsURL.absoluteString.hasSuffix("Privacy_ScreenCapture"))
    }
}
