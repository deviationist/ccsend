import Foundation

let usage = """
usage:
  ccsend ui [--host HOST] [--] FILE...        the send window (what the Quick Actions run)
  ccsend ui-import --host HOST [--to DIR | --finder] [-- ITEM...]   the import window
  ccsend send [options] HOST [DEST] FILE...    send without a window
        DEST: claude (newest Claude session) | claude:DIR (the Claude session in DIR)
              shell (newest SSH shell) | shell:DIR | default | /path | ~/path
              guess (a session or folder named like the files) | pick (choose, with fzf if installed)
              With one FILE and no DEST, or with -- before the files, you choose at the terminal.
        --hidden      include hidden files in folders
        --all         do not apply the exclude list
        --yes         send even when over the configured limits
        --no-inject   do not type the path into the Claude prompt (when the host has inject on)
        --trash       move the originals to the Trash after a complete send
  ccsend import HOST [options] REMOTE_PATH...  fetch files or folders (same parent folder) into --to DIR
        --to DIR      Mac folder to import into (default: the current folder)
        --hidden / --all / --links / --yes   hidden files, no excludes, keep links, over limits
                      (only for hosts with import = true)
  ccsend sessions HOST                         list the host's Claude sessions and SSH shells
  ccsend check                                 validate the config and test every host
  ccsend log [--host HOST] [-n N]              last N events from the Mac log, or from HOST's journal
  ccsend install                               create the Finder Quick Actions from the config
  ccsend uninstall                             remove the Quick Actions ccsend created
  ccsend init --host NAME [--host NAME ...]    write a starter config

config: ~/.config/ccsend/config.toml
"""

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("ccsend: \(msg)\n".utf8))
    exit(1)
}

func stamp(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "d MMM HH:mm"
    return f.string(from: d)
}

func describe(_ p: Plan) -> String {
    var s = "\(p.tops.count) item(s), \(p.files) file(s), \(ByteCountFormatter.string(fromByteCount: p.bytes, countStyle: .file))"
    var skipped: [String] = []
    if p.skippedHidden > 0 { skipped.append("\(p.skippedHidden) hidden") }
    if p.skippedExcluded > 0 { skipped.append("\(p.skippedExcluded) excluded") }
    if p.skippedSpecial > 0 { skipped.append("\(p.skippedSpecial) special") }
    if !skipped.isEmpty { s += "; skipped " + skipped.joined(separator: ", ") }
    return s
}

