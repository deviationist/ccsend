import Foundation

// ~/.config/ccsend/config.toml
//
// Parsed by a small strict reader for the TOML subset this schema uses:
// [table] and [table.sub] headers, key = value with basic or literal strings,
// booleans, integers and string arrays (may span lines). Anything else, and
// any key or table the schema does not know, is an error. Unknown input is
// never ignored.

struct ConfigError: Error, CustomStringConvertible {
    let description: String
    init(_ s: String) { description = s }
}

enum TOMLValue: Equatable {
    case string(String), bool(Bool), int(Int), strings([String])
}

/// Tables in file order: name -> (key -> (value, line)).
struct TOMLDocument {
    var order: [String] = []
    var tables: [String: [String: (TOMLValue, Int)]] = [:]
}

enum TOML {
    static func parse(_ text: String) throws -> TOMLDocument {
        var doc = TOMLDocument()
        doc.order.append("")
        doc.tables[""] = [:]
        var current = ""
        let lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let lineNo = i + 1
            var line = stripComment(lines[i]).trimmingCharacters(in: .whitespaces)
            i += 1
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                guard line.hasSuffix("]"), !line.hasPrefix("[[") else {
                    throw ConfigError("line \(lineNo): bad table header")
                }
                let name = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                let parts = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
                guard !parts.isEmpty, parts.allSatisfy(isBareKey) else {
                    throw ConfigError("line \(lineNo): bad table name [\(name)]")
                }
                guard doc.tables[name] == nil else { throw ConfigError("line \(lineNo): duplicate table [\(name)]") }
                doc.tables[name] = [:]
                doc.order.append(name)
                current = name
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { throw ConfigError("line \(lineNo): expected key = value") }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard isBareKey(key) else { throw ConfigError("line \(lineNo): bad key \(key)") }
            var raw = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            // Multi-line arrays: keep reading until the brackets balance.
            if raw.hasPrefix("[") {
                while !arrayClosed(raw) {
                    guard i < lines.count else { throw ConfigError("line \(lineNo): unterminated array") }
                    raw += " " + stripComment(lines[i]).trimmingCharacters(in: .whitespaces)
                    i += 1
                }
            }
            line = raw
            let value = try parseValue(line, lineNo)
            guard doc.tables[current]![key] == nil else { throw ConfigError("line \(lineNo): duplicate key \(key)") }
            doc.tables[current]![key] = (value, lineNo)
        }
        return doc
    }

    static func isBareKey(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "_" || $0 == "-" }
    }

    /// Drop a trailing # comment that is not inside a string.
    static func stripComment(_ line: String) -> String {
        var out = "", quote: Character? = nil, escaped = false
        for c in line {
            if let q = quote {
                out.append(c)
                if q == "\"" && c == "\\" && !escaped { escaped = true; continue }
                if c == q && !escaped { quote = nil }
                escaped = false
            } else if c == "#" {
                break
            } else {
                if c == "\"" || c == "'" { quote = c }
                out.append(c)
            }
        }
        return out
    }

    static func arrayClosed(_ s: String) -> Bool {
        var depth = 0, quote: Character? = nil, escaped = false
        for c in s {
            if let q = quote {
                if q == "\"" && c == "\\" && !escaped { escaped = true; continue }
                if c == q && !escaped { quote = nil }
                escaped = false
            } else if c == "\"" || c == "'" { quote = c }
            else if c == "[" { depth += 1 }
            else if c == "]" { depth -= 1 }
        }
        return depth == 0 && quote == nil
    }

    static func parseValue(_ s: String, _ line: Int) throws -> TOMLValue {
        if s == "true" { return .bool(true) }
        if s == "false" { return .bool(false) }
        if s.hasPrefix("\"") || s.hasPrefix("'") {
            var scanner = Substring(s)
            let str = try parseString(&scanner, line)
            guard scanner.trimmingCharacters(in: .whitespaces).isEmpty else { throw ConfigError("line \(line): junk after string") }
            return .string(str)
        }
        if s.hasPrefix("[") {
            var body = Substring(s.dropFirst().dropLast())
            guard s.hasSuffix("]") else { throw ConfigError("line \(line): bad array") }
            var items: [String] = []
            while true {
                body = body.drop(while: { $0 == " " || $0 == "\t" })
                if body.isEmpty { break }
                items.append(try parseString(&body, line))
                body = body.drop(while: { $0 == " " || $0 == "\t" })
                if body.isEmpty { break }
                guard body.first == "," else { throw ConfigError("line \(line): expected , in array") }
                body = body.dropFirst()
            }
            return .strings(items)
        }
        if let n = Int(s), s.allSatisfy({ $0.isNumber || $0 == "-" }) { return .int(n) }
        throw ConfigError("line \(line): unsupported value \(s)")
    }

    static func parseString(_ s: inout Substring, _ line: Int) throws -> String {
        guard let q = s.first, q == "\"" || q == "'" else { throw ConfigError("line \(line): expected a string") }
        s = s.dropFirst()
        var out = ""
        while let c = s.first {
            s = s.dropFirst()
            if c == q { return out }
            if c == "\\" && q == "\"" {
                guard let e = s.first else { break }
                s = s.dropFirst()
                switch e {
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "u":
                    let hex = String(s.prefix(4))
                    guard hex.count == 4, let v = UInt32(hex, radix: 16), let u = Unicode.Scalar(v) else {
                        throw ConfigError("line \(line): bad \\u escape")
                    }
                    out.unicodeScalars.append(u)
                    s = s.dropFirst(4)
                default: throw ConfigError("line \(line): bad escape \\\(e)")
                }
                continue
            }
            out.append(c)
        }
        throw ConfigError("line \(line): unterminated string")
    }
}

