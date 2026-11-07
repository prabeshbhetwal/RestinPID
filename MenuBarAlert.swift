import AppKit
import Combine

/// How the menu bar icon calls for attention when an app stops responding. Settings → Alerts.
final class AlertSettings: ObservableObject {
    static let shared = AlertSettings()
    static let defaultColour = "E0102A" // crimson: white ink wins on it, so the halo is white on dark menu bars

    private let defaults = UserDefaults.standard
    @Published var colourHex: String { didSet { defaults.set(colourHex, forKey: "alertColour") } }
    @Published var solidBadge: Bool { didSet { defaults.set(solidBadge, forKey: "alertSolid") } }
    @Published var showCount: Bool { didSet { defaults.set(showCount, forKey: "alertCount") } }
    @Published var pulse: Bool { didSet { defaults.set(pulse, forKey: "alertPulse") } }
    @Published var pulseSeconds: Double { didSet { defaults.set(pulseSeconds, forKey: "alertPulseSeconds") } }
    @Published var jiggle: Bool { didSet { defaults.set(jiggle, forKey: "jiggleIcon") } } // key kept from 3.4
    @Published var jiggleStrength: Double { didSet { defaults.set(jiggleStrength, forKey: "alertJiggleStrength") } }
    @Published var jiggleEvery: Double { didSet { defaults.set(jiggleEvery, forKey: "alertJiggleEvery") } }
    @Published var iconSize: Double { didSet { defaults.set(iconSize, forKey: "menuBarIconSize") } }

    /// Shows the alert in the menu bar for a few seconds; wired up by the app delegate.
    var preview: () -> Void = {}

    private init() {
        colourHex = defaults.string(forKey: "alertColour") ?? Self.defaultColour
        solidBadge = defaults.object(forKey: "alertSolid") as? Bool ?? true
        showCount = defaults.object(forKey: "alertCount") as? Bool ?? true
        pulse = defaults.object(forKey: "alertPulse") as? Bool ?? true
        pulseSeconds = defaults.object(forKey: "alertPulseSeconds") as? Double ?? 1.6
        jiggle = defaults.object(forKey: "jiggleIcon") as? Bool ?? true
        jiggleStrength = defaults.object(forKey: "alertJiggleStrength") as? Double ?? 5
        jiggleEvery = defaults.object(forKey: "alertJiggleEvery") as? Double ?? 8
        iconSize = defaults.object(forKey: "menuBarIconSize") as? Double ?? 16
    }

    var colour: NSColor {
        get {
            let v = UInt32(colourHex, radix: 16) ?? 0xE0102A
            return NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255,
                           blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        set {
            guard let c = newValue.usingColorSpace(.sRGB) else { return }
            colourHex = String(format: "%02X%02X%02X", Int((c.redComponent * 255).rounded()),
                               Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
        }
    }

    func resetLook() {
        colourHex = Self.defaultColour
        solidBadge = true; showCount = true; pulse = true; pulseSeconds = 1.6
        jiggle = true; jiggleStrength = 5; jiggleEvery = 8; iconSize = 16
    }

    func alertImage(count: Int) -> NSImage {
        Tombstone.alertImage(size: iconSize, colour: colour, solid: solidBadge, count: showCount ? count : nil,
                             label: count == 1 ? "RestinPID – an app is not responding"
                                 : "RestinPID – \(count) apps are not responding")
    }
}

/// Draws the status item and runs the alert: colour badge + count (always), glow pulse and jiggle
/// (until the panel is opened). With Reduce Motion the glow holds steady and nothing moves.
final class MenuBarIcon {
    private let button: NSStatusBarButton
    private let settings = AlertSettings.shared
    private var frozen = 0, update = false, previewing = false
    private var acknowledged = true
    private var jiggleTimer: Timer?
    private var subscription: AnyCancellable?

    init(button: NSStatusBarButton) {
        self.button = button
        button.wantsLayer = true
        subscription = settings.objectWillChange
            .receive(on: DispatchQueue.main) // read the settings after the change lands
            .sink { [weak self] in self?.refresh(restartMotion: true) }
        refresh(restartMotion: false)
    }

    /// `newlyFrozen`: an app froze since the last call, so call for attention again.
    func show(frozen: Int, update: Bool, newlyFrozen: Bool) {
        self.frozen = frozen
        self.update = update
        if newlyFrozen { acknowledged = false }
        if frozen == 0 { acknowledged = true }
        refresh(restartMotion: newlyFrozen)
    }

    /// The panel was opened: stop moving, keep the badge until the app recovers.
    func acknowledge() {
        acknowledged = true
        refresh(restartMotion: false)
    }

    func preview() {
        previewing = true
        refresh(restartMotion: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            self?.previewing = false
            self?.refresh(restartMotion: false)
        }
    }

    private func refresh(restartMotion: Bool) {
        let count = previewing ? max(frozen, 1) : frozen
        let size = CGFloat(settings.iconSize)
        let calm = Tombstone.menuBarImage(size: size, label: update ? "RestinPID – update available" : "RestinPID")
        button.image = count > 0 ? settings.alertImage(count: count) : update ? badged(calm) : calm
        button.contentTintColor = nil // a tint on the template is what went black; colour lives in the image

        let moving = count > 0 && (previewing || !acknowledged)
        glow(count > 0 ? (moving ? .pulsing : .steady) : .off)
        if moving && settings.jiggle {
            if restartMotion || jiggleTimer == nil { startJiggle() }
        } else {
            jiggleTimer?.invalidate(); jiggleTimer = nil
        }
    }

    private enum Glow { case off, steady, pulsing }

    /// A soft pill of the alert colour behind the icon; it sits under the image, so the icon stays crisp.
    private func glow(_ state: Glow) {
        guard let layer = button.layer else { return }
        layer.removeAnimation(forKey: "glow")
        layer.cornerRadius = 5
        let c = settings.colour
        guard state != .off, settings.pulse else { layer.backgroundColor = nil; return }
        if state == .steady || reduceMotion {
            layer.backgroundColor = c.withAlphaComponent(state == .steady ? 0.22 : 0.4).cgColor
            return
        }
        layer.backgroundColor = nil
        let a = CABasicAnimation(keyPath: "backgroundColor")
        a.fromValue = c.withAlphaComponent(0.05).cgColor
        a.toValue = c.withAlphaComponent(0.6).cgColor
        a.duration = settings.pulseSeconds / 2
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(a, forKey: "glow")
    }

    /// Shake now and every few seconds, like a Dock icon asking for attention.
    private func startJiggle() {
        jiggleTimer?.invalidate()
        shake()
        jiggleTimer = Timer.scheduledTimer(withTimeInterval: settings.jiggleEvery, repeats: true) { [weak self] _ in
            self?.shake()
        }
    }

    private func shake() {
        guard !reduceMotion else { return }
        let s = settings.jiggleStrength
        let anim = CAKeyframeAnimation(keyPath: "transform.translation.x")
        anim.values = [0, -s, s, -s, s, -0.75 * s, 0.75 * s, -0.4 * s, 0.4 * s, 0]
        anim.duration = 0.6
        button.layer?.add(anim, forKey: "jiggle")
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Calm icon with a dot cut into its top-right corner: an update is waiting. Stays a template.
    private func badged(_ base: NSImage) -> NSImage {
        let image = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            let d = rect.width * 0.38
            let dot = NSRect(x: rect.maxX - d, y: rect.maxY - d, width: d, height: d)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = base.accessibilityDescription
        return image
    }
}
