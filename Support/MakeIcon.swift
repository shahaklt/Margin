// Renders the app icon: a squircle with a soft gradient and a voice waveform.
import AppKit

let out = CommandLine.arguments[1]
let sizes = [16, 32, 64, 128, 256, 512, 1024]
for px in sizes {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.098
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = s * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [NSColor(red: 0.33, green: 0.36, blue: 0.98, alpha: 1),
                        NSColor(red: 0.62, green: 0.38, blue: 0.96, alpha: 1)])!.draw(in: path, angle: -60)
    // Glass sheen
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.28), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    let heights: [CGFloat] = [0.18, 0.34, 0.56, 0.42, 0.72, 0.5, 0.3, 0.46, 0.22]
    let barW = rect.width * 0.058
    let gap = rect.width * 0.038
    let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
    var x = rect.midX - total / 2
    NSColor.white.setFill()
    for h in heights {
        let bh = rect.height * h * 0.78
        NSBezierPath(roundedRect: NSRect(x: x, y: rect.midY - bh / 2, width: barW, height: bh), xRadius: barW / 2, yRadius: barW / 2).fill()
        x += barW + gap
    }
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: "\(out)/\(px).png"))
}
