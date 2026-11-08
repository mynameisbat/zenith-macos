import AppKit
import CoreGraphics
import ZenithCore

/// `Zenith --check-screen-capture`: takes the main display with the CoreGraphics call and with ScreenCaptureKit (the
/// fallback `NativeScreenCaptureBackend` uses when the first returns nothing) and says whether they agree.
enum ScreenCaptureDiagnostic {
    static func run() async -> Int32 {
        let backend = NativeScreenCaptureBackend()
        let displayID = CGMainDisplayID()
        let bounds = CGDisplayBounds(displayID)
        // The display's own pixel size (NSScreen's scale is unreliable outside a running app).
        let mode = CGDisplayCopyDisplayMode(displayID)
        let expected = (mode?.pixelWidth ?? Int(bounds.width), mode?.pixelHeight ?? Int(bounds.height))
        print("Main display: \(Int(bounds.width)) x \(Int(bounds.height)) points")
        print("Expected capture: \(expected.0) x \(expected.1) pixels")

        guard backend.hasScreenRecordingPermission else {
            // macOS lists an app under Screen Recording only after it has asked, so ask: a dialog naming the app that
            // started this command appears (once), and that app then shows up in the list to be switched on.
            _ = CGRequestScreenCaptureAccess()
            print("Screen Recording is not granted to this process (or to the app that started it).")
            print("A permission dialog should have appeared. Open System Settings → Privacy & Security → Screen Recording,")
            print("switch on the app named in the dialog, quit and reopen that app, then run this command again.")
            return 2
        }

        var failed = false
        let coreGraphicsImage = CGDisplayCreateImage(displayID)
        if let image = coreGraphicsImage {
            print("CGDisplayCreateImage:  \(image.width) x \(image.height) pixels")
        } else {
            print("CGDisplayCreateImage:  returned nothing (the fallback would be used)")
        }

        guard #available(macOS 14, *) else {
            // ScreenCaptureKit's screenshot call arrives with macOS 14, so on macOS 13 there is no fallback to compare.
            print("ScreenCaptureKit:      not available before macOS 14; CGDisplayCreateImage is the only capture path")
            print(coreGraphicsImage == nil ? "RESULT: the display could not be captured" : "RESULT: the display is captured")
            return coreGraphicsImage == nil ? 1 : 0
        }

        do {
            if let image = try await backend.captureViaScreenCaptureKit(displayID: displayID) {
                print("ScreenCaptureKit:      \(image.width) x \(image.height) pixels")
                if image.width != expected.0 || image.height != expected.1 {
                    print("  -> not the display's native resolution")
                    failed = true
                }
            } else {
                print("ScreenCaptureKit:      returned nothing")
                failed = true
            }
        } catch {
            print("ScreenCaptureKit:      failed: \(error.localizedDescription)")
            failed = true
        }
        print(failed ? "RESULT: the fallback does not match" : "RESULT: the fallback captures at the display's native resolution")
        return failed ? 1 : 0
    }
}
