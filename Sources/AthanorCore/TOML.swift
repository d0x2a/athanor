import Foundation

/// A TOML value. Dates and times keep their source text: scripts.toml has no
/// use for them, so they only need to survive being read.
package enum TOMLValue: Equatable, Sendable {
    case string(String)
    case integer(Int64)
    case float(Double)
    case bool(Bool)
    case datetime(String)
    case array([TOMLValue])
    case table(TOMLTable)

    package var typeName: String {
        switch self {
        case .string: "text in quotes"
        case .integer: "a whole number"
        case .float: "a number"
        case .bool: "true or false"
        case .datetime: "a date"
        case .array: "a list"
        case .table: "a table"
        }
    }
}

/// A table that remembers the order its keys were written in.
package struct TOMLTable: Equatable, Sendable {
    package private(set) var keys: [String] = []
    private var values: [String: TOMLValue] = [:]

    package init() {}

    package subscript(key: String) -> TOMLValue? {
        get { values[key] }
        set {
            if let newValue {
                if values.updateValue(newValue, forKey: key) == nil { keys.append(key) }
            } else if values.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }
}

package struct TOMLError: Error, Equatable, CustomStringConvertible {
    package let line: Int
    package let message: String

    package var description: String { "line \(line): \(message)" }
}

/// Reads TOML 1.0, plus 1.1's `\e` escape and line breaks inside inline tables.
package enum TOML {
    package static func parse(_ text: String) throws -> TOMLTable {
        var parser = Parser(text)
        return try parser.parseDocument()
    }
}

/// Writes the pieces of TOML that scripts.toml is made of.
package enum TOMLWriter {
    package static func key(_ key: String) -> String {
        if !key.isEmpty, key.unicodeScalars.allSatisfy(isBareKeyScalar) { return key }
        return string(key)
    }

    /// A "basic string", escaped.
    package static func string(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// Several lines as a ''' block, which needs no escaping, so it reads the
    /// way it was typed. Text that can't go in one becomes an escaped string.
    /// Reading the block back gives `text` plus a trailing line break.
    package static func multiline(_ text: String) -> String {
        let fits = !text.contains("'''") && text.unicodeScalars.allSatisfy {
            $0 == "\n" || $0 == "\t" || ($0.value >= 0x20 && $0.value != 0x7F)
        }
        return fits ? "'''\n" + text + "\n'''" : string(text)
    }
}

private func isBareKeyScalar(_ c: Unicode.Scalar) -> Bool {
    ("a"..."z").contains(c) || ("A"..."Z").contains(c) || ("0"..."9").contains(c) || c == "_" || c == "-"
}

private func isDigit(_ c: Unicode.Scalar) -> Bool {
    ("0"..."9").contains(c)
}

// MARK: - Parser

/// Tables stay mutable while the document is read, because a later [header]
/// or dotted key can add to a table opened earlier.
private final class TableBuilder {
    private var keys: [String] = []
    private var nodes: [String: Node] = [:]
    var definedByHeader = false

    subscript(key: String) -> Node? {
        get { nodes[key] }
        set {
            if nodes[key] == nil { keys.append(key) }
            nodes[key] = newValue
        }
    }

    func build() -> TOMLTable {
        var table = TOMLTable()
        for key in keys {
            switch nodes[key]! {
            case .value(let value): table[key] = value
            case .table(let builder): table[key] = .table(builder.build())
            case .tables(let builders): table[key] = .array(builders.map { .table($0.build()) })
            }
        }
        return table
    }
}

private enum Node {
    case value(TOMLValue)
    case table(TableBuilder)
    case tables([TableBuilder])
}

private struct Parser {
    private let chars: [Unicode.Scalar]
    private var pos = 0
    private var line = 1
    private let root: TableBuilder
    private var current: TableBuilder

    init(_ text: String) {
        chars = Array(text.unicodeScalars)
        let root = TableBuilder()
        self.root = root
        current = root
    }

    mutating func parseDocument() throws -> TOMLTable {
        while true {
            skipBlank()
            guard let c = peek() else { break }
            if c == "[" {
                advance()
                let isArray = peek() == "["
                if isArray { advance() }
                skipSpaces()
                let path = try parseKeyPath()
                skipSpaces()
                try expect("]", isArray ? "]] to close the header" : "] to close the header")
                if isArray {
                    try expect("]", "]] to close the header")
                    try openArrayTable(path)
                } else {
                    try openTable(path)
                }
                try expectLineEnd()
            } else {
                try parseKeyValue(into: current)
                try expectLineEnd()
            }
        }
        return root.build()
    }

    // MARK: Characters

    private func peek(_ offset: Int = 0) -> Unicode.Scalar? {
        let index = pos + offset
        return index < chars.count ? chars[index] : nil
    }

    private mutating func advance() {
        if chars[pos] == "\n" { line += 1 }
        pos += 1
    }

    private func error(_ message: String) -> TOMLError {
        TOMLError(line: line, message: message)
    }

    private func describe(_ c: Unicode.Scalar?) -> String {
        switch c {
        case nil: "the end of the file"
        case "\n"?, "\r"?: "a line break"
        case let c?: "“\(c)”"
        }
    }

    private mutating func skipSpaces() {
        while let c = peek(), c == " " || c == "\t" { advance() }
    }

    private mutating func skipComment() {
        guard peek() == "#" else { return }
        while let c = peek(), c != "\n" { advance() }
    }

    /// Spaces, comments and line breaks: what can sit between statements,
    /// and between the items of a list.
    private mutating func skipBlank() {
        while let c = peek() {
            if c == " " || c == "\t" || c == "\n" || c == "\r" {
                advance()
            } else if c == "#" {
                skipComment()
            } else {
                break
            }
        }
    }

    private mutating func expectLineEnd() throws {
        skipSpaces()
        skipComment()
        guard let c = peek() else { return }
        if c == "\n" { advance(); return }
        if c == "\r", peek(1) == "\n" { advance(); advance(); return }
        throw error("expected the end of the line, found \(describe(c))")
    }

    private mutating func expect(_ c: Unicode.Scalar, _ what: String) throws {
        guard peek() == c else { throw error("expected \(what), found \(describe(peek()))") }
        advance()
    }

    // MARK: Keys and tables

    private mutating func parseKeyPath() throws -> [String] {
        var path = [try parseKey()]
        skipSpaces()
        while peek() == "." {
            advance()
            skipSpaces()
            path.append(try parseKey())
            skipSpaces()
        }
        return path
    }

    private mutating func parseKey() throws -> String {
        switch peek() {
        case "\""?:
            return try parseBasicString()
        case "'"?:
            return try parseLiteralString()
        default:
            var key = ""
            while let c = peek(), isBareKeyScalar(c) {
                key.unicodeScalars.append(c)
                advance()
            }
            if key.isEmpty { throw error("expected a name, found \(describe(peek()))") }
            return key
        }
    }

    /// Walks `path` down from `start`, making tables as it goes. Into an array
    /// of tables it goes through the last one, as headers do.
    private func descend(_ path: ArraySlice<String>, from start: TableBuilder, fullPath: [String]) throws -> TableBuilder {
        var table = start
        for key in path {
            switch table[key] {
            case nil:
                let next = TableBuilder()
                table[key] = .table(next)
                table = next
            case .table(let next)?:
                table = next
            case .tables(let tables)?:
                table = tables[tables.count - 1]
            case .value?:
                throw error("`\(fullPath.joined(separator: "."))` can't be a table: `\(key)` already has a value")
            }
        }
        return table
    }

    private mutating func openTable(_ path: [String]) throws {
        let name = path.joined(separator: ".")
        let parent = try descend(path.dropLast(), from: root, fullPath: path)
        let key = path[path.count - 1]
        switch parent[key] {
        case nil:
            let table = TableBuilder()
            table.definedByHeader = true
            parent[key] = .table(table)
            current = table
        case .table(let table)?:
            if table.definedByHeader { throw error("[\(name)] appears twice") }
            table.definedByHeader = true
            current = table
        case .tables?:
            throw error("[\(name)] was already used as [[\(name)]]")
        case .value?:
            throw error("`\(name)` already has a value, so it can't be a table")
        }
    }

    private mutating func openArrayTable(_ path: [String]) throws {
        let name = path.joined(separator: ".")
        let parent = try descend(path.dropLast(), from: root, fullPath: path)
        let key = path[path.count - 1]
        let table = TableBuilder()
        switch parent[key] {
        case nil:
            parent[key] = .tables([table])
        case .tables(let tables)?:
            parent[key] = .tables(tables + [table])
        default:
            throw error("[[\(name)]] can't be used: `\(name)` was already set another way")
        }
        current = table
    }

    private mutating func parseKeyValue(into table: TableBuilder) throws {
        let path = try parseKeyPath()
        let name = path.joined(separator: ".")
        skipSpaces()
        guard peek() == "=" else { throw error("expected = after `\(name)`, found \(describe(peek()))") }
        advance()
        skipSpaces()
        let value = try parseValue()
        let parent = try descend(path.dropLast(), from: table, fullPath: path)
        let key = path[path.count - 1]
        if parent[key] != nil { throw error("`\(name)` is set twice") }
        parent[key] = .value(value)
    }

    // MARK: Values

    private mutating func parseValue() throws -> TOMLValue {
        switch peek() {
        case "\""?:
            if peek(1) == "\"", peek(2) == "\"" { return .string(try parseMultilineString(quote: "\"")) }
            return .string(try parseBasicString())
        case "'"?:
            if peek(1) == "'", peek(2) == "'" { return .string(try parseMultilineString(quote: "'")) }
            return .string(try parseLiteralString())
        case "["?:
            return try parseArray()
        case "{"?:
            return try parseInlineTable()
        default:
            return try parseScalar()
        }
    }

    private mutating func parseBasicString() throws -> String {
        advance()
        var out = String.UnicodeScalarView()
        while true {
            guard let c = peek() else { throw error("this \"text\" never ends; add the closing quote") }
            switch c {
            case "\"":
                advance()
                return String(out)
            case "\n", "\r":
                throw error("line break inside \"text\"; use \"\"\" or ''' for several lines")
            case "\\":
                advance()
                out.append(try parseEscape())
            default:
                out.append(c)
                advance()
            }
        }
    }

    private mutating func parseLiteralString() throws -> String {
        advance()
        var out = String.UnicodeScalarView()
        while true {
            guard let c = peek() else { throw error("this 'text' never ends; add the closing quote") }
            if c == "'" {
                advance()
                return String(out)
            }
            if c == "\n" || c == "\r" {
                throw error("line break inside 'text'; use ''' for several lines")
            }
            out.append(c)
            advance()
        }
    }

    /// """…""" (escapes allowed) or '''…''' (taken as written).
    private mutating func parseMultilineString(quote: Unicode.Scalar) throws -> String {
        advance(); advance(); advance()
        // A line break right after the opening quotes isn't part of the text.
        if peek() == "\n" {
            advance()
        } else if peek() == "\r", peek(1) == "\n" {
            advance(); advance()
        }
        var out = String.UnicodeScalarView()
        while true {
            guard let c = peek() else {
                throw error("this \(String(repeating: String(quote), count: 3)) text never ends")
            }
            if c == quote, peek(1) == quote, peek(2) == quote {
                advance(); advance(); advance()
                // Up to two more quotes are part of the text: '''it''''' ends in ''.
                var extra = 0
                while extra < 2, peek() == quote {
                    out.append(quote)
                    advance()
                    extra += 1
                }
                return String(out)
            }
            if c == "\r", peek(1) == "\n" {
                advance()
                continue
            }
            if quote == "\"", c == "\\" {
                if skipLineEndingBackslash() { continue }
                advance()
                out.append(try parseEscape())
                continue
            }
            out.append(c)
            advance()
        }
    }

    /// A `\` that ends its line joins the next one on: the backslash, the
    /// line break and the indentation after it all go.
    private mutating func skipLineEndingBackslash() -> Bool {
        var index = pos + 1
        while index < chars.count, chars[index] == " " || chars[index] == "\t" { index += 1 }
        guard index < chars.count, chars[index] == "\n" || chars[index] == "\r" else { return false }
        while pos < index { advance() }
        while let c = peek(), c == " " || c == "\t" || c == "\n" || c == "\r" { advance() }
        return true
    }

    private mutating func parseEscape() throws -> Unicode.Scalar {
        guard let c = peek() else { throw error("the text ends in the middle of an escape") }
        advance()
        switch c {
        case "b": return "\u{08}"
        case "t": return "\t"
        case "n": return "\n"
        case "f": return "\u{0C}"
        case "r": return "\r"
        case "e": return "\u{1B}"
        case "\"": return "\""
        case "\\": return "\\"
        case "u": return try parseUnicodeEscape(digits: 4)
        case "U": return try parseUnicodeEscape(digits: 8)
        default: throw error("\\\(c) isn't an escape TOML knows; write \\\\ for a backslash")
        }
    }

    private mutating func parseUnicodeEscape(digits: Int) throws -> Unicode.Scalar {
        var hex = ""
        for _ in 0..<digits {
            guard let c = peek(), c.properties.isASCIIHexDigit else {
                throw error("expected \(digits) hex digits in a \\\(digits == 4 ? "u" : "U") escape")
            }
            hex.unicodeScalars.append(c)
            advance()
        }
        guard let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) else {
            throw error("\\u\(hex) isn't a character")
        }
        return scalar
    }

    private mutating func parseArray() throws -> TOMLValue {
        advance()
        var items: [TOMLValue] = []
        while true {
            skipBlank()
            if peek() == "]" {
                advance()
                return .array(items)
            }
            items.append(try parseValue())
            skipBlank()
            if peek() == "," {
                advance()
            } else if peek() == "]" {
                advance()
                return .array(items)
            } else {
                throw error("expected , or ] in the list, found \(describe(peek()))")
            }
        }
    }

    private mutating func parseInlineTable() throws -> TOMLValue {
        advance()
        let table = TableBuilder()
        skipBlank()
        if peek() == "}" {
            advance()
            return .table(table.build())
        }
        while true {
            skipBlank()
            try parseKeyValue(into: table)
            skipBlank()
            if peek() == "," {
                advance()
                skipBlank()
                if peek() == "}" {
                    advance()
                    break
                }
            } else if peek() == "}" {
                advance()
                break
            } else {
                throw error("expected , or } in the { … } table, found \(describe(peek()))")
            }
        }
        return .table(table.build())
    }

    /// Numbers, booleans, and dates.
    private mutating func parseScalar() throws -> TOMLValue {
        func isTokenScalar(_ c: Unicode.Scalar) -> Bool {
            isBareKeyScalar(c) || c == "+" || c == "." || c == ":"
        }
        var token = ""
        while let c = peek(), isTokenScalar(c) {
            token.unicodeScalars.append(c)
            advance()
        }
        // A date and a time can be split by a space instead of a T.
        if isDate(token), peek() == " ", let next = peek(1), isDigit(next) {
            advance()
            token += " "
            while let c = peek(), isTokenScalar(c) {
                token.unicodeScalars.append(c)
                advance()
            }
        }
        if token.isEmpty { throw error("expected a value, found \(describe(peek()))") }
        switch token {
        case "true": return .bool(true)
        case "false": return .bool(false)
        case "inf", "+inf": return .float(.infinity)
        case "-inf": return .float(-.infinity)
        case "nan", "+nan", "-nan": return .float(.nan)
        default: break
        }
        if isDate(token) || isTime(token) { return .datetime(token) }
        let digits = token.replacingOccurrences(of: "_", with: "")
        for (prefix, radix) in [("0x", 16), ("0o", 8), ("0b", 2)] where digits.hasPrefix(prefix) {
            if let value = Int64(digits.dropFirst(2), radix: radix) { return .integer(value) }
            throw error("\(token) isn't a number")
        }
        if let value = Int64(digits) { return .integer(value) }
        if digits.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }), let value = Double(digits) {
            return .float(value)
        }
        throw error("\(token) isn't a value TOML understands; text needs quotes, like \"\(token)\"")
    }

    private func isDate(_ token: String) -> Bool {
        let s = Array(token.unicodeScalars)
        guard s.count >= 10 else { return false }
        return s[0..<4].allSatisfy(isDigit) && s[4] == "-" && s[5..<7].allSatisfy(isDigit)
            && s[7] == "-" && s[8..<10].allSatisfy(isDigit)
    }

    private func isTime(_ token: String) -> Bool {
        let s = Array(token.unicodeScalars)
        guard s.count >= 5 else { return false }
        return s[0..<2].allSatisfy(isDigit) && s[2] == ":" && s[3..<5].allSatisfy(isDigit)
    }
}
