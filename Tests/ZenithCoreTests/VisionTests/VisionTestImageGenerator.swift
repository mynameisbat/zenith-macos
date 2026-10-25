import Foundation
import CoreGraphics
import CoreText
import CoreImage

/// Headless in-memory test image generator for OCR and Barcode recognition suites.
///
/// Produces synthetic, zero-dependency `CGImage` buffers directly in memory using
/// CoreGraphics, CoreText, and CoreImage without reading from disk or bundle assets.
public enum VisionTestImageGenerator {

    /// Renders a single line of high-contrast text into a `CGImage` using CoreText.
    ///
    /// - Parameters:
    ///   - text: The string to draw (defaults to "ZENITH OCR TEST").
    ///   - fontSize: Font point size (defaults to 36pt).
    ///   - size: Dimensions of the resulting image buffer (defaults to 600x200).
    ///   - textColor: Foreground color for glyphs (defaults to opaque black).
    ///   - backgroundColor: Canvas background fill color (defaults to opaque white).
    /// - Returns: A non-nil `CGImage` containing the rendered text.
    public static func createTextImage(
        text: String = "ZENITH OCR TEST",
        fontSize: CGFloat = 36,
        size: CGSize = CGSize(width: 600, height: 200),
        textColor: CGColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        backgroundColor: CGColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    ) -> CGImage {
        let width = max(1, Int(size.width))
        let height = max(1, Int(size.height))
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            fatalError("Failed to allocate CGContext for createTextImage")
        }

