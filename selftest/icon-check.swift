// Icon check: renders the menu bar icons onto black, grey and white bars, measures what actually lands
// on screen, and writes a contact sheet. Run (see DEVELOPING.md):
//   xcrun swiftc -parse-as-library Icon.swift MenuBarAlert.swift selftest/icon-check.swift -o /tmp/icon-check && /tmp/icon-check <out-dir>
import AppKit

@main enum IconCheck {
    static var failed = false
    static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print(ok ? "PASS" : "FAIL", name, detail)
        if !ok { failed = true }
    }

    /// Draws `image` on a bar of `bar` colour (template images get the bar's text colour, like macOS does).
    static func onBar(_ image: NSImage, _ bar: NSColor, scale: CGFloat = 2) -> NSBitmapImageRep {
        let w = Int((image.size.width + 12) * scale), h = Int(24 * scale)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        bar.setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill()
        let r = NSRect(x: 6 * scale, y: (CGFloat(h) - image.size.height * scale) / 2,
                       width: image.size.width * scale, height: image.size.height * scale)
        if image.isTemplate {
            let tinted = NSImage(size: image.size, flipped: false) { rect in
                image.draw(in: rect); ink(on: bar).set(); rect.fill(using: .sourceAtop); return true
            }
            tinted.draw(in: r)
        } else {
            image.draw(in: r)
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// Share of icon-area pixels that differ from the bar by at least 3:1 contrast (WCAG non-text minimum).
    static func visibleShare(_ rep: NSBitmapImageRep, bar: NSColor) -> Double {
        var hits = 0, total = 0
        for x in 0..<rep.pixelsWide { for y in 0..<rep.pixelsHigh {
            guard let c = rep.colorAt(x: x, y: y) else { continue }
            total += 1
            if contrast(c, bar) >= 3 { hits += 1 }
        } }
        return Double(hits) / Double(max(total, 1))
    }

    static func main() {
        let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory()
        let bars: [(String, NSColor)] = [("black", .black), ("grey", NSColor(white: 0.5, alpha: 1)), ("white", .white),
                                         ("dark wallpaper", NSColor(srgbRed: 0.1, green: 0.1, blue: 0.18, alpha: 1))]
        let colours: [(String, NSColor)] = [("default crimson", AlertSettings.shared.colour),
            ("systemRed", NSColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1)),
            ("navy", NSColor(srgbRed: 0.05, green: 0.1, blue: 0.35, alpha: 1)),
            ("yellow", NSColor(srgbRed: 1, green: 0.85, blue: 0.1, alpha: 1)),
            ("black", .black), ("white", .white)]

        // 1. The fix: calm icon is a template (macOS colours it), alert icon is not (nothing can turn it black).
        let calm = Tombstone.menuBarImage(size: 16, label: "x")
        let alert = AlertSettings.shared.alertImage(count: 1)
        check("calm icon is a template", calm.isTemplate)
        check("alert icon is full colour, not a template", !alert.isTemplate)

        // 2. Contrast maths: for any alert colour, fill or halo stands out ≥ 4.5:1 on pure black and pure white.
        for (name, c) in colours {
            let b = alertVisibility(c, on: .black), w = alertVisibility(c, on: .white)
            check("contrast \(name)", b >= 4.5 && w >= 4.5, String(format: "black %.2f:1, white %.2f:1", b, w))
        }

        // 3. Rendered pixels: every style, size and colour leaves a clearly visible mark on every bar.
        var sheet: [[NSBitmapImageRep]] = []
        var worst = 1.0
        for (cname, c) in colours {
            for solid in [true, false] { for size in [14.0, 16, 22] {
                let img = Tombstone.alertImage(size: size, colour: c, solid: solid, count: 3, label: "x")
                var row: [NSBitmapImageRep] = []
                for (bname, bar) in bars {
                    let rep = onBar(img, bar)
                    let share = visibleShare(rep, bar: bar)
                    worst = min(worst, share)
                    if share < 0.08 { check("visible: \(cname) \(solid ? "solid" : "outline") \(Int(size))pt on \(bname)", false,
                                            String(format: "%.0f%% of pixels stand out", share * 100)) }
                    row.append(rep)
                }
                if size == 16 { sheet.append(row) }
            } }
        }
        check("rendered alert visible on black, grey, white, dark wallpaper (6 colours × 2 styles × 14/16/22 pt)", !failed,
              String(format: "worst case: %.0f%% of the bar area stands out ≥ 3:1", worst * 100))

        // Contact sheet: calm row, then each colour × style at 16 pt, on the four bars.
        sheet.insert(bars.map { onBar(calm, $0.1) }, at: 0)
        let cw = sheet.flatMap { $0 }.map(\.pixelsWide).max()!, ch = 48, gap = 8
        let w = bars.count * (cw + gap), h = sheet.count * (ch + gap)
        let canvas = NSImage(size: NSSize(width: w, height: h), flipped: true) { _ in
            NSColor(white: 0.85, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill()
            for (i, row) in sheet.enumerated() { for (j, rep) in row.enumerated() {
                rep.draw(in: NSRect(x: j * (cw + gap), y: i * (ch + gap), width: rep.pixelsWide, height: rep.pixelsHigh),
                         from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } }
            return true
        }
        let png = NSBitmapImageRep(data: canvas.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        try? png.write(to: URL(fileURLWithPath: "\(out)/menu-bar-icons.png"))
        print("sheet:", "\(out)/menu-bar-icons.png")
        exit(failed ? 1 : 0)
    }
}
