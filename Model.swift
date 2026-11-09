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

/// How the RAM and CPU limits combine into "busy".
enum BusyMatch: String, CaseIterable {
    case either, both // either limit passed / both passed at once
}

/// Ways to hide an app from the list.
enum HideOption: Hashable {
    case minutes(Int)   // for a while
    case untilTomorrow  // until midnight
    case untilRestart   // while this run of the app lasts
    case always         // the Excluded list
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
    @Published var query = "" { didSet { reholdLayout(); selection = visible.first?.id } }
    @Published var selection: pid_t?
    /// Rows stay put while the pointer is over the panel. See LayoutHold.swift.
    @Published private(set) var layoutHold = LayoutHold()
    /// When the rows last changed on screen (uptime), for click protection.
    var layoutChangedAt: TimeInterval = 0

    // Settings (persisted)
    @Published var excluded: Set<String> { didSet { saveSet(excluded, "excluded"); rebuild(); reholdLayout() } }
    @Published var pinned: Set<String> { didSet { saveSet(pinned, "pinned"); reholdLayout() } }
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
    /// Temporary hides: bundle ID -> until when; bundle ID -> the process to hide (until the app restarts).
    @Published private(set) var hiddenUntil: [String: Date] {
        didSet { defaults.set(hiddenUntil.mapValues(\.timeIntervalSince1970), forKey: "hiddenUntil") }
    }
    @Published private(set) var hiddenRun: [String: pid_t] {
        didSet { defaults.set(hiddenRun.mapValues(Int.init), forKey: "hiddenRun") }
    }
    @Published var attentionOnTop: Bool { didSet { defaults.set(attentionOnTop, forKey: "attentionOnTop") } }
    @Published var busyMatch: BusyMatch { didSet { defaults.set(busyMatch.rawValue, forKey: "busyMatch") } }
    /// Hide your own apps (Dock and background) unless they're busy, frozen or pinned.
    @Published var hideQuietApps: Bool { didSet { defaults.set(hideQuietApps, forKey: "hideQuietApps") } }
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
    private var axMisses: [pid_t: Int] = [:]    // missed pings in a row; frozen needs two (one can be a busy moment)

