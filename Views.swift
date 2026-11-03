import AppKit
import Sparkle
import SwiftUI

// MARK: - Popover panel

struct PanelView: View {
    @ObservedObject var model: AppModel
    let openSettings: () -> Void
    let checkForUpdates: () -> Void
    let showAbout: () -> Void
    let sendFeedback: () -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        let items = model.visible
        VStack(spacing: 0) {
            header
            Divider()
            if let version = model.availableUpdate { updateBanner(version) }
            if items.isEmpty { emptyState } else { list(items) }
            Divider()
            footer(items)
        }
        .frame(width: 360)
        .onAppear { searchFocused = true }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("Search running apps", text: $model.query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .accessibilityLabel("Search running apps")
            if !model.query.isEmpty {
                Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(HoverIconStyle(tint: .primary))
                    .help("Clear search")
                    .accessibilityLabel("Clear search")
            }
            Menu {
                Button("Settings…", action: openSettings).keyboardShortcut(",")
                Button(model.availableUpdate.map { "Update to \($0)…" } ?? "Check for Updates…", action: checkForUpdates)
                Button("Send Feedback…", action: sendFeedback)
                Button("About RestinPID", action: showAbout)
                Divider()
                Button("Quit RestinPID") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .modifier(HoverCircle(tint: .primary))
            .help("Settings, updates and more")
            .accessibilityLabel("More options")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// Shown after a background check finds an update; opens Sparkle's window with the release notes.
    private func updateBanner(_ version: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
                Text("RestinPID \(version) is available").font(.callout.weight(.medium))
                Spacer()
                Button("What’s New…", action: checkForUpdates)
                    .buttonStyle(.link)
                    .help("See what’s new and install the update")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.1))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { checkForUpdates() }
            Divider()
        }
    }

    private func list(_ items: [AppItem]) -> some View {
        let pinned = items.filter { model.pinned.contains($0.bundleID) }
        let others = items.filter { !model.pinned.contains($0.bundleID) }
        let groups: [(String, [AppItem])] = [
            ("Pinned", pinned),
            ("Apps", others.filter { $0.kind == .app }),
            ("Menu Bar & Background", others.filter { $0.kind == .background }),
            (model.systemApps == .whenBusy ? "macOS · Busy or Not Responding" : "macOS", others.filter { $0.kind == .system }),
        ].filter { !$0.1.isEmpty }
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(groups, id: \.0) { title, rows in
                        SectionHeader(title: title)
                        ForEach(rows) { AppRow(model: model, item: $0) }
                    }
                }
                .padding(6)
            }
            .frame(height: min(CGFloat(items.count) * 46 + CGFloat(groups.count) * 30, 520))
            .onChange(of: model.selection) { id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: model.query.isEmpty ? "checkmark.circle" : "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(model.query.isEmpty ? "No apps running" : "No apps match “\(model.query)”")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 140)
    }

    private func footer(_ items: [AppItem]) -> some View {
        let items = items.filter { $0.kind != .system } // never bulk-kill macOS's own apps
        return HStack(spacing: 4) {
            Button { model.perform(.restart, on: items) } label: { Label("Restart All", systemImage: "arrow.clockwise") }
                .buttonStyle(HoverPillStyle(tint: .accentColor))
                .help("Restart every app in the list except macOS apps")
                .disabled(items.isEmpty)
            Button { model.perform(.forceQuit, on: items) } label: { Label("Force Quit All", systemImage: "xmark.octagon") }
                .buttonStyle(HoverPillStyle(tint: .red))
                .help("Force quit every app in the list except macOS apps")
                .disabled(items.isEmpty)
            Spacer()
            Button { NSApp.terminate(nil) } label: { Label("Quit", systemImage: "power") }
                .buttonStyle(HoverPillStyle(tint: .primary))
                .help("Quit RestinPID (⌘Q)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

private struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct AppRow: View {
    @ObservedObject var model: AppModel
    let item: AppItem
    @State private var hovering = false

    private var selected: Bool { model.selection == item.id }
    private var busy: Bool { model.busy.contains(item.id) }
    private var isPinned: Bool { model.pinned.contains(item.bundleID) }
    private var isWatched: Bool { model.watched.contains(item.bundleID) }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: item.icon)
                .resizable()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(item.name).lineLimit(1)
                    if isWatched {
                        Image(systemName: "eye")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("Restarts automatically when frozen")
                    }
                }
                if model.showMemory, item.memory > 0 { usage }
            }
            Spacer(minLength: 4)
            if item.frozen {
                Text("Not Responding")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.red.opacity(0.15)))
            }
            if busy {
                ProgressView().controlSize(.small)
            } else if hovering || selected {
                RowButton(symbol: "arrow.clockwise", label: "Restart", tint: .accentColor) { model.perform(.restart, on: [item]) }
                RowButton(symbol: "xmark.octagon", label: "Force Quit", tint: .red) { model.perform(.forceQuit, on: [item]) }
            } else if isPinned {
                Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(selected ? Color.accentColor.opacity(0.18) : hovering ? Color.primary.opacity(0.06) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside { model.selection = item.id }
        }
        .onTapGesture { model.perform(.restart, on: [item]) }
        .contextMenu {
            Button("Restart") { model.perform(.restart, on: [item]) }
            Button("Force Quit") { model.perform(.forceQuit, on: [item]) }
            Divider()
            Button(isPinned ? "Unpin" : "Pin to Top") { model.togglePin(item.bundleID) }
            Button(isWatched ? "Stop Auto-Restarting When Frozen" : "Auto-Restart When Frozen") { model.toggleWatch(item.bundleID) }
            Button("Exclude from List") { model.excluded.insert(item.bundleID) }
            Divider()
            if let url = item.app.bundleURL {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
        .id(item.id)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Restarts the app")
        .accessibilityAction { model.perform(.restart, on: [item]) }
        .accessibilityAction(named: "Force Quit") { model.perform(.forceQuit, on: [item]) }
        .accessibilityAction(named: isPinned ? "Unpin" : "Pin to Top") { model.togglePin(item.bundleID) }
        .accessibilityAction(named: "Exclude from List") { model.excluded.insert(item.bundleID) }
    }

    /// "RAM 515 MB · CPU 2.3%". Each turns orange above the high-use limit in Settings.
    private var usage: some View {
        HStack(spacing: 6) {
            Text("RAM \(formatBytes(item.memory))").foregroundStyle(model.isHighRAM(item) ? Color.orange : Color.secondary)
            if let cpu = item.cpu {
                Text("·").foregroundStyle(.tertiary)
                Text("CPU \(formatCPU(cpu))").foregroundStyle(model.isHighCPU(item) ? Color.orange : Color.secondary)
            }
        }
        .font(.caption)
        .monospacedDigit()
        .help("RAM: memory used by the app and its helper processes.\nCPU: processor use, where 100% is one full core (same as Activity Monitor).\nOrange: above the high-use limit in Settings → General.")
    }

    private var accessibilityText: String {
        var parts = [item.name]
        if model.showMemory, item.memory > 0 {
            parts.append("RAM \(formatBytes(item.memory))")
            if let cpu = item.cpu { parts.append("CPU \(formatCPU(cpu))") }
        }
        if item.frozen { parts.append("Not responding") }
        if isPinned { parts.append("Pinned") }
        if busy { parts.append("Working") }
        return parts.joined(separator: ", ")
    }
}

private struct RowButton: View {
    let symbol: String
    let label: String
    let tint: Color
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(HoverIconStyle(tint: tint))
            .help(label)
            .accessibilityLabel(label)
    }
}

