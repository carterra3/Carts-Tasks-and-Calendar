"""Run the QML suites in tests/qml/ against the real views and Store, headless.

Each suite is a Quickshell root (ShellRoot) that drives components and prints
"X|PASS name" / "X|FAIL name" lines. This runner gives every suite a fresh
data dir seeded from tests/qml/seed.json, a throwaway Radicale server (one
CalDAV calendar, two address books with sample cards) and a test password in
the desktop keyring, then removes all of it.

    pip install radicale   # in any venv
    <venv>/bin/python tests/run_qml.py [SUITE ...]   # default: every suite

Needs quickshell, and Omarchy's shell at $OMARCHY_PATH (default
/usr/share/omarchy) for the qs.Commons / qs.Ui modules. Runs offscreen, so no
windows appear.
"""
import base64
import glob
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import zlib
import struct

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
SUITES = os.path.join(HERE, "qml")
SHELL = os.path.join(os.environ.get("OMARCHY_PATH", "/usr/share/omarchy"), "shell")
SECRET_KEY = "account:acc-qml"
USER, PASSWORD = "qml", "qml-pass"
LINE = re.compile(r"\b[A-Z]\|(PASS|FAIL|done|timeout)\b(.*)")


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def png(w, h, rgb):
    raw = b"".join(b"\x00" + bytes(rgb) * w for _ in range(h))

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


PHOTO = base64.b64encode(png(32, 32, (200, 120, 60))).decode()
CARDS = {
    "personal-ab": [
        "BEGIN:VCARD\r\nVERSION:3.0\r\nUID:p1\r\nFN:Mary Garcia\r\nN:Garcia;Mary;;;\r\nORG:Acme Corp\r\nTITLE:Engineer\r\n"
        "item1.EMAIL;type=INTERNET;type=HOME;type=pref:mary@example.com\r\nitem1.X-ABLABEL:_$!<Home>!$_\r\n"
        "TEL;type=CELL;type=VOICE;type=pref:(555) 010-0100\r\nTEL;type=WORK;type=VOICE:555 010 0200\r\n"
        "ADR;type=HOME:;;1 Main St;Springfield;OR;97477;USA\r\nBDAY:1990-03-14\r\nURL:https://mary.example.com\r\n"
        "NOTE:Met at the conference.\\nLikes tea.\r\nEND:VCARD\r\n",
        "BEGIN:VCARD\r\nVERSION:3.0\r\nUID:p2\r\nFN:Bob Abbott\r\nN:Abbott;Bob;;;\r\nEMAIL;TYPE=WORK:bob@work.example\r\n"
        "PHOTO;ENCODING=b;TYPE=PNG:" + PHOTO + "\r\nEND:VCARD\r\n",
        "BEGIN:VCARD\r\nVERSION:4.0\r\nUID:p3\r\nFN:Émile Zola\r\nN:Zola;Émile;;;\r\n"
        "TEL;VALUE=uri;TYPE=\"voice,home\":tel:+33-1-555-0100\r\nBDAY:--0402\r\nEND:VCARD\r\n",
        "BEGIN:VCARD\r\nVERSION:3.0\r\nUID:p4\r\nFN:Carla Diaz\r\nN:Diaz;Carla;;;\r\nTEL;TYPE=CELL:555-0300\r\nEND:VCARD\r\n",
    ],
    "work-ab": [
        "BEGIN:VCARD\r\nVERSION:3.0\r\nUID:w1\r\nFN:Zed Plumbing\r\nN:;;;;\r\nORG:Zed Plumbing\r\nTEL;TYPE=MAIN:555-0900\r\nEND:VCARD\r\n",
        "BEGIN:VCARD\r\nVERSION:3.0\r\nUID:w2\r\nFN:Dana Kim\r\nN:Kim;Dana;;;\r\nORG:Acme Corp\r\nTITLE:Manager\r\n"
        "EMAIL;TYPE=WORK:dana@acme.example\r\nEND:VCARD\r\n",
    ],
}
BOOK_NAMES = {"personal-ab": "Personal", "work-ab": "Work contacts"}


