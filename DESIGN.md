# ccsend — design

Send files and folders from the Mac into an SSH host: into the working
directory of a running Claude Code session, the current directory of an open
SSH shell, a configured default location, or a path you type with Tab
completion. Push only, over SSH, with the remote path copied to the clipboard.

Status: implemented, 2026-10-22. Hosts: Linux with python3 3.8+ (developed
against Ubuntu). macOS hosts are not supported yet (see §9).

## Layout

Repository layout:

| Path | What |
|---|---|
| `client/` | The Mac side: `ccsend.app` (Swift: window, CLI, config, SSH runner), Quick Action generator |
| `server/` | The host side: `remote.py`. Not a daemon and never installed: the client embeds it and sends it with each SSH call |
| `DESIGN.md` | This file |

## 1. Goals and non-goals

Goals
- Finder Quick Action → pick a target → files land there → remote path on the
  clipboard, absolute and shell-escaped.
- Files and folders, any type.
- Everything configured on the Mac; nothing installed or configured on hosts.
- Security first: the Mac initiates everything, the host can never ask for
  anything, and data from the host is treated as untrusted.

Non-goals
- Syncing, watching, or any background transfer.
- Pulling files from hosts to the Mac.
- Managing SSH auth. OpenSSH and `~/.ssh/config` own keys, certificates,
  agents, jump hosts and host keys.

## 2. Security model

### Assets
- Files on the Mac that were not selected for sending (everything else).
- The Mac itself (no code execution from a host).
- Files on the host outside the chosen destination.

### Adversaries considered
| Adversary | Example | What it must not achieve |
|---|---|---|
| Malicious process on the host, same user | compromised npm package, an agent's tool call | read any Mac file; learn anything beyond what was sent to it; redirect a send to another host |
| Malicious data from the host | crafted directory or session names | command injection on the Mac or the host; spoofed clipboard content; breaking out of the destination |
| Network attacker | LAN, Wi-Fi | anything (SSH with strict host keys) |
| The user's own mistakes | sending a folder with `.env` / `.git` | silently leaking secrets inside a selected folder |

Out of scope: a host compromised as root or as the user *before* a send can
read whatever is sent to it. That is inherent to sending files to it.

### Guarantees
1. **One direction.** Only the Mac opens connections. No listening port on
   the Mac, no RemoteForward, no token or credential on any host, no
   installed agent on any host.
2. **Explicit consent per send.** A transfer happens only after the user
   picks a target and presses Send. No defaults are applied silently; the
   preselected target still needs confirmation.
3. **Host output is untrusted data.** Session lists, directory listings and
   written names are parsed as strict JSON with length and character limits,
   shown as plain text, never interpreted by a shell, and never used to
   choose the host. The host to connect to comes only from the Mac config.
4. **No shell on the Mac.** The app runs `/usr/bin/ssh` and `/usr/bin/tar`
   with argument vectors (`Process`), never through `sh -c`.
5. **No injection on the host.** The remote command line is fixed:
   `python3 -c <fixed bootstrap> <base64 script>`. All variable input
   (paths, options) travels base64-encoded as JSON, decoded by the script.
6. **Writes confined on the host.** The remote side resolves the destination
   with `realpath`, requires it inside a configured `allowed_roots` entry,
   creates new entries with `O_EXCL` / `mkdir` (never overwrites), and
   refuses `..`, absolute names, device files and hard links in the stream.
7. **Folders never leak outside themselves.** Symlinks inside a sent folder
   are sent as links and never followed. Only regular files, directories and
   symlinks are sent. Hidden files and excluded patterns are filtered on the
   Mac before anything is read.
8. **Clipboard content is derived, not trusted.** The written names reported
   by the host must match the sent name or `name-N` (collision suffix);
   anything else aborts and nothing is copied.
9. **Hardened SSH invocation** (always set, cannot be overridden by config):
   `BatchMode=yes`, `StrictHostKeyChecking=yes`, `ClearAllForwardings=yes`,
   `ForwardAgent=no`, `ForwardX11=no`, `PermitLocalCommand=no`,
   `RequestTTY=no`, `ConnectTimeout=10`, `--` before the destination.
