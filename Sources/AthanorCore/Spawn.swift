import Darwin

package struct SpawnError: Error, CustomStringConvertible {
    package let path: String
    package let code: Int32

    package var description: String {
        "couldn't run \(path): \(String(cString: strerror(code)))"
    }
}

/// posix_spawn, for the two things Foundation's Process can't do: start a
/// process in a session or process group of its own, and pass on no file
/// descriptors but the three it's given.
package enum Spawn {
    /// Standard streams left nil read from or write to /dev/null.
    package static func spawn(
        _ path: String,
        arguments: [String],
        environment: [String: String],
        stdin: Int32? = nil,
        stdout: Int32? = nil,
        stderr: Int32? = nil,
        newSession: Bool = false,
        newProcessGroup: Bool = false
    ) throws -> pid_t {
        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        let streams: [(target: Int32, source: Int32?, mode: Int32)] = [
            (0, stdin, O_RDONLY), (1, stdout, O_WRONLY), (2, stderr, O_WRONLY),
        ]
        for stream in streams {
            if let source = stream.source {
                posix_spawn_file_actions_adddup2(&actions, source, stream.target)
            } else {
                posix_spawn_file_actions_addopen(&actions, stream.target, "/dev/null", stream.mode, 0)
            }
        }

        var attributes: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var flags = POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        if newSession { flags |= POSIX_SPAWN_SETSID }
        if newProcessGroup {
            flags |= POSIX_SPAWN_SETPGROUP
            posix_spawnattr_setpgroup(&attributes, 0)
        }
        posix_spawnattr_setflags(&attributes, Int16(flags))
        // Whatever this process ignores or blocks, the new one starts clean.
        var everySignal: sigset_t = ~0
        everySignal &= ~(1 << (SIGKILL - 1)) & ~(1 << (SIGSTOP - 1))
        posix_spawnattr_setsigdefault(&attributes, &everySignal)
        var noSignals: sigset_t = 0
        posix_spawnattr_setsigmask(&attributes, &noSignals)

        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, path, &actions, &attributes, argv, envp)
        guard result == 0 else { throw SpawnError(path: path, code: result) }
        return pid
    }
}
