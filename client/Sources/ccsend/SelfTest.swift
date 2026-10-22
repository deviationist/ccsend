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
        rejects(host + "inject = \"yes\"\n", "bad inject")
        rejects(host + "inject_via = [\"screen\"]\n", "unknown adapter")
        rejects(host + "inject_via = []\n", "no adapters")
        expect((try? Config.parse(host))?.hosts[0].importEnabled == false, "import is off unless enabled")
        rejects(host + "import_roots = []\n", "empty import roots")
        rejects(host + "import_roots = [\"relative\"]\n", "relative import root")
        expect((try? Config.parse(host))?.hosts[0].injectVia == [.tmux], "tmux is the default adapter")
        expect((try? Config.parse(host))?.hosts[0].inject == .off, "inject is off unless enabled")
        expect((try? Config.parse(host + "inject = \"type\"\n"))?.hosts[0].inject == .type, "inject type")
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
        importChecks()

        print(failures == 0 ? "selftest ok" : "selftest: \(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }

    /// Feed the Importer archives made by Python's tarfile, including hostile ones.
    static func importChecks() {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ccsend-import-\(getpid())").path
        defer { try? fm.removeItem(atPath: root) }
        try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        let maker = """
        import io, sys, tarfile
        kind = sys.argv[1]
        buf = io.BytesIO()
        t = tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT)
        def f(name, data=b"x", mode=0o644):
            ti = tarfile.TarInfo(name); ti.size = len(data); ti.mode = mode; t.addfile(ti, io.BytesIO(data))
        def e(name, typ, link=""):
            ti = tarfile.TarInfo(name); ti.type = typ; ti.linkname = link; ti.mode = 0o755; t.addfile(ti)
        if kind == "ok":
            e("proj", tarfile.DIRTYPE); e("proj/sub", tarfile.DIRTYPE); f("proj/sub/a.txt", b"hello")
            f("proj/run.sh", b"#!/bin/sh", 0o4755); f("proj/" + "ü" * 60 + ".txt", b"long")
        elif kind == "abs": f("/tmp/evil")
        elif kind == "dotdot": e("proj", tarfile.DIRTYPE); f("proj/../../evil")
        elif kind == "other": f("other.txt")
        elif kind == "link": e("proj", tarfile.DIRTYPE); e("proj/l", tarfile.SYMTYPE, "/etc/passwd")
        elif kind == "through": e("proj", tarfile.DIRTYPE); e("proj/l", tarfile.SYMTYPE, sys.argv[2]); f("proj/l/pwned")
        elif kind == "hard": e("proj", tarfile.DIRTYPE); e("proj/h", tarfile.LNKTYPE, "/etc/passwd")
        elif kind == "dev": e("proj", tarfile.DIRTYPE); e("proj/d", tarfile.CHRTYPE)
        elif kind == "big": e("proj", tarfile.DIRTYPE); f("proj/a", b"y" * 5000)
        t.close()
        data = buf.getvalue()
        sys.stdout.buffer.write(data[:700] if kind == "short" else data)
        """
        func stream(_ kind: String, _ extra: String = "") -> FileHandle? {
            let k = kind == "short" ? "ok" : kind
            guard let r = try? Proc.run("/usr/bin/python3", ["-c", maker, k, extra], stdin: nil, timeout: 20), r.status == 0 else { return nil }
            var data = r.stdout
            if kind == "short" { data = data.prefix(700) }
            let p = root + "/stream-\(kind)"
            fm.createFile(atPath: p, contents: data)
            return FileHandle(forReadingAtPath: p)
        }
        func run(_ kind: String, tops: [String] = ["proj"], links: Bool = false, maxBytes: Int64 = 1 << 20,
                 extra: String = "", into dir: String) -> (Importer, Error?) {
            let imp = Importer(dest: dir, tops: tops, allowSymlinks: links, maxBytes: maxBytes, maxFiles: 100)
            guard let fh = stream(kind, extra) else { return (imp, RemoteError("no stream")) }
            do { try imp.consume(fh); return (imp, nil) } catch { return (imp, error) }
        }
        func fresh(_ name: String) -> String {
            let d = root + "/" + name
            try? fm.createDirectory(atPath: d, withIntermediateDirectories: true)
            return d
        }

        let ok = fresh("ok")
        let (imp, err) = run("ok", into: ok)
        expect(err == nil, "import ok: \(String(describing: err))")
        expect((try? String(contentsOfFile: ok + "/proj/sub/a.txt", encoding: .utf8)) == "hello", "file content")
        var st = stat()
        stat(ok + "/proj/run.sh", &st)
        expect(st.st_mode & 0o7000 == 0 && st.st_mode & 0o111 != 0, "setuid dropped, executable kept")
        expect(getxattr(ok + "/proj/sub/a.txt", "com.apple.quarantine", nil, 0, 0, 0) > 0, "quarantine set")
        expect(fm.fileExists(atPath: ok + "/proj/" + String(repeating: "ü", count: 60) + ".txt"), "long pax name")
        expect(imp.localPaths == [ok + "/proj"], "local paths")
        let (imp2, err2) = run("ok", into: ok)
        expect(err2 == nil && imp2.localPaths == [ok + "/proj-1"], "collision gets -1")

        let victim = fresh("victim")
        for (kind, tops, links) in [("abs", ["proj"], false), ("dotdot", ["proj"], false), ("other", ["proj"], false),
                                    ("link", ["proj"], false), ("through", ["proj"], true), ("hard", ["proj"], false),
                                    ("dev", ["proj"], false), ("short", ["proj"], false), ("big", ["proj"], false)] {
            let d = fresh("bad-" + kind)
            let (_, e) = run(kind, tops: tops, links: links, maxBytes: kind == "big" ? 1000 : 1 << 20, extra: victim, into: d)
            expect(e != nil, "refused: \(kind)")
            expect((try? fm.contentsOfDirectory(atPath: d))?.isEmpty == true, "nothing left behind: \(kind)")
        }
        expect((try? fm.contentsOfDirectory(atPath: victim))?.isEmpty == true, "nothing written through a link")
        let (_, el) = run("link", links: true, into: fresh("links-on"))
        expect(el == nil, "links kept when allowed")
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
