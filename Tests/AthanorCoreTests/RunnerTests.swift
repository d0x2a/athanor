@testable import AthanorCore
import Foundation
import Testing

/// The App Store build's way to run a script outside the sandbox: the real
/// athanor-runner and an athanor-shim with --outside, joined the way Athanor
/// joins them. macOS starts the runner through NSUserUnixTask; here it's
/// spawned directly.
@Suite(.serialized)
struct RunnerTests {
    static var runnerPath: String {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("Resources/AppStore/athanor-runner").path
    }

    struct Launched {
        let run: ShimTests.Run
        let runner: pid_t

        func waitForRunner(timeout: TimeInterval = 10) -> Bool {
            let deadline = Date() + timeout
            while Date() < deadline {
                var status: Int32 = 0
                if waitpid(runner, &status, WNOHANG) == runner { return true }
                usleep(20_000)
            }
            return false
        }
    }

    /// For a script whose shim has gone: nothing else waits for it to end.
    static func waitForGroupToEnd(_ group: pid_t, timeout: TimeInterval) -> Bool {
        let deadline = Date() + timeout
        while Date() < deadline {
            if ProcTree.groupMembers(group).isEmpty { return true }
            usleep(20_000)
        }
        return false
    }

    func launch(
        _ command: String, cwd: String = "/tmp", timeout: Int = 10, env: [String: String] = [:],
        extra: [String] = [], stdin: Int32? = nil
    ) throws -> Launched {
        var control: [Int32] = [0, 0]
        var output: [Int32] = [0, 0]
        var errors: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &control) == 0)
        #expect(pipe(&output) == 0)
        #expect(pipe(&errors) == 0)
        for fd in control + output + errors { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        let runner = try Spawn.spawn(
            Self.runnerPath,
            arguments: ["run", "TERM", String(timeout), cwd, command],
            environment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()],
            stdin: control[1], stdout: output[1], stderr: errors[1]
        )
        for fd in [control[1], output[1], errors[1]] { close(fd) }
        defer { for fd in [control[0], output[0], errors[0]] { close(fd) } }
        RunnerSocket.write(RunnerSocket.environmentBlock(env), to: control[0])

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("athanor-runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let paths = ShimTests.Run(directory: directory, pid: 0)
        let shim = try Spawn.spawn(
            ShimTests.shimPath,
            arguments: ["--id", "s", "--log", paths.log.path, "--status", paths.statusURL.path, "--cwd", cwd,
                        "--timeout", String(timeout)] + extra + ["--outside", "--", command],
            environment: [:],
            stdin: stdin,
            inherit: [control[0], output[0], errors[0]],
            newSession: true
        )
        return Launched(run: ShimTests.Run(directory: directory, pid: shim), runner: runner)
    }

    @Test func recordsOutputAndExitCode() throws {
        let launched = try launch(
            #"echo "$GREETING"; printf '%s\n' "$MULTI"; echo oops >&2; pwd; exit 3"#,
            cwd: "~", env: ["GREETING": "hello", "MULTI": "two\nlines"]
        )
        let run = launched.run
        #expect(run.waitForExit())
        #expect(launched.waitForRunner())
        let status = try #require(ShimStatus.read(run.statusURL))
        #expect(status.exitCode == 3)
        #expect(status.signal == nil)
        #expect(status.childPid != nil)
        let lines = run.lines
        #expect(lines.first?.text == "started · pid \(status.childPid ?? 0) · ~")
        #expect(lines.contains { $0.stream == .out && $0.text == "hello" })
        #expect(lines.contains { $0.stream == .out && $0.text == "lines" })
        #expect(lines.contains { $0.stream == .err && $0.text == "oops" })
        #expect(lines.contains { $0.stream == .out && $0.text == NSHomeDirectory() })
        #expect(lines.last?.text == "exited · code 3")
    }

    /// More than the socket holds at once.
    @Test func passesALargeEnvironment() throws {
        let launched = try launch(#"echo "${#BIG}""#, env: ["BIG": String(repeating: "x", count: 100_000)])
        #expect(launched.run.waitForExit())
        #expect(launched.waitForRunner())
        #expect(launched.run.lines.contains { $0.stream == .out && $0.text == "100000" })
    }

    @Test func stopsTheWholeGroup() throws {
        let launched = try launch("sleep 30 & sleep 30; wait")
        let run = launched.run
        let started = try #require(run.waitForStatus { $0.childPid != nil })
        usleep(200_000)
        let group = try #require(started.childPid)
        #expect(ProcTree.groupMembers(group).count >= 2)
        kill(run.pid, SIGTERM)
        #expect(run.waitForExit(timeout: 5))
        #expect(launched.waitForRunner())
        let status = try #require(ShimStatus.read(run.statusURL))
        #expect(status.stopRequested == true)
        #expect(status.signal == SIGTERM)
        #expect(run.lines.last?.text == "stopped · SIGTERM")
        #expect(ProcTree.groupMembers(group).isEmpty)
    }

    /// macOS shows a gear in the menu bar while the runner runs, so it leaves
    /// the script to a copy of itself and returns.
    @Test func returnsWhileTheScriptRuns() throws {
        let launched = try launch("sleep 30")
        let run = launched.run
        let started = try #require(run.waitForStatus { $0.childPid != nil })
        let group = try #require(started.childPid)
        #expect(launched.waitForRunner(timeout: 2))
        #expect(!ProcTree.groupMembers(group).isEmpty)
        kill(run.pid, SIGTERM)
        #expect(run.waitForExit(timeout: 5))
        #expect(run.lines.last?.text == "stopped · SIGTERM")
        #expect(ProcTree.groupMembers(group).isEmpty)
    }

    @Test func stopsWhenTheLifelineCloses() throws {
        var lifeline: [Int32] = [0, 0]
        #expect(pipe(&lifeline) == 0)
        for fd in lifeline { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        let launched = try launch("sleep 30", extra: ["--lifeline"], stdin: lifeline[0])
        close(lifeline[0])
        let run = launched.run
        let started = try #require(run.waitForStatus { $0.childPid != nil })
        let group = try #require(started.childPid)
        close(lifeline[1])
        #expect(run.waitForExit(timeout: 5))
        #expect(launched.waitForRunner())
        #expect(run.lines.contains { $0.text == "Athanor quit · stopping" })
        #expect(run.lines.last?.text == "stopped · SIGTERM")
        #expect(ProcTree.groupMembers(group).isEmpty)
    }

    @Test func killsAScriptThatIgnoresTheStopSignal() throws {
        let launched = try launch("trap '' TERM; sleep 30", timeout: 1)
        let run = launched.run
        _ = try #require(run.waitForStatus { $0.childPid != nil })
        usleep(200_000)
        kill(run.pid, SIGTERM)
        #expect(run.waitForExit(timeout: 5))
        #expect(launched.waitForRunner())
        let status = try #require(ShimStatus.read(run.statusURL))
        #expect(status.signal == SIGKILL)
        #expect(run.lines.contains { $0.text == "still running 1 s after SIGTERM · sending SIGKILL" })
    }

    @Test func killsWhatTheScriptLeftBehind() throws {
        let launched = try launch("(trap '' TERM; sleep 30) & echo started; exit 0")
        let run = launched.run
        let started = try #require(run.waitForStatus { $0.childPid != nil })
        let group = try #require(started.childPid)
        #expect(run.waitForExit(timeout: 6))
        #expect(launched.waitForRunner())
        let status = try #require(ShimStatus.read(run.statusURL))
        #expect(status.exitCode == 0)
        #expect(run.lines.contains { $0.text == "sending SIGKILL to what the script left running" })
        #expect(run.lines.last?.text == "exited · code 0")
        #expect(ProcTree.groupMembers(group).isEmpty)
    }

    /// Athanor's helper killed outright: the runner stops the script itself.
    @Test func stopsWhenTheShimDies() throws {
        let launched = try launch("trap '' TERM; sleep 30", timeout: 1)
        let run = launched.run
        let started = try #require(run.waitForStatus { $0.childPid != nil })
        let group = try #require(started.childPid)
        kill(run.pid, SIGKILL)
        #expect(run.waitForExit())
        #expect(launched.waitForRunner())
        // SIGTERM, which it ignores, then SIGKILL a second later.
        #expect(Self.waitForGroupToEnd(group, timeout: 5))
    }

    @Test func reportsAMissingFolder() throws {
        let launched = try launch("true", cwd: "/no/such/folder")
        let run = launched.run
        #expect(run.waitForExit())
        #expect(launched.waitForRunner())
        let status = try #require(ShimStatus.read(run.statusURL))
        #expect(status.exitCode == 126)
        #expect(status.failure == "couldn't open the folder /no/such/folder: No such file or directory")
    }

    @Test func printsTheLoginEnvironment() throws {
        var output: [Int32] = [0, 0]
        #expect(pipe(&output) == 0)
        let runner = try Spawn.spawn(
            Self.runnerPath, arguments: ["env", "-lc"],
            environment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "SHELL": "/bin/sh", "MARK": "yes"],
            stdout: output[1]
        )
        close(output[1])
        let data = FileHandle(fileDescriptor: output[0], closeOnDealloc: true).readDataToEndOfFile()
        var status: Int32 = 0
        waitpid(runner, &status, 0)
        let environment = try #require(LoginEnvironment.parse(data))
        #expect(environment["MARK"] == "yes")
        #expect(environment["HOME"] == NSHomeDirectory())
    }
}
