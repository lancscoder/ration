// Generates the AppIcon iconset: a warm squircle with a usage gauge and bolt.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let s = CGFloat(px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon grid: 824/1024 body with a soft shadow.
    let inset = s * 100 / 1024
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = body.width * 0.225
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    let path = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
    NSColor(red: 0.80, green: 0.42, blue: 0.29, alpha: 1).setFill()
    path.fill()
    ctx.restoreGState()
    NSGradient(colors: [NSColor(red: 0.93, green: 0.55, blue: 0.38, alpha: 1), NSColor(red: 0.72, green: 0.33, blue: 0.22, alpha: 1)])!
        .draw(in: path, angle: -90)

    // Gauge track and fill.
    let center = NSPoint(x: s / 2, y: s * 0.44)
    let r = body.width * 0.33
    let lw = body.width * 0.075
    func arc(from: CGFloat, to: CGFloat, color: NSColor) {
        let p = NSBezierPath()
        p.appendArc(withCenter: center, radius: r, startAngle: from, endAngle: to, clockwise: true)
        p.lineWidth = lw
        p.lineCapStyle = .round
        color.setStroke()
        p.stroke()
    }
    arc(from: 200, to: -20, color: NSColor.white.withAlphaComponent(0.28))
    arc(from: 200, to: 60, color: .white)

    // Bolt.
    if let symbol = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: body.width * 0.30, weight: .bold).applying(.init(paletteColors: [.white]))) {
        let sz = symbol.size
        symbol.draw(in: NSRect(x: center.x - sz.width / 2, y: center.y - sz.height / 2 - body.width * 0.01, width: sz.width, height: sz.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px: px).write(to: out.appendingPathComponent("icon_\(name).png"))
}
print("wrote \(out.path)")
