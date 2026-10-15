import AppKit
import AthanorCore
import SwiftUI

/// The popover: header, scripts, footer.
struct PopoverView: View {
    let model: AppModel
    let actions: PopoverActions
    let maxListHeight: CGFloat
    @State private var expanded: String?
    @AppStorage("sandboxNoteDismissed") private var sandboxNoteDismissed = false

    init(model: AppModel, actions: PopoverActions, maxListHeight: CGFloat, initialExpanded: String? = nil) {
        self.model = model
        self.actions = actions
        self.maxListHeight = maxListHeight
        _expanded = State(initialValue: initialExpanded)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rule()
            if let error = model.fileError {
                FileErrorBanner(message: error, keepsLastGood: !model.scripts.isEmpty, open: actions.openScriptsFile)
                Rule()
            }
            if model.scriptsAreSandboxed, !sandboxNoteDismissed {
                SandboxBanner(outdated: model.runner?.state == .outdated, setUp: actions.showSettings) {
                    sandboxNoteDismissed = true
                }
                Rule()
            }
            if !model.scripts.isEmpty {
                list
            } else if model.fileError == nil {
                EmptyStateView(model: model, actions: actions)
            }
            Rule()
            footer
        }
        .frame(width: 400)
        .background(Theme.ground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border))
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(Theme.text)
    }

    private var header: some View {
        HStack(spacing: 10) {
            LogoMark(size: 26, lit: model.glyphState != .idle)
            VStack(alignment: .leading, spacing: 1) {
                Text("Athanor")
                    .font(.system(size: 14, weight: .semibold))
                summary
                    .font(.system(size: 12))
            }
            Spacer(minLength: 0)
            Button {
                actions.addScript(nil)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(IconButtonStyle(size: 30))
            .help("Add a script")
            .accessibilityLabel("Add script")
            Button(action: actions.showSettings) {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(IconButtonStyle(size: 30))
            .help("Settings")
            .accessibilityLabel("Settings")
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 12)
    }

    private var summary: Text {
        let parts = model.summaryParts
        if model.scripts.isEmpty { return Text("No scripts yet").foregroundColor(Theme.secondary) }
        if parts.running == 0, parts.crashed == 0 {
            let count = model.scripts.count
            return Text("Nothing running · \(count) script\(count == 1 ? "" : "s")").foregroundColor(Theme.secondary)
        }
        var pieces: [Text] = []
        if parts.crashed > 0 { pieces.append(Text("\(parts.crashed) crashed").foregroundColor(Theme.danger)) }
        if parts.running > 0 { pieces.append(Text("\(parts.running) running").foregroundColor(Theme.secondary)) }
        if parts.stopped > 0 { pieces.append(Text("\(parts.stopped) stopped").foregroundColor(Theme.secondary)) }
        return pieces.dropFirst().reduce(pieces[0]) { $0 + Text(" · ").foregroundColor(Theme.secondary) + $1 }
    }

    /// Crashed scripts first.
    private var ordered: [ScriptRuntime] {
        model.scripts.filter(\.needsAttention) + model.scripts.filter { !$0.needsAttention }
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(ordered) { script in
                    ScriptRow(script: script, model: model, actions: actions, expanded: $expanded)
                }
            }
            .padding(6)
        }
        .frame(maxHeight: maxListHeight)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Button("Start all") { model.startAll() }
                .buttonStyle(FilledButtonStyle())
                .disabled(!model.scripts.contains(where: \.canStart))
            Button("Stop all") { model.stopAll() }
                .buttonStyle(FilledButtonStyle())
                .disabled(!model.hasActiveScripts)
            Spacer(minLength: 0)
            Button("Logs") { actions.showLogs(nil) }
                .buttonStyle(QuietButtonStyle())
                .disabled(model.scripts.isEmpty)
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(QuietButtonStyle())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// The store build, while scripts can't leave the App Sandbox.
private struct SandboxBanner: View {
    let outdated: Bool
    let setUp: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "shippingbox")
                .foregroundStyle(Theme.secondary)
                .font(.system(size: 12))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(outdated ? "Athanor’s runner needs updating" : "Scripts run in the App Sandbox")
                    .font(.system(size: 12.5, weight: .semibold))
                Text(outdated
                    ? "Until it’s updated, scripts can’t reach Homebrew, your tools or your files."
                    : "They can’t reach Homebrew, your tools or your files until you let them run outside it.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Set Up…", action: setUp)
                .buttonStyle(SmallButtonStyle())
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.secondary)
            .help("Don’t show this again")
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// scripts.toml didn't parse.
private struct FileErrorBanner: View {
    let message: String
    let keepsLastGood: Bool
    let open: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.dangerMark)
                .font(.system(size: 12))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("scripts.toml has a mistake")
                    .font(.system(size: 12.5, weight: .semibold))
                Text(message)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.dangerNote)
                    .fixedSize(horizontal: false, vertical: true)
                Text(keepsLastGood ? "Athanor keeps using the last version that worked." : "Athanor loads it once it’s fixed.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 0)
            Button("Open", action: open)
                .buttonStyle(SmallButtonStyle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.dangerWash)
    }
}

