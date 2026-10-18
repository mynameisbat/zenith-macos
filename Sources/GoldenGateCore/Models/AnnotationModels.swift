import Foundation
import CoreGraphics
import CoreText

// MARK: - Tool Enum

/// Supported annotation vector tools.
public enum AnnotationTool: String, CaseIterable, Identifiable, Sendable {
    case pen
    case arrow
    case rectangle
    case text
    case blur
    case crop

    public var id: String { rawValue }
}

// MARK: - Type Aliases for Backward Compatibility & Ergonomic Naming

public typealias PenAnnotation = PenAnnotationCommand
public typealias ArrowAnnotation = ArrowAnnotationCommand
public typealias RectangleAnnotation = RectangleAnnotationCommand
public typealias TextAnnotation = TextAnnotationCommand
public typealias BlurAnnotation = BlurAnnotationCommand
public typealias PixelateAnnotation = BlurAnnotationCommand
public typealias CropAnnotation = CropAnnotationCommand

// MARK: - Freehand Pen Annotation (F22)

/// Smoothing algorithm used for pen/brush strokes.
public enum SmoothingAlgorithm: String, Sendable, CaseIterable, Equatable, Hashable {
    case quadraticBezier
    case catmullRom
}

/// Freehand smoothed brush stroke.
public struct PenAnnotationCommand: AnnotationCommand, Sendable, Identifiable {
    public let id: UUID
    public let points: [CGPoint]
    public let color: CGColor
    public let strokeWidth: CGFloat
    public let smoothing: SmoothingAlgorithm
    public let lineCap: CGLineCap
    public let lineJoin: CGLineJoin

    public init(
        id: UUID = UUID(),
        points: [CGPoint],
        color: CGColor,
        strokeWidth: CGFloat = 3.0,
        smoothing: SmoothingAlgorithm = .quadraticBezier,
        lineCap: CGLineCap = .round,
        lineJoin: CGLineJoin = .round
    ) {
        self.id = id
        self.points = points
        self.color = color
        self.strokeWidth = strokeWidth
        self.smoothing = smoothing
        self.lineCap = lineCap
        self.lineJoin = lineJoin
    }

    public func apply(to context: CGContext, scale: CGFloat) {
        guard points.count > 1 else { return }

        context.saveGState()
        context.setStrokeColor(color)
        context.setLineWidth(strokeWidth * scale)
        context.setLineCap(lineCap)
        context.setLineJoin(lineJoin)

        let path = CGMutablePath()
        let scaledPoints = points.map { CGPoint(x: $0.x * scale, y: $0.y * scale) }

        switch smoothing {
        case .quadraticBezier:
            path.move(to: scaledPoints[0])
            for i in 1..<scaledPoints.count {
                let prev = scaledPoints[i - 1]
                let curr = scaledPoints[i]
                let mid = CGPoint(x: (prev.x + curr.x) / 2.0, y: (prev.y + curr.y) / 2.0)
                path.addQuadCurve(to: mid, control: prev)
            }
            if let last = scaledPoints.last {
                path.addLine(to: last)
            }

        case .catmullRom:
            path.move(to: scaledPoints[0])
            if scaledPoints.count == 2 {
                path.addLine(to: scaledPoints[1])
            } else {
                for i in 0..<(scaledPoints.count - 1) {
                    let p0 = i > 0 ? scaledPoints[i - 1] : scaledPoints[i]
                    let p1 = scaledPoints[i]
                    let p2 = scaledPoints[i + 1]
                    let p3 = (i + 2 < scaledPoints.count) ? scaledPoints[i + 2] : p2

                    let c1 = CGPoint(
                        x: p1.x + (p2.x - p0.x) / 6.0,
                        y: p1.y + (p2.y - p0.y) / 6.0
                    )
                    let c2 = CGPoint(
                        x: p2.x - (p3.x - p1.x) / 6.0,
                        y: p2.y - (p3.y - p1.y) / 6.0
                    )
                    path.addCurve(to: p2, control1: c1, control2: c2)
                }
            }
        }

        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }
}

// MARK: - Arrow Annotation (F23)

/// Directional vector arrow with proportional arrowheads.
public struct ArrowAnnotationCommand: AnnotationCommand, Sendable, Identifiable {
    public let id: UUID
    public let start: CGPoint
    public let end: CGPoint
    public let color: CGColor
    public let strokeWidth: CGFloat
    public let arrowHeadLength: CGFloat
    public let arrowHeadAngle: CGFloat
    public let isHeadFilled: Bool

    public init(
        id: UUID = UUID(),
        start: CGPoint,
        end: CGPoint,
        color: CGColor,
        strokeWidth: CGFloat = 3.0,
        arrowHeadLength: CGFloat = 20.0,
        arrowHeadAngle: CGFloat = .pi / 6.0,
        isHeadFilled: Bool = false
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.color = color
        self.strokeWidth = strokeWidth
        self.arrowHeadLength = arrowHeadLength
        self.arrowHeadAngle = arrowHeadAngle
        self.isHeadFilled = isHeadFilled
    }

