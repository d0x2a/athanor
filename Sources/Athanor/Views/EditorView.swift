import AppKit
import AthanorCore
import SwiftUI

/// The form's copy of a script while it's being edited.
@MainActor @Observable
final class EditorDraft {
    enum ReadyKind: String, CaseIterable, Identifiable {
        case started = "Started"
        case port = "Port open"
        case url = "URL answers"
        var id: String { rawValue }
    }

    struct EnvRow: Identifiable, Equatable {
        let id = UUID()
        var key: String
        var value: String
    }

    enum Field: Hashable {
        case name, command, port, url, limit, window, timeout
    }

    /// nil while adding a new script.
    let originalID: String?
    var name: String
    var command: String
    var cwd: String
    var env: [EnvRow]
    var useLoginEnvironment: Bool
    var autostart: Bool
    var restartOnCrash: Bool
    var restartLimit: Int
    var restartMinutes: Int
    var stopSignal: StopSignal
    var stopTimeout: Int
    var readyKind: ReadyKind
    var port: String
    var url: String
    var errors: [Field: String] = [:]
    var saveError: String?

    init(editing config: ScriptConfig?, template: ScriptConfig? = nil) {
        let source = config ?? template ?? ScriptConfig(id: "", name: "", command: "")
        originalID = config?.id
        name = source.name
        command = source.command
        cwd = source.cwd
        env = source.env.map { EnvRow(key: $0.key, value: $0.value) }
        useLoginEnvironment = source.useLoginEnvironment
        autostart = source.autostart
        restartOnCrash = source.restartOnCrash
        restartLimit = source.restartLimit
        restartMinutes = max(1, Int((Double(source.restartWindow) / 60).rounded()))
        stopSignal = source.stopSignal
        stopTimeout = source.stopTimeout
        switch source.ready {
        case .started:
            readyKind = .started
            port = ""
            url = ""
        case .port(let value):
            readyKind = .port
            port = String(value)
            url = ""
        case .url(let value):
            readyKind = .url
            port = ""
            url = value
        }
    }

    var isNew: Bool { originalID == nil }

    /// Checks the form; on success returns the script to save.
    func validated(against model: AppModel) -> ScriptConfig? {
        errors = [:]
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        if trimmedName.isEmpty {
            errors[.name] = "Give it a name."
        } else if model.scripts.contains(where: { $0.config.name == trimmedName && $0.id != originalID }) {
            errors[.name] = "Another script is already called “\(trimmedName)”."
        }
        let script = ScriptsFile.normalizedCommand(command)
        if script.isEmpty { errors[.command] = "Write the command to run." }
        var ready = Readiness.started
        switch readyKind {
        case .started:
            break
        case .port:
            if let value = Int(port.trimmingCharacters(in: .whitespaces)), (1...65535).contains(value) {
                ready = .port(value)
            } else {
                errors[.port] = "A port is a number from 1 to 65535."
            }
        case .url:
            let text = url.trimmingCharacters(in: .whitespaces)
            if let parsed = URL(string: text), let scheme = parsed.scheme, ["http", "https"].contains(scheme), parsed.host != nil {
                ready = .url(text)
            } else {
                errors[.url] = "Use a full address, like http://127.0.0.1:8000/health."
            }
        }
        if !(0...1000).contains(restartLimit) { errors[.limit] = "0 to 1000." }
        if !(1...10_080).contains(restartMinutes) { errors[.window] = "1 to 10080 minutes." }
        if !(1...3600).contains(stopTimeout) { errors[.timeout] = "1 to 3600 seconds." }
        guard errors.isEmpty else { return nil }

        let id = originalID ?? ScriptsFile.uniqueID(for: trimmedName, taken: Set(model.scripts.map(\.id)))
        var config = ScriptConfig(id: id, name: trimmedName, command: script)
        let folder = cwd.trimmingCharacters(in: .whitespaces)
        config.cwd = folder.isEmpty ? "~" : folder
        var seen = Set<String>()
        config.env = env.reversed().compactMap { row -> EnvVar? in
            let key = row.key.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            return EnvVar(key, row.value)
        }.reversed()
        config.useLoginEnvironment = useLoginEnvironment
        config.autostart = autostart
        config.restartOnCrash = restartOnCrash
        config.restartLimit = restartLimit
        config.restartWindow = restartMinutes * 60
        config.stopSignal = stopSignal
        config.stopTimeout = stopTimeout
        config.ready = ready
        return config
    }
}

