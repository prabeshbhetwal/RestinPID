import AppKit
import Security
import ServiceManagement
import UserNotifications

/// Dock apps, third-party menu bar / background apps, and apps that ship with macOS.
enum AppKind: Int, Comparable {
    case app, background, system
    static func < (a: AppKind, b: AppKind) -> Bool { a.rawValue < b.rawValue }
}

/// Light, dark, or follow the system.
enum AppearanceMode: String, CaseIterable {
    case system, light, dark
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Where usage totals come from: off, the apps in the list, or the whole Mac (like Activity Monitor).
enum UsageScope: String, CaseIterable {
    case off, listed, system
}

/// When apps that ship with macOS appear in the list.
enum SystemAppsMode: String, CaseIterable {
    case never, whenBusy, always
}

struct AppItem: Identifiable {
    let app: NSRunningApplication
    let kind: AppKind
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
    @Published var appearance: AppearanceMode { didSet { defaults.set(appearance.rawValue, forKey: "appearance") } }
    /// Version found by a background update check, shown as a badge until the user looks at it.
    @Published var availableUpdate: String?
    /// RestinPID's own use, measured by the self-watch (the self-test reads it).
    @Published private(set) var ownMemory: UInt64 = 0
    @Published private(set) var ownCPU: Double?
    @Published var selfHeal: Bool { didSet { defaults.set(selfHeal, forKey: "selfHeal") } }
    @Published var panelTotals: UsageScope { didSet { defaults.set(panelTotals.rawValue, forKey: "panelTotals") } }
    @Published var menuBarUsage: UsageScope { didSet { defaults.set(menuBarUsage.rawValue, forKey: "menuBarUsage") } }
    /// Whole Mac: memory used (app + wired + compressed, Activity Monitor's "Memory Used") and CPU load
    /// as a share of all cores (0–100%).
    @Published private(set) var macMemory: UInt64 = 0
    @Published private(set) var macCPU: Double?
    let macMemoryTotal = ProcessInfo.processInfo.physicalMemory
    private var lastMacTicks: (busy: UInt64, total: UInt64)?
    @Published var showBackground: Bool { didSet { defaults.set(showBackground, forKey: "showBackground") } }
    @Published var systemApps: SystemAppsMode { didSet { defaults.set(systemApps.rawValue, forKey: "systemApps") } }
    /// "High use" limits: macOS apps show above them; everyone's figures turn orange.
    @Published var ramLimitGB: Double { didSet { defaults.set(ramLimitGB, forKey: "ramLimitGB") } }
    @Published var cpuLimit: Double { didSet { defaults.set(cpuLimit, forKey: "cpuLimit") } }
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
                NSLog("RestinPID: launch at login failed: \(error)")
            }
        }
    }

    private var observation: NSKeyValueObservation?
    private var timer: Timer?
    private var polling = false
    private var frozenSince: [pid_t: Date] = [:]
    private var lastCPU: [pid_t: (cpuNanos: UInt64, at: UInt64)] = [:]
    private var highUseAt: [pid_t: Date] = [:]  // last time over a limit; keeps macOS apps from flickering
    private var axAnswered = Set<pid_t>()       // answered an Accessibility ping at least once
    private var axSilent = Set<pid_t>()         // background apps that never answer; not pinged again

    private init() {
        Self.migrateOldSettings()
        excluded = Set(defaults.stringArray(forKey: "excluded") ?? [])
        pinned = Set(defaults.stringArray(forKey: "pinned") ?? [])
        watched = Set(defaults.stringArray(forKey: "watched") ?? [])
        frozenThreshold = defaults.object(forKey: "frozenThreshold") as? Double ?? 15
        confirmActions = defaults.object(forKey: "confirmActions") as? Bool ?? false
        showMemory = defaults.object(forKey: "showMemory") as? Bool ?? true
        appearance = AppearanceMode(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        selfHeal = defaults.object(forKey: "selfHeal") as? Bool ?? true
        panelTotals = UsageScope(rawValue: defaults.string(forKey: "panelTotals") ?? "") ?? .listed
        menuBarUsage = UsageScope(rawValue: defaults.string(forKey: "menuBarUsage") ?? "") ?? .off
        showBackground = defaults.object(forKey: "showBackground") as? Bool ?? true
        systemApps = SystemAppsMode(rawValue: defaults.string(forKey: "systemApps") ?? "") ?? .whenBusy
        ramLimitGB = defaults.object(forKey: "ramLimitGB") as? Double ?? 1
        cpuLimit = defaults.object(forKey: "cpuLimit") as? Double ?? 50
        notify = defaults.object(forKey: "notify") as? Bool ?? true
        if let data = defaults.data(forKey: "hotkey") {
            hotkey = try? JSONDecoder().decode(KeyCombo.self, from: data) // empty Data = user removed it
        } else {
            hotkey = .default
        }
        history = (defaults.data(forKey: "history")).flatMap { try? JSONDecoder().decode([HistoryEntry].self, from: $0) } ?? []
    }

    /// One-time copy of settings from the app's old identity (AppRestarter 2.x).
    private static func migrateOldSettings() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedFromAppRestarter") else { return }
        defaults.set(true, forKey: "migratedFromAppRestarter")
        guard let old = defaults.persistentDomain(forName: "com.prabeshbhetwal.AppRestarter") else { return }
        for key in ["excluded", "pinned", "watched", "frozenThreshold", "confirmActions", "showMemory", "notify", "hotkey", "history"]
        where defaults.object(forKey: key) == nil {
            if let value = old[key] { defaults.set(value, forKey: key) }
        }
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
        if let reason = defaults.string(forKey: "selfRestartReason") { // set just before the self-watch restarted us
            defaults.removeObject(forKey: "selfRestartReason")
            record(.restart, name: "RestinPID", ok: true, automatic: true, note: "RestinPID restarted itself because \(reason).")
        }
        startSelfWatch()
    }

    // MARK: Self-watch

    /// Limits for restarting RestinPID itself. var so the self-test can shorten them.
    var selfLimits = (warmup: 30.0, freeze: 10.0, ram: UInt64(500) << 20, cpu: 50.0, cpuFor: 60.0, cooldown: 600.0)
    /// What happens when a limit trips; the self-test swaps it out.
    var selfRestartAction: (String) -> Void = { reason in
        UserDefaults.standard.set(reason, forKey: "selfRestartReason")
        relaunchSelf(hard: true)
    }

    private let watchQueue = DispatchQueue(label: "RestinPID.selfwatch", qos: .userInitiated)
    private var watchTimer: DispatchSourceTimer?
    // Touched only on watchQueue:
    private var lastBeat = monotonicNanos()
    private var lastOwn: (cpuNanos: UInt64, at: UInt64)?
    private var busySince: UInt64?

    /// Runs on its own queue every 2 s, so a frozen main thread can't stop it. Measures our own RAM and
    /// CPU, and asks the main thread for a heartbeat; restarts RestinPID if the main thread stops
    /// answering, RAM grows past the limit, or CPU stays high (only with the setting on).
    private func startSelfWatch() {
        let started = monotonicNanos()
        let timer = DispatchSource.makeTimerSource(queue: watchQueue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.selfWatchTick(started: started) }
        timer.resume()
        watchTimer = timer
    }

    private func selfWatchTick(started: UInt64) {
        let now = monotonicNanos(), seconds = { (ns: UInt64) in Double(ns) / 1e9 }
        let usage = treeUsage(getpid(), bundlePath: Bundle.main.bundlePath)
        var cpu: Double?
        if let last = lastOwn, now > last.at {
            cpu = Double(usage.cpuNanos > last.cpuNanos ? usage.cpuNanos - last.cpuNanos : 0) / Double(now - last.at) * 100
        }
        lastOwn = (usage.cpuNanos, now)
        busySince = (cpu ?? 0) >= selfLimits.cpu ? (busySince ?? now) : nil

        var reason: String?
        if seconds(now - lastBeat) > selfLimits.freeze {
            reason = "it stopped responding for \(Int(seconds(now - lastBeat))) seconds"
        } else if usage.memory > selfLimits.ram {
            reason = "it was using \(formatBytes(usage.memory)) of RAM"
        } else if let since = busySince, seconds(now - since) > selfLimits.cpuFor {
            reason = "it stayed above \(Int(selfLimits.cpu))% CPU for \(Int(selfLimits.cpuFor)) seconds"
        }
        let enabled = defaults.object(forKey: "selfHeal") as? Bool ?? true
        let lastRestart = defaults.object(forKey: "selfRestartedAt") as? Date ?? .distantPast
        if let reason, enabled, seconds(now - started) > selfLimits.warmup,
           Date().timeIntervalSince(lastRestart) > selfLimits.cooldown { // never loop
            defaults.set(Date(), forKey: "selfRestartedAt")
            lastBeat = now
            selfRestartAction(reason)
            return
        }
        DispatchQueue.main.async {
            self.ownMemory = usage.memory
            self.ownCPU = cpu
            self.watchQueue.async { self.lastBeat = monotonicNanos() } // heartbeat: the main thread got here
        }
    }

    func restartSelf() {
        record(.restart, name: "RestinPID", ok: true, automatic: false, notifyUser: false)
        relaunchSelf()
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
            .filter { isShown($0) && (q.isEmpty || $0.name.localizedCaseInsensitiveContains(q)) }
            .sorted { rank($0) < rank($1) }
    }

    private func rank(_ item: AppItem) -> (Int, Int, String) {
        (pinned.contains(item.bundleID) ? 0 : 1, item.kind.rawValue, item.name.lowercased())
    }

    func isShown(_ item: AppItem) -> Bool {
        if pinned.contains(item.bundleID) { return true }
        switch item.kind {
        case .app: return true
        case .background: return showBackground
        case .system:
            switch systemApps {
            case .never: return false
            case .always: return true
            case .whenBusy: return item.frozen || highUseAt[item.id].map { Date().timeIntervalSince($0) < 15 } == true
            }
        }
    }

    /// The apps the list shows, ignoring the search.
    var listed: [AppItem] { all.filter(isShown) }

    /// Summed RAM and CPU (% of one core, like each row) for some apps.
    func totals(_ items: [AppItem]) -> (memory: UInt64, cpu: Double?) {
        let cpus = items.compactMap(\.cpu)
        return (items.reduce(0) { $0 + $1.memory }, cpus.isEmpty ? nil : cpus.reduce(0, +))
    }

    func isHighRAM(_ item: AppItem) -> Bool { Double(item.memory) >= ramLimitGB * 1_073_741_824 }
    func isHighCPU(_ item: AppItem) -> Bool { (item.cpu ?? 0) >= cpuLimit }

    /// Never listed: killing these logs you out or breaks password prompts.
    private static let neverList: Set<String> = ["com.apple.loginwindow", "com.apple.SecurityAgent"]

    /// nil = not listable: no bundle, this app, a helper inside another app (counted toward
    /// that app), or a command-line tool.
    static func kind(of app: NSRunningApplication) -> AppKind? {
        guard app.processIdentifier != getpid(), !app.isTerminated,
              let id = app.bundleIdentifier, !neverList.contains(id),
              let path = app.bundleURL?.path, path.hasSuffix(".app"),
              !path.dropLast(4).contains(".app/") else { return nil }
        if isApple(app, path: path) { return .system }
        return app.activationPolicy == .regular ? .app : .background
    }

    private static var appleCache: [String: Bool] = [:]

    /// Ships with macOS: under /System, or signed by Apple itself (Safari, for example).
    /// App Store apps are signed differently, so they count as yours.
    private static func isApple(_ app: NSRunningApplication, path: String) -> Bool {
        if path.hasPrefix("/System/") { return true }
        if let known = appleCache[path] { return known }
        var code: SecCode?, requirement: SecRequirement?
        let apple = SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: app.processIdentifier] as CFDictionary, [], &code) == errSecSuccess
            && SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess
            && SecCodeCheckValidity(code!, [], requirement) == errSecSuccess
        appleCache[path] = apple
        return apple
    }

    private func rebuild() {
        let previous = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        all = NSWorkspace.shared.runningApplications.compactMap { app in
            guard !excluded.contains(app.bundleIdentifier ?? ""), let kind = Self.kind(of: app) else { return nil }
            return previous[app.processIdentifier] ?? AppItem(app: app, kind: kind)
        }
        if selection == nil || !visible.contains(where: { $0.id == selection }) { selection = visible.first?.id }
    }

    private func pollStatus() {
        guard !polling else { return }
        polling = true
        let targets = all.map { ($0.id, $0.app.bundleURL?.path ?? "/nonexistent") }
        let pids = Set(targets.map(\.0))
        let trusted = AXIsProcessTrusted()
        let silent = axSilent
        DispatchQueue.global(qos: .utility).async {
            let status = Dictionary(uniqueKeysWithValues: targets.map { pid, bundle in
                (pid, (usage: treeUsage(pid, bundlePath: bundle), ping: trusted && !silent.contains(pid) ? axPing(pid) : nil))
            })
            let now = monotonicNanos()
            let macMemory = systemMemoryUsed(), macTicks = systemCPUTicks()
            DispatchQueue.main.async {
                self.polling = false
                self.accessibilityTrusted = trusted
                self.macMemory = macMemory
                if let last = self.lastMacTicks, macTicks.total > last.total {
                    self.macCPU = Double(macTicks.busy - last.busy) / Double(macTicks.total - last.total) * 100
                }
                self.lastMacTicks = macTicks
                self.all = self.all.map { item in
                    var item = item
                    guard let s = status[item.id] else { return item }
                    item.memory = s.usage.memory
                    if s.ping == true { self.axAnswered.insert(item.id) }
                    // Dock apps always answer Accessibility, so a timeout means frozen. Background apps
                    // count only if they answered before; some never do (an instant error, or no reply).
                    let answers = item.app.activationPolicy == .regular || self.axAnswered.contains(item.id)
                    item.frozen = s.ping == false && answers
                    if !answers, s.ping != true, trusted { self.axSilent.insert(item.id) }
                    if let last = self.lastCPU[item.id], now > last.at {
                        // ponytail: a helper exiting between samples drops its time; clamp at 0
                        let used = s.usage.cpuNanos > last.cpuNanos ? s.usage.cpuNanos - last.cpuNanos : 0
                        item.cpu = Double(used) / Double(now - last.at) * 100
                    }
                    self.lastCPU[item.id] = (s.usage.cpuNanos, now)
                    if self.isHighRAM(item) || self.isHighCPU(item) { self.highUseAt[item.id] = Date() }
                    return item
                }
                self.lastCPU = self.lastCPU.filter { pids.contains($0.key) }
                self.highUseAt = self.highUseAt.filter { pids.contains($0.key) }
                self.axAnswered.formIntersection(pids)
                self.axSilent.formIntersection(pids)
                if self.selection == nil || !self.visible.contains(where: { $0.id == self.selection }) {
                    self.selection = self.visible.first?.id
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

    /// User-triggered. Bulk actions and macOS apps always ask; others ask if the setting is on.
    func perform(_ action: AppAction, on items: [AppItem]) {
        let items = items.filter { !busy.contains($0.id) }
        guard !items.isEmpty else { return }
        let system = items.contains { $0.kind == .system }
        if items.count > 1 || confirmActions || system {
            let alert = NSAlert()
            alert.messageText = items.count > 1 ? "\(action.verb) \(items.count) apps?" : "\(action.verb) \(items[0].name)?"
            alert.informativeText = items.count > 1
                ? items.map(\.name).joined(separator: ", ") + "\n\nUnsaved work in these apps will be lost."
                : system ? "\(items[0].name) is part of macOS. Unsaved work in it will be lost, and macOS may restart it by itself."
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
            let app = item.app, name = item.name, system = item.kind == .system, id = item.bundleID
            DispatchQueue.global(qos: .userInitiated).async {
                var ok = forceKill(app)
                if ok, action == .restart, let url = app.bundleURL { ok = (system && cameBack(id)) || relaunch(url) }
                DispatchQueue.main.async {
                    self.busy.remove(app.processIdentifier)
                    self.record(action, name: name, ok: ok, automatic: automatic)
                }
            }
        }
    }

    private func record(_ action: AppAction, name: String, ok: Bool, automatic: Bool, note: String? = nil, notifyUser: Bool = true) {
        history.insert(HistoryEntry(date: Date(), name: name, action: action.verb, ok: ok, automatic: automatic), at: 0)
        if history.count > 200 { history.removeLast(history.count - 200) }
        defaults.set(try? JSONEncoder().encode(history), forKey: "history")

        guard notify, notifyUser else { return }
        let content = UNMutableNotificationContent()
        content.title = ok ? (action == .restart ? "Restarted \(name)" : "Force quit \(name)")
                           : "Couldn’t \(action.verb.lowercased()) \(name)"
        if automatic { content.body = note ?? "\(name) was not responding for \(Int(frozenThreshold)) seconds." }
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

    /// Adds RestinPID to the Accessibility list (first time) and opens that pane.
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
        if let error { NSLog("RestinPID: relaunch failed: \(error)") }
        done.signal()
    }
    _ = done.wait(timeout: .now() + 15)
    return ok
}

/// Quits and reopens RestinPID. A helper shell waits for this process to exit, then opens the app
/// again. hard = SIGKILL now (safe from any thread, works when the main thread is stuck).
func relaunchSelf(hard: Bool = false) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/sh")
    task.arguments = ["-c", "while kill -0 $1 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
                      Bundle.main.bundleURL.path, String(getpid())]
    try? task.run()
    if hard {
        UserDefaults.standard.synchronize() // about to be killed; flush settings first
        kill(getpid(), SIGKILL)
    } else {
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
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

/// Pings the app's main thread through Accessibility. true = answered; false = no answer
/// within 0.5 s (frozen); nil = refused at once (the app doesn't support Accessibility).
func axPing(_ pid: pid_t) -> Bool? {
    let element = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(element, 0.5)
    var value: CFTypeRef?
    let start = monotonicNanos()
    let result = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
    if result == .success { return true }
    return result == .cannotComplete && monotonicNanos() - start > 400_000_000 ? false : nil
}

/// macOS restarts many of its own apps (Dock, Finder, Control Center) by itself; wait up to 3 s for that.
func cameBack(_ bundleID: String) -> Bool {
    for _ in 0..<30 {
        if !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty { return true }
        usleep(100_000)
    }
    return false
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

/// Activity Monitor's "Memory Used": app memory + wired + compressed.
func systemMemoryUsed() -> UInt64 {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
    let ok = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
    } == KERN_SUCCESS
    guard ok else { return 0 }
    let app = UInt64(stats.internal_page_count) - min(UInt64(stats.purgeable_count), UInt64(stats.internal_page_count))
    return (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * UInt64(vm_kernel_page_size)
}

/// Cumulative CPU ticks across all cores; busy = user + system + nice.
func systemCPUTicks() -> (busy: UInt64, total: UInt64) {
    var info = host_cpu_load_info()
    var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
    let ok = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
    } == KERN_SUCCESS
    guard ok else { return (0, 0) }
    let t = info.cpu_ticks // user, system, idle, nice
    let busy = UInt64(t.0) + UInt64(t.1) + UInt64(t.3)
    return (busy, busy + UInt64(t.2))
}

func formatBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
}

func formatCPU(_ percent: Double) -> String {
    percent < 10 ? String(format: "%.1f%%", percent) : String(format: "%.0f%%", percent)
}