        context.setFillColor(backgroundColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.textMatrix = .identity

        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): textColor
        ]
        let attrString = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attrString as CFAttributedString)
        let lineBounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)

        let x = max(30.0, (CGFloat(width) - lineBounds.width) / 2.0)
        let y = (CGFloat(height) - lineBounds.height) / 2.0

        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, context)

        guard let image = context.makeImage() else {
            fatalError("Failed to create CGImage from context")
        }
        return image
    }

    /// Renders multiple lines of text with structured vertical line spacing.
    ///
    /// - Parameters:
    ///   - lines: Array of strings representing sequential text lines.
    ///   - fontSize: Font point size for each line.
    ///   - size: Dimensions of the resulting image buffer.
    ///   - textColor: Foreground color for glyphs.
    ///   - backgroundColor: Canvas background fill color.
    /// - Returns: A non-nil `CGImage` containing all rendered lines in vertical order.
    public static func createMultiLineTextImage(
        lines: [String],
        fontSize: CGFloat = 28,
        size: CGSize = CGSize(width: 800, height: 400),
        textColor: CGColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        backgroundColor: CGColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    ) -> CGImage {
        let width = max(1, Int(size.width))
        let height = max(1, Int(size.height))
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            fatalError("Failed to allocate CGContext for createMultiLineTextImage")
        }

        context.setFillColor(backgroundColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.textMatrix = .identity

        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): textColor
        ]

        let lineHeight = fontSize * 1.8
        let totalHeight = CGFloat(lines.count) * lineHeight
        let startY = (CGFloat(height) + totalHeight) / 2.0 - lineHeight

        for (index, lineText) in lines.enumerated() {
            let attrString = NSAttributedString(string: lineText, attributes: attributes)
            let ctLine = CTLineCreateWithAttributedString(attrString as CFAttributedString)
            let y = startY - CGFloat(index) * lineHeight
            context.textPosition = CGPoint(x: 40, y: y)
            CTLineDraw(ctLine, context)
        }

        guard let image = context.makeImage() else {
            fatalError("Failed to create CGImage for createMultiLineTextImage")
        }
        return image
    }

    /// Generates a standard QR Code `CGImage` from a string payload using CoreImage.
    ///
    /// - Parameters:
    ///   - payload: String value to encode into the QR code.
    ///   - scale: Display scale factor to enlarge the generated QR matrix.
    /// - Returns: A non-nil `CGImage` of the rendered QR code.
    public static func createQRCodeImage(
        payload: String,
        scale: CGFloat = 10.0
    ) -> CGImage {
        guard let data = payload.data(using: .utf8) else {
            fatalError("Invalid string payload for QR Code")
        }
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
            fatalError("CIQRCodeGenerator unavailable")
        }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let outputCI = filter.outputImage else {
            fatalError("Failed to get outputImage from CIQRCodeGenerator")
        }

        let scaledCI = outputCI.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let ciContext = CIContext(options: [CIContextOption.useSoftwareRenderer: false])
        guard let cgImage = ciContext.createCGImage(scaledCI, from: scaledCI.extent) else {
            fatalError("Failed to create CGImage from CIImage")
        }
        return cgImage
    }

    /// Synthesizes a composite canvas containing both high-contrast text and a QR code side-by-side.
    ///
    /// Used for single-pass joint text recognition and barcode detection verification.
    /// - Parameters:
    ///   - text: The text string to render on the left portion.
    ///   - qrPayload: The barcode payload string to encode on the right portion.
    ///   - size: Total dimensions of the composite canvas.
    /// - Returns: A non-nil `CGImage` containing both text and QR code.
    public static func createCompositeTextAndQRImage(
        text: String = "ZENITH COMPOSITE OCR",
        qrPayload: String = "https://zenith.app/verify",
        size: CGSize = CGSize(width: 900, height: 400)
    ) -> CGImage {
        let width = max(1, Int(size.width))
        let height = max(1, Int(size.height))
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            fatalError("Failed to allocate CGContext for createCompositeTextAndQRImage")
        }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.textMatrix = .identity

        // Draw Text on left side
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 32, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        ]
        let attrString = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attrString as CFAttributedString)
        context.textPosition = CGPoint(x: 40, y: CGFloat(height) / 2.0)
        CTLineDraw(line, context)

        // Draw QR code on right side
        let qrImage = createQRCodeImage(payload: qrPayload, scale: 6.0)
        let qrWidth = CGFloat(qrImage.width)
        let qrHeight = CGFloat(qrImage.height)
        let qrRect = CGRect(
            x: CGFloat(width) - qrWidth - 40,
            y: (CGFloat(height) - qrHeight) / 2.0,
            width: qrWidth,
            height: qrHeight
        )
        context.draw(qrImage, in: qrRect)

        guard let compositeImage = context.makeImage() else {
            fatalError("Failed to make composite CGImage")
        }
        return compositeImage
    }

    /// Creates a 1x1 solid-color degenerate pixel image.
    ///
    /// Used for validating engine resilience against minimal degenerate images.
    public static func createDegenerate1x1Image(
        color: CGColor = CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1.0)
    ) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            fatalError("Failed to allocate 1x1 CGContext")
        }
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let image = context.makeImage() else {
            fatalError("Failed to make 1x1 CGImage")
        }
        return image
    }

    /// Creates a blank image of specified dimensions with uniform fill color.
    public static func createBlankImage(
        width: Int = 400,
        height: Int = 300,
        color: CGColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    ) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            fatalError("Failed to allocate blank CGContext")
        }
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            fatalError("Failed to make blank CGImage")
        }
        return image
    }

    /// Creates an oversized valid `CGImage` exceeding the 32768 pixel boundary constraint.
    ///
    /// Used for validating bounds defense against texture allocation failure and overflow.
    public static func createOversizedImage(
        width: Int = 33000,
        height: Int = 2
    ) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = width * 4
        let data = Data(count: bytesPerRow * height)
        guard let provider = CGDataProvider(data: data as CFData) else {
            fatalError("Failed to create CGDataProvider for oversized image")
        }
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            fatalError("Failed to create oversized CGImage")
        }
        return image
    }

    /// Synthesizes an 8K Retina screen buffer (7680 x 4320 pixels, ~133 MB raw pixel buffer).
    ///
    /// Used for verifying memory bounds, autoreleasepool reclamation, and high-load stress testing.
    public static func create8KRetinaBufferImage(
        withText text: String? = nil
    ) -> CGImage {
        let width = 7680
        let height = 4320
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            fatalError("Failed to allocate 8K CGContext")
        }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        if let text = text {
            context.textMatrix = .identity
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 120, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1)
            ]
            let attrString = NSAttributedString(string: text, attributes: attributes)
            let line = CTLineCreateWithAttributedString(attrString as CFAttributedString)
            context.textPosition = CGPoint(x: 500, y: 2000)
            CTLineDraw(line, context)
        }

        guard let image = context.makeImage() else {
            fatalError("Failed to make 8K CGImage")
        }
        return image
    }

    /// Creates a multilingual test image with multi-script Unicode lines (Latin, Japanese, Chinese, Cyrillic).
    public static func createMultilingualTextImage(
        lines: [(text: String, fontName: String)] = [
            ("ZENITH SYSTEM WORKSTATION", "Helvetica-Bold"),
            ("こんにちは世界", "HiraginoSans-W6"),
            ("你好世界 快速识别", "PingFangSC-Semibold"),
            ("Привет Zenith", "Helvetica-Bold")
        ],
        size: CGSize = CGSize(width: 1000, height: 500)
    ) -> CGImage {
        let width = max(1, Int(size.width))
        let height = max(1, Int(size.height))
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            fatalError("Failed to allocate CGContext for createMultilingualTextImage")
        }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.textMatrix = .identity

        let lineHeight: CGFloat = 60
        let totalHeight = CGFloat(lines.count) * lineHeight
        let startY = (CGFloat(height) + totalHeight) / 2.0 - lineHeight

        for (index, item) in lines.enumerated() {
            let font = CTFontCreateWithName(item.fontName as CFString, 36, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1)
            ]
            let attrString = NSAttributedString(string: item.text, attributes: attributes)
            let line = CTLineCreateWithAttributedString(attrString as CFAttributedString)
            let y = startY - CGFloat(index) * lineHeight
            context.textPosition = CGPoint(x: 50, y: y)
            CTLineDraw(line, context)
        }

        guard let image = context.makeImage() else {
            fatalError("Failed to make multilingual CGImage")
        }
        return image
    }
}
