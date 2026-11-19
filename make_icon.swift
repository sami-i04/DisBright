import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let size: CGFloat = 1024

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
let gradient = NSGradient(colors: [
    NSColor(srgbRed: 0.10, green: 0.10, blue: 0.16, alpha: 1),
    NSColor(srgbRed: 0.22, green: 0.16, blue: 0.30, alpha: 1),
])!
gradient.draw(in: path, angle: 90)

if let sym = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(.init(pointSize: 480, weight: .semibold)) {
    let tinted = NSImage(size: sym.size, flipped: false) { r in
        sym.draw(in: r)
        NSColor(srgbRed: 1.0, green: 0.62, blue: 0.15, alpha: 1).set()
        r.fill(using: .sourceAtop)
        return true
    }
    let s = tinted.size
    let scale = min(560 / s.width, 560 / s.height)
    let w = s.width * scale, h = s.height * scale
    tinted.draw(in: NSRect(x: (size - w) / 2, y: (size - h) / 2, width: w, height: h))
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
