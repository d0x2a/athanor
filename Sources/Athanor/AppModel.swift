import AppKit
import AthanorCore
import Foundation
import Observation

/// Something worth a notification.
enum ScriptEvent {
    /// Crashed and staying down: restart is off, or it gave up.
    case down(ScriptRuntime)
    case restarting(ScriptRuntime, attempt: Int)
    /// Exited with code 0 on its own.
    case finished(ScriptRuntime)
}

/// The scripts and their processes.
///
/// Each running script has an athanor-shim in its own session between it and
/// the app. Starting a script spawns a shim; stopping one sends the shim
/// SIGTERM. Because shims don't depend on the app, quitting Athanor can leave
/// scripts running, and the next launch finds them again through the status
/// file each shim writes.
@MainActor @Observable
final class AppModel {
    let paths: AthanorPaths
    let settings: AppSettings
    private(set) var scripts: [ScriptRuntime] = []
    /// scripts.toml couldn't be read; the scripts from the last good read stay.
    private(set) var fileError: String?

    @ObservationIgnored var onEvent: ((ScriptEvent) -> Void)?
    /// Off for `--snapshot`, which only looks: it never starts, stops or
    /// restarts anything.
    @ObservationIgnored private var supervising = true
    @ObservationIgnored private var loginEnvironment: [String: String]?
    @ObservationIgnored private var loginEnvironmentReady = false
    @ObservationIgnored private var waitingForEnvironment: Set<String> = []
    @ObservationIgnored private var fileStamp: FileStamp?
    /// A change seen once; it's read when it's still the same a poll later.
    @ObservationIgnored private var pendingStamp: FileStamp?
    /// Removed from the list while running: kept until their shims exit, so
    /// the exit is still handled (and the shim reaped).
    @ObservationIgnored private var retiring: [ScriptRuntime] = []
    /// Deleted while running: their run-state file goes once they've exited.
    @ObservationIgnored private var deletedIDs: Set<String> = []
    @ObservationIgnored private let sampler = ProcSampler()
    @ObservationIgnored private let sampleQueue = DispatchQueue(label: "athanor.sample", qos: .utility)
    @ObservationIgnored private var sampleTick = 0
    @ObservationIgnored private var timers: [Timer] = []
    @ObservationIgnored private lazy var tailer = LogTailer { [weak self] batch in
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self?.receive(batch) }
        }
    }

    init(paths: AthanorPaths, settings: AppSettings) {
        self.paths = paths
        self.settings = settings
    }

    /// The shim ships next to the app's executable, in a bundle and in .build alike.
    private var shimPath: String {
        Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("athanor-shim").path
    }

    // MARK: Start-up

    func bootstrap(supervise: Bool = true) {
        supervising = supervise
        for folder in [paths.logsDir, paths.runDir] {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        tailer.start()
        loadFile()
        resolveLoginEnvironment()
        for script in scripts where supervise && script.config.autostart && script.canStart {
            start(script)
        }
        schedule(every: 1) { $0.loadFile() }
        schedule(every: 2) { $0.sampleProcesses() }
    }

    private func schedule(every interval: TimeInterval, _ action: @escaping (AppModel) -> Void) {
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self { action(self) }
            }
        }
        timer.tolerance = interval / 5
        RunLoop.main.add(timer, forMode: .common)
        timers.append(timer)
    }

    private func resolveLoginEnvironment() {
        Task { [weak self] in
            let environment = await Task.detached(priority: .userInitiated) { LoginEnvironment.capture() }.value
            self?.loginEnvironmentResolved(environment)
        }
    }

    private func loginEnvironmentResolved(_ environment: [String: String]?) {
        loginEnvironment = environment
        loginEnvironmentReady = true
        let waiting = scripts.filter { waitingForEnvironment.contains($0.id) }
        waitingForEnvironment.removeAll()
        for script in waiting where script.phase == .starting && script.shimPid == nil {
            launch(script)
        }
    }

    // MARK: Summary

    var glyphState: GlyphState {
        if scripts.contains(where: { $0.phase == .crashed }) { return .attention }
        if scripts.contains(where: \.hasProcess) { return .running }
        return .idle
    }

    var runningCount: Int {
        scripts.filter(\.hasProcess).count
    }

    var hasActiveScripts: Bool {
        scripts.contains(where: \.hasProcess)
    }

    /// "1 crashed · 2 running · 2 stopped".
    var summaryParts: (crashed: Int, running: Int, stopped: Int) {
        let crashed = scripts.filter(\.needsAttention).count
        let running = runningCount
        return (crashed, running, scripts.count - crashed - running)
    }

    // MARK: scripts.toml

    struct FileStamp: Equatable {
        var inode: UInt64
        var size: Int64
        var modified: timespec

        init?(_ url: URL) {
            var info = stat()
            guard stat(url.path, &info) == 0 else { return nil }
            inode = UInt64(info.st_ino)
            size = Int64(info.st_size)
            modified = info.st_mtimespec
        }

        static func == (a: FileStamp, b: FileStamp) -> Bool {
            a.inode == b.inode && a.size == b.size
                && a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec
        }
    }

    /// Reads scripts.toml if it changed.
    ///
    /// A file mid-save can be missing, empty or half written, and reading it
    /// then would stop every script. So a change is read only once it has
    /// held still for a poll, a missing file is ignored once there have been
    /// scripts, and so is an empty one. `now` skips the wait, for the app's
    /// own saves.
    func loadFile(now: Bool = false) {
        let url = paths.scriptsFile
        guard let stamp = FileStamp(url) else {
            if fileStamp == nil, scripts.isEmpty { fileError = nil }
            return
        }
        guard stamp != fileStamp else {
            pendingStamp = nil
            return
        }
        if !now, fileStamp != nil, stamp != pendingStamp {
            pendingStamp = stamp
            return
        }
        pendingStamp = nil
        fileStamp = stamp
        if stamp.size == 0, !scripts.isEmpty { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let configs = try ScriptsFile.decode(text)
            fileError = nil
            apply(configs)
        } catch {
            fileError = "\(error)"
        }
    }

    private func apply(_ configs: [ScriptConfig]) {
        var existing = Dictionary(uniqueKeysWithValues: scripts.map { ($0.id, $0) })
        var next: [ScriptRuntime] = []
        for config in configs {
            if let script = existing.removeValue(forKey: config.id) {
                if script.config != config {
                    if script.hasProcess, let launched = script.launchedConfig, !Self.runsTheSame(launched, config) {
                        script.configChangedWhileRunning = true
                    }
                    script.config = config
                    script.policy.limit = config.restartLimit
                    script.policy.window = TimeInterval(config.restartWindow)
                }
                next.append(script)
            } else {
                let script = ScriptRuntime(config: config)
                next.append(script)
                adopt(script)
            }
        }
        // Gone from the file: stop what's still running.
        for script in existing.values {
            if script.hasProcess { retiring.append(script) }
            stop(script)
            tailer.stop(script.id)
        }
        scripts = next
    }

    /// Changes that only take effect on the next start.
    private static func runsTheSame(_ a: ScriptConfig, _ b: ScriptConfig) -> Bool {
        a.command == b.command && a.cwd == b.cwd && a.env == b.env
            && a.useLoginEnvironment == b.useLoginEnvironment && a.stopSignal == b.stopSignal
            && a.stopTimeout == b.stopTimeout
    }

    /// Adds or replaces one script in scripts.toml.
    func save(_ config: ScriptConfig) throws {
        try edit(id: config.id, to: config)
    }

    func delete(_ id: String) throws {
        let wasRunning = script(id)?.hasProcess == true
        try edit(id: id, to: nil)
        if wasRunning {
            deletedIDs.insert(id)
        } else {
            try? FileManager.default.removeItem(at: paths.statusFile(for: id))
        }
    }

    /// Edits the file as it is on disk now, not as last read, so a hand edit
    /// from the last second isn't lost; and only the one script's lines, so
    /// comments and keys Athanor doesn't know stay. Refuses while the file
    /// doesn't parse, rather than overwrite the edit in progress.
    private func edit(id: String, to config: ScriptConfig?) throws {
        // Through a symlink (scripts.toml kept in a dotfiles repo), to its target.
        let url = paths.scriptsFile.resolvingSymlinksInPath()
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let updated: String
        if existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updated = ScriptsFile.encode(config.map { [$0] } ?? [])
        } else {
            let current: [ScriptConfig]
            do {
                current = try ScriptsFile.decode(existing)
            } catch {
                throw ScriptsFileError("scripts.toml has a mistake (\(error)). Fix it in the file first, so your edits there aren’t lost.")
            }
            if let spliced = ScriptsFile.editing(existing, id: id, to: config) {
                updated = spliced
            } else {
                // Can't edit just the one script: write the file anew, after
                // keeping a copy of the hand-written one.
                var list = current
                if let index = list.firstIndex(where: { $0.id == id }) {
                    if let config { list[index] = config } else { list.remove(at: index) }
                } else if let config {
                    list.append(config)
                }
                try existing.write(to: url.deletingLastPathComponent().appendingPathComponent("scripts.toml.bak"),
                                   atomically: true, encoding: .utf8)
                updated = ScriptsFile.encode(list)
            }
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try updated.write(to: url, atomically: true, encoding: .utf8)
        fileStamp = nil
        loadFile(now: true)
    }

    // MARK: Picking up scripts that kept running

    private func adopt(_ script: ScriptRuntime) {
        tailer.follow(script.id, url: paths.logFile(for: script.id))
        guard let status = ShimStatus.read(paths.statusFile(for: script.id)) else { return }
        if !status.hasEnded, isLiveShim(status) {
            script.shimPid = status.shimPid
            script.childPid = status.childPid
            script.startedAt = Date(timeIntervalSince1970: status.startedAt)
            script.isOurChild = false
            script.launchedConfig = script.config
            script.phase = .starting
            watchExit(script)
            checkReadiness(script)
        } else if status.hasEnded {
            script.lastExit = ExitRecord(status: status, byUser: status.stopRequested == true)
        } else {
            // The shim went without recording an end: killed with the rest
            // of the session at a restart or log out, or killed on its own,
            // in which case its script may still be running. Count it as stopped.
            endOrphanedGroup(status.childPid, startedAt: status.startedAt)
            let modified = (try? paths.statusFile(for: script.id).resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date()
            script.lastExit = ExitRecord(code: nil, signal: nil, at: modified, byUser: true)
        }
    }

    private func isLiveShim(_ status: ShimStatus) -> Bool {
        isShim(status.shimPid, startedAt: status.startedAt)
    }

    /// The pid is a shim, and the same one: started when it should have been,
    /// not a later process that was given the same pid. Goes by name, not
    /// path: a shim whose app was updated, moved or deleted has no path.
    private func isShim(_ pid: pid_t, startedAt: Double) -> Bool {
        guard ProcTree.exists(pid), ProcTree.name(pid) == "athanor-shim" else { return false }
        if let started = ProcTree.startTime(pid), abs(started - startedAt) > 5 { return false }
        return true
    }

    /// A shim died without stopping its script, whose group may still be
    /// running unwatched. Ends it, if the group leader is still the process
    /// the shim started (pids get reused, after a restart especially).
    private func endOrphanedGroup(_ leader: pid_t?, startedAt: Double?) {
        guard let leader, leader > 1, kill(-leader, 0) == 0 else { return }
        if let leaderStart = ProcTree.startTime(leader) {
            guard let startedAt, abs(leaderStart - startedAt) < 10 else { return }
        } else if startedAt == nil {
            return
        }
        kill(-leader, SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if kill(-leader, 0) == 0 { kill(-leader, SIGKILL) }
        }
    }

    // MARK: Starting and stopping

    /// Start by hand: forgets earlier crashes.
    func start(_ script: ScriptRuntime) {
        script.policy.reset()
        script.restartCount = 0
        script.crashNote = nil
        launch(script)
    }

    func stop(_ script: ScriptRuntime) {
        guard supervising else { return }
        script.restartWork?.cancel()
        script.restartWork = nil
        script.startAfterStop = false
        waitingForEnvironment.remove(script.id)
        guard script.hasProcess, let pid = script.shimPid else {
            if script.phase != .stopped { script.phase = .stopped }
            return
        }
        guard script.phase != .stopping else { return }
        script.stopRequested = true
        script.phase = .stopping
        script.readinessTask?.cancel()
        kill(pid, SIGTERM)
        // The shim sends SIGKILL itself after the timeout. If the shim is the
        // one that's stuck, end both here a little later.
        let grace = Double(script.launchedConfig?.stopTimeout ?? script.config.stopTimeout) + 5
        let work = DispatchWorkItem { [weak self, weak script] in
            MainActor.assumeIsolated {
                guard let self, let script, script.phase == .stopping, let pid = script.shimPid else { return }
                if let child = script.childPid ?? ShimStatus.read(self.paths.statusFile(for: script.id))?.childPid {
                    kill(-child, SIGKILL)
                }
                kill(pid, SIGKILL)
                self.checkExit(script)
            }
        }
        script.killWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + grace, execute: work)
    }

    func restart(_ script: ScriptRuntime) {
        if script.hasProcess {
            script.policy.reset()
            script.restartCount = 0
            script.crashNote = nil
            stop(script)
            script.startAfterStop = true
        } else {
            start(script)
        }
    }

    func startAll() {
        for script in scripts where script.canStart { start(script) }
    }

    func stopAll() {
        for script in scripts { stop(script) }
    }

    /// Stops everything and calls back once all of it has exited, or once the
    /// longest stop timeout has run out.
    func stopAll(then completion: @escaping () -> Void) {
        let active = scripts.filter(\.hasProcess)
        guard !active.isEmpty else { return completion() }
        active.forEach(stop)
        let longest = active.map { Double($0.launchedConfig?.stopTimeout ?? 10) }.max() ?? 10
        let deadline = Date() + longest + 3
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                let busy = self?.scripts.contains(where: \.hasProcess) ?? false
                if !busy || Date() > deadline {
                    timer.invalidate()
                    completion()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func launch(_ script: ScriptRuntime) {
        guard supervising else { return }
        script.restartWork?.cancel()
        script.restartWork = nil
        guard !script.hasProcess else { return }
        // A script deleted and re-added under the same id while its old run is
        // still stopping: the two would share a log and a run-state file.
        if retiring.contains(where: { $0.id == script.id && $0 !== script }) {
            script.phase = .starting
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak script] in
                MainActor.assumeIsolated {
                    guard let self, let script, script.phase == .starting, script.shimPid == nil else { return }
                    self.launch(script)
                }
            }
            return
        }
        let config = script.config
        if config.useLoginEnvironment, !loginEnvironmentReady {
            // Starts once the login shell has answered; until then it shows as starting.
            script.phase = .starting
            waitingForEnvironment.insert(script.id)
            return
        }
        let statusURL = paths.statusFile(for: config.id)
        try? FileManager.default.removeItem(at: statusURL)
        do {
            for folder in [paths.logsDir, paths.runDir] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            let pid = try Spawn.spawn(
                shimPath,
                arguments: [
                    "--id", config.id,
                    "--log", paths.logFile(for: config.id).path,
                    "--status", statusURL.path,
                    "--cwd", config.cwd,
                    "--signal", config.stopSignal.rawValue,
                    "--timeout", String(config.stopTimeout),
                    "--log-cap", String(settings.logCapBytes),
                    "--", config.command,
                ],
                environment: environment(for: config),
                newSession: true
            )
            script.shimPid = pid
            script.childPid = nil
            script.isOurChild = true
            script.startedAt = Date()
            script.launchedConfig = config
            script.configChangedWhileRunning = false
            script.stopRequested = false
            script.sample = nil
            script.cpuHistory = []
            script.memoryHistory = []
            script.phase = .starting
            tailer.follow(config.id, url: paths.logFile(for: config.id))
            watchExit(script)
            checkReadiness(script)
        } catch {
            script.phase = .crashed
            script.lastExit = ExitRecord(code: nil, signal: nil, at: Date(), byUser: false, failure: "\(error)")
            script.crashNote = "Athanor couldn't start it: \(error)."
        }
    }

    private func environment(for config: ScriptConfig) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in ["__CFBundleIdentifier", "XPC_SERVICE_NAME", "XPC_FLAGS", "OS_ACTIVITY_DT_MODE"] {
            environment[key] = nil
        }
        if config.useLoginEnvironment, let login = loginEnvironment {
            environment.merge(login) { _, login in login }
        } else {
            environment["PATH"] = LoginEnvironment.fallbackPath(environment["PATH"])
        }
        if environment["LANG"] == nil { environment["LANG"] = "en_US.UTF-8" }
        for variable in config.env where !variable.key.isEmpty {
            environment[variable.key] = variable.value
        }
        environment["ATHANOR_SCRIPT"] = config.id
        return environment
    }

    // MARK: Exits

    private func watchExit(_ script: ScriptRuntime) {
        guard let pid = script.shimPid else { return }
        script.exitSource?.cancel()
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self, weak script] in
            MainActor.assumeIsolated {
                guard let self, let script else { return }
                self.checkExit(script)
            }
        }
        source.resume()
        script.exitSource = source
        checkExit(script)
    }

    /// Whether the shim has gone; if it has, deals with how the script ended.
    private func checkExit(_ script: ScriptRuntime) {
        guard let pid = script.shimPid else { return }
        if script.isOurChild {
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == 0 { return }
        } else if isShim(pid, startedAt: script.startedAt?.timeIntervalSince1970 ?? 0) {
            return
        }
        shimExited(script)
    }

    private func shimExited(_ script: ScriptRuntime) {
        script.exitSource?.cancel()
        script.exitSource = nil
        script.killWork?.cancel()
        script.killWork = nil
        script.readinessTask?.cancel()
        retiring.removeAll { $0 === script }
        let status = ShimStatus.read(paths.statusFile(for: script.id))
        if status?.hasEnded != true {
            endOrphanedGroup(status?.childPid ?? script.childPid,
                             startedAt: status?.startedAt ?? script.startedAt?.timeIntervalSince1970)
        }
        let byUser = script.stopRequested || status?.stopRequested == true
        let record = ExitRecord(status: status, byUser: byUser)
        script.lastExit = record
        script.shimPid = nil
        script.childPid = nil
        script.sample = nil
        script.startedAt = nil
        script.stopRequested = false

        if script.startAfterStop {
            script.startAfterStop = false
            launch(script)
            return
        }
        guard scripts.contains(where: { $0 === script }) else {
            script.phase = .stopped
            if deletedIDs.remove(script.id) != nil, self.script(script.id) == nil {
                try? FileManager.default.removeItem(at: paths.statusFile(for: script.id))
            }
            return
        }
        guard record.crashed else {
            script.phase = .stopped
            if !byUser { onEvent?(.finished(script)) }
            return
        }
        guard script.config.restartOnCrash else {
            script.phase = .crashed
            script.crashNote = "\(record.summary). Restart after a crash is off for this script."
            onEvent?(.down(script))
            return
        }
        switch script.policy.crashed(at: Date()) {
        case .restart(let attempt, let delay):
            script.restartCount += 1
            script.phase = .restarting(at: Date() + delay)
            note(script, "restart \(attempt) of \(script.config.restartLimit) in \(Int(delay)) s")
            onEvent?(.restarting(script, attempt: attempt))
            let work = DispatchWorkItem { [weak self, weak script] in
                MainActor.assumeIsolated {
                    guard let self, let script, script.isRestarting else { return }
                    self.launch(script)
                }
            }
            script.restartWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        case .giveUp(let crashes, let span):
            script.phase = .crashed
            if crashes <= 1 {
                script.crashNote = "\(record.summary). Its restart limit is 0, so it stays down."
            } else {
                script.crashNote = "Crashed \(crashes) times in \(Self.spanText(span)). Auto-restart is paused until you start it again."
                note(script, "gave up after \(crashes - 1) restarts · auto-restart paused")
            }
            onEvent?(.down(script))
        }
    }

    private static func spanText(_ seconds: TimeInterval) -> String {
        if seconds < 90 { return "\(max(1, Int(seconds.rounded()))) seconds" }
        if seconds < 5400 { return "\(Int((seconds / 60).rounded())) minutes" }
        return "\(Int((seconds / 3600).rounded())) hours"
    }

    /// Takes a crashed script off the attention list without starting it.
    func dismiss(_ script: ScriptRuntime) {
        script.restartWork?.cancel()
        script.restartWork = nil
        script.crashNote = nil
        script.phase = .stopped
    }

    private func note(_ script: ScriptRuntime, _ text: String) {
        LogFormat.appendAthanorLine(text, to: paths.logFile(for: script.id))
    }

    // MARK: Readiness

    private func checkReadiness(_ script: ScriptRuntime) {
        script.readinessTask?.cancel()
        switch script.config.ready {
        case .started:
            if script.phase == .starting { script.phase = .running }
        case .port(let port):
            script.readinessTask = Task { [weak self, weak script] in
                while !Task.isCancelled {
                    let open = await Task.detached { PortProbe.isOpen(port) }.value
                    guard let self, let script, !Task.isCancelled, script.phase == .starting else { return }
                    if open {
                        script.phase = .running
                        self.note(script, "ready · port \(port) is open")
                        return
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        case .url(let text):
            guard let url = URL(string: text) else {
                script.phase = .running
                return
            }
            script.readinessTask = Task { [weak self, weak script] in
                while !Task.isCancelled {
                    var request = URLRequest(url: url, timeoutInterval: 2)
                    request.cachePolicy = .reloadIgnoringLocalCacheData
                    let answered = (try? await URLSession.shared.data(for: request))?.1 is HTTPURLResponse
                    guard let self, let script, !Task.isCancelled, script.phase == .starting else { return }
                    if answered {
                        script.phase = .running
                        self.note(script, "ready · \(text) answers")
                        return
                    }
                    try? await Task.sleep(for: .seconds(1.5))
                }
            }
        }
    }

    // MARK: Sampling

    private func sampleProcesses() {
        for script in scripts + retiring where script.hasProcess {
            checkExit(script)
        }
        let roots: [ProcSampler.Root] = scripts.compactMap { script in
            guard script.hasProcess, let pid = script.shimPid else { return nil }
            if script.childPid == nil {
                script.childPid = ShimStatus.read(paths.statusFile(for: script.id))?.childPid
            }
            return ProcSampler.Root(id: script.id, pid: pid, group: script.childPid)
        }
        guard !roots.isEmpty else { return }
        sampleTick += 1
        let withPorts = sampleTick % 2 == 1
        let sampler = self.sampler
        sampleQueue.async {
            let results = sampler.sample(roots, ports: withPorts)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.receive(results, withPorts: withPorts) }
            }
        }
    }

    private func receive(_ results: [String: ProcSample], withPorts: Bool) {
        let keep = 900 // 30 minutes at one sample every 2 s
        for script in scripts where script.hasProcess {
            guard var sample = results[script.id] else { continue }
            if !withPorts { sample.ports = script.sample?.ports ?? [] }
            script.sample = sample
            script.cpuHistory.append(sample.cpuPercent)
            script.memoryHistory.append(Double(sample.memoryBytes))
            if script.cpuHistory.count > keep { script.cpuHistory.removeFirst(script.cpuHistory.count - keep) }
            if script.memoryHistory.count > keep { script.memoryHistory.removeFirst(script.memoryHistory.count - keep) }
        }
    }

    private func receive(_ batch: [String: [LogLine]]) {
        for script in scripts {
            if let lines = batch[script.id] { script.log.append(lines) }
        }
    }

    // MARK: Lookups

    func script(_ id: String) -> ScriptRuntime? {
        scripts.first { $0.id == id }
    }

    func logFileSize(_ id: String) -> UInt64 {
        var info = stat()
        guard stat(paths.logFile(for: id).path, &info) == 0 else { return 0 }
        return UInt64(max(0, info.st_size))
    }
}
