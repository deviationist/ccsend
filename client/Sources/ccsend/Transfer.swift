import Foundation

/// What will be sent, decided entirely on the Mac before anything is read.
///
/// Folders are walked with lstat: symlinks are recorded as links and never
/// followed, so a link inside a folder cannot pull in files from outside it.
/// Only regular files, directories and symlinks are sent.
struct Plan {
    struct Item {
        enum Kind { case file, dir, symlink }
        let local: String        // absolute path on the Mac
        let archive: String      // path inside the stream: "<top>/<rel>"
        let kind: Kind
        let size: Int64
        let mode: UInt16
        let mtime: Int
        let linkTarget: String?
    }

    var tops: [String] = []            // top-level names, in selection order
    var items: [Item] = []
    var files = 0
    var bytes: Int64 = 0
    var skippedHidden = 0
    var skippedExcluded = 0
    var skippedSpecial = 0
    var sensitive: [String] = []       // archive paths that look like secrets

    /// True when every file in the selection is in the stream, so trashing the
    /// originals after sending loses nothing that wasn't sent.
    var sendsEverything: Bool { skippedHidden == 0 && skippedExcluded == 0 && skippedSpecial == 0 }
    var hasFolders = false

    /// Files (incl. links) and bytes that will be sent under one top-level item.
    func stats(_ top: String) -> (files: Int, bytes: Int64) {
        var files = 0, bytes: Int64 = 0
        for i in items where i.kind != .dir && (i.archive == top || i.archive.hasPrefix(top + "/")) {
            files += 1
            bytes += i.size
        }
        return (files, bytes)
    }

    static let sensitivePatterns = [".env", ".env.*", "*.env", "id_rsa", "id_ecdsa", "id_ed25519", "id_dsa",
                                    "*.pem", "*.key", "*.p12", "*.pfx", ".netrc", ".npmrc", ".pypirc",
                                    ".pgpass", "credentials", "credentials.json", "secrets.*", ".htpasswd"]
    static let sensitiveDirs = [".ssh", ".aws", ".gnupg", ".git", ".docker", ".kube"]

    struct Options {
        var includeHidden: Bool
        var applyExcludes: Bool
        var excludes: [String]
        var alwaysSkip: [String]
    }

    static func build(_ paths: [String], _ o: Options) throws -> Plan {
        var plan = Plan()
        var seen = Set<String>()
        for raw in paths {
            let path = (raw as NSString).standardizingPath
            let top = (path as NSString).lastPathComponent
            guard Check.name(top) else { throw RemoteError("cannot send \(raw): unsupported name") }
            guard seen.insert(top).inserted else { throw RemoteError("two selected items are both named \(top)") }
            var st = stat()
            guard lstat(path, &st) == 0 else { throw RemoteError("cannot read \(raw)") }
            plan.tops.append(top)
            // A top-level item was chosen explicitly: hidden or excluded names are still sent.
            try plan.add(path: path, archive: top, st: st, o, top: true)
        }
        return plan
    }

    private static func matches(_ name: String, _ patterns: [String]) -> Bool {
        patterns.contains { fnmatch($0, name, 0) == 0 }
    }

