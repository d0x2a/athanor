import Foundation

/// Where Athanor keeps its files.
///
/// The script list sits with other dotfiles so it can be kept in a dotfiles
/// repo; logs go where Console.app looks for them; run state is the app's own.
/// `ATHANOR_HOME` moves all three under one folder, which is how tests and
/// `scripts/run-dev.sh` stay off the real ones.
package struct AthanorPaths: Sendable, Equatable {
    package var scriptsFile: URL
    package var logsDir: URL
    package var runDir: URL

    package init(scriptsFile: URL, logsDir: URL, runDir: URL) {
        self.scriptsFile = scriptsFile
        self.logsDir = logsDir
        self.runDir = runDir
    }

    package init(root: URL) {
        self.init(
            scriptsFile: root.appendingPathComponent("scripts.toml"),
            logsDir: root.appendingPathComponent("logs", isDirectory: true),
            runDir: root.appendingPathComponent("run", isDirectory: true)
        )
    }

    package static func standard(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AthanorPaths {
        if let root = environment["ATHANOR_HOME"], !root.isEmpty {
            return AthanorPaths(root: URL(fileURLWithPath: expandTilde(root), isDirectory: true))
        }
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let configRoot: URL
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            configRoot = URL(fileURLWithPath: expandTilde(xdg), isDirectory: true)
        } else {
            configRoot = home.appendingPathComponent(".config", isDirectory: true)
        }
        return AthanorPaths(
            scriptsFile: configRoot.appendingPathComponent("athanor/scripts.toml"),
            logsDir: home.appendingPathComponent("Library/Logs/Athanor", isDirectory: true),
            runDir: home.appendingPathComponent("Library/Application Support/Athanor/run", isDirectory: true)
        )
    }

    package func logFile(for id: String) -> URL {
        logsDir.appendingPathComponent("\(id).log")
    }

    package func statusFile(for id: String) -> URL {
        runDir.appendingPathComponent("\(id).json")
    }
}

package func expandTilde(_ path: String) -> String {
    (path as NSString).expandingTildeInPath
}

/// The path with `~` for the home folder, for showing it.
package func abbreviateHome(_ path: String) -> String {
    let home = NSHomeDirectory()
    if path == home { return "~" }
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
}