func cmdSend(_ args: [String]) throws {
    var rest = args, opts: Set<String> = []
    while let a = rest.first, ["--hidden", "--all", "--yes", "--no-inject", "--trash"].contains(a) { opts.insert(a); rest.removeFirst() }
    guard rest.count >= 2 else { fail(usage) }
    let config = try Config.load()
    let host = try config.host(rest[0])
    var dest = rest[1]
    var files = Array(rest.dropFirst(2))
    if dest == "--" || files.isEmpty {
        // HOST FILE or HOST -- FILE...: no destination given, so choose one.
        files = dest == "--" ? files : [dest]
        dest = "pick"
    } else if files.first == "--" { files.removeFirst() }
    guard !files.isEmpty else { fail(usage) }
    let flags = Array(files.filter { $0.hasPrefix("--") })
    if !flags.isEmpty { fail("options go before HOST: \(flags.joined(separator: " "))") }

    let plan = try Plan.build(files, .init(includeHidden: opts.contains("--hidden"), applyExcludes: !opts.contains("--all"),
                                           excludes: config.excludes, alwaysSkip: config.alwaysSkip))
    print(describe(plan))
    if !plan.sensitive.isEmpty { print("warning: sensitive-looking: \(plan.sensitive.prefix(10).joined(separator: ", "))") }
    if !opts.contains("--yes") && (plan.bytes > Int64(config.maxTotalMB) << 20 || plan.files > config.maxFiles) {
        fail("over the configured limits (max_total_mb=\(config.maxTotalMB), max_files=\(config.maxFiles)); add --yes")
    }

    if opts.contains("--trash") && !plan.sendsEverything {
        fail("--trash refused: some files in the folders would be skipped (use --hidden --all, or send without --trash)")
    }
    let ssh = SSH(host: host, controlPath: nil)
    var dir = dest, create = false, target: Remote.Session?
    switch dest {
    case "pick", "guess":
        let c = try chooseDestination(config: config, host: host, ssh: ssh, files: files, plan: plan, pick: dest == "pick")
        (dir, create, target) = (c.dir, c.create, c.target)
    case let d where d == "claude" || d == "shell" || d.hasPrefix("claude:") || d.hasPrefix("shell:"):
        // kind, or kind:DIR to pick exactly one session by its working directory.
        let parts = d.split(separator: ":", maxSplits: 1).map(String.init)
        let kind = parts[0]
        let disc = try Remote.discover(ssh)
        var matches = disc.sessions.filter { $0.kind.rawValue == kind }
        if parts.count == 2 {
            var want = parts[1]
            if want == "~" { want = disc.home } else if want.hasPrefix("~/") { want = disc.home + want.dropFirst(1) }
            while want.count > 1 && want.hasSuffix("/") { want.removeLast() }
            matches = matches.filter { $0.cwd == want }
            guard matches.count == 1 else {
                fail(matches.isEmpty ? "no \(kind) session in \(parts[1]) on \(host.label)"
                                     : "\(matches.count) \(kind) sessions in \(parts[1]) on \(host.label); not choosing one")
            }
        }
        guard let s = matches.first else { fail("no \(kind) session on \(host.label)") }
        dir = s.cwd
        target = s
    case "default":
        guard !host.defaultLocation.isEmpty else { fail("\(host.name) has no default_location") }
        dir = host.defaultLocation
        create = true
    default:
        guard dest.hasPrefix("/") || dest.hasPrefix("~/") || dest == "~" else { fail("DEST must be claude, shell, default, guess, pick or a path") }
    }
    let r = try Sender.send(plan, to: dir, create: create, via: ssh)
    if config.copyPath { Sender.copyToClipboard(r.clipboard) }
    let onClipboard = config.copyPath ? " (path is on the clipboard)" : ""
    print("sent to \(host.label):\(r.dir)")
    print(r.clipboard)
    if opts.contains("--trash") {
        let failed = Sender.trash(files.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        print(failed.isEmpty ? "originals moved to the Trash" : "could not move to the Trash: \(failed.joined(separator: ", "))")
    }
    if let s = target, s.kind == .claude, host.inject != .off, !opts.contains("--no-inject") {
        if Injector.adapter(for: s, host: host) == nil {
            print("not typed into Claude: no adapter in inject_via fits that session" + onClipboard)
        } else {
            do {
                let via = try Injector.inject(ssh, into: s, text: r.clipboard + " ")
                print((host.inject == .submit ? "typed into Claude and submitted" : "typed into the Claude prompt") + " via \(via.rawValue)")
            } catch {
                print("not typed into Claude: \(error)" + onClipboard)
            }
        }
    }
}

/// DEST "pick" (choose at the terminal) and "guess" (the best guess, no questions).
/// The guessed entry comes first in the picker, like the window's preselection.
func chooseDestination(config: Config, host: HostConfig, ssh: SSH, files: [String], plan: Plan, pick: Bool) throws
    -> (dir: String, create: Bool, target: Remote.Session?) {
    if pick && !TermPicker.interactive {
        fail("no DEST given and not at a terminal; use claude, shell, default, guess or a path")
    }
    let disc = host.claudeSessions || host.sshSessions ? try Remote.discover(ssh) : nil
    let home = disc?.home ?? ""
    let sessions = (disc?.sessions ?? []).filter { $0.kind == .claude ? host.claudeSessions : host.sshSessions }
    func tilde(_ p: String) -> String { Display.tilde(p, home: home) }

    var guessedSession: Remote.Session?, guessedFolder: Guess.Folder?, others = 0
    let words = Guess.words(files.map { ($0 as NSString).lastPathComponent })
    if (config.guessDestination || !pick) && !words.isEmpty {
        guessedSession = Guess.session(sessions, home: home, words: Set(words))
        if guessedSession == nil && (host.customPath || !pick) {
            let found = try Remote.guess(ssh, words: words, excludes: config.excludes)
            guessedFolder = Guess.best(found)
            others = max(found.count - 1, 0)
        }
    }

    if !pick {
        if let s = guessedSession {
            print("guessed: \(s.kind.rawValue) session in \(Display.clean(tilde(s.cwd)))")
            return (s.cwd, false, s)
        }
        if let f = guessedFolder {
            print("guessed: \(Display.clean(tilde(f.path)))" + (others > 0 ? " (\(others) other matching folder(s))" : ""))
            return (f.path, false, nil)
        }
        fail(words.isEmpty ? "nothing to guess from in these names (only numbers or generic words)"
                           : "no session or folder on \(host.label) is named like \(words.prefix(3).joined(separator: ", "))")
    }

    enum Choice { case session(Remote.Session), folder(String), defaultLocation, typePath }
    var choices: [(Choice, TermPicker.Item)] = []
    func sessionItem(_ s: Remote.Session, guessed: Bool) -> TermPicker.Item {
        let where_ = [s.tmux.isEmpty ? (s.kind == .shell ? "SSH session" : "") : "tmux \(s.tmux)", stamp(s.started),
                      guessed ? "guessed from the file name" : ""].filter { !$0.isEmpty }
        return .init(label: s.kind.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0) + tilde(s.cwd),
                     detail: where_.joined(separator: " · "))
    }
    if let s = guessedSession { choices.append((.session(s), sessionItem(s, guessed: true))) }
    if let f = guessedFolder {
        choices.append((.folder(f.path), .init(label: "path    " + tilde(f.path),
                                               detail: "guessed from the file name" + (others > 0 ? " · \(others) other match(es)" : ""))))
    }
    for s in sessions where s != guessedSession { choices.append((.session(s), sessionItem(s, guessed: false))) }
    if !host.defaultLocation.isEmpty {
        choices.append((.defaultLocation, .init(label: "default " + host.defaultLocation, detail: "created if missing")))
    }
    if host.customPath { choices.append((.typePath, .init(label: "path    type a path…", detail: ""))) }
    guard !choices.isEmpty else { fail("no destinations on \(host.label): no sessions, and default_location and custom_path are off") }

    let names = files.map { ($0 as NSString).lastPathComponent }
    let header = names.count <= 3 ? names.joined(separator: ", ") : "\(names.count) items: " + names.prefix(3).joined(separator: ", ") + ", …"
    guard let i = try TermPicker.choose(choices.map(\.1), prompt: "send to \(host.label)>", header: header) else { fail("cancelled") }
    switch choices[i].0 {
    case .session(let s): return (s.cwd, false, s)
    case .folder(let p): return (p, false, nil)
    case .defaultLocation: return (host.defaultLocation, true, nil)
    case .typePath:
        guard let p = TermPicker.ask("path on \(host.label) (/… or ~/…):"), !p.isEmpty else { fail("cancelled") }
        guard p.hasPrefix("/") || p.hasPrefix("~/") || p == "~" else { fail("paths start with / or ~/") }
        return (p, false, nil)
    }
}

