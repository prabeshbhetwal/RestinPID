import SwiftUI

/// Settings → Alerts: how the menu bar icon calls for attention when an app stops responding.
struct AlertsTab: View {
    @ObservedObject var settings: AlertSettings

    private var colour: Binding<Color> {
        Binding(get: { Color(nsColor: settings.colour) }, set: { settings.colour = NSColor($0) })
    }

    var body: some View {
        Form {
            Section {
                IconPreview(settings: settings)
                HStack {
                    Button("Preview in the Menu Bar") { settings.preview() }
                    Spacer()
                    Button("Reset to Defaults") { settings.resetLook() }
                }
            } header: {
                Text("When an app stops responding")
            } footer: {
                Text("The badge and count stay until the app recovers. The glow pulses and the icon shakes until you open the panel. With Reduce Motion on in System Settings, the glow holds steady and nothing moves. The number under each preview is the alert’s contrast on that menu bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Badge") {
                ColorPicker("Colour", selection: colour, supportsOpacity: false)
                Toggle("Solid badge (filled tombstone)", isOn: $settings.solidBadge)
                Toggle("Show how many apps aren’t responding", isOn: $settings.showCount)
                LimitSlider(title: "Icon size", value: $settings.iconSize, range: 14...22, step: 1,
                            low: "Small", high: "Large") { "\(Int($0)) pt" }
            }
            Section("Glow") {
                Toggle("Pulse a glow behind the icon", isOn: $settings.pulse)
                LimitSlider(title: "One pulse every", value: $settings.pulseSeconds, range: 0.6...3, step: 0.2,
                            low: "Fast", high: "Slow") { String(format: "%.1f s", $0) }
                    .disabled(!settings.pulse)
            }
            Section("Jiggle") {
                Toggle("Shake the icon, like a Dock icon asking for attention", isOn: $settings.jiggle)
                Group {
                    LimitSlider(title: "Strength", value: $settings.jiggleStrength, range: 2...10, step: 1,
                                low: "Gentle", high: "Strong") { "\(Int($0)) pt" }
                    LimitSlider(title: "Repeat every", value: $settings.jiggleEvery, range: 3...30, step: 1,
                                low: "3 s", high: "30 s") { "\(Int($0)) s" }
                }
                .disabled(!settings.jiggle)
            }
        }
        .formStyle(.grouped)
    }
}

/// Calm and alert icons on black, grey and white menu bars, each with the alert's contrast there.
private struct IconPreview: View {
    @ObservedObject var settings: AlertSettings
    private let bars: [(name: String, colour: NSColor)] = [
        ("Black", .black), ("Grey", NSColor(white: 0.5, alpha: 1)), ("White", .white),
    ]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(bars, id: \.name) { bar in
                VStack(spacing: 4) {
                    HStack(spacing: 10) {
                        Image(nsImage: Tombstone.menuBarImage(size: settings.iconSize, label: "Calm"))
                            .renderingMode(.template)
                            .foregroundStyle(Color(nsColor: ink(on: bar.colour))) // menu bar text colour
                        Image(nsImage: settings.alertImage(count: 2))
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Color(nsColor: bar.colour), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                    Text("\(bar.name) · " + String(format: "%.1f:1", alertVisibility(settings.colour, on: bar.colour)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of the menu bar icon on black, grey and white menu bars")
    }
}
