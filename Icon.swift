import AppKit

/// RestinPID's mark: a tombstone whose rounded top is a restart arrow, with a heartbeat inside.
/// "Rest in PID", brought back to life. One geometry feeds the app icon (make-icon.swift) and the menu bar.
enum Tombstone {
    // Unit square, y up.
    static let left = 0.22, right = 0.78, base = 0.12, radius = 0.28
    static let centre = (x: 0.5, y: 0.56)
    static let arrowEnd = 32.0 // degrees: the arrow stops here, leaving a gap down to the right side

    static func point(_ x: Double, _ y: Double, in r: NSRect) -> NSPoint {
        NSPoint(x: r.minX + x * r.width, y: r.minY + y * r.height)
    }

    /// Closed stone shape: base, sides and round top.
    static func stone(_ r: NSRect) -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: point(left, base, in: r))
        p.line(to: point(right, base, in: r))
        p.line(to: point(right, centre.y, in: r))
        p.appendArc(withCenter: point(centre.x, centre.y, in: r), radius: radius * r.width, startAngle: 0, endAngle: 180)
        p.close()
        return p
    }

    /// The stone's edge, open at the upper right where the restart arrow ends.
    static func outline(_ r: NSRect) -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: point(right, centre.y - 0.13, in: r))
        p.line(to: point(right, base, in: r))
        p.line(to: point(left, base, in: r))
        p.line(to: point(left, centre.y, in: r))
        p.appendArc(withCenter: point(centre.x, centre.y, in: r), radius: radius * r.width,
                    startAngle: 180, endAngle: arrowEnd, clockwise: true)
        return p
    }

    /// Arrowhead at the end of the outline, pointing clockwise.
    static func arrowHead(_ r: NSRect) -> NSBezierPath {
        let a = arrowEnd * .pi / 180
        let (nx, ny) = (cos(a), sin(a))      // outward normal
        let (dx, dy) = (sin(a), -cos(a))     // clockwise tangent
        let (px, py) = (centre.x + radius * nx, centre.y + radius * ny)
        let len = 0.16, half = 0.115
        let p = NSBezierPath()
        p.move(to: point(px + dx * len, py + dy * len, in: r))
        p.line(to: point(px + nx * half, py + ny * half, in: r))
        p.line(to: point(px - nx * half, py - ny * half, in: r))
        p.close()
        return p
    }

    /// The ground the stone stands on.
    static func ground(_ r: NSRect) -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: point(0.08, base, in: r))
        p.line(to: point(0.92, base, in: r))
        return p
    }

    /// Heartbeat across the stone: the process comes back.
    static func pulse(_ r: NSRect) -> NSBezierPath {
        let pts = [(0.31, 0.44), (0.40, 0.44), (0.45, 0.61), (0.52, 0.27), (0.57, 0.50), (0.61, 0.44), (0.69, 0.44)]
        let p = NSBezierPath()
        p.move(to: point(pts[0].0, pts[0].1, in: r))
        for (x, y) in pts.dropFirst() { p.line(to: point(x, y, in: r)) }
        p.lineJoinStyle = .round
        return p
    }

    /// Exclamation mark inside the stone, for the alert.
    static func exclamation(_ r: NSRect) -> NSBezierPath {
        let w = 0.11 * r.width
        let bar = NSRect(origin: point(0.5 - 0.055, 0.40, in: r), size: NSSize(width: w, height: 0.32 * r.height))
        let p = NSBezierPath(roundedRect: bar, xRadius: w / 2, yRadius: w / 2)
        let dot = point(0.5, 0.26, in: r), d = 0.12 * r.width
        p.append(NSBezierPath(ovalIn: NSRect(x: dot.x - d / 2, y: dot.y - d / 2, width: d, height: d)))
        return p
    }

    static func stroke(_ path: NSBezierPath, _ width: CGFloat) {
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }
}

// MARK: - Menu bar images

