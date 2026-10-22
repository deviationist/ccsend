import Foundation

/// `ccsend selftest`: checks of the pure, security-relevant logic. Run by `make test`.
enum SelfTest {
    static var failures = 0

    static func expect(_ ok: Bool, _ what: String, line: Int = #line) {
        if !ok { failures += 1; print("FAIL line \(line): \(what)") }
    }

    static func rejects(_ toml: String, _ what: String, line: Int = #line) {
        do { _ = try Config.parse(toml); expect(false, "accepted: \(what)", line: line) } catch {}
    }

    static let host = "[hosts.devbox]\nssh = \"devbox\"\n"

    static func run() -> Never {
        // Config: the starter template parses; unknown or unsafe input is refused.
        do {
            let c = try Config.parse(Config.template(hosts: ["devbox", "nas"]))
            expect(c.hosts.map(\.name) == ["devbox", "nas"], "template hosts")
            expect(c.hosts[0].defaultLocation == "~/inbox" && c.hosts[0].allowedRoots == ["~"], "template values")
            expect(c.excludes.contains("node_modules"), "template excludes")
            let o = try Config.parse(host + "user = \"q\"\nssh_options = [\"IdentityFile=~/.ssh/k\", \"IdentitiesOnly=yes\"]\n")
            expect(o.hosts[0].user == "q" && o.hosts[0].sshOptions.count == 2, "user and ssh_options")
            let m = try Config.parse("[folders]\nexcludes = [\n  \"a\", # comment\n  \"b#c\",\n]\n" + host)
            expect(m.excludes == ["a", "b#c"], "multi-line array with comments")
        } catch {
            expect(false, "valid config refused: \(error)")
        }
        rejects("", "no hosts")
        rejects(host + "colour = \"red\"\n", "unknown key")
        rejects("[uii]\n" + host, "unknown table")
        rejects(host + "ssh = \"other\"\n", "duplicate key")
        rejects("[hosts.devbox]\nssh = \"-oProxyCommand=sh\"\n", "option injection via ssh")
        rejects(host + "user = \"-lroot\"\n", "option injection via user")
        rejects(host + "ssh_options = [\"ProxyCommand=sh -c id\"]\n", "ProxyCommand")
        rejects(host + "ssh_options = [\"StrictHostKeyChecking=no\"]\n", "weakening host keys")
        rejects(host + "ssh_options = [\"LocalCommand=id\"]\n", "LocalCommand")
        rejects(host + "allowed_roots = []\n", "empty roots")
        rejects(host + "allowed_roots = [\"relative\"]\n", "relative root")
        rejects(host + "default_location = \"inbox\"\n", "relative default")
        rejects(host + "claude_sessions = \"yes\"\n", "wrong type")
        rejects("[ui]\nmenu = \"tabs\"\n" + host, "bad enum")
        rejects("[ui]\nrefresh_seconds = 1\n" + host, "refresh too fast")
        expect((try? Config.parse("[ui]\nrefresh_seconds = 0\n" + host))?.refreshSeconds == 0, "refresh off")
        rejects(host + "label = \"a\nb\"\n", "unterminated string")

        // Hardened ssh options come before anything configurable (OpenSSH keeps the first value).
        let h = try! Config.parse(host + "ssh_options = [\"IdentityFile=~/.ssh/k\"]\n").hosts[0]
        let args = SSH(host: h, controlPath: nil).baseArgs()
        let firstConfigurable = args.firstIndex(of: "IdentityFile=~/.ssh/k")!
        expect(SSH.hardened.allSatisfy { args.firstIndex(of: $0)! < firstConfigurable }, "hardened options first")

        // Names reported by the host.
        expect(Check.collisionName("a.png", for: "a.png"), "same name")
        expect(Check.collisionName("a-1.png", for: "a.png"), "file collision")
        expect(Check.collisionName("web-12", for: "web"), "dir collision")
        expect(Check.collisionName("a.tar-1.gz", for: "a.tar.gz"), "double extension")
        expect(!Check.collisionName("evil.png", for: "a.png"), "different name")
        expect(!Check.collisionName("a-1.png; rm", for: "a.png"), "junk after suffix")
        expect(!Check.collisionName("a-x.png", for: "a.png"), "non-numeric suffix")
        expect(!Check.path("relative"), "relative path")
        expect(!Check.path("/a\nb"), "newline in path")
        expect(!Check.path("/a\u{202E}b"), "bidi override in path")
        expect(Check.path("/home/q/evil$(x)"), "shell characters are fine as data")
        expect(!Check.name("../x") && !Check.name("..") && !Check.name("a/b"), "traversal names")

        // Clipboard escaping.
        expect(ShellEscape.word("/home/q/a b.png") == "/home/q/a\\ b.png", "space")
        expect(ShellEscape.word("/x/$(id)'\"") == "/x/\\$\\(id\\)\\'\\\"", "metacharacters")
        expect(ShellEscape.word("/x/æøå.png") == "/x/æøå.png", "unicode stays")
        expect(ShellEscape.word("/x/a\nb") == "$'/x/a\\x0ab'", "newline uses $''")
        expect(Display.clean("a\u{1B}[31mb") == "a?[31mb", "ANSI escape cleaned")
        expect(Display.sentence("devbox: cannot connect") == "devbox: Cannot connect", "sentence after host")
        expect(Display.sentence("select files first") == "Select files first", "sentence")
        expect(Display.sentence("") == "", "sentence of empty")
        expect(Log.value("plain/path-1.txt") == "plain/path-1.txt", "log value bare")
        expect(Log.value("a b\n\"c\"") == "\"a b\\n\\\"c\\\"\"", "log value quoted")
        expect(Log.names(["æ ø", "x"]) == "[\"æ ø\",\"x\"]", "log names")

        // Tar: a stream the system tar lists with exact names and link targets.
        tarRoundTrip()

        print(failures == 0 ? "selftest ok" : "selftest: \(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }

    static func tarRoundTrip() {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ccsend-selftest-\(getpid())")
        defer { try? fm.removeItem(at: dir) }
        let long = "Screenshot " + String(repeating: "äöü", count: 30) + ".png"
        try? fm.createDirectory(at: dir.appendingPathComponent("top/sub"), withIntermediateDirectories: true)
        fm.createFile(atPath: dir.appendingPathComponent("top/sub/\(long)").path, contents: Data("hello".utf8))
        fm.createFile(atPath: dir.appendingPathComponent("top/.hidden").path, contents: Data())
        try? fm.createSymbolicLink(atPath: dir.appendingPathComponent("top/link").path, withDestinationPath: "/etc/passwd")
        do {
            let plan = try Plan.build([dir.appendingPathComponent("top").path],
                                      .init(includeHidden: false, applyExcludes: true, excludes: [], alwaysSkip: []))
            expect(plan.skippedHidden == 1, "hidden skipped")
            let tarURL = dir.appendingPathComponent("out.tar")
            fm.createFile(atPath: tarURL.path, contents: nil)
            let fh = try FileHandle(forWritingTo: tarURL)
            var w = TarWriter(out: fh)
            try w.write(plan)
            try fh.close()
            let r = try Proc.run("/usr/bin/tar", ["-tvf", tarURL.path], stdin: nil, timeout: 10)
            let listing = String(decoding: r.stdout, as: UTF8.self)
            expect(r.status == 0, "tar lists the stream: \(r.stderrText)")
            expect(listing.contains("top/sub/\(long)"), "long unicode name survives")
            expect(listing.contains("top/link -> /etc/passwd"), "symlink kept as a link:\n\(listing)")
            expect(!listing.contains(".hidden"), "hidden not in stream")
        } catch {
            expect(false, "tar round trip: \(error)")
        }
    }
}
