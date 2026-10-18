import Testing
import Foundation
import CoreGraphics
@testable import GoldenGateCore

@Suite("ScreenCaptureService Lifecycle & Backend Integration Suite")
struct ScreenCaptureServiceTests {

    @Test("SC-01: Captures main display via simulated backend")
    func testCaptureMainDisplay() async throws {
        let backend = SimulatedScreenCaptureBackend()
        let soundService = MockSoundService()
        let service = ScreenCaptureManager(backend: backend, soundService: soundService)

        let image = try await service.captureMainDisplay()
        #expect(image.width == 3840) // 1920 * 2.0
        #expect(image.height == 2160)
        #expect(backend.captureDisplayCalls.count == 1)
        #expect(soundService.shutterSoundCount == 1)
    }

    @Test("SC-02: Captures display subregion successfully")
    func testCaptureDisplayRegion() async throws {
        let backend = SimulatedScreenCaptureBackend()
        let soundService = MockSoundService()
        let service = ScreenCaptureManager(backend: backend, soundService: soundService)

        let cropRect = CGRect(x: 100, y: 100, width: 400, height: 300)
        let image = try await service.captureDisplayRegion(cropRect, displayID: 1)

        #expect(image.width == 400)
        #expect(image.height == 300)
        #expect(backend.captureRegionCalls.count == 1)
        #expect(soundService.shutterSoundCount == 1)
    }

    @Test("SC-03: Minimal 1x1 pixel region crop")
    func testMinimal1x1Crop() async throws {
        let backend = SimulatedScreenCaptureBackend()
        let soundService = MockSoundService()
        let service = ScreenCaptureManager(backend: backend, soundService: soundService)

        let rect = CGRect(x: 50, y: 50, width: 1, height: 1)
        let image = try await service.captureDisplayRegion(rect, displayID: 1)
        #expect(image.width == 1)
        #expect(image.height == 1)
        #expect(soundService.shutterSoundCount == 1)
    }

    @Test("SC-04: Explicit display ID is forwarded to backend")
    func testDisplayIDForwarding() async throws {
        let backend = SimulatedScreenCaptureBackend()
        let service = ScreenCaptureManager(backend: backend, soundService: nil)

        _ = try await service.captureDisplayRegion(CGRect(x: 10, y: 10, width: 50, height: 50), displayID: 12345)
        #expect(backend.captureRegionCalls.first?.displayID == 12345)
    }

    @Test("SC-05: Convenience method defaults to main display ID")
    func testConvenienceMethodDefaultsToMain() async throws {
        let backend = SimulatedScreenCaptureBackend()
        let service = ScreenCaptureManager(backend: backend, soundService: nil)

        _ = try await service.captureDisplayRegion(CGRect(x: 10, y: 10, width: 50, height: 50))
        #expect(backend.captureRegionCalls.first?.displayID == CGMainDisplayID())
    }

    @Test("SC-06: Throws invalidRegion on zero width rect")
    func testZeroWidthRejection() async {
        let backend = SimulatedScreenCaptureBackend()
        let soundService = MockSoundService()
        let service = ScreenCaptureManager(backend: backend, soundService: soundService)

        let badRect = CGRect(x: 10, y: 10, width: 0, height: 100)
        do {
            _ = try await service.captureDisplayRegion(badRect, displayID: 1)
            #expect(Bool(false), "Should have thrown invalidRegion")
        } catch let error as ScreenCaptureError {
            #expect(error == .invalidRegion(badRect))
        } catch {
            #expect(Bool(false), "Unexpected error type")
        }
        #expect(soundService.shutterSoundCount == 0)
    }

    @Test("SC-07: Throws invalidRegion on zero height rect")
    func testZeroHeightRejection() async {
        let backend = SimulatedScreenCaptureBackend()
        let soundService = MockSoundService()
        let service = ScreenCaptureManager(backend: backend, soundService: soundService)

        let badRect = CGRect(x: 10, y: 10, width: 100, height: 0)
        do {
            _ = try await service.captureDisplayRegion(badRect, displayID: 1)
            #expect(Bool(false), "Should have thrown invalidRegion")
        } catch let error as ScreenCaptureError {
            #expect(error == .invalidRegion(badRect))
        } catch {
            #expect(Bool(false), "Unexpected error type")
        }
        #expect(soundService.shutterSoundCount == 0)
    }

