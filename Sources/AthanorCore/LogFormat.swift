import Foundation

/// Where a log line came from: the script's stdout or stderr, or Athanor
/// noting what it did (started, stopped, restarted).
package enum LogStream: String, Sendable {
    case out
    case err
    case ath
}

package struct LogLine: Equatable, Sendable {
    /// "2026-10-12 09:41:03.123", or nil for a line not in Athanor's format.
    package var timestamp: String?
    package var stream: LogStream
    package var text: String

    package init(timestamp: String?, stream: LogStream, text: String) {
        self.timestamp = timestamp
        self.stream = stream
        self.text = text
    }

    /// "09:41:03", or "" without a timestamp.
    package var clockTime: String {
        guard let timestamp, timestamp.count >= 19 else { return "" }
        let start = timestamp.index(timestamp.startIndex, offsetBy: 11)
        let end = timestamp.index(timestamp.startIndex, offsetBy: 19)
        return String(timestamp[start..<end])
    }
}

/// A log file is plain text, one line per line of output:
///
///     2026-10-12 09:41:03.123 out Listening on http://127.0.0.1:8000
///     2026-10-12 09:41:05.002 err ssh: connect to host staging port 22: …
///     2026-10-12 09:41:05.010 ath exited · code 255
///
/// so it still reads well opened in any editor.
package enum LogFormat {
    package static func line(_ stream: LogStream, _ text: String, at time: timeval = now()) -> String {
        "\(timestamp(time)) \(stream.rawValue) \(text)\n"
    }

    package static func now() -> timeval {
        var time = timeval()
        gettimeofday(&time, nil)
        return time
    }

    package static func timestamp(_ time: timeval) -> String {
        var seconds = time_t(time.tv_sec)
        var parts = tm()
        localtime_r(&seconds, &parts)
        return String(
            format: "%04d-%02d-%02d %02d:%02d:%02d.%03d",
            Int(parts.tm_year) + 1900, Int(parts.tm_mon) + 1, Int(parts.tm_mday),
            Int(parts.tm_hour), Int(parts.tm_min), Int(parts.tm_sec), Int(time.tv_usec) / 1000
        )
    }

    package static func parse(_ raw: Substring) -> LogLine {
        let bytes = Array(raw.utf8.prefix(28))
        func digits(_ range: Range<Int>) -> Bool {
            range.allSatisfy { (0x30...0x39).contains(bytes[$0]) }
        }
        if bytes.count >= 27,
           digits(0..<4), bytes[4] == 0x2D, digits(5..<7), bytes[7] == 0x2D, digits(8..<10),
           bytes[10] == 0x20, digits(11..<13), bytes[13] == 0x3A, digits(14..<16), bytes[16] == 0x3A,
           digits(17..<19), bytes[19] == 0x2E, digits(20..<23), bytes[23] == 0x20,
           bytes.count == 27 || bytes[27] == 0x20,
           let stream = LogStream(rawValue: String(decoding: bytes[24..<27], as: UTF8.self)) {
            // The first 28 bytes are ASCII, so they're also the first 28 characters.
            return LogLine(timestamp: String(raw.prefix(23)), stream: stream, text: String(raw.dropFirst(28)))
        }
        return LogLine(timestamp: nil, stream: .out, text: String(raw))
    }

    /// Appends one Athanor line to a log file. Each line is one write to a file
    /// opened for appending, so it can't land inside a line the shim is writing.
    package static func appendAthanorLine(_ text: String, to url: URL) {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var data = Array(line(.ath, text).utf8)
        _ = data.withUnsafeMutableBytes { write(fd, $0.baseAddress, $0.count) }
    }

    // MARK: Reading lines

    private static let errorWords = [
        "error", "fatal", "panic", "exception", "traceback", "failed", "failure",
        "refused", "denied", "unreachable", "could not", "couldn't", "cannot", "can't",
        "not found", "segmentation fault", "no such file",
    ]

    /// A guess at whether a line reports a problem, for the Errors filter and
    /// the red highlight. Which stream it came on says little: plenty of
    /// programs log everything to stderr.
    package static func looksLikeError(_ text: String) -> Bool {
        let lower = text.lowercased()
        for word in errorWords {
            var searchStart = lower.startIndex
            while let range = lower.range(of: word, range: searchStart..<lower.endIndex) {
                if range.lowerBound == lower.startIndex || !lower[lower.index(before: range.lowerBound)].isLetter {
                    return true
                }
                searchStart = range.upperBound
            }
        }
        return false
    }

    /// Drops terminal escape sequences: colors, cursor moves, window titles.
    package static func stripANSI(_ text: String) -> String {
        guard text.unicodeScalars.contains("\u{1B}") else { return text }
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            guard scalar == "\u{1B}" else {
                out.append(scalar)
                index += 1
                continue
            }
            index += 1
            guard index < scalars.count else { break }
            switch scalars[index] {
            case "[":
                // CSI: parameters, then one final byte from @ to ~.
                index += 1
                while index < scalars.count, !(0x40...0x7E).contains(scalars[index].value) { index += 1 }
                index += 1
            case "]":
                // OSC: up to BEL or ESC \.
                index += 1
                while index < scalars.count, scalars[index] != "\u{07}", scalars[index] != "\u{1B}" { index += 1 }
                if index < scalars.count, scalars[index] == "\u{1B}" { index += 1 }
                index += 1
            default:
                index += 1
            }
        }
        return String(out)
    }
}

