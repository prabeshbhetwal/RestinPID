import AppKit
import Sparkle
import SwiftUI

// MARK: - Popover panel

struct PanelView: View {
    @ObservedObject var model: AppModel
    let openSettings: () -> Void
    let checkForUpdates: () -> Void
    let showAbout: () -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        let items = model.visible
        VStack(spacing: 0) {
            header
            Divider()
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
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Clear search")
                    .accessibilityLabel("Clear search")
            }
            Menu {
                Button("Settings…", action: openSettings).keyboardShortcut(",")
                Button("Check for Updates…", action: checkForUpdates)
                Button("About AppRestarter", action: showAbout)
                Divider()
                Button("Quit AppRestarter") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Settings, updates and more")
            .accessibilityLabel("More options")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func list(_ items: [AppItem]) -> some View {
        let pinned = items.filter { model.pinned.contains($0.bundleID) }
        let others = items.filter { !model.pinned.contains($0.bundleID) }
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !pinned.isEmpty {
                        SectionHeader(title: "Pinned")
                        ForEach(pinned) { AppRow(model: model, item: $0) }
                    }
                    if !others.isEmpty {
                        SectionHeader(title: pinned.isEmpty ? "Running Apps" : "Other Running Apps")
                        ForEach(others) { AppRow(model: model, item: $0) }
                    }
                }
                .padding(6)
            }
            .frame(height: min(CGFloat(items.count) * 46 + (pinned.isEmpty ? 30 : 60), 440))
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
        HStack(spacing: 12) {
            Button { model.perform(.restart, on: items) } label: { Label("Restart All", systemImage: "arrow.clockwise") }
                .help("Restart every app in the list")
            Button { model.perform(.forceQuit, on: items) } label: { Label("Force Quit All", systemImage: "xmark.octagon") }
                .help("Force quit every app in the list")
            Spacer()
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .disabled(items.isEmpty)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
                if model.showMemory, item.memory > 0 {
                    Text(formatBytes(item.memory))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
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
                RowButton(symbol: "arrow.clockwise", label: "Restart") { model.perform(.restart, on: [item]) }
                RowButton(symbol: "xmark.octagon", label: "Force Quit") { model.perform(.forceQuit, on: [item]) }
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

    private var accessibilityText: String {
        var parts = [item.name]
        if model.showMemory, item.memory > 0 { parts.append(formatBytes(item.memory)) }
        if item.frozen { parts.append("Not responding") }
        if isPinned { parts.append("Pinned") }
        if busy { parts.append("Working") }
        return parts.joined(separator: ", ")
    }
}

private struct RowButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 20, height: 20) }
            .buttonStyle(.borderless)
            .help(label)
            .accessibilityLabel(label)
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
                Toggle("Launch AppRestarter at login", isOn: $model.launchAtLogin)
                Toggle("Ask before restarting or force quitting an app", isOn: $model.confirmActions)
                Toggle("Show memory use", isOn: $model.showMemory)
                Toggle("Notify after each restart or force quit", isOn: $model.notify)
                LabeledContent("Open panel shortcut") { HotkeyRecorder(combo: $model.hotkey) }
            } footer: {
                Text("Restart All and Force Quit All always ask first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                        Text("AppRestarter needs Accessibility access to tell when an app is not responding. Without it, the “Not Responding” badge and auto-restart are off.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Grant Access…") { model.requestAccessibility() }
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

struct UpdatesTab: View {
    let updater: SPUUpdater
    @State private var automatic = false

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    var body: some View {
        Form {
            LabeledContent("Current version", value: version)
            Toggle("Automatically check for updates", isOn: $automatic)
                .onChange(of: automatic) { updater.automaticallyChecksForUpdates = $0 }
            LabeledContent("Last checked") {
                Text(updater.lastUpdateCheckDate?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
            }
            HStack {
                Spacer()
                Button("Check for Updates Now") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }
        .formStyle(.grouped)
        .onAppear { automatic = updater.automaticallyChecksForUpdates }
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

private func appURL(_ bundleID: String) -> URL? {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
}

private func appName(_ bundleID: String) -> String {
    appURL(bundleID).map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleID
}

private func appIcon(_ bundleID: String) -> NSImage {
    appURL(bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSWorkspace.shared.icon(for: .application)
}
