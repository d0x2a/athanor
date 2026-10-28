import Foundation

package struct ScriptsFileError: Error, Equatable, CustomStringConvertible {
    package let line: Int?
    package let message: String

    package init(line: Int? = nil, _ message: String) {
        self.line = line
        self.message = message
    }

    package var description: String {
        line.map { "line \($0): \(message)" } ?? message
    }
}

/// scripts.toml: a list of `[[script]]` tables.
///
/// Reading is forgiving: keys Athanor doesn't know are skipped, and missing
/// ones take their defaults. Writing puts every key in, so the file documents
/// itself for whoever edits it by hand.
package enum ScriptsFile {
    package static func decode(_ text: String) throws -> [ScriptConfig] {
        let root: TOMLTable
        do {
            root = try TOML.parse(text)
        } catch let error as TOMLError {
            throw ScriptsFileError(line: error.line, error.message)
        }
        guard let list = root["script"] else { return [] }
        guard case .array(let items) = list else {
            throw ScriptsFileError("write each script as a [[script]] table")
        }
        var scripts: [ScriptConfig] = []
        for (index, item) in items.enumerated() {
            guard case .table(let table) = item else {
                throw ScriptsFileError("write each script as a [[script]] table")
            }
            scripts.append(try decodeScript(table, number: index + 1))
        }

        // Ids written in the file win; the rest are made from names, around them.
        var taken = Set<String>()
        for script in scripts where !script.id.isEmpty {
            guard taken.insert(script.id).inserted else {
                throw ScriptsFileError("two scripts have the id \"\(script.id)\"")
            }
        }
        for index in scripts.indices where scripts[index].id.isEmpty {
            scripts[index].id = uniqueID(for: scripts[index].name, taken: taken)
            taken.insert(scripts[index].id)
        }
        return scripts
    }

    package static func encode(_ scripts: [ScriptConfig]) -> String {
        header + scripts.map { "\n" + block($0) }.joined()
    }

    /// One `[[script]]` table, ending in a line break.
    package static func block(_ script: ScriptConfig) -> String {
        var out = "[[script]]\n"
            out += "id = \(TOMLWriter.string(script.id))\n"
            out += "name = \(TOMLWriter.string(script.name))\n"
            let command = normalizedCommand(script.command)
            let commandValue = command.contains("\n") ? TOMLWriter.multiline(command) : TOMLWriter.string(command)
            out += "command = \(commandValue)\n"
            out += "cwd = \(TOMLWriter.string(script.cwd))\n"
            if !script.env.isEmpty {
                let pairs = script.env.map { "\(TOMLWriter.key($0.key)) = \(TOMLWriter.string($0.value))" }
                out += "env = { \(pairs.joined(separator: ", ")) }\n"
            }
            out += "login_env = \(script.useLoginEnvironment)\n"
            out += "autostart = \(script.autostart)\n"
            out += "restart = \(script.restartOnCrash)\n"
            out += "restart_limit = \(script.restartLimit)\n"
            out += "restart_window = \(script.restartWindow)\n"
            out += "stop_signal = \(TOMLWriter.string(script.stopSignal.rawValue))\n"
            out += "stop_timeout = \(script.stopTimeout)\n"
            switch script.ready {
            case .started:
                out += "ready = \"started\"\n"
            case .port(let port):
                out += "ready = \"port\"\nport = \(port)\n"
            case .url(let url):
                out += "ready = \"url\"\nurl = \(TOMLWriter.string(url))\n"
            }
        return out
    }

    // MARK: Editing in place

    /// The file with the script `id` replaced by `config`, added if there's no
    /// such script, or removed when `config` is nil, and nothing else
    /// touched: comments, keys Athanor doesn't know and the other scripts stay
    /// as they were written. Nil when that can't be done safely (the result
    /// wouldn't read back as intended); then the file has to be rewritten whole.
    package static func editing(_ text: String, id: String, to config: ScriptConfig?) -> String? {
        guard let current = try? decode(text) else { return nil }
        var segments = splitScripts(text)
        guard segments.count == current.count + 1 else { return nil }
        var expected = current
        if let index = current.firstIndex(where: { $0.id == id }) {
            var (_, keep) = splitOffTail(segments[index + 1])
            if let config {
                segments[index + 1] = block(config) + keep
                expected[index] = config
            } else {
                // One blank line where the script was, not two.
                if segments[index].hasSuffix("\n\n"), keep.hasPrefix("\n") { keep.removeFirst() }
                segments[index + 1] = keep
                expected.remove(at: index)
            }
        } else {
            guard let config else { return text }
            var last = segments.removeLast()
            if !last.isEmpty, !last.hasSuffix("\n") { last += "\n" }
            segments.append(last)
            segments.append((last.isEmpty || last.hasSuffix("\n\n") ? "" : "\n") + block(config))
            expected.append(config)
        }
        let result = segments.joined()
        guard let reread = try? decode(result), reread == expected else { return nil }
        return result
    }

    /// The file with its scripts in the order of `ids`. Each script takes the
    /// comment written directly above it along (no blank line between);
    /// everything else, the blank lines and other tables among them, stays
    /// where it was. Nil when that can't be done safely.
    package static func reordering(_ text: String, to ids: [String]) -> String? {
        guard let current = try? decode(text), current.map(\.id).sorted() == ids.sorted() else { return nil }
        let segments = splitScripts(text)
        guard segments.count == current.count + 1 else { return nil }
        var gaps = [segments[0]]
        var units: [String] = []
        for segment in segments.dropFirst() {
            let (script, rest) = splitOffTail(segment)
            let (gap, comment) = splitOffComment(gaps.removeLast())
            gaps.append(gap)
            units.append(comment + script)
            gaps.append(rest)
        }
        let order = ids.compactMap { id in current.firstIndex { $0.id == id } }
        var result = gaps[0]
        for (slot, index) in order.enumerated() {
            result += units[index] + gaps[slot + 1]
        }
        guard let reread = try? decode(result), reread == order.map({ current[$0] }) else { return nil }
        return result
    }

    /// Cuts the text before each `[[script]]` line: what comes before the first
    /// script, then one piece per script.
    private static func splitScripts(_ text: String) -> [String] {
        var segments = [""]
        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let piece = index < lines.count - 1 ? line + "\n" : line
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("[[script]]") {
                segments.append(piece)
            } else {
                segments[segments.count - 1] += piece
            }
        }
        return segments
    }

    /// Splits one script's piece into the script itself and what follows it
    /// that isn't part of it: trailing comments and blank lines (often about
    /// the next script) and any other table, which all stay.
    private static func splitOffTail(_ segment: String) -> (script: String, rest: String) {
        var lines = segment.components(separatedBy: "\n")
        let endsWithBreak = lines.last == ""
        if endsWithBreak { lines.removeLast() }
        var end = lines.count
        for (index, line) in lines.enumerated().dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("["), !trimmed.hasPrefix("[script."), !trimmed.hasPrefix("[ script.") {
                end = index
                break
            }
        }
        var tailStart = end
        while tailStart > 1 {
            let trimmed = lines[tailStart - 1].trimmingCharacters(in: .whitespaces)
            guard trimmed.isEmpty || trimmed.hasPrefix("#") else { break }
            tailStart -= 1
        }
        let join = { (part: ArraySlice<String>) in part.map { $0 + "\n" }.joined() }
        var rest = join(lines[tailStart...])
        if !endsWithBreak, rest.hasSuffix("\n") { rest.removeLast() }
        return (join(lines[..<tailStart]), rest)
    }

    /// Splits the comment lines that end `text`, which sit directly above the
    /// script that follows, from what comes before them.
    private static func splitOffComment(_ text: String) -> (rest: String, comment: String) {
        guard text.hasSuffix("\n") else { return (text, "") }
        var lines = text.components(separatedBy: "\n")
        lines.removeLast()
        var start = lines.count
        while start > 0, lines[start - 1].trimmingCharacters(in: .whitespaces).hasPrefix("#") {
            start -= 1
        }
        let join = { (part: ArraySlice<String>) in part.map { $0 + "\n" }.joined() }
        return (join(lines[..<start]), join(lines[start...]))
    }

    package static let header = """
        # Athanor's scripts. Each [[script]] runs with /bin/sh -c.
        # Athanor reloads this file when it changes, so it can be edited by hand.
        #
        # id              names the script's log and run state; set once
        # cwd             folder the script starts in
        # env             extra variables, e.g. env = { PORT = "8000" }
        # login_env       start from your login shell's environment (PATH etc.)
        # autostart       start when Athanor opens
        # restart         restart after a crash, at most restart_limit times
        #                 within restart_window seconds
        # stop_signal     TERM, INT, HUP or QUIT; SIGKILL follows after
        #                 stop_timeout seconds
        # ready           "started", "port" (with port = 8000) or
        #                 "url" (with url = "http://127.0.0.1:8000/health")

        """

    /// Commands are kept without blank lines at either end or trailing
    /// whitespace; a ''' block gives one back, and none of it means anything
    /// to sh.
    package static func normalizedCommand(_ command: String) -> String {
        var lines = command.split(separator: "\n", omittingEmptySubsequences: false).map {
            String($0.reversed().drop(while: { $0 == " " || $0 == "\t" || $0 == "\r" }).reversed())
        }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    // MARK: Ids

    /// Lowercase letters and digits, runs of anything else as one dash.
    package static func slug(_ name: String) -> String {
        var out = ""
        var pendingDash = false
        for scalar in name.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                if pendingDash, !out.isEmpty { out += "-" }
                out.unicodeScalars.append(scalar)
                pendingDash = false
            } else {
                pendingDash = true
            }
        }
        return out.isEmpty ? "script" : String(out.prefix(48))
    }

    package static func uniqueID(for name: String, taken: Set<String>) -> String {
        let base = slug(name)
        var id = base
        var suffix = 2
        while taken.contains(id) {
            id = "\(base)-\(suffix)"
            suffix += 1
        }
        return id
    }

    /// Ids end up in file names.
    package static func isValidID(_ id: String) -> Bool {
        guard let first = id.unicodeScalars.first, first != ".", first != "-" else { return false }
        return id.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0)
                || $0 == "-" || $0 == "_" || $0 == "."
        }
    }

    // MARK: Reading one script

    private static func decodeScript(_ table: TOMLTable, number: Int) throws -> ScriptConfig {
        var label = "script \(number)"
        if case .string(let name)? = table["name"], !name.isEmpty { label = "script “\(name)”" }
        let fields = Fields(table: table, label: label)

        guard let rawCommand = try fields.string("command") else {
            throw ScriptsFileError("\(label) has no command")
        }
        let command = normalizedCommand(rawCommand)
        guard !command.isEmpty else { throw ScriptsFileError("\(label) has an empty command") }

        let name = try fields.string("name").flatMap { $0.isEmpty ? nil : $0 }
            ?? String(command.split(whereSeparator: { $0 == " " || $0 == "\n" }).first ?? "script")
        var script = ScriptConfig(id: "", name: name, command: command)

        if let id = try fields.string("id"), !id.isEmpty {
            guard isValidID(id) else {
                throw ScriptsFileError("\(label): id can only use letters, digits, - _ and .")
            }
            script.id = id
        }
        if let cwd = try fields.string("cwd"), !cwd.isEmpty { script.cwd = cwd }
        if let env = table["env"] {
            guard case .table(let vars) = env else {
                throw ScriptsFileError("\(label): env should look like env = { NAME = \"value\" }")
            }
            script.env = try vars.keys.map { key in
                switch vars[key]! {
                case .string(let value): EnvVar(key, value)
                case .integer(let value): EnvVar(key, String(value))
                case .float(let value): EnvVar(key, String(value))
                case .bool(let value): EnvVar(key, String(value))
                default: throw ScriptsFileError("\(label): env.\(key) should be text in quotes")
                }
            }
        }
        if let value = try fields.bool("login_env") { script.useLoginEnvironment = value }
        if let value = try fields.bool("autostart") { script.autostart = value }
        if let value = try fields.bool("restart") { script.restartOnCrash = value }
        if let value = try fields.int("restart_limit", 0...1000) { script.restartLimit = value }
        if let value = try fields.int("restart_window", 1...604_800) { script.restartWindow = value }
        if let value = try fields.string("stop_signal") {
            guard let signal = StopSignal(name: value) else {
                throw ScriptsFileError("\(label): stop_signal should be TERM, INT, HUP or QUIT")
            }
            script.stopSignal = signal
        }
        if let value = try fields.int("stop_timeout", 1...3600) { script.stopTimeout = value }

        let port = try fields.int("port", 1...65535)
        let url = try fields.string("url")
        switch try fields.string("ready")?.lowercased() {
        case nil:
            if let port { script.ready = .port(port) } else if let url { script.ready = .url(url) }
        case "started":
            script.ready = .started
        case "port":
            guard let port else { throw ScriptsFileError("\(label): ready = \"port\" needs port = …") }
            script.ready = .port(port)
        case "url":
            guard let url, !url.isEmpty else { throw ScriptsFileError("\(label): ready = \"url\" needs url = \"…\"") }
            script.ready = .url(url)
        case let other?:
            throw ScriptsFileError("\(label): ready should be \"started\", \"port\" or \"url\", not \"\(other)\"")
        }
        return script
    }

    private struct Fields {
        let table: TOMLTable
        let label: String

        func string(_ key: String) throws -> String? {
            guard let value = table[key] else { return nil }
            guard case .string(let text) = value else { throw mismatch(key, "text in quotes", value) }
            return text
        }

        func bool(_ key: String) throws -> Bool? {
            guard let value = table[key] else { return nil }
            guard case .bool(let flag) = value else { throw mismatch(key, "true or false", value) }
            return flag
        }

        func int(_ key: String, _ range: ClosedRange<Int>) throws -> Int? {
            guard let value = table[key] else { return nil }
            guard case .integer(let number) = value else { throw mismatch(key, "a whole number", value) }
            guard let int = Int(exactly: number), range.contains(int) else {
                throw ScriptsFileError("\(label): \(key) should be between \(range.lowerBound) and \(range.upperBound)")
            }
            return int
        }

        private func mismatch(_ key: String, _ expected: String, _ value: TOMLValue) -> ScriptsFileError {
            ScriptsFileError("\(label): \(key) should be \(expected), not \(value.typeName)")
        }
    }
}
