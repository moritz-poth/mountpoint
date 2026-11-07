// Draws the volume icon that Finder shows for mounted workspaces (macFUSE option volicon).
// The volume itself has the "folder drive" shape (concept 8, volume B): steel-grey body with a folder tab, a dark
// drive base with a light seam and a green LED – the base and LED keep it apart from a plain folder at 16 px.
// Steel grey because anthracite vanished in dark Finder windows; nearly square because Finder's column view
// shrinks wide icons to a thin strip. Geometry in a 256-unit grid, like scripts/make-icon.swift.
//   swift scripts/make-volume-icon.swift <dir>.iconset   (used by scripts/build-app.sh)
//   swift scripts/make-volume-icon.swift                 → assets/volume-icon.png (preview, 1024 px)
import AppKit

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

/// Same construction as in make-icon.swift: tab, 45° slant, rounded body.
func folderDrive(left: CGFloat, top: CGFloat, bodyTop: CGFloat, tabEnd: CGFloat, right: CGFloat, bottom: CGFloat,
                 tabRadius: CGFloat, radius: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: left, y: (bodyTop + bottom) / 2))
    p.addArc(tangent1End: CGPoint(x: left, y: top), tangent2End: CGPoint(x: tabEnd, y: top), radius: tabRadius)
    p.addLine(to: CGPoint(x: tabEnd, y: top))
    p.addLine(to: CGPoint(x: tabEnd + bodyTop - top, y: bodyTop))
    p.addArc(tangent1End: CGPoint(x: right, y: bodyTop), tangent2End: CGPoint(x: right, y: bottom), radius: radius)
    p.addArc(tangent1End: CGPoint(x: right, y: bottom), tangent2End: CGPoint(x: left, y: bottom), radius: radius)
    p.addArc(tangent1End: CGPoint(x: left, y: bottom), tangent2End: CGPoint(x: left, y: top), radius: radius)
    p.closeSubpath()
    return p
}

func render(_ size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!.retagging(with: .sRGB)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext
    let k = CGFloat(size) / 256
    cg.scaleBy(x: k, y: k)
    cg.translateBy(x: 0, y: 256)   // design coordinates: origin top left
    cg.scaleBy(x: 1, y: -1)

    // 16/32 px: own cut – base a third of the height, strong seam and LED, no shadow or light edge (they only smear)
    let small = size <= 32
    let baseTop: CGFloat = small ? 170 : 184
    let shape = folderDrive(left: 16, top: 48, bodyTop: 72, tabEnd: 100, right: 240, bottom: 238, tabRadius: 16, radius: 24)

    // shadow (CG offsets are in base space: negative = down)
    cg.saveGState()
    if size >= 64 { cg.setShadow(offset: CGSize(width: 0, height: -4 * k), blur: 7 * k, color: color(0x000000, 0.3)) }
    cg.addPath(shape)
    cg.setFillColor(color(0x5c6268))
    cg.fillPath()
    cg.restoreGState()

    // steel gradient, lighter top band, dark drive base
    cg.saveGState()
    cg.addPath(shape)
    cg.clip()
    let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                          colors: [color(0x8b9197), color(0x5a6066)] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(grad, start: CGPoint(x: 0, y: 48), end: CGPoint(x: 0, y: 238), options: [])
    cg.setFillColor(color(0xffffff, 0.10))
    cg.fill(CGRect(x: 0, y: 48, width: 256, height: 40))
    cg.setFillColor(color(0x1f2225, 0.55))
    cg.fill(CGRect(x: 0, y: baseTop, width: 256, height: 238 - baseTop))
    cg.restoreGState()

    // light seam above the base
    cg.setStrokeColor(color(0xffffff, 0.35))
    cg.setLineWidth(small ? 6 : max(2, 1 / k))
    cg.move(to: CGPoint(x: 16, y: baseTop))
    cg.addLine(to: CGPoint(x: 240, y: baseTop))
    cg.strokePath()

    // fine light edge
    if !small {
        cg.addPath(shape)
        cg.setStrokeColor(color(0xffffff, 0.25))
        cg.setLineWidth(max(1.5, 1 / k))
        cg.strokePath()
    }

    // status LED in the base
    let led: CGFloat = small ? 18 : 10
    let ledX: CGFloat = small ? 196 : 206
    cg.setFillColor(color(0x3fb950))
    cg.fillEllipse(in: CGRect(x: ledX - led, y: (baseTop + 238) / 2 - led, width: led * 2, height: led * 2))

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
    try! render(1024).write(to: URL(fileURLWithPath: "assets/volume-icon.png"))
    print("assets/volume-icon.png")
}
