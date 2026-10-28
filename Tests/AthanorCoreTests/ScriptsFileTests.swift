@testable import AthanorCore
import Testing

struct ScriptsFileTests {
    @Test func decodesWithDefaults() throws {
        let scripts = try ScriptsFile.decode("""
            [[script]]
            command = "caffeinate -dims"

            [[script]]
            name = "rapid-mlx"
            command = '''
            export HF_HOME="$HOME/models/hf"
            exec rapid-mlx serve mlx-community/Qwen3-8B-4bit
            '''
            cwd = "~/models"
            env = { PYTHONUNBUFFERED = "1" }
            autostart = true
            ready = "port"
            port = 8000
            stop_signal = "sigint"
            """)
        #expect(scripts.count == 2)
        #expect(scripts[0].name == "caffeinate")
        #expect(scripts[0].id == "caffeinate")
        #expect(scripts[0].restartOnCrash)
        #expect(scripts[0].ready == .started)
        #expect(scripts[1].id == "rapid-mlx")
        #expect(scripts[1].command == "export HF_HOME=\"$HOME/models/hf\"\nexec rapid-mlx serve mlx-community/Qwen3-8B-4bit")
        #expect(scripts[1].summary == "rapid-mlx serve mlx-community/Qwen3-8B-4bit")
        #expect(scripts[1].env == [EnvVar("PYTHONUNBUFFERED", "1")])
        #expect(scripts[1].autostart)
        #expect(scripts[1].ready == .port(8000))
        #expect(scripts[1].stopSignal == .int)
    }

    @Test func encodeThenDecodeIsLossless() throws {
        var a = ScriptConfig(id: "db-tunnel", name: "db tunnel", command: "ssh -N -L 5432:localhost:5432 staging")
        a.restartLimit = 5
        a.restartWindow = 120
        a.ready = .port(5432)
        var b = ScriptConfig(id: "web", name: "docs \"site\"", command: "cd ~/source/docs\nnpm run dev")
        b.env = [EnvVar("NODE_ENV", "development"), EnvVar("WITH SPACE", "x")]
        b.ready = .url("http://localhost:5173/")
        b.useLoginEnvironment = false
        b.stopSignal = .hup
        b.stopTimeout = 3
        b.cwd = "~/source/docs"
        let text = ScriptsFile.encode([a, b])
        #expect(try ScriptsFile.decode(text) == [a, b])
    }

    @Test func derivesUniqueIDsAroundExplicitOnes() throws {
        let scripts = try ScriptsFile.decode("""
            [[script]]
            name = "Web Server"
            command = "a"
            [[script]]
            id = "web-server"
            command = "b"
            [[script]]
            name = "web server!"
            command = "c"
            """)
        #expect(scripts.map(\.id) == ["web-server-2", "web-server", "web-server-3"])
    }

    @Test func explainsMistakes() {
        func message(_ text: String) -> String? {
            do {
                _ = try ScriptsFile.decode(text)
                return nil
            } catch {
                return "\(error)"
            }
        }
        #expect(message("[[script]]\nname = \"x\"\n") == "script “x” has no command")
        #expect(message("[[script]]\ncommand = \"x\"\nrestart = \"yes\"\n")
            == "script 1: restart should be true or false, not text in quotes")
        #expect(message("[[script]]\ncommand = \"x\"\nready = \"port\"\n")
            == "script 1: ready = \"port\" needs port = …")
        #expect(message("[[script]]\nid = \"a\"\ncommand = \"x\"\n[[script]]\nid = \"a\"\ncommand = \"y\"\n")
            == "two scripts have the id \"a\"")
        #expect(message("[[script]]\nid = \"../x\"\ncommand = \"x\"\n")
            == "script 1: id can only use letters, digits, - _ and .")
        #expect(message("[[script]]\ncommand = x\n")?.hasPrefix("line 2:") == true)
    }

    @Test func slugs() {
        #expect(ScriptsFile.slug("rapid-mlx") == "rapid-mlx")
        #expect(ScriptsFile.slug("  Docs Site (dev)! ") == "docs-site-dev")
        #expect(ScriptsFile.slug("✨") == "script")
        #expect(ScriptsFile.uniqueID(for: "a", taken: ["a", "a-2"]) == "a-3")
    }

    @Test func summaryPicksTheMainLine() {
        func summary(_ command: String) -> String {
            ScriptConfig(id: "x", name: "x", command: command).summary
        }
        #expect(summary("caffeinate -dims") == "caffeinate -dims")
        #expect(summary("# comment\ncd ~/app\nexport A=1\nnpm run dev") == "npm run dev")
        #expect(summary("export A=1\nexec ./server --port 1") == "./server --port 1")
        #expect(summary("i=0\nwhile true; do\n  echo tick\ndone") == "while true; do")
        #expect(summary("PORT=8000 node server.js") == "PORT=8000 node server.js")
    }
}