func cmdImport(_ args: [String]) throws {
    guard let hostName = args.first else { fail(usage) }
    var rest = Array(args.dropFirst()), opts: Set<String> = [], to = FileManager.default.currentDirectoryPath
    while let a = rest.first, a.hasPrefix("--") {
        if a == "--to", rest.count >= 2 { to = rest[1]; rest.removeFirst(2); continue }
        guard ["--hidden", "--all", "--links", "--yes"].contains(a) else { fail(usage) }
        opts.insert(a); rest.removeFirst()
    }
    if rest.first == "--" { rest.removeFirst() }
    guard !rest.isEmpty else { fail(usage) }
    let config = try Config.load()
    let host = try config.host(hostName)
    guard host.importEnabled else { fail("import is off for \(host.name); set import = true in its [hosts.\(host.name)] table") }
    let paths = rest
    // Remote paths: split at the last "/" ourselves (no Mac path handling, no ~ expansion).
    func split(_ p: String) -> (String, String)? {
        var p = p
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        guard let i = p.lastIndex(of: "/") else { return nil }
        let parent = i == p.startIndex ? "/" : String(p[..<i])
        return (parent, String(p[p.index(after: i)...]))
    }
    let pairs = paths.compactMap(split)
    guard pairs.count == paths.count, Set(pairs.map(\.0)).count == 1 else { fail("import paths must share one parent folder") }
    let dir = pairs[0].0
    let names = pairs.map(\.1)
    let dest = URL(fileURLWithPath: to).standardizedFileURL.path
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: dest, isDirectory: &isDir), isDir.boolValue else { fail("\(dest) is not a folder") }

    let ssh = SSH(host: host, controlPath: nil)
    let o = Remote.DownloadOptions(hidden: opts.contains("--hidden"), excludes: opts.contains("--all") ? [] : config.excludes,
                                   symlinks: host.importSymlinks || opts.contains("--links"))
    let plan = try Remote.downloadPlan(ssh, dir: dir, names: names, o)
    print("\(names.count) item(s), \(plan.files) file(s), \(ByteCountFormatter.string(fromByteCount: plan.bytes, countStyle: .file))"
          + "; skipped \(plan.skippedHidden) hidden, \(plan.skippedExcluded) excluded, \(plan.skippedLinks) links")
    let maxBytes = Int64(config.maxTotalMB) << 20
    if !opts.contains("--yes") && (plan.bytes > maxBytes || plan.files > config.maxFiles) {
        fail("over the configured limits (max_total_mb=\(config.maxTotalMB), max_files=\(config.maxFiles)); add --yes")
    }
    try Importer.checkSpace(dest, bytes: plan.bytes)
    let imp = Importer(dest: dest, tops: names, allowSymlinks: o.symlinks,
                       maxBytes: max(plan.bytes, 1) + (1 << 20), maxFiles: plan.files + 100)
    try Remote.download(ssh, dir: dir, names: names, o, maxBytes: imp.maxBytes, maxFiles: imp.maxFiles, consume: imp.consume)
    for p in imp.localPaths { print(p) }
}

