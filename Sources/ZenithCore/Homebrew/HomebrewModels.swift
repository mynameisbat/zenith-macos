import Foundation

// The pure half of the Homebrew manager: what `brew` prints, read into values, and the command lines Zenith builds.
// Nothing here runs a process; `HomebrewManagerModel` does, through injected runners.

/// A formula (command-line tool or library) or a cask (an app or other prebuilt download).
public enum HomebrewPackageKind: String, Sendable, Equatable, Hashable, CaseIterable {
    case formula, cask

    /// The flag that tells `brew` which of the two a name means (a few names are both).
    public var flag: String { self == .formula ? "--formula" : "--cask" }
}

/// One formula or cask, installed or found by a search.
public struct HomebrewPackage: Identifiable, Sendable, Equatable {
    /// What `brew` commands take: `full_name` / `full_token` (includes the tap for packages from other taps).
    public let name: String
    /// What the list shows: the formula's name, or the cask's app name ("Mozilla Firefox").
    public let displayName: String
    public let kind: HomebrewPackageKind
    /// The installed version, or the latest one for a package that is not installed.
    public let version: String
    public let latestVersion: String?
    public let summary: String?
    public let homepage: String?
    public let isInstalled: Bool
    /// `false` for a formula that was only installed as another one's dependency.
    public let isInstalledOnRequest: Bool
    public let isPinned: Bool
    public let isOutdated: Bool
    /// Where the installed files are, for the size: the formula's Cellar folder or the cask's app.
    public var sizePath: String?
    public var bytes: Int64?

    public var id: String { "\(kind.rawValue):\(name)" }

    public init(
        name: String,
        displayName: String? = nil,
        kind: HomebrewPackageKind,
        version: String,
        latestVersion: String? = nil,
        summary: String? = nil,
        homepage: String? = nil,
        isInstalled: Bool,
        isInstalledOnRequest: Bool = true,
        isPinned: Bool = false,
        isOutdated: Bool = false,
        sizePath: String? = nil,
        bytes: Int64? = nil
    ) {
        self.name = name
        self.displayName = displayName ?? name
        self.kind = kind
        self.version = version
        self.latestVersion = latestVersion
        self.summary = summary
        self.homepage = homepage
        self.isInstalled = isInstalled
        self.isInstalledOnRequest = isInstalledOnRequest
        self.isPinned = isPinned
        self.isOutdated = isOutdated
        self.sizePath = sizePath
        self.bytes = bytes
    }
}

/// One line of `brew outdated`: what is installed and what it would be upgraded to.
public struct HomebrewOutdatedPackage: Identifiable, Sendable, Equatable {
    public let name: String
    public let kind: HomebrewPackageKind
    public let installedVersions: [String]
    public let currentVersion: String
    public let isPinned: Bool

    public var id: String { "\(kind.rawValue):\(name)" }
    public var installedVersion: String { installedVersions.last ?? "" }

    public init(name: String, kind: HomebrewPackageKind, installedVersions: [String], currentVersion: String, isPinned: Bool = false) {
        self.name = name
        self.kind = kind
        self.installedVersions = installedVersions
        self.currentVersion = currentVersion
        self.isPinned = isPinned
    }
}

// MARK: - Reading brew's JSON

public enum HomebrewJSONError: Error, Equatable {
    case unreadable
}

/// Reads `brew info --json=v2` and `brew outdated --json=v2`. Every field is optional on the way in: brew adds and
/// drops fields between versions, and one odd entry must not hide the rest.
public enum HomebrewJSON {
    private struct InfoDocument: Decodable {
        var formulae: [Formula]?
        var casks: [Cask]?
    }

    private struct Formula: Decodable {
        struct Versions: Decodable { var stable: String? }
        struct Installed: Decodable {
            var version: String?
            var installed_on_request: Bool?
        }
        var name: String?
        var full_name: String?
        var desc: String?
        var homepage: String?
        var versions: Versions?
        var installed: [Installed]?
        var pinned: Bool?
        var outdated: Bool?
    }

    private struct Cask: Decodable {
        var token: String?
        var full_token: String?
        var name: [String]?
        var desc: String?
        var homepage: String?
        var version: String?
        var installed: String?
        var pinned: Bool?
        var outdated: Bool?
        var artifacts: [Artifact]?
    }

