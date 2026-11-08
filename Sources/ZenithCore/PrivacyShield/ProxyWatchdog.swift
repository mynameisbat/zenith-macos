import Foundation

/// A small separate process that gets the user back online if Zenith dies while Privacy Shield is on.
///
/// The system proxy points at Zenith's listener; when Zenith is killed, crashes, or loses the disk image it ran from,
/// nothing is listening and every browser loses its connection until Zenith is opened again. The app cannot fix that
/// itself, because it is gone. This process outlives it: it waits for the app's PID to disappear, and then, only if the
/// proxy still points at Zenith's port and nothing is listening there, switches that proxy off. The next launch of
/// Zenith still restores the user's own earlier settings (`SystemProxyManager.recoverFromUncleanShutdown`).
///
/// It runs `/bin/sh` with system tools only, none of which live on a volume that can go away, and it does nothing in
/// the cases where acting would be wrong: a normal quit (the proxy is already back), or a new Zenith that has taken
/// over the port.
public final class ProxyWatchdog: @unchecked Sendable {
    /// Arguments: the app's PID, the shield's port, the network service name. Paths of the tools can be replaced with
    /// `NETWORKSETUP` and `NC` in the environment, and its waits with `CHECK_SECONDS` and `SETTLE_SECONDS`; that is how
    /// the tests run it.
    static let script = """
    trap '' HUP INT
    pid="$1"; port="$2"; service="$3"
    networksetup="${NETWORKSETUP:-/usr/sbin/networksetup}"
    nc="${NC:-/usr/bin/nc}"
    interval="${CHECK_SECONDS:-2}"
    while kill -0 "$pid" 2>/dev/null; do sleep "$interval"; done
    sleep "${SETTLE_SECONDS:-1}"
    # A Zenith that is listening on the port again (relaunched) owns the proxy now.
    if "$nc" -z 127.0.0.1 "$port" >/dev/null 2>&1; then exit 0; fi
    for kind in web secureweb; do
      info="$("$networksetup" "-get${kind}proxy" "$service" 2>/dev/null)"
      case "$info" in
        *"Enabled: Yes"*) ;;
        *) continue ;;
      esac
      printf '%s\\n' "$info" | grep -q '^Server: 127\\.0\\.0\\.1$' || continue
      printf '%s\\n' "$info" | grep -q "^Port: $port\\$" || continue
      "$networksetup" "-set${kind}proxystate" "$service" off
    done
    """

    private let lock = NSLock()
    private var process: Process?

    public init() {}

    /// Starts watching `appPID`. Replaces a watchdog started before.
    @discardableResult
    public func start(
        port: UInt16,
        service: String,
        appPID: Int32 = ProcessInfo.processInfo.processIdentifier,
        environment: [String: String] = [:]
    ) -> Bool {
        stop()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", Self.script, "zenith-watchdog", String(appPID), String(port), service]
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            NSLog("[ProxyWatchdog] Could not start: %@", "\(error)")
            return false
        }
        lock.lock()
        self.process = process
        lock.unlock()
        return true
    }

    /// Ends the watchdog (the proxy was restored normally, so there is nothing left to guard).
    public func stop() {
        lock.lock()
        let running = process
        process = nil
        lock.unlock()
        if let running, running.isRunning { running.terminate() }
    }

    /// Whether the watchdog process is alive.
    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return process?.isRunning == true
    }
}
