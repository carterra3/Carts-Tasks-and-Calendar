"""The one-time import from the separate Calendar and Tasks apps.

    python3 tests/test_importer.py

Runs sync/importer.py against a temporary data folder with a fake
`secret-tool` on PATH (a tiny script keeping secrets in a JSON file), so the
real keyring is never touched.
"""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
IMPORTER = os.path.join(os.path.dirname(HERE), "sync", "importer.py")

FAKE_SECRET_TOOL = r'''#!/usr/bin/env python3
import json, os, sys
db = os.environ["FAKE_KEYRING"]
try:
    data = json.load(open(db))
except FileNotFoundError:
    data = {}
args = sys.argv[1:]
cmd = args[0]
rest = [a for a in args[1:] if not a.startswith("--label")]
attrs = dict(zip(rest[0::2], rest[1::2]))
k = attrs["service"] + "|" + attrs["key"]
if cmd == "lookup":
    if k in data:
        sys.stdout.write(data[k]); sys.exit(0)
    sys.exit(1)
if cmd == "store":
    data[k] = sys.stdin.read()
    json.dump(data, open(db, "w")); sys.exit(0)
if cmd == "clear":
    data.pop(k, None); json.dump(data, open(db, "w")); sys.exit(0)
sys.exit(2)
'''


def setup():
    root = tempfile.mkdtemp(prefix="carts-import-")
    data_home = os.path.join(root, "data")
    bin_dir = os.path.join(root, "bin")
    os.makedirs(bin_dir)
    tool = os.path.join(bin_dir, "secret-tool")
    with open(tool, "w") as f:
        f.write(FAKE_SECRET_TOOL)
    os.chmod(tool, 0o755)
    keyring = os.path.join(root, "keyring.json")
    env = dict(os.environ, XDG_DATA_HOME=data_home, FAKE_KEYRING=keyring, PATH=bin_dir + os.pathsep + os.environ["PATH"])
    env.pop("CARTS_NO_IMPORT", None)
    return root, data_home, keyring, env


def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(data, f)


def run(env, *args):
    r = subprocess.run([sys.executable, IMPORTER, *args], env=env, capture_output=True, text=True, timeout=60)
    assert r.returncode == 0, r.stderr
    return json.loads(r.stdout.strip().splitlines()[-1])


def read(path):
    with open(path) as f:
        return json.load(f)


# ---- Both old apps present.
root, data_home, keyring, env = setup()
old_cal, old_tasks, new = (os.path.join(data_home, d) for d in ("omarchy-calendar", "omarchy-tasks", "carts"))
write(os.path.join(old_cal, "calendar.json"), {
    "version": 1,
    "accounts": [{"id": "acc-cal", "provider": "fastmail", "server": "https://caldav.fastmail.com/", "username": "pat@example.com"}],
    "calendars": [
        {"id": "cal-1", "name": "Home", "color": "theme:blue", "visible": True, "source": {"type": "local"}},
        {"id": "cal-2", "name": "Work", "color": "theme:red", "visible": True,
         "source": {"type": "caldav", "accountId": "acc-cal", "url": "https://caldav.fastmail.com/dav/work/"}},
        {"id": "cal-3", "name": "Holidays", "color": "theme:green", "visible": True, "source": {"type": "ics", "label": "example.org"}},
    ],
    "events": [{"uid": "e1", "calendarId": "cal-1", "title": "Dentist", "start": "2026-10-20T08:30", "end": "2026-10-20T09:30"}],
    "prefs": {"weekStart": "monday"},
})
write(os.path.join(old_cal, "remote.json"), {"version": 1, "calendars": {"cal-2": {"events": []}}})
write(os.path.join(old_cal, "contacts.json"), {"version": 1, "books": {}})
write(os.path.join(old_tasks, "tasks.json"), {
    "version": 1,
    "accounts": [
        # taken over from the calendar: folds into acc-cal
        {"id": "acc-t1", "provider": "fastmail", "server": "https://caldav.fastmail.com/", "username": "pat@example.com", "linkedFrom": "acc-cal"},
        # its own sign-in to another server: added
        {"id": "acc-t2", "provider": "nextcloud", "server": "https://cloud.example.com/remote.php/dav/", "username": "pat"},
    ],
    "lists": [
        {"id": "list-1", "name": "Errands", "color": "theme:accent", "source": {"type": "local"}},
        {"id": "list-2", "name": "Work tasks", "color": "theme:blue", "source": {"type": "caldav", "accountId": "acc-t1", "url": "https://caldav.fastmail.com/dav/tasks/"}},
        {"id": "list-3", "name": "Shared", "color": "theme:yellow", "source": {"type": "caldav", "accountId": "acc-t2", "url": "https://cloud.example.com/remote.php/dav/calendars/pat/shared/"}},
    ],
    "tasks": [{"uid": "T1", "listId": "list-1", "title": "Buy stamps", "status": "NEEDS-ACTION"}],
    "prefs": {"keepHistory": False},
})
write(os.path.join(old_tasks, "remote.json"), {"version": 1, "lists": {"list-2": {"tasks": [{"uid": "R1", "listId": "list-2", "title": "Report"}]}}})
write(os.path.join(old_tasks, "remote-status.json"), {"version": 1, "lists": {"list-2": {"syncedAt": 1, "error": ""}}})
write(keyring, {
    "omarchy-calendar|account:acc-cal": "cal-pw",
    "omarchy-calendar|ics:cal-3": "https://example.org/secret.ics",
    "omarchy-tasks|account:acc-t1": "cal-pw",
    "omarchy-tasks|account:acc-t2": "nc-pw",
})

