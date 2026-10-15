import AthanorCore
import Foundation

// athanor-shim: runs one script for Athanor.
//
//   athanor-shim --id ID --log FILE --status FILE --cwd DIR
//                [--signal TERM] [--timeout 10] [--log-cap BYTES] [--lifeline]
//                [--outside] -- COMMAND
//
// Athanor starts one per script, in a session of its own, so it outlives the
// app. It runs COMMAND with /bin/sh -c in a new process group, timestamps every
// line the script prints into the log, and records the pids and how the script
// ended in the status file. On SIGTERM, SIGINT or SIGHUP it stops the script's
// whole group with --signal, then SIGKILL after --timeout seconds, and exits
// once the script has.
//
// With --lifeline, standard input is a pipe whose other end Athanor holds, and
// the shim stops its script when that pipe closes: when Athanor exits, however
// it exits. The App Store build uses it, since in the App Sandbox the next
// copy of Athanor couldn't signal this shim to stop it.
//
// With --outside, the script is already running, outside the App Sandbox:
// Athanor started it through athanor-runner (Resources/AppStore), and hands
// the shim the runner's socket as fd 3 and the script's output and errors as
// fds 4 and 5. The shim can't signal anything outside the sandbox, so it asks
// the runner to, and learns the script's pid and exit from it.

struct Options {
    var id = ""
    var logPath = ""
    var statusPath = ""
    var cwd = "~"
    var command = ""
    var stopSignal = SIGTERM
    var stopTimeout = 10.0
    var logCap: Int64 = 10 * 1024 * 1024
    var lifeline = false
    var outside = false

    static func parse(_ arguments: [String]) -> Options? {
        var options = Options()
        var index = 1
        while index < arguments.count {
            let flag = arguments[index]
            if flag == "--" {
                options.command = arguments[(index + 1)...].joined(separator: " ")
                break
            }
            if flag == "--lifeline" || flag == "--outside" {
                if flag == "--lifeline" { options.lifeline = true } else { options.outside = true }
                index += 1
                continue
            }
            guard index + 1 < arguments.count else { return nil }
            let value = arguments[index + 1]
            switch flag {
            case "--id": options.id = value
            case "--log": options.logPath = value
            case "--status": options.statusPath = value
            case "--cwd": options.cwd = value
            case "--signal":
                guard let signal = StopSignal(name: value) else { return nil }
                options.stopSignal = signal.number
            case "--timeout":
                guard let seconds = Double(value), seconds > 0 else { return nil }
                options.stopTimeout = seconds
            case "--log-cap":
                guard let bytes = Int64(value), bytes > 0 else { return nil }
                options.logCap = bytes
            default:
                return nil
            }
            index += 2
        }
        guard !options.logPath.isEmpty, !options.statusPath.isEmpty, !options.command.isEmpty else { return nil }
        return options
    }
}

/// Everything here runs on `queue`, which is what makes the unchecked
/// Sendable true.
final class Shim: @unchecked Sendable {
    private let queue = DispatchQueue(label: "athanor.shim")
    private let options: Options
    private let log: LogWriter
    private var status: ShimStatus
    private var childPid: pid_t = 0
    private var readers: [Int32: (source: DispatchSourceRead, stream: LogStream)] = [:]
    private var splitters: [Int32: LineSplitter] = [:]
    private var keepAlive: [AnyObject] = []
    private var stopping = false
    private var stopRequestedAt: Date?
    private var finished = false
    /// With --outside: what the runner has sent that isn't a whole line yet.
    private var controlBuffer = Data()

    init(options: Options) {
        self.options = options
        log = LogWriter(path: options.logPath, cap: options.logCap)
        status = ShimStatus(shimPid: getpid(), startedAt: Date().timeIntervalSince1970)
    }

    func run() -> Never {
        // Before anything else, so a stop that arrives early is caught, not fatal.
        for signal in [SIGTERM, SIGINT, SIGHUP] {
            Darwin.signal(signal, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signal, queue: queue)
            source.setEventHandler { [self] in stop() }
            source.resume()
            keepAlive.append(source)
        }
        Darwin.signal(SIGPIPE, SIG_IGN)
        if options.lifeline { watchLifeline() }
        queue.async { [self] in start() }
        dispatchMain()
    }

