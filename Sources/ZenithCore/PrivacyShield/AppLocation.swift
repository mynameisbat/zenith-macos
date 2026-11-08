import Foundation

/// Where the running app lives, as far as Privacy Shield cares.
///
/// An app opened from a mounted disk image (or an external drive) stops working the moment that volume goes away: its
/// code is paged in from the volume as it runs, and the process dies with a bus error. With Privacy Shield on, that
/// leaves the system proxy pointing at a listener that no longer exists, and the Mac without internet until Zenith is
/// started again from somewhere permanent.
public enum AppLocation {
    /// Whether `path` is on a volume mounted under `/Volumes` (a disk image, an external drive, a network share).
    /// The boot volume's own `/Volumes/Macintosh HD` entry is a symbolic link to `/`, which resolves away.
    public static func isOnMountedVolume(_ path: String) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        return resolved.hasPrefix("/Volumes/")
    }

    /// Whether `path` lies on the volume mounted at `volumePath`.
    public static func isPath(_ path: String, onVolumeMountedAt volumePath: String) -> Bool {
        let volume = URL(fileURLWithPath: volumePath).standardizedFileURL.path
        guard volume != "/" else { return false }   // the boot volume is not one this guards against
        let candidate = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        return candidate == volume || candidate.hasPrefix(volume + "/")
    }
}