// MARK: - Hover styles

/// Round icon button: grey at rest; tinted icon on a soft circle when hovered; shrinks when pressed.
struct HoverIconStyle: ButtonStyle {
    var tint: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .modifier(HoverCircle(tint: tint, pressed: configuration.isPressed))
    }
}

struct HoverCircle: ViewModifier {
    var tint: Color
    var pressed = false
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    func body(content: Content) -> some View {
        let active = hovering && enabled
        content
            .foregroundStyle(active ? tint : Color.secondary)
            .frame(width: 26, height: 26)
            .background(Circle().fill(tint.opacity(active ? (pressed ? 0.28 : 0.14) : 0)))
            .scaleEffect(pressed ? 0.88 : 1)
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: active)
            .animation(.easeOut(duration: 0.08), value: pressed)
    }
}

/// Text + icon footer button: tinted capsule on hover.
struct HoverPillStyle: ButtonStyle {
    var tint: Color
    func makeBody(configuration: Configuration) -> some View {
        Pill(configuration: configuration, tint: tint)
    }

    private struct Pill: View {
        let configuration: Configuration
        let tint: Color
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let active = hovering && enabled
            configuration.label
                .font(.callout)
                .foregroundStyle(active ? tint : enabled ? Color.secondary : Color.secondary.opacity(0.5))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(tint.opacity(active ? (configuration.isPressed ? 0.25 : 0.12) : 0)))
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .contentShape(Capsule())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: active)
        }
    }
}

