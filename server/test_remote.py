"""Tests for remote.py, run the way the client runs it (bootstrap + base64 args).

    python3 server/test_remote.py          # on the Mac: everything but discover
    python3 test_remote.py                 # on a Linux host: discover too

Each test gets its own fake HOME, so nothing outside a temp dir is touched.
"""
import base64
import io
import json
import os
import subprocess
import sys
import tarfile
import shutil
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))


def read(path):
    with open(path, "rb") as f:
        return f.read()


SCRIPT = read(os.path.join(HERE, "remote.py"))
# Must stay identical to the client's bootstrap (client/Sources/ccsend/Remote.swift).
BOOTSTRAP = "import base64,sys;exec(compile(base64.b64decode(sys.argv.pop(1)),'remote.py','exec'))"


def b64(b):
    return base64.b64encode(b).decode()


def tar_bytes(entries):
    """entries: (name, kind, payload) with kind file|dir|sym|hard|fifo."""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
        for name, kind, payload in entries:
            ti = tarfile.TarInfo(name)
            if kind == "file":
                ti.size = len(payload)
                t.addfile(ti, io.BytesIO(payload))
                continue
            ti.type = {"dir": tarfile.DIRTYPE, "sym": tarfile.SYMTYPE,
                       "hard": tarfile.LNKTYPE, "fifo": tarfile.FIFOTYPE}[kind]
            if kind == "dir":
                ti.mode = 0o755
            if kind in ("sym", "hard"):
                ti.linkname = payload
            t.addfile(ti)
    return buf.getvalue()


