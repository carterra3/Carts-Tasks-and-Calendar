"""Run the Tasks-mode QML suites (tests/qml/tasks_*.qml) against the real
window, views and stores, headless.

Each suite is a Quickshell root (ShellRoot) that drives components and prints
"X|PASS name" / "X|FAIL name" lines. This runner gives every suite a fresh
data dir seeded from tests/qml/seed.json, a throwaway Radicale server (one
calendar that holds tasks, with a repeating Apple-style reminder), an account
in calendar.json pointing at it, and its password in the keyring under the
"carts" service, then removes all of it.

    pip install radicale   # in any venv
    <venv>/bin/python tests/run_qml_tasks.py [SUITE ...]   # default: every suite

Needs quickshell and Omarchy's shell at $OMARCHY_PATH (default
/usr/share/omarchy). Runs offscreen, so no windows appear.
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

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
SUITES = os.path.join(HERE, "qml")
SHELL = os.path.join(os.environ.get("OMARCHY_PATH", "/usr/share/omarchy"), "shell")
CAL_ACCOUNT = "acc-cal-qml"
PASSWORD = "qml-pass"
LINE = re.compile(r"\b[A-Z]\|(PASS|FAIL|done|timeout)\b(.*)")

REMINDER = ("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Apple Inc.//iOS 17//EN\r\nBEGIN:VTODO\r\nUID:apple-weekly\r\n"
            "DTSTAMP:20261001T000000Z\r\nSUMMARY:Take out recycling\r\nDTSTART;VALUE=DATE:@DUE@\r\nDUE;VALUE=DATE:@DUE@\r\n"
            "RRULE:FREQ=WEEKLY\r\nX-APPLE-SORT-ORDER:1\r\nBEGIN:VALARM\r\nACTION:DISPLAY\r\nDESCRIPTION:Reminder\r\n"
            "TRIGGER:-PT15M\r\nEND:VALARM\r\nEND:VTODO\r\nEND:VCALENDAR\r\n")
EVENT = ("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:ev1\r\nDTSTART:20261020T150000Z\r\n"
         "DTEND:20261020T160000Z\r\nSUMMARY:Meeting\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n")


def user_of(suite):
    return "qml" + re.sub(r"[^a-z0-9]", "", suite.lower())


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


class Radicale:
    def __init__(self, tmp, suites):
        self.port = free_port()
        self.base = f"http://127.0.0.1:{self.port}/"
        # One server user per suite, so suites never see each other's lists.
        with open(os.path.join(tmp, "users"), "w") as f:
            f.write("".join(f"{user_of(s)}:{PASSWORD}\n" for s in suites))
        conf = os.path.join(tmp, "radicale.conf")
        with open(conf, "w") as f:
            f.write(f"[server]\nhosts = 127.0.0.1:{self.port}\n[auth]\ntype = htpasswd\n"
                    f"htpasswd_filename = {tmp}/users\nhtpasswd_encryption = plain\n"
                    f"[storage]\nfilesystem_folder = {tmp}/collections\n[logging]\nlevel = warning\n")
        self.proc = subprocess.Popen([sys.executable, "-m", "radicale", "--config", conf],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(60):
            try:
                urllib.request.urlopen(self.base, timeout=1)
                break
            except urllib.error.HTTPError:
                break
            except Exception:
                time.sleep(0.1)

    def req(self, user, method, path, body=None, ctype="application/xml"):
        auth = "Basic " + base64.b64encode(f"{user}:{PASSWORD}".encode()).decode()
        r = urllib.request.Request(self.base + path, data=body.encode() if body else None, method=method,
                                   headers={"Authorization": auth, "Content-Type": ctype})
        try:
            return urllib.request.urlopen(r, timeout=5).status
        except urllib.error.HTTPError as e:
            return e.code

    def seed(self, slug):
        """A calendar holding tasks and an event, for the suite's own user."""
        u = user_of(slug)
        assert self.req(u, "MKCALENDAR", f"{u}/{slug}/",
                        '<?xml version="1.0"?><c:mkcalendar xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">'
                        f'<d:set><d:prop><d:displayname>Home {slug}</d:displayname></d:prop></d:set></c:mkcalendar>') == 201
        due = time.strftime("%Y%m%d", time.localtime(time.time() - 86400))     # yesterday: overdue
        assert self.req(u, "PUT", f"{u}/{slug}/apple-weekly.ics", REMINDER.replace("@DUE@", due), "text/calendar") in (201, 204)
        assert self.req(u, "PUT", f"{u}/{slug}/ev1.ics", EVENT, "text/calendar") in (201, 204)

    def stop(self):
        self.proc.terminate()


