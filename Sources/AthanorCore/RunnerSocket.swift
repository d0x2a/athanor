import Darwin

/// Writing to athanor-runner's socket (see Resources/AppStore/athanor-runner).
package enum RunnerSocket {
    /// The script's environment, which Athanor sends before anything else:
    /// NAME=VALUE entries each ended by a NUL, then an empty one.
    package static func environmentBlock(_ environment: [String: String]) -> [UInt8] {
        var block: [UInt8] = []
        for (key, value) in environment.sorted(by: { $0.key < $1.key }) where !key.isEmpty {
            block += Array("\(key)=\(value)".utf8) + [0]
        }
        return block + [0]
    }

    /// Blocks until all of it is written. False if the runner has gone.
    @discardableResult
    package static func write(_ bytes: [UInt8], to fd: Int32) -> Bool {
        var sent = 0
        while sent < bytes.count {
            let count = bytes[sent...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                sent += count
            } else if count < 0, errno != EINTR {
                return false
            }
        }
        return true
    }
}
