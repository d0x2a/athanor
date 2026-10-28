import AppKit
import AthanorCore
import SwiftUI

/// What the popover can ask of the rest of the app.
struct PopoverActions {
    var addScript: (ScriptConfig?) -> Void
    var showScripts: (String?) -> Void
    var showLogs: (String?) -> Void
    var showSettings: () -> Void
    var openScriptsFile: () -> Void
    var close: () -> Void
}

/// A borderless panel under the menu bar item, the way MenuBarExtra's window
/// style looks, but one the app can open itself (for the keyboard shortcut).
final class PopoverPanel: NSPanel {
    var onCancel: (() -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        hidesOnDeactivate = false
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// The menu bar item: its glyph, and the popover it opens.
@MainActor
final class StatusItemController: NSObject {
    private let model: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let images: [GlyphState: NSImage] = [
        .idle: StatusGlyph.image(for: .idle),
        .running: StatusGlyph.image(for: .running),
        .attention: StatusGlyph.image(for: .attention),
    ]
    private var panel: PopoverPanel?
    /// Reports the content's size as preferredContentSize and does no Auto
    /// Layout sizing, which would grow the panel from its bottom edge.
    private var hosting: NSHostingController<AnyView>?
    private var sizeObservation: NSKeyValueObservation?
    private var monitors: [Any] = []
    /// When a click elsewhere last closed the popover, in system uptime.
    private var dismissedAt: TimeInterval = 0
    var actions: PopoverActions!

    init(model: AppModel) {
        self.model = model
        super.init()
        if let button = item.button {
            button.target = self
            button.action = #selector(toggle)
            button.imagePosition = .imageLeft
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }
        observe()
    }

    var isOpen: Bool { panel?.isVisible == true }

    @objc func toggle() {
        if isOpen {
            close()
        } else if ProcessInfo.processInfo.systemUptime - dismissedAt > 0.4 {
            // Otherwise this is the item's own action for the click that
            // just closed the popover, which would open it again.
            open()
        }
    }

    func open() {
        guard let button = item.button, let buttonWindow = button.window else { return }
        let panel = self.panel ?? makePanel()
        let size = hosting?.sizeThatFits(in: CGSize(width: 400, height: 10_000)) ?? CGSize(width: 400, height: 420)
        let anchor = buttonWindow.frame
        let screen = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? anchor
        var x = anchor.midX - size.width / 2
        x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
        // Flush with the bottom of the menu bar, as a status item's menu is.
        let top = anchor.minY
        panel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        button.highlight(true)
        installMonitors()
    }

    func close() {
        panel?.orderOut(nil)
        item.button?.highlight(false)
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func makePanel() -> PopoverPanel {
        let panel = PopoverPanel()
        panel.onCancel = { [weak self] in self?.close() }
        let maxList = max(240, (NSScreen.main?.visibleFrame.height ?? 900) - 260)
        let root = PopoverView(model: model, actions: actions, maxListHeight: maxList)
        let hosting = NSHostingController(rootView: AnyView(root))
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentView = hosting.view
        sizeObservation = hosting.observe(\.preferredContentSize, options: [.new]) { [weak self] hosting, _ in
            let size = hosting.preferredContentSize
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.resize(to: size) }
            }
        }
        self.panel = panel
        self.hosting = hosting
        return panel
    }

    /// Keeps the top edge under the menu bar as the content grows and shrinks.
    private func resize(to size: CGSize) {
        // A hidden panel has no position worth keeping; open() places it.
        guard size.width > 0, size.height > 0, let panel, panel.isVisible else { return }
        let frame = panel.frame
        guard abs(frame.height - size.height) > 0.5 || abs(frame.width - size.width) > 0.5 else { return }
        let next = NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height)
        panel.setFrame(next, display: true, animate: false)
        panel.invalidateShadow()
    }

    /// Clicks anywhere else close the popover, as a menu would. A click on
    /// the item is left to its action, which closes it.
    private func installMonitors() {
        guard monitors.isEmpty else { return }
        // The menu bar draws status items in a process of its own, so a click
        // on the item can arrive here as well as through its action.
        if let outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }) {
            monitors.append(outside)
        }
        // Global monitors don't see Athanor's own windows.
        if let inside = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window !== self.panel else { return }
                self.dismiss()
            }
            return event
        }) {
            monitors.append(inside)
        }
    }

    private func dismiss() {
        if let itemFrame = item.button?.window?.frame, itemFrame.contains(NSEvent.mouseLocation) { return }
        dismissedAt = ProcessInfo.processInfo.systemUptime
        close()
    }

    // MARK: The glyph

    private func observe() {
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.observe() }
            }
        }
    }

    private func render() {
        guard let button = item.button else { return }
        let state = model.glyphState
        let count = model.runningCount
        button.image = images[state]
        button.title = model.settings.showRunningCount && count > 0 ? " \(count)" : ""
        let label: String
        switch state {
        case .idle: label = "Athanor, nothing running"
        case .running: label = "Athanor, \(count) running"
        case .attention: label = "Athanor, a script crashed"
        }
        button.setAccessibilityLabel(label)
        button.toolTip = label
    }
}
