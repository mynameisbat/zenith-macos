import Foundation
@testable import ZenithCore

/// A `SystemCommandRunner` that runs nothing and remembers what it was asked to run, so tests can check which
/// system commands a service would issue without changing the machine they run on.
final class RecordingCommandRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var _commands: [[String]] = []
    private var _failing: Set<String> = []
    private var _outputs: [String: String] = [:]

    /// Executable names (e.g. "killall") that should exit non-zero.
    var failing: Set<String> {
        get { lock.withLock { _failing } }
        set { lock.withLock { _failing = newValue } }
    }

    /// Canned standard output per executable name.
    var outputs: [String: String] {
        get { lock.withLock { _outputs } }
        set { lock.withLock { _outputs = newValue } }
    }

    /// Each entry is the executable's file name followed by its arguments.
    var commands: [[String]] { lock.withLock { _commands } }

    func didRun(_ executableName: String, containing argument: String? = nil) -> Bool {
        commands.contains { $0.first == executableName && (argument == nil || $0.contains(argument!)) }
    }

    var runner: SystemCommandRunner {
        { [self] executable, arguments in
            let name = URL(fileURLWithPath: executable).lastPathComponent
            return lock.withLock {
                _commands.append([name] + arguments)
                return SystemCommandResult(
                    status: _failing.contains(name) ? 1 : 0,
                    output: _outputs[name] ?? "",
                    errorOutput: _failing.contains(name) ? "\(name): failed" : ""
                )
            }
        }
    }
}
