import Foundation

/// Exit status and captured output of a finished system command.
public struct SystemCommandResult: Sendable {
    public let status: Int32
    public let output: String
    public let errorOutput: String

    public init(status: Int32, output: String, errorOutput: String = "") {
        self.status = status
        self.output = output
        self.errorOutput = errorOutput
    }
}

/// Runs an executable and returns its result, or `nil` when it could not be launched.
/// Services take one of these so tests can stand in for `networksetup`, `lipo`, `codesign` and friends.
public typealias SystemCommandRunner = @Sendable (_ executable: String, _ arguments: [String]) -> SystemCommandResult?

public enum SystemCommand {
    private final class DataBox: @unchecked Sendable {
        var data = Data()
    }

    /// Runs a real process. Both output pipes are drained before waiting for exit, so a child that writes more than
    /// a pipe buffer holds (64 KiB) can never block forever.
    public static let processRunner: SystemCommandRunner = { executable, arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            NSLog("[SystemCommand] Execution failed for \(executable) \(arguments.first ?? ""): \(error)")
            return nil
        }

        // The error pipe is drained on a dedicated thread, not a dispatch queue: this function blocks its caller, and
        // callers can be the very threads a shared queue would need to run on (many at once exhaust it and every
        // call then waits forever).
        let errorBox = DataBox()
        let errorDrained = DispatchSemaphore(value: 0)
        let errorReader = Thread {
            errorBox.data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            errorDrained.signal()
        }
        errorReader.start()
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        errorDrained.wait()
        process.waitUntilExit()

        return SystemCommandResult(
            status: process.terminationStatus,
            output: String(decoding: outputData, as: UTF8.self),
            errorOutput: String(decoding: errorBox.data, as: UTF8.self)
        )
    }
}
