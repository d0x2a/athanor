import AppKit
import AthanorCore
import SwiftUI
import UniformTypeIdentifiers

/// What the scripts window is showing: the selected script, and the forms
/// of the scripts looked at, which keep changes not yet saved while another
/// script is shown.
@MainActor @Observable
final class ScriptsWindowState {
    /// A script's id, or one of `newKeys`.
    private(set) var selection: String?
    /// One form per script looked at, by id, and per script being added.
    private(set) var drafts: [String: EditorDraft] = [:]
    /// Scripts being added and not saved yet, in the order they were begun.
    private(set) var newKeys: [String] = []
    /// A move or delete scripts.toml refused.
    var listError: String?
    /// The script being dragged in the list, and the one it's over.
    var dragging: String?
    var dropTarget: String?
    @ObservationIgnored private var lastScript: String?

    func select(_ key: String, model: AppModel) {
        if let current = selection, current != key, drafts[current]?.isUntouchedBlank == true {
            drafts[current] = nil
            newKeys.removeAll { $0 == current }
        }
        selection = key
        if model.script(key) != nil { lastScript = key }
        sync(with: model)
    }

    /// Begins a new script, from a template if given.
    func add(template: ScriptConfig?, model: AppModel) {
        if template == nil, let blank = newKeys.first(where: { drafts[$0]?.isUntouchedBlank == true }) {
            select(blank, model: model)
            return
        }
        let key = "new:" + UUID().uuidString
        drafts[key] = EditorDraft(editing: nil, template: template)
        newKeys.append(key)
        select(key, model: model)
    }

    /// Begins a new script with the settings of `id` as saved.
    func duplicate(_ id: String, model: AppModel) {
        guard var copy = model.script(id)?.config else { return }
        let taken = Set(model.scripts.map(\.config.name) + newKeys.compactMap { drafts[$0]?.name })
        var name = "\(copy.name) copy"
        var number = 2
        while taken.contains(name) {
            name = "\(copy.name) copy \(number)"
            number += 1
        }
        copy.name = name
        add(template: copy, model: model)
    }

    /// Saves the form; it then shows the script as saved.
    @discardableResult
    func save(_ key: String, model: AppModel) -> ScriptConfig? {
        guard let draft = drafts[key] else { return nil }
        draft.saveError = nil
        guard let config = draft.validated(against: model) else { return nil }
        do {
            try model.save(config)
        } catch {
            draft.saveError = "Couldn’t save: \(error)"
            return nil
        }
        drafts[key] = nil
        newKeys.removeAll { $0 == key }
        if selection == key {
            selection = config.id
            lastScript = config.id
        }
        sync(with: model)
        return config
    }

    /// Reverts a script's form to the script as saved; drops a new one.
    func discardChanges(_ key: String, model: AppModel) {
        drafts[key] = nil
        newKeys.removeAll { $0 == key }
        sync(with: model)
    }

    /// Moves a script to `index` in the list.
    func move(_ id: String, to index: Int, model: AppModel) {
        var ids = model.scripts.map(\.id)
        guard let from = ids.firstIndex(of: id) else { return }
        ids.remove(at: from)
        ids.insert(id, at: min(max(0, index), ids.count))
        guard ids != model.scripts.map(\.id) else { return }
        do {
            try model.reorder(ids)
            listError = nil
        } catch {
            listError = "Couldn’t move it: \(error)"
        }
    }

    func delete(_ id: String, model: AppModel) {
        let index = model.scripts.firstIndex { $0.id == id } ?? 0
        do {
            try model.delete(id)
            listError = nil
        } catch {
            listError = "Couldn’t delete it: \(error)"
            return
        }
        drafts[id] = nil
        if selection == id, !model.scripts.isEmpty {
            select(model.scripts[min(index, model.scripts.count - 1)].id, model: model)
        } else {
            sync(with: model)
        }
    }

    /// Forms with changes, in list order.
    func unsaved(in model: AppModel) -> [(key: String, draft: EditorDraft)] {
        (model.scripts.map(\.id) + newKeys).compactMap { key in
            drafts[key].flatMap { $0.isDirty ? (key, $0) : nil }
        }
    }

    /// Saves every form with changes. False when one can't be saved; it's
    /// then selected, saying why.
    func saveAll(model: AppModel) -> Bool {
        for (key, _) in unsaved(in: model) {
            guard save(key, model: model) != nil else {
                selection = key
                return false
            }
        }
        return true
    }