// MARK: - Settings window

/// Native preferences window: toolbar tabs with icons, window title follows the tab.
func makeSettingsController(model: AppModel, updater: SPUUpdater) -> NSTabViewController {
    func tab<V: View>(_ title: String, _ symbol: String, _ view: V) -> NSTabViewItem {
        let hosting = NSHostingController(rootView: view.padding(20).frame(width: 540, height: 420))
        hosting.sizingOptions = .preferredContentSize
        hosting.title = title
        let item = NSTabViewItem(viewController: hosting)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }
    let controller = NSTabViewController()
    controller.tabStyle = .toolbar
    controller.tabViewItems = [
        tab("General", "gearshape", GeneralTab(model: model)),
        tab("Excluded", "eye.slash", ExcludedTab(model: model)),
        tab("Auto-Restart", "bolt.heart", AutoRestartTab(model: model)),
        tab("History", "clock.arrow.circlepath", HistoryTab(model: model)),
        tab("Updates", "arrow.down.circle", UpdatesTab(updater: updater)),
    ]
    return controller
}

struct ExcludedTab: View {
    @ObservedObject var model: AppModel
    var body: some View {
        AppListTab(
            model: model, apps: $model.excluded,
            caption: "Excluded apps never appear in the list and are skipped by Restart All and Force Quit All."
        )
    }
}

struct GeneralTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $model.appearance) {
                    Text("System").tag(AppearanceMode.system)
                    Text("Light").tag(AppearanceMode.light)
                    Text("Dark").tag(AppearanceMode.dark)
                }
                .pickerStyle(.segmented)
                Toggle("Launch RestinPID at login", isOn: $model.launchAtLogin)
                Toggle("Ask before restarting or force quitting an app", isOn: $model.confirmActions)
                Toggle("Show RAM and CPU use", isOn: $model.showMemory)
                Toggle("Notify after each restart or force quit", isOn: $model.notify)
                LabeledContent("Open panel shortcut") { HotkeyRecorder(combo: $model.hotkey) }
            } footer: {
                Text("Restart All, Force Quit All and actions on macOS apps always ask first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Show menu bar and background apps", isOn: $model.showBackground)
                Picker("Show macOS apps", selection: $model.systemApps) {
                    Text("Never").tag(SystemAppsMode.never)
                    Text("When busy or not responding").tag(SystemAppsMode.whenBusy)
                    Text("Always").tag(SystemAppsMode.always)
                }
                Stepper(value: $model.ramLimitGB, in: 0.25...32, step: 0.25) {
                    Text("Busy when RAM is over **\(model.ramLimitGB.formatted(.number.precision(.fractionLength(0...2)))) GB**")
                }
                Stepper(value: $model.cpuLimit, in: 10...800, step: 10) {
                    Text("or CPU is over **\(Int(model.cpuLimit))%**")
                }
            } header: {
                Text("Apps in the list")
            } footer: {
                Text("Apps that came with macOS (Finder, Dock, Spotlight…) stay hidden until they pass a limit or stop responding. Pin one to always show it. Figures over a limit turn orange for every app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Keyboard (in the panel)") {
                ShortcutRow(keys: "↑ ↓", action: "Move selection")
                ShortcutRow(keys: "↩", action: "Restart selected app")
                ShortcutRow(keys: "⌘↩  or  ⌘⌫", action: "Force quit selected app")
                ShortcutRow(keys: "⌘P", action: "Pin or unpin selected app")
                ShortcutRow(keys: "Esc", action: "Clear search, then close")
                ShortcutRow(keys: "⌘,", action: "Settings")
            }
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutRow: View {
    let keys: String
    let action: String
    var body: some View {
        LabeledContent(action) {
            Text(keys).font(.system(.body, design: .rounded)).foregroundStyle(.secondary)
        }
    }
}

/// Editable list of bundle IDs (used for Excluded and Auto-Restart).
private struct AppListTab: View {
    @ObservedObject var model: AppModel
    @Binding var apps: Set<String>
    let caption: String
    @State private var selection = Set<String>()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(caption).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List(selection: $selection) {
                ForEach(apps.sorted { appName($0).lowercased() < appName($1).lowercased() }, id: \.self) { id in
                    HStack(spacing: 8) {
                        Image(nsImage: appIcon(id)).resizable().frame(width: 20, height: 20)
                        Text(appName(id))
                        Spacer()
                        Text(id).font(.caption).foregroundStyle(.tertiary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .overlay {
                if apps.isEmpty { Text("No apps").foregroundStyle(.secondary) }
            }
            HStack(spacing: 4) {
                Menu {
                    let running = AppModel.shared.all.filter { !apps.contains($0.bundleID) }
                    if !running.isEmpty {
                        Section("Running Apps") {
                            ForEach(running.sorted { $0.name < $1.name }) { item in
                                Button(item.name) { apps.insert(item.bundleID) }
                            }
                        }
                    }
                    Button("Choose from Applications Folder…") { chooseApps() }
                } label: {
                    Image(systemName: "plus")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Add app")
                Button {
                    apps.subtract(selection)
                    selection.removeAll()
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selection.isEmpty)
                .accessibilityLabel("Remove selected apps")
                .keyboardShortcut(.delete, modifiers: [])
            }
        }
    }

    private func chooseApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier { apps.insert(id) }
        }
    }
}

struct AutoRestartTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.accessibilityTrusted {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Accessibility access needed").font(.headline)
                        Text("RestinPID needs Accessibility access to tell when an app is not responding. Without it, the “Not Responding” badge and auto-restart are off.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Already switched on? Turn RestinPID off and on again in that list, or restart RestinPID.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Open Accessibility Settings…") { model.requestAccessibility() }
                            Button("Restart RestinPID") { relaunchSelf() }
                        }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.yellow.opacity(0.1)))
            }
            Stepper(value: $model.frozenThreshold, in: 5...300, step: 5) {
                Text("Restart after an app is not responding for **\(Int(model.frozenThreshold)) seconds**")
            }
            AppListTab(
                model: model, apps: $model.watched,
                caption: "These apps restart automatically when they stop responding."
            )
        }
    }
}

