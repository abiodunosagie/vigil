// Draws the Vigil app icon (a warm cup on a night tile: the Mac stays up while Claude works).
// Usage: swift make-icon.swift <output.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // Tile, inset like system icons.
    let tile = NSBezierPath(roundedRect: NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s),
                            xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [NSColor(red: 0.20, green: 0.16, blue: 0.30, alpha: 1),
                        NSColor(red: 0.06, green: 0.05, blue: 0.12, alpha: 1)])!.draw(in: tile, angle: -90)

    // The cup, drawn from the SF Symbol in warm orange.
    let config = NSImage.SymbolConfiguration(pointSize: 460 * s, weight: .semibold)
        .applying(.init(paletteColors: [NSColor(red: 1.0, green: 0.62, blue: 0.22, alpha: 1)]))
    if let cup = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let r = NSRect(x: (1024 * s - cup.size.width) / 2, y: (1024 * s - cup.size.height) / 2 - 20 * s,
                       width: cup.size.width, height: cup.size.height)
        cup.draw(in: r)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try draw(size: CGFloat(base * scale)).write(to: out.appendingPathComponent(name))
    }
}
