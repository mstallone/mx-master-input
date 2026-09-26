// Renders the app icon into an .iconset directory, in the same visual language as Runway and RetinaShot:
// a warm cream plate, a near-black glyph, and one terracotta accent.
// Usage: make-icon <output.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let cream = NSColor(srgbRed: 0xF3 / 255, green: 0xED / 255, blue: 0xE0 / 255, alpha: 1)
let ink = NSColor(srgbRed: 0x24 / 255, green: 0x22 / 255, blue: 0x1F / 255, alpha: 1)
let terracotta = NSColor(srgbRed: 0xD0 / 255, green: 0x76 / 255, blue: 0x39 / 255, alpha: 1)

func render(_ px: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: px, height: px))
    image.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high

    // Plate on Apple's icon grid (artwork fills ~80% of the canvas), with a soft drop shadow.
    let inset = px * 0.10
    let square = NSRect(x: inset, y: inset, width: px - 2 * inset, height: px - 2 * inset)
    let radius = square.width * 0.225
    let plate = NSBezierPath(roundedRect: square, xRadius: radius, yRadius: radius)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowOffset = NSSize(width: 0, height: -px * 0.012)
    shadow.shadowBlurRadius = px * 0.025
    shadow.set()
    cream.setFill()
    plate.fill()
    NSGraphicsContext.restoreGraphicsState()
    // Hairline highlight just inside the edge, like the Runway plate.
    let rim = NSBezierPath(roundedRect: square.insetBy(dx: px * 0.012, dy: px * 0.012), xRadius: radius - px * 0.012, yRadius: radius - px * 0.012)
    rim.lineWidth = px * 0.006
    NSColor.white.withAlphaComponent(0.7).setStroke()
    rim.stroke()

    // A mouse, in the stroke weight of RetinaShot's brackets.
    let s = square.width
    let line = s * 0.062
    let body = NSRect(x: square.midX - s * 0.17, y: square.midY - s * 0.27, width: s * 0.34, height: s * 0.54)
    let outline = NSBezierPath(roundedRect: body, xRadius: body.width / 2, yRadius: body.width / 2)
    outline.lineWidth = line
    ink.setStroke()
    outline.stroke()
    let split = NSBezierPath()
    split.lineWidth = line
    split.lineCapStyle = .round
    split.move(to: NSPoint(x: body.midX, y: body.maxY))
    split.line(to: NSPoint(x: body.midX, y: body.maxY - body.height * 0.3))
    split.stroke()
    // The swipe, in the family's accent color.
    let chevrons = NSBezierPath()
    chevrons.lineWidth = line
    chevrons.lineCapStyle = .round
    chevrons.lineJoinStyle = .round
    let reach = s * 0.085, depth = s * 0.06, gap = s * 0.09
    for (x, direction) in [(body.minX - gap, -1.0), (body.maxX + gap, 1.0)] {
        chevrons.move(to: NSPoint(x: x, y: square.midY + reach))
        chevrons.line(to: NSPoint(x: x + direction * depth, y: square.midY))
        chevrons.line(to: NSPoint(x: x, y: square.midY - reach))
    }
    terracotta.setStroke()
    chevrons.stroke()

    image.unlockFocus()
    return image
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(size * scale)
        let image = render(px)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
        try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
    }
}
