import Foundation

/// Guessing the destination from the names being sent (`ui.guess_destination`):
/// "Floke-6.zip" suggests a folder named floke, Floke or floke_app's sibling
/// "Floke-App" for "floke-app-v2.tar.gz". Pure logic; the host does the walk.
enum Guess {
    /// Words too generic to say anything about where a file belongs: common
    /// file-name noise and common folder names.
    static let stop: Set<String> = [
        "the", "and", "for", "with", "from", "copy", "final", "draft", "new", "old", "untitled", "edit", "edited",
        "screenshot", "screen", "shot", "recording", "image", "img", "photo", "pic", "picture", "video", "movie",
        "scan", "export", "exported", "download", "downloads", "upload", "file", "files", "document", "documents",
        "doc", "docs", "backup", "version", "ver", "release", "latest", "main", "master", "archive",
        "desktop", "home", "tmp", "temp", "test", "tests", "data", "src", "lib", "bin", "build", "dist", "out",
        "output", "app", "apps", "code", "projects", "project", "misc", "inbox", "work", "notes", "readme", "index", "assets",
        "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec",
    ]
    static let maxWords = 32

    /// Lowercase letters and digits only: how folder names and words are compared.
    static func norm(_ s: String) -> String {
        String(String.UnicodeScalarView(s.lowercased().unicodeScalars.filter { $0.isASCII && CharacterSet.alphanumerics.contains($0) }))
    }

    /// Tokens of one name: extension(s) removed, split at punctuation, letter/digit
    /// changes and camelCase humps. "FlokeApp-v2.tar.gz" -> floke app v 2.
    static func tokens(_ name: String) -> [String] {
        var stem = name
        let ext = (stem as NSString).pathExtension
        if !ext.isEmpty, ext.count <= 5, ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
            stem = String(stem.dropLast(ext.count + 1))
            if ["gz", "bz2", "xz", "zst"].contains(ext.lowercased()), stem.lowercased().hasSuffix(".tar") { stem = String(stem.dropLast(4)) }
        }
        var out: [String] = [], cur = ""
        var prev: Character?
        for c in stem {
            guard c.isASCII, c.isLetter || c.isNumber else { if !cur.isEmpty { out.append(cur); cur = "" }; prev = nil; continue }
            if let p = prev, !cur.isEmpty, (p.isNumber != c.isNumber) || (p.isLowercase && c.isUppercase) {
                out.append(cur); cur = ""
            }
            cur.append(c)
            prev = c
        }
        if !cur.isEmpty { out.append(cur) }
        return out.map { $0.lowercased() }
    }

    /// Words a folder name may match: runs of up to four adjacent tokens joined
    /// ("floke", "flokeapp"), at least 3 characters, not generic.
    static func words(_ names: [String]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for name in names {
            let t = tokens(name)
            for i in t.indices {
                for n in 1...4 where i + n <= t.count {
                    let run = t[i..<(i + n)], w = run.joined()
                    // Not "floke6" from "Floke-6", not "finalcopy": a run must not start or end
                    // with a number and must hold at least one word that says something.
                    guard w.count >= 3, w.count <= 64, !run.first!.allSatisfy(\.isNumber), !run.last!.allSatisfy(\.isNumber),
                          run.contains(where: { $0.count >= 3 && !stop.contains($0) && !$0.allSatisfy(\.isNumber) }),
                          !stop.contains(w), seen.insert(w).inserted else { continue }
                    out.append(w)
                }
            }
        }
        return Array(out.prefix(maxWords))
    }

    /// The longest word matched by a component of `path` below `home`, if any.
    static func match(_ path: String, home: String, words: Set<String>) -> String? {
        var rel = path
        if !home.isEmpty, path.hasPrefix(home + "/") { rel = String(path.dropFirst(home.count + 1)) }
        else if path == home { return nil }
        return rel.split(separator: "/").map { norm(String($0)) }.filter(words.contains).max { $0.count < $1.count }
    }

    struct Folder: Equatable { let path: String; let word: String; let depth: Int; let mtime: Date }

    /// The folder to suggest: the longest (most specific) word, then the
    /// shallowest, then the most recently changed.
    static func best(_ folders: [Folder]) -> Folder? {
        folders.min { a, b in
            if a.word.count != b.word.count { return a.word.count > b.word.count }
            if a.depth != b.depth { return a.depth < b.depth }
            return a.mtime > b.mtime
        }
    }
}
