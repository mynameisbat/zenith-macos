import AppKit
import Foundation

// What the Permissions page tells the user: for every macOS permission Zenith can use, its state, what it is for,
// which Zenith features use it, and whether those features are on. The decision logic is a pure function
// (`ZenithPermissionsReport.statuses`) so it can be tested with plain values; the view only draws the result.

/// A macOS privacy permission Zenith can use.
public enum ZenithPermissionKind: String, CaseIterable, Sendable, Identifiable {
    case screenRecording
    case accessibility
    case automation
    case calendar

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .screenRecording: return String(localized: "Screen Recording")
        case .accessibility: return String(localized: "Accessibility")
        case .automation: return String(localized: "Automation")
        case .calendar: return String(localized: "Calendars")
        }
    }

    /// What the permission lets Zenith do.
    public var purpose: String {
        switch self {
        case .screenRecording:
            return String(localized: "Lets Zenith capture the screen and read text from it.")
        case .accessibility:
            return String(localized: "Lets Zenith press keys for you: \u{2318}V to paste, and media keys.")
        case .automation:
            return String(localized: "Lets Zenith tell other apps what to do: Music, Spotify and Finder.")
        case .calendar:
            return String(localized: "Lets Zenith read your events to show the next one in the island.")
        }
    }

    /// What still works when the permission is missing.
    public var withoutIt: String {
        switch self {
        case .screenRecording:
            return String(localized: "Without it, screenshots and text recognition only see the desktop picture. Clipboard history, shortcuts and the island are not affected.")
        case .accessibility:
            return String(localized: "Without it, clipboard items are only copied, not pasted for you. Everything else works, and the island controls Music and Spotify directly.")
        case .automation:
            return String(localized: "Without it, the island still shows what is playing, and other players can still be controlled. Music and Spotify controls, Music artwork and moving protected leftovers to the Trash do not work.")
        case .calendar:
            return String(localized: "Without it, the island simply has no calendar widget. Nothing else changes.")
        }
    }

    /// The Privacy & Security pane that lists this permission.
    public var settingsURL: URL {
        switch self {
        case .screenRecording: return SystemPermissions.screenRecordingSettingsURL
        case .accessibility: return SystemPermissions.accessibilitySettingsURL
        case .automation: return SystemPermissions.automationSettingsURL
        case .calendar: return SystemPermissions.calendarSettingsURL
        }
    }
}

/// A user-visible Zenith feature that needs a permission.
public enum ZenithPermissionFeature: String, CaseIterable, Sendable, Identifiable {
    case areaCapture
    case fullScreenCapture
    case screenText
    case autoPaste
    case mediaKeyFallback
    case playerControls
    case musicArtwork
    case leftoversTrash
    case calendarWidget
    case cleaningMode

    public var id: String { rawValue }

    public var permission: ZenithPermissionKind {
        switch self {
        case .areaCapture, .fullScreenCapture, .screenText: return .screenRecording
        case .autoPaste, .mediaKeyFallback, .cleaningMode: return .accessibility
        case .playerControls, .musicArtwork, .leftoversTrash: return .automation
        case .calendarWidget: return .calendar
        }
    }

    public var title: String {
        switch self {
        case .areaCapture: return String(localized: "Capture an area of the screen")
        case .fullScreenCapture: return String(localized: "Capture the whole screen")
        case .screenText: return String(localized: "Read text from the screen")
        case .autoPaste: return String(localized: "Paste a clipboard item for you")
        case .mediaKeyFallback: return String(localized: "Media keys, when a player cannot be controlled directly")
        case .playerControls: return String(localized: "Play, pause and skip in Music and Spotify")
        case .musicArtwork: return String(localized: "Album art from Music")
        case .leftoversTrash: return String(localized: "Cleaner \u{2192} Leftovers: protected folders")
        case .calendarWidget: return String(localized: "Next calendar event in the island")
        case .cleaningMode: return String(localized: "Cleaning Mode: block the keyboard and trackpad")
        }
    }
}

/// Whether a feature is currently in use. Most Zenith features have no switch: they run when the user uses them.
public enum ZenithFeatureActivity: Sendable, Equatable {
    /// The feature has a setting and it is on.
    case on
    /// The feature has a setting and it is off.
    case off
    /// The feature has no setting; it is there whenever the user reaches for it.
    case alwaysAvailable