    private mutating func add(path: String, archive: String, st: stat, _ o: Options, top: Bool) throws {
        let name = (path as NSString).lastPathComponent
        if !top {
            if Plan.matches(name, o.alwaysSkip) { skippedExcluded += 1; return }
            if !o.includeHidden && name.hasPrefix(".") { skippedHidden += count(path, st); return }
            if o.applyExcludes && Plan.matches(name, o.excludes) { skippedExcluded += count(path, st); return }
        }
        let mode = UInt16(st.st_mode & 0o7777)
        let mtime = Int(st.st_mtimespec.tv_sec)
        let fmt = st.st_mode & S_IFMT
        if Plan.matches(name, Plan.sensitivePatterns) || (fmt == S_IFDIR && Plan.sensitiveDirs.contains(name)) {
            sensitive.append(archive + (fmt == S_IFDIR ? "/" : ""))
        }
        switch fmt {
        case S_IFREG:
            items.append(Item(local: path, archive: archive, kind: .file, size: Int64(st.st_size), mode: mode, mtime: mtime, linkTarget: nil))
            files += 1
            bytes += Int64(st.st_size)
        case S_IFLNK:
            var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let n = readlink(path, &buf, buf.count - 1)
            guard n >= 0 else { throw RemoteError("cannot read link \(path)") }
            let target = String(decoding: buf[0..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            items.append(Item(local: path, archive: archive, kind: .symlink, size: 0, mode: mode, mtime: mtime, linkTarget: target))
            files += 1
        case S_IFDIR:
            hasFolders = true
            items.append(Item(local: path, archive: archive, kind: .dir, size: 0, mode: mode, mtime: mtime, linkTarget: nil))
            let names = try FileManager.default.contentsOfDirectory(atPath: path).sorted()
            for n in names {
                let child = path + "/" + n
                var cst = stat()
                guard lstat(child, &cst) == 0 else { continue }
                try add(path: child, archive: archive + "/" + n, st: cst, o, top: false)
            }
        default:
            skippedSpecial += 1
        }
    }

    /// Number of files a skipped entry stands for (for the summary only).
    private func count(_ path: String, _ st: stat) -> Int {
        guard st.st_mode & S_IFMT == S_IFDIR else { return 1 }
        var n = 0
        let e = FileManager.default.enumerator(atPath: path)
        while e?.nextObject() != nil, n < 100_000 { n += 1 }
        return max(n, 1)
    }
}

/// A minimal POSIX pax tar writer. Every entry gets a pax header carrying its
/// exact UTF-8 path (and link target), so names of any length survive.
/// No uid/gid/uname, no extended attributes, no macOS metadata.
struct TarWriter {
    let out: FileHandle
    var sent: Int64 = 0
    var progress: ((Int64) -> Void)?

    mutating func write(_ plan: Plan) throws {
        for item in plan.items { try entry(item) }
        try emit(Data(count: 1024))
    }

    private mutating func entry(_ item: Plan.Item) throws {
        var pax = record("path", item.archive)
        if let t = item.linkTarget { pax += record("linkpath", t) }
        try emit(header(name: "PaxHeaders/entry", size: Int64(pax.count), type: "x", mode: 0o644, mtime: item.mtime))
        try emit(pad(pax))

        let type: Character, size: Int64
        switch item.kind {
        case .file: type = "0"; size = item.size
        case .dir: type = "5"; size = 0
        case .symlink: type = "2"; size = 0
        }
        try emit(header(name: ascii(item.archive), size: size, type: type, mode: Int(item.mode), mtime: item.mtime,
                        link: item.linkTarget.map(ascii) ?? ""))
        guard item.kind == .file else { return }

        // Exactly `size` bytes: a file that shrank while sending is padded, one that grew is cut.
        guard let fh = FileHandle(forReadingAtPath: item.local) else { throw RemoteError("cannot read \(item.local)") }
        defer { try? fh.close() }
        var left = size
        while left > 0 {
            let chunk = try fh.read(upToCount: Int(min(left, 1 << 20))) ?? Data()
            if chunk.isEmpty { try emit(Data(count: Int(left))); left = 0; break }
            try emit(chunk)
            left -= Int64(chunk.count)
        }
        let rem = Int(size % 512)
        if rem != 0 { try emit(Data(count: 512 - rem)) }
    }

    private mutating func emit(_ d: Data) throws {
        try out.write(contentsOf: d)
        sent += Int64(d.count)
        progress?(sent)
    }

    private func pad(_ d: Data) -> Data {
        var d = d
        let rem = d.count % 512
        if rem != 0 { d.append(Data(count: 512 - rem)) }
        return d
    }

    /// "<len> key=value\n" where len counts the whole record including itself.
    private func record(_ key: String, _ value: String) -> Data {
        let body = " \(key)=\(value)\n"
        let bodyLen = body.utf8.count
        var len = bodyLen + 1
        while String(len).count + bodyLen != len { len = String(len).count + bodyLen }
        return Data((String(len) + body).utf8)
    }

    /// ASCII stand-in for the fixed-width ustar fields; the pax record carries the real value.
    private func ascii(_ s: String) -> String {
        String(s.utf8.prefix(99).map { $0 < 0x80 ? Character(Unicode.Scalar($0)) : "_" })
    }

    private func header(name: String, size: Int64, type: Character, mode: Int, mtime: Int, link: String = "") -> Data {
        var h = [UInt8](repeating: 0, count: 512)
        func put(_ s: String, _ off: Int, _ len: Int) {
            for (i, b) in s.utf8.prefix(len).enumerated() { h[off + i] = b }
        }
        func octal(_ v: Int64, _ off: Int, _ len: Int) {
            put(String(String(v, radix: 8).suffix(len - 1)).leftPad(len - 1), off, len - 1)
        }
        put(name, 0, 100)
        octal(Int64(mode & 0o7777), 100, 8)
        octal(0, 108, 8)
        octal(0, 116, 8)
        octal(size, 124, 12)
        octal(Int64(max(mtime, 0)), 136, 12)
        for i in 148..<156 { h[i] = 0x20 }
        h[156] = UInt8(ascii: type.unicodeScalars.first!)
        put(link, 157, 100)
        put("ustar", 257, 6)
        put("00", 263, 2)
        let sum = h.reduce(0) { $0 + Int($1) }
        put(String(String(sum, radix: 8)).leftPad(6), 148, 6)
        h[154] = 0
        h[155] = 0x20
        return Data(h)
    }
}

private extension String {
    func leftPad(_ n: Int) -> String { count >= n ? self : String(repeating: "0", count: n - count) + self }
}

enum ShellEscape {
    /// One word for zsh/bash: plain characters as is, others backslash-escaped;
    /// names with control characters use $'…' so they still paste as one word.
    static func word(_ s: String) -> String {
        let plain = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-./,:+@%^=")
        if s.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            var out = "$'"
            for u in s.unicodeScalars {
                switch u {
                case "\\": out += "\\\\"
                case "'": out += "\\'"
                case _ where u.value < 0x20 || u.value == 0x7F: out += String(format: "\\x%02x", u.value)
                default: out.unicodeScalars.append(u)
                }
            }
            return out + "'"
        }
        var out = ""
        for u in s.unicodeScalars {
            if plain.contains(u) || u.value > 0x7F { out.unicodeScalars.append(u) } else { out += "\\" + String(u) }
        }
        return out
    }
}
