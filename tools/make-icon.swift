import AppKit
import CoreGraphics

// ── Apple's continuous-corner squircle ───────────────────────────────────────
// Not a plain rounded rect: the 90° corner arc is shortened and blended into
// each edge with cubic segments, which is what stops the corners reading as
// "drawn with a compass". Standard construction, smoothing = 0.6 (Apple's).
func squircle(size S: CGFloat, radius R: CGFloat, smoothing s: CGFloat = 0.6) -> CGPath {
    let d2r = { (d: CGFloat) in d * .pi / 180 }
    let p  = (1 + s) * R
    let arcMeasure = 90 * (1 - s)
    let arcChordHalf = sin(d2r(arcMeasure / 2)) * R * sqrt(2)   // dx == dy of the chord
    let angleAlpha = (90 - arcMeasure) / 2
    let p3p4 = R * tan(d2r(angleAlpha / 2))
    let angleBeta = 45 * s
    let c = p3p4 * cos(d2r(angleBeta))
    let d = c * tan(d2r(angleBeta))
    let b = (p - arcChordHalf - c - d) / 3
    let a = 2 * b

    let path = CGMutablePath()
    // Built in a y-down convention; the shape is symmetric so orientation is moot.
    func corner(_ cx: CGFloat, _ cy: CGFloat, _ a0: CGFloat, _ a1: CGFloat) {
        path.addArc(center: CGPoint(x: cx, y: cy), radius: R,
                    startAngle: d2r(a0), endAngle: d2r(a1), clockwise: false)
    }
    path.move(to: CGPoint(x: p, y: 0))
    path.addLine(to: CGPoint(x: S - p, y: 0))
    path.addCurve(to: CGPoint(x: S - p + a + b + c, y: d),
                  control1: CGPoint(x: S - p + a, y: 0), control2: CGPoint(x: S - p + a + b, y: 0))
    corner(S - R, R, -63, -27)
    var e = path.currentPoint
    path.addCurve(to: CGPoint(x: e.x + d, y: e.y + a + b + c),
                  control1: CGPoint(x: e.x + d, y: e.y + c), control2: CGPoint(x: e.x + d, y: e.y + b + c))
    path.addLine(to: CGPoint(x: S, y: S - p))
    path.addCurve(to: CGPoint(x: S - d, y: S - p + a + b + c),
                  control1: CGPoint(x: S, y: S - p + a), control2: CGPoint(x: S, y: S - p + a + b))
    corner(S - R, S - R, 27, 63)
    e = path.currentPoint
    path.addCurve(to: CGPoint(x: e.x - (a + b + c), y: e.y + d),
                  control1: CGPoint(x: e.x - c, y: e.y + d), control2: CGPoint(x: e.x - (b + c), y: e.y + d))
    path.addLine(to: CGPoint(x: p, y: S))
    path.addCurve(to: CGPoint(x: p - (a + b + c), y: S - d),
                  control1: CGPoint(x: p - a, y: S), control2: CGPoint(x: p - (a + b), y: S))
    corner(R, S - R, 117, 153)
    e = path.currentPoint
    path.addCurve(to: CGPoint(x: e.x - d, y: e.y - (a + b + c)),
                  control1: CGPoint(x: e.x - d, y: e.y - c), control2: CGPoint(x: e.x - d, y: e.y - (b + c)))
    path.addLine(to: CGPoint(x: 0, y: p))
    path.addCurve(to: CGPoint(x: d, y: p - (a + b + c)),
                  control1: CGPoint(x: 0, y: p - a), control2: CGPoint(x: 0, y: p - (a + b)))
    corner(R, R, -153, -117)
    e = path.currentPoint
    path.addCurve(to: CGPoint(x: e.x + a + b + c, y: e.y - d),
                  control1: CGPoint(x: e.x + c, y: e.y - d), control2: CGPoint(x: e.x + b + c, y: e.y - d))
    path.closeSubpath()
    return path
}

// ── The glyph: keyboard key + light rays, from the reference art ─────────────
// Five rays on an even 34° fan radiating from the key, which is the macOS
// keyboard-illumination motif on the F5/F6 keys.
func glyphPath(small: Bool = false) -> CGPath {
    let p = CGMutablePath()
    let c = CGPoint(x: 0, y: 0)
    let r1: CGFloat = small ? 188 : 196
    let r2: CGFloat = small ? 300 : 302
    let w:  CGFloat = small ? 40 : 29
    for deg in (small ? [-58.0, 0.0, 58.0] : [-68.0, -34.0, 0.0, 34.0, 68.0]) {
        let t = CGFloat(deg) * .pi / 180
        let inner = CGPoint(x: c.x + sin(t) * r1, y: c.y + cos(t) * r1)
        let outer = CGPoint(x: c.x + sin(t) * r2, y: c.y + cos(t) * r2)
        let seg = CGMutablePath()
        seg.move(to: inner); seg.addLine(to: outer)
        p.addPath(seg.copy(strokingWithWidth: w, lineCap: .round, lineJoin: .round, miterLimit: 10))
    }
    // The key itself.
    let bar = CGRect(x: -118, y: -18, width: 236, height: small ? 58 : 52)
    p.addPath(CGPath(roundedRect: bar, cornerWidth: 26, cornerHeight: 26, transform: nil))
    return p
}

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a)
}

