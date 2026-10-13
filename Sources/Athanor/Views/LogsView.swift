import AppKit
import AthanorCore
import SwiftUI

/// What the logs window is showing, kept across openings.
@MainActor @Observable
final class LogsWindowState {
    var selection: String?
    var filter = ""
    var errorsOnly = false
    var follow = true
}

/// Every script's output: a list on the left, the selected script's
/// stats and log on the right.
struct LogsView: View {
    let model: AppModel
    @Bindable var state: LogsWindowState
    let edit: (String) -> Void

    private var selected: ScriptRuntime? {
        state.selection.flatMap(model.script) ?? model.scripts.first
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Theme.line.frame(width: 1)
            if let script = selected {
                LogDetail(model: model, script: script, state: state, edit: edit)
            } else {
                Text("No scripts yet")
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 760, minHeight: 440)
        .background(Theme.ground)
        .foregroundStyle(Theme.text)
        .tint(Theme.accentFill)
    }

    private var sidebar: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(model.scripts) { script in
                    SidebarItem(script: script, selected: script.id == selected?.id) {
                        state.selection = script.id
                    }
                }
            }
            .padding(8)
        }
        .frame(width: 220)
        .background(Theme.well.opacity(0.5))
    }
}

private struct SidebarItem: View {
    let script: ScriptRuntime
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                StatusDot(phase: script.phase)
                VStack(alignment: .leading, spacing: 2) {
                    Text(script.config.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    TimelineView(.periodic(from: .now, by: 5)) { context in
                        Text(status(now: context.date))
                            .font(.system(size: 11))
                            .foregroundStyle(script.needsAttention ? Theme.danger : Theme.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Theme.selection : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func status(now: Date) -> String {
        switch script.phase {
        case .running:
            return script.startedAt.map { "Running · up \(Format.duration(now.timeIntervalSince($0)))" } ?? "Running"
        case .starting: return "Starting"
        case .stopping: return "Stopping"
        case .restarting: return "Restarting"
        case .crashed: return [script.lastExit?.summary, script.lastExit.map { Format.ago($0.at, now: now) }]
            .compactMap { $0 }.joined(separator: " · ")
        case .stopped:
            return script.lastExit.map { "Stopped · \(Format.day($0.at, now: now))" } ?? "Never run"
        }
    }
}

private struct LogDetail: View {
    let model: AppModel
    let script: ScriptRuntime
    @Bindable var state: LogsWindowState
    let edit: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Rule()
            toolbar
            LogTextView(
                scriptID: script.id,
                lines: script.log.lines,
                filter: state.filter,
                errorsOnly: state.errorsOnly,
                follow: state.follow
            )
            Rule()
            statusBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(script.config.name)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                    phasePill
                    ForEach(script.sample?.ports ?? [], id: \.self) { PortChip(port: $0) }
                }
                HStack(spacing: 16) {
                    if let pid = script.childPid ?? script.shimPid, script.hasProcess {
                        meta("PID", String(pid), mono: true)
                    }
                    if let started = script.startedAt {
                        meta("Started", Format.clock(started))
                    }
                    if script.restartCount > 0 { meta("Restarts", String(script.restartCount)) }
                    if script.config.cwd != "~" {
                        Text(script.config.cwd)
                            .font(Theme.mono(11.5))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 11.5))
            }
            .frame(minWidth: 220, alignment: .leading)
            Spacer(minLength: 0)
            if script.hasProcess {
                HStack(spacing: 18) {
                    chart("CPU", script.sample.map { Format.cpu($0.cpuPercent) } ?? "—",
                          values: script.cpuHistory, floor: 100, color: Theme.lit)
                    chart("Memory", script.sample.map { Format.bytes($0.memoryBytes) } ?? "—",
                          values: script.memoryHistory, floor: 0, color: Theme.accentFill)
                }
            }
            HStack(spacing: 6) {
                if script.hasProcess {
                    Button("Restart") { model.restart(script) }
                    Button("Stop") { model.stop(script) }
                } else {
                    Button("Start") { model.start(script) }
                }
                Button("Edit") { edit(script.id) }
            }
            .buttonStyle(FilledButtonStyle(height: 28, bordered: true))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var phasePill: some View {
        let (text, color, fill): (String, Color, Color) = {
            switch script.phase {
            case .running: return ("Running", Theme.lit, Theme.lit.opacity(0.16))
            case .starting: return ("Starting", Theme.lit, Theme.lit.opacity(0.12))
            case .stopping: return ("Stopping", Theme.secondary, Theme.raised)
            case .restarting: return ("Restarting", Theme.danger, Theme.dangerWash)
            case .crashed: return ("Crashed", Theme.danger, Theme.dangerWash)
            case .stopped: return ("Stopped", Theme.secondary, Theme.raised)
            }
        }()
        return Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(fill))
    }

    private func meta(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(Theme.secondary)
            Text(value).font(mono ? Theme.mono(11.5) : .system(size: 11.5).monospacedDigit())
        }
    }