dry = run(env, "--dry-run")
assert dry["dryRun"] and dry["calendars"] == 3 and dry["lists"] == 3, dry
assert not os.path.exists(os.path.join(new, "calendar.json")), "dry run wrote files"

res = run(env)
assert res["imported"] and res["accountsMerged"] == 1 and res["accountsAdded"] == 1, res
assert res["secrets"] == 3 and res["secretsMissing"] == 0, res

cal = read(os.path.join(new, "calendar.json"))
assert [c["id"] for c in cal["calendars"]] == ["cal-1", "cal-2", "cal-3"], cal
assert cal["events"][0]["title"] == "Dentist" and cal["prefs"] == {"weekStart": "monday"}
assert [a["id"] for a in cal["accounts"]] == ["acc-cal", "acc-t2"], cal["accounts"]
assert "linkedFrom" not in json.dumps(cal["accounts"])
tasks = read(os.path.join(new, "tasks.json"))
assert "accounts" not in tasks, tasks
src = {l["id"]: l["source"] for l in tasks["lists"]}
assert src["list-2"]["accountId"] == "acc-cal" and src["list-3"]["accountId"] == "acc-t2", src
assert tasks["tasks"][0]["title"] == "Buy stamps" and tasks["prefs"] == {"keepHistory": False}
assert read(os.path.join(new, "tasks-remote.json"))["lists"]["list-2"]["tasks"][0]["uid"] == "R1"
assert read(os.path.join(new, "tasks-status.json"))["lists"]["list-2"]["syncedAt"] == 1
assert read(os.path.join(new, "remote.json"))["calendars"] == {"cal-2": {"events": []}}
assert os.path.exists(os.path.join(new, "contacts.json"))

keys = read(keyring)
assert keys["carts|account:acc-cal"] == "cal-pw" and keys["carts|ics:cal-3"] == "https://example.org/secret.ics"
assert keys["carts|account:acc-t2"] == "nc-pw" and "carts|account:acc-t1" not in keys, keys
# The old entries are left alone.
assert keys["omarchy-calendar|account:acc-cal"] == "cal-pw" and keys["omarchy-tasks|account:acc-t2"] == "nc-pw"
for d in (new,):
    assert oct(os.stat(d).st_mode & 0o777) == "0o700", oct(os.stat(d).st_mode)
    for f in os.listdir(d):
        if f.endswith(".json"):
            assert os.stat(os.path.join(d, f)).st_mode & 0o077 == 0, f

# A second run does nothing, even after the old data changes.
write(os.path.join(old_cal, "calendar.json"), {"version": 1, "calendars": [], "events": []})
again = run(env)
assert not again["imported"] and again["reason"] == "already imported", again
assert len(read(os.path.join(new, "calendar.json"))["calendars"]) == 3
print("both apps ok")

# ---- Only the Tasks app: a calendar.json is made for its accounts.
root, data_home, keyring, env = setup()
new = os.path.join(data_home, "carts")
write(os.path.join(data_home, "omarchy-tasks", "tasks.json"), {
    "version": 1,
    "accounts": [{"id": "acc-x", "provider": "caldav", "server": "https://dav.example.com/", "username": "sam", "linkedFrom": "gone"}],
    "lists": [{"id": "l", "name": "Tasks", "source": {"type": "caldav", "accountId": "acc-x", "url": "https://dav.example.com/t/"}}],
    "tasks": [],
})
write(keyring, {"omarchy-calendar|account:gone": "from-calendar"})
res = run(env)
assert res["imported"] and res["accountsAdded"] == 1 and res["secrets"] == 1, res
cal = read(os.path.join(new, "calendar.json"))
assert cal["calendars"][0]["name"] == "Personal" and cal["accounts"][0]["id"] == "acc-x", cal
assert read(keyring)["carts|account:acc-x"] == "from-calendar"
print("tasks only ok")

# ---- Nothing old, or carts already set up: no import, no files, marker set.
root, data_home, keyring, env = setup()
res = run(env)
assert not res["imported"] and res["reason"] == "nothing to import", res
assert sorted(os.listdir(os.path.join(data_home, "carts"))) == [".import.lock", ".imported"]

root, data_home, keyring, env = setup()
write(os.path.join(data_home, "carts", "calendar.json"), {"version": 1, "calendars": []})
write(os.path.join(data_home, "omarchy-calendar", "calendar.json"), {"version": 1, "calendars": [{"id": "x"}]})
res = run(env)
assert not res["imported"] and res["reason"] == "carts already has data", res
assert read(os.path.join(data_home, "carts", "calendar.json"))["calendars"] == []

root, data_home, keyring, env = setup()
write(os.path.join(data_home, "omarchy-calendar", "calendar.json"), {"version": 1, "calendars": [{"id": "x"}]})
res = run(dict(env, CARTS_NO_IMPORT="1"))
assert not res["imported"] and not os.path.exists(os.path.join(data_home, "carts", ".imported")), res
print("no-op cases ok")
print("importer tests passed")