struct HistoryTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Table(model.history) {
                TableColumn("Time") { Text($0.date.formatted(date: .abbreviated, time: .standard)) }
                    .width(min: 150)
                TableColumn("App", value: \.name)
                TableColumn("Action") { Text($0.automatic ? "\($0.action) (auto)" : $0.action) }
                TableColumn("Result") { entry in
                    Label(entry.ok ? "Done" : "Failed", systemImage: entry.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(entry.ok ? .green : .red)
                }
                .width(70)
            }
            .overlay {
                if model.history.isEmpty { Text("No restarts yet").foregroundStyle(.secondary) }
            }
            HStack {
                Text("\(model.history.count) entries (last 200 kept)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear History") { model.clearHistory() }.disabled(model.history.isEmpty)
            }
        }
    }
}

/// How often Sparkle checks. Sparkle's interval is in seconds; Never turns scheduled checks off.
enum UpdateFrequency: Double, CaseIterable {
    case daily = 86_400, weekly = 604_800, fortnightly = 1_209_600, monthly = 2_592_000, never = 0
    var title: String {
        switch self {
        case .daily: return "Every day"
        case .weekly: return "Every week"
        case .fortnightly: return "Every two weeks"
        case .monthly: return "Every month"
        case .never: return "Never"
        }
    }
    static func current(_ updater: SPUUpdater) -> UpdateFrequency {
        guard updater.automaticallyChecksForUpdates else { return .never }
        return allCases.filter { $0 != .never }.min { abs($0.rawValue - updater.updateCheckInterval) < abs($1.rawValue - updater.updateCheckInterval) } ?? .daily
    }
}