    private func chart(_ title: String, _ value: String, values: [Double], floor: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(title).foregroundStyle(Theme.secondary)
                Text(value).monospacedDigit()
            }
            .font(.system(size: 11))
            .lineLimit(1)
            .fixedSize()
            Sparkline(values: values, floor: floor)
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                .frame(width: 120, height: 28)
                .background(alignment: .bottom) { Theme.line.frame(height: 1) }
                .accessibilityLabel("\(title) over the last \(max(1, values.count * 2 / 60)) minutes")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary)
                TextField("Filter output", text: $state.filter)
                    .textFieldStyle(.plain)
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 8)
            .frame(width: 240, height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.well))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border))
            Picker("Show", selection: $state.errorsOnly) {
                Text("All").tag(false)
                Text("Errors").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            Toggle("Follow", isOn: $state.follow)
                .toggleStyle(LitToggleStyle())
            Button("Clear") { script.log.clear() }
                .buttonStyle(FilledButtonStyle(height: 26, bordered: true))
                .help("Clears this view. The log file keeps everything.")
        }
        .controlSize(.small)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private var statusBar: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            HStack(spacing: 10) {
                Text(abbreviateHome(model.paths.logFile(for: script.id).path))
                    .font(Theme.mono(11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(Format.bytes(model.logFileSize(script.id))) of \(model.settings.logCapMB) MB")
                Spacer()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.paths.logFile(for: script.id)])
                }
                .buttonStyle(QuietButtonStyle(tint: Theme.accentText))
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 20)
            .frame(height: 30)
        }
    }
}

/// A small line chart, scaled to its data; `floor` sets the least top of the
/// scale, so 3% CPU doesn't fill the box.
struct Sparkline: Shape {
    let values: [Double]
    var floor: Double = 0

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let points = Self.downsample(values, to: 120)
        guard points.count > 1 else { return path }
        let low = floor > 0 ? 0 : (points.min() ?? 0) * 0.9
        let high = max(points.max() ?? 1, floor, low + 1)
        for (index, value) in points.enumerated() {
            let x = rect.minX + rect.width * CGFloat(index) / CGFloat(points.count - 1)
            let y = rect.maxY - 1 - (rect.height - 2) * CGFloat((value - low) / (high - low))
            index == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
        }
        return path
    }

    private static func downsample(_ values: [Double], to count: Int) -> [Double] {
        guard values.count > count else { return values }
        let size = Double(values.count) / Double(count)
        return (0..<count).map { bucket in
            let start = Int(Double(bucket) * size)
            let end = max(start + 1, Int(Double(bucket + 1) * size))
            return values[start..<min(end, values.count)].max() ?? 0
        }
    }
}

/// The log itself, in an NSTextView so it can be selected and copied. New
/// lines are appended rather than the whole text rebuilt.
struct LogTextView: NSViewRepresentable {
    let scriptID: String
    let lines: [DisplayLine]
    let filter: String
    let errorsOnly: Bool
    let follow: Bool

    final class Coordinator {
        var scriptID: String?
        var filter = ""
        var errorsOnly = false
        var firstID = -1
        var lastID = -1
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.allowsUndo = false
        textView.drawsBackground = true
        textView.backgroundColor = Palette.well
        textView.textContainerInset = NSSize(width: 14, height: 10)
        textView.setAccessibilityLabel("Output")
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Palette.well
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let textView = scrollView.documentView as! NSTextView
        let coordinator = context.coordinator
        guard let storage = textView.textStorage else { return }
        let rebuild = coordinator.scriptID != scriptID || coordinator.filter != filter
            || coordinator.errorsOnly != errorsOnly || (lines.first?.id ?? -1) != coordinator.firstID
            || (lines.last?.id ?? -1) < coordinator.lastID
        let fresh: ArraySlice<DisplayLine>
        if rebuild {
            storage.setAttributedString(NSAttributedString())
            fresh = lines[...]
        } else {
            let start = lines.firstIndex { $0.id > coordinator.lastID } ?? lines.endIndex
            fresh = lines[start...]
        }
        coordinator.scriptID = scriptID
        coordinator.filter = filter
        coordinator.errorsOnly = errorsOnly
        coordinator.firstID = lines.first?.id ?? -1
        coordinator.lastID = lines.last?.id ?? -1
        guard rebuild || !fresh.isEmpty else { return }

        let needle = filter.trimmingCharacters(in: .whitespaces)
        let text = NSMutableAttributedString()
        for line in fresh {
            if errorsOnly, !line.isError { continue }
            if !needle.isEmpty, !line.text.localizedCaseInsensitiveContains(needle) { continue }
            text.append(Self.render(line))
        }
        storage.beginEditing()
        storage.append(text)
        storage.endEditing()
        if follow {
            textView.scrollToEndOfDocument(nil)
        }
    }

    private static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        style.headIndent = 74
        return style
    }()

    private static func render(_ line: DisplayLine) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let time = line.time.isEmpty ? "        " : line.time
        out.append(NSAttributedString(string: time + "  ", attributes: [
            .font: font, .foregroundColor: Palette.tertiary, .paragraphStyle: paragraph,
        ]))
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
        if line.isError {
            attributes[.foregroundColor] = Palette.danger
            attributes[.backgroundColor] = Palette.errorLine
        } else if line.stream == .ath {
            attributes[.foregroundColor] = Palette.accentText
        } else {
            attributes[.foregroundColor] = Palette.text
        }
        out.append(NSAttributedString(string: line.text + "\n", attributes: attributes))
        return out
    }
}