    /// An entry of a cask's `artifacts`: only `{"app": ["X.app"], "target": "/Applications/X.app"}` matters here.
    private struct Artifact: Decodable {
        var app: [String]?
        var target: String?

        private enum Keys: String, CodingKey { case app, target }

        init(from decoder: Decoder) throws {
            guard let container = try? decoder.container(keyedBy: Keys.self) else { return }
            // `app` mixes strings and option objects; keep the strings.
            if var list = try? container.nestedUnkeyedContainer(forKey: .app) {
                var names: [String] = []
                while !list.isAtEnd {
                    if let name = try? list.decode(String.self) {
                        names.append(name)
                    } else {
                        _ = try? list.decode(Skip.self)
                    }
                }
                app = names
            }
            target = try? container.decode(String.self, forKey: .target)
        }
    }

    private struct Skip: Decodable {
        init(from decoder: Decoder) throws {}
    }

    private struct OutdatedDocument: Decodable {
        struct Entry: Decodable {
            var name: String?
            var installed_versions: [String]?
            var current_version: String?
            var pinned: Bool?
        }
        var formulae: [Entry]?
        var casks: [Entry]?
    }

    /// Packages from `brew info --json=v2 …` (with `--installed`, or for names a search found).
    /// `prefix` is Homebrew's prefix (`/opt/homebrew`), for a formula's Cellar folder.
    public static func packages(from data: Data, prefix: String? = nil) throws -> [HomebrewPackage] {
        guard let document = try? JSONDecoder().decode(InfoDocument.self, from: data) else {
            throw HomebrewJSONError.unreadable
        }
        let formulae: [HomebrewPackage] = (document.formulae ?? []).compactMap { formula in
            guard let shortName = formula.name ?? formula.full_name else { return nil }
            let installed = formula.installed ?? []
            let installedVersion = installed.last?.version
            return HomebrewPackage(
                name: formula.full_name ?? shortName,
                displayName: shortName,
                kind: .formula,
                version: installedVersion ?? formula.versions?.stable ?? "",
                latestVersion: formula.versions?.stable,
                summary: formula.desc,
                homepage: formula.homepage,
                isInstalled: !installed.isEmpty,
                isInstalledOnRequest: installed.contains { $0.installed_on_request ?? true } || installed.isEmpty,
                isPinned: formula.pinned ?? false,
                isOutdated: formula.outdated ?? false,
                sizePath: installed.isEmpty ? nil : prefix.map { "\($0)/Cellar/\(shortName)" }
            )
        }
        let casks: [HomebrewPackage] = (document.casks ?? []).compactMap { cask in
            guard let token = cask.full_token ?? cask.token else { return nil }
            let installedVersion = cask.installed.flatMap { $0.isEmpty ? nil : $0 }
            let app = (cask.artifacts ?? []).first { !($0.app ?? []).isEmpty }
            let appPath = app.flatMap { artifact in artifact.target ?? artifact.app?.first.map { "/Applications/\($0)" } }
            return HomebrewPackage(
                name: token,
                displayName: cask.name?.first ?? cask.token ?? token,
                kind: .cask,
                version: installedVersion ?? cask.version ?? "",
                latestVersion: cask.version,
                summary: cask.desc,
                homepage: cask.homepage,
                isInstalled: installedVersion != nil,
                isPinned: cask.pinned ?? false,
                isOutdated: cask.outdated ?? false,
                sizePath: installedVersion == nil ? nil : appPath
            )
        }
        return formulae + casks
    }

    /// Packages from `brew outdated --json=v2`.
    public static func outdated(from data: Data) throws -> [HomebrewOutdatedPackage] {
        guard let document = try? JSONDecoder().decode(OutdatedDocument.self, from: data) else {
            throw HomebrewJSONError.unreadable
        }
        func convert(_ entries: [OutdatedDocument.Entry]?, kind: HomebrewPackageKind) -> [HomebrewOutdatedPackage] {
            (entries ?? []).compactMap { entry in
                guard let name = entry.name else { return nil }
                return HomebrewOutdatedPackage(
                    name: name,
                    kind: kind,
                    installedVersions: entry.installed_versions ?? [],
                    currentVersion: entry.current_version ?? "",
                    isPinned: entry.pinned ?? false
                )
            }
        }
        return convert(document.formulae, kind: .formula) + convert(document.casks, kind: .cask)
    }

