import AppKit
import AthanorCore
import SwiftUI

struct SettingsView: View {
    let model: AppModel
    @Bindable var settings: AppSettings
    @State private var loginItemError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            group {
                switchRow("Open Athanor at login", isOn: Binding(
                        get: { settings.launchesAtLogin },
                        set: { enabled in
                            do {
                                try settings.setLaunchesAtLogin(enabled)
                                loginItemError = nil
                            } catch {
                                loginItemError = "macOS didn’t allow it: \(error.localizedDescription)"
                            }
                        }
                    ))
                if let loginItemError {
                    Text(loginItemError)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.danger)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                }
                divider
                switchRow("Show how many scripts are running next to the icon", isOn: $settings.showRunningCount)
                divider
                row {
                    HStack {
                        Text("Keyboard shortcut to open")
                        Spacer()
                        HotkeyRecorder(hotkey: $settings.hotkey)
                    }
                }
            }

            section("When you quit Athanor") {
                if Sandbox.isActive {
                    Text("Athanor stops all scripts when it quits.")
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                } else {
                    Picker("When you quit Athanor", selection: $settings.quitBehavior) {
                        Text("Stop all scripts").tag(QuitBehavior.stop)
                        Text("Leave them running and reconnect next time").tag(QuitBehavior.leave)
                        Text("Ask each time").tag(QuitBehavior.ask)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    Text("Scripts left running keep writing to their log files. Athanor finds them again when it reopens.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.top, 6)
                        .padding(.bottom, 12)
                }
            }

            section("Notify me when") {
                switchRow("A script crashes and stays down", isOn: $settings.notifyWhenDown)
                divider
                switchRow("A script is restarted after a crash", isOn: $settings.notifyOnRestart)
                divider
                switchRow("A script finishes on its own (exit 0)", isOn: $settings.notifyOnFinish)
            }

            section("Files") {
                fileRow("Script list", path: model.paths.scriptsFile, button: "Open in Editor") {
                    openScriptsFile(model.paths)
                }
                divider
                fileRow("Logs", path: model.paths.logsDir, button: "Show in Finder") {
                    try? FileManager.default.createDirectory(at: model.paths.logsDir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(model.paths.logsDir)
                }
                divider
                row {
                    HStack {
                        Text("Keep logs per script up to")
                        Spacer()
                        Picker("Keep logs per script up to", selection: $settings.logCapMB) {
                            Text("1 MB").tag(1)
                            Text("10 MB").tag(10)
                            Text("100 MB").tag(100)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                Text("The script list is a plain text file: edit it by hand or keep it in your dotfiles. Athanor reloads it when it changes. A new log size applies the next time a script starts.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
        }
        .font(.system(size: 13))
        .padding(24)
        .tint(Theme.accentFill)
        .frame(width: 600)
        .background(Theme.ground)
        .foregroundStyle(Theme.text)
    }

    // MARK: Pieces

    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.raised.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.secondary)
                .padding(.leading, 4)
            group(content)
        }
    }

    private func switchRow(_ title: String, isOn: Binding<Bool>) -> some View {
        row {
            HStack {
                Text(title)
                Spacer(minLength: 12)
                Toggle(title, isOn: isOn)
                    .labelsHidden()
            }
        }
    }

    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .toggleStyle(.switch)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .padding(.horizontal, 14)
    }

    private var divider: some View {
        Theme.line.frame(height: 1).padding(.horizontal, 14)
    }

    private func fileRow(_ title: String, path: URL, button: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(abbreviateHome(path.path))
                    .font(Theme.mono(11.5))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button(button, action: action)
                .buttonStyle(FilledButtonStyle(height: 26, bordered: true))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// Opens scripts.toml in the user's editor for .toml files, or TextEdit if
/// nothing claims them. Creates it first if it doesn't exist yet.
@MainActor
func openScriptsFile(_ paths: AthanorPaths) {
    let url = paths.scriptsFile
    if !FileManager.default.fileExists(atPath: url.path) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? ScriptsFile.encode([]).write(to: url, atomically: true, encoding: .utf8)
    }
    if NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
        NSWorkspace.shared.open(url)
    } else if let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
        NSWorkspace.shared.open([url], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Click, then press the new shortcut. Esc cancels; Delete clears it.
struct HotkeyRecorder: View {
    @Binding var hotkey: Hotkey?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                recording ? stopRecording() : startRecording()
            } label: {
                Text(recording ? "Press a shortcut…" : (hotkey?.display ?? "None"))
                    .font(.system(size: 12.5).monospacedDigit())
                    .foregroundStyle(recording ? Theme.accentText : Theme.text)
                    .frame(minWidth: 110)
            }
            .buttonStyle(FilledButtonStyle(height: 26, bordered: true, fill: Theme.well))
            .accessibilityLabel(recording ? "Recording shortcut" : "Keyboard shortcut: \(hotkey?.display ?? "none"). Click to change.")
            if hotkey != nil, !recording {
                Button {
                    hotkey = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.secondary)
                .accessibilityLabel("Remove shortcut")
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case 53: // Esc
                stopRecording()
            case 51, 117: // Delete, Forward Delete
                hotkey = nil
                stopRecording()
            default:
                guard let new = Hotkey(event: event) else { return nil }
                hotkey = new
                stopRecording()
            }
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
