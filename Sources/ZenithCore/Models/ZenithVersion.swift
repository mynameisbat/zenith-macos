import Foundation

/// The single place the app's version is declared. `scripts/bundle_app.sh` and `scripts/create_dmg.sh` read it from
/// here, so the command-line `--version`, the bundle's Info.plist and the DMG name cannot drift apart.
public enum ZenithVersion {
    public static let current = "2.2.0"
    public static let build = "3"
}
