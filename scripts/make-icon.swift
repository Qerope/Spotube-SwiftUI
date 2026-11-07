// Regenerate the app icons: swift scripts/make-icon.swift Sources/Assets.xcassets/AppIcon.appiconset
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Spotube Lite icon: white play + sound waves on Apple Music red. Drawn in a 1024 space.
func draw(_ ctx: CGContext, mac: Bool) {
    let cs = CGColorSpaceCreateDeviceRGB()
    ctx.translateBy(x: 0, y: 1024); ctx.scaleBy(x: 1, y: -1)  // top-left origin
    var body = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    if mac {
        body = CGRect(x: 100, y: 100, width: 824, height: 824)
        let path = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
        ctx.addPath(path); ctx.setFillColor(CGColor(red: 0.9, green: 0.15, blue: 0.25, alpha: 1)); ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(path); ctx.clip()
    }
    let grad = CGGradient(colorsSpace: cs, colors: [CGColor(red: 1, green: 0.36, blue: 0.45, alpha: 1), CGColor(red: 0.98, green: 0.176, blue: 0.282, alpha: 1),
                                                     CGColor(red: 0.84, green: 0.09, blue: 0.2, alpha: 1)] as CFArray, locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: body.minY), end: CGPoint(x: 512, y: body.maxY), options: [])
    // Content scaled into the body.
    let s = body.width / 1024
    ctx.translateBy(x: body.minX, y: body.minY); ctx.scaleBy(x: s, y: s)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 30, color: CGColor(red: 0.45, green: 0, blue: 0.08, alpha: 0.35))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    // Rounded play triangle (fill + round-joined stroke).
    let tri = CGMutablePath()
    tri.move(to: CGPoint(x: 305, y: 402)); tri.addLine(to: CGPoint(x: 305, y: 620)); tri.addLine(to: CGPoint(x: 497, y: 511)); tri.closeSubpath()
    ctx.setFillColor(.white); ctx.setStrokeColor(.white); ctx.setLineWidth(60); ctx.setLineJoin(.round)
    ctx.addPath(tri); ctx.drawPath(using: .fillStroke)
    ctx.setLineCap(.round); ctx.setLineWidth(36)
    func arc(_ cx: CGFloat, _ r: CGFloat, _ deg: CGFloat, _ alpha: CGFloat) {
        let a = deg * .pi / 180
        ctx.setStrokeColor(CGColor(gray: 1, alpha: alpha))
        ctx.addArc(center: CGPoint(x: cx, y: 511), radius: r, startAngle: -a, endAngle: a, clockwise: false); ctx.strokePath()
    }
    arc(476, 196, 46.9, 0.95)
    arc(403, 332, 34.7, 0.55)
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

func write(_ name: String, _ px: Int, mac: Bool) {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: (mac ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    draw(ctx, mac: mac)
    let url = URL(fileURLWithPath: CommandLine.arguments[1] + "/" + name)
    let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, ctx.makeImage()!, nil); CGImageDestinationFinalize(d)
}

write("ios1024.png", 1024, mac: false)
for (n, px) in [(16, 16), (16, 32), (32, 32), (32, 64), (128, 128), (128, 256), (256, 256), (256, 512), (512, 512), (512, 1024)] {
    write("mac\(n)@\(px / n)x.png", px, mac: true)
}
