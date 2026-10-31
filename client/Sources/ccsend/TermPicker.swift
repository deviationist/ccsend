import Foundation

/// Choosing a destination at the terminal (`ccsend send HOST FILE`): fzf when
/// it is installed, else a numbered list. Labels contain text from the host
/// (session directories), so they are cleaned of control characters before
/// they reach the terminal, and the answer is only ever an index into our own
/// list, never text to act on.
enum TermPicker {
    struct Item { let label: String; let detail: String }

    static var interactive: Bool { isatty(0) == 1 && isatty(2) == 1 }

    static func fzfPath() -> String? {
        let dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin"]
        return dirs.map { $0 + "/fzf" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// One line per item: "index<TAB>label  detail". Tabs and control characters
    /// in the text become "?" (Display.clean), so the index field can't be faked.
    static func lines(_ items: [Item]) -> [String] {
        let width = min(items.map { Display.clean($0.label).count }.max() ?? 0, 60)
        return items.enumerated().map { i, it in
            let l = Display.clean(it.label)
            let pad = l.count < width ? String(repeating: " ", count: width - l.count) : ""
            return "\(i)\t" + l + pad + (it.detail.isEmpty ? "" : "  " + Display.clean(it.detail))
        }
    }

    /// The index fzf printed, if it is one of ours.
    static func index(fromFzf out: String, count: Int) -> Int? {
        guard let first = out.split(separator: "\n").first,
              let tab = first.firstIndex(of: "\t"), let i = Int(first[..<tab]), (0..<count).contains(i) else { return nil }
        return i
    }

    /// The chosen index, or nil when cancelled.
    static func choose(_ items: [Item], prompt: String, header: String) throws -> Int? {
        guard !items.isEmpty else { return nil }
        if let fzf = fzfPath() { return try viaFzf(fzf, items, prompt: prompt, header: header) }
        return viaList(items, prompt: prompt, header: header)
    }

    /// fzf draws on the terminal itself; only our lines go in and one line comes out.
    /// Started with posix_spawn and an argument vector (no shell). Not Foundation's
    /// Process: that puts the child in its own process group, and a background
    /// group reading the terminal is stopped (SIGTTIN), so fzf would hang.
    private static func viaFzf(_ fzf: String, _ items: [Item], prompt: String, header: String) throws -> Int? {
        let args = [fzf, "--no-multi", "--reverse", "--height=~50%", "--delimiter=\t", "--with-nth=2..",
                    "--prompt=" + Display.clean(prompt) + " ", "--header=" + Display.clean(header), "--no-sort"]
        // The user's FZF_DEFAULT_OPTS may bind keys to commands (execute, become): not here.
        var env = ProcessInfo.processInfo.environment
        for k in ["FZF_DEFAULT_OPTS", "FZF_DEFAULT_OPTS_FILE", "FZF_DEFAULT_COMMAND"] { env[k] = nil }

        let inPipe = Pipe(), outPipe = Pipe()
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, inPipe.fileHandleForReading.fileDescriptor, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe.fileHandleForWriting.fileDescriptor, 1)
        for fd in [inPipe.fileHandleForWriting.fileDescriptor, outPipe.fileHandleForReading.fileDescriptor] {
            posix_spawn_file_actions_addclose(&actions, fd)
        }
        // ccsend ignores Ctrl-C while fzf runs (so fzf reports it as a cancel);
        // fzf itself gets the default handling back.
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGINT)
        posix_spawnattr_setsigdefault(&attr, &defaults)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGDEF))

        let cArgs = args.map { strdup($0) } + [nil]
        let cEnv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (cArgs + cEnv).forEach { free($0) } }
        let oldInt = signal(SIGINT, SIG_IGN)
        defer { signal(SIGINT, oldInt) }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, fzf, &actions, &attr, cArgs, cEnv)
        guard rc == 0 else { throw RemoteError("cannot start fzf: \(String(cString: strerror(rc)))") }
        try? inPipe.fileHandleForReading.close()
        try? outPipe.fileHandleForWriting.close()

        inPipe.fileHandleForWriting.write(Data((lines(items).joined(separator: "\n") + "\n").utf8))
        try? inPipe.fileHandleForWriting.close()
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        // Exit 0: chosen. 130: Esc or Ctrl-C. 1: nothing matched.
        guard status & 0x7f == 0, (status >> 8) & 0xff == 0 else { return nil }
        return index(fromFzf: String(decoding: out, as: UTF8.self), count: items.count)
    }

    private static func viaList(_ items: [Item], prompt: String, header: String) -> Int? {
        say(Display.clean(header))
        for (n, line) in lines(items).enumerated() {
            let text = line.split(separator: "\t", maxSplits: 1).last.map(String.init) ?? ""
            say(String(format: "%3d) ", n + 1) + text)
        }
        while true {
            FileHandle.standardError.write(Data("\(Display.clean(prompt)) [1]: ".utf8))
            guard let a = readLine()?.trimmingCharacters(in: .whitespaces) else { return nil }
            if a.isEmpty { return 0 }
            if a == "q" { return nil }
            if let n = Int(a), (1...items.count).contains(n) { return n - 1 }
            say("enter 1-\(items.count), or q to cancel")
        }
    }

    static func say(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

    /// A line typed at the terminal (the custom path), prompt on stderr.
    static func ask(_ prompt: String) -> String? {
        FileHandle.standardError.write(Data((Display.clean(prompt) + " ").utf8))
        return readLine()?.trimmingCharacters(in: .whitespaces)
    }
}

