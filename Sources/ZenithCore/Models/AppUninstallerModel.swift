import Foundation

/// The state behind Settings → Cleaner → Uninstall: the installed apps, the one picked, and the list of what goes
/// with it (a `CleanupToolModel`, which does the ticking, the confirmation and the removal).
///
/// Nothing here runs unless the page is open and the user acts: the app list is read when the page appears or on
/// Refresh, and an app's files are measured only once it is picked.
@MainActor
public final class AppUninstallerModel: ObservableObject {
    @Published public private(set) var apps: [InstalledAppInfo] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var hasLoaded = false
    @Published public var searchText = ""
    @Published public private(set) var selectedApp: InstalledAppInfo?
    /// The picked app's list; `nil` while the app list is showing.
    @Published public private(set) var tool: CleanupToolModel?
    /// One line about the last thing that happened (an app that was refused, an uninstall that finished).
    @Published public private(set) var notice: String?

    private let service: AppUninstallerService

    public init(service: AppUninstallerService = .shared) {
        self.service = service
    }

    /// The apps whose name or bundle identifier contains the search text, ignoring case and accents.
    public var filteredApps: [InstalledAppInfo] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return apps }
        return apps.filter {
            $0.displayName.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || $0.bundleIdentifier.range(of: query, options: .caseInsensitive) != nil
        }
    }

    public func loadApps() async {
        guard !isLoading else { return }
        isLoading = true
        let service = self.service
        apps = await Task.detached { service.listInstalledApps() }.value
        hasLoaded = true
        isLoading = false
    }

    /// Opens an app's list and looks for its files.
    public func select(_ app: InstalledAppInfo) async {
        let model = CleanupToolModel.uninstaller(app: app, service: service)
        notice = nil
        selectedApp = app
        tool = model
        await model.scan()
    }

    /// For an app picked in a file dialog or dropped on the page: opens it, or says why it cannot be uninstalled.
    @discardableResult
    public func choose(appAtPath path: String) async -> Bool {
        let service = self.service
        let verdict = await Task.detached { service.eligibility(ofAppAt: path, measuringSize: false) }.value
        switch verdict {
        case .success(let app):
            await select(app)
            return true
        case .failure(let refusal):
            let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            notice = Self.message(for: refusal, name: name)
            return false
        }
    }

    /// Back to the app list.
    public func back() {
        selectedApp = nil
        tool = nil
    }

    /// Call after the picked app's list removed something. When the app and everything listed with it are gone,
    /// returns to the app list (without that app) and says so; otherwise the list stays, showing what is left.
    public func afterCleaning() async {
        guard let app = selectedApp, let tool else { return }
        guard tool.candidates.isEmpty, !tool.isScanning, !tool.isCleaning else { return }
        guard !FileManager.default.fileExists(atPath: app.bundlePath) else { return }
        back()
        apps.removeAll { $0.bundlePath == app.bundlePath }
        notice = String(localized: "\(app.displayName) and its files are in the Trash.")
    }

    public static func message(for refusal: UninstallRefusal, name: String) -> String {
        switch refusal {
        case .notAnApp:
            return String(localized: "\(name) is not an app.")
        case .partOfMacOS:
            return String(localized: "\(name) is part of macOS or made by Apple, so Zenith leaves it alone.")
        case .isZenith:
            return String(localized: "Zenith can't uninstall itself. Quit it and move it to the Trash in Finder.")
        case .insideAnotherApp:
            return String(localized: "\(name) is a part of another app. Uninstall that app instead.")
        case .unreadable:
            return String(localized: "Zenith can't tell which files belong to \(name), so it won't uninstall it.")
        }
    }
}
