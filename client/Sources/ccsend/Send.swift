import AppKit
import Foundation

/// One send, shared by the CLI and the window.
struct SendResult {
    let host: HostConfig
    let dir: String
    let paths: [String]          // absolute remote paths of the top-level items
    var clipboard: String { paths.map(ShellEscape.word).joined(separator: " ") }
}

enum Sender {
    static func send(_ plan: Plan, to dir: String, create: Bool, via ssh: SSH,
                     progress: ((Int64) -> Void)? = nil) throws -> SendResult {
        guard !plan.tops.isEmpty else { throw RemoteError("nothing to send") }
        let r = try Remote.upload(ssh, dir: dir, create: create, tops: plan.tops) { fh in
            var w = TarWriter(out: fh)
            w.progress = progress
            try w.write(plan)
        }
        let byTop = Dictionary(uniqueKeysWithValues: r.written.map { ($0.sent, $0.name) })
        let paths = plan.tops.map { r.dir == "/" ? "/" + byTop[$0]! : r.dir + "/" + byTop[$0]! }
        let result = SendResult(host: ssh.host, dir: r.dir, paths: paths)
        return result
    }

    static func copyToClipboard(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }
}

/// ~/Library/Logs/ccsend.log: one event per line, key=value, rotated at 1 MB.
/// Never file contents. File names only when log_names is on.
enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ccsend.log")
    /// This run (window or CLI invocation); sent to the host with every request.
    static let run = String(UUID().uuidString.lowercased().prefix(8))
    static var logNames = true

    static func newID() -> String { String(UUID().uuidString.lowercased().prefix(12)) }

    static func value(_ v: String) -> String {
        let plain = v.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._/:@%+-".unicodeScalars.contains($0) }
        if plain && !v.isEmpty { return v }
        let data = try? JSONSerialization.data(withJSONObject: [v], options: [.withoutEscapingSlashes])
        let arr = data.map { String(decoding: $0, as: UTF8.self) } ?? "[\"?\"]"
        return String(arr.dropFirst().dropLast())
    }

    static func names(_ n: [String]) -> String {
        let data = try? JSONSerialization.data(withJSONObject: n, options: [.withoutEscapingSlashes])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }

    static func event(_ fields: [(String, String)]) {
        let line = ([("run", run)] + fields).map { "\($0.0)=\($0.1)" }.joined(separator: " ")
        write(line)
    }

    static func write(_ line: String) {
        let fm = FileManager.default
        if let a = try? fm.attributesOfItem(atPath: url.path), (a[.size] as? Int ?? 0) > 1 << 20 {
            try? fm.removeItem(at: url.appendingPathExtension("1"))
            try? fm.moveItem(at: url, to: url.appendingPathExtension("1"))
        }
        let ts = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(ts) \(Display.clean(line))\n".utf8)
        if let fh = try? FileHandle(forWritingTo: url) {
            _ = try? fh.seekToEnd()
            try? fh.write(contentsOf: data)
            try? fh.close()
        } else {
            fm.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
        }
    }
}
