"""ccsend remote side: runs on the SSH host for the length of one SSH command.

Never installed. The Mac client embeds this file and runs it as

    ssh <host> python3 -c '<BOOTSTRAP>' <base64 of this file> <base64 JSON request>

so the remote command line is fixed and all variable input arrives encoded.
BOOTSTRAP pops the script from argv and execs it; argv[1] is then the request.
Output is one JSON object on stdout: {"ok": true, ...} or {"ok": false, "error": "..."}.

Every request may carry "id" (request id), "win" (client window/run id) and
"log_names" (bool). Each request is logged to the journal with tag ccsend
(journalctl -t ccsend): id, command, SSH client address, result, and for
uploads the directory, counts, bytes and, if log_names, the names written.
The client keeps the authoritative log; this one is for cross-checking.

Requests
    {"cmd": "discover"}
        Claude Code sessions and interactive SSH shells with their working dirs.
    {"cmd": "resolve", "path": P, "roots": [R...]}
        Resolve a destination (~ expanded, realpath) and check it is inside a root.
    {"cmd": "list", "dir": D, "prefix": X, "roots": [R...]}
        Directory entries of D starting with X, for Tab completion.
    {"cmd": "inject", "pane": "%N", "pid": P, "text": T, "submit": bool}
        Paste T into tmux pane %N as a bracketed paste (and press Enter if
        submit). Only if process P is named claude, runs inside that pane, and
        T has no control characters. Opt-in on the client; never into a shell.
    {"cmd": "foreground", "pid": P, "ssh_port": N}
        Confirm process P is still your claude, in the foreground of the SSH
        terminal whose client port is N. The client asks right before typing
        into that terminal from the Mac (the iTerm adapter).
    {"cmd": "browse", "dir": D, "roots": [R...], "hidden": bool}
        Entries of D (name, kind file|dir|link|other, size, mtime) for the
        import window. D must resolve inside a root.
    {"cmd": "download", "dir": D, "names": [N...], "roots": [R...],
     "symlinks": bool, "hidden": bool, "excludes": [G...], "dry_run": bool,
     "max_bytes": B, "max_files": F}
        The named entries of D, folders walked without following links.
        dry_run: only count. Otherwise a pax tar stream goes to stdout and the
        JSON result to stderr as one line "CCSEND-RESULT {...}". Inside
        folders, hidden entries are skipped unless hidden, and names matching
        an excludes glob are skipped; the named entries themselves always go.
        Links are skipped unless symlinks; other special files always are.
        Owner names and ids are not sent.
    {"cmd": "upload", "dir": D, "roots": [R...], "create": bool, "tops": [N...]}
        Read a tar stream on stdin and write it into D. Only the top-level names
        in "tops" are accepted; each is written as N, or N-1, N-2 ... if taken.
        Nothing existing is ever overwritten.

discover is Linux only (/proc). Python 3.8+.
"""
import base64
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import time

try:
    import syslog
except ImportError:  # not on every platform; logging is best effort
    syslog = None

HOME = os.path.realpath(os.path.expanduser("~"))
STATS = {"files": 0, "bytes": 0}
MAX_LIST = 200


class Refused(Exception):
    pass


# ---------------------------------------------------------------- paths


def expand(p):
    if not isinstance(p, str) or not p or "\0" in p:
        raise Refused("invalid path")
    if p == "~" or p.startswith("~/"):
        p = HOME + p[1:]
    if not os.path.isabs(p):
        raise Refused("path must be absolute or start with ~/: %r" % p)
    return p


def roots_of(req):
    roots = req.get("roots")
    if not isinstance(roots, list) or not roots:
        raise Refused("no allowed roots")
    return [os.path.realpath(expand(r)) for r in roots]


def inside(path, roots):
    return any(path == r or path.startswith(r.rstrip("/") + "/") for r in roots)


def confined(p, roots):
    """realpath of p, which must lie inside one of roots."""
    rp = os.path.realpath(expand(p))
    if not inside(rp, roots):
        raise Refused("%s is outside the allowed roots" % rp)
    return rp


# ---------------------------------------------------------------- discover


