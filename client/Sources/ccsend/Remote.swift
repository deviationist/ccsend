import Foundation

struct RemoteError: Error, CustomStringConvertible {
    let description: String
    init(_ s: String) { description = s }
}

/// Calls into server/remote.py over SSH.
///
/// The remote command line is fixed: python3 -c '<bootstrap>' <script> <request>,
/// where script and request are base64 ([A-Za-z0-9+/=], inert in any shell).
/// Nothing the user or the host supplies is ever spliced into it.
/// Everything the host sends back is untrusted: decoded strictly, size-capped,
/// checked, and cleaned before display.
enum Remote {
    // Must stay identical to BOOTSTRAP in server/test_remote.py. No single quotes inside.
    static let bootstrap = "import base64,sys;exec(compile(base64.b64decode(sys.argv.pop(1)),\"remote.py\",\"exec\"))"

    static func command(_ request: [String: Any]) throws -> String {
        let json = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        return "python3 -c '\(bootstrap)' \(RemoteScript.base64) \(json.base64EncodedString())"
    }

    static func call(_ ssh: SSH, _ request: [String: Any], stdin: ((FileHandle) throws -> Void)? = nil,
                     timeout: TimeInterval = 20) throws -> [String: Any] {
        let id = Log.newID(), cmd = request["cmd"] as? String ?? "?", start = Date()
        var req = request
        req["id"] = id
        req["win"] = Log.run
        req["log_names"] = Log.logNames
        func ms() -> String { String(Int(Date().timeIntervalSince(start) * 1000)) }
        do {
            let obj = try callRaw(ssh, req, stdin: stdin, timeout: timeout)
            var f: [(String, String)] = [("id", id), ("event", cmd), ("host", ssh.host.name), ("result", "ok"), ("ms", ms())]
            if let s = obj["sessions"] as? [Any] { f.append(("sessions", String(s.count))) }
            if let e = obj["entries"] as? [Any], let d = obj["dir"] as? String { f += [("dir", Log.value(d)), ("entries", String(e.count))] }
            if let w = obj["written"] as? [[String: Any]], let d = obj["dir"] as? String {
                f += [("dir", Log.value(d)), ("items", String(w.count)),
                      ("files", String(obj["files"] as? Int ?? 0)), ("bytes", String(obj["bytes"] as? Int ?? 0))]
                if Log.logNames { f.append(("names", Log.names(w.compactMap { $0["name"] as? String }))) }
            }
            if let p = obj["path"] as? String { f.append(("path", Log.value(p))) }
            Log.event(f)
            return obj
        } catch {
            Log.event([("id", id), ("event", cmd), ("host", ssh.host.name), ("result", "error"), ("ms", ms()),
                       ("error", Log.value(String("\(error)".prefix(300))))])
            throw error
        }
    }

    private static func callRaw(_ ssh: SSH, _ request: [String: Any], stdin: ((FileHandle) throws -> Void)?,
                                timeout: TimeInterval) throws -> [String: Any] {
        let r = try ssh.run(try command(request), stdin: stdin, timeout: timeout)
        guard r.stdout.count < 4 << 20 else { throw RemoteError("\(ssh.host.label): response too large") }
        let text = String(decoding: r.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = text.split(separator: "\n").last,
              let obj = try? JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any],
              let ok = obj["ok"] as? Bool else {
            if r.status == 255 { throw RemoteError("\(ssh.host.label): ssh failed: \(r.stderrText)") }
            if r.stderrText.contains("python3") { throw RemoteError("\(ssh.host.label): python3 is not available on the host") }
            throw RemoteError("\(ssh.host.label): unexpected response (exit \(r.status)) \(r.stderrText)")
        }
        guard ok else { throw RemoteError("\(ssh.host.label): \(Display.clean(obj["error"] as? String ?? "refused"))") }
        return obj
    }

    // MARK: - typed requests

    struct Session: Identifiable, Hashable {
        enum Kind: String { case claude, shell }
        let kind: Kind
        let cwd: String
        let tmux: String
        let started: Date
        var id: String { "\(kind.rawValue):\(cwd):\(tmux):\(started.timeIntervalSince1970)" }
    }

    struct Discovery {
        let home: String
        let sessions: [Session]
    }

    static func discover(_ ssh: SSH) throws -> Discovery {
        let o = try call(ssh, ["cmd": "discover"], timeout: 15)
        guard let home = o["home"] as? String, Check.path(home) else { throw RemoteError("\(ssh.host.label): bad home in response") }
        let raw = o["sessions"] as? [[String: Any]] ?? []
        var sessions: [Session] = []
        for s in raw.prefix(100) {
            guard let k = (s["kind"] as? String).flatMap(Session.Kind.init(rawValue:)),
                  let cwd = s["cwd"] as? String, Check.path(cwd) else { continue }
            let tmux = (s["tmux"] as? String).map { String(Display.clean($0).prefix(60)) } ?? ""
            let started = Date(timeIntervalSince1970: TimeInterval(s["started"] as? Int ?? 0))
            sessions.append(Session(kind: k, cwd: cwd, tmux: tmux, started: started))
        }
        return Discovery(home: home, sessions: sessions)
    }

