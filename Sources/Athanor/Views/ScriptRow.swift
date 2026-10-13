import AppKit
import AthanorCore
import SwiftUI

/// One script in the popover, with its details when expanded.
struct ScriptRow: View {
    let script: ScriptRuntime
    let model: AppModel
    let actions: PopoverActions
    @Binding var expanded: String?

    private var isExpanded: Bool { expanded == script.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                StatusDot(phase: script.phase)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(script.config.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        ForEach(Array((script.sample?.ports ?? []).prefix(2)), id: \.self) { port in
                            PortChip(port: port)
                        }
                    }
                    Text(script.config.summary)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 4)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    RowStats(script: script, now: context.date)
                }
                HStack(spacing: 2) {
                    primaryButton
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { expanded = isExpanded ? nil : script.id }
                    } label: {
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .buttonStyle(IconButtonStyle(tint: Theme.secondary, filled: false))
                    .accessibilityLabel("Details for \(script.config.name)")
                    .accessibilityValue(isExpanded ? "expanded" : "collapsed")
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.15)) { expanded = isExpanded ? nil : script.id }
            }

            if isExpanded {
                RowDetail(script: script, model: model, actions: actions)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(background))
        .overlay {
            if script.needsAttention {
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.dangerBorder)
            }
        }
    }

    private var background: Color {
        if script.needsAttention { return Theme.dangerWash }
        return isExpanded ? Theme.raised : .clear
    }

    @ViewBuilder
    private var primaryButton: some View {
        if script.hasProcess {
            Button {
                model.stop(script)
            } label: {
                Image(systemName: "stop.fill").font(.system(size: 10))
            }
            .buttonStyle(IconButtonStyle())
            .disabled(script.phase == .stopping)
            .help("Stop")
            .accessibilityLabel("Stop \(script.config.name)")
        } else {
            Button {
                model.start(script)
            } label: {
                Image(systemName: "play.fill").font(.system(size: 10))
            }
            .buttonStyle(IconButtonStyle(tint: Theme.lit))
            .disabled(script.phase == .starting)
            .help("Start")
            .accessibilityLabel("Start \(script.config.name)")
        }
    }
}

/// The two short lines on the right of a row.
private struct RowStats: View {
    let script: ScriptRuntime
    let now: Date

    var body: some View {
        let (first, second, alarming) = lines
        VStack(alignment: .trailing, spacing: 3) {
            Text(first)
                .foregroundStyle(alarming ? Theme.danger : (script.hasProcess ? Theme.text : Theme.secondary))
            Text(second)
                .foregroundStyle(Theme.secondary)
        }
        .font(.system(size: 11).monospacedDigit())
        .lineLimit(1)
    }

    private var lines: (String, String, Bool) {
        switch script.phase {
        case .starting:
            switch script.config.ready {
            case .port(let port): return ("Starting…", "waiting for :\(port)", false)
            case .url: return ("Starting…", "waiting for URL", false)
            case .started: return ("Starting…", "", false)
            }
        case .running:
            let usage = script.sample.map { "\(Format.cpu($0.cpuPercent)) · \(Format.bytes($0.memoryBytes))" } ?? "—"
            let uptime = script.startedAt.map { "up \(Format.duration(now.timeIntervalSince($0)))" } ?? ""
            return (usage, uptime, false)
        case .stopping:
            return ("Stopping…", "", false)
        case .restarting(let at):
            return (script.lastExit?.summary ?? "Crashed", "restarting in \(max(0, Int(at.timeIntervalSince(now).rounded(.up))))s", true)
        case .crashed:
            return (script.lastExit?.summary ?? "Crashed", script.lastExit.map { Format.ago($0.at, now: now) } ?? "", true)
        case .stopped:
            guard let exit = script.lastExit else { return ("Stopped", "Never run", false) }
            let summary = exit.byUser || exit.code == 0 ? "Stopped" : exit.summary
            return (summary, "Last run \(Format.day(exit.at, now: now))", false)
        }
    }
}

/// Running is a lit dot, starting a pulsing one, stopped a hollow ring,
/// crashed a red diamond: shape and lightness, not just hue.
struct StatusDot: View {
    let phase: ScriptRuntime.Phase
    @State private var pulse = false