def proc_read(pid, name, mode="r"):
    with open("/proc/%s/%s" % (pid, name), mode) as f:
        return f.read()


def stat_fields(pid):
    # Fields after "(comm)": state ppid pgrp session tty_nr tpgid ..., starttime at index 19.
    return proc_read(pid, "stat").rsplit(")", 1)[1].split()


def environ(pid):
    raw = proc_read(pid, "environ", "rb")
    return dict(kv.split(b"=", 1) for kv in raw.split(b"\0") if b"=" in kv)


def own_pids():
    uid = os.getuid()
    for pid in os.listdir("/proc"):
        if pid.isdigit():
            try:
                if os.stat("/proc/" + pid).st_uid == uid:
                    yield pid
            except OSError:
                pass


def boot_time():
    with open("/proc/uptime") as f:
        return time.time() - float(f.read().split()[0])


PANE_RE = re.compile(r"^%[0-9]{1,6}$")


def tmux_pane(env):
    pane = env.get(b"TMUX_PANE", b"").decode("utf-8", "replace")
    return pane if PANE_RE.match(pane) else ""


def tmux_session(env):
    pane = tmux_pane(env)
    if not pane:
        return ""
    try:
        out = subprocess.run(["tmux", "display-message", "-p", "-t", pane, "#S"],
                             capture_output=True, text=True, timeout=3)
        return out.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def ssh_client_port(pid, f):
    """Client port of the SSH connection whose terminal pid is in the foreground of.

    Taken from the session leader of pid's terminal (the login shell sshd
    started), not from pid's own environment, which any process can set.
    0 when pid is not the foreground process group of an SSH login terminal.
    """
    tty, pgrp, sid, tpgid = f[4], f[2], f[3], f[5]
    if tty == "0" or pgrp != tpgid:
        return 0
    try:
        lf = stat_fields(sid)
        if lf[4] != tty or lf[3] != sid:
            return 0
        conn = environ(sid).get(b"SSH_CONNECTION", b"").split()
        port = int(conn[1]) if len(conn) == 4 else 0
        return port if 0 < port < 65536 else 0
    except (OSError, ValueError, IndexError):
        return 0


def discover(req):
    if not os.path.isdir("/proc/self"):
        raise Refused("session discovery needs Linux /proc")
    boot, hz = boot_time(), os.sysconf("SC_CLK_TCK")
    sessions, claude_ttys = [], set()
    pids = list(own_pids())
    for pid in pids:
        try:
            if proc_read(pid, "comm").strip() != "claude":
                continue
            f = stat_fields(pid)
            env = environ(pid)
            pane = tmux_pane(env)
            sessions.append({"kind": "claude", "cwd": os.readlink("/proc/%s/cwd" % pid),
                             "tmux": tmux_session(env), "pane": pane, "pid": int(pid),
                             "ssh_port": 0 if pane else ssh_client_port(pid, f),
                             "started": int(boot + int(f[19]) / hz)})
            claude_ttys.add(f[4])
        except (OSError, IndexError, ValueError):
            continue
    for pid in pids:
        try:
            f = stat_fields(pid)
            # Interactive SSH login shell: session leader with a terminal and SSH_CONNECTION.
            if f[3] != pid or f[4] == "0" or not environ(pid).get(b"SSH_CONNECTION"):
                continue
            if f[4] in claude_ttys:
                continue
            fg = f[5] if os.path.exists("/proc/" + f[5]) else pid
            if proc_read(fg, "comm").strip().startswith("tmux"):
                continue  # Claude inside tmux is listed from its own process
            sessions.append({"kind": "shell", "cwd": os.readlink("/proc/%s/cwd" % fg),
                             "tmux": "", "pane": "", "pid": int(pid), "ssh_port": 0,
                             "started": int(boot + int(f[19]) / hz)})
        except (OSError, IndexError, ValueError):
            continue
    sessions.sort(key=lambda s: -s["started"])
    return {"home": HOME, "sessions": sessions}


# ---------------------------------------------------------------- resolve / list


def resolve(req):
    rp = confined(req.get("path"), roots_of(req))
    return {"path": rp, "exists": os.path.isdir(rp)}


