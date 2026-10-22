import Foundation

/// Unpacks a tar stream from a host into a Mac folder. The stream is untrusted:
///
///   - only regular files and directories (and symlinks, if allowed) are accepted;
///     anything else aborts the import
///   - every path is relative, without "..", and starts with one of the
///     requested top-level names
///   - top-level items never overwrite: a taken name becomes name-1, name-2 …
///   - nothing is written through a symlink: a parent directory must be one this
///     import created itself
///   - size and file count are capped while streaming
///   - every file gets the com.apple.quarantine flag, so Gatekeeper treats it like
///     a download; setuid/setgid bits are never set
///   - on any failure, everything this import created is removed
final class Importer {
    let dest: String
    let tops: [String]
    let allowSymlinks: Bool
    let maxBytes: Int64
    let maxFiles: Int
    var progress: ((Int64) -> Void)?

    private(set) var written: [String: String] = [:]   // top name -> local name
    private var order: [String] = []
    private var ourDirs = Set<String>()
    private var files = 0
    private var bytes: Int64 = 0
    private var buffer = Data()
    private var input: FileHandle!

    init(dest: String, tops: [String], allowSymlinks: Bool, maxBytes: Int64, maxFiles: Int) {
        self.dest = dest
        self.tops = tops
        self.allowSymlinks = allowSymlinks
        self.maxBytes = maxBytes
        self.maxFiles = maxFiles
    }

    /// Refuse before downloading if the Mac folder's volume lacks room (plus 100 MB headroom).
    static func checkSpace(_ dest: String, bytes: Int64) throws {
        let v = try URL(fileURLWithPath: dest).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let free = v.volumeAvailableCapacityForImportantUsage, free < bytes + (100 << 20) {
            throw RemoteError("not enough free space in \(dest)")
        }
    }

    /// Local paths of the imported top-level items, in request order.
    var localPaths: [String] { tops.compactMap { written[$0].map { dest + "/" + $0 } } }

    func consume(_ fh: FileHandle) throws {
        input = fh
        do {
            try run()
        } catch {
            rollback()
            throw error
        }
        let missing = tops.filter { written[$0] == nil }
        if !missing.isEmpty {
            rollback()
            throw RemoteError("the host did not send: \(missing.joined(separator: ", "))")
        }
    }

    private func rollback() {
        for t in order {
            if let n = written[t] { try? FileManager.default.removeItem(atPath: dest + "/" + n) }
        }
        written = [:]
    }

    // MARK: reading

    private func read(_ n: Int) throws -> Data {
        while buffer.count < n {
            let chunk = try input.read(upToCount: max(1 << 16, n - buffer.count)) ?? Data()
            if chunk.isEmpty { throw RemoteError("the download ended early") }
            buffer.append(chunk)
        }
        let out = buffer.prefix(n)
        buffer.removeFirst(n)
        return Data(out)
    }

    private func skip(_ n: Int64) throws {
        var left = n
        while left > 0 { let c = Int(min(left, 1 << 20)); _ = try read(c); left -= Int64(c) }
    }