    var body: some View {
        Group {
            switch phase {
            case .running:
                Circle().fill(Theme.lit)
                    .frame(width: 9, height: 9)
                    .background(Circle().fill(Theme.lit.opacity(0.18)).frame(width: 15, height: 15))
            case .starting, .stopping:
                Circle().fill(Theme.lit)
                    .frame(width: 9, height: 9)
                    .opacity(pulse ? 0.25 : 0.9)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                    .onAppear { pulse = true }
                    .onDisappear { pulse = false }
            case .stopped:
                Circle().strokeBorder(Theme.unlit, lineWidth: 1.5)
                    .frame(width: 9, height: 9)
            case .crashed, .restarting:
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Theme.dangerMark)
                    .frame(width: 7.5, height: 7.5)
                    .rotationEffect(.degrees(45))
            }
        }
        .frame(width: 15, height: 15)
        .accessibilityHidden(true)
    }
}

struct PortChip: View {
    let port: UInt16

    var body: some View {
        Text(":\(String(port))")
            .font(Theme.mono(10.5, weight: .medium))
            .foregroundStyle(Theme.accentText)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.chip))
            .accessibilityLabel("port \(String(port))")
    }
}

/// The expanded part: why it's down, pid and start time, the last lines of
/// output, and what to do next.
private struct RowDetail: View {
    let script: ScriptRuntime
    let model: AppModel
    let actions: PopoverActions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if script.needsAttention, let note = script.crashNote {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dangerNote)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if script.configChangedWhileRunning {
                Text("You changed this script while it was running. Restart it to use the changes.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.accentText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            meta
            logTail
            buttons
        }
        .padding(.leading, 39)
        .padding(.trailing, 12)
        .padding(.bottom, 12)
    }

    private var meta: some View {
        HStack(spacing: 14) {
            if let pid = script.childPid ?? script.shimPid, script.hasProcess {
                metaItem("PID", String(pid), mono: true)
            }
            if let started = script.startedAt {
                metaItem("Started", Format.clock(started))
            } else if let exit = script.lastExit, let code = exit.code, !exit.byUser {
                metaItem("Code", String(code), mono: true)
            }
            if script.restartCount > 0 {
                metaItem("Restarts", String(script.restartCount))
            }
            if script.config.cwd != "~" {
                Text(script.config.cwd)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .font(.system(size: 11))
    }

    private func metaItem(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(Theme.secondary)
            Text(value).font(mono ? Theme.mono(11) : .system(size: 11)).foregroundStyle(Theme.text)
        }
    }

    private var logTail: some View {
        let lines = script.log.lines.suffix(7)
        return VStack(alignment: .leading, spacing: 0) {
            if lines.isEmpty {
                Text("No output yet")
                    .foregroundStyle(Theme.tertiary)
            }
            ForEach(lines) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(line.time).foregroundStyle(Theme.tertiary)
                    Text(line.text)
                        .foregroundStyle(color(for: line))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .font(Theme.mono(10.5))
        .lineSpacing(3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.well))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.line))
    }

    private func color(for line: DisplayLine) -> Color {
        if line.isError { return Theme.danger }
        if line.stream == .ath { return Theme.accentText }
        return Theme.text
    }

    private var buttons: some View {
        HStack(spacing: 6) {
            if script.needsAttention {
                Button("Start again") { model.start(script) }
                    .buttonStyle(PrimaryButtonStyle())
            } else if script.hasProcess {
                Button {
                    model.restart(script)
                } label: {
                    Label("Restart", systemImage: "arrow.clockwise")
                }
                .buttonStyle(SmallButtonStyle())
                .disabled(script.phase == .stopping)
            }
            Button("Open log") { actions.showLogs(script.id) }
                .buttonStyle(SmallButtonStyle())
            Button("Edit") { actions.edit(script.id) }
                .buttonStyle(SmallButtonStyle())
            if script.phase == .crashed {
                Button("Dismiss") { model.dismiss(script) }
                    .buttonStyle(SmallButtonStyle())
            } else {
                Button("Copy command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(script.config.command, forType: .string)
                }
                .buttonStyle(SmallButtonStyle())
            }
        }
    }
}