    /// Names from `brew search --formula|--cask …`: one per line. Headers (`==> Formulae`), blank lines and anything
    /// that is not a valid name are dropped.
    public static func searchNames(from output: String) -> [String] {
        var seen = Set<String>()
        return output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { HomebrewCommand.isValidPackageName($0) && seen.insert($0).inserted }
    }
}

// MARK: - Finding brew

/// Where `brew` is. An app started from Finder has no shell PATH, so the two standard places are checked directly.
public struct HomebrewLocator: Sendable {
    /// Apple silicon first, then Intel.
    public static let standardPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    public let candidates: [String]
    public let isExecutable: @Sendable (String) -> Bool

    public init(
        candidates: [String] = HomebrewLocator.standardPaths,
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.candidates = candidates
        self.isExecutable = isExecutable
    }

    public func locate() -> String? {
        candidates.first(where: isExecutable)
    }

    /// `/opt/homebrew/bin/brew` → `/opt/homebrew`.
    public static func prefix(forBrewAt path: String) -> String {
        let bin = (path as NSString).deletingLastPathComponent
        return (bin as NSString).deletingLastPathComponent
    }
}

// MARK: - Command lines

/// Something the queue runs. Each one is a single `brew` command.
public enum HomebrewOperation: Sendable, Equatable {
    case install(name: String, kind: HomebrewPackageKind)
    case uninstall(name: String, kind: HomebrewPackageKind)
    /// Upgrades exactly these packages of one kind (never "everything that is outdated now").
    case upgrade(names: [String], kind: HomebrewPackageKind)
    case update

    /// The arguments after `brew`.
    public var arguments: [String] {
        switch self {
        case .install(let name, let kind): return ["install", kind.flag, name]
        case .uninstall(let name, let kind): return ["uninstall", kind.flag, name]
        case .upgrade(let names, let kind): return ["upgrade", kind.flag] + names
        case .update: return ["update"]
        }
    }

    /// Every package name it touches is safe to pass as an argument.
    public var hasValidNames: Bool {
        switch self {
        case .install(let name, _), .uninstall(let name, _): return HomebrewCommand.isValidPackageName(name)
        case .upgrade(let names, _): return !names.isEmpty && names.allSatisfy(HomebrewCommand.isValidPackageName)
        case .update: return true
        }
    }

    /// What the activity line says while it runs.
    public var title: String {
        switch self {
        case .install(let name, _): return String(localized: "Installing \(name)")
        case .uninstall(let name, _): return String(localized: "Uninstalling \(name)")
        case .upgrade(let names, _):
            return names.count == 1
                ? String(localized: "Upgrading \(names[0])")
                : String(localized: "Upgrading \(names.count) packages")
        case .update: return String(localized: "Updating Homebrew")
        }
    }
}

public enum HomebrewCommand {
    /// Set for every command: no surprise `brew update` before an install, and no "Hide these hints with…" lines.
    public static let environment = ["HOMEBREW_NO_AUTO_UPDATE=1", "HOMEBREW_NO_ENV_HINTS=1", "HOMEBREW_NO_COLOR=1"]

    /// Runs through `/usr/bin/env` so the variables reach brew without touching Zenith's own environment, and the
    /// existing `SystemCommandRunner` (which takes no environment) can run it.
    public static func invocation(brew: String, arguments: [String]) -> (executable: String, arguments: [String]) {
        ("/usr/bin/env", environment + [brew] + arguments)
    }

    /// The same command to paste into Terminal (where sudo can ask for the password).
    public static func terminalCommand(brew: String, arguments: [String]) -> String {
        ([brew] + arguments).map(shellQuoted).joined(separator: " ")
    }

    /// A formula, cask or `tap/name` — letters, digits and `@ + . _ - /` — that cannot be taken for an option.
    public static func isValidPackageName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 200, let first = name.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(first) else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@+._-/")
        return name.unicodeScalars.allSatisfy(allowed.contains) && !name.contains("..")
    }

    /// What may be passed to `brew search`: not empty, and not something brew would read as an option.
    public static func normalizedQuery(_ query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 100, !trimmed.hasPrefix("-"),
              !trimmed.contains(where: \.isNewline) else { return nil }
        return trimmed
    }

    static func shellQuoted(_ word: String) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@+._-/=:,")
        if !word.isEmpty, word.unicodeScalars.allSatisfy(plain.contains) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - What went wrong

