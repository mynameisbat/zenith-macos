// swift-tools-version: 6.0
import Foundation
import PackageDescription

// With only the Command Line Tools selected, `swift test` does not load the Swift Testing macro plugin by itself, so
// it is named explicitly. With full Xcode selected (as on CI) the toolchain provides the plugin, and naming a second
// copy would conflict with it. So the flag is added only when the Command Line Tools are the active developer
// directory, and only if the plugin is really there.
let activeDeveloperDirectory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
    ?? (try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link"))
    ?? "/Library/Developer/CommandLineTools"
let commandLineToolsTestingMacros = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
let testingMacroSettings: [SwiftSetting] =
    activeDeveloperDirectory.hasPrefix("/Library/Developer/CommandLineTools")
        && FileManager.default.fileExists(atPath: commandLineToolsTestingMacros)
    ? [.unsafeFlags(["-Xfrontend", "-load-plugin-library", "-Xfrontend", commandLineToolsTestingMacros])]
    : []

let package = Package(
    name: "Zenith",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "ZenithCore",
            targets: ["ZenithCore"]
        ),
        .executable(
            name: "Zenith",
            targets: ["ZenithApp"]
        ),
        // Loaded into /usr/bin/perl to read the system's Now Playing (see the target below). Never linked into the app.
        .library(
            name: "ZenithNowPlayingAdapter",
            type: .dynamic,
            targets: ["ZenithNowPlayingAdapter"]
        )
    ],
    dependencies: [],
    targets: [
        // Core business logic, protocols, domain models, and test mocks
        .target(
            name: "ZenithCore",
            dependencies: [],
            path: "Sources/ZenithCore"
        ),
        // macOS application layer: NSApplication, Menu Bar, Windows & SwiftUI Views
        .executableTarget(
            name: "ZenithApp",
            dependencies: [
                "ZenithCore"
            ],
            path: "Sources/ZenithApp"
        ),
        // C-callable glue around the private MediaRemote framework. It runs inside a perl process, on its own, so it
        // uses the Swift 5 language mode: its state is guarded by one serial queue rather than by actor isolation.
        .target(
            name: "ZenithNowPlayingAdapter",
            dependencies: [],
            path: "Sources/ZenithNowPlayingAdapter",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Modern Swift Testing test suites (Tiers 1-4)
        .testTarget(
            name: "ZenithCoreTests",
            dependencies: [
                "ZenithCore"
            ],
            path: "Tests/ZenithCoreTests",
            swiftSettings: testingMacroSettings
        )
    ]
)