class Radicale:
    def __init__(self, tmp):
        self.port = free_port()
        self.base = f"http://127.0.0.1:{self.port}/"
        with open(os.path.join(tmp, "users"), "w") as f:
            f.write(f"{USER}:{PASSWORD}\n")
        conf = os.path.join(tmp, "radicale.conf")
        with open(conf, "w") as f:
            f.write(f"[server]\nhosts = 127.0.0.1:{self.port}\n[auth]\ntype = htpasswd\n"
                    f"htpasswd_filename = {tmp}/users\nhtpasswd_encryption = plain\n"
                    f"[storage]\nfilesystem_folder = {tmp}/collections\n[logging]\nlevel = warning\n")
        self.proc = subprocess.Popen([sys.executable, "-m", "radicale", "--config", conf],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(50):
            try:
                urllib.request.urlopen(self.base, timeout=1)
                break
            except urllib.error.HTTPError:
                break
            except Exception:
                time.sleep(0.1)
        self.auth = "Basic " + base64.b64encode(f"{USER}:{PASSWORD}".encode()).decode()

    def req(self, method, path, body=None, ctype="application/xml"):
        r = urllib.request.Request(self.base + path, data=body.encode() if body else None, method=method,
                                   headers={"Authorization": self.auth, "Content-Type": ctype})
        try:
            return urllib.request.urlopen(r, timeout=5).status
        except urllib.error.HTTPError as e:
            return e.code

    def seed(self):
        self.req("MKCALENDAR", f"{USER}/work/",
                 '<?xml version="1.0"?><c:mkcalendar xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">'
                 '<d:set><d:prop><d:displayname>Work</d:displayname></d:prop></d:set></c:mkcalendar>')
        for slug, cards in CARDS.items():
            self.req("MKCOL", f"{USER}/{slug}/",
                     '<?xml version="1.0"?><d:mkcol xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav"><d:set><d:prop>'
                     '<d:resourcetype><d:collection/><card:addressbook/></d:resourcetype>'
                     f'<d:displayname>{BOOK_NAMES[slug]}</d:displayname></d:prop></d:set></d:mkcol>')
            for card in cards:
                uid = card.split("UID:")[1].split("\r\n")[0]
                assert self.req("PUT", f"{USER}/{slug}/{uid}.vcf", card, "text/vcard") in (201, 204)

    def stop(self):
        self.proc.terminate()


def config_dir(tmp, suite):
    """A Quickshell config folder: the repo's QML/JS, sync/, Omarchy's
    Commons/Ui (which must sit inside the folder), and the suite as shell.qml."""
    d = os.path.join(tmp, "cfg-" + suite)
    os.makedirs(d)
    for f in glob.glob(os.path.join(REPO, "*.qml")) + glob.glob(os.path.join(REPO, "*.js")):
        if os.path.basename(f) != "CalendarApp.qml":
            os.symlink(f, os.path.join(d, os.path.basename(f)))
    os.symlink(os.path.join(REPO, "sync"), os.path.join(d, "sync"))
    for m in ("Commons", "Ui"):
        os.symlink(os.path.join(SHELL, m), os.path.join(d, m))
    shutil.copy(os.path.join(SUITES, suite + ".qml"), os.path.join(d, "shell.qml"))
    return d


def run_suite(tmp, rad, suite):
    data_home = os.path.join(tmp, "data-" + suite)
    os.makedirs(os.path.join(data_home, "carts"))
    with open(os.path.join(SUITES, "seed.json")) as f:
        seed = f.read().replace("@BASE@", rad.base)
    with open(os.path.join(data_home, "carts", "calendar.json"), "w") as f:
        f.write(seed)
    env = dict(os.environ, XDG_DATA_HOME=data_home, TZ="America/Chicago", QT_QPA_PLATFORM="offscreen")
    env.pop("WAYLAND_DISPLAY", None)
    try:
        out = subprocess.run(["quickshell", "-p", config_dir(tmp, suite)], env=env, capture_output=True,
                             text=True, timeout=120).stdout
    except subprocess.TimeoutExpired as e:
        out = (e.stdout or b"").decode() if isinstance(e.stdout, bytes) else (e.stdout or "")
        out += "\nX|timeout (runner)"
    if os.environ.get("QML_VERBOSE"):
        print(out)
    passed, failed, finished, problems = 0, [], False, []
    for line in out.splitlines():
        m = LINE.search(line)
        if m:
            kind, rest = m.group(1), m.group(2).strip()
            if kind == "PASS":
                passed += 1
            elif kind == "FAIL":
                failed.append(rest)
            elif kind == "done":
                finished = True
            else:
                failed.append("timed out " + rest)
        elif ("WARN" in line or "ERROR" in line) and "/cfg-" + suite in line:
            problems.append(line.strip())     # QML warnings from our own files
    ok = finished and not failed and not problems and passed > 0
    print(f"{'ok  ' if ok else 'FAIL'} {suite}: {passed} passed" + (f", {len(failed)} failed" if failed else "")
          + ("" if finished else ", did not finish"))
    for f in failed:
        print("     FAIL", f)
    for p in problems:
        print("     ", p)
    return ok


def main(argv):
    suites = argv or sorted(os.path.splitext(os.path.basename(p))[0] for p in glob.glob(os.path.join(SUITES, "*.qml")))
    if not shutil.which("quickshell"):
        print("quickshell not found")
        return 2
    tmp = tempfile.mkdtemp(prefix="calendar-qml-")
    rad = Radicale(tmp)
    ok = False
    try:
        subprocess.run(["secret-tool", "store", "--label", "Carts: QML test", "service", "carts",
                        "key", SECRET_KEY], input=PASSWORD, text=True, check=True)
        rad.seed()
        ok = all([run_suite(tmp, rad, s) for s in suites])
    finally:
        subprocess.run(["secret-tool", "clear", "service", "carts", "key", SECRET_KEY])
        rad.stop()
        shutil.rmtree(tmp, ignore_errors=True)
    print("qml suites passed" if ok else "qml suites FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
