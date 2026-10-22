import Foundation

/// Runs /usr/bin/ssh with an argument vector (never a shell on the Mac).
///
/// OpenSSH keeps the FIRST value it sees for each option, and command-line -o
/// options are read before ~/.ssh/config. The hardened options therefore come
/// first, so neither the ccsend config nor ~/.ssh/config can weaken them.
struct SSH {
    let host: HostConfig
    /// Set while a window is open: reuse one connection for Tab completion.
    var controlPath: String?

    static let hardened = [
        "BatchMode=yes",              // never prompt: Quick Actions have no terminal
        "StrictHostKeyChecking=yes",  // never send to an unverified host
        "ClearAllForwardings=yes",
        "ForwardAgent=no",
        "ForwardX11=no",
        "PermitLocalCommand=no",
        "RequestTTY=no",
        "ConnectTimeout=10",
        "ServerAliveInterval=15",
        "ServerAliveCountMax=2",
        "LogLevel=ERROR",
    ]

    static let controlDir: URL = {
        let d = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/ccsend")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(d.path, 0o700)
        return d
    }()

    func baseArgs(control: String = "no") -> [String] {
        var a: [String] = []
        for o in SSH.hardened { a += ["-o", o] }
        if let cp = controlPath {
            a += ["-o", "ControlMaster=\(control)", "-o", "ControlPath=\(cp)"]
        } else {
            a += ["-o", "ControlMaster=no", "-o", "ControlPath=none"]
        }
        for o in host.sshOptions { a += ["-o", o] }
        if let u = host.user { a += ["-l", u] }
        a.append("-T")
        return a
    }

    /// Start a background master connection (for completion); returns once authenticated.
    static func openMaster(for host: HostConfig) throws -> SSH {
        var s = SSH(host: host, controlPath: nil)
        let path = controlDir.appendingPathComponent("cm-\(host.name)-\(getpid())").path
        s.controlPath = path
        var a = s.baseArgs(control: "yes")
        a += ["-o", "ControlPersist=60", "-N", "-f", "--", host.ssh]
        let start = Date()
        let r = try Proc.run("/usr/bin/ssh", a, stdin: nil, timeout: 20)
        let ms = String(Int(Date().timeIntervalSince(start) * 1000))
        guard r.status == 0 else {
            Log.event([("event", "connect"), ("host", host.name), ("result", "error"), ("ms", ms), ("error", Log.value(r.stderrText))])
            throw RemoteError("cannot connect to \(host.label): \(r.stderrText)")
        }
        Log.event([("event", "connect"), ("host", host.name), ("result", "ok"), ("ms", ms)])
        return s
    }

    func closeMaster() {
        guard let cp = controlPath else { return }
        var a = baseArgs()
        a += ["-O", "exit", "--", host.ssh]
        _ = try? Proc.run("/usr/bin/ssh", a, stdin: nil, timeout: 5)
        unlink(cp)
    }

    func stream(_ remoteCommand: String, timeout: TimeInterval, consume: (FileHandle) throws -> Void) throws -> ProcResult {
        var a = baseArgs()
        a += ["--", host.ssh, remoteCommand]
        return try Proc.stream("/usr/bin/ssh", a, timeout: timeout, consume: consume)
    }

    /// Run a remote command line (already fixed and quoted by Remote).
    func run(_ remoteCommand: String, stdin: ((FileHandle) throws -> Void)? = nil, timeout: TimeInterval) throws -> ProcResult {
        var a = baseArgs()
        a += ["--", host.ssh, remoteCommand]
        return try Proc.run("/usr/bin/ssh", a, stdin: stdin, timeout: timeout)
    }
}

struct ProcResult {
    var status: Int32
    var stdout: Data
    var stderr: Data
    var stderrText: String {
        Display.clean(String(decoding: stderr.prefix(2000), as: UTF8.self)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum Proc {
    /// Run a program and hand its stdout to `consume` as a stream (for large
    /// downloads). stderr is collected. The process is killed if `consume` throws
    /// or after `timeout`.
    static func stream(_ path: String, _ args: [String], timeout: TimeInterval,
                       consume: (FileHandle) throws -> Void) throws -> ProcResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel() }
        do {
            try consume(out.fileHandleForReading)
        } catch {
            p.terminate()
            group.wait()
            p.waitUntilExit()
            throw error
        }
        _ = out.fileHandleForReading.readDataToEndOfFile()   // drain anything after the archive
        group.wait()
        p.waitUntilExit()
        return ProcResult(status: p.terminationStatus, stdout: Data(), stderr: errData)
    }

    /// Run a program with an argument vector. stdin, if given, is written on a
    /// background thread (and closed afterwards) while stdout/stderr are drained.
    static func run(_ path: String, _ args: [String], stdin: ((FileHandle) throws -> Void)?,
                    timeout: TimeInterval, env: [String: String]? = nil) throws -> ProcResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if let env { p.environment = env }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let inPipe = stdin == nil ? nil : Pipe()
        p.standardInput = inPipe ?? FileHandle.nullDevice
        try p.run()

        let group = DispatchGroup()
        var outData = Data(), errData = Data(), writeError: Error?
        let q = DispatchQueue.global()
        group.enter(); q.async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); q.async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        if let inPipe, let stdin {
            group.enter()
            q.async {
                do { try stdin(inPipe.fileHandleForWriting) } catch { writeError = error }
                try? inPipe.fileHandleForWriting.close()
                group.leave()
            }
        }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            group.wait()
            throw RemoteError("timed out after \(Int(timeout))s")
        }
        p.waitUntilExit()
        if let writeError, p.terminationStatus == 0 { throw writeError }
        return ProcResult(status: p.terminationStatus, stdout: outData, stderr: errData)
    }
}