    static func resolve(_ ssh: SSH, _ path: String) throws -> (path: String, exists: Bool) {
        let o = try call(ssh, ["cmd": "resolve", "path": path, "roots": ssh.host.allowedRoots])
        guard let p = o["path"] as? String, Check.path(p) else { throw RemoteError("bad path in response") }
        return (p, o["exists"] as? Bool ?? false)
    }

    struct Entry: Hashable { let name: String; let isDir: Bool }

    static func list(_ ssh: SSH, dir: String, prefix: String) throws -> (dir: String, entries: [Entry]) {
        let o = try call(ssh, ["cmd": "list", "dir": dir, "prefix": prefix, "roots": ssh.host.allowedRoots], timeout: 10)
        guard let d = o["dir"] as? String, Check.path(d) else { throw RemoteError("bad dir in response") }
        var out: [Entry] = []
        for e in (o["entries"] as? [[String: Any]] ?? []).prefix(200) {
            guard let n = e["name"] as? String, Check.name(n), n.hasPrefix(prefix) else { continue }
            out.append(Entry(name: n, isDir: e["dir"] as? Bool ?? false))
        }
        return (d, out)
    }

    struct Written { let sent: String; let name: String }

    static func upload(_ ssh: SSH, dir: String, create: Bool, tops: [String],
                       stream: @escaping (FileHandle) throws -> Void) throws -> (dir: String, written: [Written]) {
        let o = try call(ssh, ["cmd": "upload", "dir": dir, "create": create, "tops": tops,
                               "roots": ssh.host.allowedRoots], stdin: stream, timeout: 3600)
        guard let d = o["dir"] as? String, Check.path(d) else { throw RemoteError("bad dir in response") }
        var written: [Written] = []
        for w in o["written"] as? [[String: Any]] ?? [] {
            guard let sent = w["sent"] as? String, let name = w["name"] as? String,
                  tops.contains(sent), Check.collisionName(name, for: sent) else {
                throw RemoteError("\(ssh.host.label): the host reported an unexpected file name; nothing was copied")
            }
            written.append(Written(sent: sent, name: name))
        }
        guard written.map(\.sent).sorted() == tops.sorted() else {
            throw RemoteError("\(ssh.host.label): the host did not confirm every item")
        }
        return (d, written)
    }
}

/// Checks on strings that come from the host.
enum Check {
    static func path(_ s: String) -> Bool {
        s.hasPrefix("/") && s.utf8.count <= 4096 && !s.unicodeScalars.contains(where: Display.isUnsafe)
    }

    static func name(_ s: String) -> Bool {
        !s.isEmpty && s != "." && s != ".." && s.utf8.count <= 255 && !s.contains("/")
            && !s.unicodeScalars.contains(where: Display.isUnsafe)
    }

    /// name must be sent itself, or sent with "-N" before its extension (files) or at the end (folders).
    static func collisionName(_ name: String, for sent: String) -> Bool {
        if name == sent { return true }
        let ext = (sent as NSString).pathExtension
        let base = ext.isEmpty ? sent : String(sent.dropLast(ext.count + 1))
        for (b, e) in [(base, ext.isEmpty ? "" : "." + ext), (sent, "")] {
            guard name.hasPrefix(b + "-"), name.hasSuffix(e) else { continue }
            let mid = name.dropFirst(b.count + 1).dropLast(e.count)
            if !mid.isEmpty, mid.count <= 4, mid.allSatisfy(\.isASCII), mid.allSatisfy(\.isNumber) { return true }
        }
        return false
    }
}

enum Display {
    /// Control characters and bidi overrides: could spoof what the window shows.
    static func isUnsafe(_ u: Unicode.Scalar) -> Bool {
        u.value < 0x20 || (0x7F...0x9F).contains(u.value) || (0x202A...0x202E).contains(u.value)
            || (0x2066...0x2069).contains(u.value) || u.value == 0x200E || u.value == 0x200F
    }

    static func clean(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.map { isUnsafe($0) ? "?" : $0 }))
    }

    /// Sentence case for the window: capitalise the first letter of the message,
    /// after a leading "<host>: " if there is one (host labels keep their case).
    static func sentence(_ s: String) -> String {
        var head = "", body = Substring(s)
        if let r = s.range(of: ": "), !s[..<r.lowerBound].contains(" ") {
            head = String(s[..<r.upperBound])
            body = s[r.upperBound...]
        }
        guard let f = body.first else { return s }
        return head + f.uppercased() + String(body.dropFirst())
    }

    /// ~ for paths under the remote home.
    static func tilde(_ path: String, home: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
