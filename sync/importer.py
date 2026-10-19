#!/usr/bin/env python3
"""One-time import from the older separate apps (standard library only).

Cart's Tasks and Calendar keeps everything in ~/.local/share/carts. People coming from the
standalone Calendar app (~/.local/share/omarchy-calendar, keyring service
"omarchy-calendar") or Tasks app (~/.local/share/omarchy-tasks, keyring
service "omarchy-tasks") get their data copied over the first time Cart's Tasks and Calendar
starts. The old folders and keyring entries are only read, never changed,
so the old apps keep working.

What is copied:
  calendar  calendar.json, remote.json, remote-status.json, contacts.json;
            keyring entries account:<id> and ics:<calendarId>
  tasks     tasks.json (lists, local tasks, prefs) -> tasks.json,
            remote.json -> tasks-remote.json,
            remote-status.json -> tasks-status.json.
            The Tasks app kept its own accounts. Each is matched to a
            calendar account (the one it was taken over from, or the same
            provider/server/username); unmatched ones are added to
            calendar.json with their password copied to account:<id>.

It runs at most once: when the data folder already has calendar.json or
tasks.json, or holds the .imported marker, it does nothing. Set
CARTS_NO_IMPORT=1 to skip it.

    importer.py            import if needed; prints one JSON line
    importer.py --dry-run  say what would be imported, write nothing
"""

from __future__ import annotations

import fcntl
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

DATA_HOME = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
DATA_DIR = os.path.join(DATA_HOME, "carts")
OLD_CAL = os.path.join(DATA_HOME, "omarchy-calendar")
OLD_TASKS = os.path.join(DATA_HOME, "omarchy-tasks")
MARKER = os.path.join(DATA_DIR, ".imported")
LOCK = os.path.join(DATA_DIR, ".import.lock")
SERVICE = "carts"
OLD_CAL_SERVICE = "omarchy-calendar"
OLD_TASKS_SERVICE = "omarchy-tasks"


def _read(path):
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else None
    except (FileNotFoundError, json.JSONDecodeError):
        return None


def _write(path, data, pretty=False):
    fd, tmp = tempfile.mkstemp(dir=DATA_DIR, prefix=".import.", suffix=".json")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        if pretty:
            json.dump(data, f, indent=2, ensure_ascii=False)
        else:
            json.dump(data, f, separators=(",", ":"), ensure_ascii=False)
        f.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def _copy(src, dst):
    if os.path.isfile(src):
        shutil.copyfile(src, dst)
        os.chmod(dst, 0o600)
        return True
    return False


def secret_get(service, key):
    try:
        r = subprocess.run(["secret-tool", "lookup", "service", service, "key", key],
                           capture_output=True, text=True, timeout=30)
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None
    return r.stdout if r.returncode == 0 and r.stdout else None


def secret_set(key, value, label):
    try:
        r = subprocess.run(["secret-tool", "store", f"--label={label}", "service", SERVICE, "key", key],
                           input=value, capture_output=True, text=True, timeout=60)
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False
    return r.returncode == 0


def _same_account(a, b):
    def norm(s):
        return str(s or "").strip().lower().rstrip("/")
    return (norm(a.get("provider")) == norm(b.get("provider")) and norm(a.get("username")) == norm(b.get("username"))
            and norm(a.get("server")) == norm(b.get("server")))


def plan():
    """What an import would do now: {"skip": reason} or the pieces found."""
    if os.environ.get("CARTS_NO_IMPORT"):
        return {"skip": "CARTS_NO_IMPORT is set"}
    if os.path.exists(MARKER):
        return {"skip": "already imported"}
    for name in ("calendar.json", "tasks.json"):
        if os.path.exists(os.path.join(DATA_DIR, name)):
            return {"skip": "carts already has data", "fresh": True}
    cal = _read(os.path.join(OLD_CAL, "calendar.json"))
    tasks = _read(os.path.join(OLD_TASKS, "tasks.json"))
    if cal is None and tasks is None:
        return {"skip": "nothing to import", "fresh": True}
    return {"calendar": cal, "tasks": tasks}