// MARK: - Schema

enum MenuMode: String { case perHost = "per-host", single }
/// Typing the remote path into a Claude Code prompt (tmux only). Opt-in per host.
enum Inject: String { case off, type, submit }
enum Preselect: String { case newestClaude = "newest-claude", defaultLocation = "default-location", none }

struct HostConfig {
    var name: String            // [hosts.<name>]
    var label: String
    var ssh: String             // ssh destination: alias or hostname
    var user: String?           // -l
    var sshOptions: [String]    // extra -o Key=Value, allowlisted
    var claudeSessions = true
    var sshSessions = true
    var defaultLocation = ""    // "" = off
    var customPath = true
    var allowedRoots = ["~"]
    var inject = Inject.off
    var injectVia: [Injector.Adapter] = [.tmux]
}

struct Config {
    var menu = MenuMode.perHost
    var preselect = Preselect.newestClaude
    var refreshSeconds = 15
    var includeHidden = false
    var applyExcludes = true
    var excludes = ["node_modules", ".venv", "venv", "__pycache__", ".pytest_cache", ".mypy_cache",
                    ".next", ".nuxt", ".turbo", "dist", "build", "target", ".gradle", ".DS_Store", "._*", "Thumbs.db"]
    var alwaysSkip = [".DS_Store", "._*"]
    var maxTotalMB = 2048
    var maxFiles = 20000
    var logNames = true
    var hosts: [HostConfig] = []

    func host(_ name: String) throws -> HostConfig {
        guard let h = hosts.first(where: { $0.name == name }) else { throw ConfigError("no host \(name) in the config") }
        return h
    }

    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/ccsend/config.toml")

    /// ssh options a host may set. Everything that runs commands, forwards or
    /// weakens host verification (ProxyCommand, LocalCommand, StrictHostKeyChecking …) is refused.
    static let allowedSSHOptions: Set<String> = [
        "IdentityFile", "CertificateFile", "IdentitiesOnly", "Port", "ProxyJump",
        "HostKeyAlias", "UserKnownHostsFile", "PubkeyAcceptedAlgorithms", "HostKeyAlgorithms",
    ]

