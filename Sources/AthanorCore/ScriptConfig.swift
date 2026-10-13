import Foundation

/// The signal Stop sends first. SIGKILL follows if the script outlasts its
/// stop timeout.
package enum StopSignal: String, CaseIterable, Sendable {
    case term = "TERM"
    case int = "INT"
    case hup = "HUP"
    case quit = "QUIT"

    package var number: Int32 {
        switch self {
        case .term: SIGTERM
        case .int: SIGINT
        case .hup: SIGHUP
        case .quit: SIGQUIT
        }
    }

    package var name: String { "SIG" + rawValue }

    /// Takes "TERM", "SIGTERM" or "sigterm".
    package init?(name: String) {
        var text = name.uppercased()
        if text.hasPrefix("SIG") { text.removeFirst(3) }
        self.init(rawValue: text)
    }
}

/// When a script that has started counts as up.
package enum Readiness: Equatable, Sendable {
    /// As soon as it starts.
    case started
    /// Once something accepts connections on this port on localhost.
    case port(Int)
    /// Once this URL answers at all, whatever the status.
    case url(String)
}

package struct EnvVar: Equatable, Sendable {
    package var key: String
    package var value: String

    package init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }
}

/// One entry in scripts.toml.
package struct ScriptConfig: Equatable, Sendable, Identifiable {
    /// Names the log and run-state files, so it stays put when the name changes.
    package var id: String
    package var name: String
    /// Run with `/bin/sh -c`.
    package var command: String
    package var cwd = "~"
    package var env: [EnvVar] = []
    /// Start from the environment a login shell builds (PATH and the rest)
    /// rather than the bare one apps get from launchd.
    package var useLoginEnvironment = true
    package var autostart = false
    package var restartOnCrash = true
    /// At most this many automatic restarts…
    package var restartLimit = 3
    /// …within this many seconds.
    package var restartWindow = 300
    package var stopSignal = StopSignal.term
    /// Seconds between the stop signal and SIGKILL.
    package var stopTimeout = 10
    package var ready = Readiness.started

    package init(id: String, name: String, command: String) {
        self.id = id
        self.name = name
        self.command = command
    }

    /// One line to show for the command. A script that ends in `exec x` is
    /// really x; otherwise the first line that does something, skipping
    /// comments and the usual setup (export, cd, source).
    package var summary: String {
        let lines = command.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        if let exec = lines.last(where: { $0.hasPrefix("exec ") }) {
            return String(exec.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        }
        let setup = ["export ", "cd ", "source ", ". ", "set "]
        return lines.first { line in
            !setup.contains { line.hasPrefix($0) } && !Self.isAssignment(line)
        } ?? lines.first ?? ""
    }

    /// `name=value` and nothing more: setting up, not doing. (`PORT=1 node
    /// app.js` is doing: it runs node.)
    private static func isAssignment(_ line: String) -> Bool {
        guard let equals = line.firstIndex(of: "=") else { return false }
        let name = line[..<equals]
        guard let first = name.first, !first.isNumber,
              name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return false }
        let value = line[line.index(after: equals)...]
        return !value.contains(" ") || value.hasPrefix("\"") || value.hasPrefix("'")
    }
}