/// No scripts yet: what Athanor does, and three to start from.
private struct EmptyStateView: View {
    let model: AppModel
    let actions: PopoverActions

    private struct Example {
        let title: String
        let config: ScriptConfig
    }

    private var examples: [Example] {
        var awake = ScriptConfig(id: "", name: "caffeinate", command: "caffeinate -dims")
        awake.useLoginEnvironment = false
        if model.scriptsAreSandboxed {
            // Scripts there can't reach Homebrew or Apple's developer tools
            // (python3 among them), only what comes with macOS.
            let site = ScriptConfig(
                id: "", name: "site check",
                command: "while true; do curl -s -o /dev/null -w '%{http_code}\\n' https://www.apple.com; sleep 60; done"
            )
            let battery = ScriptConfig(
                id: "", name: "battery", command: "while true; do pmset -g batt | tail -1; sleep 300; done"
            )
            return [
                Example(title: "Keep the Mac awake", config: awake),
                Example(title: "Check a website every minute", config: site),
                Example(title: "Log the battery every 5 minutes", config: battery),
            ]
        }
        let model = ScriptConfig(id: "", name: "rapid-mlx", command: "rapid-mlx serve <model>")
        var http = ScriptConfig(id: "", name: "http server", command: "python3 -m http.server 8000")
        http.ready = .port(8000)
        return [
            Example(title: "Keep the Mac awake", config: awake),
            Example(title: "Local model server", config: model),
            Example(title: "Serve a folder over HTTP", config: http),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                LogoMark(size: 44, lit: false)
                Text("Run your scripts from the menu bar")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.top, 4)
                (Text("Athanor starts each script with ") + Text("/bin/sh").font(Theme.mono(11.5))
                    + Text(", restarts it if it crashes, and keeps its output."))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    actions.addScript(nil)
                } label: {
                    Label("Add script", systemImage: "plus")
                }
                .buttonStyle(PrimaryButtonStyle(height: 32))
                .padding(.top, 8)
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 20)

            VStack(alignment: .leading, spacing: 4) {
                Text("Or start from an example")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 4)
                ForEach(examples, id: \.title) { example in
                    ExampleButton(title: example.title, command: example.config.command) {
                        actions.addScript(example.config)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 12)

            Rule()
            HStack(spacing: 4) {
                Text("Saved to")
                Text(abbreviateHome(model.paths.scriptsFile.path))
                    .font(Theme.mono(10.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}

private struct ExampleButton: View {
    let title: String
    let command: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(command)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accentText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering ? Theme.raised : Theme.well))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("Add example: \(title)")
    }
}