    private func start() {
        // First thing, so Athanor can find this shim from here on.
        writeStatus()
        if options.outside { return startOutside() }
        let folder = expandTilde(options.cwd)
        guard chdir(folder) == 0 else {
            fail("couldn't open the folder \(options.cwd): \(String(cString: strerror(errno)))", code: 126)
        }
        var outPipe: [Int32] = [0, 0]
        var errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0, pipe(&errPipe) == 0 else {
            fail("couldn't make pipes: \(String(cString: strerror(errno)))", code: 126)
        }
        for fd in [outPipe[0], errPipe[0]] {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }
        do {
            childPid = try Spawn.spawn(
                "/bin/sh",
                arguments: ["-c", options.command],
                environment: ProcessInfo.processInfo.environment,
                stdout: outPipe[1],
                stderr: errPipe[1],
                newProcessGroup: true
            )
        } catch {
            fail("\(error)", code: 127)
        }
        close(outPipe[1])
        close(errPipe[1])

        status.childPid = childPid
        writeStatus()
        log.write(.ath, "started · pid \(childPid) · \(abbreviateHome(folder))")

        watch(outPipe[0], .out)
        watch(errPipe[0], .err)

        let exitSource = DispatchSource.makeProcessSource(identifier: childPid, eventMask: .exit, queue: queue)
        exitSource.setEventHandler { [self] in reap() }
        exitSource.resume()
        keepAlive.append(exitSource)

        // Once a second: write out a line that's been waiting for its line
        // break (a prompt), and catch an exit if the event was missed.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [self] in
            flushStaleLines()
            reap()
        }
        timer.resume()
        keepAlive.append(timer)

