// Renders the 1024x1024 opaque app icon: swift scripts/make_icon.swift <output.png>
import AppKit

let size = 1024
let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
let s = CGFloat(size)
let gradient = CGGradient(colorsSpace: space, colors: [
    CGColor(red: 0.05, green: 0.08, blue: 0.16, alpha: 1),
    CGColor(red: 0.08, green: 0.30, blue: 0.40, alpha: 1),
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])

// Dot grid suggesting a LiDAR point cloud.
ctx.setFillColor(CGColor(red: 0.3, green: 0.95, blue: 0.75, alpha: 0.35))
for x in stride(from: 96, to: size, by: 64) {
    for y in stride(from: 96, to: size, by: 64) {
        ctx.fillEllipse(in: CGRect(x: x - 5, y: y - 5, width: 10, height: 10))
    }
}

// Wireframe cube.
let c = CGPoint(x: s / 2, y: s / 2)
let r: CGFloat = 250
func p(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint { CGPoint(x: c.x + dx, y: c.y + dy) }
let top = p(0, r), upperLeft = p(-r * 0.87, r * 0.5), upperRight = p(r * 0.87, r * 0.5)
let center = p(0, 0), lowerLeft = p(-r * 0.87, -r * 0.5), lowerRight = p(r * 0.87, -r * 0.5), bottom = p(0, -r)
ctx.setStrokeColor(CGColor(red: 0.4, green: 1, blue: 0.85, alpha: 1))
ctx.setLineWidth(28)
ctx.setLineJoin(.round)
ctx.setLineCap(.round)
ctx.addLines(between: [top, upperRight, lowerRight, bottom, lowerLeft, upperLeft, top])
ctx.addLines(between: [upperLeft, center, upperRight])
ctx.addLines(between: [center, bottom])
ctx.strokePath()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