    public var label: String {
        switch self {
        case .on: return String(localized: "On")
        case .off: return String(localized: "Off")
        case .alwaysAvailable: return String(localized: "Always available")
        }
    }
}

/// The state macOS reports for a permission, read without asking.
public enum ZenithPermissionState: Sendable, Equatable {
    case granted
    /// Not allowed (macOS does not say whether the user was ever asked, for permissions that only report yes/no).
    case notGranted
    /// macOS has not asked yet.
    case notDetermined
    /// macOS decides per target app and cannot be queried without the risk of a prompt.
    case askedPerApp
    /// Cannot be read here (e.g. Calendars when running outside the app bundle).
    case unavailable
}

/// What the page should say about one permission.
public enum ZenithPermissionVerdict: Sendable, Equatable {
    /// Granted, and a feature that uses it is on or always available.
    case inUse
    /// Granted, but every feature that uses it is switched off.
    case grantedButUnused
    /// Not granted, and a feature the user turned on needs it.
    case neededButMissing
    /// Not granted, and nothing the user turned on needs it.
    case notGranted
    case notAskedYet
    case askedPerApp
    case unavailable
}

public struct ZenithFeatureStatus: Sendable, Equatable, Identifiable {
    public let feature: ZenithPermissionFeature
    public let activity: ZenithFeatureActivity
    public var id: String { feature.id }
}

public struct ZenithPermissionStatus: Sendable, Equatable, Identifiable {
    public let kind: ZenithPermissionKind
    public let state: ZenithPermissionState
    public let verdict: ZenithPermissionVerdict
    public let features: [ZenithFeatureStatus]
    public var id: String { kind.id }

    /// The short text in the badge. Always words, so VoiceOver does not depend on colour.
    public var badgeText: String {
        switch verdict {
        case .inUse, .grantedButUnused: return String(localized: "Allowed")
        case .neededButMissing, .notGranted: return String(localized: "Not Allowed")
        case .notAskedYet: return String(localized: "Not asked yet")
        case .askedPerApp: return String(localized: "Asked per app")
        case .unavailable: return String(localized: "Needs Zenith.app")
        }
    }

    /// A sentence to show under the permission when there is something to point out.
    public var notice: String? {
        switch verdict {
        case .grantedButUnused:
            return String(localized: "Zenith has this permission but nothing you have turned on uses it. You can remove it in System Settings.")
        case .neededButMissing:
            return String(localized: "A feature you have turned on needs this permission. Allow it in System Settings.")
        case .askedPerApp:
            return String(localized: "macOS asks the first time, separately for each app Zenith controls.")
        case .unavailable:
            return String(localized: "macOS only lets the bundled Zenith.app ask for this, not a build started with swift run.")
        case .inUse, .notGranted, .notAskedYet:
            return nil
        }
    }

    /// Whether a notice is a warning (orange) rather than plain information.
    public var noticeIsWarning: Bool {
        verdict == .grantedButUnused || verdict == .neededButMissing
    }

    /// Whether "Open System Settings" makes sense: not when macOS has not asked yet (Zenith is not listed) or the
    /// permission cannot be asked for.
    public var offersSettingsButton: Bool {
        switch verdict {
        case .notAskedYet, .unavailable: return false
        default: return true
        }
    }
}

public enum ZenithPermissionsReport {
    /// The status of every permission. `states` and `activity` default to "not granted" and "always available" for
    /// anything missing, so a caller never has to fill every entry.
    public static func statuses(
        states: [ZenithPermissionKind: ZenithPermissionState],
        activity: [ZenithPermissionFeature: ZenithFeatureActivity]
    ) -> [ZenithPermissionStatus] {
        ZenithPermissionKind.allCases.map { kind in
            let state = states[kind] ?? .notGranted
            let features = ZenithPermissionFeature.allCases
                .filter { $0.permission == kind }
                .map { ZenithFeatureStatus(feature: $0, activity: activity[$0] ?? .alwaysAvailable) }
            return ZenithPermissionStatus(
                kind: kind,
                state: state,
                verdict: verdict(state: state, features: features),
                features: features
            )
        }
    }

