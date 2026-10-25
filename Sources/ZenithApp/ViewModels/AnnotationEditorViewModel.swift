import AppKit
import SwiftUI
import Combine
import CoreGraphics
import ZenithCore
import UniformTypeIdentifiers

/// Preset colors for the vector annotation palette.
public struct PresetColors {
    public static let red    = CGColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1.0)
    public static let orange = CGColor(srgbRed: 1.00, green: 0.58, blue: 0.00, alpha: 1.0)
    public static let yellow = CGColor(srgbRed: 1.00, green: 0.80, blue: 0.00, alpha: 1.0)
    public static let green  = CGColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1.0)
    public static let blue   = CGColor(srgbRed: 0.00, green: 0.48, blue: 1.00, alpha: 1.0)
    public static let purple = CGColor(srgbRed: 0.69, green: 0.32, blue: 0.87, alpha: 1.0)
    public static let white  = CGColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1.0)
    public static let black  = CGColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1.0)

    public static let all: [CGColor] = [red, orange, yellow, green, blue, purple, white, black]
}

/// State for an inline text box being drafted.
public struct TextDraftState: Identifiable, Sendable {
    public let id: UUID
    public var origin: CGPoint
    public var text: String
    public var fontSize: CGFloat
    public var color: CGColor

    public init(id: UUID = UUID(), origin: CGPoint, text: String, fontSize: CGFloat = 16.0, color: CGColor) {
        self.id = id
        self.origin = origin
        self.text = text
        self.fontSize = fontSize
        self.color = color
    }
}

/// ViewModel coordinating annotation tools, user gestures, command stack, and image export.
@MainActor
public final class AnnotationEditorViewModel: ObservableObject {
    // Core Data
    public let baseImage: CGImage
    public let canvasSize: CGSize
    public let imageScaleFactor: CGFloat

    // Injected Dependencies
    public let pasteboardService: PasteboardServiceProtocol
    public let soundService: SoundServiceProtocol?
    public let exportService: ImageExportServiceProtocol

    // Annotation Command History
    @Published public var commandStack = AnnotationCommandStack()

    // Active Tool & Styling
    @Published public var selectedTool: AnnotationTool = .pen
    @Published public var selectedColor: CGColor = PresetColors.red
    @Published public var selectedStrokeWidth: CGFloat = 4.0

    // Live Drag Previews
    @Published public var activePreviewCommand: (any AnnotationCommand)?
    @Published public var activeDragPoints: [CGPoint] = []

    // Inline Text Drafting
    @Published public var textDraft: TextDraftState?

    // Interactive Crop State
    @Published public var committedCropRect: CGRect?
    @Published public var activeCropRect: CGRect?

    // Toast & Dismissal Handlers
    public var onDismissRequest: (() -> Void)?

    private var cancellables = Set<AnyCancellable>()