def list_dir(req):
    d = confined(req.get("dir"), roots_of(req))
    prefix = req.get("prefix", "")
    if not isinstance(prefix, str) or "/" in prefix or "\0" in prefix:
        raise Refused("invalid prefix")
    try:
        names = sorted(os.listdir(d))
    except OSError as e:
        raise Refused("cannot list %s: %s" % (d, e.strerror))
    entries = []
    for name in names:
        if not name.startswith(prefix) or (name.startswith(".") and not prefix.startswith(".")):
            continue
        entries.append({"name": name, "dir": os.path.isdir(os.path.join(d, name))})
        if len(entries) >= MAX_LIST:
            break
    return {"dir": d, "entries": entries, "truncated": len(entries) >= MAX_LIST}


# ---------------------------------------------------------------- browse / download

MAX_BROWSE = 5000


def kind_of(st_mode):
    import stat as st
    if st.S_ISLNK(st_mode):
        return "link"
    if st.S_ISDIR(st_mode):
        return "dir"
    if st.S_ISREG(st_mode):
        return "file"
    return "other"


def browse(req):
    d = confined(req.get("dir"), roots_of(req))
    hidden = req.get("hidden") is True
    try:
        names = sorted(os.listdir(d), key=lambda n: n.lower())
    except OSError as e:
        raise Refused("cannot list %s: %s" % (d, e.strerror))
    entries = []
    for name in names:
        if name.startswith(".") and not hidden:
            continue
        try:
            st = os.lstat(os.path.join(d, name))
        except OSError:
            continue
        k = kind_of(st.st_mode)
        entries.append({"name": name, "kind": k, "size": st.st_size if k == "file" else 0, "mtime": int(st.st_mtime)})
        if len(entries) >= MAX_BROWSE:
            break
    parent = os.path.dirname(d)
    roots = roots_of(req)
    return {"dir": d, "entries": entries, "truncated": len(entries) >= MAX_BROWSE,
            "parent": parent if parent != d and inside(parent, roots) else ""}


def walk_selection(d, names, symlinks, hidden=True, excludes=()):
    """(path, arcname, kind) for the selection; folders walked without following links."""
    import fnmatch
    skipped = {"links": 0, "special": 0, "hidden": 0, "excluded": 0}

    def visit(path, arc, top=False):
        name = os.path.basename(path)
        if not top:
            if not hidden and name.startswith("."):
                skipped["hidden"] += 1
                return
            if any(fnmatch.fnmatchcase(name, g) for g in excludes):
                skipped["excluded"] += 1
                return
        try:
            mode = os.lstat(path).st_mode
        except OSError:
            return
        k = kind_of(mode)
        if k == "link":
            if symlinks:
                yield path, arc, "link"
            else:
                skipped["links"] += 1
            return
        if k == "other":
            skipped["special"] += 1
            return
        yield path, arc, k
        if k == "dir":
            try:
                children = sorted(os.listdir(path))
            except OSError:
                return
            for c in children:
                for x in visit(os.path.join(path, c), arc + "/" + c):
                    yield x

    entries = []
    for n in names:
        entries.extend(visit(os.path.join(d, n), n, top=True))
    return entries, skipped