func render(size: CGFloat) -> CGImage {
    let sc = size / 1024.0
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: sc, y: sc)
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // Apple's macOS grid: an 824pt body centred in a 1024pt canvas.
    let bodyS: CGFloat = 824, inset: CGFloat = 100, radius: CGFloat = 185.4
    let body = squircle(size: bodyS, radius: radius)
    var move = CGAffineTransform(translationX: inset, y: inset)
    let bodyPath = body.copy(using: &move)!

    // Ambient shadow, as the icon templates carry.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 34,
                  color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.42))
    ctx.addPath(bodyPath); ctx.setFillColor(color(20, 21, 24)); ctx.fillPath()
    ctx.restoreGState()

    // Body gradient — cool graphite, lit from above the way macOS icons are.
    ctx.saveGState()
    ctx.addPath(bodyPath); ctx.clip()
    let grad = CGGradient(colorsSpace: cs, colors: [
        color(72, 77, 87), color(48, 52, 60), color(31, 33, 38), color(19, 20, 23)
    ] as CFArray, locations: [0, 0.42, 0.74, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: inset + bodyS),
                           end: CGPoint(x: 0, y: inset), options: [])

    // Warm pool of light rising off the key, as if the backlight bleeds.
    let glow = CGGradient(colorsSpace: cs, colors: [
        color(255, 196, 110, 0.22), color(255, 176, 90, 0.07), color(255, 170, 80, 0.0)
    ] as CFArray, locations: [0, 0.45, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 458), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 458), endRadius: 340, options: [])
    ctx.restoreGState()

    // Specular top rim — the single detail that most sells "native".
    ctx.saveGState()
    ctx.addPath(bodyPath); ctx.clip()
    ctx.addPath(bodyPath)
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.30))
    ctx.setLineWidth(5)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let rim = CGGradient(colorsSpace: cs, colors: [
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.42),
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.05),
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.0)
    ] as CFArray, locations: [0, 0.35, 1])!
    ctx.drawLinearGradient(rim, start: CGPoint(x: 0, y: inset + bodyS),
                           end: CGPoint(x: 0, y: inset + bodyS * 0.45), options: [])
    ctx.restoreGState()

    // Glyph, optically centred in the body.
    let g = glyphPath(small: size <= 32)
    let bb = g.boundingBox
    let scale: CGFloat = size <= 32 ? 0.82 : 0.90
    var gt = CGAffineTransform(translationX: 512 - bb.midX * scale, y: 512 - bb.midY * scale)
        .scaledBy(x: scale, y: scale)
    let gp = g.copy(using: &gt)!

    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 46, color: color(255, 190, 120, 0.85))
    ctx.addPath(gp); ctx.setFillColor(color(255, 247, 235)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 16, color: color(255, 214, 160, 0.9))
    ctx.addPath(gp); ctx.setFillColor(color(255, 250, 243)); ctx.fillPath()
    ctx.restoreGState()

    return ctx.makeImage()!
}

let outDir = CommandLine.arguments[1]
let mode = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "preview"

func writePNG(_ img: CGImage, _ name: String) {
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
}

if mode == "iconset" {
    for (px, name) in [(16,"icon_16x16"),(32,"icon_16x16@2x"),(32,"icon_32x32"),
                       (64,"icon_32x32@2x"),(128,"icon_128x128"),(256,"icon_128x128@2x"),
                       (256,"icon_256x256"),(512,"icon_256x256@2x"),(512,"icon_512x512"),
                       (1024,"icon_512x512@2x")] {
        writePNG(render(size: CGFloat(px)), "\(name).png")
    }
    print("wrote iconset pngs")
} else {
    writePNG(render(size: 1024), "preview_1024.png")
    // Contact sheet: each small size blown up 6x with no smoothing, so the
    // actual delivered pixels are what gets judged.
    let sizes: [CGFloat] = [16, 32, 64, 128]
    let zoom: CGFloat = 6, pad: CGFloat = 20
    let sheetW = sizes.reduce(0) { $0 + $1 * zoom + pad } + pad
    let sheetH = 128 * zoom + pad * 2
    let cs = CGColorSpaceCreateDeviceRGB()
    let sheet = CGContext(data: nil, width: Int(sheetW), height: Int(sheetH), bitsPerComponent: 8,
                          bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    sheet.setFillColor(CGColor(srgbRed: 0.62, green: 0.62, blue: 0.64, alpha: 1))
    sheet.fill(CGRect(x: 0, y: 0, width: sheetW, height: sheetH))
    sheet.interpolationQuality = .none
    var x = pad
    for s in sizes {
        let img = render(size: s)
        let w = s * zoom
        sheet.draw(img, in: CGRect(x: x, y: sheetH - pad - w, width: w, height: w))
        x += w + pad
    }
    writePNG(sheet.makeImage()!, "sheet.png")
    print("wrote preview + sheet")
}