def config_dir(tmp, suite):
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
    with open(os.path.join(SUITES, "tasks_seed.json")) as f:
        seed = f.read()
    today = time.strftime("%Y-%m-%d")
    seed = seed.replace("@TODAY@", today)
    with open(os.path.join(data_home, "carts", "tasks.json"), "w") as f:
        f.write(seed)
    # The window opens in Tasks mode; the account is the shared one.
    with open(os.path.join(data_home, "carts", "calendar.json"), "w") as f:
        json.dump({"version": 1, "accounts": [{"id": CAL_ACCOUNT, "provider": "caldav", "server": rad.base, "username": user_of(suite)}],
                   "calendars": [], "events": [], "prefs": {"windowMode": "tasks"}}, f)
    rad.seed(suite)
    # Per suite: removing a task list's last use of the account clears this
    # entry, as it should for a real account.
    subprocess.run(["secret-tool", "store", "--label", "Carts: QML test", "service", "carts",
                    "key", "account:" + CAL_ACCOUNT], input=PASSWORD, text=True, check=True)
    env = dict(os.environ, XDG_DATA_HOME=data_home, QT_QPA_PLATFORM="offscreen",
               QML_TEST_COLLECTION=f"{rad.base}{user_of(suite)}/{suite}/")
    env.pop("WAYLAND_DISPLAY", None)
    try:
        out = subprocess.run(["quickshell", "-p", config_dir(tmp, suite)], env=env, capture_output=True,
                             text=True, timeout=150).stdout
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
            problems.append(line.strip())
    ok = finished and not failed and not problems and passed > 0
    print(f"{'ok  ' if ok else 'FAIL'} {suite}: {passed} passed" + (f", {len(failed)} failed" if failed else "")
          + ("" if finished else ", did not finish"))
    for f in failed:
        print("     FAIL", f)
    for p in problems:
        print("     ", p)
    return ok


def task_keys():
    """Keys of the app's keyring entries (secret-tool prints attributes on stderr)."""
    r = subprocess.run(["secret-tool", "search", "--all", "service", "carts"], capture_output=True, text=True)
    return set(re.findall(r"^attribute\.key = (.*)$", r.stdout + "\n" + r.stderr, re.M))


def main(argv):
    suites = argv or sorted(os.path.splitext(os.path.basename(p))[0] for p in glob.glob(os.path.join(SUITES, "tasks_*.qml")))
    if not shutil.which("quickshell"):
        print("quickshell not found")
        return 2
    keys_before = task_keys()
    tmp = tempfile.mkdtemp(prefix="carts-tasks-qml-")
    rad = Radicale(tmp, suites)
    ok = False
    try:
        subprocess.run(["secret-tool", "store", "--label", "Carts: QML test", "service", "carts",
                        "key", "account:" + CAL_ACCOUNT], input=PASSWORD, text=True, check=True)
        ok = all([run_suite(tmp, rad, s) for s in suites])
    finally:
        subprocess.run(["secret-tool", "clear", "service", "carts", "key", "account:" + CAL_ACCOUNT])
        # Passwords the suites stored (new sign-ins): every key that was not
        # there before the run.
        for key in task_keys() - keys_before:
            subprocess.run(["secret-tool", "clear", "service", "carts", "key", key])
        rad.stop()
        shutil.rmtree(tmp, ignore_errors=True)
    print("qml suites passed" if ok else "qml suites FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