def download(req):
    roots = roots_of(req)
    d = confined(req.get("dir"), roots)
    names = req.get("names")
    if not isinstance(names, list) or not names or not all(valid_name(n) for n in names) or len(set(names)) != len(names):
        raise Refused("invalid names")
    for n in names:
        if not os.path.lexists(os.path.join(d, n)):
            raise Refused("%s does not exist in %s" % (n, d))
    excludes = req.get("excludes") or []
    if not isinstance(excludes, list) or not all(isinstance(g, str) and len(g) < 200 for g in excludes):
        raise Refused("invalid excludes")
    entries, skipped = walk_selection(d, names, req.get("symlinks") is True, req.get("hidden") is True, excludes[:200])
    files = sum(1 for e in entries if e[2] != "dir")
    total = 0
    for path, _, k in entries:
        if k == "file":
            try:
                total += os.lstat(path).st_size
            except OSError:
                pass
    result = {"dir": d, "files": files, "bytes": total, "skipped_links": skipped["links"],
              "skipped_special": skipped["special"], "skipped_hidden": skipped["hidden"],
              "skipped_excluded": skipped["excluded"], "tops": [n for n in names]}
    if req.get("dry_run") is True:
        return result
    max_bytes, max_files = req.get("max_bytes"), req.get("max_files")
    if isinstance(max_bytes, int) and total > max_bytes or isinstance(max_files, int) and files > max_files:
        raise Refused("selection is over the limits (%d files, %d bytes)" % (files, total))

    def strip(ti):
        ti.uid = ti.gid = 0
        ti.uname = ti.gname = ""
        ti.mode &= 0o777   # no setuid/setgid/sticky
        return ti

    sent_files, sent_bytes = 0, 0
    with tarfile.open(fileobj=sys.stdout.buffer, mode="w|", format=tarfile.PAX_FORMAT) as tar:
        for path, arc, k in entries:
            try:
                ti = strip(tar.gettarinfo(path, arcname=arc))
            except OSError:
                continue   # vanished since the walk
            if k == "file" and ti.isreg():
                with open(path, "rb") as f:
                    tar.addfile(ti, f)
                sent_files += 1
                sent_bytes += ti.size
            elif k == "dir" and ti.isdir():
                tar.addfile(ti)
            elif k == "link" and ti.issym():
                tar.addfile(ti)
                sent_files += 1
    sys.stdout.buffer.flush()
    result.update(files=sent_files, bytes=sent_bytes, streamed=True)
    return result


# ---------------------------------------------------------------- inject


def tmux(*args, stdin=None):
    try:
        r = subprocess.run(["tmux"] + list(args), input=stdin, capture_output=True, timeout=5)
    except (OSError, subprocess.SubprocessError) as e:
        raise Refused("tmux failed: %s" % e)
    if r.returncode != 0:
        raise Refused("tmux %s failed: %s" % (args[0], r.stderr.decode("utf-8", "replace").strip()[:200]))
    return r.stdout.decode("utf-8", "replace").strip()


def inject(req):
    pane, pid, text = req.get("pane"), req.get("pid"), req.get("text")
    if not isinstance(pane, str) or not PANE_RE.match(pane):
        raise Refused("invalid pane")
    if not isinstance(pid, int) or pid <= 1:
        raise Refused("invalid pid")
    if not isinstance(text, str) or not text or len(text) > 8192 or any(ord(c) < 0x20 or ord(c) == 0x7F for c in text):
        raise Refused("invalid text")
    p = str(pid)
    try:
        if os.stat("/proc/" + p).st_uid != os.getuid() or proc_read(p, "comm").strip() != "claude":
            raise Refused("process %s is not your claude session" % p)
        if tmux_pane(environ(p)) != pane:
            raise Refused("claude process %s is not in pane %s" % (p, pane))
    except OSError:
        raise Refused("claude process %s is gone" % p)
    # The pane's own process must be an ancestor of the claude process.
    pane_pid = tmux("display-message", "-p", "-t", pane, "#{pane_pid}")
    q = p
    while q not in ("0", "1", pane_pid):
        q = stat_fields(q)[1]
    if q != pane_pid:
        raise Refused("claude process %s does not run in pane %s" % (p, pane))
    buf = "ccsend-%d" % os.getpid()
    tmux("load-buffer", "-b", buf, "-", stdin=text.encode("utf-8"))
    tmux("paste-buffer", "-p", "-d", "-b", buf, "-t", pane)
    if req.get("submit") is True:
        tmux("send-keys", "-t", pane, "Enter")
    return {"pane": pane, "submitted": req.get("submit") is True}


def foreground(req):
    pid, port = req.get("pid"), req.get("ssh_port")
    if not isinstance(pid, int) or pid <= 1 or not isinstance(port, int) or not 0 < port < 65536:
        raise Refused("invalid request")
    p = str(pid)
    try:
        if os.stat("/proc/" + p).st_uid != os.getuid() or proc_read(p, "comm").strip() != "claude":
            raise Refused("process %s is not your claude session" % p)
        if ssh_client_port(p, stat_fields(p)) != port:
            raise Refused("claude is no longer in the foreground of that SSH session")
    except OSError:
        raise Refused("claude process %s is gone" % p)
    return {"pid": pid, "foreground": True}