    public func apply(to context: CGContext, scale: CGFloat) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let distance = hypot(dx, dy)
        guard distance > 0.001 else { return }

        context.saveGState()
        context.setStrokeColor(color)
        context.setFillColor(color)
        context.setLineWidth(strokeWidth * scale)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        let s = CGPoint(x: start.x * scale, y: start.y * scale)
        let e = CGPoint(x: end.x * scale, y: end.y * scale)

        // Draw main stem
        context.beginPath()
        context.move(to: s)
        context.addLine(to: e)
        context.strokePath()

        // Calculate arrowhead wings
        let maxHeadLength = distance * scale * 0.45
        let length = min(arrowHeadLength * scale, maxHeadLength)
        let lineAngle = atan2(e.y - s.y, e.x - s.x)
        let leftAngle = lineAngle + .pi - arrowHeadAngle
        let rightAngle = lineAngle + .pi + arrowHeadAngle

        let leftPoint = CGPoint(x: e.x + length * cos(leftAngle), y: e.y + length * sin(leftAngle))
        let rightPoint = CGPoint(x: e.x + length * cos(rightAngle), y: e.y + length * sin(rightAngle))

        if isHeadFilled {
            context.beginPath()
            context.move(to: e)
            context.addLine(to: leftPoint)
            context.addLine(to: rightPoint)
            context.closePath()
            context.fillPath()
        } else {
            context.beginPath()
            context.move(to: leftPoint)
            context.addLine(to: e)
            context.addLine(to: rightPoint)
            context.strokePath()
        }

        context.restoreGState()
    }
}

// MARK: - Rectangle Annotation (F24)

/// Bounded rectangle annotation (stroked or filled) with optional rounded corners.
public struct RectangleAnnotationCommand: AnnotationCommand, Sendable, Identifiable {
    public let id: UUID
    public let rect: CGRect
    public let color: CGColor
    public let strokeWidth: CGFloat
    public let isFilled: Bool
    public let cornerRadius: CGFloat

    public init(
        id: UUID = UUID(),
        rect: CGRect,
        color: CGColor,
        strokeWidth: CGFloat = 3.0,
        isFilled: Bool = false,
        cornerRadius: CGFloat = 0.0
    ) {
        self.id = id
        self.rect = rect
        self.color = color
        self.strokeWidth = strokeWidth
        self.isFilled = isFilled
        self.cornerRadius = cornerRadius
    }

    public func apply(to context: CGContext, scale: CGFloat) {
        let stdRect = rect.standardized
        guard stdRect.width > 0, stdRect.height > 0 else { return }

        context.saveGState()
        let scaledRect = CGRect(
            x: stdRect.origin.x * scale,
            y: stdRect.origin.y * scale,
            width: stdRect.width * scale,
            height: stdRect.height * scale
        )

        let maxRadius = min(scaledRect.width, scaledRect.height) / 2.0
        let effectiveRadius = max(0, min(cornerRadius * scale, maxRadius))

        let path = CGMutablePath()
        if effectiveRadius > 0 {
            path.addRoundedRect(in: scaledRect, cornerWidth: effectiveRadius, cornerHeight: effectiveRadius)
        } else {
            path.addRect(scaledRect)
        }

        if isFilled {
            context.setFillColor(color)
            context.addPath(path)
            context.fillPath()
        } else {
            context.setStrokeColor(color)
            context.setLineWidth(strokeWidth * scale)
            context.addPath(path)
            context.strokePath()
        }

        context.restoreGState()
    }
}

// MARK: - Text Annotation (F25)

/// Text label with typographic bounds and optional background contrast pill.
public struct TextAnnotationCommand: AnnotationCommand, Sendable, Identifiable {
    public let id: UUID
    public let origin: CGPoint
    public let text: String
    public let fontSize: CGFloat
    public let color: CGColor
    public let backgroundColor: CGColor?
    public let fontName: String

    public init(
        id: UUID = UUID(),
        origin: CGPoint,
        text: String,
        fontSize: CGFloat = 16.0,
        color: CGColor,
        backgroundColor: CGColor? = nil,
        fontName: String = "HelveticaNeue-Medium"
    ) {
        self.id = id
        self.origin = origin
        self.text = text
        self.fontSize = fontSize
        self.color = color
        self.backgroundColor = backgroundColor
        self.fontName = fontName
    }

    public func apply(to context: CGContext, scale: CGFloat) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        context.saveGState()
        let ctFont = CTFontCreateWithName(fontName as CFString, fontSize * scale, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: ctFont,
            kCTForegroundColorAttributeName: color
        ]

