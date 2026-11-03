import AppKit
import Combine
import Sparkle
import SwiftUI
import UserNotifications

@main
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private let model = AppModel.shared
    private let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var feedbackWindow: NSWindow?
    private var keyMonitor: Any?
    private var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        UNUserNotificationCenter.current().delegate = self

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
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

        // Menu bar icon turns into a warning when any listed app is frozen.
        model.$all
            .map { [model] in $0.contains { $0.frozen && model.isShown($0) } }
            .removeDuplicates()
            .sink { [weak self] anyFrozen in
                let name = anyFrozen ? "exclamationmark.arrow.circlepath" : "arrow.clockwise.circle"
                let label = anyFrozen ? "RestinPID – an app is not responding" : "RestinPID"
                self?.statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: label)
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
            let window = NSWindow(contentViewController: NSHostingController(rootView: FeedbackView()))
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

    // Show notifications even while our popover is in front.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