struct UpdatesTab: View {
    let updater: SPUUpdater
    @ObservedObject var model = AppModel.shared
    @State private var frequency = UpdateFrequency.daily
    @State private var autoInstall = false

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    var body: some View {
        Form {
            LabeledContent("Current version", value: version)
            Picker("Check for updates", selection: $frequency) {
                ForEach(UpdateFrequency.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .onChange(of: frequency) { new in
                updater.automaticallyChecksForUpdates = new != .never
                if new != .never { updater.updateCheckInterval = new.rawValue }
            }
            Toggle("Download and install updates automatically", isOn: $autoInstall)
                .onChange(of: autoInstall) { updater.automaticallyDownloadsUpdates = $0 }
                .disabled(frequency == .never)
            if let version = model.availableUpdate {
                LabeledContent("Available") {
                    Text("RestinPID \(version)").foregroundStyle(Color.accentColor)
                }
            }
            LabeledContent("Last checked") {
                Text(updater.lastUpdateCheckDate?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
            }
            HStack {
                Spacer()
                Button(model.availableUpdate == nil ? "Check for Updates Now" : "See What’s New…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            Text("When a check finds an update, a dot appears on the menu bar icon and a banner at the top of the panel. Click either to read what’s new before installing.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
        .onAppear {
            frequency = .current(updater)
            autoInstall = updater.automaticallyDownloadsUpdates
        }
    }
}

// MARK: - Hotkey recorder

private struct HotkeyRecorder: View {
    @Binding var combo: KeyCombo?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 4) {
            Button(recording ? "Type shortcut…" : (combo?.display ?? "Click to set")) {
                recording ? stop() : start()
            }
            .frame(minWidth: 120)
            .accessibilityHint(recording ? "Press a key combination with Control, Option or Command. Escape cancels." : "Records a new shortcut")
            if combo != nil, !recording {
                Button { combo = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Remove shortcut")
                    .accessibilityLabel("Remove shortcut")
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        Hotkey.shared.unregister() // so the current shortcut can be re-recorded
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil } // Esc cancels
            guard let new = KeyCombo(event: event) else { NSSound.beep(); return nil }
            combo = new
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording, let combo { Hotkey.shared.register(combo) }
        recording = false
    }
}

// MARK: - Helpers
/// SF Symbol with a dot cut into its top-right corner; stays a template so it matches the menu bar.
func badgedSymbol(_ name: String, label: String) -> NSImage? {
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: label) else { return nil }
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
    image.accessibilityDescription = label
    return image
}


private func appURL(_ bundleID: String) -> URL? {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
}

private func appName(_ bundleID: String) -> String {
    appURL(bundleID).map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleID
}

private func appIcon(_ bundleID: String) -> NSImage {
    appURL(bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSWorkspace.shared.icon(for: .application)
}

// MARK: - Feedback

let repoURL = "https://github.com/prabeshbhetwal/RestinPID"

/// Collects a bug report or idea, then opens a pre-filled GitHub issue (forms in .github/ISSUE_TEMPLATE).
/// ponytail: no backend; GitHub Issues is the inbox. Add an email/web endpoint if non-GitHub users need one.
struct FeedbackView: View {
    enum Kind: String, CaseIterable { case bug = "Report a Problem", idea = "Suggest a Feature" }
    @State private var kind = Kind.bug
    @State private var title = ""
    @State private var details = ""
    @State private var includeSystem = true

    var body: some View {
        Form {
            Picker("Type", selection: $kind) {
                ForEach(Kind.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            TextField("Title", text: $title, prompt: Text("One-line summary"))
            VStack(alignment: .leading, spacing: 4) {
                Text(kind == .bug ? "What happened, and what did you expect?" : "What would you like, and why?")
                    .font(.callout)
                TextEditor(text: $details)
                    .font(.body)
                    .frame(minHeight: 140)
                    .accessibilityLabel("Details")
            }
            Toggle(isOn: $includeSystem) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Include app and Mac versions")
                    Text(systemInfo).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Link("See existing reports", destination: URL(string: "\(repoURL)/issues")!)
                    .font(.callout)
                Spacer()
                Button("Continue on GitHub…", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Opens a pre-filled issue in your browser; nothing is sent until you submit it there. Needs a free GitHub account.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
        .frame(width: 480)
    }

    private var systemInfo: String {
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        #if arch(arm64)
        let chip = "Apple silicon"
        #else
        let chip = "Intel"
        #endif
        return "RestinPID \(version) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString) · \(chip)"
    }

    private func submit() {
        var components = URLComponents(string: "\(repoURL)/issues/new")!
        components.queryItems = [
            URLQueryItem(name: "template", value: kind == .bug ? "bug.yml" : "idea.yml"),
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "details", value: details), // field ids in the issue forms
        ] + (includeSystem ? [URLQueryItem(name: "system", value: systemInfo)] : [])
        if let url = components.url { NSWorkspace.shared.open(url) }
        NSApp.keyWindow?.close()
    }
}
