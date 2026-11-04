import Foundation

/// Throwaway `UserDefaults` suites for tests.
///
/// `UserDefaults(suiteName:)` writes `~/Library/Preferences/<suite>.plist` for the machine running the tests, and the
/// tests used a fresh UUID suite each time and never removed it: tens of thousands of files piled up there. Suites
/// made here are all named `zenith.tests.*`, which `scripts/test_each_suite.sh` deletes after each suite. (Cleaning up
/// inside the process does not work: `removePersistentDomain` only empties the plist, and `cfprefsd` writes pending
/// changes back after the process is gone.)
enum TestDefaults {
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var names: Set<String> = []
        var hookInstalled = false
    }

    private static let registry = Registry()

    static let prefix = "zenith.tests."

    /// Same as `UserDefaults(suiteName:)`, with the name prefixed so the file it creates can be recognised.
    static func make(_ requestedName: String) -> UserDefaults? {
        let suiteName = requestedName.hasPrefix(prefix) ? requestedName : prefix + requestedName
        guard let defaults = UserDefaults(suiteName: suiteName) else { return nil }
        registry.lock.withLock {
            registry.names.insert(suiteName)
            if !registry.hookInstalled {
                registry.hookInstalled = true
                atexit { TestDefaults.removeAll() }
            }
        }
        return defaults
    }

    fileprivate static func removeAll() {
        let names = registry.lock.withLock { registry.names }
        let preferences = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Preferences", isDirectory: true)
        for name in names {
            UserDefaults.standard.removePersistentDomain(forName: name)
            // Only files this helper named: "<suite>.plist" for a suite it created.
            if let preferences {
                try? FileManager.default.removeItem(at: preferences.appendingPathComponent("\(name).plist"))
            }
        }
    }
}
