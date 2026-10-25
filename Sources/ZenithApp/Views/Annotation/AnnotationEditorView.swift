import AppKit
import SwiftUI
import CoreGraphics
import ZenithCore

/// Root SwiftUI view for the annotation editor workspace.
public struct AnnotationEditorView: View {
    @ObservedObject public var viewModel: AnnotationEditorViewModel

    public init(viewModel: AnnotationEditorViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack {
            // Dark neutral backdrop for letterboxing and contrast
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            // 1. Drawing Canvas Area
            AnnotationCanvasView(viewModel: viewModel)
                .frame(width: viewModel.canvasSize.width, height: viewModel.canvasSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: Color.black.opacity(0.18), radius: 10, x: 0, y: 4)

            // 2. Interactive Crop Overlay
            if viewModel.selectedTool == .crop || viewModel.committedCropRect != nil {
                CropOverlayView(viewModel: viewModel)
                    .frame(width: viewModel.canvasSize.width, height: viewModel.canvasSize.height)
            }

            // 3. Inline Text Input Overlay
            if let draft = viewModel.textDraft {
                InlineTextEditorView(viewModel: viewModel, draft: draft)
                    .frame(width: viewModel.canvasSize.width, height: viewModel.canvasSize.height)
            }

            // 4. Floating Styling Toolbar
            VStack {
                Spacer()
                StylingToolbarView(viewModel: viewModel)
                    .padding(.bottom, 20)
            }
        }
    }
}

// MARK: - Crop Overlay View

public struct CropOverlayView: View {
    @ObservedObject public var viewModel: AnnotationEditorViewModel

    public init(viewModel: AnnotationEditorViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        GeometryReader { geometry in
            let crop = viewModel.activeCropRect ?? viewModel.committedCropRect ?? CGRect(origin: .zero, size: geometry.size)

            ZStack {
                // Dimmed surround
                CropDimmedMask(cropRect: crop, fullSize: geometry.size)
                    .fill(Color.black.opacity(0.4), style: FillStyle(eoFill: true))

                // Bounding Border
                Rectangle()
                    .stroke(Color.white, lineWidth: 1.5)
                    .frame(width: crop.width, height: crop.height)
                    .position(x: crop.midX, y: crop.midY)

                // 8 Corner & Midpoint Handles
                CropHandlesView(cropRect: crop)
            }
        }
    }
}

public struct CropDimmedMask: Shape {
    public var cropRect: CGRect
    public var fullSize: CGSize

    public init(cropRect: CGRect, fullSize: CGSize) {
        self.cropRect = cropRect
        self.fullSize = fullSize
    }

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(CGRect(origin: .zero, size: fullSize))
        path.addRect(cropRect)
        return path
    }
}

public struct CropHandlesView: View {
    public var cropRect: CGRect

    public init(cropRect: CGRect) {
        self.cropRect = cropRect
    }

    public var body: some View {
        let handleSize: CGFloat = 8.0
        ZStack {
            handle(at: CGPoint(x: cropRect.minX, y: cropRect.minY), size: handleSize)
            handle(at: CGPoint(x: cropRect.midX, y: cropRect.minY), size: handleSize)
            handle(at: CGPoint(x: cropRect.maxX, y: cropRect.minY), size: handleSize)
            handle(at: CGPoint(x: cropRect.minX, y: cropRect.midY), size: handleSize)
            handle(at: CGPoint(x: cropRect.maxX, y: cropRect.midY), size: handleSize)
            handle(at: CGPoint(x: cropRect.minX, y: cropRect.maxY), size: handleSize)
            handle(at: CGPoint(x: cropRect.midX, y: cropRect.maxY), size: handleSize)
            handle(at: CGPoint(x: cropRect.maxX, y: cropRect.maxY), size: handleSize)
        }
    }

    private func handle(at point: CGPoint, size: CGFloat) -> some View {
        Rectangle()
            .fill(Color.white)
            .border(Color.black.opacity(0.5), width: 1)
            .frame(width: size, height: size)
            .position(point)
    }
}

// MARK: - Inline Text Editor View

public struct InlineTextEditorView: View {
    @ObservedObject public var viewModel: AnnotationEditorViewModel
    public var draft: TextDraftState
    @FocusState private var isFocused: Bool

    public init(viewModel: AnnotationEditorViewModel, draft: TextDraftState) {
        self.viewModel = viewModel
        self.draft = draft
    }

    public var body: some View {
        TextField("", text: Binding(
            get: { viewModel.textDraft?.text ?? "" },
            set: { viewModel.textDraft?.text = $0 }
        ))
        .font(.system(size: draft.fontSize, weight: .medium))
        .foregroundColor(Color(cgColor: draft.color))
        .textFieldStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.85))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(Color.accentColor, lineWidth: 1.5)
        )
        .focused($isFocused)
        .position(x: draft.origin.x + 80, y: draft.origin.y + 12)
        .frame(width: 220)
        .onSubmit {
            viewModel.commitTextDraft()
        }
        .onAppear {
            isFocused = true
        }
    }
}