struct ScriptsFileEditingTests {
    static let handWritten = """
        # my scripts, kept in dotfiles

        [[script]]
        name = "web"   # the docs site
        command = "npm run dev"
        cwd = "~/source/docs"
        color = "blue"        # a key Athanor doesn't know

        # the tunnel needs VPN first
        [[script]]
        name = "tunnel"
        command = "ssh -N db"
        [script.env]
        A = "1"

        [extras]
        note = "kept"
        """

    @Test func replacesOneScriptAndKeepsTheRest() throws {
        var tunnel = try #require(try ScriptsFile.decode(Self.handWritten).last)
        tunnel.command = "ssh -N -L 5432:localhost:5432 db"
        let edited = try #require(ScriptsFile.editing(Self.handWritten, id: "tunnel", to: tunnel))
        #expect(edited.contains("# my scripts, kept in dotfiles"))
        #expect(edited.contains("name = \"web\"   # the docs site"))
        #expect(edited.contains("color = \"blue\"        # a key Athanor doesn't know"))
        #expect(edited.contains("# the tunnel needs VPN first\n[[script]]\nid = \"tunnel\""))
        #expect(edited.contains("[extras]\nnote = \"kept\""))
        #expect(!edited.contains("[script.env]"))
        #expect(try ScriptsFile.decode(edited).last == tunnel)
    }

    @Test func addsAndRemoves() throws {
        let added = ScriptConfig(id: "caffeinate", name: "caffeinate", command: "caffeinate -dims")
        let withNew = try #require(ScriptsFile.editing(Self.handWritten, id: "caffeinate", to: added))
        #expect(withNew.hasPrefix(Self.handWritten))
        #expect(try ScriptsFile.decode(withNew).map(\.id) == ["web", "tunnel", "caffeinate"])

        let withoutWeb = try #require(ScriptsFile.editing(Self.handWritten, id: "web", to: nil))
        #expect(try ScriptsFile.decode(withoutWeb).map(\.id) == ["tunnel"])
        #expect(withoutWeb.hasPrefix("# my scripts, kept in dotfiles\n\n# the tunnel needs VPN first\n[[script]]"))
        #expect(!withoutWeb.contains("npm run dev"))
    }

    @Test func reordersWithCommentsAttached() throws {
        let swapped = try #require(ScriptsFile.reordering(Self.handWritten, to: ["tunnel", "web"]))
        #expect(try ScriptsFile.decode(swapped).map(\.id) == ["tunnel", "web"])
        #expect(swapped.hasPrefix("# my scripts, kept in dotfiles\n\n# the tunnel needs VPN first\n[[script]]\nname = \"tunnel\""))
        #expect(swapped.contains("[script.env]\nA = \"1\"\n\n[[script]]\nname = \"web\"   # the docs site"))
        #expect(swapped.hasSuffix("color = \"blue\"        # a key Athanor doesn't know\n\n[extras]\nnote = \"kept\""))

        #expect(ScriptsFile.reordering(swapped, to: ["web", "tunnel"]) == Self.handWritten)
        #expect(ScriptsFile.reordering(Self.handWritten, to: ["web", "tunnel"]) == Self.handWritten)
    }

    @Test func removingFromTheMiddleLeavesOneBlankLine() throws {
        let a = ScriptConfig(id: "a", name: "a", command: "a")
        let b = ScriptConfig(id: "b", name: "b", command: "b")
        let c = ScriptConfig(id: "c", name: "c", command: "c")
        let removed = try #require(ScriptsFile.editing(ScriptsFile.encode([a, b, c]), id: "b", to: nil))
        #expect(removed == ScriptsFile.encode([a, c]))
    }

    @Test func reordersAWrittenFile() throws {
        let a = ScriptConfig(id: "a", name: "a", command: "a")
        let b = ScriptConfig(id: "b", name: "b", command: "b\nexec c")
        let c = ScriptConfig(id: "c", name: "c", command: "c")
        let text = ScriptsFile.encode([a, b, c])
        let moved = try #require(ScriptsFile.reordering(text, to: ["c", "a", "b"]))
        #expect(moved.hasPrefix(ScriptsFile.header))
        #expect(try ScriptsFile.decode(moved) == [c, a, b])
        #expect(ScriptsFile.reordering(text, to: ["c", "a"]) == nil)
    }

    @Test func refusesWhatItCantReadBack() {
        #expect(ScriptsFile.editing("[[script]]\ncommand = x", id: "x", to: nil) == nil)
        let inline = "script = [{ command = \"a\" }]\n"
        let config = ScriptConfig(id: "b", name: "b", command: "b")
        #expect(ScriptsFile.editing(inline, id: "b", to: config) == nil)
    }
}