10. **Connection reuse is private and short-lived.** One ControlMaster per
    send dialog (for Tab completion), socket under
    `~/Library/Caches/ccsend/` (mode 0700), `ControlPersist=60`, closed when
    the window closes.
11. **Fail closed.** Unknown config keys, malformed host output, an
    unreachable host, a destination outside `allowed_roots`: stop with a
    clear message, send nothing.

## 3. Architecture

```
Mac                                                    host (devbox, nas)
───                                                    ─────────────────
Finder Quick Action "Send to devbox"
  └─ ccsend.app (Swift, SwiftUI window)
       ├─ reads ~/.config/ccsend/config.toml
       ├─ ssh … devbox  python3 -c … discover   ───────► lists Claude + SSH sessions
       ├─ ssh … devbox  python3 -c … list <dir> ───────► Tab completion (via ControlMaster)
       ├─ tar (filtered) | ssh … upload <dir> ───────► writes files, reports names
       └─ clipboard ← escaped absolute paths; notification; log
```

No component is installed on hosts. `remote.py` is embedded in the app and
sent with each call; the host runs it with its own `python3` (Ubuntu ships
3.12+).

### Mac components
| Component | Role |
|---|---|
| `ccsend.app` | SwiftUI window, SSH orchestration, config, clipboard, notifications. Ad-hoc signed app bundle in `~/Applications`. |
| `ccsend` CLI (same binary) | `ccsend install` (generate Quick Actions from config), `ccsend check` (validate config, test each host), `ccsend send --host devbox --to <dir> <files>` (scriptable, no UI). |
| Quick Actions | Generated: one per host (`menu = "per-host"`) or one `Send to remote` (`menu = "single"`). Each just runs `ccsend.app` with the host and the selected files. |
| `server/remote.py` | Embedded in the app at build time. Commands: `discover`, `list`, `upload`. |

Swift with no third-party packages. The config parser is a small strict TOML
subset reader written for this schema (tables, strings, booleans, integers,
string arrays); anything outside that subset is an error. This keeps the
supply chain empty.

### Remote commands (`server/remote.py`)
All arguments arrive as one base64 JSON object. Output is JSON lines.

- `discover {}` → per session `{kind: "claude"|"shell", cwd, tmux, started}`.
  Claude: processes named `claude` owned by the user, cwd from `/proc`, tmux
  session from `TMUX_PANE`. Shell: interactive SSH login shells (session
  leader, has a tty and `SSH_CONNECTION`), cwd of the foreground process;
  shells whose foreground is Claude or a tmux client are skipped (covered by
  the Claude entries).
- `list {dir, prefix}` → up to 200 entries `{name, dir: bool}` for Tab
  completion. Confined to `allowed_roots`.
- `inject {pane, pid, text, submit}` (opt-in, `inject` per host) pastes the
  shell-escaped remote paths into the tmux pane of a Claude session as a
  bracketed paste, and presses Enter only with `inject = "submit"`. Refused
  unless `pid` is the user's process named `claude`, its `TMUX_PANE` is
  `pane`, and the pane's own process is its ancestor; `text` must have no
  control characters. It never types into a shell. Claude outside tmux is
  not supported: injecting into another terminal (`TIOCSTI`) is disabled on
  modern kernels.
- `foreground {pid, ssh_port}` (iTerm adapter): the host re-confirms right
  before typing that `pid` is the user's `claude` and is the foreground
  process group of the SSH terminal with that client port. The port comes
  from the terminal's session leader (the login shell sshd started), not
  from Claude's own environment. On the Mac, the matching local ssh
  connection must go to the address this host's alias resolves to, and ssh
  must be the foreground job of its terminal; text and tty reach AppleScript
  as arguments, never as script source.
- `browse {dir, hidden, roots=import_roots}` and `download {dir, names, roots,
  symlinks, hidden, excludes, dry_run, max_bytes, max_files}` (opt-in,
  `import = true`). The host walks the named entries without following links
  and streams a pax tar on stdout, with the result on stderr. It strips owner
  names, ids and setuid/setgid bits, and skips special files, and links unless
  allowed. The Mac does not trust that stream (`Import.swift`). It accepts only
  regular files, directories and (if allowed) links, rejects absolute paths,
  `..` and names outside the requested tops, and claims top-level names
  without overwriting. It writes only inside directories it created itself, so
  never through a link. It caps bytes and files while streaming, checks free
  space first, sets `com.apple.quarantine` on every file, and removes
  everything it created on any failure.
