import AppKit
import AthanorCore
import SwiftUI

/// The scripts, logs and settings windows, one of each.
///
/// Athanor has no Dock icon, except while one of these is open, so the window
/// can be found with ⌘-Tab like any other.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var scriptsWindow: NSWindow?
    private var logsWindow: NSWindow?
    private var settingsWindow: NSWindow?
    let scriptsState = ScriptsWindowState()
    let logsState = LogsWindowState()

    init(model: AppModel) {
        self.model = model
    }

    /// The scripts window, showing this script, or the one shown last.
    func showScripts(select id: String?) {
        openScriptsWindow()
        if let id { scriptsState.select(id, model: model) }
    }

    /// The scripts window, with a new script begun from `template`, or blank.
    func newScript(template: ScriptConfig?) {
        openScriptsWindow()
        scriptsState.add(template: template, model: model)
    }

    private func openScriptsWindow() {
        if let scriptsWindow {
            present(scriptsWindow)
            return
        }
        scriptsState.sync(with: model)
        let window = makeWindow(title: "Scripts", content: ScriptsView(model: model, state: scriptsState), resizable: true)
        window.setContentSize(NSSize(width: 960, height: 680))
        window.setFrameAutosaveName("AthanorScripts")
        scriptsWindow = window
        present(window)
    }

    func showLogs(select id: String?) {
        if let id { logsState.selection = id }
        if let logsWindow {
            present(logsWindow)
            return
        }
        let view = LogsView(model: model, state: logsState) { [weak self] id in
            self?.showScripts(select: id)
        }
        let window = makeWindow(title: "Logs", content: view, resizable: true)
        window.setContentSize(NSSize(width: 980, height: 620))
        window.setFrameAutosaveName("AthanorLogs")
        logsWindow = window
        present(window)
    }

    func showSettings() {
        if let settingsWindow {
            present(settingsWindow)
            return
        }
        let view = SettingsView(model: model, settings: model.settings) { [weak self] in
            self?.showScripts(select: nil)
        }
        let window = makeWindow(title: "Athanor Settings", content: view, resizable: false)
        settingsWindow = window
        present(window)
    }

    private func makeWindow<Content: View>(title: String, content: Content, resizable: Bool) -> NSWindow {
        let hosting = NSHostingController(rootView: content)
        hosting.sizingOptions = resizable ? [.minSize] : [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.styleMask = resizable ? [.titled, .closable, .miniaturizable, .resizable] : [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.backgroundColor = Palette.ground
        window.center()
        return window
    }

    private func present(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Before quitting: shows the scripts window asking about changes not
    /// saved, if it has any, and says so; quitting then waits for another try.
    func askAboutUnsavedScripts() -> Bool {
        guard let scriptsWindow, !scriptsState.unsaved(in: model).isEmpty else { return false }
        present(scriptsWindow)
        scriptsWindow.performClose(nil)
        return true
    }

    /// Closing the scripts window with changes not saved asks what to do with them.
    func windowShouldClose(_ window: NSWindow) -> Bool {
        guard window === scriptsWindow else { return true }
        let unsaved = scriptsState.unsaved(in: model)
        guard let first = unsaved.first else { return true }
        let alert = NSAlert()
        alert.messageText = unsaved.count == 1
            ? "Save your changes to “\(first.draft.name.isEmpty ? "New Script" : first.draft.name)”?"
            : "Save your changes to \(unsaved.count) scripts?"
        alert.informativeText = "If you don’t save them, they’re lost."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don’t Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch response {
                case .alertFirstButtonReturn:
                    // One that can't be saved stays on screen, saying why.
                    guard self.scriptsState.saveAll(model: self.model) else { return }
                case .alertSecondButtonReturn:
                    break
                default:
                    return
                }
                window.close()
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === scriptsWindow {
            scriptsWindow = nil
            scriptsState.reset()
        }
        if window === logsWindow { logsWindow = nil }
        if window === settingsWindow { settingsWindow = nil }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.scriptsWindow == nil, self.logsWindow == nil, self.settingsWindow == nil else { return }
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
