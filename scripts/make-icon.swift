// Renders the app icon: swiftc scripts/make-icon.swift -o /tmp/icon && /tmp/icon icon-1024.png
// then resize into NotesApp/Resources/Assets.xcassets/AppIcon.appiconset (see its Contents.json).
import AppKit
import CoreGraphics

// Off the Record app icon: a speech bubble holding transcript lines, one of them redacted,
// on a red "recording" squircle. Drawn on Apple's 1024 grid (824 pt body, 100 pt margin).
let size: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}
// Flip so y grows downward, like a design tool.
ctx.translateBy(x: 0, y: size); ctx.scaleBy(x: 1, y: -1)

// Body: continuous-corner squircle with a soft drop shadow.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: color(0x000000, 0.28))
ctx.addPath(squircle); ctx.setFillColor(color(0xC8283C)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(squircle); ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [color(0xF2545B), color(0xC8283C), color(0x9E1B30)] as CFArray, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
// Faint top highlight.
let hl = CGGradient(colorsSpace: cs, colors: [color(0xFFFFFF, 0.18), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(hl, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 420), options: [])
ctx.restoreGState()

// Speech bubble with a tail at the lower left.
let bubbleRect = CGRect(x: 220, y: 260, width: 584, height: 420)
let tail = CGMutablePath()
tail.move(to: CGPoint(x: 300, y: 600))
tail.addLine(to: CGPoint(x: 420, y: 640))
tail.addQuadCurve(to: CGPoint(x: 268, y: 792), control: CGPoint(x: 360, y: 760))
tail.addQuadCurve(to: CGPoint(x: 300, y: 600), control: CGPoint(x: 300, y: 700))
tail.closeSubpath()
// One transparency layer so the bubble and its tail cast a single shadow.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 30, color: color(0x4A0710, 0.35))
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
ctx.setFillColor(color(0xFFFBF7))
ctx.addPath(CGPath(roundedRect: bubbleRect, cornerWidth: 96, cornerHeight: 96, transform: nil)); ctx.fillPath()
ctx.addPath(tail); ctx.fillPath()
ctx.endTransparencyLayer()
ctx.restoreGState()

// Transcript lines; the middle one is mostly redacted.
func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ c: CGColor) {
    ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: h / 2, cornerHeight: h / 2, transform: nil))
    ctx.setFillColor(c); ctx.fillPath()
}
let grey = color(0xC9C4C2), ink = color(0x1D1A1F)
bar(300, 350, 424, 40, grey)
bar(300, 445, 110, 40, grey)
bar(432, 434, 292, 62, ink)          // the redaction
bar(300, 540, 300, 40, grey)

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("wrote", CommandLine.arguments[1])
