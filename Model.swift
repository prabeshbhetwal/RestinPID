import AppKit
import ServiceManagement
import UserNotifications

struct AppItem: Identifiable {
    let app: NSRunningApplication
    var memory: UInt64 = 0   // RAM, bytes: app + its helper processes
    var cpu: Double?         // % of one core, like Activity Monitor; nil until the second sample
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
    private var lastCPU: [pid_t: (cpuNanos: UInt64, at: UInt64)] = [:]

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
        // Re-check Accessibility the moment the user flips it in System Settings (macOS posts this
        // when the trusted list changes; the value lags slightly), and whenever we come forward.
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            for delay in [0.3, 1.0, 2.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.refreshAccessibility() }
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshAccessibility() }
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
        let targets = all.map { ($0.id, $0.app.bundleURL?.path ?? "/nonexistent") }
        let pids = targets.map(\.0)
        let trusted = AXIsProcessTrusted()
        DispatchQueue.global(qos: .utility).async {
            let status = Dictionary(uniqueKeysWithValues: targets.map { pid, bundle in
                (pid, (usage: treeUsage(pid, bundlePath: bundle), frozen: trusted && isUnresponsive(pid)))
            })
            let now = monotonicNanos()
            DispatchQueue.main.async {
                self.polling = false
                self.accessibilityTrusted = trusted
                self.all = self.all.map { item in
                    var item = item
                    guard let s = status[item.id] else { return item }
                    item.memory = s.usage.memory
                    item.frozen = s.frozen
                    if let last = self.lastCPU[item.id], now > last.at {
                        // ponytail: a helper exiting between samples drops its time; clamp at 0
                        let used = s.usage.cpuNanos > last.cpuNanos ? s.usage.cpuNanos - last.cpuNanos : 0
                        item.cpu = Double(used) / Double(now - last.at) * 100
                    }
                    self.lastCPU[item.id] = (s.usage.cpuNanos, now)
                    return item
                }
                self.lastCPU = self.lastCPU.filter { pid, _ in pids.contains(pid) }
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

    /// Adds AppRestarter to the Accessibility list (first time) and opens that pane.
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        accessibilityTrusted = AXIsProcessTrustedWithOptions(options)
        if !accessibilityTrusted,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func refreshAccessibility() {
        let trusted = AXIsProcessTrusted()
        if trusted != accessibilityTrusted { accessibilityTrusted = trusted }
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

/// Quits and reopens AppRestarter (picks up a newly granted permission).
func relaunchSelf() {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/sh")
    task.arguments = ["-c", "sleep 0.5; /usr/bin/open \"$0\"", Bundle.main.bundleURL.path]
    try? task.run()
    NSApp.terminate(nil)
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

/// RAM (same "Memory" figure as Activity Monitor) and total CPU time for an app plus the
/// helper processes it spawned from inside its own bundle (browser tabs, Electron helpers).
/// Tools it merely launches (shells, node servers) are skipped. ponytail: XPC services
/// launched by launchd aren't children, so they're not counted.
func treeUsage(_ root: pid_t, bundlePath: String) -> (memory: UInt64, cpuNanos: UInt64) {
    var memory: UInt64 = 0, ticks: UInt64 = 0
    var queue = [root], seen = Set<pid_t>()
    let prefix = bundlePath.hasSuffix("/") ? bundlePath : bundlePath + "/"
    while let pid = queue.popLast() {
        guard seen.insert(pid).inserted else { continue }
        queue += childPIDs(pid)
        guard pid == root || executablePath(pid)?.hasPrefix(prefix) == true else { continue }
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        } == 0
        if ok {
            memory += info.ri_phys_footprint
            ticks += info.ri_user_time + info.ri_system_time
        }
    }
    return (memory, ticks * UInt64(timebase.numer) / UInt64(timebase.denom))
}

private func executablePath(_ pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil
}

private func childPIDs(_ pid: pid_t) -> [pid_t] {
    let count = proc_listchildpids(pid, nil, 0)
    guard count > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(count) + 16)
    let found = proc_listchildpids(pid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    return Array(pids.prefix(max(0, Int(found)))).filter { $0 > 0 }
}

/// rusage CPU times are mach ticks (not ns) on Apple silicon.
private let timebase: mach_timebase_info_data_t = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return info
}()

func monotonicNanos() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
}

func formatBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
}

func formatCPU(_ percent: Double) -> String {
    percent < 10 ? String(format: "%.1f%%", percent) : String(format: "%.0f%%", percent)
}