    /// The window closed: changes not saved by now are gone.
    func reset() {
        drafts = [:]
        newKeys = []
        listError = nil
        dragging = nil
        dropTarget = nil
    }

    /// Catches the forms up with scripts.toml: a form without changes shows
    /// the script as the file has it now, a script gone from the file takes
    /// its form along, and something stays selected.
    func sync(with model: AppModel) {
        for (key, draft) in drafts {
            guard let id = draft.originalID else { continue }
            if let script = model.script(id) {
                if !draft.isDirty, draft.original != script.config {
                    drafts[key] = EditorDraft(editing: script.config)
                }
            } else {
                drafts[key] = nil
            }
        }
        let exists = { (key: String) in self.newKeys.contains(key) || model.script(key) != nil }
        if !(selection.map(exists) ?? false) {
            selection = lastScript.flatMap { exists($0) ? $0 : nil } ?? model.scripts.first?.id ?? newKeys.last
        }
        if let selection, drafts[selection] == nil, let script = model.script(selection) {
            drafts[selection] = EditorDraft(editing: script.config)
        }
    }
}

/// Every script, to add, change, reorder and remove: the list on the left,
/// the selected one's settings on the right.
struct ScriptsView: View {
    let model: AppModel
    @Bindable var state: ScriptsWindowState
    /// Asking before deleting this script, or dropping this new one.
    @State private var confirmingRemove: String?

