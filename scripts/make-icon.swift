import AppKit
// The mark: a chat bubble on a warm tile with a glowing ember inside — an assistant you talk to,
// running warm on your own Mac. The same bubble and ember appear in the app as `EmberGlyph`.
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for file in try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil) where file.lastPathComponent.hasPrefix("icon_") && file.pathExtension == "png" {
    try FileManager.default.removeItem(at: file)
}
func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

/// One continuous outline: a rounded body with a tail at the lower left (y grows upward here).
func bubble(body: NSRect, tail: CGFloat) -> NSBezierPath {
    let w = body.width, radius = body.height * 0.4, small = w * 0.045
    let points: [(NSPoint, CGFloat)] = [
        (NSPoint(x: body.maxX, y: body.maxY), radius),
        (NSPoint(x: body.maxX, y: body.minY), radius),
        (NSPoint(x: body.minX + w * 0.58, y: body.minY), small),
        (NSPoint(x: body.minX + w * 0.2, y: body.minY - tail), small * 0.7),
        (NSPoint(x: body.minX + w * 0.36, y: body.minY), small),
        (NSPoint(x: body.minX, y: body.minY), radius),
        (NSPoint(x: body.minX, y: body.maxY), radius),
    ]
    let path = NSBezierPath()
    path.move(to: NSPoint(x: body.midX, y: body.maxY))
    for (index, (corner, r)) in points.enumerated() {
        let next = index + 1 < points.count ? points[index + 1].0 : NSPoint(x: body.midX, y: body.maxY)
        path.appendArc(from: corner, to: next, radius: r)
    }
    path.close()
    return path
}

for size in [16, 32, 64, 128, 256, 512, 1024] {
    let s = CGFloat(size), detailed = size >= 64
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    // macOS icon grid: an 824/1024 rounded square, with the system's soft shadow below it.
    let margin = s * 100 / 1024
    let tile = NSRect(x: margin, y: margin, width: s - margin * 2, height: s - margin * 2)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    if detailed {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = color(0x000000, 0.28); shadow.shadowBlurRadius = s * 0.02; shadow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
        shadow.set(); color(0xE4541C).setFill(); tilePath.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
    NSGradient(starting: color(0xFF8A4C), ending: color(0xC9440F))!.draw(in: tilePath, angle: -60)
    if detailed {
        // A gentle sheen across the top keeps the tile from reading as flat orange.
        NSGraphicsContext.saveGraphicsState(); tilePath.addClip()
        NSGradient(starting: color(0xFFFFFF, 0.16), ending: color(0xFFFFFF, 0))!.draw(in: NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)
        NSGraphicsContext.restoreGraphicsState()
    }
    // The bubble: larger at small sizes, where detail turns to mush.
    let bodyWidth = tile.width * (detailed ? 0.6 : 0.68)
    let bodyHeight = bodyWidth * 0.78, tail = bodyWidth * 0.2
    let body = NSRect(x: s / 2 - bodyWidth / 2, y: s / 2 - (bodyHeight - tail) / 2, width: bodyWidth, height: bodyHeight)
    let shape = bubble(body: body, tail: tail)
    NSGraphicsContext.saveGraphicsState()
    if detailed {
        let shadow = NSShadow(); shadow.shadowColor = color(0x6B2306, 0.35); shadow.shadowBlurRadius = s * 0.035; shadow.shadowOffset = NSSize(width: 0, height: -s * 0.014)
        shadow.set()
    }
    color(0xFCF8F2).setFill(); shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    if detailed { NSGradient(starting: color(0xFFFFFF, 0), ending: color(0xEFE6D8, 0.7))!.draw(in: shape, angle: -90) }
    // The ember.
    let center = NSPoint(x: body.midX, y: body.midY)
    if detailed {
        NSGradient(colors: [color(0xFF6B2C, 0.3), color(0xFF6B2C, 0)])!
            .draw(fromCenter: center, radius: 0, toCenter: center, radius: bodyHeight * 0.34, options: [])
    }
    let core = bodyHeight * (detailed ? 0.28 : 0.36)
    let ember = NSBezierPath(ovalIn: NSRect(x: center.x - core / 2, y: center.y - core / 2, width: core, height: core))
    NSGradient(starting: color(0xFF8A4C), ending: color(0xE0541A))!.draw(in: ember, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    let data = bitmap.representation(using: .png, properties: [:])!
    if [16, 32, 128, 256, 512].contains(size) { try data.write(to: destination.appendingPathComponent("icon_\(size)x\(size).png")) }
    if [32, 64, 256, 512, 1024].contains(size) { try data.write(to: destination.appendingPathComponent("icon_\(size/2)x\(size/2)@2x.png")) }
}
