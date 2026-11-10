// Draws the background of the download image's window (540 × 340 pt, see build-app.sh): transparent (Finder shows white,
// item names stay black in light and dark mode), the app's title "MOUNTPOINT" (Helvetica Neue Light, like Panel.swift)
// and a dry-brush arrow from the app (centre x 140) to the Applications link (centre x 400), icon centres at y 160.
//   swift scripts/make-dmg-background.swift <out.png> <scale>
import AppKit

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

/// Fixed seed: every build draws the same strokes.
struct RNG { var s: UInt64 = 0x4d6f756e74; mutating func next() -> CGFloat { s = s &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(s >> 33) / CGFloat(1 << 31) } }
var rng = RNG()

let args = CommandLine.arguments
let scale = CGFloat(Double(args[2])!)
let w = 540.0, h = 340.0, iconY = 160.0
let ink = color(0x272a2e)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w * scale), pixelsHigh: Int(h * scale), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let cg = NSGraphicsContext.current!.cgContext
cg.scaleBy(x: scale, y: scale)

// title, as at the top of the app's panel
let title = NSAttributedString(string: "MOUNTPOINT", attributes: [
    .font: NSFont(name: "HelveticaNeue-Light", size: 26) ?? NSFont.systemFont(ofSize: 26, weight: .light),
    .kern: 2.5, .foregroundColor: NSColor(cgColor: ink)!])
title.draw(at: NSPoint(x: (w - title.size().width + 2.5) / 2, y: h - 58))

/// One brush stroke along a quadratic curve (top-left coordinates): many bristles side by side, each with small wobble
/// and dry gaps (more at the edges and towards the end), the brush pressing in at the start and lifting at the end.
func brush(from a: CGPoint, via c: CGPoint, to b: CGPoint, width: CGFloat) {
    let bristles = 30, steps = 90
    func point(_ t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u * u * a.x + 2 * u * t * c.x + t * t * b.x, y: u * u * a.y + 2 * u * t * c.y + t * t * b.y)
    }
    cg.setLineCap(.round)
    for i in 0..<bristles {
        let o = (CGFloat(i) / CGFloat(bristles - 1) - 0.5)               // -0.5 … 0.5 across the brush
        let edge = abs(o) * 2                                            // 0 centre … 1 edge
        let start = 0.02 + rng.next() * 0.06 * (0.3 + edge)              // bristles touch down a little apart
        let end = 1 - rng.next() * 0.08 * (0.2 + edge)
        let wobble = rng.next() * 0.6
        cg.setStrokeColor(color(0x272a2e, 0.88 + 0.12 * rng.next()))
        cg.setLineWidth(width / CGFloat(bristles) * (1.6 + rng.next()))
        var drawing = false
        for s in 0...steps {
            let t = start + (end - start) * CGFloat(s) / CGFloat(steps)
            let p = point(t), q = point(min(t + 0.01, 1)), r = point(max(t - 0.01, 0))
            let len = max(hypot(q.x - r.x, q.y - r.y), 0.001)
            let n = CGPoint(x: -(q.y - r.y) / len, y: (q.x - r.x) / len)
            let press = min(1, 0.55 + t * 4) * (t > 0.9 ? 1 - (t - 0.9) * 2.5 : 1)   // press in, lift off
            let off = o * width * press + sin(t * 9 + wobble * 10) * 0.35
            let pt = CGPoint(x: p.x + n.x * off, y: h - (p.y + n.y * off))
            // dry gaps: likelier at the edges and towards the end of the stroke
            let gap = rng.next() < (0.008 + 0.07 * edge * edge * edge + 0.10 * t * t * edge * edge)
            if gap { if drawing { cg.strokePath(); drawing = false }; continue }
            if drawing { cg.addLine(to: pt) } else { cg.move(to: pt); drawing = true }
        }
        if drawing { cg.strokePath() }
    }
}

// shaft: slightly curved, rising towards Applications; head: two strokes into and out of the tip
let tip = CGPoint(x: 322, y: iconY - 6)
brush(from: CGPoint(x: 216, y: iconY + 14), via: CGPoint(x: 262, y: iconY - 2), to: CGPoint(x: tip.x - 2, y: tip.y + 1), width: 15)
brush(from: CGPoint(x: 294, y: iconY - 30), via: CGPoint(x: 310, y: iconY - 18), to: tip, width: 12)
brush(from: tip, via: CGPoint(x: 312, y: iconY + 6), to: CGPoint(x: 300, y: iconY + 20), width: 12)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[1]))
