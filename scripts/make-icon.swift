// Draws the app icon for every size on Apple's icon grid (small sizes have less margin, like Apple's own icons).
//   swift scripts/make-icon.swift            → assets/icon.png (1024 px, for the README)
//   swift scripts/make-icon.swift <dir>.iconset → all iconset sizes (used by scripts/build-app.sh)
// Motif "folder drive" (concept 8, variant B): a solid drive whose top has a folder tab, green LED = mounted.
// Geometry in a 256-unit grid, same as menuBarIcon() in main.swift and scripts/make-volume-icon.swift.
import AppKit

/// Plate size per pixel size, measured from macOS system app icons.
let plateFor: [Int: Int] = [16: 14, 32: 28, 64: 52, 128: 104, 256: 206, 512: 412, 1024: 824]

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

/// Drive with folder tab: tab from `left` to `tabEnd` at `top`, 45° slant down to the body top, rounded body.
func folderDrive(left: CGFloat, top: CGFloat, bodyTop: CGFloat, tabEnd: CGFloat, right: CGFloat, bottom: CGFloat,
                 tabRadius: CGFloat, radius: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: left, y: (bodyTop + bottom) / 2))
    p.addArc(tangent1End: CGPoint(x: left, y: top), tangent2End: CGPoint(x: tabEnd, y: top), radius: tabRadius)
    p.addLine(to: CGPoint(x: tabEnd, y: top))
    p.addLine(to: CGPoint(x: tabEnd + bodyTop - top, y: bodyTop))   // exactly 45°
    p.addArc(tangent1End: CGPoint(x: right, y: bodyTop), tangent2End: CGPoint(x: right, y: bottom), radius: radius)
    p.addArc(tangent1End: CGPoint(x: right, y: bottom), tangent2End: CGPoint(x: left, y: bottom), radius: radius)
    p.addArc(tangent1End: CGPoint(x: left, y: bottom), tangent2End: CGPoint(x: left, y: top), radius: radius)
    p.closeSubpath()
    return p
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

    // motif: 62 % of the plate (4 px per grid unit in the 824 plate), optically 4 units below the centre
    // tiny sizes: larger motif (like Apple's small icons), otherwise it turns into mush
    let boost: CGFloat = size <= 16 ? 1.3 : size <= 32 ? 1.18 : size <= 64 ? 1.08 : 1
    let unit = k * 4 * 0.62 * boost   // pixels per grid unit
    cg.translateBy(x: margin + 412 * k, y: margin + 412 * k + 16 * k)
    cg.scaleBy(x: unit, y: unit)
    cg.translateBy(x: -128, y: -138)

    let shape = folderDrive(left: 40, top: 80, bodyTop: 100, tabEnd: 98, right: 216, bottom: 196, tabRadius: 12, radius: 20)
    cg.addPath(shape)
    cg.setFillColor(color(0xe9eaeb))
    cg.fillPath()
    cg.addPath(shape)   // the stroke widens the solid shape by 8 units, round corners like the outline version
    cg.setStrokeColor(color(0xe9eaeb))
    cg.setLineWidth(16)
    cg.setLineJoin(.round)
    cg.strokePath()
    // fine seam between tab and body – only where it is still visible
    if size >= 64 {
        cg.setStrokeColor(color(0x272a2e, 0.14))
        cg.setLineWidth(6)
        cg.move(to: CGPoint(x: 48, y: 128))
        cg.addLine(to: CGPoint(x: 208, y: 128))
        cg.strokePath()
    }
    // status LED
    let led = max(13, (size <= 32 ? 1.3 : 0) / unit)
    cg.setFillColor(color(0x1a7f37))
    cg.fillEllipse(in: CGRect(x: 180 - led, y: 164 - led, width: led * 2, height: led * 2))

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
