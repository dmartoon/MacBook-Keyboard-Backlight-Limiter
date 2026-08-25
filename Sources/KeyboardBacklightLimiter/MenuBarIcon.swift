import AppKit

/// The menu bar item's icon: the app icon's glyph exactly — five rays over a
/// single key — with no squircle behind it.
///
/// The geometry below is copied from `glyphPath()` in `tools/make-icon.swift`
/// (its full-size variant). If one is retuned, retune the other, or the menu
/// bar and the app icon drift apart.
///
/// Marked as a **template image**, which is what makes it white. macOS tints
/// template images itself, so it renders white on a dark menu bar and black on
/// a light one, and stays correct under wallpaper tinting and while the item is
/// highlighted. Hardcoding white would make it invisible in light mode.
enum MenuBarIcon {
    /// Sized by **height**, with the width following the glyph's own aspect.
    /// Forcing it into a square was the bug: this mark is roughly 1.8:1, so a
    /// square box is width-constrained and the glyph ends up barely half the
    /// height of the Wi-Fi and battery items beside it. Menu bar items are
    /// matched on height, and wide ones are perfectly normal — the battery is
    /// wider than this.
    /// 15pt rather than 16: a whole point is the nearest step down that keeps
    /// the height integral, and integral heights stay crisp at both 1x and 2x —
    /// worth more than hitting exactly 95% on a 16pt mark.
    static func image(height: CGFloat = 15) -> NSImage {
        let box = glyph().boundingBox
        let width = (height * box.width / box.height).rounded()
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(NSColor.black.cgColor)   // recoloured by the template
            ctx.addPath(fitted(in: rect, inset: 0.5))
            ctx.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Scales the glyph to fill the target box, so the geometry can stay in the
    /// app icon's own units and be compared against it directly.
    private static func fitted(in rect: CGRect, inset: CGFloat) -> CGPath {
        let raw = glyph()
        let box = raw.boundingBox
        let target = rect.insetBy(dx: inset, dy: inset)
        let scale = min(target.width / box.width, target.height / box.height)
        var t = CGAffineTransform(
            translationX: target.midX - box.midX * scale,
            y: target.midY - box.midY * scale
        ).scaledBy(x: scale, y: scale)
        return raw.copy(using: &t)!
    }

    private static func glyph() -> CGPath {
        let path = CGMutablePath()
        // Heavier than the app icon's 29: the icon has a whole 1024pt canvas to
        // carry a fine line, the menu bar has 16pt and sits next to chunky
        // system glyphs.
        let r1: CGFloat = 196, r2: CGFloat = 302, width: CGFloat = 36
        for degrees in [-68.0, -34.0, 0.0, 34.0, 68.0] {
            let t = CGFloat(degrees) * .pi / 180
            let segment = CGMutablePath()
            segment.move(to: CGPoint(x: sin(t) * r1, y: cos(t) * r1))
            segment.addLine(to: CGPoint(x: sin(t) * r2, y: cos(t) * r2))
            path.addPath(segment.copy(strokingWithWidth: width, lineCap: .round,
                                      lineJoin: .round, miterLimit: 10))
        }
        let key = CGRect(x: -118, y: -18, width: 236, height: 58)
        path.addPath(CGPath(roundedRect: key, cornerWidth: 29, cornerHeight: 29, transform: nil))
        return path
    }
}
