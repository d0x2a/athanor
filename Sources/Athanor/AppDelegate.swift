import AppKit
import AthanorCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var statusItem: StatusItemController!
    private var windows: WindowManager!
    private let notifier = Notifier()
    private let hotkey = GlobalHotkey()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let paths = AthanorPaths.standard()
        // Two copies on the same scripts (a dev build beside a release, say)
        // would both restart a crashed one.
        guard Self.lockRunFolder(paths.runDir) else {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "Athanor is already running."
            alert.informativeText = "Another copy is looking after these scripts. Look for the furnace in the menu bar."
            alert.runModal()
            exit(0)
        }
        NSApp.setActivationPolicy(.accessory)

        let settings = AppSettings()
        model = AppModel(paths: paths, settings: settings)
        windows = WindowManager(model: model)
        statusItem = StatusItemController(model: model)
        statusItem.actions = PopoverActions(
            addScript: { [weak self] template in
                self?.statusItem.close()
                self?.windows.showEditor(for: nil, template: template)
            },
            edit: { [weak self] id in
                self?.statusItem.close()
                self?.windows.showEditor(for: id)
            },
            showLogs: { [weak self] id in
                self?.statusItem.close()
                self?.windows.showLogs(select: id)
            },
            showSettings: { [weak self] in
                self?.statusItem.close()
                self?.windows.showSettings()
            },
            openScriptsFile: { [weak self] in
                guard let self else { return }
                self.statusItem.close()
                openScriptsFile(self.model.paths)
            },
            close: { [weak self] in self?.statusItem.close() }
        )
        installMainMenu()

        notifier.setUp()
        notifier.onStart = { [weak self] id in
            guard let self, let script = self.model.script(id) else { return }
            self.model.start(script)
        }
        notifier.onShowLog = { [weak self] id in self?.windows.showLogs(select: id) }
        model.onEvent = { [weak self] event in self?.notify(event) }

        hotkey.action = { [weak self] in self?.statusItem.toggle() }
        watchHotkey()

        model.bootstrap()

        // The first time, show where Athanor lives.
        if !UserDefaults.standard.bool(forKey: "hasLaunched") {
            UserDefaults.standard.set(true, forKey: "hasLaunched")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                MainActor.assumeIsolated { self?.statusItem.open() }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { statusItem.open() }
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.hasActiveScripts else { return .terminateNow }
        switch model.settings.quitBehavior {
        case .leave:
            return .terminateNow
        case .stop:
            stopAllThenQuit()
            return .terminateLater
        case .ask:
            statusItem.close()
            NSApp.activate()
            let alert = NSAlert()
            let count = model.runningCount
            alert.messageText = count == 1 ? "A script is still running." : "\(count) scripts are still running."
            alert.informativeText = "Scripts left running keep going, and Athanor reconnects to them when it opens again."
            alert.addButton(withTitle: "Leave Running")
            alert.addButton(withTitle: "Stop and Quit")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                return .terminateNow
            case .alertSecondButtonReturn:
                stopAllThenQuit()
                return .terminateLater
            default:
                return .terminateCancel
            }
        }
    }

    private func stopAllThenQuit() {
        model.stopAll {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }

    /// Holds an flock on run/athanor.lock for as long as the process lives.
    private static func lockRunFolder(_ folder: URL) -> Bool {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fd = open(folder.appendingPathComponent("athanor.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return true }
        return flock(fd, LOCK_EX | LOCK_NB) == 0
    }

    // MARK: Notifications

    private func notify(_ event: ScriptEvent) {
        let settings = model.settings
        switch event {
        case .down(let script):
            guard settings.notifyWhenDown else { return }
            let summary = script.lastExit?.summary ?? "Crashed"
            notifier.post(title: "\(script.config.name) stopped (\(summary.lowercased()))",
                          body: script.crashNote ?? "It isn’t being restarted.",
                          scriptID: script.id, down: true)
        case .restarting(let script, let attempt):
            guard settings.notifyOnRestart else { return }
            notifier.post(title: "\(script.config.name) crashed",
                          body: "Restarting it (\(attempt) of \(script.config.restartLimit)).",
                          scriptID: script.id, down: false)
        case .finished(let script):
            guard settings.notifyOnFinish else { return }
            notifier.post(title: "\(script.config.name) finished", body: "It exited with code 0.",
                          scriptID: script.id, down: false)
        }
    }

    private func watchHotkey() {
        withObservationTracking {
            hotkey.set(model?.settings.hotkey ?? AppSettings().hotkey)
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.watchHotkey() }
            }
        }
    }

    // MARK: Menu

    /// Never shown while Athanor has no Dock icon, but its key equivalents
    /// still work: without an Edit menu, ⌘C and ⌘V do nothing in text fields.
    private func installMainMenu() {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Athanor",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Athanor", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Athanor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: appMenu, title: "Athanor")

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Find…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
            .tag = Int(NSTextFinder.Action.showFindInterface.rawValue)
        main.addItem(submenu: editMenu, title: "Edit")

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addItem(submenu: windowMenu, title: "Window")
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }

    @objc private func showSettings() {
        windows.showSettings()
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
