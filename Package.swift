// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GoldenGate",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "GoldenGateCore",
            targets: ["GoldenGateCore"]
        ),
        .executable(
            name: "GoldenGateApp",
            targets: ["GoldenGateApp"]
        )
    ],
    dependencies: [],
    targets: [
        // Core business logic, protocols, domain models, and test mocks
        .target(
            name: "GoldenGateCore",
            dependencies: [],
            path: "Sources/GoldenGateCore"
        ),
        // macOS application layer: NSApplication, Menu Bar, Windows & SwiftUI Views
        .executableTarget(
            name: "GoldenGateApp",
            dependencies: [
                "GoldenGateCore"
            ],
            path: "Sources/GoldenGateApp"
        ),
        // Modern Swift Testing test suites (Tiers 1-4)
        .testTarget(
            name: "GoldenGateCoreTests",
            dependencies: [
                "GoldenGateCore"
            ],
            path: "Tests/GoldenGateCoreTests",
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
