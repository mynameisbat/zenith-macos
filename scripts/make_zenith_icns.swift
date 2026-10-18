import Cocoa

let inputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon_1024.png"
guard let inputImage = NSImage(contentsOfFile: inputPath) else {
    fatalError("Cannot load input image at \(inputPath)")
}

let canvasSize: CGFloat = 1024
let iconSize: CGFloat = 824
let margin: CGFloat = 100
let cornerRadius: CGFloat = 185

let outputImage = NSImage(size: NSSize(width: canvasSize, height: canvasSize))
outputImage.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("No CGContext") }

let rect = CGRect(x: margin, y: margin, width: iconSize, height: iconSize)

// 1. Draw subtle drop shadow behind squircle
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 24, color: NSColor.black.withAlphaComponent(0.32).cgColor)
let squirclePath = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
ctx.addPath(squirclePath)
ctx.setFillColor(NSColor.black.cgColor)
ctx.fillPath()
ctx.restoreGState()

// 2. Clip to squircle and draw image
ctx.saveGState()
ctx.addPath(squirclePath)
ctx.clip()

// Crop the exact squircle from input: (180, 180, 660, 660)
if let cgInput = inputImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
   let cropped = cgInput.cropping(to: CGRect(x: 180, y: 180, width: 660, height: 660)) {
    ctx.draw(cropped, in: rect)
}

ctx.restoreGState()

// 3. Crisp subtle hairline rim light around the squircle
ctx.saveGState()
ctx.addPath(squirclePath)
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.25).cgColor)
ctx.setLineWidth(1.5)
ctx.strokePath()
ctx.restoreGState()

outputImage.unlockFocus()

guard let tiff = outputImage.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("Failed to convert to PNG")
}

let outURL = URL(fileURLWithPath: "ZenithAppIcon_1024.png")
try png.write(to: outURL)
print("Saved 1024x1024 transparent Zenith icon to \(outURL.path)")
