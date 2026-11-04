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
            print("Screen Recording is not granted to this process (or to the app that started it), so neither method can")
            print("see other apps' windows. Grant it in System Settings → Privacy & Security → Screen Recording and run again.")
            return 2
        }

        var failed = false
        if let image = CGDisplayCreateImage(displayID) {
            print("CGDisplayCreateImage:  \(image.width) x \(image.height) pixels")
        } else {
            print("CGDisplayCreateImage:  returned nothing (the fallback would be used)")
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