# ---------------------------------------------------------------- upload


def valid_name(n):
    return isinstance(n, str) and n not in ("", ".", "..") and "/" not in n and "\0" not in n


def claim(dirpath, name, is_dir):
    """Create name, or name-1, name-2 ..., in dirpath without overwriting; return the name used."""
    base, ext = (name, "") if is_dir else os.path.splitext(name)
    for n in range(10000):
        cand = name if n == 0 else "%s-%d%s" % (base, n, ext)
        path = os.path.join(dirpath, cand)
        try:
            if is_dir:
                os.mkdir(path, 0o755)
            else:
                os.close(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644))
            return cand
        except FileExistsError:
            continue
    raise Refused("no free name for %s" % name)


def member_parts(name):
    if name.startswith("/"):
        raise Refused("absolute path in stream: %r" % name)
    parts = [p for p in name.split("/") if p not in ("", ".")]
    if not parts or ".." in parts:
        raise Refused("unsafe path in stream: %r" % name)
    return parts


def check_parent(path, top_dir):
    """The parent of path must resolve inside top_dir: no escaping through symlinked dirs."""
    parent = os.path.realpath(os.path.dirname(path))
    if parent != top_dir and not parent.startswith(top_dir + "/"):
        raise Refused("path escapes its folder: %s" % path)


def write_member(tar, m, path, flags):
    STATS["files"] += 1
    STATS["bytes"] += m.size
    src = tar.extractfile(m)
    fd = os.open(path, flags | os.O_WRONLY | os.O_NOFOLLOW, 0o644 | (m.mode & 0o111))
    with os.fdopen(fd, "wb") as out:
        while True:
            chunk = src.read(1 << 20)
            if not chunk:
                break
            out.write(chunk)


def upload(req):
    roots = roots_of(req)
    target = os.path.realpath(expand(req.get("dir")))
    if not inside(target, roots):
        raise Refused("%s is outside the allowed roots" % target)
    if not os.path.isdir(target):
        if not req.get("create"):
            raise Refused("%s does not exist" % target)
        os.makedirs(target, 0o755, exist_ok=True)
        target = os.path.realpath(target)
        if not inside(target, roots):
            raise Refused("%s is outside the allowed roots" % target)
    tops = req.get("tops")
    if not isinstance(tops, list) or not tops or not all(valid_name(t) for t in tops):
        raise Refused("invalid top-level names")
    written, order = {}, []   # sent top-level name -> name written
    try:
        receive(target, tops, written, order)
    except BaseException:
        # Leave nothing half-written: remove what this call created.
        for t in order:
            p = os.path.join(target, written[t])
            if os.path.isdir(p) and not os.path.islink(p):
                shutil.rmtree(p, ignore_errors=True)
            elif os.path.lexists(p):
                os.unlink(p)
        raise
    return {"dir": target, "written": [{"sent": t, "name": written[t]} for t in order],
            "files": STATS["files"], "bytes": STATS["bytes"]}


def receive(target, tops, written, order):
    with tarfile.open(fileobj=sys.stdin.buffer, mode="r|") as tar:
        for m in tar:
            parts = member_parts(m.name)
            top = parts[0]
            if top not in tops:
                raise Refused("unexpected item in stream: %r" % top)
            if not (m.isfile() or m.isdir() or m.issym()):
                raise Refused("unsupported entry type in stream: %r" % m.name)
            if top not in written:
                written[top] = claim(target, top, m.isdir() or len(parts) > 1)
                order.append(top)
            top_dir = os.path.realpath(os.path.join(target, written[top]))
            path = os.path.join(top_dir, *parts[1:])
            if len(parts) == 1:
                # The top-level entry itself; claim() created it.
                if m.issym():
                    os.unlink(path)
                    os.symlink(m.linkname, path)
                    STATS["files"] += 1
                elif m.isfile():
                    write_member(tar, m, path, os.O_TRUNC)
                continue
            check_parent(path, top_dir)
            if m.isdir():
                os.makedirs(path, 0o755, exist_ok=True)
            elif m.issym():
                os.symlink(m.linkname, path)
                STATS["files"] += 1
            else:
                write_member(tar, m, path, os.O_CREAT | os.O_EXCL)
    missing = [t for t in tops if t not in written]
    if missing:
        raise Refused("stream ended without: %s" % ", ".join(missing))


