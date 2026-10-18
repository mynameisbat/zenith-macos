import AppKit
import GoldenGateCore

// 1. CLI arguments handling for fast verification and CI automation
let arguments = CommandLine.arguments

if arguments.contains("--version") {
    print("Zenith 2.0.0")
    exit(0)
}

if arguments.contains("--smoke-test") {
    print("ZenithApp: Smoke test passed successfully.")
    exit(0)
}

if arguments.contains("--help") {
    print("""
    Zenith 2.0 - Precision Mac Workspace
    Usage:
      swift run GoldenGateApp [options]

    Options:
      --smoke-test    Verify executable launch and exit immediately
      --version       Print application version
      --help          Show this help message
    """)
    exit(0)
}


// 2. Initialize NSApplication singleton
let app = NSApplication.shared

// 3. Set activation policy to .accessory BEFORE running event loop
// Suppresses Dock icon and Cmd-Tab application switcher
app.setActivationPolicy(.accessory)

// 4. Instantiate and assign application delegate
let delegate = AppDelegate()
app.delegate = delegate

// 5. Start main AppKit event loop
app.run()
