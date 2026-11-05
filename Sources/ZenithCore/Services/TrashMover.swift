import Foundation

/// Moves a file or folder to the Trash.
///
/// `FileManager.trashItem` is refused with "you don't have permission" (NSCocoaErrorDomain 513) for some places that
/// macOS protects from other apps, notably the folders inside `~/Library/Containers`; Terminal cannot even `rm` them.
/// Finder is allowed to, so a refusal is retried through Finder (needs the user's Automation permission for it, which
/// macOS asks for once). If that fails too, the error says what to do instead of just "no permission".
public struct TrashMover: Sendable {
    public enum Failure: Error, LocalizedError, Equatable {
        /// Neither Zenith nor Finder (as far as Zenith is allowed to ask it) could move the item.
        case protectedByMacOS(name: String)

        public var errorDescription: String? {
            switch self {
            case .protectedByMacOS(let name):
                return "macOS protects “\(name)” (it belongs to another app), so Zenith could not move it to the Trash. Allow Zenith to control Finder when macOS asks (System Settings → Privacy & Security → Automation), or give Zenith Full Disk Access, then try again. You can also delete it yourself in Finder."
            }
        }
    }

    private let trashDirectly: @Sendable (URL) throws -> Void
    private let runCommand: SystemCommandRunner
    private let itemExists: @Sendable (URL) -> Bool

    public init(
        trashDirectly: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
        runCommand: @escaping SystemCommandRunner = SystemCommand.processRunner,
        itemExists: @escaping @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) {
        self.trashDirectly = trashDirectly
        self.runCommand = runCommand
        self.itemExists = itemExists
    }

    public static let system = TrashMover()

    /// Whether this is the refusal that Finder may still be able to get around.
    static func isPermissionRefusal(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSCocoaErrorDomain else { return false }
        return nsError.code == NSFileWriteNoPermissionError || nsError.code == NSFileReadNoPermissionError
    }

    /// AppleScript that asks Finder to move one path to the Trash, with a time limit so a permission prompt that
    /// nobody answers cannot hang the caller.
    static func finderScript(for path: String) -> String {
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return """
        with timeout of 20 seconds
            tell application "Finder" to delete (POSIX file "\(escaped)")
        end timeout
        """
    }

    public func move(_ url: URL) throws {
        do {
            try trashDirectly(url)
        } catch {
            guard Self.isPermissionRefusal(error) else { throw error }
            let result = runCommand("/usr/bin/osascript", ["-e", Self.finderScript(for: url.path)])
            guard let result, result.status == 0, !itemExists(url) else {
                throw Failure.protectedByMacOS(name: url.lastPathComponent)
            }
        }
    }
}