    public init(
        baseImage: CGImage,
        canvasSize: CGSize,
        imageScaleFactor: CGFloat,
        pasteboardService: PasteboardServiceProtocol = PasteboardMonitor.shared,
        soundService: SoundServiceProtocol? = AudioFeedbackManager.shared,
        exportService: ImageExportServiceProtocol = ImageExportService.shared
    ) {
        self.baseImage = baseImage
        self.canvasSize = canvasSize
        self.imageScaleFactor = imageScaleFactor
        self.pasteboardService = pasteboardService
        self.soundService = soundService
        self.exportService = exportService

        commandStack.objectWillChange
            .sink { [weak self] _ in
                if Thread.isMainThread {
                    self?.objectWillChange.send()
                } else {
                    DispatchQueue.main.async {
                        self?.objectWillChange.send()
                    }
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Gesture Dispatchers

    public func handleDragChanged(at point: CGPoint, start: CGPoint) {
        switch selectedTool {
        case .pen:
            if activeDragPoints.isEmpty {
                activeDragPoints.append(start)
            }
            activeDragPoints.append(point)
            if activeDragPoints.count > 1 {
                activePreviewCommand = PenAnnotationCommand(
                    points: activeDragPoints,
                    color: selectedColor,
                    strokeWidth: selectedStrokeWidth
                )
            }

        case .arrow:
            activePreviewCommand = ArrowAnnotationCommand(
                start: start,
                end: point,
                color: selectedColor,
                strokeWidth: selectedStrokeWidth
            )

        case .rectangle:
            let rect = makeNormalizedRect(start: start, end: point)
            activePreviewCommand = RectangleAnnotationCommand(
                rect: rect,
                color: selectedColor,
                strokeWidth: selectedStrokeWidth
            )

        case .blur:
            let rect = makeNormalizedRect(start: start, end: point)
            activePreviewCommand = BlurAnnotationCommand(
                rect: rect,
                pixelSize: 16.0
            )

        case .crop:
            activeCropRect = makeNormalizedRect(start: start, end: point)

        case .text:
            break
        }
    }

    public func handleDragEnded(at point: CGPoint, start: CGPoint) {
        switch selectedTool {
        case .pen:
            if activeDragPoints.count > 1 {
                let command = PenAnnotationCommand(
                    points: activeDragPoints,
                    color: selectedColor,
                    strokeWidth: selectedStrokeWidth
                )
                commandStack.push(command)
            }
            activeDragPoints.removeAll()
            activePreviewCommand = nil

        case .arrow:
            let dist = hypot(point.x - start.x, point.y - start.y)
            if dist >= 4.0 {
                let command = ArrowAnnotationCommand(
                    start: start,
                    end: point,
                    color: selectedColor,
                    strokeWidth: selectedStrokeWidth
                )
                commandStack.push(command)
            }
            activePreviewCommand = nil

        case .rectangle:
            let rect = makeNormalizedRect(start: start, end: point)
            if rect.width >= 3.0 && rect.height >= 3.0 {
                let command = RectangleAnnotationCommand(
                    rect: rect,
                    color: selectedColor,
                    strokeWidth: selectedStrokeWidth
                )
                commandStack.push(command)
            }
            activePreviewCommand = nil

        case .blur:
            let rect = makeNormalizedRect(start: start, end: point)
            if rect.width >= 4.0 && rect.height >= 4.0 {
                let command = BlurAnnotationCommand(
                    rect: rect,
                    pixelSize: 16.0
                )
                commandStack.push(command)
            }
            activePreviewCommand = nil

        case .crop:
            if let crop = activeCropRect, crop.width >= 20.0 && crop.height >= 20.0 {
                committedCropRect = crop
            }
            activeCropRect = nil

        case .text:
            break
        }
    }

    public func handleTap(at point: CGPoint) {
        if selectedTool == .text {
            if let existing = textDraft, !existing.text.trimmingCharacters(in: .whitespaces).isEmpty {
                commitTextDraft()
            }
            textDraft = TextDraftState(
                origin: point,
                text: "",
                fontSize: 16.0,
                color: selectedColor
            )
        }
    }

    public func commitTextDraft() {
        guard let draft = textDraft, !draft.text.trimmingCharacters(in: .whitespaces).isEmpty else {
            textDraft = nil
            return
        }
        let command = TextAnnotationCommand(
            origin: draft.origin,
            text: draft.text,
            fontSize: draft.fontSize,
            color: draft.color
        )
        commandStack.push(command)
        textDraft = nil
    }

    public func cancelTextDraft() {
        textDraft = nil
    }

    // MARK: - Undo / Redo

    public func undo() {
        commandStack.undo()
    }

    public func redo() {
        commandStack.redo()
    }

    // MARK: - In-Editor Actions

    public func copyToClipboard() {
        commitTextDraft()
        let flattened = exportService.renderAnnotatedImage(
            baseImage: baseImage,
            commands: commandStack.commands,
            cropRect: committedCropRect,
            scale: imageScaleFactor
        )
        pasteboardService.writeImageToPasteboard(flattened)
        soundService?.playNewCopySound()
        ToastHUDController.shared.show(message: "Copied to Clipboard!", icon: "checkmark.circle.fill")
        onDismissRequest?()
    }

    public func saveToDisk(parentWindow: NSWindow?) {
        commitTextDraft()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultExportFilename()

        let response: NSApplication.ModalResponse
        if let window = parentWindow {
            response = panel.runModal()
            _ = window // avoid unused warning
        } else {
            response = panel.runModal()
        }

        guard response == .OK, let url = panel.url else { return }

        let flattened = exportService.renderAnnotatedImage(
            baseImage: baseImage,
            commands: commandStack.commands,
            cropRect: committedCropRect,
            scale: imageScaleFactor
        )

        let isJPEG = url.pathExtension.lowercased() == "jpg" || url.pathExtension.lowercased() == "jpeg"
        let data: Data? = isJPEG ? exportService.exportToJPEG(image: flattened, quality: 0.95) : exportService.exportToPNG(image: flattened)

        guard let fileData = data else {
            NSLog("[AnnotationEditorViewModel] Failed to encode image data for %@", url.path)
            ToastHUDController.shared.show(
                message: "Save Failed: Image encoding failed",
                icon: "exclamationmark.triangle.fill"
            )
            return
        }

        do {
            try fileData.write(to: url, options: .atomic)
            soundService?.playShutterSound()
            ToastHUDController.shared.show(message: "Saved to Disk!", icon: "arrow.down.doc.fill")
            onDismissRequest?()
        } catch {
            NSLog("[AnnotationEditorViewModel] Failed to save image to %@: %@", url.path, error.localizedDescription)
            ToastHUDController.shared.show(
                message: "Save Failed: \(error.localizedDescription)",
                icon: "exclamationmark.triangle.fill"
            )
        }
    }

    public func handleEscape() {
        if textDraft != nil {
            cancelTextDraft()
            return
        }
        if committedCropRect != nil {
            committedCropRect = nil
            return
        }
        onDismissRequest?()
    }

    // MARK: - Helpers

    private func makeNormalizedRect(start: CGPoint, end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    private func defaultExportFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Screenshot \(formatter.string(from: Date())).png"
    }
}
