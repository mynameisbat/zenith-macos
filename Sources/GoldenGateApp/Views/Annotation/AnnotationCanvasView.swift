import SwiftUI
import CoreGraphics
import GoldenGateCore

/// Hardware-accelerated canvas view rendering the captured bitmap and vector annotations via SwiftUI Canvas.
public struct AnnotationCanvasView: View {
    @ObservedObject public var viewModel: AnnotationEditorViewModel

    public init(viewModel: AnnotationEditorViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack {
            // Base screenshot image
            Image(decorative: viewModel.baseImage, scale: 1.0, orientation: .up)
                .resizable()
                .aspectRatio(contentMode: .fit)

            // Vector Annotations Canvas
            Canvas { context, _ in
                context.withCGContext { cgContext in
                    // Render all committed commands from the stack
                    for command in viewModel.commandStack.commands {
                        command.apply(to: cgContext, scale: 1.0)
                    }

                    // Render live active drag preview command
                    if let activePreview = viewModel.activePreviewCommand {
                        activePreview.apply(to: cgContext, scale: 1.0)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .local)
                .onChanged { value in
                    viewModel.handleDragChanged(at: value.location, start: value.startLocation)
                }
                .onEnded { value in
                    viewModel.handleDragEnded(at: value.location, start: value.startLocation)
                }
        )
        .simultaneousGesture(
            SpatialTapGesture(coordinateSpace: .local)
                .onEnded { value in
                    viewModel.handleTap(at: value.location)
                }
        )
    }
}
