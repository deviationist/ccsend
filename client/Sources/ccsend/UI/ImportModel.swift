import AppKit
import Foundation

/// State of one import window: browse the host, pick entries, pull them into `dest`.
/// Listings come from the host and are untrusted; they reach the view only
/// through Remote.browse's checks and are rendered verbatim.
final class ImportModel: ObservableObject {
    enum Phase: Equatable { case connecting, ready, importing, done, failed(String) }

    let config: Config
    @Published var host: HostConfig { didSet { if oldValue.name != host.name { reset(); connect() } } }
    let dest: String

    @Published var phase = Phase.connecting
    @Published var home = ""
    @Published var shortcuts: [(label: String, path: String)] = []
    @Published var dir = ""                 // current remote folder (resolved)
    @Published var parent = ""
    @Published var entries: [Remote.RemoteEntry] = []
    @Published var loading = false
    @Published var listError = ""
    @Published var path = "~/"              // the path field
    @Published var candidates: [Remote.Entry] = []
    @Published var completionNote = ""
    @Published var selection = Set<String>() { didSet { replan() } }
    @Published var includeHidden: Bool { didSet { reload(); replan() } }
    @Published var applyExcludes: Bool { didSet { replan() } }
    @Published var keepLinks: Bool { didSet { replan() } }
    @Published var plan: Remote.DownloadPlan?
    @Published var planning = false
    @Published var importError: String?
    @Published var overLimitConfirmed = false
    @Published var progress: Double = 0
    @Published var imported: [String] = []

    private var ssh: SSH?
    private let work = DispatchQueue(label: "ccsend.import")
    private var planGen = 0

    init(config: Config, host: HostConfig, dest: String) {
        self.config = config
        self.host = host
        self.dest = dest
        includeHidden = config.includeHidden
        applyExcludes = config.applyExcludes
        keepLinks = host.importSymlinks
        connect()
    }

    var options: Remote.DownloadOptions {
        Remote.DownloadOptions(hidden: includeHidden, excludes: applyExcludes ? config.excludes : [], symlinks: keepLinks)
    }

    func tilde(_ p: String) -> String { Display.tilde(p, home: home) }

    var localDestLabel: String {
        let h = FileManager.default.homeDirectoryForCurrentUser.path
        return dest == h ? "~" : dest.hasPrefix(h + "/") ? "~" + dest.dropFirst(h.count) : dest
    }

    // MARK: connection

    private func reset() {
        close()
        dir = ""; parent = ""; entries = []; selection = []; shortcuts = []; plan = nil
        keepLinks = host.importSymlinks
    }

    func connect() {
        phase = .connecting
        let host = self.host
        work.async {
            do {
                let s = try SSH.openMaster(for: host)
                let d = try? Remote.discover(s)
                DispatchQueue.main.async {
                    self.ssh = s
                    self.home = d?.home ?? ""
                    var sc: [(String, String)] = []
                    for x in d?.sessions ?? [] where x.kind == .claude { sc.append(("Claude  " + Display.tilde(x.cwd, home: self.home), x.cwd)) }
                    for x in d?.sessions ?? [] where x.kind == .shell { sc.append(("Shell  " + Display.tilde(x.cwd, home: self.home), x.cwd)) }
                    sc.append(("Home  ~", "~"))
                    if !host.defaultLocation.isEmpty { sc.append(("Default  " + host.defaultLocation, host.defaultLocation)) }
                    self.shortcuts = sc
                    self.phase = .ready
                    self.go(self.startFolder(newestClaude: d?.sessions.first(where: { $0.kind == .claude })?.cwd))
                }
            } catch {
                DispatchQueue.main.async { self.phase = .failed("\(error)") }
            }
        }
    }

    /// import_start: home (default) | newest-claude | default | last | a path.
    private func startFolder(newestClaude: String?) -> String {
        switch host.importStart {
        case "home": return "~"
        case "newest-claude": return newestClaude ?? "~"
        case "default": return host.defaultLocation.isEmpty ? "~" : host.defaultLocation
        case "last": return LastImport.get(host.name) ?? newestClaude ?? "~"
        default: return host.importStart
        }
    }

    func close() {
        let s = ssh
        ssh = nil
        s?.closeMaster()
    }

    // MARK: browsing

    func go(_ target: String) {
        guard let ssh else { return }
        loading = true
        listError = ""
        candidates = []
        let hidden = includeHidden
        work.async {
            let r = Result { try Remote.browse(ssh, dir: target, hidden: hidden) }
            DispatchQueue.main.async {
                self.loading = false
                switch r {
                case .success(let b):
                    if b.dir != self.dir { self.selection = [] }
                    self.dir = b.dir
                    self.parent = b.parent
                    self.entries = b.entries
                    self.path = self.tilde(b.dir) == "~" ? "~/" : self.tilde(b.dir) + "/"
                case .failure(let e):
                    self.listError = Display.sentence("\(e)")
                }
            }
        }
    }