    private var selectedScript: ScriptRuntime? {
        state.selection.flatMap(model.script)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Theme.line.frame(width: 1)
            VStack(spacing: 0) {
                if let error = model.fileError {
                    FileErrorBanner(message: error, keepsLastGood: !model.scripts.isEmpty) {
                        openScriptsFile(model.paths)
                    }
                    Rule()
                }
                if let key = state.selection, let draft = state.drafts[key] {
                    EditorView(model: model, state: state, key: key, draft: draft)
                        .id(draft.id)
                } else {
                    empty
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 890, minHeight: 540)
        .background(Theme.ground)
        .foregroundStyle(Theme.text)
        .tint(Theme.accentFill)
        .onAppear { state.sync(with: model) }
        .onChange(of: model.scripts.map(\.config)) { state.sync(with: model) }
        .confirmationDialog(removeTitle, isPresented: Binding(
            get: { confirmingRemove != nil },
            set: { if !$0 { confirmingRemove = nil } }
        ), presenting: confirmingRemove) { key in
            if model.script(key) != nil {
                Button("Delete Script", role: .destructive) { state.delete(key, model: model) }
            } else {
                Button("Discard", role: .destructive) { state.discardChanges(key, model: model) }
            }
        } message: { key in
            if let script = model.script(key) {
                Text(script.hasProcess
                     ? "It’s running; Athanor stops it first. Its log file stays."
                     : "Its log file stays in ~/Library/Logs/Athanor.")
            } else {
                Text("It hasn’t been saved.")
            }
        }
    }

    private var removeTitle: String {
        guard let key = confirmingRemove else { return "" }
        if let script = model.script(key) { return "Delete “\(script.config.name)”?" }
        return "Discard this new script?"
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Text("No scripts yet")
                .foregroundStyle(Theme.secondary)
            Button("Add Script") { state.add(template: nil, model: model) }
                .buttonStyle(PrimaryButtonStyle(height: 30))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: The list

    private var sidebar: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(model.scripts.enumerated()), id: \.element.id) { index, script in
                        scriptItem(script, at: index)
                    }
                    ForEach(state.newKeys, id: \.self) { key in
                        if let draft = state.drafts[key] {
                            ScriptListItem(
                                title: draft.name.isEmpty ? "New Script" : draft.name,
                                subtitle: Text("Not saved yet").foregroundColor(Theme.accentText),
                                phase: .stopped, edited: false, selected: state.selection == key
                            ) {
                                state.select(key, model: model)
                            }
                            .contextMenu {
                                Button("Discard…") { remove(key) }
                            }
                        }
                    }
                }
                .padding(8)
            }
            if let error = state.listError {
                Text(error)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
            Rule()
            toolbar
        }
        .frame(width: 230)
        .background(Theme.well.opacity(0.5))
    }

    private func scriptItem(_ script: ScriptRuntime, at index: Int) -> some View {
        let edited = state.drafts[script.id]?.isDirty == true
        let target = state.dropTarget == script.id && state.dragging != script.id
        let fromAbove = (state.dragging.flatMap { id in model.scripts.firstIndex { $0.id == id } } ?? index) < index
        return ScriptListItem(
            title: script.config.name,
            subtitle: Text(script.config.summary).font(Theme.mono(10.5)),
            phase: script.phase, edited: edited, selected: state.selection == script.id
        ) {
            state.select(script.id, model: model)
        }
        .overlay(alignment: fromAbove ? .bottom : .top) {
            if target {
                Capsule().fill(Theme.accentFill).frame(height: 2).offset(y: fromAbove ? 2 : -2)
            }
        }
        .onDrag {
            state.dragging = script.id
            return NSItemProvider(object: script.id as NSString)
        }
        .onDrop(of: [.text], delegate: ScriptDropDelegate(target: script.id, model: model, state: state))
        .contextMenu {
            Button("Duplicate") { state.duplicate(script.id, model: model) }
            Divider()
            Button("Move Up") { state.move(script.id, to: index - 1, model: model) }
                .disabled(index == 0)
            Button("Move Down") { state.move(script.id, to: index + 1, model: model) }
                .disabled(index == model.scripts.count - 1)
            Divider()
            Button("Delete…") { remove(script.id) }
        }
        .accessibilityAction(named: "Move Up") { state.move(script.id, to: index - 1, model: model) }
        .accessibilityAction(named: "Move Down") { state.move(script.id, to: index + 1, model: model) }
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            Button {
                state.add(template: nil, model: model)
            } label: {
                Image(systemName: "plus")
            }
            .keyboardShortcut("n")
            .help("Add a script (⌘N)")
            .accessibilityLabel("Add script")
            Button {
                if let script = selectedScript { state.duplicate(script.id, model: model) }
            } label: {
                Image(systemName: "plus.square.on.square")
            }
            .keyboardShortcut("d")
            .help("Duplicate (⌘D)")
            .accessibilityLabel("Duplicate script")
            .disabled(selectedScript == nil)
            Button {
                if let key = state.selection { remove(key) }
            } label: {
                Image(systemName: "minus")
            }
            .help(selectedScript == nil ? "Discard" : "Delete…")
            .accessibilityLabel(selectedScript == nil ? "Discard new script" : "Delete script")
            .disabled(state.selection == nil)
            Spacer(minLength: 0)
            Button {
                openScriptsFile(model.paths)
            } label: {
                Image(systemName: "doc.text")
            }
            .help("Open scripts.toml in your text editor")
            .accessibilityLabel("Open scripts.toml")
        }
        .buttonStyle(IconButtonStyle(size: 26, tint: Theme.secondary, filled: false))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    /// Deletes a script or drops a new one, asking first unless it's a new
    /// one nothing was done to.
    private func remove(_ key: String) {
        if model.script(key) == nil, state.drafts[key]?.isDirty != true {
            state.discardChanges(key, model: model)
        } else {
            confirmingRemove = key
        }
    }
}

private struct ScriptListItem: View {
    let title: String
    let subtitle: Text
    let phase: ScriptRuntime.Phase
    let edited: Bool
    let selected: Bool
    let select: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(phase: phase)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                subtitle
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if edited {
                Circle()
                    .fill(Theme.accentText)
                    .frame(width: 7, height: 7)
                    .help("Changed, not saved")
                    .accessibilityLabel("Changed, not saved")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Theme.selection : .clear))
        .contentShape(Rectangle())
        // A tap rather than a Button, which would keep the row from being dragged.
        .onTapGesture(perform: select)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, select)
    }
}

/// Dropping a script on another puts it in that one's place.
private struct ScriptDropDelegate: DropDelegate {
    let target: String
    let model: AppModel
    let state: ScriptsWindowState

    func validateDrop(info: DropInfo) -> Bool {
        state.dragging != nil
    }

    func dropEntered(info: DropInfo) {
        state.dropTarget = target
    }

    func dropExited(info: DropInfo) {
        if state.dropTarget == target { state.dropTarget = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            state.dragging = nil
            state.dropTarget = nil
        }
        guard let dragged = state.dragging, let index = model.scripts.firstIndex(where: { $0.id == target }) else {
            return false
        }
        state.move(dragged, to: index, model: model)
        return true
    }
}
