import AppKit
import SwiftUI
import CoreGraphics
import GoldenGateCore

/// Custom NSWindow for the annotation editor with key event dispatching.
public final class AnnotationWindow: NSWindow {
    public weak var eventDelegate: AnnotationWindowEventDelegate?

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { true }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let eventDelegate = eventDelegate, eventDelegate.handleKeyEquivalent(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    public override func keyDown(with event: NSEvent) {
        if let eventDelegate = eventDelegate, eventDelegate.handleKeyDown(event) {
            return
        }
        super.keyDown(with: event)
    }

    public override func cancelOperation(_ sender: Any?) {
        eventDelegate?.handleEscape()
    }
}

/// Delegate protocol handling in-editor keyboard shortcuts.
@MainActor
public protocol AnnotationWindowEventDelegate: AnyObject {
    func handleKeyEquivalent(_ event: NSEvent) -> Bool
    func handleKeyDown(_ event: NSEvent) -> Bool
    func handleEscape()
}

public extension AnnotationWindowEventDelegate {
    func handleKeyDown(_ event: NSEvent) -> Bool { false }
}

/// Controller managing the post-capture annotation editor window.
@MainActor
public final class AnnotationWindowController: NSObject, NSWindowDelegate, AnnotationWindowEventDelegate {
    public static let shared = AnnotationWindowController()

    private var window: AnnotationWindow?
    private var activeViewModel: AnnotationEditorViewModel?

    override public init() {
        super.init()
    }

    public var isVisible: Bool {
        window?.isVisible ?? false
    }

    /// Presents the annotation editor for the captured image.
    public func present(
        image: CGImage,
        screen: NSScreen? = nil,
        pasteboardService: PasteboardServiceProtocol = PasteboardMonitor.shared,
        soundService: SoundServiceProtocol? = AudioFeedbackManager.shared,
        exportService: ImageExportServiceProtocol = ImageExportService.shared
    ) {
        let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first
        let geometry = Self.calculateWindowGeometry(for: image, on: targetScreen)

        let viewModel = AnnotationEditorViewModel(
            baseImage: image,
            canvasSize: geometry.canvasSize,
            imageScaleFactor: geometry.scaleFactor,
            pasteboardService: pasteboardService,
            soundService: soundService,
            exportService: exportService
        )
        self.activeViewModel = viewModel

        viewModel.onDismissRequest = { [weak self] in
            self?.dismiss()
        }

        let editorView = AnnotationEditorView(viewModel: viewModel)
        let hostingView = NSHostingView(rootView: editorView)
        hostingView.autoresizingMask = [.width, .height]

        let editorWindow = AnnotationWindow(
            contentRect: geometry.windowFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        editorWindow.isReleasedWhenClosed = false
        editorWindow.titlebarAppearsTransparent = true
        editorWindow.titleVisibility = .hidden
        editorWindow.isMovableByWindowBackground = true
        editorWindow.isOpaque = false
        editorWindow.backgroundColor = .windowBackgroundColor
        editorWindow.hasShadow = true
        editorWindow.level = .floating
        editorWindow.collectionBehavior = [.fullScreenAuxiliary, .participatesInCycle]
        editorWindow.contentView = hostingView
        editorWindow.delegate = self
        editorWindow.eventDelegate = self

        self.window = editorWindow

        editorWindow.alphaValue = 0.0
        editorWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            editorWindow.animator().alphaValue = 1.0
        }
    }

    /// Fades out and dismisses the editor window.
    public func dismiss() {
        guard let currentWindow = window, currentWindow.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            currentWindow.animator().alphaValue = 0.0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                currentWindow.orderOut(nil)
                self?.window = nil
                self?.activeViewModel = nil
            }
        }
    }

    // MARK: - AnnotationWindowEventDelegate

    public func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard let vm = activeViewModel else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers ?? ""

        // Cmd+Q: Quit Application
        if flags == .command && chars.lowercased() == "q" {
            NSApp.terminate(nil)
            return true
        }

        // Cmd+W: Close Editor
        if flags == .command && chars.lowercased() == "w" {
            dismiss()
            return true
        }

        // Cmd+C: Copy & Dismiss
        if flags == .command && chars.lowercased() == "c" {
            vm.copyToClipboard()
            return true
        }

        // Cmd+S: Save & Dismiss
        if flags == .command && chars.lowercased() == "s" {
            vm.saveToDisk(parentWindow: self.window)
            return true
        }

        // Cmd+Z: Undo
        if flags == .command && chars.lowercased() == "z" {
            vm.undo()
            return true
        }

        // Shift+Cmd+Z: Redo
        if flags == [.command, .shift] && chars.lowercased() == "z" {
            vm.redo()
            return true
        }

        return false
    }

    public func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let vm = activeViewModel else { return false }
        // If inline text editing is active, pass all keystrokes to the text field
        if vm.textDraft != nil {
            return false
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // If Command, Control, or Option is pressed, let keyEquivalent / system menu handle it
        if !flags.isDisjoint(with: [.command, .control, .option]) {
            return false
        }
        guard let chars = event.charactersIgnoringModifiers?.lowercased(), !chars.isEmpty else {
            return false
        }

        switch chars {
        case "p":
            vm.selectedTool = .pen
            return true
        case "a":
            vm.selectedTool = .arrow
            return true
        case "r":
            vm.selectedTool = .rectangle
            return true
        case "t":
            vm.selectedTool = .text
            return true
        case "b":
            vm.selectedTool = .blur
            return true
        case "c":
            vm.selectedTool = .crop
            return true
        case "1"..."8":
            if let digit = Int(chars), digit >= 1, digit <= PresetColors.all.count {
                vm.selectedColor = PresetColors.all[digit - 1]
                return true
            }
        case "[":
            if vm.selectedStrokeWidth > 4.0 {
                vm.selectedStrokeWidth = 4.0
            } else {
                vm.selectedStrokeWidth = 2.0
            }
            return true
        case "]":
            if vm.selectedStrokeWidth < 4.0 {
                vm.selectedStrokeWidth = 4.0
            } else {
                vm.selectedStrokeWidth = 8.0
            }
            return true
        default:
            break
        }

        return false
    }

    public func handleEscape() {
        activeViewModel?.handleEscape()
    }

    // MARK: - Window Geometry Helper

    public struct WindowGeometry: Equatable, Sendable {
        public let windowFrame: NSRect
        public let canvasSize: CGSize
        public let scaleFactor: CGFloat

        public init(windowFrame: NSRect, canvasSize: CGSize, scaleFactor: CGFloat) {
            self.windowFrame = windowFrame
            self.canvasSize = canvasSize
            self.scaleFactor = scaleFactor
        }
    }

    public static func calculateWindowGeometry(for image: CGImage, on screen: NSScreen? = nil) -> WindowGeometry {
        let visibleFrame = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let scale = screen?.backingScaleFactor ?? 2.0
        let geom = EditorWindowGeometryCalculator.calculate(
            imageWidth: image.width,
            imageHeight: image.height,
            displayVisibleFrame: visibleFrame,
            backingScaleFactor: scale
        )
        return WindowGeometry(
            windowFrame: geom.windowFrame,
            canvasSize: geom.canvasSize,
            scaleFactor: geom.scaleFactor
        )
    }
}
