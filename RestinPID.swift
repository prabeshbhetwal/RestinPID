import AppKit
import Combine
import Sparkle
import SwiftUI
import UserNotifications

@main
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate,
    SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private let model = AppModel.shared
    private lazy var updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var feedbackWindow: NSWindow?
    private var keyMonitor: Any?
    private var subscriptions = Set<AnyCancellable>()
    private var knownFrozen = Set<pid_t>()  // frozen apps already announced
    private var menuIcon: MenuBarIcon!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        UNUserNotificationCenter.current().delegate = self
        _ = updater // start Sparkle's schedule

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeft
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        let panel = PanelView(
            model: model,
            openSettings: { [weak self] in self?.showSettings() },
            checkForUpdates: { [weak self] in self?.checkForUpdates() },
            showAbout: { [weak self] in self?.showAbout() },
            sendFeedback: { [weak self] in self?.showFeedback() }
        )
        let hosting = NSHostingController(rootView: panel)
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = true

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.popover.isShown, event.window == hosting.view.window else { return event }
            if event.keyCode == 53 { // Esc: clear search first, then close
                if self.model.query.isEmpty { self.popover.performClose(nil) } else { self.model.query = "" }
                return nil
            }
            return self.model.handleKey(event) ? nil : event
        }

        // Menu bar icon: colour badge, count, glow and jiggle when a listed app is frozen; a dot when an update waits.
        menuIcon = MenuBarIcon(button: statusItem.button!)
        AlertSettings.shared.preview = { [weak self] in self?.menuIcon.preview() }
        model.$all
            .map { [model] in Set($0.filter { $0.frozen && model.isShown($0) }.map(\.id)) }
            .combineLatest(model.$availableUpdate.map { $0 != nil })
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] frozen, update in
                guard let self else { return }
                let newlyFrozen = !frozen.subtracting(self.knownFrozen).isEmpty
                self.menuIcon.show(frozen: frozen.count, update: update, newlyFrozen: newlyFrozen)
                self.knownFrozen = frozen
            }
            .store(in: &subscriptions)
        if CommandLine.arguments.contains("--preview-alert") { menuIcon.preview() } // for checking the look

        // Optional RAM · CPU reading next to the icon; refreshed with each poll.
        model.$all.map { _ in () }
            .merge(with: model.$macMemory.map { _ in () }, model.$menuBarUsage.map { _ in () })
            .receive(on: DispatchQueue.main) // read the model after the change lands
            .sink { [weak self] in self?.updateStatusReading() }
            .store(in: &subscriptions)

        model.$appearance
            .sink { [weak self] mode in
                NSApp.appearance = mode.nsAppearance
                self?.popover.appearance = mode.nsAppearance
            }
            .store(in: &subscriptions)

        Hotkey.shared.action = { [weak self] in self?.togglePopover() }
        model.$hotkey
            .sink { combo in
                if let combo { Hotkey.shared.register(combo) } else { Hotkey.shared.unregister() }
            }
            .store(in: &subscriptions)

        model.start()
    }

    // MARK: Status item + popover

    private func updateStatusReading() {
        guard let button = statusItem.button else { return }
        let reading: (memory: UInt64, cpu: Double?)?
        switch model.menuBarUsage {
        case .off: reading = nil
        case .listed: reading = model.totals(model.listed)
        case .system: reading = (model.macMemory, model.macCPU)
        }
        guard let reading, reading.memory > 0 else {
            button.attributedTitle = NSAttributedString()
            button.toolTip = nil
            return
        }
        let text = " " + formatBytes(reading.memory) + (reading.cpu.map { "  " + formatCPU($0) } ?? "")
        button.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
        ])
        button.toolTip = model.menuBarUsage == .system
            ? "Whole Mac: memory used and CPU load"
            : "Apps in the list: total RAM and CPU (100% = one core)"
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            statusItem.menu = makeStatusMenu()
            sender.performClick(nil)
            statusItem.menu = nil
        } else {
            togglePopover()
        }
    }

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        menuIcon.acknowledge() // seen it: motion stops, the badge stays while the app is frozen
        model.prepareForDisplay()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    // MARK: Windows

    @objc func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: makeSettingsController(model: model, updater: updater.updater))
            window.styleMask = [.titled, .closable]
            window.toolbarStyle = .preference
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showFeedback() {
        popover.performClose(nil)
        if feedbackWindow == nil {
            let hosting = NSHostingController(rootView: FeedbackView())
            hosting.sizingOptions = .preferredContentSize
            let window = NSWindow(contentViewController: hosting)
            window.title = "Send Feedback"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            feedbackWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        feedbackWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showAbout() {
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(
                string: "Rest in PID: force quit and restart frozen or greedy apps from the menu bar.",
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
            ),
        ])
    }

    @objc func checkForUpdates() {
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        updater.checkForUpdates(nil)
    }

    // MARK: Menus

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        let open = menu.addItem(withTitle: "Open RestinPID", action: #selector(togglePopover), keyEquivalent: "")
        if let combo = model.hotkey { open.title += "  (\(combo.display))" }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        menu.addItem(withTitle: "Send Feedback…", action: #selector(showFeedback), keyEquivalent: "")
        menu.addItem(withTitle: "About RestinPID", action: #selector(showAbout), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit RestinPID", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        return menu
    }

    /// Hidden main menu: gives ⌘, / ⌘Q / ⌘W and copy-paste in text fields.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About RestinPID", action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "Send Feedback…", action: #selector(showFeedback), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit RestinPID", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "RestinPID", action: nil, keyEquivalent: "").submenu = appMenu

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = window

        return main
    }

    // MARK: Updates (Sparkle gentle reminders)

    // A menu bar app is rarely in front, so scheduled checks don't pop a window over the user's work.
    // The menu bar dot, panel banner and a notification announce it; any of them opens Sparkle's
    // window, which shows the release notes before installing.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        model.availableUpdate = update.displayVersionString
        guard !handleShowingUpdate, !state.userInitiated else { return }
        let content = UNMutableNotificationContent()
        content.title = "RestinPID \(update.displayVersionString) is available"
        content.body = "Click to see what’s new."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "update", content: content, trigger: nil))
    }

    func standardUserDriverWillFinishUpdateSession() {
        model.availableUpdate = nil
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.identifier == "update" { checkForUpdates() }
        completionHandler()
    }

    // Show notifications even while our popover is in front.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