- `upload {dir, allowed_roots}` with a tar stream on stdin → writes entries,
  prints `{dir}` then `{top}` per top-level item written.

## 4. Configuration

`~/.config/ccsend/config.toml`, mode 0600, owned by the user (refused
otherwise). Unknown keys are errors.

```toml
[ui]
menu = "per-host"            # "per-host" | "single"
preselect = "newest-claude"  # "newest-claude" | "default-location" | "none"

[folders]
include_hidden = false       # default state of the "Include hidden files" checkbox
apply_excludes = true        # default state of the "Exclude common files" checkbox
excludes = [                 # matched against each path component
  "node_modules", ".venv", "venv", "__pycache__", ".pytest_cache",
  ".mypy_cache", ".next", ".nuxt", ".turbo", "dist", "build", "target",
  ".gradle", ".DS_Store", "._*", "Thumbs.db",
]
always_skip = [".DS_Store", "._*"]   # dropped even with both boxes changed

[limits]
max_total_mb = 2048          # ask before sending more
max_files = 20000

[hosts.devbox]
label = "devbox"
ssh = "devbox"                 # ~/.ssh/config alias or hostname
user = "alice"                # optional; passed as -l (overrides ~/.ssh/config)
ssh_options = []             # optional extra -o options, e.g. ["IdentityFile=~/.ssh/ccsend_ed25519",
                             #   "CertificateFile=~/.ssh/ccsend_ed25519-cert.pub", "IdentitiesOnly=yes"]
claude_sessions = true       # list Claude Code sessions
ssh_sessions = true          # list open SSH shells
default_location = "~/inbox" # "" disables the Default target
custom_path = true           # "Choose path…" with Tab completion
allowed_roots = ["~"]        # destinations must resolve inside one of these

[hosts.nas]
label = "nas"
ssh = "nas"
user = "alice"
claude_sessions = true
ssh_sessions = true
default_location = "~/inbox"
custom_path = true
allowed_roots = ["~"]
```

Validation:
- `ssh` and `user` must match `^[A-Za-z0-9._-]+$`, so no option injection
  like `-oProxyCommand=…`.
- `ssh_options` entries must be `Key=Value` with `Key` on an allowlist:
  `IdentityFile`, `CertificateFile`, `IdentitiesOnly`, `Port`, `ProxyJump`,
  `HostKeyAlias`, `UserKnownHostsFile`. `ProxyCommand`, `LocalCommand` and
  similar are refused.
- The hardened options in §2.9 always come first on the ssh command line.
  OpenSSH keeps the first value it sees for each option and reads the
  command line before `~/.ssh/config`, so neither file can weaken them.

## 5. The window

```
┌ Send to devbox ─────────────────────────────────────────────────┐
│ 2 items: Screenshot 2026-10-22 at 00.49.54.png, web/ (14 MB)  │
│                                                               │
│ Destination                                                   │
│  (•) Claude   ~/code/myapp     tmux cc-myapp · 13:08  │
│  ( ) Claude   ~/code/webapp         tmux cc-webapp · 13:16      │
│  ( ) Shell    ~                    ssh session · 09:41        │
│  ( ) Default  ~/inbox                                         │
│  ( ) Path     [~/code/myapp/we|          ] ⇥ completes    │
│                                  web/  workers/               │
│                                                               │
│ Folders                                                       │
│  [ ] Include hidden files                                     │
│  [x] Exclude common files (node_modules, .venv, dist, …)      │
│      → 1,204 files skipped · 312 files, 14 MB will be sent    │
│                                                               │
│ ⚠ Contains sensitive-looking files: .env, config/id_ed25519   │
│                                                               │
│                                         [Cancel]  [Send ⏎]    │
└───────────────────────────────────────────────────────────────┘
```

