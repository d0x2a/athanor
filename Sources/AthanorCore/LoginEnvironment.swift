import Foundation

/// The environment a Terminal window would have.
///
/// Apps opened from the Dock or at login get launchd's bare environment, whose
/// PATH has no Homebrew, pip or nvm in it. Running the user's shell as an
/// interactive login shell and reading its environment back fixes that the way
/// editors do.
package enum LoginEnvironment {
    /// Set by a shell for itself or by a terminal, and wrong for a script.
    private static let ignored: Set<String> = [
        "PWD", "OLDPWD", "SHLVL", "_", "TERM", "COLORTERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION",
        "TERM_SESSION_ID", "ITERM_SESSION_ID", "ITERM_PROFILE", "LC_TERMINAL", "LC_TERMINAL_VERSION",
        "COLUMNS", "LINES", "PS1", "PS2", "PROMPT",
    ]
    private static let begin = "__ATHANOR_ENV_BEGIN__"
    private static let end = "__ATHANOR_ENV_END__"

    package static func userShell() -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// Blocks while the shell starts, at most `timeout` seconds per try.
    /// Interactive first, since that's where most people set PATH (.zshrc);
    /// then login-only, for shells whose rc files misbehave without a terminal.
    package static func capture(shell: String = userShell(), timeout: TimeInterval = 8) -> [String: String]? {
        for flags in ["-ilc", "-lc"] {
            if let environment = run(shell, flags: flags, timeout: timeout) { return environment }
        }
        return nil
    }

    /// Takes the text between the markers: whatever rc files print before it
    /// (a greeting, a warning) doesn't get in.
    package static func parse(_ data: Data) -> [String: String]? {
        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.range(of: begin),
              let stop = text.range(of: end, range: start.upperBound..<text.endIndex) else { return nil }
        var environment: [String: String] = [:]
        for entry in text[start.upperBound..<stop.lowerBound].split(separator: "\0") {
            guard let equals = entry.firstIndex(of: "="), equals != entry.startIndex else { continue }
            let key = String(entry[..<equals])
            guard !ignored.contains(key) else { continue }
            environment[key] = String(entry[entry.index(after: equals)...])
        }
        return environment.isEmpty ? nil : environment
    }

    /// For when there's no login shell to ask: the system PATH with the usual
    /// package-manager folders in front.
    package static func fallbackPath(_ existing: String?) -> String {
        var parts = (existing ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        for folder in ["/usr/local/bin", "/opt/homebrew/sbin", "/opt/homebrew/bin"] where !parts.contains(folder) {
            parts.insert(folder, at: 0)
        }
        return parts.joined(separator: ":")
    }

    private final class Output: @unchecked Sendable {
        var data = Data()
    }

    private static func run(_ shell: String, flags: String, timeout: TimeInterval) -> [String: String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = [flags, "printf '%s' '\(begin)'; /usr/bin/env -0; printf '%s' '\(end)'"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
        } catch {
            return nil
        }
        let output = Output()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            output.data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        return parse(output.data)
    }
}
