import SwiftUI
import ZenithCore

/// High-precision pixel magnifier loupe view displaying magnified pixel grid, crosshair, and live hex color.
public struct LoupeMagnifierView: View {
    public let grid: [[PixelColor]]
    public let centerColor: PixelColor
    public let zoomFactor: LoupeZoomFactor

    public init(
        grid: [[PixelColor]],
        centerColor: PixelColor,
        zoomFactor: LoupeZoomFactor = .zoom4x
    ) {
        self.grid = grid
        self.centerColor = centerColor
        self.zoomFactor = zoomFactor
    }

    private var dimension: Int {
        zoomFactor.sourceGridDimension
    }

    public var body: some View {
        VStack(spacing: 6) {
            // Magnified Pixel Grid
            ZStack {
                let cellCount = dimension
                let cellSize: CGFloat = cellCount == 15 ? 7.0 : 5.0

                // Render pixel matrix
                Canvas { context, size in
                    let half = cellCount / 2
                    for r in 0..<min(grid.count, cellCount) {
                        let row = grid[r]
                        for c in 0..<min(row.count, cellCount) {
                            let pColor = row[c]
                            let rect = CGRect(
                                x: CGFloat(c) * cellSize,
                                y: CGFloat(r) * cellSize,
                                width: cellSize,
                                height: cellSize
                            )

                            let fill = Color(
                                red: Double(pColor.red) / 255.0,
                                green: Double(pColor.green) / 255.0,
                                blue: Double(pColor.blue) / 255.0,
                                opacity: Double(pColor.alpha) / 255.0
                            )
                            context.fill(Path(rect), with: .color(fill))

                            // Grid lines
                            let gridBorder = Path(rect)
                            context.stroke(gridBorder, with: .color(Color.white.opacity(0.12)), lineWidth: 0.5)
                        }
                    }

                    // Highlight Center Pixel Box
                    let centerRect = CGRect(
                        x: CGFloat(half) * cellSize,
                        y: CGFloat(half) * cellSize,
                        width: cellSize,
                        height: cellSize
                    )
                    context.stroke(Path(centerRect), with: .color(.white), lineWidth: 1.5)
                    context.stroke(Path(centerRect), with: .color(.black.opacity(0.8)), lineWidth: 0.5)

                    // Crosshair guides
                    let midX = centerRect.midX
                    let midY = centerRect.midY
                    var crosshair = Path()
                    // Top line
                    crosshair.move(to: CGPoint(x: midX, y: 0))
                    crosshair.addLine(to: CGPoint(x: midX, y: centerRect.minY))
                    // Bottom line
                    crosshair.move(to: CGPoint(x: midX, y: centerRect.maxY))
                    crosshair.addLine(to: CGPoint(x: midX, y: size.height))
                    // Left line
                    crosshair.move(to: CGPoint(x: 0, y: midY))
                    crosshair.addLine(to: CGPoint(x: centerRect.minX, y: midY))
                    // Right line
                    crosshair.move(to: CGPoint(x: centerRect.maxX, y: midY))
                    crosshair.addLine(to: CGPoint(x: size.width, y: midY))
                    context.stroke(crosshair, with: .color(Color.white.opacity(0.4)), lineWidth: 0.75)
                }
                .frame(width: cellSize * CGFloat(cellCount), height: cellSize * CGFloat(cellCount))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.35), lineWidth: 1.0)
                )
            }

            // Hex Readout and Swatch Pill
            HStack(spacing: 6) {
                // Live Swatch
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color(
                        red: Double(centerColor.red) / 255.0,
                        green: Double(centerColor.green) / 255.0,
                        blue: Double(centerColor.blue) / 255.0
                    ))
                    .frame(width: 12, height: 12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .stroke(Color.white.opacity(0.4), lineWidth: 0.5)
                    )

                Text(centerColor.hexString)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Color(white: 0.08, opacity: 0.9))
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                    )
            )
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(white: 0.12, opacity: 0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.25), lineWidth: 1.0)
                )
        )
        .shadow(color: Color.black.opacity(0.45), radius: 6, x: 0, y: 3)
    }
}