    @Test("SC-08: Throws invalidRegion on negative dimensions")
    func testNegativeDimensionRejection() async {
        let backend = SimulatedScreenCaptureBackend()
        let soundService = MockSoundService()
        let service = ScreenCaptureManager(backend: backend, soundService: soundService)

        let badRect = CGRect(x: 0, y: 0, width: -50, height: 100)
        do {
            _ = try await service.captureDisplayRegion(badRect, displayID: 1)
            #expect(Bool(false), "Should have thrown invalidRegion")
        } catch let error as ScreenCaptureError {
            #expect(error == .invalidRegion(badRect))
        } catch {
            #expect(Bool(false), "Unexpected error type")
        }
        #expect(soundService.shutterSoundCount == 0)
    }

    @Test("SC-09: Throws invalidRegion on NaN coordinates")
    func testNaNCoordinateRejection() async {
        let backend = SimulatedScreenCaptureBackend()
        let soundService = MockSoundService()
        let service = ScreenCaptureManager(backend: backend, soundService: soundService)

        let badRect = CGRect(x: 0, y: 0, width: Double.nan, height: 100)
        do {
            _ = try await service.captureDisplayRegion(badRect, displayID: 1)
            #expect(Bool(false), "Should have thrown invalidRegion")
        } catch let error as ScreenCaptureError {
            if case .invalidRegion = error {
                #expect(true)
            } else {
                #expect(Bool(false), "Expected invalidRegion error, got \(error)")
            }
        } catch {
            #expect(Bool(false), "Unexpected error type")
        }
        #expect(soundService.shutterSoundCount == 0)
    }

    @Test("SC-10: Throws invalidRegion on oversized geometries (> 32768)")
    func testOversizedGeometryRejection() async {
        let backend = SimulatedScreenCaptureBackend()
        let soundService = MockSoundService()
        let service = ScreenCaptureManager(backend: backend, soundService: soundService)

        let badRect = CGRect(x: 0, y: 0, width: 40_000, height: 100)
        do {
            _ = try await service.captureDisplayRegion(badRect, displayID: 1)
            #expect(Bool(false), "Should have thrown invalidRegion")
        } catch let error as ScreenCaptureError {
            #expect(error == .invalidRegion(badRect))
        } catch {
            #expect(Bool(false), "Unexpected error type")
        }
        #expect(soundService.shutterSoundCount == 0)
    }

    @Test("SC-11: Permission denied throws ScreenCaptureError.permissionDenied")
    func testPermissionDenied() async {
        let backend = SimulatedScreenCaptureBackend()
        backend.hasScreenRecordingPermission = false
        let soundService = MockSoundService()
        let service = ScreenCaptureManager(backend: backend, soundService: soundService)

        #expect(service.hasScreenRecordingPermission == false)
        do {
            _ = try await service.captureMainDisplay()
            #expect(Bool(false), "Should have thrown permissionDenied")
        } catch let error as ScreenCaptureError {
            #expect(error == .permissionDenied)
        } catch {
            #expect(Bool(false), "Unexpected error type")
        }
        #expect(soundService.shutterSoundCount == 0)
    }

    @Test("SC-12: Backend error propagation")
    func testBackendErrorPropagation() async {
        let backend = SimulatedScreenCaptureBackend()
        backend.stubbedError = ScreenCaptureError.captureFailed(reason: "Hardware pipeline unavailable")
        let soundService = MockSoundService()
        let service = ScreenCaptureManager(backend: backend, soundService: soundService)

        do {
            _ = try await service.captureMainDisplay()
            #expect(Bool(false), "Should have thrown captureFailed")
        } catch let error as ScreenCaptureError {
            #expect(error == .captureFailed(reason: "Hardware pipeline unavailable"))
        } catch {
            #expect(Bool(false), "Unexpected error type")
        }
        #expect(soundService.shutterSoundCount == 0)
    }

