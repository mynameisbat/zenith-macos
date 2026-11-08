import Foundation
import Darwin

/// The number of files and sockets a process may hold open.
///
/// An app started from Finder or the Dock gets a soft limit of 256 from launchd (a Terminal shell has far more, which
/// is why it never shows when running from the command line). Every tunnel the proxy carries uses two sockets, so with
/// 256 a busy browser tab or two would use them all and new connections would start to fail.
public enum FileDescriptorLimit {
    /// What the proxy asks for. 10 240 is `OPEN_MAX`, the value macOS documents as always accepted.
    public static let desired: UInt64 = 10_240

    /// The soft limit to set: `desired` if the hard limit and the system's per-process maximum allow it, otherwise
    /// the most they allow. Never lower than `current`.
    public static func targetSoftLimit(current: UInt64, hard: UInt64, perProcessMaximum: UInt64, desired: UInt64 = FileDescriptorLimit.desired) -> UInt64 {
        max(current, min(desired, hard, perProcessMaximum))
    }

    /// Raises the soft limit towards `desired`; does nothing when it is already there. Returns the soft limit in force
    /// afterwards (0 if it could not be read).
    @discardableResult
    public static func raiseSoftLimit(desired: UInt64 = FileDescriptorLimit.desired) -> UInt64 {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return 0 }
        let current = UInt64(limit.rlim_cur)

        var perProcess: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let known = sysctlbyname("kern.maxfilesperproc", &perProcess, &size, nil, 0) == 0 && perProcess > 0
        let target = targetSoftLimit(
            current: current,
            hard: UInt64(limit.rlim_max),
            perProcessMaximum: known ? UInt64(perProcess) : desired,
            desired: desired
        )
        guard target > current else { return current }

        limit.rlim_cur = rlim_t(target)
        if setrlimit(RLIMIT_NOFILE, &limit) == 0 { return target }
        NSLog("[PrivacyShield] Could not raise the open-file limit (errno %d)", errno)
        return current
    }
}
