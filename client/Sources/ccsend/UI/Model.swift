import AppKit
import Foundation

/// State of one send window. All SSH work runs off the main thread; results
/// are published back on it. Strings from the host reach the view only
/// through Check/Display and are rendered verbatim.
/// Tab completion of a remote path, shared by the send and import windows.
enum Completion {
    struct Result { var text: String?; var candidates: [Remote.Entry] = []; var note = ""; var beep = false }

    static func complete(_ input: String, ssh: SSH, roots: [String]) -> Result {
        var text = input
        if text.isEmpty || text == "~" { text = "~/" }
        guard text.hasPrefix("/") || text.hasPrefix("~/") else { return Result(text: nil, note: "paths start with ~/ or /") }
        let slash = text.range(of: "/", options: .backwards)!
        let dirPart = String(text[..<slash.upperBound])
        let prefix = String(text[slash.upperBound...])
        do {
            let (_, entries) = try Remote.list(ssh, dir: dirPart, prefix: prefix, roots: roots)
            if entries.isEmpty { return Result(text: text == input ? nil : text, beep: true) }
            if entries.count == 1 {
                let e = entries[0]
                return Result(text: dirPart + e.name + (e.isDir ? "/" : ""))
            }
            let common = entries.map(\.name).reduce(entries[0].name) { $0.commonPrefix(with: $1) }
            if common.count > prefix.count { return Result(text: dirPart + common) }
            return Result(text: text == input ? nil : text, candidates: entries)
        } catch {
            return Result(text: nil, note: Display.clean("\(error)"))
        }
    }
}

final class SendModel: ObservableObject {
    enum Phase: Equatable { case connecting, ready, sending, done, failed(String) }

    struct Destination: Identifiable, Hashable {
        enum Kind: Hashable { case session(Remote.Session), defaultLocation, path }
        let kind: Kind
        var id: String {
            switch kind {
            case .session(let s): return s.id
            case .defaultLocation: return "default"
            case .path: return "path"
            }
        }
    }

    let config: Config
    let files: [String]

    @Published var host: HostConfig { didSet { if oldValue.name != host.name { injectOn = true; connect() } } }
    @Published var phase = Phase.connecting
    @Published var discovery: Remote.Discovery?
    @Published var destinations: [Destination] = []
    @Published var selected: String? {
        didSet { if programmatic == 0 && selected != nil { userChose = true; notice = "" } }
    }
    @Published var refreshing = false
    @Published var updatedAt: Date?
    @Published var notice = ""
    @Published var path = "~/"
    @Published var candidates: [Remote.Entry] = []
    @Published var completionNote = ""
    @Published var includeHidden: Bool { didSet { replan() } }
    @Published var applyExcludes: Bool { didSet { replan() } }
    @Published var plan: Plan?
    @Published var planError: String?
    @Published var sendError: String?
    @Published var overLimitConfirmed = false
    @Published var progress: Double = 0
    @Published var result: SendResult?
    @Published var injectOn = true          // the per-send checkbox; only shown when the host opted in
    @Published var doneMessage = ""

    private var ssh: SSH?
    private var userChose = false      // the user picked a destination: refreshes never change it
    private var programmatic = 0
    private var timer: Timer?
    private var generation = 0
    private let work = DispatchQueue(label: "ccsend.work")

    init(config: Config, host: HostConfig, files: [String]) {
        self.config = config
        self.files = files
        self.host = host
        includeHidden = config.includeHidden
        applyExcludes = config.applyExcludes
        replan()
        connect()
    }

    // MARK: connection and discovery

    func connect() {
        generation += 1
        let gen = generation, host = self.host, old = ssh
        ssh = nil
        phase = .connecting
        discovery = nil
        destinations = []
        setSelected(nil)
        userChose = false
        notice = ""
        candidates = []
        work.async {
            old?.closeMaster()
            do {
                let s = try SSH.openMaster(for: host)
                let d = (host.claudeSessions || host.sshSessions) ? try Remote.discover(s) : nil
                DispatchQueue.main.async {
                    guard gen == self.generation else { s.closeMaster(); return }
                    self.ssh = s
                    self.discovery = d
                    self.updatedAt = Date()
                    self.buildDestinations()
                    self.phase = .ready
                    self.startTimer()
                }
            } catch {
                DispatchQueue.main.async {
                    if gen == self.generation { self.phase = .failed("\(error)") }
                }
            }
        }
    }

    func close() {
        timer?.invalidate()
        let s = ssh
        ssh = nil
        s?.closeMaster()
    }

    private func setSelected(_ id: String?) {
        programmatic += 1
        selected = id
        programmatic -= 1
    }

    private func buildDestinations() {
        var d: [Destination] = []
        for s in discovery?.sessions ?? [] {
            if s.kind == .claude && host.claudeSessions || s.kind == .shell && host.sshSessions {
                d.append(Destination(kind: .session(s)))
            }
        }
        if !host.defaultLocation.isEmpty { d.append(Destination(kind: .defaultLocation)) }
        if host.customPath { d.append(Destination(kind: .path)) }
        destinations = d

        if let cur = selected {
            // Never move a selection; only clear it when its session has ended.
            if !d.contains(where: { $0.id == cur }) {
                setSelected(nil)
                userChose = false
                notice = "The selected session has ended. Choose a destination."
            }
            return
        }
        guard !userChose else { return }
        switch config.preselect {
        case .newestClaude:
            setSelected(d.first(where: { if case .session(let s) = $0.kind { return s.kind == .claude } else { return false } })?.id
                ?? d.first(where: { $0.kind == .defaultLocation })?.id)
        case .defaultLocation:
            setSelected(d.first(where: { $0.kind == .defaultLocation })?.id)
        case .none:
            break
        }
    }