        guard let attrString = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary) else {
            context.restoreGState()
            return
        }

        let line = CTLineCreateWithAttributedString(attrString)
        let isFlipped = context.ctm.d < 0
        let scaledOrigin = CGPoint(x: origin.x * scale, y: origin.y * scale)

        // Draw background contrast pill if requested
        if let bgColor = backgroundColor {
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            let textHeight = ascent + descent

            let padX = 8.0 * scale
            let padY = 4.0 * scale
            let pillY = isFlipped ? (scaledOrigin.y - ascent - padY) : (scaledOrigin.y - descent - padY)
            let pillRect = CGRect(
                x: scaledOrigin.x - padX,
                y: pillY,
                width: textWidth + 2 * padX,
                height: textHeight + 2 * padY
            )

            let pillRadius = 4.0 * scale
            let pillPath = CGPath(roundedRect: pillRect, cornerWidth: pillRadius, cornerHeight: pillRadius, transform: nil)
            context.setFillColor(bgColor)
            context.addPath(pillPath)
            context.fillPath()
        }

        if isFlipped {
            context.textMatrix = CGAffineTransform(scaleX: 1.0, y: -1.0)
        } else {
            context.textMatrix = .identity
        }
        context.textPosition = scaledOrigin
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

// MARK: - Blur / Pixelate Annotation (F26)

/// Region blur command applying privacy mosaic pixelation.
public struct BlurAnnotationCommand: AnnotationCommand, Sendable, Identifiable {
    public let id: UUID
    public let rect: CGRect
    public let pixelSize: CGFloat

    public init(id: UUID = UUID(), rect: CGRect, pixelSize: CGFloat = 16.0) {
        self.id = id
        self.rect = rect
        self.pixelSize = pixelSize
    }

    public func apply(to context: CGContext, scale: CGFloat) {
        let stdRect = rect.standardized
        guard stdRect.width > 0, stdRect.height > 0 else { return }

        context.saveGState()
        let scaledRect = CGRect(
            x: stdRect.origin.x * scale,
            y: stdRect.origin.y * scale,
            width: stdRect.width * scale,
            height: stdRect.height * scale
        )

        // Native CoreGraphics Nearest-Neighbor Pixelation if bitmap is readable
        let blockSize = max(2.0, pixelSize * scale)

        if let fullImage = context.makeImage() {
            let fullRect = CGRect(x: 0, y: 0, width: fullImage.width, height: fullImage.height)
            let clampedRect = scaledRect.intersection(fullRect)
            let sW = max(1, Int((clampedRect.width > 0 ? clampedRect.width : scaledRect.width) / blockSize))
            let sH = max(1, Int((clampedRect.height > 0 ? clampedRect.height : scaledRect.height) / blockSize))

            if !clampedRect.isNull, clampedRect.width > 0, clampedRect.height > 0,
               let surfaceImage = fullImage.cropping(to: clampedRect),
               let miniContext = CGContext(
                   data: nil,
                   width: sW,
                   height: sH,
                   bitsPerComponent: 8,
                   bytesPerRow: sW * 4,
                   space: CGColorSpaceCreateDeviceRGB(),
                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
               ) {
                miniContext.interpolationQuality = .none
                miniContext.draw(surfaceImage, in: CGRect(x: 0, y: 0, width: sW, height: sH))

                if let pixellatedTile = miniContext.makeImage() {
                    context.interpolationQuality = .none
                    if context.ctm.d < 0 {
                        context.saveGState()
                        context.translateBy(x: clampedRect.origin.x, y: clampedRect.origin.y + clampedRect.height)
                        context.scaleBy(x: 1.0, y: -1.0)
                        context.draw(pixellatedTile, in: CGRect(x: 0, y: 0, width: clampedRect.width, height: clampedRect.height))
                        context.restoreGState()
                    } else {
                        context.draw(pixellatedTile, in: clampedRect)
                    }
                    context.restoreGState()
                    return
                }
            }
        }

        // Fallback tint mask (safe for non-bitmap contexts or initial rendering)
        context.setFillColor(CGColor(gray: 0.2, alpha: 0.85))
        context.fill(scaledRect)
        context.restoreGState()
    }
}

// MARK: - Interactive Crop Annotation (F27)

/// Interactive crop command defining boundary adjustment post-capture.
public struct CropAnnotationCommand: AnnotationCommand, Sendable, Identifiable {
    public let id: UUID
    public let cropRect: CGRect
    public let originalSize: CGSize

    public var normalizedRect: CGRect {
        guard originalSize.width > 0, originalSize.height > 0 else { return .zero }
        return CGRect(
            x: cropRect.origin.x / originalSize.width,
            y: cropRect.origin.y / originalSize.height,
            width: cropRect.width / originalSize.width,
            height: cropRect.height / originalSize.height
        )
    }

    public init(id: UUID = UUID(), cropRect: CGRect, originalSize: CGSize) {
        self.id = id
        self.cropRect = cropRect.standardized
        self.originalSize = originalSize
    }

    public func apply(to context: CGContext, scale: CGFloat) {
        let scaledCrop = CGRect(
            x: cropRect.origin.x * scale,
            y: cropRect.origin.y * scale,
            width: cropRect.width * scale,
            height: cropRect.height * scale
        )
        context.clip(to: scaledCrop)
    }
}
