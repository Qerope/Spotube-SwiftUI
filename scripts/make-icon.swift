import AppKit
func render(_ px: Int, mac: Bool) -> Data {
    let s = CGFloat(px), cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let c = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.scaleBy(x: s / 1024, y: s / 1024)
    // macOS grid: 824pt tile with shadow; iOS: full-bleed (system masks it)
    let tile = mac ? CGRect(x: 100, y: 100, width: 824, height: 824) : CGRect(x: 0, y: 0, width: 1024, height: 1024)
    let path = CGPath(roundedRect: tile, cornerWidth: mac ? 185 : 0, cornerHeight: mac ? 185 : 0, transform: nil)
    if mac { c.saveGState(); c.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(gray: 0, alpha: 0.45)); c.addPath(path); c.setFillColor(.black); c.fillPath(); c.restoreGState() }
    c.saveGState(); c.addPath(path); c.clip()
    c.drawLinearGradient(CGGradient(colorsSpace: cs, colors: [CGColor(gray: 0.11, alpha: 1), CGColor(gray: 0.0, alpha: 1)] as CFArray, locations: [0, 1])!,
                         start: CGPoint(x: 512, y: tile.maxY), end: CGPoint(x: 512, y: tile.minY), options: [])
    // hairline inner border
    c.addPath(CGPath(roundedRect: tile.insetBy(dx: 2, dy: 2), cornerWidth: mac ? 183 : 0, cornerHeight: mac ? 183 : 0, transform: nil))
    c.setStrokeColor(CGColor(gray: 1, alpha: 0.08)); c.setLineWidth(4); c.strokePath()
    let mint1 = CGColor(srgbRed: 0.36, green: 0.98, blue: 0.70, alpha: 1), mint2 = CGColor(srgbRed: 0.10, green: 0.78, blue: 0.52, alpha: 1)
    let cx: CGFloat = 395, cy: CGFloat = 512
    // rounded play triangle
    let tri = CGMutablePath(), r: CGFloat = 34
    let p = [CGPoint(x: cx - 120, y: cy + 165), CGPoint(x: cx + 165, y: cy), CGPoint(x: cx - 120, y: cy - 165)]
    tri.move(to: CGPoint(x: (p[0].x + p[2].x) / 2, y: (p[0].y + p[2].y) / 2))
    for i in 0..<3 { tri.addArc(tangent1End: p[i], tangent2End: p[(i + 1) % 3], radius: r) }
    tri.closeSubpath()
    c.saveGState(); c.addPath(tri); c.clip()
    c.drawLinearGradient(CGGradient(colorsSpace: cs, colors: [mint1, mint2] as CFArray, locations: [0, 1])!, start: CGPoint(x: cx, y: cy + 170), end: CGPoint(x: cx, y: cy - 170), options: [])
    c.restoreGState()
    // two broadcast arcs
    c.setLineCap(.round)
    for (i, rad) in [CGFloat(250), 330].enumerated() {
        c.addArc(center: CGPoint(x: cx + 10, y: cy), radius: rad, startAngle: -.pi / 5.2, endAngle: .pi / 5.2, clockwise: false)
        c.setStrokeColor(i == 0 ? mint1.copy(alpha: 0.85)! : mint1.copy(alpha: 0.4)!); c.setLineWidth(36); c.strokePath()
    }
    c.restoreGState()
    return NSBitmapImageRep(cgImage: c.makeImage()!).representation(using: .png, properties: [:])!
}
let out = CommandLine.arguments[1]
var images: [[String: String]] = []
for (pt, sc) in [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)] {
    let f = "mac\(pt)@\(sc)x.png"; try! render(pt * sc, mac: true).write(to: URL(fileURLWithPath: "\(out)/\(f)"))
    images.append(["idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(sc)x", "filename": f])
}
try! render(1024, mac: false).write(to: URL(fileURLWithPath: "\(out)/ios1024.png"))
images.append(["idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": "ios1024.png"])
let json: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: json, options: .prettyPrinted).write(to: URL(fileURLWithPath: "\(out)/Contents.json"))
