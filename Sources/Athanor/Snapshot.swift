import AppKit
import AthanorCore
import SwiftUI

/// `Athanor --snapshot DIR`: renders the popover and windows to PNGs in light
/// and dark, from the real scripts.toml (or ATHANOR_HOME's), then quits. For
/// checking a design change, and for screenshots in docs.
///
/// It loads the scripts and watches any that are already running, but starts
/// nothing, and keeps its settings apart from the app's.
///
/// ATHANOR_SNAPSHOT_WAIT=SECONDS watches for longer before rendering, so the
/// logs window's CPU and memory charts have some history to draw.
@MainActor
enum Snapshot {
    static func run(to directory: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let defaults = UserDefaults(suiteName: "com.d0x2a.athanor.snapshot")!
        let model = AppModel(paths: .standard(), settings: AppSettings(defaults: defaults))
        model.bootstrap(supervise: false)
        // By default, long enough for logs to load and two CPU samples to land.
        let wait = ProcessInfo.processInfo.environment["ATHANOR_SNAPSHOT_WAIT"].flatMap(TimeInterval.init) ?? 5
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            MainActor.assumeIsolated {
                render(model, to: URL(fileURLWithPath: directory, isDirectory: true))
                exit(0)
            }
        }
        app.run()
        exit(0)
    }

    private static func render(_ model: AppModel, to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let actions = PopoverActions(addScript: { _ in }, edit: { _ in }, showLogs: { _ in },
                                     showSettings: {}, openScriptsFile: {}, close: {})
        // Show a crash: the first script that has ever exited badly.
        if let flaky = model.scripts.first(where: { $0.lastExit?.crashed == true && !$0.hasProcess }) {
            flaky.phase = .crashed
            flaky.restartCount = flaky.config.restartLimit
            flaky.crashNote = "Crashed \(flaky.config.restartLimit + 1) times in 8 seconds. Auto-restart is paused until you start it again."
        }
        let running = model.scripts.first(where: \.hasProcess)
        let crashed = model.scripts.first(where: { $0.phase == .crashed })

        for (name, appearance) in [("dark", NSAppearance(named: .darkAqua)!), ("light", NSAppearance(named: .aqua)!)] {
            capture(PopoverView(model: model, actions: actions, maxListHeight: 600, initialExpanded: nil),
                    appearance: appearance, to: folder.appendingPathComponent("popover-\(name).png"))
            if let running {
                capture(PopoverView(model: model, actions: actions, maxListHeight: 600, initialExpanded: running.id),
                        appearance: appearance, to: folder.appendingPathComponent("popover-running-\(name).png"))
            }
            if let crashed {
                capture(PopoverView(model: model, actions: actions, maxListHeight: 600, initialExpanded: crashed.id),
                        appearance: appearance, to: folder.appendingPathComponent("popover-crashed-\(name).png"))
            }
            let editing = running?.config ?? model.scripts.first?.config
            capture(EditorView(model: model, draft: EditorDraft(editing: editing)) {},
                    appearance: appearance, to: folder.appendingPathComponent("editor-\(name).png"))
            let logsState = LogsWindowState()
            logsState.selection = running?.id
            capture(LogsView(model: model, state: logsState) { _ in }.frame(width: 980, height: 620),
                    appearance: appearance, to: folder.appendingPathComponent("logs-\(name).png"))
            capture(SettingsView(model: model, settings: model.settings),
                    appearance: appearance, to: folder.appendingPathComponent("settings-\(name).png"))
        }
        let emptyPaths = AthanorPaths(root: folder.appendingPathComponent("empty-home"))
        let empty = AppModel(paths: emptyPaths, settings: model.settings)
        for (name, appearance) in [("dark", NSAppearance(named: .darkAqua)!), ("light", NSAppearance(named: .aqua)!)] {
            capture(PopoverView(model: empty, actions: actions, maxListHeight: 600, initialExpanded: nil),
                    appearance: appearance, to: folder.appendingPathComponent("popover-empty-\(name).png"))
        }
        renderGlyphs(to: folder.appendingPathComponent("glyphs.png"))
        if let icon = AppIcon.render(pixels: 512) {
            let rep = NSBitmapImageRep(cgImage: icon)
            try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("icon.png"))
        }
    }

    /// The three menu bar glyphs on a dark and a light bar, at 4×.
    private static func renderGlyphs(to url: URL) {
        let scale: CGFloat = 4
        let bars: [(NSAppearance, NSColor)] = [
            (NSAppearance(named: .darkAqua)!, NSColor(hex: 0x1E1F22)),
            (NSAppearance(named: .aqua)!, NSColor(hex: 0xECECEC)),
        ]
        let states: [GlyphState] = [.idle, .running, .attention]
        let cell: CGFloat = 30
        let image = NSImage(size: NSSize(width: cell * CGFloat(states.count) * scale, height: cell * CGFloat(bars.count) * scale))
        image.lockFocus()
        for (row, (appearance, color)) in bars.enumerated() {
            appearance.performAsCurrentDrawingAppearance {
                color.setFill()
                NSRect(x: 0, y: CGFloat(row) * cell * scale, width: image.size.width, height: cell * scale).fill()
                for (column, state) in states.enumerated() {
                    let glyph = StatusGlyph.image(for: state)
                    let rect = NSRect(x: (CGFloat(column) * cell + 6) * scale, y: (CGFloat(row) * cell + 6) * scale,
                                      width: 18 * scale, height: 18 * scale)
                    if glyph.isTemplate {
                        // What the menu bar does with a template: its alpha, in the bar's text color.
                        let tinted = NSImage(size: glyph.size, flipped: false) { bounds in
                            glyph.draw(in: bounds)
                            NSColor.labelColor.set()
                            bounds.fill(using: .sourceAtop)
                            return true
                        }
                        tinted.draw(in: rect)
                    } else {
                        glyph.draw(in: rect)
                    }
                }
            }
        }
        image.unlockFocus()
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }

    private static func capture<Content: View>(_ view: Content, appearance: NSAppearance, to url: URL) {
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, appearance.name == .darkAqua ? .dark : .light))
        hosting.appearance = appearance
        let size = hosting.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView = hosting
        window.orderFrontRegardless()
        // Views that measure themselves (the popover's list) settle over a
        // couple of passes; resize to whatever they settle at.
        for _ in 0..<3 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date() + 0.25)
            let settled = hosting.fittingSize
            if settled != window.contentLayoutRect.size {
                window.setContentSize(settled)
            }
        }
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        appearance.performAsCurrentDrawingAppearance {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}
