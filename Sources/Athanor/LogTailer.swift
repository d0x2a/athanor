import AthanorCore
import Foundation

/// Follows scripts' log files and hands new lines over in batches.
///
/// Polls twice a second rather than watching with kqueue: a stat per file is
/// cheap, and polling copes the same way with a file that doesn't exist yet,
/// one that was rotated, and one that was truncated.
final class LogTailer: @unchecked Sendable {
    /// Lines per script id, in file order.
    typealias Delivery = @Sendable ([String: [LogLine]]) -> Void

    private struct Tail {
        let url: URL
        var handle: FileHandle?
        var inode: UInt64 = 0
        var offset: UInt64 = 0
        var partial = Data()
        var isFirstOpen = true
        /// After skipping ahead, the first bytes are the end of some line.
        var skipToLineStart = false
    }

    /// How much of an existing log to show when following starts.
    private let backlog: UInt64 = 256 * 1024
    /// More unread than this and the reader skips ahead.
    private let maxRead: UInt64 = 4 * 1024 * 1024

    // Touched only on `queue`.
    private let queue = DispatchQueue(label: "athanor.logtail", qos: .utility)
    private var tails: [String: Tail] = [:]
    private var timer: DispatchSourceTimer?
    private let deliver: Delivery

    init(deliver: @escaping Delivery) {
        self.deliver = deliver
    }

    func start() {
        queue.async { [self] in
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 0.5)
            timer.setEventHandler { [self] in poll() }
            timer.resume()
            self.timer = timer
        }
    }

    func follow(_ id: String, url: URL) {
        queue.async { [self] in
            guard tails[id] == nil else { return }
            tails[id] = Tail(url: url)
            poll(only: id)
        }
    }

    func stop(_ id: String) {
        queue.async { [self] in
            try? tails[id]?.handle?.close()
            tails[id] = nil
        }
    }

    private func poll(only: String? = nil) {
        var batch: [String: [LogLine]] = [:]
        for id in only.map({ [$0] }) ?? Array(tails.keys) {
            guard var tail = tails[id] else { continue }
            let lines = read(&tail)
            tails[id] = tail
            if !lines.isEmpty { batch[id] = lines }
        }
        if !batch.isEmpty { deliver(batch) }
    }

    private func read(_ tail: inout Tail) -> [LogLine] {
        var info = stat()
        guard stat(tail.url.path, &info) == 0 else {
            try? tail.handle?.close()
            tail.handle = nil
            return []
        }
        let size = UInt64(max(0, info.st_size))
        let inode = UInt64(info.st_ino)
        var lines: [LogLine] = []
        if let old = tail.handle, inode != tail.inode {
            // Rotated: the old file may have lines written since the last poll.
            try? old.seek(toOffset: tail.offset)
            lines += split(old.readDataToEndOfFile(), into: &tail)
            if !tail.partial.isEmpty {
                lines.append(LogFormat.parse(Substring(String(decoding: tail.partial, as: UTF8.self))))
            }
        }
        if tail.handle == nil || inode != tail.inode || size < tail.offset {
            // New, rotated or truncated: (re)open. Only the first open starts
            // near the end; after that a new file is read from its beginning.
            try? tail.handle?.close()
            guard let handle = FileHandle(forReadingAtPath: tail.url.path) else { return lines }
            tail.handle = handle
            tail.inode = inode
            tail.partial = Data()
            tail.offset = tail.isFirstOpen && size > backlog ? size - backlog : 0
            tail.isFirstOpen = false
            if tail.offset > 0 {
                // Start at a line boundary.
                try? handle.seek(toOffset: tail.offset)
                let chunk = handle.readData(ofLength: 4096)
                if let newline = chunk.firstIndex(of: 0x0A) {
                    tail.offset += UInt64(newline - chunk.startIndex + 1)
                }
            }
        }
        guard size > tail.offset, let handle = tail.handle else { return lines }
        if size - tail.offset > maxRead {
            tail.offset = size - maxRead
            tail.partial = Data()
            tail.skipToLineStart = true
        }
        do {
            try handle.seek(toOffset: tail.offset)
        } catch {
            return lines
        }
        let data = handle.readData(ofLength: Int(size - tail.offset))
        tail.offset += UInt64(data.count)
        return lines + split(data, into: &tail)
    }

    /// Complete lines from `data` after what was left over last time; keeps
    /// the unfinished end for next time.
    private func split(_ data: Data, into tail: inout Tail) -> [LogLine] {
        var buffer = tail.partial + data
        if tail.skipToLineStart {
            guard let newline = buffer.firstIndex(of: 0x0A) else {
                tail.partial = Data()
                return []
            }
            buffer = buffer[(newline + 1)...]
            tail.skipToLineStart = false
        }
        var lines: [LogLine] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let text = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            lines.append(LogFormat.parse(Substring(text)))
            buffer = buffer[(newline + 1)...]
        }
        tail.partial = Data(buffer)
        return lines
    }
}
