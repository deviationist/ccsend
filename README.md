# ccsend

Send files and folders from macOS Finder into an SSH host: into the working
directory of a running Claude Code session, the current directory of an open
SSH shell, a default location, or a path you type with Tab completion. The
remote path is copied to the clipboard, shell-escaped, ready to paste.

Push only, over plain SSH. Nothing is installed or configured on the host,
nothing listens on the Mac, and the host holds no credential.

## How it works

1. Select files or folders in Finder → right-click → Quick Actions → **Send to &lt;host&gt;**.
2. A window lists the host's Claude Code sessions and SSH shells (refreshed
   every 15 s), plus the default location and a path field.
3. Pick one and press Send. The files are streamed over SSH. Names that already
   exist get `-1`, `-2`, and so on, so nothing is ever overwritten.
4. The absolute remote path, for example `/home/alice/myapp/Screenshot\ 2026-01-01\ at\ 12.00.00.png`,
   is on the clipboard.

The host side is `server/remote.py`. The app embeds it and runs it with the
host's own `python3` for the length of one SSH command.

## Requirements

- macOS 15+ with the Xcode command line tools (Swift 6).
- Hosts: Linux with `python3` 3.8+, reachable with key or certificate auth
  through `~/.ssh/config`, and with their host keys in `known_hosts`.

## Install

```sh
make test       # server tests + client self-checks
make install    # ~/Applications/ccsend.app, ~/.local/bin/ccsend, Finder Quick Actions
ccsend init --host devbox --host nas   # writes ~/.config/ccsend/config.toml
ccsend check                           # validates the config and tests every host
ccsend install                         # re-create the Quick Actions after config changes
```

`make install BUNDLE_ID=com.example.ccsend` sets the app's bundle id (macOS ties
the Desktop/Downloads permission to it).

## Configuration

Everything specific to your setup lives in `~/.config/ccsend/config.toml`
(mode 0600, outside this repository). Unknown keys are errors.

```toml
[ui]
menu = "per-host"            # one Quick Action per host, or "single" for one "Send to remote"
preselect = "newest-claude"  # "newest-claude" | "default-location" | "none"
refresh_seconds = 15         # 0 = off

[folders]
include_hidden = false       # default of the "Include hidden files" checkbox
apply_excludes = true        # default of the "Exclude common files" checkbox
excludes = ["node_modules", ".venv", "dist", "build", ".DS_Store"]

[logging]
log_names = true             # file names in the logs (never contents)

[hosts.devbox]
ssh = "devbox"               # ~/.ssh/config alias: keys, certificates, ProxyJump come from there
user = "alice"               # optional, ssh -l
ssh_options = ["IdentityFile=~/.ssh/ccsend_ed25519", "IdentitiesOnly=yes"]   # optional, allowlisted keys only
claude_sessions = true
ssh_sessions = true
default_location = "~/inbox"
custom_path = true
allowed_roots = ["~"]        # uploads must resolve inside these, checked on the host
```

## Command line

```sh
ccsend send devbox claude ~/Desktop/shot.png    # newest Claude session; also: shell | default | /path | ~/path
ccsend sessions devbox
ccsend log                                       # Mac log
ccsend log --host devbox                         # the host's journal (journalctl -t ccsend)
```

## Security

In short:
- **SSH is locked down.** It runs with `BatchMode`, strict host-key checking, and no forwarding. Those options come first on the command line, so neither the config nor `~/.ssh/config` can weaken them.
- **No shell anywhere for your data.** On the Mac, ssh and tar are started directly. On the host the command line is fixed, and all variable input arrives base64-encoded.
- **Everything the host says is untrusted.** Its replies are checked, size-capped and cleaned before display, and a host can never choose which host is contacted.
- **Writes are confined:** only inside `allowed_roots`, never overwriting, and partial uploads are rolled back.
- **Folders don't leak:** symlinks inside a folder are sent as links, never followed. Hidden files and common junk are filtered on the Mac, and a warning lists sensitive-looking files.
- **Logged on both ends,** with shared request ids. The Mac log is the authoritative record.

The threat model and the full set of guarantees are in [DESIGN.md](DESIGN.md).

## License

MIT
