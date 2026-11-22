import SwiftUI
import CoreGraphics
import ZenithCore

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
                        draw(command, in: cgContext)
                    }

                    // Render live active drag preview command
                    if let activePreview = viewModel.activePreviewCommand {
                        draw(activePreview, in: cgContext)
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

    /// A blur shows the mosaic the exported image will have, taken from the capture (this canvas is drawn over the
    /// image and holds only the annotations, so the command alone could only paint a grey band, and the text stayed
    /// readable through it).
    private func draw(_ command: AnnotationCommand, in cgContext: CGContext) {
        guard let blur = command as? BlurAnnotationCommand else {
            command.apply(to: cgContext, scale: 1.0)
            return
        }
        let scale = viewModel.imageScaleFactor
        let base = viewModel.baseImage
        let rect = blur.rect.standardized
        let region = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
            .integral
            .intersection(CGRect(x: 0, y: 0, width: base.width, height: base.height))
        guard !region.isNull, region.width > 0, region.height > 0,
              let cells = PrivacyPixelation.averagedCells(of: base, region: region, cellSize: blur.pixelSize * scale) else {
            blur.apply(to: cgContext, scale: 1.0)
            return
        }
        let shown = CGRect(x: region.minX / scale, y: region.minY / scale, width: region.width / scale, height: region.height / scale)
        PrivacyPixelation.draw(cells, in: shown, on: cgContext)
    }
}
