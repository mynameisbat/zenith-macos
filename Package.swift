// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Zenith",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "ZenithCore",
            targets: ["ZenithCore"]
        ),
        .executable(
            name: "Zenith",
            targets: ["ZenithApp"]
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
        // Modern Swift Testing test suites (Tiers 1-4)
        .testTarget(
            name: "ZenithCoreTests",
            dependencies: [
                "ZenithCore"
            ],
            path: "Tests/ZenithCoreTests",
            swiftSettings: [
                .unsafeFlags([
                    "-Xfrontend",
                    "-load-plugin-library",
                    "-Xfrontend",
                    "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
                ])
            ]
        )
    ]
)