class Remote(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        # Cleanups run last-in first-out, so anything a test registers later
        # (like killing its tmux server) runs before the directory is removed.
        self.addCleanup(self.tmp.cleanup)
        self.home = os.path.realpath(self.tmp.name)
        os.mkdir(os.path.join(self.home, "dest"))

    def run_remote(self, req, stdin=b""):
        env = dict(os.environ, HOME=self.home)
        req = dict(req, id="selftest") if isinstance(req, dict) and req else req
        p = subprocess.run([sys.executable, "-c", BOOTSTRAP, b64(SCRIPT), b64(json.dumps(req).encode())],
                           input=stdin, capture_output=True, env=env, timeout=30)
        out = json.loads(p.stdout.decode())
        self.assertEqual(p.returncode == 0, out["ok"], p.stderr.decode())
        return out

    def upload(self, entries, tops, dest="~/dest", roots=("~",), create=False):
        return self.run_remote({"cmd": "upload", "dir": dest, "roots": list(roots), "create": create,
                                "tops": tops}, tar_bytes(entries))

    def p(self, *parts):
        return os.path.join(self.home, *parts)

    # ------------------------------------------------------------ requests

    def test_bad_requests(self):
        for req in ({}, {"cmd": "rm"}, {"cmd": "upload"}, {"cmd": "list", "dir": "~", "roots": []}):
            self.assertFalse(self.run_remote(req)["ok"], req)

    def test_resolve(self):
        out = self.run_remote({"cmd": "resolve", "path": "~/dest", "roots": ["~"]})
        self.assertEqual(out["path"], self.p("dest"))
        self.assertTrue(out["exists"])
        for bad in ("/etc", "~/../..", "relative/path", "~/dest/../../x"):
            self.assertFalse(self.run_remote({"cmd": "resolve", "path": bad, "roots": ["~"]})["ok"], bad)

    def test_resolve_symlink_out_of_root(self):
        os.symlink("/etc", self.p("dest", "etc"))
        self.assertFalse(self.run_remote({"cmd": "resolve", "path": "~/dest/etc", "roots": ["~"]})["ok"])

    def test_narrow_root(self):
        os.mkdir(self.p("other"))
        out = self.run_remote({"cmd": "resolve", "path": "~/other", "roots": ["~/dest"]})
        self.assertFalse(out["ok"])
        # A sibling sharing the prefix must not count as inside.
        os.mkdir(self.p("dest2"))
        self.assertFalse(self.run_remote({"cmd": "resolve", "path": "~/dest2", "roots": ["~/dest"]})["ok"])

    # ------------------------------------------------------------ list

    def test_list(self):
        for n in ("web", "workers", ".hidden", "readme.md"):
            (os.mkdir if "." not in n[1:] else lambda p: open(p, "w").close())(self.p("dest", n))
        out = self.run_remote({"cmd": "list", "dir": "~/dest", "prefix": "w", "roots": ["~"]})
        self.assertEqual([e["name"] for e in out["entries"]], ["web", "workers"])
        self.assertTrue(all(e["dir"] for e in out["entries"]))
        out = self.run_remote({"cmd": "list", "dir": "~/dest", "prefix": "", "roots": ["~"]})
        self.assertNotIn(".hidden", [e["name"] for e in out["entries"]])
        out = self.run_remote({"cmd": "list", "dir": "~/dest", "prefix": ".", "roots": ["~"]})
        self.assertEqual([e["name"] for e in out["entries"]], [".hidden"])
        self.assertFalse(self.run_remote({"cmd": "list", "dir": "/etc", "prefix": "", "roots": ["~"]})["ok"])
        self.assertFalse(self.run_remote({"cmd": "list", "dir": "~", "prefix": "../", "roots": ["~"]})["ok"])

    # ------------------------------------------------------------ upload

    def test_upload_file_and_collisions(self):
        out = self.upload([("shot 1.png", "file", b"png")], ["shot 1.png"])
        self.assertEqual(out["written"], [{"sent": "shot 1.png", "name": "shot 1.png"}])
        out = self.upload([("shot 1.png", "file", b"two")], ["shot 1.png"])
        self.assertEqual(out["written"][0]["name"], "shot 1-1.png")
        self.assertEqual(read(self.p("dest", "shot 1.png")), b"png")
        self.assertEqual(read(self.p("dest", "shot 1-1.png")), b"two")

    def test_upload_folder(self):
        entries = [("web", "dir", None), ("web/src", "dir", None), ("web/src/a.ts", "file", b"a"),
                   ("web/link", "sym", "../../outside"), ("web/empty", "dir", None)]
        out = self.upload(entries, ["web"])
        self.assertEqual(out["written"][0]["name"], "web")
        self.assertEqual(read(self.p("dest", "web", "src", "a.ts")), b"a")
        self.assertEqual(os.readlink(self.p("dest", "web", "link")), "../../outside")
        self.assertTrue(os.path.isdir(self.p("dest", "web", "empty")))
        out = self.upload(entries, ["web"])
        self.assertEqual(out["written"][0]["name"], "web-1")

    def test_upload_unicode_and_long_names(self):
        # Over the 100-byte ustar limit (needs pax), under the 255-byte name limit.
        name = "Screenshot 2026-01-01 at 12.00.00 " + "äöü" * 20 + ".png"
        out = self.upload([(name, "file", b"x")], [name])
        self.assertEqual(out["written"][0]["name"], name)
        # Too long for the filesystem: refused cleanly, nothing left behind.
        name = "x" * 300
        self.assertFalse(self.upload([(name, "file", b"x")], [name])["ok"])
        self.assertEqual(os.listdir(self.p("dest")), ["Screenshot 2026-01-01 at 12.00.00 " + "äöü" * 20 + ".png"])

    def test_upload_create_default_location(self):
        self.assertFalse(self.upload([("a", "file", b"x")], ["a"], dest="~/inbox")["ok"])
        out = self.upload([("a", "file", b"x")], ["a"], dest="~/inbox", create=True)
        self.assertEqual(out["dir"], self.p("inbox"))

    def test_upload_refusals(self):
        cases = {
            "outside root": ([("a", "file", b"x")], ["a"], "/tmp"),
            "dotdot member": ([("../a", "file", b"x")], [".."], "~/dest"),
            "absolute member": ([("/a", "file", b"x")], ["a"], "~/dest"),
            "unexpected top": ([("b", "file", b"x")], ["a"], "~/dest"),
            "hard link": ([("a", "hard", "/etc/passwd")], ["a"], "~/dest"),
            "fifo": ([("a", "fifo", None)], ["a"], "~/dest"),
            "missing top": ([("a", "file", b"x")], ["a", "b"], "~/dest"),
            "slash in top": ([("a/b", "file", b"x")], ["a/b"], "~/dest"),
        }
        for label, (entries, tops, dest) in cases.items():
            out = self.upload(entries, tops, dest=dest)
            self.assertFalse(out["ok"], label)
        self.assertEqual(os.listdir(self.p("dest")), [], "refused uploads must leave nothing behind")

    def test_upload_symlinked_dir_escape(self):
        # A symlink inside the folder, then a file "through" it: must not write outside.
        os.mkdir(self.p("victim"))
        entries = [("web", "dir", None), ("web/esc", "sym", self.p("victim")), ("web/esc/pwned", "file", b"x")]
        self.assertFalse(self.upload(entries, ["web"])["ok"])
        self.assertEqual(os.listdir(self.p("victim")), [])
        self.assertEqual(os.listdir(self.p("dest")), [])

    def test_upload_does_not_follow_existing_symlink_dest(self):
        os.symlink("/etc", self.p("dest", "etc"))
        self.assertFalse(self.upload([("a", "file", b"x")], ["a"], dest="~/dest/etc")["ok"])

    def test_upload_truncated_stream_rolls_back(self):
        data = tar_bytes([("web", "dir", None), ("web/a", "file", b"x" * 100000)])
        out = self.run_remote({"cmd": "upload", "dir": "~/dest", "roots": ["~"], "tops": ["web"]}, data[:20000])
        self.assertFalse(out["ok"])
        self.assertEqual(os.listdir(self.p("dest")), [])

    # ------------------------------------------------------------ browse / download

    def make_tree(self):
        src = self.p("dest", "proj")
        os.makedirs(os.path.join(src, "sub"))
        with open(os.path.join(src, "a.txt"), "w") as f:
            f.write("hello")
        with open(os.path.join(src, "sub", "b.bin"), "wb") as f:
            f.write(b"\0" * 1000)
        with open(os.path.join(src, ".env"), "w") as f:
            f.write("SECRET=1")
        os.symlink("/etc/passwd", os.path.join(src, "passwd-link"))
        os.mkfifo(os.path.join(src, "fifo"))
        os.makedirs(os.path.join(src, "node_modules", "x"))
        with open(os.path.join(src, "node_modules", "x", "i.js"), "w") as f:
            f.write("x")
        return src

    def run_download(self, req):
        env = dict(os.environ, HOME=self.home)
        r = dict(req, cmd="download", id="selftest")
        p = subprocess.run([sys.executable, "-c", BOOTSTRAP, b64(SCRIPT), b64(json.dumps(r).encode())],
                           capture_output=True, env=env, timeout=30)
        line = [l for l in p.stderr.decode().splitlines() if l.startswith("CCSEND-RESULT ")]
        return json.loads(line[-1][len("CCSEND-RESULT "):]) if line else None, p.stdout

    def test_browse(self):
        self.make_tree()
        out = self.run_remote({"cmd": "browse", "dir": "~/dest/proj", "roots": ["~"]})
        kinds = {e["name"]: e["kind"] for e in out["entries"]}
        self.assertEqual(kinds, {"a.txt": "file", "sub": "dir", "passwd-link": "link", "fifo": "other", "node_modules": "dir"})
        out = self.run_remote({"cmd": "browse", "dir": "~/dest/proj", "roots": ["~"], "hidden": True})
        self.assertIn(".env", [e["name"] for e in out["entries"]])
        self.assertEqual(out["parent"], self.p("dest"))
        self.assertFalse(self.run_remote({"cmd": "browse", "dir": "/etc", "roots": ["~"]})["ok"])
        self.assertEqual(self.run_remote({"cmd": "browse", "dir": "~", "roots": ["~"]})["parent"], "")

    def test_download_dry_run(self):
        self.make_tree()
        base = {"cmd": "download", "dir": "~/dest", "names": ["proj"], "roots": ["~"], "dry_run": True}
        out = self.run_remote(dict(base, excludes=["node_modules"]))
        self.assertEqual((out["files"], out["bytes"], out["skipped_links"], out["skipped_special"],
                          out["skipped_hidden"], out["skipped_excluded"]), (2, 1005, 1, 1, 1, 1))
        out = self.run_remote(dict(base, hidden=True, symlinks=True))
        self.assertEqual((out["files"], out["skipped_links"], out["skipped_hidden"]), (5, 0, 0))
        # A named entry is sent even if it is hidden or excluded.
        out = self.run_remote(dict(base, dir="~/dest/proj", names=[".env", "node_modules"], excludes=["node_modules"]))
        self.assertEqual(out["files"], 2)

    def test_download_stream(self):
        self.make_tree()
        res, data = self.run_download({"dir": "~/dest", "names": ["proj"], "roots": ["~"], "excludes": ["node_modules"]})
        self.assertTrue(res["ok"], res)
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:") as tar:
            members = {m.name: m for m in tar.getmembers()}
            self.assertEqual(set(members), {"proj", "proj/a.txt", "proj/sub", "proj/sub/b.bin"})
            self.assertEqual(tar.extractfile(members["proj/a.txt"]).read(), b"hello")
            for m in members.values():
                self.assertEqual((m.uid, m.gid, m.uname, m.gname), (0, 0, "", ""), m.name)
                self.assertEqual(m.mode & 0o7000, 0)

    def test_download_refusals(self):
        self.make_tree()
        for req in ({"dir": "/etc", "names": ["passwd"]}, {"dir": "~/dest", "names": ["../x"]},
                    {"dir": "~/dest", "names": ["missing"]}, {"dir": "~/dest", "names": []},
                    {"dir": "~/dest", "names": ["proj", "proj"]}):
            res, data = self.run_download(dict(req, roots=["~"]))
            self.assertFalse(res["ok"], req)
            self.assertEqual(data, b"", req)
        res, data = self.run_download({"dir": "~/dest", "names": ["proj"], "roots": ["~"], "max_bytes": 10})
        self.assertFalse(res["ok"])
        self.assertEqual(data, b"")

    # ------------------------------------------------------------ inject

    def test_inject_refusals_without_tmux(self):
        for req in ({"pane": "1", "pid": 2, "text": "x"}, {"pane": "%1;rm", "pid": 2, "text": "x"},
                    {"pane": "%1", "pid": "2", "text": "x"}, {"pane": "%1", "pid": 2, "text": "a\nb"},
                    {"pane": "%1", "pid": 2, "text": "a\x1b[2J"}, {"pane": "%1", "pid": 2, "text": ""}):
            self.assertFalse(self.run_remote(dict(req, cmd="inject"))["ok"], req)

    def test_foreground_refusals(self):
        for req in ({"pid": 1, "ssh_port": 22}, {"pid": os.getpid(), "ssh_port": 0},
                    {"pid": "x", "ssh_port": 22}, {"pid": os.getpid(), "ssh_port": 70000}):
            self.assertFalse(self.run_remote(dict(req, cmd="foreground"))["ok"], req)
        # A live process that is not claude.
        self.assertFalse(self.run_remote({"cmd": "foreground", "pid": os.getpid(), "ssh_port": 50000})["ok"])

    @unittest.skipUnless(sys.platform.startswith("linux") and shutil.which("tmux"), "needs Linux and tmux")
    def test_inject_into_tmux(self):
        sock = os.path.join(self.home, "tmux.sock")
        fake = os.path.join(self.home, "claude")
        shutil.copy(os.path.realpath(sys.executable), fake)
        env = dict(os.environ, HOME=self.home)
        env.pop("TMUX", None)

        def tm(*a):
            return subprocess.run(["tmux", "-S", sock] + list(a), capture_output=True, text=True, env=env).stdout.strip()

        # Pane 1 runs a fake "claude" that echoes its input; pane 2 runs a plain shell.
        tm("new-session", "-d", "-s", "t", "-x", "200", "-y", "20", fake, "-c",
           "import sys\nfor l in sys.stdin: print('GOT', l, end='')")
        tm("split-window", "-t", "t", "sh")
        self.addCleanup(lambda: tm("kill-server"))
        panes = dict(l.split() for l in tm("list-panes", "-t", "t", "-F", "#{pane_index} #{pane_id}").splitlines())
        claude_pid = None
        for _ in range(50):
            for pid in os.listdir("/proc"):
                try:
                    if pid.isdigit() and os.readlink("/proc/%s/exe" % pid) == os.path.realpath(fake):
                        claude_pid = int(pid)
                except OSError:
                    pass
            if claude_pid:
                break
            time.sleep(0.1)
        self.assertTrue(claude_pid)
        # remote.py talks to the same tmux server through TMUX (as it would inside a session).
        os.environ["TMUX"] = sock + ",0,0"
        self.addCleanup(lambda: os.environ.pop("TMUX", None))
        good = {"cmd": "inject", "pane": panes["0"], "pid": claude_pid, "text": "/home/a/x\\ y.png ", "submit": True}
        out = self.run_remote(good)
        self.assertTrue(out["ok"], out)
        time.sleep(0.5)
        self.assertIn("GOT /home/a/x\\ y.png", tm("capture-pane", "-p", "-t", panes["0"]))
        # The shell pane is refused even with the claude pid, and nothing is typed there.
        out = self.run_remote(dict(good, pane=panes["1"]))
        self.assertFalse(out["ok"])
        self.assertNotIn("x\\ y.png", tm("capture-pane", "-p", "-t", panes["1"]))

    # ------------------------------------------------------------ discover

    @unittest.skipUnless(sys.platform.startswith("linux"), "discover needs /proc")
    def test_discover(self):
        out = self.run_remote({"cmd": "discover"})
        self.assertTrue(out["ok"])
        self.assertEqual(out["home"], self.home)
        for s in out["sessions"]:
            self.assertIn(s["kind"], ("claude", "shell"))
            self.assertTrue(os.path.isabs(s["cwd"]))


if __name__ == "__main__":
    unittest.main(verbosity=1)
