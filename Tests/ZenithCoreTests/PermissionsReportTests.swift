import Testing
import Foundation
@testable import ZenithCore

@Suite("PermissionsReportTests")
struct PermissionsReportTests {
    private func status(
        _ kind: ZenithPermissionKind,
        _ state: ZenithPermissionState,
        _ activity: [ZenithPermissionFeature: ZenithFeatureActivity] = [:]
    ) -> ZenithPermissionStatus {
        ZenithPermissionsReport.statuses(states: [kind: state], activity: activity).first { $0.kind == kind }!
    }

    @Test("PRM-01: granted and a feature is on is in use")
    func grantedUsed() {
        let s = status(.calendar, .granted, [.calendarWidget: .on])
        #expect(s.verdict == .inUse)
        #expect(s.notice == nil)
        #expect(s.offersSettingsButton)
    }

    @Test("PRM-02: granted but every feature is off warns")
    func grantedUnused() {
        let s = status(.calendar, .granted, [.calendarWidget: .off])
        #expect(s.verdict == .grantedButUnused)
        #expect(s.noticeIsWarning)
        #expect(s.notice != nil)
        #expect(s.badgeText == String(localized: "Allowed"))
    }

    @Test("PRM-03: missing while a feature is on is a hint")
    func missingNeeded() {
        let s = status(.calendar, .notGranted, [.calendarWidget: .on])
        #expect(s.verdict == .neededButMissing)
        #expect(s.noticeIsWarning)
        #expect(s.badgeText == String(localized: "Not Allowed"))
    }

    @Test("PRM-04: missing while the feature is off is not a warning")
    func missingNotNeeded() {
        let s = status(.calendar, .notGranted, [.calendarWidget: .off])
        #expect(s.verdict == .notGranted)
        #expect(s.notice == nil)
    }

    @Test("PRM-05: not determined: asked-yet, or needed when a feature is on; no Settings button until asked")
    func undetermined() {
        #expect(status(.calendar, .notDetermined, [.calendarWidget: .off]).verdict == .notAskedYet)
        #expect(status(.calendar, .notDetermined, [.calendarWidget: .off]).offersSettingsButton == false)
        #expect(status(.calendar, .notDetermined, [.calendarWidget: .on]).verdict == .neededButMissing)
    }

    @Test("PRM-06: features without a switch count as in use and never warn as unused")
    func alwaysAvailable() {
        let granted = status(.accessibility, .granted)
        #expect(granted.verdict == .inUse)
        #expect(granted.features.allSatisfy { $0.activity == .alwaysAvailable })
        let missing = status(.accessibility, .notGranted)
        #expect(missing.verdict == .notGranted)
    }

    @Test("PRM-07: Automation is reported per app and never as granted or denied")
    func perApp() {
        let s = status(.automation, .askedPerApp)
        #expect(s.verdict == .askedPerApp)
        #expect(s.notice != nil)
        #expect(!s.noticeIsWarning)
    }

    @Test("PRM-08: unavailable has no Settings button")
    func unavailable() {
        let s = status(.calendar, .unavailable, [.calendarWidget: .on])
        #expect(s.verdict == .unavailable)
        #expect(!s.offersSettingsButton)
    }

    @Test("PRM-09: every permission lists at least one feature and every feature belongs to one")
    func featureMap() {
        let all = ZenithPermissionsReport.statuses(states: [:], activity: [:])
        #expect(all.map(\.kind) == ZenithPermissionKind.allCases)
        for s in all { #expect(!s.features.isEmpty, "\(s.kind) lists no feature") }
        #expect(all.flatMap(\.features).count == ZenithPermissionFeature.allCases.count)
        for kind in ZenithPermissionKind.allCases {
            #expect(!kind.title.isEmpty && !kind.purpose.isEmpty && !kind.withoutIt.isEmpty)
        }
    }

    @Test("PRM-10: settings URLs point at the matching Privacy panes")
    func urls() {
        #expect(ZenithPermissionKind.screenRecording.settingsURL.absoluteString.hasSuffix("Privacy_ScreenCapture"))
        #expect(ZenithPermissionKind.accessibility.settingsURL.absoluteString.hasSuffix("Privacy_Accessibility"))
        #expect(ZenithPermissionKind.automation.settingsURL.absoluteString.hasSuffix("Privacy_Automation"))
        #expect(ZenithPermissionKind.calendar.settingsURL.absoluteString.hasSuffix("Privacy_Calendars"))
    }

    @MainActor
    @Test("PRM-11: the model reads the mock without prompting, and opens the right URL through the opener")
    func model() {
        let mock = MockPermissionsService(screenRecordingGranted: true, accessibilityGranted: false)
        mock.calendarState = .granted
        let opener = RecordingSettingsOpener()
        let model = ZenithPermissionsModel(
            permissions: mock,
            activity: StaticFeatureActivity([.calendarWidget: .off]),
            opener: opener
        )
        func verdict(_ k: ZenithPermissionKind) -> ZenithPermissionVerdict { model.statuses.first { $0.kind == k }!.verdict }
        #expect(verdict(.screenRecording) == .inUse)
        #expect(verdict(.accessibility) == .notGranted)
        #expect(verdict(.automation) == .askedPerApp)
        #expect(verdict(.calendar) == .grantedButUnused)
        #expect(mock.requestScreenRecordingCallCount == 0)
        #expect(mock.requestAccessibilityCallCount == 0)

        model.openSettings(for: .calendar)
        #expect(opener.openedURLs == [ZenithPermissionKind.calendar.settingsURL])

        mock.accessibilityGranted = true
        model.refresh()
        #expect(verdict(.accessibility) == .inUse)
    }
}
