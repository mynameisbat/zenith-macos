import Foundation

/// Reopens Zenith after an update: a detached `/bin/sh` child that waits for this process to exit, then `open`s the
/// app, like `ProxyWatchdog` waits for the app's PID. The PID and the path are passed as arguments, never put into
/// the script's text. If the old process is still there after `timeoutSeconds`, it gives up without opening anything.
public enum RelaunchHelper {
    /// Arguments: PID, app path, time limit in seconds. `OPEN` in the environment replaces `/usr/bin/open` (tests).
    static let script = """
    trap '' HUP INT
    pid="$1"; app="$2"; limit="$3"
    open_tool="${OPEN:-/usr/bin/open}"
    ticks=0
    while kill -0 "$pid" 2>/dev/null; do
      ticks=$((ticks + 1))
      if [ "$ticks" -gt $((limit * 5)) ]; then exit 1; fi
      sleep 0.2
    done
    sleep 0.5
    exec "$open_tool" "$app"
    """

    public static let defaultTimeoutSeconds = 60

    /// Starts the helper and returns its process (nil if it could not start). The caller then quits normally.
    @discardableResult
    public static func start(
        appPath: String,
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        timeoutSeconds: Int = defaultTimeoutSeconds,
        environment: [String: String] = [:]
    ) -> Process? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "zenith-relaunch", String(pid), appPath, String(max(1, timeoutSeconds))]
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            NSLog("[Updater] Could not start the relaunch helper: %@", "\(error)")
            return nil
        }
        return process
    }
}
