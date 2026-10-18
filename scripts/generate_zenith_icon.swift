import Cocoa
import CoreGraphics

func createZenithIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    ctx.saveGState()

    // 1. Apple macOS Squircle Dimensions (approx 82.4% of total canvas)
    let margin = size * 0.088
    let iconRect = CGRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
    let cornerRadius = iconRect.width * 0.224 // Apple standard squircle corner ratio

    // 2. Drop Shadow behind squircle
    ctx.setShadow(
        offset: CGSize(width: 0, height: -size * 0.03),
        blur: size * 0.06,
        color: NSColor.black.withAlphaComponent(0.35).cgColor
    )

    let squirclePath = CGPath(
        roundedRect: iconRect,
        cornerWidth: cornerRadius,
        cornerHeight: cornerRadius,
        transform: nil
    )

    ctx.addPath(squirclePath)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()

    ctx.restoreGState() // Clear shadow for inner content
    ctx.saveGState()

    // Clip to squircle
    ctx.addPath(squirclePath)
    ctx.clip()

    // 3. Deep Royal Indigo to Twilight Purple Background Gradient
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bgColors = [
        NSColor(red: 0.36, green: 0.42, blue: 0.98, alpha: 1.0).cgColor,
        NSColor(red: 0.26, green: 0.28, blue: 0.85, alpha: 1.0).cgColor,
        NSColor(red: 0.14, green: 0.12, blue: 0.45, alpha: 1.0).cgColor
    ] as CFArray
    let bgLocations: [CGFloat] = [0.0, 0.6, 1.0]

    if let gradient = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: bgLocations) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: iconRect.midX, y: iconRect.maxY),
            end: CGPoint(x: iconRect.midX, y: iconRect.minY),
            options: []
        )
    }

    // 4. Subtle Radial Ambient Glow near the top
    let glowColors = [
        NSColor(red: 0.65, green: 0.70, blue: 1.0, alpha: 0.40).cgColor,
        NSColor(red: 0.45, green: 0.50, blue: 1.0, alpha: 0.0).cgColor
    ] as CFArray
    if let glowGradient = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 1.0]) {
        ctx.drawRadialGradient(
            glowGradient,
            startCenter: CGPoint(x: iconRect.midX, y: iconRect.maxY * 0.85),
            startRadius: 0,
            endCenter: CGPoint(x: iconRect.midX, y: iconRect.maxY * 0.85),
            endRadius: iconRect.width * 0.6,
            options: []
        )
    }

    // 5. Hero Emblem: The Zenith Apex Crest
    let centerX = iconRect.midX
    let centerY = iconRect.midY

    // Stacked Glass Layers (representing Precision Clipboard & Workspace)
    let layerW = iconRect.width * 0.42
    let layerH = iconRect.height * 0.28

    for (index, offset) in [(-layerH * 0.35), 0.0, (layerH * 0.35)].enumerated() {
        let cardRect = CGRect(
            x: centerX - layerW / 2,
            y: centerY - layerH / 2 + offset,
            width: layerW,
            height: layerH
        )
        let cardPath = CGPath(roundedRect: cardRect, cornerWidth: layerH * 0.2, cornerHeight: layerH * 0.2, transform: nil)

        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -4),
            blur: 8,
            color: NSColor.black.withAlphaComponent(0.25).cgColor
        )
        ctx.addPath(cardPath)
        let alpha = 0.15 + CGFloat(index) * 0.10
        ctx.setFillColor(NSColor.white.withAlphaComponent(alpha).cgColor)
        ctx.fillPath()

        // Card border
        ctx.addPath(cardPath)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
        ctx.setLineWidth(size * 0.003)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // Glowing Central Apex Star / Diamond Prism (representing Screen Capture & Accuracy)
    ctx.saveGState()
    ctx.setShadow(
        offset: .zero,
        blur: size * 0.04,
        color: NSColor(red: 0.6, green: 0.85, blue: 1.0, alpha: 0.9).cgColor
    )

    let starSize = iconRect.width * 0.32
    let starPath = CGMutablePath()
    let starCenter = CGPoint(x: centerX, y: centerY)

    // Draw an elegant 8-pointed star / aperture diamond
    let numPoints = 8
    for i in 0..<(numPoints * 2) {
        let angle = CGFloat(i) * CGFloat.pi / CGFloat(numPoints) - CGFloat.pi / 2
        let radius = (i % 2 == 0) ? (starSize / 2) : (starSize * 0.22)
        let point = CGPoint(
            x: starCenter.x + radius * cos(angle),
            y: starCenter.y + radius * sin(angle)
        )
        if i == 0 {
            starPath.move(to: point)
        } else {
            starPath.addLine(to: point)
        }
    }
    starPath.closeSubpath()

    // Fill star with brilliant white-to-cyan gradient
    let starColors = [
        NSColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0).cgColor,
        NSColor(red: 0.75, green: 0.88, blue: 1.0, alpha: 0.95).cgColor
    ] as CFArray
    if let starGradient = CGGradient(colorsSpace: colorSpace, colors: starColors, locations: [0.0, 1.0]) {
        ctx.addPath(starPath)
        ctx.clip()
        ctx.drawLinearGradient(
            starGradient,
            start: CGPoint(x: centerX, y: centerY + starSize / 2),
            end: CGPoint(x: centerX, y: centerY - starSize / 2),
            options: []
        )
    }
    ctx.restoreGState()

    // 6. Top Rim Light Highlight (Apple Glass Polish)
    let rimPath = CGPath(
        roundedRect: iconRect.insetBy(dx: 1, dy: 1),
        cornerWidth: cornerRadius,
        cornerHeight: cornerRadius,
        transform: nil
    )
    ctx.addPath(rimPath)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.3).cgColor)
    ctx.setLineWidth(size * 0.0025)
    ctx.strokePath()

    ctx.restoreGState()
    image.unlockFocus()
    return image
}

let size: CGFloat = 1024
let iconImage = createZenithIcon(size: size)

if let tiffData = iconImage.tiffRepresentation,
   let bitmap = NSBitmapImageRep(data: tiffData),
   let pngData = bitmap.representation(using: .png, properties: [:]) {
    let outUrl = URL(fileURLWithPath: "AppIcon_1024.png")
    try? pngData.write(to: outUrl)
    print("Exported 1024x1024 icon to \(outUrl.path)")
}
