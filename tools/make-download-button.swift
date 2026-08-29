// Renders docs/download-button.png — the landing page's download button, as a
// flat image the README can link.
//
// Markdown carries no CSS, so the button has to be a picture. It is drawn from
// the same numbers as `.btn` in docs/index.html rather than cropped out of a
// screenshot, so the two stay in step: change the palette there and re-run this.
//
//   swift tools/make-download-button.swift docs/download-button.png
//
// Only the button is an image. The title, tagline and lede around it are real
// markdown, because the README has no background of its own and GitHub renders
// it on either a white or a near-black page — near-white type baked into a
// transparent PNG would disappear on the light theme. The button survives both
// because it carries its own cream fill and dark ink.
//
// It is drawn WITHOUT the page's outer glow. That shadow is a dark-background
// effect; on the light theme it renders as a smudge.

import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs/download-button.png"

// Geometry mirrors `.btn`. 2x to match docs/screenshot.png, which is also 2x.
let scale: CGFloat = 2
let fontSize: CGFloat = 17
let padX: CGFloat = 30, padY: CGFloat = 15
let gap: CGFloat = 10, glyph: CGFloat = 17, radius: CGFloat = 13
let kern: CGFloat = -0.17          // letter-spacing: -.01em

func srgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green:   CGFloat((hex >> 8) & 0xff) / 255,
            blue:    CGFloat(hex & 0xff) / 255, alpha: a)
}

let ink = srgb(0x16130d)
let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)   // font-weight: 600
let title = NSAttributedString(string: "Download for macOS",
                               attributes: [.font: font, .foregroundColor: ink, .kern: kern])

let lineHeight = ceil(font.ascender - font.descender + font.leading)
let w = ceil(padX * 2 + glyph + gap + title.size().width)
let h = padY * 2 + lineHeight

guard let ctx = CGContext(data: nil, width: Int(w * scale), height: Int(h * scale),
                          bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    FileHandle.standardError.write(Data("cannot create context\n".utf8)); exit(1)
}
ctx.scaleBy(x: scale, y: scale)
ctx.translateBy(x: 0, y: h)             // flip to y-down, so the SVG path below
ctx.scaleBy(x: 1, y: -1)                // can be transcribed coordinate for coordinate
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)

// ── the pill ────────────────────────────────────────────────────────────────
let pill = CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h),
                  cornerWidth: radius, cornerHeight: radius, transform: nil)
ctx.saveGState()
ctx.addPath(pill); ctx.clip()
let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                      colors: [srgb(0xfff0d2).cgColor, srgb(0xf6d99f).cgColor] as CFArray,
                      locations: [0, 1])!
ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 0, y: h), options: [])
ctx.setFillColor(NSColor(white: 1, alpha: 0.5).cgColor)   // inset 0 1px 0 highlight
ctx.fill(CGRect(x: 0, y: 0, width: w, height: 1))
ctx.restoreGState()

// ── the download glyph, transcribed from the inline SVG (viewBox 0 0 16 16) ──
ctx.saveGState()
ctx.translateBy(x: padX, y: (h - glyph) / 2)
ctx.scaleBy(x: glyph / 16, y: glyph / 16)
ctx.setStrokeColor(ink.cgColor)
ctx.setLineWidth(1.6); ctx.setLineCap(.round); ctx.setLineJoin(.round)

ctx.move(to: CGPoint(x: 8, y: 1.5));  ctx.addLine(to: CGPoint(x: 8, y: 10))
ctx.move(to: CGPoint(x: 8, y: 10));   ctx.addLine(to: CGPoint(x: 4.75, y: 6.75))
ctx.move(to: CGPoint(x: 8, y: 10));   ctx.addLine(to: CGPoint(x: 11.25, y: 6.75))
ctx.move(to: CGPoint(x: 2, y: 11.5))
ctx.addArc(tangent1End: CGPoint(x: 2, y: 14), tangent2End: CGPoint(x: 3.5, y: 14), radius: 1.5)
ctx.addLine(to: CGPoint(x: 12.5, y: 14))
ctx.addArc(tangent1End: CGPoint(x: 14, y: 14), tangent2End: CGPoint(x: 14, y: 12.5), radius: 1.5)
ctx.addLine(to: CGPoint(x: 14, y: 11.5))
ctx.strokePath()
ctx.restoreGState()

// ── the label ───────────────────────────────────────────────────────────────
title.draw(in: CGRect(x: padX + glyph + gap, y: (h - lineHeight) / 2,
                      width: w, height: lineHeight))

guard let image = ctx.makeImage() else {
    FileHandle.standardError.write(Data("cannot render\n".utf8)); exit(1)
}
let rep = NSBitmapImageRep(cgImage: image)
rep.size = NSSize(width: w, height: h)
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) — \(Int(w * scale))x\(Int(h * scale)) px, display width \(Int(w))")