    func reload() { if !dir.isEmpty { go(dir) } }
    func up() { if !parent.isEmpty { go(parent) } }

    func open(_ e: Remote.RemoteEntry) {
        guard e.kind == .dir else { return }
        go(dir == "/" ? "/" + e.name : dir + "/" + e.name)
    }

    func selectable(_ e: Remote.RemoteEntry) -> Bool {
        e.kind == .file || e.kind == .dir || (e.kind == .link && keepLinks)
    }

    func toggle(_ e: Remote.RemoteEntry) {
        guard selectable(e) else { return }
        if selection.contains(e.name) { selection.remove(e.name) } else { selection.insert(e.name) }
    }

    func selectAll() { selection = Set(entries.filter(selectable).map(\.name)) }

    // MARK: completion

    func complete() {
        guard let ssh else { return }
        let text = path, roots = host.importRoots
        work.async {
            let r = Completion.complete(text, ssh: ssh, roots: roots)
            DispatchQueue.main.async {
                guard self.path == text else { return }
                self.completionNote = r.note
                self.candidates = r.candidates
                if let t = r.text { self.path = t }
                if r.beep { NSSound.beep() }
            }
        }
    }

    func pick(_ e: Remote.Entry) {
        guard let slash = path.range(of: "/", options: .backwards) else { return }
        path = String(path[..<slash.upperBound]) + e.name + (e.isDir ? "/" : "")
        candidates = []
        if e.isDir { go(path) }
    }

    // MARK: plan and import

    private func replan() {
        planGen += 1
        overLimitConfirmed = false
        let gen = planGen, names = Array(selection).sorted(), d = dir, o = options
        guard let ssh, !names.isEmpty, !d.isEmpty else { plan = nil; planning = false; return }
        planning = true
        work.asyncAfter(deadline: .now() + 0.25) {
            guard gen == self.planGen else { return }
            let r = Result { try Remote.downloadPlan(ssh, dir: d, names: names, o) }
            DispatchQueue.main.async {
                guard gen == self.planGen else { return }
                self.planning = false
                switch r {
                case .success(let p): self.plan = p; self.importError = nil
                case .failure(let e): self.plan = nil; self.importError = "\(e)"
                }
            }
        }
    }

    var overLimit: Bool {
        guard let p = plan else { return false }
        return p.bytes > Int64(config.maxTotalMB) << 20 || p.files > config.maxFiles
    }

    var canImport: Bool { phase == .ready && !selection.isEmpty && plan != nil && !planning }

    func start() {
        guard canImport, let ssh, let plan else { return }
        if overLimit && !overLimitConfirmed { overLimitConfirmed = true; return }
        phase = .importing
        importError = nil
        let names = Array(selection).sorted(), d = dir, o = options, dest = self.dest
        let total = max(Double(plan.bytes), 1)
        var tick = Date.distantPast
        work.async {
            do {
                try Importer.checkSpace(dest, bytes: plan.bytes)
                let imp = Importer(dest: dest, tops: names, allowSymlinks: o.symlinks,
                                   maxBytes: plan.bytes + (1 << 20), maxFiles: plan.files + 100)
                imp.progress = { sent in
                    guard Date().timeIntervalSince(tick) > 0.1 else { return }
                    tick = Date()
                    DispatchQueue.main.async { self.progress = min(Double(sent) / total, 1) }
                }
                try Remote.download(ssh, dir: d, names: names, o, maxBytes: imp.maxBytes, maxFiles: imp.maxFiles, consume: imp.consume)
                let paths = imp.localPaths
                DispatchQueue.main.async {
                    self.imported = paths
                    LastImport.set(self.host.name, d)
                    self.progress = 1
                    self.phase = .done
                    NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { NSApp.terminate(nil) }
                }
            } catch {
                DispatchQueue.main.async {
                    self.importError = "\(error)"
                    self.phase = .ready
                }
            }
        }
    }
}

/// The folder last imported from, per host (for import_start = "last"). Mac only.
enum LastImport {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ccsend/last-import.json")

    static func get(_ host: String) -> String? {
        guard let d = try? Data(contentsOf: url), let o = try? JSONSerialization.jsonObject(with: d) as? [String: String],
              let p = o[host], Check.path(p) else { return nil }
        return p
    }

    static func set(_ host: String, _ dir: String) {
        var o = ((try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }) ?? [:]
        o[host] = dir
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) { try? d.write(to: url, options: .atomic) }
    }
}
