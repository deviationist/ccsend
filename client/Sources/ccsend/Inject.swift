import AppKit
import Foundation

/// Typing the remote path into a Claude Code prompt. Opt-in per host
/// (inject = "type" | "submit"), through the adapters in inject_via, in order:
///
///   tmux   the host pastes into the session's tmux pane (Remote.inject),
///          after checking the pane runs that claude process.
///   iterm  the Mac types into the iTerm2 tab whose ssh connection carries
///          the session: the host reports the connection's client port, the
///          Mac finds its local ssh process, that process's terminal, and the
///          iTerm session on it. Checks before typing:
///            - the local connection goes to this host's address (a host
///              cannot point us at a tab connected somewhere else),
///            - ssh is the foreground job of that terminal,
///            - the host confirms claude is still in the foreground there.
enum Injector {
    enum Adapter: String, CaseIterable { case tmux, iterm }

    /// The adapter that fits a session, without running anything.
    static func adapter(for s: Remote.Session, host: HostConfig) -> Adapter? {
        guard host.inject != .off, s.kind == .claude else { return nil }
        for a in host.injectVia {
            if a == .tmux && !s.pane.isEmpty { return .tmux }
            if a == .iterm && s.pane.isEmpty && s.sshPort > 0 { return .iterm }
        }
        return nil
    }

    static func inject(_ ssh: SSH, into s: Remote.Session, text: String) throws -> Adapter {
        guard let a = adapter(for: s, host: ssh.host) else { throw RemoteError("no inject adapter fits this session") }
        let submit = ssh.host.inject == .submit
        switch a {
        case .tmux:
            try Remote.inject(ssh, into: s, text: text, submit: submit)
        case .iterm:
            let tty = try localTerminal(port: s.sshPort, host: ssh.host)
            try Remote.foreground(ssh, s)
            try typeInITerm(tty: tty, text: text, submit: submit)
            Log.event([("event", "inject"), ("via", "iterm"), ("host", ssh.host.name), ("tty", tty), ("result", "ok"),
                       ("submitted", submit ? "true" : "false")])
        }
        return a
    }

    // MARK: - iTerm

    /// The terminal (/dev/ttysN) of the local ssh process whose connection to
    /// this host uses local port `port`, if ssh is the foreground job there.
    static func localTerminal(port: Int, host: HostConfig) throws -> String {
        let addrs = try hostAddresses(host)
        let r = try Proc.run("/usr/sbin/lsof", ["-nP", "-a", "-c", "ssh", "-iTCP", "-sTCP:ESTABLISHED", "-Fpn"],
                             stdin: nil, timeout: 10)
        var pid: String?, match: String?
        for line in String(decoding: r.stdout, as: UTF8.self).split(separator: "\n") {
            if line.hasPrefix("p") { pid = String(line.dropFirst()); continue }
            guard line.hasPrefix("n"), let p = pid else { continue }
            // n<local addr>:<port>-><remote addr>:<port>, IPv6 in brackets.
            let parts = line.dropFirst().components(separatedBy: "->")
            guard parts.count == 2, let (_, lport) = split(parts[0]), let (raddr, rport) = split(parts[1]) else { continue }
            if lport == port && addrs.ips.contains(raddr) && rport == addrs.port { match = p; break }
        }
        guard let p = match else { throw RemoteError("no open SSH connection to \(host.label) in a terminal matches that session") }
        let ps = try Proc.run("/bin/ps", ["-o", "tty=,stat=", "-p", p], stdin: nil, timeout: 5)
        let f = String(decoding: ps.stdout, as: UTF8.self).split(whereSeparator: { $0.isWhitespace })
        guard f.count == 2, f[0].hasPrefix("ttys"), f[1].contains("+") else {
            throw RemoteError("that SSH connection is not the foreground job of a terminal")
        }
        return "/dev/" + f[0]
    }

    private static func split(_ endpoint: String) -> (String, Int)? {
        guard let i = endpoint.lastIndex(of: ":"), let port = Int(endpoint[endpoint.index(after: i)...]) else { return nil }
        var addr = String(endpoint[..<i])
        if addr.hasPrefix("[") && addr.hasSuffix("]") { addr = String(addr.dropFirst().dropLast()) }
        return (addr, port)
    }

    /// Where ssh connects for this host (after ~/.ssh/config), resolved to IPs.
    static func hostAddresses(_ host: HostConfig) throws -> (ips: Set<String>, port: Int) {
        var a = ["-G"]
        for o in host.sshOptions { a += ["-o", o] }
        a += ["--", host.ssh]
        let r = try Proc.run("/usr/bin/ssh", a, stdin: nil, timeout: 10)
        var name = host.ssh, port = 22
        for line in String(decoding: r.stdout, as: UTF8.self).split(separator: "\n") {
            let kv = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            if kv[0] == "hostname" { name = kv[1] }
            if kv[0] == "port", let p = Int(kv[1]) { port = p }
        }
        var ips = Set<String>()
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        if getaddrinfo(name, nil, &hints, &res) == 0 {
            var p = res
            while let ai = p {
                var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                    ips.insert(String(cString: buf))
                }
                p = ai.pointee.ai_next
            }
            freeaddrinfo(res)
        }
        guard !ips.isEmpty else { throw RemoteError("cannot resolve \(name)") }
        return (ips, port)
    }

    /// Type into the iTerm2 session on `tty`. Text and tty go in as arguments, never into the script.
    static func typeInITerm(tty: String, text: String, submit: Bool) throws {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.googlecode.iterm2").isEmpty else {
            throw RemoteError("iTerm2 is not running")
        }
        guard !text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw RemoteError("refusing to type control characters")
        }
        let script = """
        on run argv
            set theText to item 1 of argv
            set theTTY to item 2 of argv
            set doSubmit to (item 3 of argv) is "1"
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is theTTY then
                                tell s to write text theText newline doSubmit
                                return "ok"
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return "notfound"
        end run
        """
        let r = try Proc.run("/usr/bin/osascript", ["-e", script, text, tty, submit ? "1" : "0"], stdin: nil, timeout: 15)
        let out = String(decoding: r.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if r.status != 0 {
            if r.stderrText.contains("-1743") || r.stderrText.contains("Not authorized") {
                throw RemoteError("ccsend is not allowed to control iTerm2 (System Settings → Privacy & Security → Automation)")
            }
            throw RemoteError("iTerm2 scripting failed: \(r.stderrText)")
        }
        guard out == "ok" else { throw RemoteError("no iTerm2 session on \(tty)") }
    }
}