- With `menu = "single"` a host picker sits on top. Choosing a host runs
  discovery for it.
- Discovery runs when the window opens, with a spinner and a 5 s timeout.
  An unreachable host shows an error in place of the list.
- Path field: Tab completes the common prefix; a second Tab shows the
  candidates; directories end in `/`; `~` is the remote home. Completion
  uses the shared SSH connection, so each Tab is one round trip.
- Folder options only show when a folder is selected. The counts update live.
- Sensitive-file warning: shown whenever an item that will be sent matches
  `.env*`, `id_*`, `*.pem`, `*.key`, `.netrc`, `.npmrc`, `.pypirc`, `.ssh/`,
  `.aws/`, `.git/`. It is information, not a block.
- Send uploads, copies the paths, shows a notification and closes. Esc
  cancels.

## 6. Transfer

- The Mac builds the file list itself (walks folders, applies
  hidden/exclude/always-skip, checks limits), then runs `/usr/bin/tar` with
  an explicit file list (`-T`, null-separated), `--no-mac-metadata`,
  `COPYFILE_DISABLE=1`, and without `-h`, so symlinks stay links.
- The stream goes to `ssh … upload` on stdin. Top-level names that clash on
  the host get `-1`, `-2`, and so on; nothing is overwritten.
- Clipboard: the absolute remote paths of the top-level items, each escaped
  for zsh/bash (backslash before spaces and shell metacharacters),
  space-separated, e.g.
  `/home/alice/code/myapp/Screenshot\ 2026-10-22\ at\ 00.49.54.png`.

## 7. Logging

Both ends log every request, one event per line in `key=value` form. Values
with spaces or special characters are JSON-quoted, so a line can't be forged
by a crafted name. File contents are never logged. File names are logged
unless `[logging] log_names = false`.

| Where | What | Read with |
|---|---|---|
| Mac: `~/Library/Logs/ccsend.log` (0600, rotated at 1 MB) | `connect`, `discover`, `resolve`, `list`, `upload`: result, ms, host, dir, counts, bytes, names, errors | `ccsend log [-n N]` |
| Host: journal, tag `ccsend` (journald is already size-capped) | the same request, as seen by the host: client address (from `SSH_CONNECTION`), result, dir, counts, bytes, names, refusal reason | `ccsend log --host devbox`, or `journalctl -t ccsend` on the host |

Correlation: `run=` is one window or CLI invocation, `id=` one request. Both
are generated on the Mac and sent with the request, so the same ids appear on
both sides. The server's own test suite logs with `id=selftest`.

The Mac log is the authoritative record of what left the Mac. A compromised
host can edit its own journal, so the host log is for troubleshooting and
cross-checking. `ccsend log --host` cleans control characters from the
host's lines before printing them.

## 8. Build stages

1. `remote.py` with `discover`, `list`, `upload` + its tests (run against
   devbox in a scratch dir).
2. Swift core: config parser and validation, SSH runner, `ccsend check`,
   `ccsend send` (CLI, no UI). End-to-end test on devbox and nas.
3. SwiftUI window: destinations, folder options, counts, sensitive warning.
4. Path field with Tab completion over ControlMaster.
5. Quick Action generation (`ccsend install`), both menu modes.
6. Logging on both ends.

### Test plan
- Discovery: plain shell, shell in tmux, Claude in tmux, Claude direct, no
  sessions, unreachable host.
- Upload: name clashes, spaces and unicode in names, nested folders, empty
  folder, symlink to outside the folder (must arrive as a link), hidden and
  excluded filtering, limits.
- Hostile host output: crafted cwd/session names with quotes, `$()`,
  newlines, ANSI escapes, very long strings → shown inert or rejected.
- Hostile written-name report → nothing copied to the clipboard.
- Destination outside `allowed_roots` → refused on the host.
- Config: unknown key, bad host alias (`-oProxyCommand=…`), disallowed
  `ssh_options`, wrong file mode → refused with a clear message.

## 9. Later
- macOS hosts: discovery via `ps`/`lsof` instead of `/proc`.
- Optional pinned copy of `remote.py` on hosts with a checksum check, if
  sending it per call ever becomes a problem.