/// Cuts a byte stream into lines.
///
/// A lone carriage return starts the line over, the way a terminal draws a
/// progress bar, so a bar that redraws itself many times a second becomes one
/// line rather than thousands.
package struct LineSplitter: Sendable {
    package private(set) var lastInputAt: UInt64 = 0
    private var buffer: [UInt8] = []
    private var pendingReturn = false
    private let maxLine = 16_384

    package init() {}

    package var hasPartialLine: Bool { !buffer.isEmpty }

    package mutating func feed(_ bytes: some Sequence<UInt8>, now: UInt64 = 0) -> [String] {
        var lines: [String] = []
        var sawInput = false
        for byte in bytes {
            sawInput = true
            if pendingReturn {
                pendingReturn = false
                if byte == 0x0A {
                    lines.append(take())
                    continue
                }
                buffer.removeAll(keepingCapacity: true)
            }
            switch byte {
            case 0x0A:
                lines.append(take())
            case 0x0D:
                pendingReturn = true
            default:
                buffer.append(byte)
                if buffer.count >= maxLine { lines.append(take()) }
            }
        }
        if sawInput { lastInputAt = now }
        return lines
    }

    /// The unfinished line, if any: at the end of the stream, or when a
    /// prompt has sat without its line break for a while.
    package mutating func flush() -> String? {
        pendingReturn = false
        return buffer.isEmpty ? nil : take()
    }

    private mutating func take() -> String {
        let text = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll(keepingCapacity: true)
        return LogFormat.stripANSI(text)
    }
}

/// Appends lines to a script's log, moving it to `<name>.1` when it passes
/// its size cap.
package final class LogWriter {
    private let path: String
    private let cap: Int64
    private var fd: Int32
    private var size: Int64

    package init(path: String, cap: Int64) {
        self.path = path
        self.cap = max(cap, 64 * 1024)
        fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        size = fd >= 0 ? Int64(lseek(fd, 0, SEEK_END)) : 0
    }

    deinit {
        if fd >= 0 { close(fd) }
    }

    package func write(_ stream: LogStream, _ text: String) {
        guard fd >= 0 else { return }
        var bytes = Array(LogFormat.line(stream, text).utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeMutableBytes { buffer in
                Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
            }
            if written < 0 {
                if errno == EINTR { continue }
                return
            }
            offset += written
        }
        size += Int64(bytes.count)
        if size > cap { rotate() }
    }

    private func rotate() {
        close(fd)
        rename(path, path + ".1")
        fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND | O_CLOEXEC, 0o644)
        size = 0
        let name = (path as NSString).lastPathComponent
        write(.ath, "log rotated · earlier lines are in \(name).1")
    }
}
