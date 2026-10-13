@testable import AthanorCore
import Foundation
import Testing

/// Runs the real athanor-shim binary, which SwiftPM builds next to the test bundle.
@Suite(.serialized)
struct ShimTests {
    struct Run {
        let directory: URL
        let pid: pid_t
        var log: URL { directory.appendingPathComponent("s.log") }
        var statusURL: URL { directory.appendingPathComponent("s.json") }

        func waitForExit(timeout: TimeInterval = 10) -> Bool {
            let deadline = Date() + timeout
            while Date() < deadline {
                var status: Int32 = 0
                if waitpid(pid, &status, WNOHANG) == pid { return true }
                usleep(20_000)
            }
            return false
        }

        func waitForStatus(_ ready: (ShimStatus) -> Bool) -> ShimStatus? {
            for _ in 0..<250 {
                if let status = ShimStatus.read(statusURL), ready(status) { return status }
                usleep(20_000)
            }
            return nil
        }

        var lines: [LogLine] {
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            return text.split(separator: "\n").map(LogFormat.parse)
        }
    }

    /// The test binary is …/debug/AthanorPackageTests.xctest/Contents/MacOS/AthanorPackageTests,
    /// and the shim sits in that debug folder.
    static var shimPath: String {
        var info = Dl_info()
        dladdr(#dsohandle, &info)
        var url = URL(fileURLWithPath: String(cString: info.dli_fname))
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("athanor-shim").path
    }

    func launch(
        _ command: String, cwd: String? = nil, extra: [String] = [], binary: String = shimPath, stdin: Int32? = nil
    ) throws -> Run {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("athanor-shim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let run = Run(directory: directory, pid: 0)
        let pid = try Spawn.spawn(
            binary,
            arguments: ["--id", "s", "--log", run.log.path, "--status", run.statusURL.path,
                        "--cwd", cwd ?? directory.path] + extra + ["--", command],
            environment: ["PATH": "/usr/bin:/bin", "GREETING": "hello"],
            stdin: stdin,
            newSession: true
        )
        return Run(directory: directory, pid: pid)
    }

    @Test func recordsOutputAndExitCode() throws {
        let run = try launch(#"echo "$GREETING"; echo oops >&2; pwd; printf 'no newline'; exit 3"#)
        #expect(run.waitForExit())
        let status = try #require(ShimStatus.read(run.statusURL))
        #expect(status.exitCode == 3)
        #expect(status.signal == nil)
        #expect(status.childPid != nil)
        let lines = run.lines
        #expect(lines.first?.stream == .ath)
        #expect(lines.first?.text.hasPrefix("started · pid ") == true)
        #expect(lines.contains { $0.stream == .out && $0.text == "hello" })
        #expect(lines.contains { $0.stream == .err && $0.text == "oops" })
        #expect(lines.contains { $0.stream == .out && $0.text.hasSuffix(run.directory.lastPathComponent) })
        #expect(lines.contains { $0.stream == .out && $0.text == "no newline" })
        #expect(lines.last?.stream == .ath)
        #expect(lines.last?.text == "exited · code 3")
        #expect(lines.allSatisfy { $0.timestamp != nil })
    }

    @Test func stopsTheWholeGroup() throws {
        let run = try launch("sleep 30 & sleep 30; wait")
        let started = try #require(run.waitForStatus { $0.childPid != nil })
        usleep(200_000)
        let group = try #require(started.childPid)
        #expect(ProcTree.groupMembers(group).count >= 2)
        kill(run.pid, SIGTERM)
        #expect(run.waitForExit(timeout: 5))
        let status = try #require(ShimStatus.read(run.statusURL))
        #expect(status.stopRequested == true)
        #expect(status.signal == SIGTERM)
        #expect(run.lines.last?.text == "stopped · SIGTERM")
        usleep(100_000)
        #expect(ProcTree.groupMembers(group).isEmpty)
    }

    /// The App Store build: when Athanor exits, its end of the pipe closes.
    @Test func stopsWhenTheLifelineCloses() throws {
        var lifeline: [Int32] = [0, 0]
        #expect(pipe(&lifeline) == 0)
        for fd in lifeline { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        let run = try launch("sleep 30 & sleep 30; wait", extra: ["--lifeline"], stdin: lifeline[0])
        close(lifeline[0])
        let started = try #require(run.waitForStatus { $0.childPid != nil })
        usleep(200_000)
        let group = try #require(started.childPid)
        let tree = ProcTree.tree(root: run.pid, group: group)
        #expect(tree.contains(group))
        #expect(tree.count >= 3)
        close(lifeline[1])
        #expect(run.waitForExit(timeout: 5))
        let status = try #require(ShimStatus.read(run.statusURL))
        #expect(status.stopRequested == true)
        #expect(status.signal == SIGTERM)
        #expect(run.lines.contains { $0.text == "Athanor quit · stopping" })
        #expect(run.lines.last?.text == "stopped · SIGTERM")
        usleep(100_000)
        #expect(ProcTree.groupMembers(group).isEmpty)
    }

    @Test func killsAScriptThatIgnoresTheStopSignal() throws {
        let run = try launch("trap '' TERM; sleep 30", extra: ["--timeout", "1"])
        _ = try #require(run.waitForStatus { $0.childPid != nil })
        usleep(200_000)
        kill(run.pid, SIGTERM)
        #expect(run.waitForExit(timeout: 5))
        let status = try #require(ShimStatus.read(run.statusURL))
        #expect(status.signal == SIGKILL)
        #expect(run.lines.contains { $0.text == "still running 1 s after SIGTERM · sending SIGKILL" })
    }

    @Test func killsWhatTheScriptLeftBehind() throws {
        let run = try launch("(trap '' TERM; sleep 30) & echo started; exit 0")
        let started = try #require(run.waitForStatus { $0.childPid != nil })
        let group = try #require(started.childPid)
        #expect(run.waitForExit(timeout: 6))
        let status = try #require(ShimStatus.read(run.statusURL))
        #expect(status.exitCode == 0)
        #expect(run.lines.contains { $0.text == "sending SIGKILL to what the script left running" })
        #expect(run.lines.last?.text == "exited · code 0")
        usleep(100_000)
        #expect(ProcTree.groupMembers(group).isEmpty)
    }

    /// An update deletes or moves the app while its shims run on. Athanor
    /// must still know them, or it would stop their scripts as orphans.
    @Test func namesAShimWhoseFileIsGone() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("athanor-bin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let binary = folder.appendingPathComponent("athanor-shim").path
        try FileManager.default.copyItem(atPath: Self.shimPath, toPath: binary)
        let run = try launch("sleep 30", binary: binary)
        _ = try #require(run.waitForStatus { $0.childPid != nil })
        #expect(ProcTree.name(run.pid) == "athanor-shim")

        try FileManager.default.removeItem(at: folder)
        #expect(ProcTree.executablePath(run.pid) == nil)
        #expect(ProcTree.name(run.pid) == "athanor-shim")
        kill(run.pid, SIGTERM)
        #expect(run.waitForExit())
    }

    @Test func reportsAMissingFolder() throws {
        let run = try launch("true", cwd: "/no/such/folder")
        #expect(run.waitForExit())
        let status = try #require(ShimStatus.read(run.statusURL))
        #expect(status.exitCode == 126)
        #expect(status.failure?.hasPrefix("couldn't open the folder /no/such/folder") == true)
    }

    @Test func rotatesTheLog() throws {
        let run = try launch("i=0; while [ $i -lt 3000 ]; do echo line-$i-padding-padding-padding; i=$((i+1)); done",
                             extra: ["--log-cap", "65536"])
        #expect(run.waitForExit())
        let rotated = run.directory.appendingPathComponent("s.log.1")
        #expect(FileManager.default.fileExists(atPath: rotated.path))
        #expect(run.lines.first?.text == "log rotated · earlier lines are in s.log.1")
        #expect(run.lines.last?.text == "exited · code 0")
    }
}

struct ProcTreeTests {
    @Test func measuresABusyProcess() throws {
        let pid = try Spawn.spawn("/bin/sh", arguments: ["-c", "while :; do :; done"],
                                  environment: [:], newProcessGroup: true)
        defer {
            kill(pid, SIGKILL)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
        let sampler = ProcSampler()
        let root = ProcSampler.Root(id: "busy", pid: getpid(), group: pid)
        _ = sampler.sample([root], ports: false)
        usleep(500_000)
        let sample = try #require(sampler.sample([root], ports: false)["busy"])
        #expect(sample.cpuPercent > 50)
        #expect(sample.cpuPercent < 150)
        #expect(sample.memoryBytes > 0)
    }

    @Test func findsListeningPorts() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(bound == 0)
        #expect(listen(fd, 1) == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        let port = UInt16(bigEndian: address.sin_port)
        #expect(ProcTree.listeningPorts(getpid()).contains(port))
        #expect(PortProbe.isOpen(Int(port)))
    }

    @Test func readsLoginEnvironmentOutput() {
        let data = Data("motd text\n__ATHANOR_ENV_BEGIN__PATH=/opt/homebrew/bin:/usr/bin\0SHLVL=2\0EMPTY=\0__ATHANOR_ENV_END__".utf8)
        let environment = LoginEnvironment.parse(data)
        #expect(environment == ["PATH": "/opt/homebrew/bin:/usr/bin", "EMPTY": ""])
        #expect(LoginEnvironment.fallbackPath("/usr/bin:/bin").hasPrefix("/opt/homebrew/bin:"))
    }
}