    private static func field(_ h: Data, _ off: Int, _ len: Int) -> String {
        let bytes = h[h.startIndex + off ..< h.startIndex + off + len].prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func octal(_ h: Data, _ off: Int, _ len: Int) throws -> Int64 {
        let b = h[h.startIndex + off]
        if b & 0x80 != 0 { throw RemoteError("unsupported size encoding in the download") }
        let s = field(h, off, len).trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
        if s.isEmpty { return 0 }
        guard let v = Int64(s, radix: 8), v >= 0 else { throw RemoteError("bad number in the download") }
        return v
    }

    private func run() throws {
        var pax: [String: String] = [:]
        while true {
            let h = try read(512)
            if h.allSatisfy({ $0 == 0 }) { return }        // end of archive
            let type = Character(Unicode.Scalar(h[h.startIndex + 156]))
            var size = try Importer.octal(h, 124, 12)
            let mode = try Importer.octal(h, 100, 8)
            let mtime = try Importer.octal(h, 136, 12)
            var name = Importer.field(h, 0, 100)
            if Importer.field(h, 257, 5) == "ustar" {
                let prefix = Importer.field(h, 345, 155)
                if !prefix.isEmpty { name = prefix + "/" + name }
            }
            var link = Importer.field(h, 157, 100)
            let padded = (size + 511) / 512 * 512

            switch type {
            case "x", "g":
                guard size <= 1 << 20 else { throw RemoteError("oversized header in the download") }
                let data = try read(Int(padded)).prefix(Int(size))
                if type == "x" { pax = try Importer.parsePax(data) }
                continue
            default:
                break
            }
            if let p = pax["path"] { name = p }
            if let l = pax["linkpath"] { link = l }
            if let s = pax["size"], let v = Int64(s), v >= 0 { size = v }
            pax = [:]
            let body = (size + 511) / 512 * 512

            let parts = try components(name)
            let kind: Character
            switch type {
            case "0", "\0", "7": kind = "f"
            case "5": kind = "d"
            case "2":
                guard allowSymlinks else { throw RemoteError("the host sent a link although links are off") }
                kind = "l"
            default:
                throw RemoteError("unsupported entry in the download: \(Display.clean(name))")
            }
            if kind != "f" && size != 0 { try skip(body); continue }

            let path = try place(parts, isDir: kind == "d" || parts.count > 1)
            switch kind {
            case "d":
                if parts.count > 1 && !ourDirs.contains(path) {
                    guard mkdir(path, 0o755) == 0 else { throw RemoteError("cannot create \(path)") }
                    ourDirs.insert(path)
                }
            case "l":
                guard !link.isEmpty, !link.contains("\0") else { throw RemoteError("bad link in the download") }
                if parts.count == 1 { unlink(path) }        // placeholder from claim()
                guard symlink(link, path) == 0 else { throw RemoteError("cannot create link \(path)") }
                files += 1
            default:
                files += 1
                bytes += size
                guard files <= maxFiles, bytes <= maxBytes else { throw RemoteError("the download is over the limits") }
                try writeFile(path, size: size, padded: body, mode: mode, mtime: mtime, fresh: parts.count > 1)
            }
            if kind != "f" { try skip(body) }
        }
    }

    /// pax records: "<len> key=value\n", len counting the whole record.
    static func parsePax(_ d: Data) throws -> [String: String] {
        var out: [String: String] = [:]
        var i = d.startIndex
        while i < d.endIndex {
            guard let sp = d[i...].firstIndex(of: 0x20),
                  let len = Int(String(decoding: d[i..<sp], as: UTF8.self)), len > 0,
                  i + len <= d.endIndex, sp + 1 < i + len else {
                throw RemoteError("bad extended header in the download")
            }
            let rec = d[(sp + 1)..<(i + len - 1)]          // drop the trailing newline
            if let eq = rec.firstIndex(of: 0x3D) {
                out[String(decoding: rec[..<eq], as: UTF8.self)] = String(decoding: rec[(eq + 1)...], as: UTF8.self)
            }
            i += len
        }
        return out
    }

    // MARK: placing

    private func components(_ name: String) throws -> [String] {
        guard !name.hasPrefix("/") else { throw RemoteError("absolute path in the download") }
        let parts = name.split(separator: "/").map(String.init).filter { $0 != "." }
        guard !parts.isEmpty, parts.allSatisfy(Check.name) else {
            throw RemoteError("unsafe path in the download: \(Display.clean(name))")
        }
        guard tops.contains(parts[0]) else { throw RemoteError("unexpected item in the download: \(Display.clean(parts[0]))") }
        return parts
    }

    /// Local path for an entry. The first time a top-level name is seen it is claimed
    /// in dest without overwriting. Nested entries must sit inside directories this
    /// import created.
    private func place(_ parts: [String], isDir: Bool) throws -> String {
        let top = parts[0]
        if written[top] == nil {
            written[top] = try claim(top, isDir: isDir)
            order.append(top)
            if isDir { ourDirs.insert(dest + "/" + written[top]!) }
        }
        var path = dest + "/" + written[top]!
        for p in parts.dropFirst() {
            guard ourDirs.contains(path) else { throw RemoteError("path escapes its folder in the download") }
            path += "/" + p
        }
        return path
    }

    private func claim(_ name: String, isDir: Bool) throws -> String {
        let ext = isDir ? "" : (name as NSString).pathExtension
        let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        for n in 0..<10000 {
            let cand = n == 0 ? name : (ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)")
            let path = dest + "/" + cand
            if isDir {
                if mkdir(path, 0o755) == 0 { return cand }
            } else {
                let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
                if fd >= 0 { close(fd); return cand }
            }
            guard errno == EEXIST else { throw RemoteError("cannot create \(path): \(String(cString: strerror(errno)))") }
        }
        throw RemoteError("no free name for \(name)")
    }

    private func writeFile(_ path: String, size: Int64, padded: Int64, mode: Int64, mtime: Int64, fresh: Bool) throws {
        let perm = mode_t(0o644 | (mode & 0o111))
        let flags = O_WRONLY | O_NOFOLLOW | (fresh ? (O_CREAT | O_EXCL) : O_TRUNC)
        let fd = open(path, flags, perm)
        guard fd >= 0 else { throw RemoteError("cannot write \(path): \(String(cString: strerror(errno)))") }
        let fh = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var left = size
        while left > 0 {
            let chunk = try read(Int(min(left, 1 << 20)))
            try fh.write(contentsOf: chunk)
            left -= Int64(chunk.count)
            progress?(bytes - left)
        }
        fchmod(fd, perm)
        try fh.close()
        if padded > size { _ = try read(Int(padded - size)) }
        quarantine(path)
        var times = [timespec(tv_sec: Int(mtime), tv_nsec: 0), timespec(tv_sec: Int(mtime), tv_nsec: 0)]
        utimensat(AT_FDCWD, path, &times, AT_SYMLINK_NOFOLLOW)
    }

    /// The flag browsers set on downloads: Gatekeeper asks before an imported app or script runs.
    private func quarantine(_ path: String) {
        let value = String(format: "0083;%08x;ccsend;", Int(Date().timeIntervalSince1970))
        _ = value.withCString { setxattr(path, "com.apple.quarantine", $0, strlen($0), 0, XATTR_NOFOLLOW) }
    }
}
