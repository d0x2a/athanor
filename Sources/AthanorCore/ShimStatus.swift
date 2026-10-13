import Foundation

/// What a shim writes about its script, to `run/<id>.json`: once when the
/// script starts and again when it ends. It's how Athanor finds scripts that
/// kept running while it was quit, and learns how a script ended when the
/// shim wasn't its own child.
package struct ShimStatus: Codable, Equatable, Sendable {
    package var shimPid: Int32
    package var childPid: Int32?
    /// Seconds since 1970.
    package var startedAt: Double
    package var exitCode: Int32?
    package var signal: Int32?
    package var endedAt: Double?
    /// The shim was asked to stop the script.
    package var stopRequested: Bool?
    /// Why the script never started.
    package var failure: String?

    package init(shimPid: Int32, startedAt: Double) {
        self.shimPid = shimPid
        self.startedAt = startedAt
    }

    package var hasEnded: Bool { endedAt != nil }

    package static func read(_ url: URL) -> ShimStatus? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ShimStatus.self, from: data)
    }

    package func write(_ url: URL) throws {
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

/// Exit details in words: "code 255", "SIGKILL".
package enum ExitDescription {
    package static func signalName(_ number: Int32) -> String {
        switch number {
        case SIGHUP: "SIGHUP"
        case SIGINT: "SIGINT"
        case SIGQUIT: "SIGQUIT"
        case SIGILL: "SIGILL"
        case SIGTRAP: "SIGTRAP"
        case SIGABRT: "SIGABRT"
        case SIGBUS: "SIGBUS"
        case SIGFPE: "SIGFPE"
        case SIGKILL: "SIGKILL"
        case SIGSEGV: "SIGSEGV"
        case SIGPIPE: "SIGPIPE"
        case SIGALRM: "SIGALRM"
        case SIGTERM: "SIGTERM"
        case SIGUSR1: "SIGUSR1"
        case SIGUSR2: "SIGUSR2"
        default: "signal \(number)"
        }
    }

    /// Splits a `waitpid` status. (WIFEXITED and friends are macros Swift can't see.)
    package static func decode(waitStatus status: Int32) -> (code: Int32?, signal: Int32?) {
        let signal = status & 0x7F
        if signal == 0 { return ((status >> 8) & 0xFF, nil) }
        return (nil, signal)
    }
}
