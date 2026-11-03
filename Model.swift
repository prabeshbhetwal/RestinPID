import AppKit
import ServiceManagement
import UserNotifications

struct AppItem: Identifiable {
    let app: NSRunningApplication
    var memory: UInt64 = 0
    var frozen = false

    var id: pid_t { app.processIdentifier }
    var bundleID: String { app.bundleIdentifier ?? "" }
    var name: String { app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "Unknown" }
    var icon: NSImage { app.icon ?? NSWorkspace.shared.icon(for: .application) }
}

enum AppAction {
    case restart, forceQuit
    var verb: String { self == .restart ? "Restart" : "Force Quit" }
}

struct HistoryEntry: Codable, Identifiable {
    var id = UUID()
    let date: Date
    let name: String
    let action: String
    let ok: Bool
    let automatic: Bool
}

final class AppModel: ObservableObject {
    static let shared = AppModel()
    private let defaults = UserDefaults.standard

    // Live state
    @Published private(set) var all: [AppItem] = []
    @Published private(set) var busy: Set<pid_t> = []
    @Published private(set) var accessibilityTrusted = AXIsProcessTrusted()
    @Published var query = "" { didSet { selection = visible.first?.id } }
    @Published var selection: pid_t?

    // Settings (persisted)
    @Published var excluded: Set<String> { didSet { saveSet(excluded, "excluded"); rebuild() } }
    @Published var pinned: Set<String> { didSet { saveSet(pinned, "pinned") } }
    @Published var watched: Set<String> { didSet { saveSet(watched, "watched") } }
    @Published var frozenThreshold: Double { didSet { defaults.set(frozenThreshold, forKey: "frozenThreshold") } }
    @Published var confirmActions: Bool { didSet { defaults.set(confirmActions, forKey: "confirmActions") } }
    @Published var showMemory: Bool { didSet { defaults.set(showMemory, forKey: "showMemory") } }
    @Published var notify: Bool {
        didSet {
            defaults.set(notify, forKey: "notify")
            if notify { requestNotificationPermission() }
        }
    }
    @Published var hotkey: KeyCombo? {
        didSet { defaults.set(hotkey.flatMap { try? JSONEncoder().encode($0) } ?? Data(), forKey: "hotkey") }
    }
    @Published private(set) var history: [HistoryEntry]

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("AppRestarter: launch at login failed: \(error)")
            }
        }
    }

    private var observation: NSKeyValueObservation?
    private var timer: Timer?
    private var polling = false
    private var frozenSince: [pid_t: Date] = [:]

    private init() {
        excluded = Set(defaults.stringArray(forKey: "excluded") ?? [])
        pinned = Set(defaults.stringArray(forKey: "pinned") ?? [])
        watched = Set(defaults.stringArray(forKey: "watched") ?? [])
        frozenThreshold = defaults.object(forKey: "frozenThreshold") as? Double ?? 15
        confirmActions = defaults.object(forKey: "confirmActions") as? Bool ?? false
        showMemory = defaults.object(forKey: "showMemory") as? Bool ?? true
        notify = defaults.object(forKey: "notify") as? Bool ?? true
        if let data = defaults.data(forKey: "hotkey") {
            hotkey = try? JSONDecoder().decode(KeyCombo.self, from: data) // empty Data = user removed it
        } else {
            hotkey = .default
        }
        history = (defaults.data(forKey: "history")).flatMap { try? JSONDecoder().decode([HistoryEntry].self, from: $0) } ?? []
    }

    func start() {
        observation = NSWorkspace.shared.observe(\.runningApplications, options: [.initial]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.rebuild() }
        }
        // Memory + frozen state + watchdog. ponytail: fixed 3 s poll; event-driven would need private APIs.
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.pollStatus() }
        if notify { requestNotificationPermission() }
    }

    func prepareForDisplay() {
        query = ""
        selection = visible.first?.id
        pollStatus()
    }

    // MARK: List

    var visible: [AppItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return all
            .filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) }
            .sorted { (pinned.contains($0.bundleID) ? 0 : 1, $0.name.lowercased()) < (pinned.contains($1.bundleID) ? 0 : 1, $1.name.lowercased()) }
    }

    /// User-installed, regular (Dock) apps: not under /System, not this app, not excluded.
    static func isUserApp(_ app: NSRunningApplication) -> Bool {
        guard app.activationPolicy == .regular,
              app.processIdentifier != getpid(),
              app.bundleIdentifier != nil,
              let path = app.bundleURL?.path else { return false }
        return !path.hasPrefix("/System/")
    }

    private func rebuild() {
        let previous = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        all = NSWorkspace.shared.runningApplications
            .filter { Self.isUserApp($0) && !excluded.contains($0.bundleIdentifier ?? "") && !$0.isTerminated }
            .map { previous[$0.processIdentifier] ?? AppItem(app: $0) }
        if selection == nil || !visible.contains(where: { $0.id == selection }) { selection = visible.first?.id }
    }

    private func pollStatus() {
        guard !polling else { return }
        polling = true
        let pids = all.map(\.id)
        let trusted = AXIsProcessTrusted()
        DispatchQueue.global(qos: .utility).async {
            let status = Dictionary(uniqueKeysWithValues: pids.map { pid in
                (pid, (memory: memoryFootprint(pid), frozen: trusted && isUnresponsive(pid)))
            })
            DispatchQueue.main.async {
                self.polling = false
                self.accessibilityTrusted = trusted
                self.all = self.all.map { item in
                    var item = item
                    if let s = status[item.id] { item.memory = s.memory; item.frozen = s.frozen }
                    return item
                }
                self.runWatchdog()
            }
        }
    }

    private func runWatchdog() {
        let now = Date()
        for item in all {
            guard item.frozen else { frozenSince[item.id] = nil; continue }
            let since = frozenSince[item.id] ?? now
            frozenSince[item.id] = since
            if watched.contains(item.bundleID), now.timeIntervalSince(since) >= frozenThreshold, !busy.contains(item.id) {
                run(.restart, on: [item], automatic: true)
            }
        }
    }

    // MARK: Actions

    /// User-triggered. Bulk actions always ask; single ones ask if the setting is on.
    func perform(_ action: AppAction, on items: [AppItem]) {
        let items = items.filter { !busy.contains($0.id) }
        guard !items.isEmpty else { return }
        if items.count > 1 || confirmActions {
            let alert = NSAlert()
            alert.messageText = items.count > 1 ? "\(action.verb) \(items.count) apps?" : "\(action.verb) \(items[0].name)?"
            alert.informativeText = items.count > 1
                ? items.map(\.name).joined(separator: ", ") + "\n\nUnsaved work in these apps will be lost."
                : "Unsaved work in this app will be lost."
            alert.alertStyle = .warning
            alert.addButton(withTitle: action.verb)
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        run(action, on: items, automatic: false)
    }

    private func run(_ action: AppAction, on items: [AppItem], automatic: Bool) {
        for item in items {
            busy.insert(item.id)
            let app = item.app, name = item.name
            DispatchQueue.global(qos: .userInitiated).async {
                var ok = forceKill(app)
                if ok, action == .restart, let url = app.bundleURL { ok = relaunch(url) }
                DispatchQueue.main.async {
                    self.busy.remove(app.processIdentifier)
                    self.record(action, name: name, ok: ok, automatic: automatic)
                }
            }
        }
    }

    private func record(_ action: AppAction, name: String, ok: Bool, automatic: Bool) {
        history.insert(HistoryEntry(date: Date(), name: name, action: action.verb, ok: ok, automatic: automatic), at: 0)
        if history.count > 200 { history.removeLast(history.count - 200) }
        defaults.set(try? JSONEncoder().encode(history), forKey: "history")

        guard notify else { return }
        let content = UNMutableNotificationContent()
        content.title = ok ? (action == .restart ? "Restarted \(name)" : "Force quit \(name)")
                           : "Couldn’t \(action.verb.lowercased()) \(name)"
        if automatic { content.body = "\(name) was not responding for \(Int(frozenThreshold)) seconds." }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func clearHistory() {
        history = []
        defaults.removeObject(forKey: "history")
    }

    // MARK: Keyboard (popover)

    /// ↑↓ select · ↩ restart · ⌘↩ / ⌘⌫ force quit · ⌘P pin.
    func handleKey(_ event: NSEvent) -> Bool {
        let items = visible
        let cmd = event.modifierFlags.contains(.command)
        let index = items.firstIndex { $0.id == selection }
        let current = index.map { items[$0] }
        switch Int(event.keyCode) {
        case 125: // down
            if !items.isEmpty { selection = items[min((index ?? -1) + 1, items.count - 1)].id }
        case 126: // up
            if !items.isEmpty { selection = items[max((index ?? items.count) - 1, 0)].id }
        case 36, 76: // return
            if let current { perform(cmd ? .forceQuit : .restart, on: [current]) }
        case 51 where cmd: // ⌘⌫
            if let current { perform(.forceQuit, on: [current]) }
        case 35 where cmd: // ⌘P
            if let current { togglePin(current.bundleID) }
        default:
            return false
        }
        return true
    }

    func togglePin(_ id: String) {
        if pinned.contains(id) { pinned.remove(id) } else { pinned.insert(id) }
    }

    func toggleWatch(_ id: String) {
        if watched.contains(id) { watched.remove(id) } else { watched.insert(id) }
    }

    // MARK: Permissions

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        accessibilityTrusted = AXIsProcessTrustedWithOptions(options)
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func saveSet(_ set: Set<String>, _ key: String) {
        defaults.set(set.sorted(), forKey: key)
    }
}

// MARK: - Process helpers

/// Force terminate, then SIGKILL (cannot be ignored, works on frozen apps), then admin kill if owned by another user.
func forceKill(_ app: NSRunningApplication) -> Bool {
    let pid = app.processIdentifier
    app.forceTerminate()
    if kill(pid, SIGKILL) != 0 && errno == EPERM { adminKill(pid) }
    for _ in 0..<50 where isAlive(pid) { usleep(100_000) } // up to 5 s
    return !isAlive(pid)
}

func relaunch(_ url: URL) -> Bool {
    usleep(300_000) // let LaunchServices notice the old process is gone
    let done = DispatchSemaphore(value: 0)
    var ok = false
    let config = NSWorkspace.OpenConfiguration()
    config.activates = true
    NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
        ok = app != nil
        if let error { NSLog("AppRestarter: relaunch failed: \(error)") }
        done.signal()
    }
    _ = done.wait(timeout: .now() + 15)
    return ok
}

func isAlive(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
}

func adminKill(_ pid: pid_t) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    task.arguments = ["-e", "do shell script \"kill -9 \(pid)\" with administrator privileges"]
    try? task.run()
    task.waitUntilExit()
}

/// Pings the app's main thread through Accessibility; a frozen app can't answer within 0.5 s.
func isUnresponsive(_ pid: pid_t) -> Bool {
    let element = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(element, 0.5)
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .cannotComplete
}

/// Physical memory of the main process. ponytail: helper processes (Electron, browsers) not summed.
func memoryFootprint(_ pid: pid_t) -> UInt64 {
    var info = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    return result == 0 ? info.ri_phys_footprint : 0
}

func formatBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
}
