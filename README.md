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
4. Optional, per send: **Move the originals to the Trash after sending**. It is
   unticked every time, runs only after the host confirms everything arrived,
   and is unavailable when folder filters skip files (they would be lost). The
   Trash's Put Back restores them.
5. The absolute remote path, for example `/home/alice/myapp/Screenshot\ 2026-01-01\ at\ 12.00.00.png`,
   is on the clipboard.

**Import (opt-in, `import = true` per host)** works the other way round:
right-click the Desktop or empty space in a folder → **Import from &lt;host&gt;**
(from ccsend's Finder extension), or right-click a folder → Quick Actions →
**Import from &lt;host&gt;**. Browse the host,
tick files and folders, and press Import. The Mac fetches them over SSH and
shows them in Finder.

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

[limits]
max_total_mb = 2048          # ask before sending more
max_files = 20000

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
inject = "off"               # opt-in, see below: "type" | "submit"
inject_via = ["tmux"]        # adapters, tried in order: "tmux", "iterm"
import = false               # opt-in: "Import from <host>"
import_roots = ["~"]         # what the Mac may browse and fetch on this host
import_symlinks = false      # symbolic links inside imported folders: skipped, or kept as links
import_start = "home"        # where the import window opens: home | newest-claude | default | last | ~/path
```

### Typing the path into Claude (opt-in)

With `inject = "type"` on a host, sending to a Claude Code session also types
the remote path into that session's prompt, so you only add your message.
`inject = "submit"` also presses Enter. The window has a checkbox to skip it
for one send; the CLI has `--no-inject`.

`inject_via` lists the adapters to try, in order (default `["tmux"]`):

- `tmux`: for Claude running inside tmux. The host pastes into the session's
  pane after checking that the pane really runs that `claude` process.
- `iterm`: for Claude running directly in an SSH session in an iTerm2 tab.
  The host reports which SSH connection Claude is in the foreground of. The
  Mac finds that connection's tab (only if it goes to this host's address and
  ssh is the tab's foreground job). The host then re-confirms Claude is still
  in the foreground, and the Mac types the path with iTerm2's scripting.
  macOS asks once whether ccsend may control iTerm2.

Neither adapter ever types into a shell. If no adapter fits, the path is only
copied to the clipboard, as always.

Target one session exactly from the CLI with `claude:DIR`:
`ccsend send devbox claude:~/myapp shot.png`.

## Command line

```sh
ccsend send devbox claude ~/Desktop/shot.png    # newest Claude session; also: claude:DIR | shell | shell:DIR | default | /path
ccsend send --hidden --all devbox default ~/proj   # include hidden files, skip the exclude list (--yes: over limits, --no-inject)
ccsend send --trash devbox claude ~/Downloads/IMG_0042.PNG   # then move the original to the Trash
ccsend import devbox --to ~/Downloads ~/myapp/report ~/myapp/notes.md   # same parent folder; --hidden --all --links --yes
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
- **Imports are treated as untrusted:**
  - The Mac unpacks the archive itself, accepting only files and folders (links only if allowed).
  - No absolute paths and no `..`; nothing is ever written through a link.
  - Nothing is overwritten.
  - Size and file-count limits apply, and free space is checked first.
  - setuid is dropped, and every file gets the quarantine flag, so Gatekeeper asks before an imported app or script runs.
- **Logged on both ends,** with shared request ids. The Mac log is the authoritative record.

The threat model and the full set of guarantees are in [DESIGN.md](DESIGN.md).

## Permissions

macOS asks once for each of these:
- Access to Desktop, Downloads or Documents, the first time you send from there.
- "ccsend wants to control iTerm2", only if a host uses `inject_via = ["iterm"]`.
- The Finder extension (the right-click menu on the Desktop and in folders) may need switching on once:
  System Settings → General → Login Items & Extensions → Finder → ccsend.

## Uninstall

```sh
ccsend uninstall               # removes only the Quick Actions ccsend created
rm -rf ~/Applications/ccsend.app ~/.local/bin/ccsend ~/Library/Caches/ccsend ~/Library/Logs/ccsend.log*
rm -rf ~/.config/ccsend        # your config
```
Nothing was installed on the hosts. Their journal entries (tag `ccsend`) age out with the journal.

## License

MIT