def run(dry_run=False):
    p = plan()
    if "skip" in p:
        if p.get("fresh") and not dry_run and not os.environ.get("CARTS_NO_IMPORT"):
            _mark("fresh")
        return {"ok": True, "imported": False, "reason": p["skip"]}
    cal, tasks = p["calendar"], p["tasks"]
    report = {"ok": True, "imported": True, "calendar": cal is not None, "tasks": tasks is not None,
              "secrets": 0, "secretsMissing": 0, "accountsMerged": 0, "accountsAdded": 0}
    if dry_run:
        report["dryRun"] = True
        report["calendars"] = len((cal or {}).get("calendars", []))
        report["lists"] = len((tasks or {}).get("lists", []))
        return report

    # ---- Calendar: the files as they are, plus their keyring entries.
    if cal is None:
        cal = {"version": 1, "calendars": [{"id": "cal-" + str(int(time.time())), "name": "Personal",
                                             "color": "theme:accent", "visible": True, "source": {"type": "local"}}],
               "events": [], "accounts": []}
    else:
        for name in ("remote.json", "remote-status.json", "contacts.json"):
            _copy(os.path.join(OLD_CAL, name), os.path.join(DATA_DIR, name))
        keys = ["account:" + a["id"] for a in cal.get("accounts", []) if isinstance(a, dict) and a.get("id")]
        keys += ["ics:" + c["id"] for c in cal.get("calendars", [])
                 if isinstance(c, dict) and c.get("id") and (c.get("source") or {}).get("type") == "ics"]
        for key in keys:
            value = secret_get(OLD_CAL_SERVICE, key)
            if value is None:
                report["secretsMissing"] += 1
            elif secret_set(key, value, "Cart's Tasks and Calendar: " + key.split(":")[0] + " (imported)"):
                report["secrets"] += 1
    accounts = [a for a in cal.get("accounts", []) if isinstance(a, dict) and a.get("id")]

    # ---- Tasks: lists and tasks as they are; accounts folded into the
    # calendar's. The Tasks app's accounts live in tasks.json.
    if tasks is not None:
        remap = {}
        for acc in tasks.get("accounts", []) or []:
            if not isinstance(acc, dict) or not acc.get("id"):
                continue
            match = next((a for a in accounts if a["id"] == acc.get("linkedFrom")), None) \
                or next((a for a in accounts if _same_account(a, acc)), None)
            if match is not None:
                remap[acc["id"]] = match["id"]
                report["accountsMerged"] += 1
                continue
            value = secret_get(OLD_TASKS_SERVICE, "account:" + acc["id"])
            if value is None and acc.get("linkedFrom"):
                value = secret_get(OLD_CAL_SERVICE, "account:" + acc["linkedFrom"])
            if value is None:
                report["secretsMissing"] += 1
            elif secret_set("account:" + acc["id"], value, f"Cart's Tasks and Calendar: {acc.get('username', '')} (imported)"):
                report["secrets"] += 1
            accounts.append({k: acc.get(k, "") for k in ("id", "provider", "server", "username")})
            report["accountsAdded"] += 1
        out = {k: v for k, v in tasks.items() if k != "accounts"}
        for lst in out.get("lists", []) or []:
            src = lst.get("source") if isinstance(lst, dict) else None
            if isinstance(src, dict) and src.get("accountId") in remap:
                src["accountId"] = remap[src["accountId"]]
        _write(os.path.join(DATA_DIR, "tasks.json"), out, pretty=True)
        old_remote = _read(os.path.join(OLD_TASKS, "remote.json"))
        if old_remote is not None:
            _write(os.path.join(DATA_DIR, "tasks-remote.json"), old_remote)
        old_status = _read(os.path.join(OLD_TASKS, "remote-status.json"))
        if old_status is not None:
            _write(os.path.join(DATA_DIR, "tasks-status.json"), old_status)

    cal["accounts"] = accounts
    # calendar.json last: its appearance is what tells the stores data is here.
    _write(os.path.join(DATA_DIR, "calendar.json"), cal, pretty=True)
    _mark("imported")
    return report


def _mark(kind):
    with open(MARKER, "w", encoding="utf-8") as f:
        f.write(kind + " " + time.strftime("%Y-%m-%dT%H:%M:%S") + "\n")


def main(argv):
    os.umask(0o077)
    dry = "--dry-run" in argv
    os.makedirs(DATA_DIR, mode=0o700, exist_ok=True)
    try:
        with open(LOCK, "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)    # the plugin and the app may start together
            out = run(dry)
    except Exception as e:  # never keep the app from starting
        out = {"ok": False, "error": f"{e.__class__.__name__}: {e}"}
    print(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
