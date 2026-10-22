import Foundation

let usage = """
usage:
  ccsend ui [--host HOST] [--] FILE...        the send window (what the Quick Actions run)
  ccsend send HOST DEST [options] FILE...      send without a window
        DEST: claude (newest Claude session) | claude:DIR (the Claude session in DIR)
              shell (newest SSH shell) | shell:DIR | default | /path | ~/path
        --hidden      include hidden files in folders
        --all         do not apply the exclude list
        --yes         send even when over the configured limits
        --no-inject   do not type the path into the Claude prompt (when the host has inject on)
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
    while let a = rest.first, ["--hidden", "--all", "--yes", "--no-inject"].contains(a) { opts.insert(a); rest.removeFirst() }
    guard rest.count >= 3 else { fail(usage) }
    let config = try Config.load()
    let host = try config.host(rest[0])
    let dest = rest[1]
    var files = Array(rest.dropFirst(2))
    if files.first == "--" { files.removeFirst() }
    let flags = Array(files.filter { $0.hasPrefix("--") })
    if !flags.isEmpty { fail("options go before HOST: \(flags.joined(separator: " "))") }

    let plan = try Plan.build(files, .init(includeHidden: opts.contains("--hidden"), applyExcludes: !opts.contains("--all"),
                                           excludes: config.excludes, alwaysSkip: config.alwaysSkip))
    print(describe(plan))
    if !plan.sensitive.isEmpty { print("warning: sensitive-looking: \(plan.sensitive.prefix(10).joined(separator: ", "))") }
    if !opts.contains("--yes") && (plan.bytes > Int64(config.maxTotalMB) << 20 || plan.files > config.maxFiles) {
        fail("over the configured limits (max_total_mb=\(config.maxTotalMB), max_files=\(config.maxFiles)); add --yes")
    }

    let ssh = SSH(host: host, controlPath: nil)
    var dir = dest, create = false, target: Remote.Session?
    switch dest {
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
        guard dest.hasPrefix("/") || dest.hasPrefix("~/") || dest == "~" else { fail("DEST must be claude, shell, default or a path") }
    }
    let r = try Sender.send(plan, to: dir, create: create, via: ssh)
    Sender.copyToClipboard(r.clipboard)
    print("sent to \(host.label):\(r.dir)")
    print(r.clipboard)
    if let s = target, s.kind == .claude, host.inject != .off, !opts.contains("--no-inject") {
        if Injector.adapter(for: s, host: host) == nil {
            print("not typed into Claude: no adapter in inject_via fits that session (path is on the clipboard)")
        } else {
            do {
                let via = try Injector.inject(ssh, into: s, text: r.clipboard + " ")
                print((host.inject == .submit ? "typed into Claude and submitted" : "typed into the Claude prompt") + " via \(via.rawValue)")
            } catch {
                print("not typed into Claude: \(error) (path is on the clipboard)")
            }
        }
    }
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

let argv = Array(CommandLine.arguments.dropFirst())
do {
    switch argv.first {
    case "ui": try UI.run(Array(argv.dropFirst()))
    case "send": try cmdSend(Array(argv.dropFirst()))
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
