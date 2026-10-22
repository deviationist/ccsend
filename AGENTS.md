# ccsend: agent notes

Sends files and folders from macOS Finder into SSH hosts: into a Claude Code
session's working directory, an SSH shell's directory, a default location or
a typed path. Push only, over plain SSH. `DESIGN.md` holds the threat model
and the full list of guarantees. Read it before changing anything security
relevant.

## Layout

| Path | Purpose |
|---|---|
| `client/` | Swift package: the Mac app (SwiftUI window), CLI and Quick Action generator, all one binary |
| `client/Sources/ccsend/Config.swift` | Strict TOML-subset reader + schema. Unknown keys and tables are errors |
| `client/Sources/ccsend/SSH.swift` | The only place ssh is started. Hardened options, ControlMaster, `Proc.run` |
| `client/Sources/ccsend/Remote.swift` | Calls into `server/remote.py`; checks every response (`Check`, `Display`) |
| `client/Sources/ccsend/Transfer.swift` | Selection walk + filters (`Plan`), pax tar writer, shell escaping |
| `client/Sources/ccsend/Inject.swift` | Typing the path into a Claude prompt: tmux and iTerm adapters |
| `client/Sources/ccsend/Import.swift` | Unpacking an import stream from a host: the untrusted-archive rules live here |
| `client/Sources/ccsend/Install.swift` | Generates `~/Library/Services/*.workflow` from the config |
| `client/Sources/ccsend/UI/` | Window: `Model.swift` (state, SSH work off the main thread), `SendView.swift` |
| `client/Sources/ccsend/SelfTest.swift` | `ccsend selftest`: pure-logic checks |
| `server/remote.py` | Host side. Embedded into the app at build time, sent with every SSH call, never installed |
| `server/test_remote.py` | stdlib `unittest`, runs remote.py exactly as the client does |

No third-party dependencies on either side, and it should stay that way.
Client: Swift 6 toolchain, macOS 15+. Server: Python 3.8+, Linux (`/proc`).

## Build and test

```sh
make test       # server tests on the Mac + ccsend selftest
make install    # build, install to ~/Applications, link ~/.local/bin/ccsend, regenerate Quick Actions
```

Run the server tests on a Linux host too: `discover` and the tmux `inject`
test only run there.
```sh
d=$(ssh HOST mktemp -d); scp server/remote.py server/test_remote.py HOST:$d/; ssh HOST "cd $d && python3 test_remote.py; rm -rf $d"
```

`client/Sources/ccsend/RemoteScript.swift` is generated from `server/remote.py`
by make and is gitignored. Never edit it.

## Rules that must hold

- **The Mac starts every connection.** Nothing listens on the Mac, there is no
  RemoteForward, no token on hosts, and nothing is installed on hosts.
- **No shell for variable data.** On the Mac, processes are started with argv
  (`Proc.run`), never `sh -c`. The remote command line is fixed
  (`python3 -c '<bootstrap>' <b64 script> <b64 JSON>`). Never splice paths,
  names or options into it.
- **Hardened ssh options come first** (`SSH.hardened`). OpenSSH keeps the
  first value it sees, so appending them would let the config weaken them.
  The selftest checks the order.
- **Everything from the host is untrusted:** session lists, cwd, names,
  journal lines. Check it (`Check.*`), cap its size, and render it with
  `Text(verbatim:)` only. Strip control characters (`Display.clean`) before it
  reaches a terminal.
- **Writes stay inside `allowed_roots`, are never overwrites (O_EXCL), and roll back on failure.**
- **Symlinks inside sent folders are sent as links, never followed.**
- **Import is opt-in** (`import = false` by default) **and the stream is untrusted:**
  `Importer` writes only inside directories it created, never overwrites,
  quarantines every file and rolls back on failure. `selftest` feeds it
  hostile archives; keep that list growing.
- **Injection is opt-in** (`inject = "off"` by default) **and never types into a shell.**
  tmux: the pane must run that claude pid. iTerm: the connection must go to
  this host's address, ssh must be in the foreground, and the host must
  re-confirm claude is in the foreground right before typing.
- **Nothing setup-specific in the repo.** Hosts, users, paths and keys live in
  `~/.config/ccsend/config.toml`. Examples use `devbox`, `nas` and `alice`.

## Style

- Window: sentence case (capital first word). CLI and errors: lowercase, like
  ssh or git. Errors are written once in CLI form; the window capitalises them
  with `Display.sentence`.
- Logs: one `key=value` event per line, values JSON-quoted when needed, never
  file contents. The same `run=` and `id=` appear in the Mac log and the host
  journal (`journalctl -t ccsend`).

## Gotchas learned the hard way

- **Testing injection:** never target "the newest Claude session" on a host
  with real sessions, and never use `inject = "submit"` there. Target a fake
  session by directory (`ccsend send HOST claude:~/test-dir FILE`) after
  checking `ccsend sessions HOST` lists it. A fake claude is a copy of python3
  named `claude`. Ubuntu's `sleep` is a multi-call binary that refuses to run
  under another name.
- **Remote paths in local shells:** `~` in a command typed on the Mac expands
  to the Mac's home before ssh sends it. Use absolute remote paths.
- **iTerm test windows take keyboard focus.** Keystrokes meant for something
  else can land in them.
- **`unittest` runs `tearDown` before cleanups.** Register the temp-dir removal
  with `addCleanup` in `setUp`, so a test's own cleanups (like killing its tmux
  server) run first.
- **Linux limits file names to 255 bytes**, so non-ASCII names hit that sooner.
- **macOS:** delete a signed binary before copying a new one (overwriting in
  place gets it killed). Finder lists Quick Actions only after Automator has
  saved them, which `ccsend install` does. Privacy permissions are tied to the
  bundle id (`make BUNDLE_ID=…`).
- **The app's own snapshot aid:** `CCSEND_SNAPSHOT=/path CCSEND_SNAPSHOT_AT=2,5`
  renders the window to PNGs without Screen Recording permission.
