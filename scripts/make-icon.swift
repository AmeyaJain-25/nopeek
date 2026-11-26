// Renders the NoPeek app icon (gradient squircle + 🙈) into an .iconset.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/AppIcon.iconset")
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s), flipped: false) { rect in
        let inset = s * 0.1
        let body = rect.insetBy(dx: inset, dy: inset)
        let path = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
        NSGradient(colors: [
            NSColor(calibratedRed: 0.42, green: 0.22, blue: 0.95, alpha: 1),
            NSColor(calibratedRed: 0.95, green: 0.27, blue: 0.55, alpha: 1),
        ])!.draw(in: path, angle: -60)

        let emoji = "🙈" as NSString
        let font = NSFont.systemFont(ofSize: body.width * 0.62)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let textSize = emoji.size(withAttributes: attrs)
        emoji.draw(at: NSPoint(x: body.midX - textSize.width / 2, y: body.midY - textSize.height / 2 - body.height * 0.02),
                   withAttributes: attrs)
        return true
    }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: s, height: s)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: s, height: s))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(size: base).write(to: output.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(size: base * 2).write(to: output.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print("Wrote \(output.path)")
