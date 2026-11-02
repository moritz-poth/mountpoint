// Draws the volume icon that Finder shows for mounted workspaces (macFUSE option volicon).
// macOS drive style: anthracite body, lighter top edge, Mountpoint pictogram, green status LED.
//   swift scripts/make-volume-icon.swift <dir>.iconset   (used by scripts/build-app.sh)
//   swift scripts/make-volume-icon.swift                 → assets/volume-icon.png (preview, 1024 px)
import AppKit

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

func render(_ size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!.retagging(with: .sRGB)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext
    let k = CGFloat(size) / 1024
    cg.scaleBy(x: k, y: k)
    cg.translateBy(x: 0, y: 1024)   // design coordinates: origin top left
    cg.scaleBy(x: 1, y: -1)
    // small sizes: less margin, like macOS drive icons
    let inset: CGFloat = size <= 32 ? 30 : 90
    let body = CGRect(x: inset, y: 170, width: 1024 - 2 * inset, height: 690)
    let radius: CGFloat = 80
    let shape = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // shadow (CG offsets are in base space: negative = down)
    cg.saveGState()
    if size >= 64 { cg.setShadow(offset: CGSize(width: 0, height: -14 * k), blur: 28 * k, color: color(0x000000, 0.35)) }
    cg.addPath(shape)
    cg.setFillColor(color(0x2e3236))
    cg.fillPath()
    cg.restoreGState()

    // body gradient + lighter top edge (suggests the top face of a drive)
    cg.saveGState()
    cg.addPath(shape)
    cg.clip()
    let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                          colors: [color(0x4a4f55), color(0x2b2e33)] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(grad, start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.maxY), options: [])
    cg.setFillColor(color(0xffffff, 0.10))
    cg.fill(CGRect(x: body.minX, y: body.minY, width: body.width, height: 80))
    // base strip
    cg.setFillColor(color(0x000000, 0.22))
    cg.fill(CGRect(x: body.minX, y: body.maxY - 110, width: body.width, height: 110))
    cg.restoreGState()

    // fine light edge
    cg.addPath(CGPath(roundedRect: body.insetBy(dx: 2, dy: 2), cornerWidth: radius - 2, cornerHeight: radius - 2, transform: nil))
    cg.setStrokeColor(color(0xffffff, 0.12))
    cg.setLineWidth(max(4, 1 / k))
    cg.strokePath()

    // status LED in the base strip
    let led: CGFloat = size <= 32 ? 40 : 28
    cg.setFillColor(color(0x3fb950))
    cg.fillEllipse(in: CGRect(x: body.maxX - 100 - led / 2, y: body.maxY - 55 - led / 2, width: led, height: led))

    // pictogram N01 (folder above drive), centered in the face above the base strip
    let unit: CGFloat = size <= 32 ? 7.6 : 5.8
    cg.saveGState()
    cg.translateBy(x: 512, y: body.minY + 40 + (body.height - 150) / 2)
    cg.scaleBy(x: unit, y: unit)
    cg.translateBy(x: -50, y: -52)
    cg.setStrokeColor(color(0xe9eaeb))
    cg.setFillColor(color(0xe9eaeb))
    cg.setLineWidth(max(3.6, (size <= 32 ? 1.4 : 0) / (unit * k)))
    cg.setLineJoin(.round)
    cg.setLineCap(.butt)
    cg.move(to: CGPoint(x: 26, y: 47))
    for (x, y) in [(26.0, 28.0), (45.2, 28.0), (50.2, 34.0), (74.0, 34.0), (74.0, 47.0)] { cg.addLine(to: CGPoint(x: x, y: y)) }
    cg.strokePath()
    cg.setLineCap(.round)
    cg.addPath(CGPath(roundedRect: CGRect(x: 14, y: 54, width: 72, height: 22), cornerWidth: 6, cornerHeight: 6, transform: nil))
    cg.strokePath()
    cg.fillEllipse(in: CGRect(x: 70.5, y: 61.5, width: 7, height: 7))
    cg.restoreGState()

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
