import AppKit

// A legacy ICNS needs its own transparent margin and rounded tile. Drawing each
// representation from vectors keeps small Finder and Dock sizes antialiased.
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

for (name, pixels) in variants {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Cannot render icon") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    context.cgContext.setShouldAntialias(true)
    let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824),
                            xRadius: 184, yRadius: 184)
    NSGradient(starting: NSColor(calibratedWhite: 0.16, alpha: 1),
               ending: NSColor(calibratedWhite: 0.055, alpha: 1))!.draw(in: tile, angle: -90)
    NSColor(calibratedWhite: 0.3, alpha: 0.45).setStroke()
    tile.lineWidth = 2
    tile.stroke()
    let rings: [(CGFloat, NSColor)] = [
        (280, NSColor(srgbRed: 1, green: 77/255, blue: 0, alpha: 1)),
        (200, NSColor(srgbRed: 46/255, green: 229/255, blue: 118/255, alpha: 1)),
        (120, NSColor(srgbRed: 212/255, green: 1, blue: 0, alpha: 1))
    ]
    for (radius, color) in rings {
        color.setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: 512-radius, y: 512-radius,
                                              width: 2*radius, height: 2*radius))
        ring.lineWidth = 36
        ring.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode icon") }
    try png.write(to: output.appendingPathComponent(name + ".png"))
}