/// Add or edit a script.
struct EditorView: View {
    let model: AppModel
    @Bindable var draft: EditorDraft
    let close: () -> Void
    @State private var confirmingDelete = false

    private var runtime: ScriptRuntime? {
        draft.originalID.flatMap(model.script)
    }

    var body: some View {
        VStack(spacing: 0) {
            Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 14) {
                GridRow {
                    label("Name")
                    field {
                        TextField("", text: $draft.name, prompt: Text("rapid-mlx"))
                            .textFieldStyle(.roundedBorder)
                        error(.name)
                    }
                }
                GridRow {
                    label("Script")
                    field {
                        ScriptTextView(text: $draft.command)
                            .frame(height: 112)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        error(.command)
                        hint {
                            Text("Runs with ") + code("/bin/sh -c") + Text(". Start the last line with ")
                                + code("exec") + Text(" so Stop reaches the program, not just the shell.")
                        }
                    }
                }
                GridRow {
                    label("Working folder")
                    HStack(spacing: 8) {
                        TextField("", text: $draft.cwd, prompt: Text("~"))
                            .textFieldStyle(.roundedBorder)
                            .font(Theme.mono(12))
                        // In the sandbox a chosen folder would be out of the
                        // script's reach by the next launch.
                        if !Sandbox.isActive {
                            Button("Choose…", action: chooseFolder)
                                .buttonStyle(FilledButtonStyle(height: 24, bordered: true))
                        }
                    }
                }
                GridRow {
                    label("Environment")
                    field {
                        ForEach($draft.env) { $row in
                            HStack(spacing: 6) {
                                TextField("", text: $row.key, prompt: Text("NAME"))
                                    .textFieldStyle(.roundedBorder)
                                    .font(Theme.mono(12))
                                    .accessibilityLabel("Variable name")
                                TextField("", text: $row.value, prompt: Text("value"))
                                    .textFieldStyle(.roundedBorder)
                                    .font(Theme.mono(12))
                                    .accessibilityLabel("Value")
                                Button {
                                    draft.env.removeAll { $0.id == row.id }
                                } label: {
                                    Image(systemName: "minus")
                                }
                                .buttonStyle(IconButtonStyle(size: 24, tint: Theme.secondary, filled: false))
                                .accessibilityLabel("Remove \(row.key.isEmpty ? "variable" : row.key)")
                            }
                        }
                        Button {
                            draft.env.append(.init(key: "", value: ""))
                        } label: {
                            Label("Add variable", systemImage: "plus")
                        }
                        .buttonStyle(FilledButtonStyle(height: 24))
                        if !Sandbox.isActive {
                            Toggle(isOn: $draft.useLoginEnvironment) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Use the environment from my login shell")
                                    Text("Apps started from the Dock or at login don’t get your Terminal’s PATH, so Homebrew, pip and nvm tools aren’t found without this.")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(Theme.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(.top, 6)
                        }
                    }
                }

                GridRow {
                    Rule().gridCellColumns(2)
                }

                GridRow {
                    label("Start")
                    Toggle("Start when Athanor opens", isOn: $draft.autostart)
                }
                GridRow {
                    label("If it crashes")
                    field {
                        Toggle("Restart it automatically", isOn: $draft.restartOnCrash)
                        HStack(spacing: 6) {
                            Text("up to")
                            numberField($draft.restartLimit, label: "Most restarts")
                            Text("times in")
                            numberField($draft.restartMinutes, label: "Within minutes")
                            Text("minutes, then pause and notify me")
                        }
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.secondary)
                        .padding(.leading, 20)
                        .disabled(!draft.restartOnCrash)
                        error(.limit)
                        error(.window)
                    }
                }
                GridRow {
                    label("Stop with")
                    field {
                        HStack(spacing: 6) {
                            Picker("Stop signal", selection: $draft.stopSignal) {
                                ForEach(StopSignal.allCases, id: \.self) { Text($0.name).tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                            Text("then force quit after")
                            numberField($draft.stopTimeout, label: "Seconds before force quit")
                            Text("seconds")
                        }
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.secondary)
                        error(.timeout)
                    }
                }
                GridRow {
                    label("Ready when")
                    field {
                        HStack(spacing: 8) {
                            Picker("Ready when", selection: $draft.readyKind) {
                                ForEach(EditorDraft.ReadyKind.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                            switch draft.readyKind {
                            case .started:
                                EmptyView()
                            case .port:
                                TextField("", text: $draft.port, prompt: Text("8000"))
                                    .textFieldStyle(.roundedBorder)
                                    .font(Theme.mono(12))
                                    .frame(width: 80)
                                    .accessibilityLabel("Port")
                            case .url:
                                TextField("", text: $draft.url, prompt: Text("http://127.0.0.1:8000/health"))
                                    .textFieldStyle(.roundedBorder)
                                    .font(Theme.mono(12))
                                    .accessibilityLabel("URL")
                            }
                        }
                        error(.port)
                        error(.url)
                        hint {
                            Text(readyHint)
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 18)

            if let message = draft.saveError {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 12)
            }

            Rule()
            footer
        }
        .frame(width: 660)
        .font(.system(size: 13))
        .tint(Theme.accentFill)
        .background(Theme.ground)
        .confirmationDialog("Delete “\(draft.name)”?", isPresented: $confirmingDelete) {
            Button("Delete Script", role: .destructive, action: delete)
        } message: {
            Text(runtime?.hasProcess == true
                 ? "It’s running; Athanor stops it first. Its log file stays."
                 : "Its log file stays in ~/Library/Logs/Athanor.")
        }
    }

    private var readyHint: String {
        switch draft.readyKind {
        case .started: "Counts as up as soon as it starts. Right for scripts with no port, like caffeinate."
        case .port: "The dot stays dim until something listens on this port on localhost."
        case .url: "The dot stays dim until this address answers, with any status."
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if !draft.isNew {
                Button("Delete Script…") { confirmingDelete = true }
                    .buttonStyle(QuietButtonStyle(tint: Theme.danger))
            }
            Spacer()
            Button("Cancel", action: close)
                .keyboardShortcut(.cancelAction)
                .buttonStyle(FilledButtonStyle(height: 30, bordered: true))
            Button("Save") { save(thenRun: false) }
                .buttonStyle(FilledButtonStyle(height: 30, bordered: true))
            Button(runtime?.hasProcess == true ? "Save and Restart" : "Save and Start") { save(thenRun: true) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(PrimaryButtonStyle(height: 30))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Theme.raised.opacity(0.35))
    }

    // MARK: Pieces

    private func label(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(Theme.secondary)
            .frame(width: 120, alignment: .trailing)
            .padding(.top, 4)
            .gridColumnAlignment(.trailing)
    }

    private func field<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func error(_ field: EditorDraft.Field) -> some View {
        if let message = draft.errors[field] {
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.danger)
        }
    }

    private func hint(_ text: () -> Text) -> some View {
        text()
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func code(_ text: String) -> Text {
        Text(text).font(Theme.mono(11)).foregroundColor(Theme.text)
    }

    private func numberField(_ value: Binding<Int>, label: String) -> some View {
        TextField("", value: value, format: .number)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.center)
            .frame(width: 52)
            .accessibilityLabel(label)
    }

    // MARK: Actions

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: expandTilde(draft.cwd.isEmpty ? "~" : draft.cwd))
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            draft.cwd = abbreviateHome(url.path)
        }
    }

    private func save(thenRun: Bool) {
        draft.saveError = nil
        guard let config = draft.validated(against: model) else { return }
        do {
            try model.save(config)
        } catch {
            draft.saveError = "Couldn’t save: \(error)"
            return
        }
        if thenRun, let script = model.script(config.id) {
            if script.hasProcess {
                model.restart(script)
            } else {
                model.start(script)
            }
        }
        close()
    }

    private func delete() {
        guard let id = draft.originalID else { return }
        do {
            try model.delete(id)
            close()
        } catch {
            draft.saveError = "Couldn’t delete: \(error)"
        }
    }
}

/// A plain-text editor for shell: no smart quotes or dashes, which would
/// break the script, and no spelling underlines.
struct ScriptTextView: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = Palette.text
        textView.backgroundColor = Palette.well
        textView.insertionPointColor = Palette.accentText
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.string = text
        textView.delegate = context.coordinator
        textView.setAccessibilityLabel("Script")
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Palette.well
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let textView = scrollView.documentView as! NSTextView
        if textView.string != text {
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}