extension Tombstone {
    /// Calm state: monochrome template, so macOS colours it to match the menu bar.
    static func menuBarImage(size: CGFloat, label: String) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            NSColor.black.set()
            stroke(outline(r), r.width * 0.095)
            stroke(ground(r), r.width * 0.095)
            stroke(pulse(r), r.width * 0.08)
            arrowHead(r).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = label
        return image
    }

    /// Alert state: full colour, never a template, so macOS can't recolour it (a tinted template
    /// is what turned black on dark menu bars). The halo uses the ink colour, so on any background
    /// either the fill or the halo stands out by at least 4.58:1 (see `ink(on:)`).
    static func alertImage(size: CGFloat, colour: NSColor, solid: Bool, count: Int?, label: String) -> NSImage {
        let fill = colour.usingColorSpace(.sRGB) ?? colour
        let ink = ink(on: fill)
        let width = count == nil ? size : size * 1.4
        let image = NSImage(size: NSSize(width: width, height: size), flipped: false) { bounds in
            let r = NSRect(x: 0, y: 0, width: size, height: size)
            let w = r.width * 0.095, halo = r.width * 0.09
            if solid {
                ink.set()
                stroke(stone(r), halo * 2)
                stroke(ground(r), w + halo * 2)
                fill.set()
                stone(r).fill()
                stroke(ground(r), w)
                ink.set()
                exclamation(r).fill()
            } else {
                for (colour, extra) in [(ink, halo * 2), (fill, 0)] {
                    colour.set()
                    stroke(outline(r), w + extra)
                    stroke(ground(r), w + extra)
                    let head = arrowHead(r)
                    head.fill()
                    if extra > 0 { stroke(head, extra) }
                    let mark = exclamation(r)
                    if extra > 0 { stroke(mark, extra) } else { mark.fill() }
                }
            }
            if let count { badge(count, at: NSPoint(x: bounds.maxX - size * 0.27, y: size * 0.72),
                                 radius: size * 0.25, fill: fill, ink: ink, halo: halo) }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = label
        return image
    }

    /// Dock-style count bubble.
    private static func badge(_ count: Int, at c: NSPoint, radius: CGFloat, fill: NSColor, ink: NSColor, halo: CGFloat) {
        func disc(_ r: CGFloat) -> NSBezierPath { NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)) }
        ink.set(); disc(radius + halo).fill()
        fill.set(); disc(radius).fill()
        let text = count > 9 ? "9+" : String(count)
        let font = NSFont.systemFont(ofSize: radius * (count > 9 ? 1.15 : 1.45), weight: .heavy)
        let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: ink])
        let sz = s.size()
        s.draw(at: NSPoint(x: c.x - sz.width / 2, y: c.y - sz.height / 2 + font.descender / 2))
    }
}

// MARK: - Contrast (WCAG 2)

func luminance(_ c: NSColor) -> Double {
    guard let s = c.usingColorSpace(.sRGB) else { return 0 }
    func ch(_ v: CGFloat) -> Double { let v = Double(v); return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    return 0.2126 * ch(s.redComponent) + 0.7152 * ch(s.greenComponent) + 0.0722 * ch(s.blueComponent)
}

func contrast(_ a: NSColor, _ b: NSColor) -> Double {
    let (x, y) = (luminance(a) + 0.05, luminance(b) + 0.05)
    return max(x, y) / min(x, y)
}

/// Black or white, whichever stands out more on `fill`. Because contrast(fill, black) × contrast(fill, white)
/// = 21, the loser is still ≥ √21 ≈ 4.58:1 against the fill — which is what keeps the alert visible on
/// pure black and pure white menu bars alike.
func ink(on fill: NSColor) -> NSColor {
    contrast(fill, .white) >= contrast(fill, .black) ? .white : .black
}

/// How well the alert icon stands out on a menu bar: its best edge, fill or halo.
func alertVisibility(_ fill: NSColor, on bar: NSColor) -> Double {
    max(contrast(fill, bar), contrast(ink(on: fill), bar))
}
