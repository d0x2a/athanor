import AppKit
import AthanorCore
import Foundation
import Observation

/// athanor-runner, which lets the App Store build run scripts outside the App
/// Sandbox (see Resources/AppStore/athanor-runner).
///
/// macOS runs what's in ~/Library/Application Scripts/<bundle id> for the app,
/// outside its sandbox (NSUserUnixTask), but lets the app only read that
/// folder. So Athanor asks once, with an open panel on the folder, and copies
/// the runner in. A script then starts like this: Athanor runs the runner
/// with a socket and two pipes, and hands their other ends to an athanor-shim
/// (--outside), which logs as usual and asks the runner for the signals the
/// sandbox won't let it send. Only Athanor itself can start the runner:
/// macOS refuses the shim. The runner leaves the script to a copy of itself
/// and returns at once, so the gear macOS shows in the menu bar while it runs
/// only flashes (see athanor-runner).
@MainActor @Observable
final class Runner {
    enum State {
        /// Not in the folder: scripts run in the sandbox.
        case missing
        /// In the folder, but not this version's: scripts run in the sandbox
        /// until it's replaced.
        case outdated
        case ready
    }

    private(set) var state = State.missing
    let folder: URL
    @ObservationIgnored private let bundled: Data

    var url: URL { folder.appendingPathComponent("athanor-runner") }

    /// With `~` for the real home folder: in the sandbox, NSHomeDirectory is
    /// the container's.
    var shownPath: String {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else { return url.path }
        let home = String(cString: directory)
        return url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
    }

    /// Set by the service that starts the runner, and wrong for a script.
    nonisolated static let serviceVariables: Set<String> = [
        "XPC_SERVICE_NAME", "XPC_FLAGS", "MallocNanoZone", "MallocSpaceEfficient", "OSLogRateLimit",
    ]

    /// Nil outside the sandbox, where scripts don't need it.
    init?() {
        guard Sandbox.isActive,
              let source = Bundle.main.url(forResource: "athanor-runner", withExtension: nil),
              let bundled = try? Data(contentsOf: source),
              let folder = try? FileManager.default.url(
                  for: .applicationScriptsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        else { return nil }
        self.folder = folder
        self.bundled = bundled
        refresh()
    }

    /// Looks again: it may have been deleted or replaced in the Finder.
    func refresh() {
        let new: State
        if let installed = try? Data(contentsOf: url) {
            new = installed == bundled && FileManager.default.isExecutableFile(atPath: url.path) ? .ready : .outdated
        } else {
            new = .missing
        }
        if new != state { state = new }
    }

    /// Asks for the folder with an open panel, then copies the runner in.
    /// False if the panel was cancelled.
    func install() throws -> Bool {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.directoryURL = folder
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Allow"
        panel.message = "Click Allow to let Athanor put its runner in this folder. macOS runs it outside the App Sandbox, so your scripts can use Homebrew, your tools and your files."
        guard panel.runModal() == .OK, let chosen = panel.url else { return false }
        guard chosen.resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path else {
            throw RunnerError("That’s a different folder. Click Allow without choosing anything, in “\(folder.lastPathComponent)”.")
        }
        // Atomically, so a runner that's running keeps reading its own copy.
        try bundled.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        refresh()
        return state == .ready
    }

    /// Starts `config` through the runner, which adds `environment` to the
    /// one it has. Returns the ends for the shim, in the order it takes them
    /// (fd 3, 4, 5): the socket, the script's output and its errors. `failed`
    /// hears why macOS couldn't run the runner.
    func start(_ config: ScriptConfig, environment: [String: String],
               failed: @escaping @Sendable (String) -> Void) throws -> [Int32] {
        var control: [Int32] = [-1, -1]
        var output: [Int32] = [-1, -1]
        var errors: [Int32] = [-1, -1]
        let all = { control + output + errors }
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &control) == 0, pipe(&output) == 0, pipe(&errors) == 0 else {
            let code = errno
            all().filter { $0 >= 0 }.forEach { close($0) }
            throw RunnerError("couldn’t make pipes: \(String(cString: strerror(code)))")
        }
        for fd in all() { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        let task: NSUserUnixTask
        do {
            task = try NSUserUnixTask(url: url)
        } catch {
            all().forEach { close($0) }
            throw error
        }
        task.standardInput = FileHandle(fileDescriptor: control[1], closeOnDealloc: false)
        task.standardOutput = FileHandle(fileDescriptor: output[1], closeOnDealloc: false)
        task.standardError = FileHandle(fileDescriptor: errors[1], closeOnDealloc: false)
        let arguments = ["run", config.stopSignal.rawValue, String(config.stopTimeout), config.cwd, config.command]
        task.execute(withArguments: arguments) { error in
            guard let error = error as NSError? else { return }
            let reason = error.localizedFailureReason ?? error.localizedDescription
            // How the runner ended, not the script; the shim has the script's exit.
            guard !reason.hasPrefix("Script task exited") else { return }
            failed(reason)
        }
        // execute has handed copies to macOS.
        for fd in [control[1], output[1], errors[1]] { close(fd) }
        // The environment goes first, through the socket rather than as
        // arguments, which anyone on the Mac can read with ps. On another
        // thread: it may not fit until the runner reads it.
        let block = RunnerSocket.environmentBlock(environment)
        let writer = fcntl(control[0], F_DUPFD_CLOEXEC, 0)
        DispatchQueue.global(qos: .userInitiated).async {
            RunnerSocket.write(block, to: writer)
            close(writer)
        }
        return [control[0], output[0], errors[0]]
    }

    /// The login shell's environment, as LoginEnvironment.capture gets it
    /// outside the sandbox: interactive first, then login only.
    func loginEnvironment() async -> [String: String]? {
        let url = url
        for flags in ["-ilc", "-lc"] {
            let data = await Task.detached(priority: .userInitiated) {
                Self.output(of: url, arguments: ["env", flags], timeout: 8)
            }.value
            if let data, let environment = LoginEnvironment.parse(data) {
                return environment.filter { !Self.serviceVariables.contains($0.key) }
            }
        }
        return nil
    }

    private final class Output: @unchecked Sendable {
        var data = Data()
    }

    /// Blocks while the runner runs, at most `timeout` seconds.
    nonisolated private static func output(of url: URL, arguments: [String], timeout: TimeInterval) -> Data? {
        guard let task = try? NSUserUnixTask(url: url) else { return nil }
        let pipe = Pipe()
        task.standardOutput = pipe.fileHandleForWriting
        task.execute(withArguments: arguments, completionHandler: nil)
        try? pipe.fileHandleForWriting.close()
        let output = Output()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            output.data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        return done.wait(timeout: .now() + timeout) == .success ? output.data : nil
    }
}

struct RunnerError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
