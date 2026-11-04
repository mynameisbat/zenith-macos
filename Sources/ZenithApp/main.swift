import AppKit
import ZenithCore

// 1. CLI arguments handling for fast verification and CI automation
let arguments = CommandLine.arguments

if arguments.contains("--version") {
    print("Zenith \(ZenithVersion.current)")
    exit(0)
}

if arguments.contains("--smoke-test") {
    print("ZenithApp: Smoke test passed successfully.")
    exit(0)
}

if arguments.contains("--check-screen-capture") {
    // Runs both capture paths and compares them. Needs the Screen Recording permission of whatever started it.
    final class ExitCode: @unchecked Sendable { var value: Int32 = 0 }
    let result = ExitCode()
    let finished = DispatchSemaphore(value: 0)
    Task.detached {
        result.value = await ScreenCaptureDiagnostic.run()
        finished.signal()
    }
    finished.wait()
    exit(result.value)
}

if arguments.contains("--help") {
    print("""
    Zenith \(ZenithVersion.current) - Precision Mac Workspace
    Usage:
      swift run Zenith [options]

    Options:
      --smoke-test    Verify executable launch and exit immediately
      --version       Print application version
      --check-screen-capture
                      Capture the main display with both methods and compare them (needs Screen Recording permission)
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
