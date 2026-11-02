// Draws the app icon for every size on Apple's icon grid (small sizes have less margin, like Apple's own icons).
//   swift scripts/make-icon.swift            → assets/icon.png (1024 px, for the README)
//   swift scripts/make-icon.swift <dir>.iconset → all iconset sizes (used by scripts/build-app.sh)
// Motif N01 in a 100-unit grid, same as assets/menubar.svg.
import AppKit

/// Plate size per pixel size, measured from macOS system app icons.
let plateFor: [Int: Int] = [16: 14, 32: 28, 64: 52, 128: 104, 256: 206, 512: 412, 1024: 824]
let motifScale: CGFloat = 6.44   // in the 824 px plate; 15 % larger than the first version

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

func render(_ size: Int) -> Data {
    let plateSize = CGFloat(plateFor[size]!)
    let margin = (CGFloat(size) - plateSize) / 2
    let k = plateSize / 824   // everything is designed for the 824 px plate

    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext
    cg.translateBy(x: 0, y: CGFloat(size))   // origin top left
    cg.scaleBy(x: 1, y: -1)

    let plateRect = CGRect(x: margin, y: margin, width: plateSize, height: plateSize)
    let radius = 185 * k
    let plate = CGPath(roundedRect: plateRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // shadow (Apple's standard), only where it is visible
    cg.saveGState()
    if size >= 64 { cg.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 20 * k, color: color(0x000000, 0.35)) }
    cg.addPath(plate)
    cg.setFillColor(color(0x2e3236))
    cg.fillPath()
    cg.restoreGState()

    // subtle vertical gradient
    cg.saveGState()
    cg.addPath(plate)
    cg.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [color(0x3c4146), color(0x272a2e)] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(gradient, start: CGPoint(x: 0, y: plateRect.minY), end: CGPoint(x: 0, y: plateRect.maxY), options: [])
    cg.restoreGState()

    // fine light edge
    let edge = max(3 * k, 0.75)
    cg.addPath(CGPath(roundedRect: plateRect.insetBy(dx: edge / 2, dy: edge / 2),
                      cornerWidth: radius - edge / 2, cornerHeight: radius - edge / 2, transform: nil))
    cg.setStrokeColor(color(0xffffff, 0.10))
    cg.setLineWidth(edge)
    cg.strokePath()

    // motif: folder (flat line ends) above a flat drive with LED
    // tiny sizes: larger motif (like Apple's small icons), otherwise it turns into mush
    let boost: CGFloat = size <= 16 ? 1.45 : size <= 32 ? 1.25 : size <= 64 ? 1.1 : 1
    let unit = k * motifScale * boost   // pixels per motif unit
    cg.translateBy(x: margin + 412 * k, y: margin + 412 * k)
    cg.scaleBy(x: unit, y: unit)
    cg.translateBy(x: -50, y: -52)
    // minimum line weight in tiny sizes, otherwise the lines fade away
    let minPx: CGFloat = size <= 16 ? 1.1 : size <= 32 ? 1.6 : 0
    cg.setLineWidth(max(3.6, minPx / unit))
    cg.setStrokeColor(color(0xe9eaeb))
    cg.setFillColor(color(0xe9eaeb))
    cg.setLineJoin(.round)

    cg.setLineCap(.butt)
    cg.move(to: CGPoint(x: 26, y: 47))
    for (x, y) in [(26.0, 28.0), (45.2, 28.0), (50.2, 34.0), (74.0, 34.0), (74.0, 47.0)] { cg.addLine(to: CGPoint(x: x, y: y)) }
    cg.strokePath()

    cg.setLineCap(.round)
    cg.addPath(CGPath(roundedRect: CGRect(x: 14, y: 54, width: 72, height: 22), cornerWidth: 6, cornerHeight: 6, transform: nil))
    cg.strokePath()
    let led = max(3.5, (size <= 32 ? 1.2 : 0) / unit)
    cg.fillEllipse(in: CGRect(x: 74 - led, y: 65 - led, width: led * 2, height: led * 2))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let args = CommandLine.arguments.dropFirst()
if let dir = args.first {
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for s in [16, 32, 128, 256, 512] {
        try! render(s).write(to: URL(fileURLWithPath: "\(dir)/icon_\(s)x\(s).png"))
        try! render(s * 2).write(to: URL(fileURLWithPath: "\(dir)/icon_\(s)x\(s)@2x.png"))
    }
    print(dir)
} else {
    try! render(1024).write(to: URL(fileURLWithPath: "assets/icon.png"))
    print("assets/icon.png")
}