/// Why a command failed, in words the user can act on.
public enum HomebrewFailure: Sendable, Equatable {
    /// The package asked for an administrator password (sudo), which an app cannot answer.
    case needsPassword(terminalCommand: String)
    case notFound(name: String?)
    /// Another brew process holds the lock.
    case busy
    case network
    case cancelled
    case couldNotStart
    case failed(status: Int32, detail: String)

    public var message: String {
        switch self {
        case .needsPassword:
            return String(localized: "This package needs your administrator password, which Zenith cannot ask for. Run the command in Terminal instead.")
        case .notFound(let name):
            if let name {
                return String(localized: "Homebrew has no package named \(name).")
            }
            return String(localized: "Homebrew could not find that package.")
        case .busy:
            return String(localized: "Another Homebrew command is running. Wait for it to finish and try again.")
        case .network:
            return String(localized: "Homebrew could not download what it needed. Check your internet connection and try again.")
        case .cancelled:
            return String(localized: "Cancelled.")
        case .couldNotStart:
            return String(localized: "Homebrew could not be started.")
        case .failed(let status, let detail):
            if detail.isEmpty {
                return String(localized: "Homebrew stopped with exit code \(String(status)).")
            }
            return detail
        }
    }

    public var terminalCommand: String? {
        if case .needsPassword(let command) = self { return command }
        return nil
    }

    /// `nil` when the command succeeded.
    public static func classify(
        status: Int32?,
        output: String,
        wasCancelled: Bool,
        operation: HomebrewOperation,
        brew: String
    ) -> HomebrewFailure? {
        if wasCancelled { return .cancelled }
        guard let status else { return .couldNotStart }
        guard status != 0 else { return nil }
        let lower = output.lowercased()

        let passwordSigns = [
            "sudo: a terminal is required",
            "sudo: no tty present",
            "sudo: a password is required",
            "sudo: unable to read password",
            "no askpass program",
            "must be run as root"
        ]
        if passwordSigns.contains(where: lower.contains) {
            return .needsPassword(terminalCommand: HomebrewCommand.terminalCommand(brew: brew, arguments: operation.arguments))
        }
        if lower.contains("has already locked") || lower.contains("another active homebrew") || lower.contains("is already in progress") {
            return .busy
        }
        if lower.contains("no available formula") || lower.contains("no cask with this name") || lower.contains("no formulae or casks found")
            || lower.contains("is unavailable") {
            switch operation {
            case .install(let name, _), .uninstall(let name, _): return .notFound(name: name)
            default: return .notFound(name: nil)
            }
        }
        if lower.contains("curl: (") || lower.contains("failed to download") || lower.contains("could not resolve host")
            || lower.contains("failed to connect") || lower.contains("connection timed out") {
            return .network
        }
        return .failed(status: status, detail: errorLine(in: output))
    }

    /// brew's own explanation: the last `Error: …` line (with the line after it when it ends in a colon), or the
    /// last line it printed.
    static func errorLine(in output: String) -> String {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let index = lines.lastIndex(where: { $0.hasPrefix("Error:") }) {
            var line = String(lines[index].dropFirst("Error:".count)).trimmingCharacters(in: .whitespaces)
            if line.hasSuffix(":"), index + 1 < lines.count {
                line += " " + lines[index + 1]
            }
            return String(line.prefix(400))
        }
        return String((lines.last ?? "").prefix(400))
    }
}

// MARK: - The log

/// The text of the activity log: brew's output as it streams, made readable and kept to a bounded size.
public struct HomebrewLog: Sendable, Equatable {
    public private(set) var text = ""
    public let limit: Int

    public init(limit: Int = 60_000) {
        self.limit = limit
    }

    /// Adds a chunk of output: colour codes go, carriage returns (progress bars) become line breaks, and the oldest
    /// lines are dropped once the log is longer than `limit`.
    public mutating func append(_ chunk: String) {
        text += Self.clean(chunk)
        if text.count > limit {
            var trimmed = String(text.suffix(limit))
            if let newline = trimmed.firstIndex(of: "\n") {
                trimmed = String(trimmed[trimmed.index(after: newline)...])
            }
            text = trimmed
        }
    }

    public mutating func appendCommandLine(_ line: String) {
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        append("$ \(line)\n")
    }

    public mutating func clear() {
        text = ""
    }

    static func clean(_ chunk: String) -> String {
        var result = chunk.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        result = result.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        return result
    }
}