    static func load(from url: URL = Config.url) throws -> Config {
        let path = url.path
        var st = stat()
        guard lstat(path, &st) == 0 else {
            throw ConfigError("no config at \(path); create one with: ccsend init --host <name>")
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else { throw ConfigError("\(path) is not a regular file") }
        guard st.st_uid == getuid() else { throw ConfigError("\(path) is not owned by you") }
        guard st.st_mode & 0o022 == 0 else { throw ConfigError("\(path) is writable by others; run: chmod 600 \(path)") }
        let text = try String(contentsOf: url, encoding: .utf8)
        let c = try parse(text)
        Log.logNames = c.logNames
        return c
    }

    static func parse(_ text: String) throws -> Config {
        let doc = try TOML.parse(text)
        var c = Config()
        for name in doc.order {
            let t = doc.tables[name]!
            var keys = Set(t.keys)
            func take(_ k: String) -> (TOMLValue, Int)? { keys.remove(k); return t[k] }
            func str(_ k: String) throws -> String? {
                guard let (v, l) = take(k) else { return nil }
                guard case .string(let s) = v else { throw ConfigError("line \(l): \(k) must be a string") }
                return s
            }
            func bool(_ k: String) throws -> Bool? {
                guard let (v, l) = take(k) else { return nil }
                guard case .bool(let b) = v else { throw ConfigError("line \(l): \(k) must be true or false") }
                return b
            }
            func int(_ k: String) throws -> Int? {
                guard let (v, l) = take(k) else { return nil }
                guard case .int(let n) = v, n > 0 else { throw ConfigError("line \(l): \(k) must be a positive integer") }
                return n
            }
            func strs(_ k: String) throws -> [String]? {
                guard let (v, l) = take(k) else { return nil }
                guard case .strings(let a) = v else { throw ConfigError("line \(l): \(k) must be an array of strings") }
                return a
            }
            switch name {
            case "":
                break
            case "ui":
                if let s = try str("menu") {
                    guard let m = MenuMode(rawValue: s) else { throw ConfigError("ui.menu must be \"per-host\" or \"single\"") }
                    c.menu = m
                }
                if let s = try str("preselect") {
                    guard let p = Preselect(rawValue: s) else {
                        throw ConfigError("ui.preselect must be \"newest-claude\", \"default-location\" or \"none\"")
                    }
                    c.preselect = p
                }
                if let (v, l) = take("refresh_seconds") {
                    guard case .int(let n) = v, n == 0 || (5...3600).contains(n) else {
                        throw ConfigError("line \(l): refresh_seconds must be 0 (off) or 5-3600")
                    }
                    c.refreshSeconds = n
                }
            case "folders":
                if let b = try bool("include_hidden") { c.includeHidden = b }
                if let b = try bool("apply_excludes") { c.applyExcludes = b }
                if let a = try strs("excludes") { c.excludes = a }
                if let a = try strs("always_skip") { c.alwaysSkip = a }
            case "logging":
                if let b = try bool("log_names") { c.logNames = b }
            case "limits":
                if let n = try int("max_total_mb") { c.maxTotalMB = n }
                if let n = try int("max_files") { c.maxFiles = n }
            case let n where n.hasPrefix("hosts."):
                let hname = String(n.dropFirst("hosts.".count))
                guard !hname.contains(".") else { throw ConfigError("[\(n)]: nested host tables are not supported") }
                var h = HostConfig(name: hname, label: hname, ssh: hname, user: nil, sshOptions: [])
                if let s = try str("label") { h.label = s }
                if let s = try str("ssh") { h.ssh = s }
                if let s = try str("user") { h.user = s }
                if let a = try strs("ssh_options") { h.sshOptions = a }
                if let b = try bool("claude_sessions") { h.claudeSessions = b }
                if let b = try bool("ssh_sessions") { h.sshSessions = b }
                if let s = try str("default_location") { h.defaultLocation = s }
                if let b = try bool("custom_path") { h.customPath = b }
                if let a = try strs("allowed_roots") { h.allowedRoots = a }
                if let s = try str("inject") {
                    guard let i = Inject(rawValue: s) else { throw ConfigError("[\(n)]: inject must be \"off\", \"type\" or \"submit\"") }
                    h.inject = i
                }
                if let (v, l) = take("inject_via") {
                    guard case .strings(let a) = v, !a.isEmpty else { throw ConfigError("line \(l): inject_via must be a list like [\"tmux\", \"iterm\"]") }
                    h.injectVia = try a.map { s in
                        guard let ad = Injector.Adapter(rawValue: s) else { throw ConfigError("line \(l): unknown inject adapter \"\(s)\" (tmux, iterm)") }
                        return ad
                    }
                }
                try validate(h)
                c.hosts.append(h)
            default:
                throw ConfigError("unknown table [\(name)]")
            }
            if let k = keys.sorted().first {
                throw ConfigError("line \(t[k]!.1): unknown key \(k) in [\(name.isEmpty ? "top level" : name)]")
            }
        }
        guard !c.hosts.isEmpty else { throw ConfigError("no [hosts.<name>] in the config") }
        return c
    }

    static func validate(_ h: HostConfig) throws {
        let ctx = "[hosts.\(h.name)]"
        // Destinations and users start with a letter or digit: no "-oProxyCommand=…" option injection.
        let ident = try! NSRegularExpression(pattern: "^[A-Za-z0-9][A-Za-z0-9._-]{0,252}$")
        func ok(_ s: String) -> Bool { ident.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
        guard ok(h.name) else { throw ConfigError("\(ctx): bad host name") }
        guard ok(h.ssh) else { throw ConfigError("\(ctx): ssh must be an ssh alias or hostname (letters, digits, . _ -)") }
        if let u = h.user, !ok(u) { throw ConfigError("\(ctx): bad user \(u)") }
        guard !h.label.isEmpty, h.label.count <= 40, !h.label.contains(where: { $0.isNewline }) else {
            throw ConfigError("\(ctx): label must be 1-40 characters on one line")
        }
        for o in h.sshOptions {
            let parts = o.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[1].isEmpty, Config.allowedSSHOptions.contains(parts[0]) else {
                throw ConfigError("\(ctx): ssh_options entry \"\(o)\" is not allowed (allowed keys: \(Config.allowedSSHOptions.sorted().joined(separator: ", ")))")
            }
            guard !parts[1].contains(where: { $0.isNewline || $0 == "\0" }) else { throw ConfigError("\(ctx): bad ssh_options value") }
        }
        guard !h.allowedRoots.isEmpty else { throw ConfigError("\(ctx): allowed_roots must not be empty") }
        for p in h.allowedRoots + (h.defaultLocation.isEmpty ? [] : [h.defaultLocation]) {
            guard p == "~" || p.hasPrefix("~/") || p.hasPrefix("/") else {
                throw ConfigError("\(ctx): \(p) must be absolute or start with ~/")
            }
        }
    }

    static func template(hosts: [String]) -> String {
        var s = """
        # ccsend configuration. Unknown keys are errors. See DESIGN.md in the ccsend repository.

        [ui]
        menu = "per-host"            # "per-host": one Quick Action per host | "single": one "Send to remote"
        preselect = "newest-claude"  # "newest-claude" | "default-location" | "none"
        refresh_seconds = 15         # re-read the host's sessions while the window is open; 0 = off

        [folders]
        include_hidden = false       # default of the "Include hidden files" checkbox
        apply_excludes = true        # default of the "Exclude common files" checkbox
        excludes = [
          "node_modules", ".venv", "venv", "__pycache__", ".pytest_cache", ".mypy_cache",
          ".next", ".nuxt", ".turbo", "dist", "build", "target", ".gradle",
          ".DS_Store", "._*", "Thumbs.db",
        ]
        always_skip = [".DS_Store", "._*"]   # dropped whatever the checkboxes say

        [limits]
        max_total_mb = 2048          # ask before sending more
        max_files = 20000

        [logging]
        log_names = true             # file names in ~/Library/Logs/ccsend.log and the host journal (never contents)

        """
        for h in hosts {
            s += """

            [hosts.\(h)]
            label = "\(h)"
            ssh = "\(h)"                 # ~/.ssh/config alias or hostname; keys and certificates come from there
            # user = "\(h)"              # optional, passed as ssh -l
            # ssh_options = ["IdentityFile=~/.ssh/ccsend_ed25519", "IdentitiesOnly=yes"]
            claude_sessions = true       # offer running Claude Code sessions
            ssh_sessions = true          # offer open SSH shells
            default_location = "~/inbox" # "" turns the Default destination off
            custom_path = true           # "Path" destination with Tab completion
            allowed_roots = ["~"]        # destinations must resolve inside these (checked on the host)
            inject = "off"               # opt-in: "type" puts the path in the Claude prompt, "submit" also presses Enter
            inject_via = ["tmux"]        # adapters, tried in order: "tmux" (host-side), "iterm" (Mac types into the iTerm2 tab)

            """
        }
        return s
    }
}
