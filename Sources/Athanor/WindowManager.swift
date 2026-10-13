import AppKit
import AthanorCore
import SwiftUI

/// The editor, logs and settings windows. One of each, except editors: one
/// per script.
///
/// Athanor has no Dock icon, except while one of these is open, so the window
/// can be found with ⌘-Tab like any other.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var editors: [String: NSWindow] = [:]
    private var logsWindow: NSWindow?
    private var settingsWindow: NSWindow?
    let logsState = LogsWindowState()

    init(model: AppModel) {
        self.model = model
    }

    func showEditor(for id: String?, template: ScriptConfig? = nil) {
        let key = id ?? "new"
        if let window = editors[key] {
            present(window)
            return
        }
        let config = id.flatMap(model.script)?.config
        let draft = EditorDraft(editing: config, template: template)
        var window: NSWindow!
        let view = EditorView(model: model, draft: draft) { [weak self] in
            window?.close()
            self?.editors[key] = nil
        }
        window = makeWindow(title: config.map { "Edit Script — \($0.name)" } ?? "New Script", content: view, resizable: false)
        editors[key] = window
        present(window)
    }

    func showLogs(select id: String?) {
        if let id { logsState.selection = id }
        if let logsWindow {
            present(logsWindow)
            return
        }
        let view = LogsView(model: model, state: logsState) { [weak self] id in
            self?.showEditor(for: id)
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
        let window = makeWindow(title: "Athanor Settings",
                                content: SettingsView(model: model, settings: model.settings), resizable: false)
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

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === logsWindow { logsWindow = nil }
        if window === settingsWindow { settingsWindow = nil }
        editors = editors.filter { $0.value !== window }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.editors.isEmpty, self.logsWindow == nil, self.settingsWindow == nil else { return }
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