    private init() {
        Self.migrateOldSettings()
        excluded = Set(defaults.stringArray(forKey: "excluded") ?? [])
        pinned = Set(defaults.stringArray(forKey: "pinned") ?? [])
        watched = Set(defaults.stringArray(forKey: "watched") ?? [])
        frozenThreshold = defaults.object(forKey: "frozenThreshold") as? Double ?? 15
        confirmActions = defaults.object(forKey: "confirmActions") as? Bool ?? true // a click restarts; ask unless turned off
        showMemory = defaults.object(forKey: "showMemory") as? Bool ?? true
        appearance = AppearanceMode(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        selfHeal = defaults.object(forKey: "selfHeal") as? Bool ?? true
        attentionOnTop = defaults.object(forKey: "attentionOnTop") as? Bool ?? true
        hiddenUntil = (defaults.dictionary(forKey: "hiddenUntil") as? [String: Double] ?? [:]).mapValues { Date(timeIntervalSince1970: $0) }
        hiddenRun = (defaults.dictionary(forKey: "hiddenRun") as? [String: Int] ?? [:]).mapValues { pid_t($0) }
        busyMatch = BusyMatch(rawValue: defaults.string(forKey: "busyMatch") ?? "") ?? .either
        hideQuietApps = defaults.object(forKey: "hideQuietApps") as? Bool ?? false
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
        if let old = defaults.persistentDomain(forName: "com.prabeshbhetwal.AppRestarter") {
            for key in ["excluded", "pinned", "watched", "frozenThreshold", "confirmActions", "showMemory", "notify", "hotkey", "history"]
            where defaults.object(forKey: key) == nil {
                if let value = old[key] { defaults.set(value, forKey: key) }
            }
        }
        defaults.set(true, forKey: "migratedFromAppRestarter") // after the copy, so a crash mid-copy retries
    }

    func start() {
        observation = NSWorkspace.shared.observe(\.runningApplications, options: [.initial]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.rebuild() }
        }
        // Memory + frozen state + watchdog. ponytail: fixed 3 s poll; event-driven would need private APIs.
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.pollStatus() }
        timer?.tolerance = 1 // lets macOS batch wake-ups with other timers (energy)
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
        timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .seconds(1))
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

    /// The rows as drawn: held in place while the pointer is over the panel, live otherwise.
    var visible: [AppItem] {
        layoutHold.isOn ? layoutHold.rows(updatedFrom: all) : liveVisible
    }

    private var liveVisible: [AppItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return all
            .filter { isShown($0) && (q.isEmpty || $0.name.localizedCaseInsensitiveContains(q)) }
            .sorted { rank($0) < rank($1) }
    }

    /// Same order as the panel's groups, so ↑↓ moves down the list as drawn.
    private func rank(_ item: AppItem) -> (Int, Int, String) {
        let section = needsAttention(item) ? (attentionOnTop ? 0 : 3) : pinned.contains(item.bundleID) ? 1 : 2
        return (section, item.kind.rawValue, item.name.lowercased())
    }

    /// The group a row is drawn in. While the layout is held, a row keeps the group it had.
    func inAttentionGroup(_ item: AppItem) -> Bool {
        layoutHold.isOn ? layoutHold.inAttentionGroup(item.id) : needsAttention(item)
    }

    /// Apps that need attention but wait for the pointer to leave before they get a row.
    var waitingForAttention: [AppItem] {
        guard layoutHold.isOn else { return [] }
        return liveVisible.filter { needsAttention($0) && !layoutHold.contains($0.id) }
    }

    /// The panel reports the pointer entering and leaving it.
    func setPointerOverPanel(_ inside: Bool) {
        guard inside != layoutHold.isOn else { return }
        if inside { layoutHold.begin(liveVisible, attention: needsAttention) } else { layoutHold.end() }
        if selection == nil || !visible.contains(where: { $0.id == selection }) { selection = visible.first?.id }
    }

    /// The person changed the list themselves (search, pin, hide): show it now, then hold again.
    private func reholdLayout() {
        guard layoutHold.isOn else { return }
        layoutHold.end()
        layoutHold.begin(liveVisible, attention: needsAttention)
    }

    /// Click protection: false for a click that came right after the rows moved, aimed at the old layout.
    func clickIsSafe() -> Bool {
        ProcessInfo.processInfo.systemUptime - layoutChangedAt >= clickGuardInterval
    }

    /// Frozen apps, and macOS apps that are only listed because they're busy.
    func needsAttention(_ item: AppItem) -> Bool {
        item.frozen || (item.kind == .system && systemApps == .whenBusy && !pinned.contains(item.bundleID))
    }

    func isShown(_ item: AppItem) -> Bool {
        if isHiddenForNow(item) { return false }
        if pinned.contains(item.bundleID) { return true }
        let active = item.frozen || wasBusyRecently(item)
        switch item.kind {
        case .app: return !hideQuietApps || active
        case .background: return showBackground && (!hideQuietApps || active)
        case .system:
            switch systemApps {
            case .never: return false
            case .always: return true
            case .whenBusy: return active
            }
        }
    }

    /// Busy now or in the last 15 s, so rows don't flicker in and out around a limit.
    private func wasBusyRecently(_ item: AppItem) -> Bool {
        highUseAt[item.id].map { Date().timeIntervalSince($0) < 15 } == true
    }

    /// The RAM and CPU limits, combined with or / and.
    func isBusy(_ item: AppItem) -> Bool {
        busyMatch == .either ? isHighRAM(item) || isHighCPU(item) : isHighRAM(item) && isHighCPU(item)
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

    /// Never restarted automatically, even when watched: killing them mid-job can damage a disk,
    /// an install or a migration. A person can still restart them by hand.
    static let neverAutoRestart: Set<String> = ["com.apple.installer", "com.apple.DiskUtility", "com.apple.MigrateAssistant"]

    /// nil = not listable: no bundle, this app (or another copy of it), a helper inside another
    /// app (counted toward that app), or a command-line tool.
    static func kind(of app: NSRunningApplication) -> AppKind? {
        guard app.processIdentifier != getpid(), !app.isTerminated,
              let id = app.bundleIdentifier, !neverList.contains(id), id != Bundle.main.bundleIdentifier,
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
                    self.axMisses[item.id] = s.ping == false && answers ? (self.axMisses[item.id] ?? 0) + 1 : 0
                    item.frozen = (self.axMisses[item.id] ?? 0) >= 2
                    if !answers, s.ping != true, trusted { self.axSilent.insert(item.id) }
                    if let last = self.lastCPU[item.id], now > last.at {
                        // ponytail: a helper exiting between samples drops its time; clamp at 0
                        let used = s.usage.cpuNanos > last.cpuNanos ? s.usage.cpuNanos - last.cpuNanos : 0
                        item.cpu = Double(used) / Double(now - last.at) * 100
                    }
                    self.lastCPU[item.id] = (s.usage.cpuNanos, now)
                    if self.isBusy(item) { self.highUseAt[item.id] = Date() }
                    return item
                }
                self.lastCPU = self.lastCPU.filter { pids.contains($0.key) }
                self.highUseAt = self.highUseAt.filter { pids.contains($0.key) }
                self.axAnswered.formIntersection(pids)
                self.axSilent.formIntersection(pids)
                self.axMisses = self.axMisses.filter { pids.contains($0.key) }
                self.pruneHides()
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
            if watched.contains(item.bundleID), !Self.neverAutoRestart.contains(item.bundleID),
               now.timeIntervalSince(since) >= frozenThreshold, !busy.contains(item.id) {
                run(.restart, on: [item], automatic: true)
            }
        }
    }

    // MARK: Actions

    /// User-triggered. Bulk actions and macOS apps always ask; others ask if the setting is on.
    func perform(_ action: AppAction, on items: [AppItem]) {
        let items = items.filter { !busy.contains($0.id) && !$0.app.isTerminated } // a held row can outlive its app
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
                    if !ok, !automatic { self.showFailure(action, name: name) } // a click that silently did nothing reads as a bug
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

    private func showFailure(_ action: AppAction, name: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn’t \(action.verb.lowercased()) \(name)"
        alert.informativeText = action == .restart
            ? "\(name) may still be running, or it quit and didn’t open again. Try again, or open it from the Dock or Applications."
            : "\(name) is still running. If it belongs to another user, the admin password is needed. You can also try Activity Monitor."
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
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

    // MARK: Hiding

    func isHiddenForNow(_ item: AppItem) -> Bool {
        (hiddenUntil[item.bundleID].map { $0 > Date() } ?? false) || hiddenRun[item.bundleID] == item.id
    }

    func hide(_ item: AppItem, _ option: HideOption) {
        switch option {
        case .minutes(let m): hiddenUntil[item.bundleID] = Date().addingTimeInterval(TimeInterval(m * 60))
        case .untilTomorrow: hiddenUntil[item.bundleID] = Calendar.current.startOfDay(for: Date().addingTimeInterval(86_400))
        case .untilRestart: hiddenRun[item.bundleID] = item.id
        case .always: excluded.insert(item.bundleID)
        }
        reholdLayout()
        if selection == item.id { selection = visible.first?.id }
    }

    func showAgain(_ bundleID: String) {
        hiddenUntil[bundleID] = nil
        hiddenRun[bundleID] = nil
        reholdLayout()
    }

    /// Drop timed hides that ran out and run hides whose process has quit.
    private func pruneHides() {
        let now = Date(), running = Set(all.map(\.id))
        if hiddenUntil.contains(where: { $0.value <= now }) { hiddenUntil = hiddenUntil.filter { $0.value > now } }
        if !all.isEmpty, hiddenRun.contains(where: { !running.contains($0.value) }) { hiddenRun = hiddenRun.filter { running.contains($0.value) } }
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
/// The PID is checked against the process's start time before each kill, so a PID the app freed
/// and macOS handed to another process is never killed.
func forceKill(_ app: NSRunningApplication) -> Bool {
    let pid = app.processIdentifier
    guard let born = startTime(pid) else { return true } // already gone
    app.forceTerminate()
    if startTime(pid) == born, kill(pid, SIGKILL) != 0, errno == EPERM { adminKill(pid, born: born) }
    for _ in 0..<50 where startTime(pid) == born { usleep(100_000) } // up to 5 s
    return startTime(pid) != born
}

/// Opens the app again, retrying while LaunchServices still thinks the old copy is running.
func relaunch(_ url: URL) -> Bool {
    for delay in [0.3, 1.0, 3.0] {
        usleep(useconds_t(delay * 1_000_000))
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
        if ok { return true }
    }
    return false
}

/// When the process started (µs since 1970), or nil if it's gone. Two processes that share a PID
/// over time never share this. sysctl works for every user's processes, like ps.
func startTime(_ pid: pid_t) -> UInt64? {
    var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
    let t = info.kp_proc.p_starttime
    return UInt64(t.tv_sec) * 1_000_000 + UInt64(t.tv_usec)
}

/// Quits and reopens RestinPID. A helper shell waits for this process to exit, then opens the app
/// again. hard = SIGKILL now (safe from any thread, works when the main thread is stuck).
func relaunchSelf(hard: Bool = false) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/sh")
    task.arguments = ["-c", "while kill -0 $1 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
                      Bundle.main.bundleURL.path, String(getpid())]
    do { try task.run() } catch {
        NSLog("RestinPID: couldn't start the relaunch helper, staying open: \(error)") // quitting now would leave us dead
        return
    }
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

/// Kills a process owned by another user, as root, after the admin password prompt. The prompt can
/// stay open for minutes, so the root shell re-checks the start time (as ps prints it) and only
/// kills the same process.
func adminKill(_ pid: pid_t, born: UInt64) {
    guard let stamp = psStart(pid), startTime(pid) == born else { return }
    let shell = "[ \"$(LC_ALL=C /bin/ps -p \(pid) -o lstart=)\" = \"\(stamp)\" ] && /bin/kill -9 \(pid)"
    let script = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    task.arguments = ["-e", "do shell script \"\(script)\" with administrator privileges"]
    try? task.run()
    task.waitUntilExit()
}

/// ps's start time for a process, e.g. "Sat Nov  8 09:40:12 2026". Only letters, digits, spaces
/// and colons, so it's safe to put in the root shell command.
private func psStart(_ pid: pid_t) -> String? {
    let task = Process(), pipe = Pipe()
    task.executableURL = URL(fileURLWithPath: "/bin/ps")
    task.arguments = ["-p", String(pid), "-o", "lstart="]
    task.environment = ["LC_ALL": "C"]
    task.standardOutput = pipe
    guard (try? task.run()) != nil else { return nil }
    task.waitUntilExit()
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .newlines)
    let safe = !out.isEmpty && out.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == " " || $0 == ":") }
    return task.terminationStatus == 0 && safe ? out : nil
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