        if stopping { sendStopSignal() }
        reap()
    }

    private func startOutside() {
        for fd: Int32 in [3, 4, 5] {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }
        // The output is read from "started" on, so the log opens with that line.
        let source = DispatchSource.makeReadSource(fileDescriptor: 3, queue: queue)
        source.setEventHandler { [self, weak source] in
            if !readControl() { source?.cancel() }
        }
        source.resume()
        keepAlive.append(source)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [self] in flushStaleLines() }
        timer.resume()
        keepAlive.append(timer)
    }

    /// Acts on whole lines from the runner. False once it has gone.
    private func readControl() -> Bool {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(3, &buffer, buffer.count)
            if count > 0 {
                controlBuffer.append(contentsOf: buffer[0..<count])
                while let newline = controlBuffer.firstIndex(of: 10) {
                    let line = String(decoding: controlBuffer[controlBuffer.startIndex..<newline], as: UTF8.self)
                    controlBuffer.removeSubrange(controlBuffer.startIndex...newline)
                    handleControl(line)
                }
                continue
            }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN { return true }
            runnerGone()
            return false
        }
    }

    private func handleControl(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
        switch parts.first {
        case "started":
            guard parts.count >= 2, let pid = pid_t(parts[1]), pid > 0 else { return }
            childPid = pid
            status.childPid = pid
            writeStatus()
            log.write(.ath, "started · pid \(pid) · \(parts.count > 2 ? parts[2] : options.cwd)")
            watch(4, .out)
            watch(5, .err)
            if stopping { sendStopSignal() }
        case "failed":
            fail(String(line.dropFirst("failed ".count)), code: 126)
        case "exited":
            guard !finished, parts.count >= 2, let code = Int32(parts[1]) else { return }
            // From bash's `wait`: 128 + the signal, for a script a signal ended.
            if code > 128, code - 128 < NSIG {
                finish(code: nil, signal: code - 128)
            } else {
                finish(code: code, signal: nil)
            }
        default:
            break
        }
    }

    /// The runner closed its end without saying how the script ended.
    private func runnerGone() {
        guard !finished else { return }
        if childPid == 0 {
            fail("Athanor’s runner didn’t start the script", code: 127)
        }
        log.write(.ath, "Athanor’s runner quit unexpectedly")
        finish(code: nil, signal: SIGKILL)
    }

    /// The whole group: with kill, or by asking the runner.
    private func signalGroup(_ signal: Int32) {
        guard childPid > 0 else { return }
        if options.outside {
            let name = ExitDescription.signalName(signal).replacingOccurrences(of: "SIG", with: "")
            RunnerSocket.write(Array("signal \(name)\n".utf8), to: 3)
        } else {
            kill(-childPid, signal)
        }
    }

    /// Something is left in the group. Outside the sandbox kill can only
    /// say the group exists (EPERM), not signal it.
    private func groupExists() -> Bool {
        kill(-childPid, 0) == 0 || (options.outside && errno == EPERM)
    }

    // MARK: Output

    private func watch(_ fd: Int32, _ stream: LogStream) {
        splitters[fd] = LineSplitter()
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [self] in drain(fd) }
        source.setCancelHandler { close(fd) }
        readers[fd] = (source, stream)
        source.resume()
    }

    /// Reads what the pipe holds, stopping when it would block; closes it at
    /// end of file.
    private func drain(_ fd: Int32) {
        guard let reader = readers[fd] else { return }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                for line in splitters[fd]!.feed(buffer[0..<count], now: now) {
                    log.write(reader.stream, line)
                }
            } else if count == 0 {
                if let line = splitters[fd]!.flush() { log.write(reader.stream, line) }
                readers[fd] = nil
                reader.source.cancel()
                return
            } else if errno != EINTR {
                return
            }
        }
    }

    private func flushStaleLines() {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        for (fd, reader) in readers {
            guard splitters[fd]!.hasPartialLine,
                  now - splitters[fd]!.lastInputAt > 1_000_000_000,
                  let line = splitters[fd]!.flush() else { continue }
            log.write(reader.stream, line)
        }
    }

    // MARK: Stopping

    /// Athanor never writes to the pipe: anything that ends the wait is
    /// end of file, or an error that counts as one.
    private func watchLifeline() {
        _ = fcntl(STDIN_FILENO, F_SETFL, fcntl(STDIN_FILENO, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: queue)
        source.setEventHandler { [self, weak source] in
            var byte: UInt8 = 0
            let count = read(STDIN_FILENO, &byte, 1)
            if count > 0 || (count < 0 && (errno == EAGAIN || errno == EINTR)) { return }
            source?.cancel()
            guard !stopping, !finished else { return }
            log.write(.ath, "Athanor quit · stopping")
            stop()
        }
        source.resume()
        keepAlive.append(source)
    }

    private func stop() {
        guard !stopping, !finished else { return }
        stopping = true
        stopRequestedAt = Date()
        status.stopRequested = true
        if childPid > 0 {
            writeStatus()
            sendStopSignal()
        }
    }

    private func sendStopSignal() {
        signalGroup(options.stopSignal)
        queue.asyncAfter(deadline: .now() + options.stopTimeout) { [self] in
            guard !finished else { return }
            let name = ExitDescription.signalName(options.stopSignal)
            log.write(.ath, "still running \(Int(options.stopTimeout)) s after \(name) · sending SIGKILL")
            signalGroup(SIGKILL)
        }
    }

    // MARK: Exit

    private func reap() {
        guard !finished, !options.outside, childPid > 0 else { return }
        var waitStatus: Int32 = 0
        let result = waitpid(childPid, &waitStatus, WNOHANG)
        guard result == childPid else { return }
        let (code, signal) = ExitDescription.decode(waitStatus: waitStatus)
        finish(code: code, signal: signal)
    }

    private func finish(code: Int32?, signal: Int32?) {
        finished = true
        status.exitCode = code
        status.signal = signal
        // Whatever the script left running in its group goes with it: SIGTERM,
        // then SIGKILL for anything still there after a grace period (what's
        // left of the stop timeout, when stopping).
        signalGroup(SIGTERM)
        let grace = stopRequestedAt.map { max(0.5, options.stopTimeout - Date().timeIntervalSince($0)) } ?? 2
        waitForGroup(until: Date() + grace) { [self] in
            finalize(code: code, signal: signal)
        }
    }

    private func waitForGroup(until deadline: Date, then done: @escaping @Sendable () -> Void) {
        guard groupExists() else { return done() }
        guard Date() < deadline else {
            log.write(.ath, "sending SIGKILL to what the script left running")
            signalGroup(SIGKILL)
            queue.asyncAfter(deadline: .now() + 0.2, execute: done)
            return
        }
        queue.asyncAfter(deadline: .now() + 0.1) { [self] in
            waitForGroup(until: deadline, then: done)
        }
    }

    private func finalize(code: Int32?, signal: Int32?) {
        // Output still in the pipes goes before the exit line. Something that
        // escaped the group may hold them open; don't wait for it.
        for fd in Array(readers.keys) { drain(fd) }
        for (fd, reader) in readers {
            if let line = splitters[fd]!.flush() { log.write(reader.stream, line) }
        }
        status.endedAt = Date().timeIntervalSince1970
        let verb = stopping ? "stopped" : (signal != nil ? "killed by" : "exited")
        if let signal {
            log.write(.ath, "\(verb) \(stopping ? "· " : "")\(ExitDescription.signalName(signal))")
        } else {
            log.write(.ath, "\(verb) · code \(code ?? 0)")
        }
        writeStatus()
        exit(0)
    }

    private func fail(_ message: String, code: Int32) -> Never {
        log.write(.ath, message)
        status.exitCode = code
        status.failure = message
        status.endedAt = Date().timeIntervalSince1970
        writeStatus()
        exit(0)
    }

    private func writeStatus() {
        try? status.write(URL(fileURLWithPath: options.statusPath))
    }
}

guard let options = Options.parse(CommandLine.arguments) else {
    FileHandle.standardError.write(Data(
        "usage: athanor-shim --id ID --log FILE --status FILE --cwd DIR [--signal TERM] [--timeout 10] [--log-cap BYTES] [--lifeline] [--outside] -- COMMAND\n".utf8
    ))
    exit(64)
}
Shim(options: options).run()