func cmdSessions(_ name: String) throws {
    let config = try Config.load()
    let host = try config.host(name)
    let d = try Remote.discover(SSH(host: host, controlPath: nil))
    if d.sessions.isEmpty { print("no sessions on \(host.label)") }
    for s in d.sessions {
        let extra = s.tmux.isEmpty ? "" : "  (tmux \(s.tmux))"
        print("\(s.kind.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)) \(Display.tilde(s.cwd, home: d.home))\(extra)  since \(stamp(s.started))")
    }
}

func cmdCheck() throws {
    let config = try Config.load()
    print("config ok: \(config.hosts.count) host(s), menu \(config.menu.rawValue)")
    var failed = false
    for h in config.hosts {
        do {
            let ssh = SSH(host: h, controlPath: nil)
            let d = try Remote.discover(ssh)
            var line = "\(h.label): ok, home \(d.home), \(d.sessions.count) session(s)"
            if !h.defaultLocation.isEmpty {
                let r = try Remote.resolve(ssh, h.defaultLocation)
                line += ", default \(r.path)\(r.exists ? "" : " (created on first send)")"
            }
            print(line)
        } catch {
            failed = true
            print("\(h.label): FAILED \(error)")
        }
    }
    if failed { exit(1) }
}

func cmdLog(_ args: [String]) throws {
    var rest = args, host: String?, n = 30
    while let a = rest.first {
        if a == "--host", rest.count >= 2 { host = rest[1]; rest.removeFirst(2) }
        else if a == "-n", rest.count >= 2, let v = Int(rest[1]), (1...10000).contains(v) { n = v; rest.removeFirst(2) }
        else { fail(usage) }
    }
    guard let host else {
        let text = (try? String(contentsOf: Log.url, encoding: .utf8)) ?? ""
        for l in text.split(separator: "\n").suffix(n) { print(l) }
        return
    }
    let config = try Config.load()
    let h = try config.host(host)
    // Fixed command line; the output is from the host, so it is cleaned before it reaches the terminal.
    let r = try SSH(host: h, controlPath: nil).run("journalctl -t ccsend -n \(n) --no-pager -o short-iso", timeout: 20)
    guard r.status == 0 else { fail("\(h.label): journalctl failed: \(r.stderrText)") }
    for l in String(decoding: r.stdout.prefix(4 << 20), as: UTF8.self).split(separator: "\n") { print(Display.clean(String(l))) }
}

func cmdInit(_ args: [String]) throws {
    var hosts: [String] = [], rest = args
    while rest.count >= 2, rest[0] == "--host" { hosts.append(rest[1]); rest.removeFirst(2) }
    guard !hosts.isEmpty, rest.isEmpty else { fail(usage) }
    let url = Config.url
    guard !FileManager.default.fileExists(atPath: url.path) else { fail("\(url.path) already exists") }
    let text = Config.template(hosts: hosts)
    _ = try Config.parse(text)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
    print("wrote \(url.path)")
}

let argv = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-psn_") }
do {
    switch argv.first {
    case nil where Bundle.main.bundlePath.hasSuffix(".app"):
        UI.runURL()   // started by LaunchServices for a ccsend:// link (the Finder extension)
    case "ui": try UI.run(Array(argv.dropFirst()))
    case "ui-import": try UI.runImport(Array(argv.dropFirst()))
    case "send": try cmdSend(Array(argv.dropFirst()))
    case "import": try cmdImport(Array(argv.dropFirst()))
    case "sessions" where argv.count == 2: try cmdSessions(argv[1])
    case "check": try cmdCheck()
    case "log": try cmdLog(Array(argv.dropFirst()))
    case "install": try Installer.install()
    case "uninstall": try Installer.uninstall()
    case "init": try cmdInit(Array(argv.dropFirst()))
    case "selftest": SelfTest.run()
    default: fail(usage)
    }
} catch {
    fail("\(error)")
}
