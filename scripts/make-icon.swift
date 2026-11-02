// Draws assets/icon.png (1024 px, macOS icon grid: 824 px plate, shadow, subtle gradient and edge).
// Motif N01 in a 100-unit grid, same as assets/menubar.svg. Usage: swift scripts/make-icon.swift
import AppKit

let size = 1024
let motifScale: CGFloat = 6.44   // 15 % larger than the first version (5.6)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx
let cg = ctx.cgContext
// SVG-like coordinates: origin top left
cg.translateBy(x: 0, y: CGFloat(size))
cg.scaleBy(x: 1, y: -1)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

// Plate with Apple's standard drop shadow
let plateRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let plate = CGPath(roundedRect: plateRect, cornerWidth: 185, cornerHeight: 185, transform: nil)
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: 10), blur: 20, color: color(0x000000, 0.35))
cg.addPath(plate)
cg.setFillColor(color(0x2e3236))
cg.fillPath()
cg.restoreGState()

// Subtle vertical gradient, so the plate reads on dark backgrounds
cg.saveGState()
cg.addPath(plate)
cg.clip()
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [color(0x3c4146), color(0x272a2e)] as CFArray, locations: [0, 1])!
cg.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])
cg.restoreGState()

// Fine light edge
cg.addPath(CGPath(roundedRect: plateRect.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 183.5, cornerHeight: 183.5, transform: nil))
cg.setStrokeColor(color(0xffffff, 0.10))
cg.setLineWidth(3)
cg.strokePath()

// Motif N01: folder (flat line ends) above a flat drive with LED
cg.translateBy(x: 512, y: 512)
cg.scaleBy(x: motifScale, y: motifScale)
cg.translateBy(x: -50, y: -52)
cg.setStrokeColor(color(0xe9eaeb))
cg.setFillColor(color(0xe9eaeb))
cg.setLineWidth(3.6)
cg.setLineJoin(.round)

cg.setLineCap(.butt)
cg.move(to: CGPoint(x: 26, y: 47))
for (x, y) in [(26.0, 28.0), (45.2, 28.0), (50.2, 34.0), (74.0, 34.0), (74.0, 47.0)] { cg.addLine(to: CGPoint(x: x, y: y)) }
cg.strokePath()

cg.setLineCap(.round)
cg.addPath(CGPath(roundedRect: CGRect(x: 14, y: 54, width: 72, height: 22), cornerWidth: 6, cornerHeight: 6, transform: nil))
cg.strokePath()
cg.fillEllipse(in: CGRect(x: 74 - 3.5, y: 65 - 3.5, width: 7, height: 7))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "assets/icon.png"))
print("assets/icon.png")
