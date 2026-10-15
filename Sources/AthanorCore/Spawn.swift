import Darwin

package struct SpawnError: Error, CustomStringConvertible {
    package let path: String
    package let code: Int32
    /// A descriptor that couldn't be passed on, when that's what failed.
    package var fd: Int32?

    package init(path: String, code: Int32, fd: Int32? = nil) {
        self.path = path
        self.code = code
        self.fd = fd
    }

    package var description: String {
        let what = fd.map { "pass descriptor \($0) to \(path)" } ?? "run \(path)"
        return "couldn't \(what): \(String(cString: strerror(code)))"
    }
}

/// posix_spawn, for the two things Foundation's Process can't do: start a
/// process in a session or process group of its own, and pass on no file
/// descriptors but the ones it's given.
package enum Spawn {
    /// Standard streams left nil read from or write to /dev/null. `inherit`
    /// becomes the new process's descriptors 3, 4 and so on, in order.
    package static func spawn(
        _ path: String,
        arguments: [String],
        environment: [String: String],
        stdin: Int32? = nil,
        stdout: Int32? = nil,
        stderr: Int32? = nil,
        inherit: [Int32] = [],
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
        // Copies numbered above any target first, so that moving one into
        // place can't overwrite another that's still to move.
        let copies = inherit.map { fcntl($0, F_DUPFD_CLOEXEC, 3 + Int32(inherit.count)) }
        defer { copies.filter { $0 >= 0 }.forEach { close($0) } }
        if let failed = copies.firstIndex(of: -1) { throw SpawnError(path: path, code: errno, fd: inherit[failed]) }
        for (index, copy) in copies.enumerated() {
            posix_spawn_file_actions_adddup2(&actions, copy, 3 + Int32(index))
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
