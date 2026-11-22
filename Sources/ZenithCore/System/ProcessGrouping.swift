import Foundation

/// Folds an app's helper processes into the app. Chrome runs a renderer per tab, Claude and Slack run "Helper"
/// processes: listed one by one they fill the Running Apps list with names such as "Google Chrome Helper (Renderer)"
/// and no icon. A process belongs to the outermost `.app` its executable sits in (`ProcessTelemetry.appBundlePath`),
/// so a helper inside `Chrome.app/Contents/Frameworks/… Helper.app/` is one of Chrome's. Pure: it only looks at the
/// records it is given, so it is tested with made-up processes.
public enum ProcessGrouping {
    /// One record per app (its name is the bundle's, its CPU and memory the sums of all its processes, its PID the
    /// app's own main process, which is the one to ask to quit), and every process that is not in an app as it was.
    /// The order of first appearance is kept.
    public static func grouped(_ processes: [ProcessTelemetry]) -> [ProcessTelemetry] {
        var order: [String] = []
        var members: [String: [ProcessTelemetry]] = [:]
        var result: [(key: String, single: ProcessTelemetry?)] = []

        for process in processes {
            guard let bundle = process.appBundlePath else {
                result.append((key: "pid:\(process.pid)", single: process))
                continue
            }
            if members[bundle] == nil {
                order.append(bundle)
                result.append((key: bundle, single: nil))
            }
            members[bundle, default: []].append(process)
        }

        return result.compactMap { entry in
            if let single = entry.single { return single }
            guard let group = members[entry.key] else { return nil }
            return merged(group, bundlePath: entry.key)
        }
    }

    /// The name an app is shown under: its bundle's file name without `.app`.
    public static func appName(bundlePath: String) -> String {
        let last = (bundlePath as NSString).lastPathComponent
        return last.hasSuffix(".app") ? String(last.dropLast(4)) : last
    }

    private static func merged(_ group: [ProcessTelemetry], bundlePath: String) -> ProcessTelemetry {
        let main = mainProcess(of: group)
        return ProcessTelemetry(
            pid: main.pid,
            ppid: main.ppid,
            name: appName(bundlePath: bundlePath),
            command: main.command,
            cpuPercent: group.reduce(0) { $0 + $1.cpuPercent },
            memoryPercent: group.reduce(0) { $0 + $1.memoryPercent },
            memoryBytes: group.reduce(0) { $0 + $1.memoryBytes },
            state: main.state,
            isZombie: false,
            processCount: group.reduce(0) { $0 + $1.processCount }
        )
    }

    /// The process to stand for the app: one whose executable is the bundle's own (`…/X.app/Contents/MacOS/X`, no
    /// other `.app` after it), the lowest PID if several; else the one using the most memory.
    private static func mainProcess(of group: [ProcessTelemetry]) -> ProcessTelemetry {
        let own = group.filter { isBundleExecutable($0.command) }
        if let first = own.min(by: { $0.pid < $1.pid }) { return first }
        return group.max(by: { $0.memoryBytes < $1.memoryBytes }) ?? group[0]
    }

    private static func isBundleExecutable(_ command: String) -> Bool {
        guard let range = command.range(of: ".app/") else { return false }
        return !command[range.upperBound...].contains(".app/")
    }
}
