import AthanorCore
import Foundation
import Observation

/// How a script's last run ended.
struct ExitRecord: Equatable {
    var code: Int32?
    var signal: Int32?
    var at: Date
    var byUser: Bool
    /// Why it never started, when it didn't.
    var failure: String?

    init(code: Int32?, signal: Int32?, at: Date, byUser: Bool, failure: String? = nil) {
        self.code = code
        self.signal = signal
        self.at = at
        self.byUser = byUser
        self.failure = failure
    }

    init(status: ShimStatus?, byUser: Bool) {
        let ended = status?.endedAt.map { Date(timeIntervalSince1970: $0) } ?? Date()
        if let status, status.hasEnded {
            self.init(code: status.exitCode, signal: status.signal, at: ended, byUser: byUser, failure: status.failure)
        } else {
            // The shim went without writing how the script ended: it was killed.
            self.init(code: nil, signal: byUser ? SIGKILL : nil, at: ended, byUser: byUser,
                      failure: byUser ? nil : "Athanor's helper process quit unexpectedly")
        }
    }

    /// Ended on its own, and not cleanly.
    var crashed: Bool {
        !byUser && !(code == 0 && signal == nil && failure == nil)
    }

    /// "Exited 255", "Killed · SIGKILL", "Couldn't start", "Stopped", "Finished".
    var summary: String {
        if failure != nil { return "Couldn't start" }
        if byUser { return "Stopped" }
        if let signal { return "Killed · \(ExitDescription.signalName(signal))" }
        if code == 0 { return "Finished" }
        return "Exited \(code ?? -1)"
    }
}

/// One script: its settings from scripts.toml and everything Athanor knows
/// about its current run.
@MainActor @Observable
final class ScriptRuntime: Identifiable {
    enum Phase: Equatable {
        /// Not running: never started, stopped, or finished cleanly.
        case stopped
        /// Running, not yet ready (its port isn't open yet, say).
        case starting
        case running
        case stopping
        /// Crashed; Athanor starts it again at this time.
        case restarting(at: Date)
        /// Crashed and staying down until started by hand.
        case crashed
    }

    let id: String
    var config: ScriptConfig
    var phase = Phase.stopped
    var shimPid: pid_t?
    var childPid: pid_t?
    var startedAt: Date?
    var lastExit: ExitRecord?
    /// Automatic restarts since it was last started by hand.
    var restartCount = 0
    /// Says why it's down, after a crash.
    var crashNote: String?
    var sample: ProcSample?
    var cpuHistory: [Double] = []
    var memoryHistory: [Double] = []
    /// scripts.toml changed how it runs while it was running.
    var configChangedWhileRunning = false
    let log = LogBuffer()

    @ObservationIgnored var policy: RestartPolicy
    @ObservationIgnored var stopRequested = false
    @ObservationIgnored var startAfterStop = false
    @ObservationIgnored var isOurChild = false
    @ObservationIgnored var launchedConfig: ScriptConfig?
    @ObservationIgnored var exitSource: DispatchSourceProcess?
    @ObservationIgnored var restartWork: DispatchWorkItem?
    @ObservationIgnored var killWork: DispatchWorkItem?
    @ObservationIgnored var readinessTask: Task<Void, Never>?

    init(config: ScriptConfig) {
        id = config.id
        self.config = config
        policy = RestartPolicy(limit: config.restartLimit, window: TimeInterval(config.restartWindow))
    }

    /// Its process exists: starting, running or stopping.
    var hasProcess: Bool {
        switch phase {
        case .starting, .running, .stopping: shimPid != nil
        default: false
        }
    }

    var isRestarting: Bool {
        if case .restarting = phase { return true }
        return false
    }

    /// Crashed, whether or not a restart is coming: sorts to the top.
    var needsAttention: Bool {
        phase == .crashed || isRestarting
    }

    var canStart: Bool {
        switch phase {
        case .stopped, .crashed, .restarting: true
        default: false
        }
    }
}

/// One line as the log views show it.
struct DisplayLine: Identifiable, Equatable {
    let id: Int
    let time: String
    let stream: LogStream
    let text: String
    let isError: Bool
}

/// The last few thousand lines of a script's log, in memory.
@MainActor @Observable
final class LogBuffer {
    private(set) var lines: [DisplayLine] = []
    @ObservationIgnored private var nextID = 0
    private let limit = 5000

    func append(_ new: [LogLine]) {
        guard !new.isEmpty else { return }
        var added: [DisplayLine] = []
        added.reserveCapacity(new.count)
        for line in new {
            added.append(DisplayLine(id: nextID, time: line.clockTime, stream: line.stream, text: line.text,
                                     isError: Self.isError(line)))
            nextID += 1
        }
        var all = lines + added
        // Trimmed a thousand at a time: the log view redraws from scratch when
        // the first line changes, and shouldn't on every new line.
        if all.count > limit + 1000 { all.removeFirst(all.count - limit) }
        lines = all
    }

    func clear() {
        lines = []
    }

    private static func isError(_ line: LogLine) -> Bool {
        guard line.stream == .ath else { return LogFormat.looksLikeError(line.text) }
        let text = line.text
        return text.hasPrefix("killed") || text.hasPrefix("gave up") || text.hasPrefix("couldn't")
            || text.hasPrefix("still running") || (text.hasPrefix("exited · code") && !text.hasSuffix("code 0"))
    }
}