    // MARK: refresh

    private func startTimer() {
        timer?.invalidate()
        guard config.refreshSeconds > 0 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(config.refreshSeconds), repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    /// Re-read the sessions over the open connection; reconnect once if it has gone.
    func refresh() {
        guard phase == .ready, !refreshing, let current = ssh else { return }
        guard host.claudeSessions || host.sshSessions else { updatedAt = Date(); return }
        refreshing = true
        let gen = generation, host = self.host
        work.async {
            var s = current
            var r = Result { try Remote.discover(s) }
            if case .failure = r, let fresh = try? SSH.openMaster(for: host) {
                s = fresh
                r = Result { try Remote.discover(fresh) }
            }
            DispatchQueue.main.async {
                self.refreshing = false
                guard gen == self.generation, self.phase == .ready else { return }
                if s.controlPath != current.controlPath { current.closeMaster(); self.ssh = s }
                switch r {
                case .success(let d):
                    if self.notice.hasPrefix("Refresh failed") { self.notice = "" }
                    self.discovery = d
                    self.updatedAt = Date()
                    self.buildDestinations()
                case .failure(let e):
                    self.notice = "Refresh failed: " + Display.sentence("\(e)")
                }
            }
        }
    }

    func tilde(_ p: String) -> String { Display.tilde(p, home: discovery?.home ?? "") }

    // MARK: plan

    func replan() {
        let opts = Plan.Options(includeHidden: includeHidden, applyExcludes: applyExcludes,
                                excludes: config.excludes, alwaysSkip: config.alwaysSkip)
        let files = self.files
        overLimitConfirmed = false
        work.async {
            let r = Result { try Plan.build(files, opts) }
            DispatchQueue.main.async {
                switch r {
                case .success(let p): self.plan = p; self.planError = nil
                case .failure(let e): self.plan = nil; self.planError = "\(e)"
                }
            }
        }
    }

    var overLimit: Bool {
        guard let p = plan else { return false }
        return p.bytes > Int64(config.maxTotalMB) << 20 || p.files > config.maxFiles
    }

    // MARK: Tab completion

    /// zsh-like: complete the last path component against a remote listing.
    func complete() {
        guard let ssh, phase == .ready else { return }
        let text = path, gen = generation, roots = host.allowedRoots
        work.async {
            let r = Completion.complete(text, ssh: ssh, roots: roots)
            DispatchQueue.main.async {
                guard gen == self.generation, self.path == text else { return }
                self.apply(r)
            }
        }
    }

    private func apply(_ r: Completion.Result) {
        completionNote = r.note
        candidates = r.candidates
        if let t = r.text { path = t }
        if r.beep { NSSound.beep() }
    }

    func pick(_ e: Remote.Entry) {
        guard let slash = path.range(of: "/", options: .backwards) else { return }
        path = String(path[..<slash.upperBound]) + e.name + (e.isDir ? "/" : "")
        candidates = []
    }

    // MARK: send

    /// The selected destination, if it is a Claude session.
    var selectedClaude: Remote.Session? {
        guard let id = selected, let d = destinations.first(where: { $0.id == id }),
              case .session(let s) = d.kind, s.kind == .claude else { return nil }
        return s
    }

    /// Where the path will be typed after the upload, if anywhere.
    var injectTarget: Remote.Session? {
        guard injectOn, let s = selectedClaude, Injector.adapter(for: s, host: host) != nil else { return nil }
        return s
    }

    var canSend: Bool {
        phase == .ready && plan != nil && selected != nil && (selected != "path" || path.count > 1)
    }

    func send() {
        guard canSend, let ssh, let plan, let id = selected,
              let dest = destinations.first(where: { $0.id == id }) else { return }
        if overLimit && !overLimitConfirmed { overLimitConfirmed = true; return }
        var dir = "", create = false
        switch dest.kind {
        case .session(let s): dir = s.cwd
        case .defaultLocation: dir = host.defaultLocation; create = true
        case .path: dir = path
        }
        phase = .sending
        sendError = nil
        let total = max(Double(plan.bytes), 1)
        let injectInto = injectTarget, submit = host.inject == .submit
        var lastTick = Date.distantPast
        work.async {
            do {
                let r = try Sender.send(plan, to: dir, create: create, via: ssh) { sent in
                    guard Date().timeIntervalSince(lastTick) > 0.1 else { return }
                    lastTick = Date()
                    DispatchQueue.main.async { self.progress = min(Double(sent) / total, 1) }
                }
                var message = "Sent. Path copied to the clipboard."
                if let s = injectInto {
                    do {
                        _ = try Injector.inject(ssh, into: s, text: r.clipboard + " ")
                        message = submit ? "Sent, typed into Claude and submitted. Also copied."
                                         : "Sent and typed into the Claude prompt. Also copied."
                    } catch {
                        message = "Sent. Path copied, but typing into Claude failed: " + Display.sentence("\(error)")
                    }
                }
                DispatchQueue.main.async {
                    Sender.copyToClipboard(r.clipboard)
                    self.doneMessage = message
                    self.result = r
                    self.progress = 1
                    self.phase = .done
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { NSApp.terminate(nil) }
                }
            } catch {
                DispatchQueue.main.async {
                    self.sendError = "\(error)"
                    self.phase = .ready
                }
            }
        }
    }
}
