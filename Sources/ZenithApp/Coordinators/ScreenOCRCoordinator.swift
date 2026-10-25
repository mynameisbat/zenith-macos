import AppKit
import Foundation
import Combine
import CoreGraphics
import ZenithCore

/// Coordinates optical character recognition (OCR) and barcode/QR code detection from screen surfaces.
///
/// Connects screen capture overlays (`CaptureOverlayController`) with the Apple Vision framework engine
/// (`VisionEngineService`), copies results to the system clipboard (`NSPasteboard`), and notifies the user
/// via ephemeral HUD notifications (`ToastHUDController`).
@MainActor
public final class ScreenOCRCoordinator: ObservableObject {
    /// Shared singleton instance.
    public static let shared = ScreenOCRCoordinator()

    // MARK: - Injected Dependencies

    public let visionEngine: VisionEngineProtocol
    public let captureController: CaptureOverlayController
    public let pasteboard: NSPasteboard
    public let toastController: ToastHUDController

    // MARK: - State

    @Published public private(set) var isProcessing: Bool = false
    @Published public private(set) var lastResult: VisionAnalysisResult?

    // MARK: - Initialization

    public init(
        visionEngine: VisionEngineProtocol = VisionEngineService.shared,
        captureController: CaptureOverlayController = .shared,
        pasteboard: NSPasteboard = .general,
        toastController: ToastHUDController = .shared
    ) {
        self.visionEngine = visionEngine
        self.captureController = captureController
        self.pasteboard = pasteboard
        self.toastController = toastController
    }

    // MARK: - Public Entry Points

    /// Starts interactive area capture overlay, performs OCR and barcode detection on the selected region,
    /// copies the recognized text/payload to the clipboard, and displays a toast notification.
    public func startAreaOCR(completion: (@MainActor @Sendable (VisionAnalysisResult?) -> Void)? = nil) {
        guard !captureController.isOverlayActive else {
            completion?(nil)
            return
        }

        captureController.startAreaCapture { [weak self] capturedImage in
            guard let self = self else {
                completion?(nil)
                return
            }
            guard let image = capturedImage else {
                // User cancelled or screen recording permission denied
                completion?(nil)
                return
            }

            Task { @MainActor in
                let result = await self.process(image: image)
                completion?(result)
            }
        }
    }

    /// Captures the full main display immediately, performs OCR and barcode detection,
    /// copies the recognized text/payload to the clipboard, and displays a toast notification.
    public func startFullscreenOCR(completion: (@MainActor @Sendable (VisionAnalysisResult?) -> Void)? = nil) {
        captureController.captureFullscreen { [weak self] capturedImage in
            guard let self = self else {
                completion?(nil)
                return
            }
            guard let image = capturedImage else {
                // Screen recording permission denied or capture failed
                completion?(nil)
                return
            }

            Task { @MainActor in
                let result = await self.process(image: image)
                completion?(result)
            }
        }
    }

    /// Cancels any active capture overlay.
    public func cancelOCR() {
        captureController.cancelCapture()
    }

    // MARK: - Processing Engine

    /// Analyzes a given CGImage for text and barcodes, copies results to pasteboard, and triggers HUD feedback.
    @discardableResult
    public func process(image: CGImage) async -> VisionAnalysisResult? {
        isProcessing = true
        defer { isProcessing = false }

        do {
            let options = VisionAnalysisOptions(
                recognizeText: true,
                detectBarcodes: true,
                textConfig: .default,
                barcodeTypes: VisionBarcodeType.allCases
            )

            let result = try await visionEngine.analyze(image: image, options: options)
            self.lastResult = result

            let text = result.textResult.fullText.trimmingCharacters(in: .whitespacesAndNewlines)
            let barcodePayloads = result.barcodes
                .map { $0.payload.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            let combinedString: String
            if !text.isEmpty && !barcodePayloads.isEmpty {
                combinedString = text + "\n" + barcodePayloads.joined(separator: "\n")
            } else if !text.isEmpty {
                combinedString = text
            } else if !barcodePayloads.isEmpty {
                combinedString = barcodePayloads.joined(separator: "\n")
            } else {
                // No text or barcodes found in image
                toastController.show(
                    message: "No Text or QR Code Detected",
                    icon: "exclamationmark.magnifyingglass"
                )
                return result
            }

            // Copy extracted string to pasteboard
            pasteboard.clearContents()
            pasteboard.setString(combinedString, forType: .string)

            // Trigger HUD toast confirmation
            toastController.show(
                message: "Text Copied to Clipboard",
                icon: "doc.text.viewfinder"
            )
            return result
        } catch is CancellationError {
            // Task was cancelled; return cleanly without fatal errors
            return nil
        } catch let error as VisionEngineError {
            switch error {
            case .cancelled:
                // Cancelled cleanly without fatal errors
                return nil
            default:
                NSLog("[Zenith] ScreenOCRCoordinator recognition error: \(error)")
                toastController.show(
                    message: "No Text or QR Code Detected",
                    icon: "exclamationmark.magnifyingglass"
                )
                return nil
            }
        } catch {
            NSLog("[Zenith] ScreenOCRCoordinator unexpected error: \(error)")
            toastController.show(
                message: "No Text or QR Code Detected",
                icon: "exclamationmark.magnifyingglass"
            )
            return nil
        }
    }
}
