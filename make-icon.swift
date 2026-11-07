// Renders the app icon PNGs into an .iconset folder: the Icon.swift tombstone on a dusk sky.
// Usage (build.sh does this): xcrun swiftc -parse-as-library make-icon.swift Icon.swift -o /tmp/mk && /tmp/mk <out.iconset>
import AppKit

@main enum MakeIcon {
    static func main() throws {
        let out = CommandLine.arguments[1]
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                           ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
            try render(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
        }
    }

    static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    static func render(_ px: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let ctx = NSGraphicsContext.current!.cgContext
        let size = CGFloat(px), detailed = px >= 64

        // Tile on the macOS icon grid, with a soft drop shadow.
        let t = NSRect(x: size * 0.1, y: size * 0.1, width: size * 0.8, height: size * 0.8)
        let tile = NSBezierPath(roundedRect: t, xRadius: t.width * 0.225, yRadius: t.width * 0.225)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = size * 0.02
        shadow.shadowOffset = NSSize(width: 0, height: -size * 0.01)
        shadow.set()
        rgb(0x1A1640).setFill()
        tile.fill()
        NSShadow().set()

        NSGraphicsContext.saveGraphicsState()
        tile.addClip()
        func u(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: t.minX + x * t.width, y: t.minY + y * t.height) }

        // Dusk sky: night at the top, a warm horizon behind the hill.
        NSGradient(colors: [rgb(0x15123A), rgb(0x3E2768), rgb(0x9C4A7A), rgb(0xF2925E)],
                   atLocations: [0, 0.45, 0.72, 1], colorSpace: .sRGB)!.draw(in: t, angle: -90)

        if detailed {
            rgb(0xFFFFFF, 0.85).setFill()
            for (x, y, r) in [(0.14, 0.62, 0.008), (0.31, 0.9, 0.006), (0.47, 0.84, 0.009), (0.62, 0.93, 0.005),
                              (0.78, 0.86, 0.01), (0.88, 0.7, 0.006), (0.7, 0.72, 0.005), (0.11, 0.9, 0.006)] as [(CGFloat, CGFloat, CGFloat)] {
                let c = u(x, y), d = r * t.width * 2
                NSBezierPath(ovalIn: NSRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)).fill()
            }
            // Crescent moon: a disc minus an offset disc.
            let m = u(0.2, 0.8), mr = t.width * 0.085, cut = u(0.235, 0.83)
            ctx.saveGState()
            ctx.addRect(t)
            ctx.addEllipse(in: CGRect(x: cut.x - mr, y: cut.y - mr, width: mr * 2, height: mr * 2))
            ctx.clip(using: .evenOdd)
            rgb(0xFFF1CC).setFill()
            NSBezierPath(ovalIn: NSRect(x: m.x - mr, y: m.y - mr, width: mr * 2, height: mr * 2)).fill()
            ctx.restoreGState()
        }

        // The stone, standing on a dark hill.
        let s = t.width * 0.66
        let r = NSRect(x: t.midX - s / 2, y: t.minY + t.height * 0.2 - s * Tombstone.base, width: s, height: s)
        let glowCentre = Tombstone.point(0.5, 0.5, in: r)
        NSGradient(colors: [rgb(0x5CF5B8, 0.35), rgb(0x5CF5B8, 0)])!
            .draw(fromCenter: glowCentre, radius: 0, toCenter: glowCentre, radius: s * 0.62, options: [])

        let hill = NSBezierPath()
        hill.move(to: u(0, 0))
        hill.line(to: u(0, 0.17))
        hill.curve(to: u(1, 0.15), controlPoint1: u(0.35, 0.27), controlPoint2: u(0.7, 0.24))
        hill.line(to: u(1, 0))
        hill.close()
        NSGradient(colors: [rgb(0x2A2050), rgb(0x0F0B22)])!.draw(in: hill, angle: -90)

        NSGradient(colors: [rgb(0xE4E1F0), rgb(0x9A94B6)])!.draw(in: Tombstone.stone(r), angle: -90)

        if detailed { // engraved "PID" above the heartbeat
            let base = NSFont.systemFont(ofSize: s * 0.12, weight: .black)
            let font = base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: s * 0.12) } ?? base
            let text = NSAttributedString(string: "PID", attributes: [
                .font: font, .foregroundColor: rgb(0x5E587C), .kern: s * 0.012,
            ])
            let ts = text.size(), c = Tombstone.point(0.47, 0.71, in: r)
            text.draw(at: NSPoint(x: c.x - ts.width / 2, y: c.y - ts.height / 2))
        }

        // Glowing restart arrow round the edge and the heartbeat inside: back from the dead.
        let glow = NSShadow()
        glow.shadowColor = rgb(0x5CF5B8, 0.9)
        glow.shadowBlurRadius = size * 0.025
        glow.set()
        rgb(0x5CF5B8).set()
        Tombstone.stroke(Tombstone.outline(r), s * 0.075)
        Tombstone.arrowHead(r).fill()
        Tombstone.stroke(Tombstone.pulse(r), s * 0.06)
        NSShadow().set()

        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }
}