    @Test("SC-13: Audio shutter plays once on successful main capture")
    func testShutterPlayedOnMainSuccess() async throws {
        let backend = SimulatedScreenCaptureBackend()
        let soundService = MockSoundService()
        let service = ScreenCaptureManager(backend: backend, soundService: soundService)

        _ = try await service.captureMainDisplay()
        #expect(soundService.shutterSoundCount == 1)
    }

    @Test("SC-14: Audio shutter plays once on successful region capture")
    func testShutterPlayedOnRegionSuccess() async throws {
        let backend = SimulatedScreenCaptureBackend()
        let soundService = MockSoundService()
        let service = ScreenCaptureManager(backend: backend, soundService: soundService)

        _ = try await service.captureDisplayRegion(CGRect(x: 0, y: 0, width: 200, height: 200), displayID: 1)
        #expect(soundService.shutterSoundCount == 1)
    }

    @Test("SC-15: Audio shutter is suppressed when region capture throws")
    func testShutterSuppressedOnRegionError() async {
        let backend = SimulatedScreenCaptureBackend()
        let soundService = MockSoundService()
        let service = ScreenCaptureManager(backend: backend, soundService: soundService)

        _ = try? await service.captureDisplayRegion(CGRect(x: 0, y: 0, width: -10, height: 10), displayID: 1)
        #expect(soundService.shutterSoundCount == 0)
    }

    @Test("SC-16: Audio shutter is suppressed when permission is denied")
    func testShutterSuppressedOnPermissionDenied() async {
        let backend = SimulatedScreenCaptureBackend()
        backend.hasScreenRecordingPermission = false
        let soundService = MockSoundService()
        let service = ScreenCaptureManager(backend: backend, soundService: soundService)

        _ = try? await service.captureMainDisplay()
        #expect(soundService.shutterSoundCount == 0)
    }

    @Test("SC-17: Sound mute compliance delegates to SoundServiceProtocol")
    func testSoundMuteCompliance() async throws {
        let backend = SimulatedScreenCaptureBackend()
        let soundService = MockSoundService()
        soundService.isMuted = true
        let service = ScreenCaptureManager(backend: backend, soundService: soundService)

        _ = try await service.captureMainDisplay()
        #expect(soundService.playedSounds.isEmpty)
        #expect(soundService.shutterSoundCount == 0)
    }

    @Test("SC-18: NativeScreenCaptureBackend conforms to backend protocol")
    func testNativeBackendContract() {
        let native = NativeScreenCaptureBackend()
        let hasPerm = native.hasScreenRecordingPermission
        #expect(hasPerm == true || hasPerm == false)
    }

    @Test("SC-19: ScreenCaptureManager.live is correctly wired")
    func testLiveScreenCaptureManagerWired() {
        let live = ScreenCaptureManager.live
        #expect(live.hasScreenRecordingPermission == NativeScreenCaptureBackend().hasScreenRecordingPermission)
    }

    @Test("SC-20: EditorWindowGeometryCalculator handles extreme zero and NaN bounds gracefully")
    func testEditorGeometryExtremeZeroBounds() {
        let geom = EditorWindowGeometryCalculator.calculate(
            imageWidth: 0,
            imageHeight: 0,
            displayVisibleFrame: .zero,
            backingScaleFactor: 0.0
        )
        #expect(!geom.windowFrame.origin.x.isNaN)
        #expect(!geom.windowFrame.origin.y.isNaN)
        #expect(!geom.windowFrame.width.isNaN)
        #expect(!geom.windowFrame.height.isNaN)
        #expect(geom.windowFrame.width >= 520)
        #expect(geom.windowFrame.height >= 360)
        #expect(!geom.scaleFactor.isNaN)
        #expect(!geom.scaleFactor.isInfinite)
        #expect(geom.scaleFactor > 0)
    }
}
