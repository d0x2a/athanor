@testable import AthanorCore
import Testing

struct TOMLTests {
    @Test func readsScalarsAndComments() throws {
        let table = try TOML.parse("""
            # a comment
            name = "rapid-mlx"   # trailing comment
            count = 1_000
            hex = 0xff
            ratio = 0.5
            on = true
            when = 2026-10-12T09:41:00Z
            """)
        #expect(table["name"] == .string("rapid-mlx"))
        #expect(table["count"] == .integer(1000))
        #expect(table["hex"] == .integer(255))
        #expect(table["ratio"] == .float(0.5))
        #expect(table["on"] == .bool(true))
        #expect(table["when"] == .datetime("2026-10-12T09:41:00Z"))
        #expect(table.keys == ["name", "count", "hex", "ratio", "on", "when"])
    }

    @Test func readsStrings() throws {
        let table = try TOML.parse(#"""
            basic = "tab\there \"quoted\" \u00e9"
            literal = 'C:\path\no-escapes'
            block = '''
            line one
              line 'two'
            '''
            joined = """
            one \
               two"""
            quotes = '''ends in '''''
            """#)
        #expect(table["basic"] == .string("tab\there \"quoted\" é"))
        #expect(table["literal"] == .string(#"C:\path\no-escapes"#))
        #expect(table["block"] == .string("line one\n  line 'two'\n"))
        #expect(table["joined"] == .string("one two"))
        #expect(table["quotes"] == .string("ends in ''"))
    }

    @Test func readsArraysOfTablesAndSubtables() throws {
        let table = try TOML.parse("""
            [[script]]
            name = "a"
            env = { PORT = "1", "WITH SPACE" = "2" }

            [[script]]
            name = "b"
            [script.env]
            DEBUG = "1"

            [server]
            ports = [ 8000,
              8001, # second
            ]
            """)
        guard case .array(let scripts)? = table["script"], scripts.count == 2,
              case .table(let first) = scripts[0], case .table(let second) = scripts[1] else {
            Issue.record("expected two scripts")
            return
        }
        guard case .table(let firstEnv)? = first["env"], case .table(let secondEnv)? = second["env"] else {
            Issue.record("expected env tables")
            return
        }
        #expect(firstEnv.keys == ["PORT", "WITH SPACE"])
        #expect(secondEnv["DEBUG"] == .string("1"))
        guard case .table(let server)? = table["server"] else {
            Issue.record("expected [server]")
            return
        }
        #expect(server["ports"] == .array([.integer(8000), .integer(8001)]))
    }

    @Test func reportsErrorsWithLines() {
        func line(of text: String) -> Int? {
            do {
                _ = try TOML.parse(text)
                return nil
            } catch let error as TOMLError {
                return error.line
            } catch {
                return nil
            }
        }
        #expect(line(of: "a = 1\nb = rapid-mlx\n") == 2)
        #expect(line(of: "a = 1\na = 2\n") == 2)
        #expect(line(of: "a = \"unterminated\n") == 1)
        #expect(line(of: "[t]\n[t]\n") == 2)
        #expect(line(of: "\n\nname \"x\"") == 3)
    }

    @Test func writerRoundTrips() throws {
        let tricky = "quote \" backslash \\ tab \t bell \u{07} é"
        let table = try TOML.parse("v = \(TOMLWriter.string(tricky))\nk = 1")
        #expect(table["v"] == .string(tricky))
        let block = "set -e\necho 'hi'\n\tindented"
        let parsed = try TOML.parse("v = \(TOMLWriter.multiline(block))")
        #expect(parsed["v"] == .string(block + "\n"))
        #expect(TOMLWriter.key("PORT") == "PORT")
        #expect(TOMLWriter.key("WITH SPACE") == "\"WITH SPACE\"")
    }
}