    static func verdict(state: ZenithPermissionState, features: [ZenithFeatureStatus]) -> ZenithPermissionVerdict {
        let anyOn = features.contains { $0.activity == .on }
        let anyUsed = features.contains { $0.activity != .off }
        switch state {
        case .granted:
            return anyUsed ? .inUse : .grantedButUnused
        case .notGranted:
            return anyOn ? .neededButMissing : .notGranted
        case .notDetermined:
            return anyOn ? .neededButMissing : .notAskedYet
        case .askedPerApp:
            return .askedPerApp
        case .unavailable:
            return .unavailable
        }
    }
}

// MARK: - Seams

/// Which features are on. The live one reads the real settings; tests pass plain values.
@MainActor
public protocol ZenithFeatureActivityProviding {
    func activity(for feature: ZenithPermissionFeature) -> ZenithFeatureActivity
}

/// Reads the settings Zenith really has. The calendar widget and the Cleaning Mode shortcut have switches; the rest are
/// always available.
@MainActor
public struct LiveFeatureActivity: ZenithFeatureActivityProviding {
    private let widgets: IslandWidgetSettings
    private let cleaningMode: CleaningModeSettings

    public init(widgets: IslandWidgetSettings = .shared, cleaningMode: CleaningModeSettings = .shared) {
        self.widgets = widgets
        self.cleaningMode = cleaningMode
    }

    public func activity(for feature: ZenithPermissionFeature) -> ZenithFeatureActivity {
        switch feature {
        case .calendarWidget: return widgets.showCalendar ? .on : .off
        // Cleaning Mode can always be started from the hub; its global shortcut is the switch.
        case .cleaningMode: return cleaningMode.hotKeyEnabled ? .on : .alwaysAvailable
        default: return .alwaysAvailable
        }
    }
}

/// Fixed answers, for tests and screenshots.
public struct StaticFeatureActivity: ZenithFeatureActivityProviding {
    public var values: [ZenithPermissionFeature: ZenithFeatureActivity]

    public init(_ values: [ZenithPermissionFeature: ZenithFeatureActivity] = [:]) {
        self.values = values
    }

    public func activity(for feature: ZenithPermissionFeature) -> ZenithFeatureActivity {
        values[feature] ?? .alwaysAvailable
    }
}

/// Opens a System Settings URL.
public protocol SystemSettingsOpening: Sendable {
    @discardableResult
    func open(_ url: URL) -> Bool
}

public struct WorkspaceSettingsOpener: SystemSettingsOpening {
    public init() {}

    public func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}

/// Remembers what it was asked to open, without opening anything.
public final class RecordingSettingsOpener: SystemSettingsOpening, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URL] = []

    public init() {}

    public var openedURLs: [URL] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    public func open(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        recorded.append(url)
        return true
    }
}

// MARK: - Model for the page

@MainActor
public final class ZenithPermissionsModel: ObservableObject {
    @Published public private(set) var statuses: [ZenithPermissionStatus] = []

    private let permissions: PermissionsServiceProtocol
    private let activity: ZenithFeatureActivityProviding
    private let opener: SystemSettingsOpening

    public init(
        permissions: PermissionsServiceProtocol = SystemPermissionsService.shared,
        activity: ZenithFeatureActivityProviding = LiveFeatureActivity(),
        opener: SystemSettingsOpening = WorkspaceSettingsOpener()
    ) {
        self.permissions = permissions
        self.activity = activity
        self.opener = opener
        refresh()
    }

    /// Reads every state again. Never asks macOS for anything.
    public func refresh() {
        var states: [ZenithPermissionKind: ZenithPermissionState] = [
            .screenRecording: permissions.checkScreenRecordingPermission() ? .granted : .notGranted,
            .accessibility: permissions.checkAccessibilityPermission() ? .granted : .notGranted,
            // macOS reports Automation per target app, and asking can show a prompt, so it is not read.
            .automation: .askedPerApp
        ]
        switch permissions.calendarAccess() {
        case .granted: states[.calendar] = .granted
        case .denied: states[.calendar] = .notGranted
        case .notDetermined: states[.calendar] = .notDetermined
        case .unavailable: states[.calendar] = .unavailable
        }
        var features: [ZenithPermissionFeature: ZenithFeatureActivity] = [:]
        for feature in ZenithPermissionFeature.allCases {
            features[feature] = activity.activity(for: feature)
        }
        statuses = ZenithPermissionsReport.statuses(states: states, activity: features)
    }

    public func openSettings(for kind: ZenithPermissionKind) {
        _ = opener.open(kind.settingsURL)
    }
}