# ---------------------------------------------------------------- main

COMMANDS = {"discover": discover, "resolve": resolve, "list": list_dir, "upload": upload, "inject": inject,
            "foreground": foreground, "browse": browse, "download": download}


ID_RE = re.compile(r"^[A-Za-z0-9-]{1,64}$")


def field(v):
    """key=value value: bare if simple, else JSON-quoted (escapes control characters)."""
    if isinstance(v, list):
        return json.dumps(v, ensure_ascii=False)
    v = str(v)
    return v if re.match(r"^[A-Za-z0-9._/:@%+-]+$", v) else json.dumps(v, ensure_ascii=False)


def log(req, out):
    if syslog is None:
        return
    rid = req.get("id") if isinstance(req, dict) else None
    win = req.get("win") if isinstance(req, dict) else None
    parts = [
        ("id", rid if isinstance(rid, str) and ID_RE.match(rid) else "-"),
        ("win", win if isinstance(win, str) and ID_RE.match(win) else "-"),
        ("event", req.get("cmd", "?") if isinstance(req, dict) and req.get("cmd") in COMMANDS else "invalid"),
        ("client", (os.environ.get("SSH_CONNECTION", "-").split() or ["-"])[0]),
        ("result", "ok" if out.get("ok") else "refused"),
    ]
    if out.get("ok"):
        if "sessions" in out:
            parts.append(("sessions", len(out["sessions"])))
        if "entries" in out:
            parts += [("dir", out["dir"]), ("entries", len(out["entries"]))]
        if "written" in out:
            parts += [("dir", out["dir"]), ("items", len(out["written"])), ("files", out["files"]), ("bytes", out["bytes"])]
            if req.get("log_names", True) is not False:
                parts.append(("names", [w["name"] for w in out["written"]]))
        if "path" in out:
            parts.append(("path", out["path"]))
        if "tops" in out and "skipped_links" in out:
            parts += [("dir", out["dir"]), ("items", len(out["tops"])), ("files", out["files"]), ("bytes", out["bytes"]),
                      ("dry_run", not out.get("streamed", False)), ("skipped_links", out["skipped_links"])]
            if req.get("log_names", True) is not False:
                parts.append(("names", out["tops"]))
        if "pane" in out:
            parts += [("pane", out["pane"]), ("submitted", out["submitted"])]
    else:
        parts.append(("error", out.get("error", "")[:300]))
    try:
        syslog.openlog("ccsend", 0, syslog.LOG_USER)
        syslog.syslog(syslog.LOG_INFO if out.get("ok") else syslog.LOG_WARNING,
                      " ".join("%s=%s" % (k, field(v)) for k, v in parts))
    except Exception:
        pass


def main():
    req = {}
    try:
        req = json.loads(base64.b64decode(sys.argv[1]).decode("utf-8"))
        if not isinstance(req, dict) or req.get("cmd") not in COMMANDS:
            raise Refused("unknown request")
        out = COMMANDS[req["cmd"]](req)
        out["ok"] = True
    except Refused as e:
        out = {"ok": False, "error": str(e)}
    except Exception as e:
        out = {"ok": False, "error": "%s: %s" % (type(e).__name__, e)}
    log(req if isinstance(req, dict) else {}, out)
    if isinstance(req, dict) and req.get("cmd") == "download" and req.get("dry_run") is not True:
        # stdout carries the tar stream; the result goes to stderr.
        sys.stderr.write("CCSEND-RESULT " + json.dumps(out) + "\n")
    else:
        sys.stdout.write(json.dumps(out) + "\n")
    sys.exit(0 if out["ok"] else 1)


main()
