// Tekent het app-icoon (gloeilamp met een stip eronder, als een uitroepteken, op een rond vierkant; zelfde vormen als het Android-icoon) als iconset; build-app.sh maakt er AppIcon.icns van.
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

    // gloeilamp zelf getekend (geen SF Symbol: dat mag niet in een app-icoon), dezelfde vormen als het
    // Android-icoon (android/app/src/main/res/drawable/ic_launcher_foreground.xml): een raster van 108 eenheden
    // over het vlak, y naar beneden zoals daar
    let bulb = CGMutablePath()
    bulb.move(to: CGPoint(x: 46, y: 63.5))
    bulb.addCurve(to: CGPoint(x: 38, y: 41), control1: CGPoint(x: 46, y: 57.5), control2: CGPoint(x: 38, y: 53))
    bulb.addArc(center: CGPoint(x: 54, y: 41), radius: 16, startAngle: .pi, endAngle: 2 * .pi, clockwise: false)
    bulb.addCurve(to: CGPoint(x: 62, y: 63.5), control1: CGPoint(x: 70, y: 53), control2: CGPoint(x: 62, y: 57.5))
    bulb.closeSubpath()
    for y in [66.8, 72.0] {   // twee ringen van de fitting
        bulb.addRoundedRect(in: CGRect(x: 44.3, y: y, width: 19.4, height: 3.4), cornerWidth: 1.7, cornerHeight: 1.7)
    }
    bulb.move(to: CGPoint(x: 61, y: 77.2))   // het dopje: halve ellips onderaan
    bulb.addArc(center: .zero, radius: 1, startAngle: 0, endAngle: .pi, clockwise: false,
                transform: CGAffineTransform(translationX: 54, y: 77.2).scaledBy(x: 7, y: 4.8))
    bulb.closeSubpath()
    // lamp iets kleiner en hoger, met een stip eronder: samen een uitroepteken (zoals het Android-icoon)
    let shrink = CGAffineTransform(translationX: 54, y: 22).scaledBy(x: 0.8, y: 0.8).translatedBy(x: -54, y: -22)
    let mark = CGMutablePath()
    mark.addPath(bulb, transform: shrink)
    mark.addEllipse(in: CGRect(x: 49.5, y: 74.5, width: 9, height: 9))
    let toTile = CGAffineTransform(translationX: tile.minX, y: tile.maxY)
        .scaledBy(x: tile.width / 108, y: -tile.height / 108)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.addPath(mark.copy(using: [toTile])!)
    ctx.setFillColor(NSColor(calibratedRed: 1, green: 0.84, blue: 0.25, alpha: 1).cgColor)
    ctx.fillPath()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
