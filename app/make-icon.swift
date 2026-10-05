// Tekent het app-icoon (gloeilamp op een rond vierkant) als iconset; build-app.sh maakt er AppIcon.icns van.
// Gebruik: swift make-icon.swift <uitvoer.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    // macOS-raster: het vlak beslaat ~80% van het canvas, met afgeronde hoeken
    let inset = s * 0.1
    let tile = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.36, blue: 0.85, alpha: 1),
               ending: NSColor(calibratedRed: 0.36, green: 0.68, blue: 0.98, alpha: 1))!.draw(in: shape, angle: 90)

    let config = NSImage.SymbolConfiguration(pointSize: tile.height * 0.55, weight: .regular)
        .applying(.init(paletteColors: [NSColor(calibratedRed: 1, green: 0.84, blue: 0.25, alpha: 1)]))
    if let bulb = NSImage(systemSymbolName: "lightbulb.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let size = bulb.size
        bulb.draw(in: NSRect(x: tile.midX - size.width / 2, y: tile.midY - size.height / 2,
                             width: size.width, height: size.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
