#!/usr/bin/env python3
"""Task sync helper for Cart's Tasks and Calendar (standard library only).

The app owns tasks.json (task lists, local tasks, task prefs) and
calendar.json (accounts, shared with calendars and address books). This
helper only reads them, and is the only writer of tasks-remote.json (tasks
fetched from CalDAV lists) and tasks-status.json (when each list last synced,
errors). Account passwords live in the desktop keyring via secret-tool
(service "carts", key "account:<id>", the same entry calsync.py uses), never
in a file or on a command line.

Commands (input, when any, is one JSON line on stdin; output is one JSON line):
  sync [LIST_ID ...]   fetch CalDAV task lists into tasks-remote.json
  discover             {accountId} for a known account, or {provider, server,
                       username, password, accountId} for a new sign-in
                       -> task lists (collections that hold VTODOs); stores the
                       password on success
  make-list            {accountId, name, color} -> create a task list (MKCALENDAR)
  put                  {listId, task}  create or update a task
  delete               {listId, task}
  forget               {listIds: [...], secretKeys: [...]}
"""

from __future__ import annotations

import fcntl
import json
import os
import sys
import tempfile
import time
import urllib.parse
import uuid
import xml.sax.saxutils as saxutils
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dav  # noqa: E402
import vtodo  # noqa: E402
from dav import Failure  # noqa: E402

DATA_HOME = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
DATA_DIR = os.path.join(DATA_HOME, "carts")
TASKS_JSON = os.path.join(DATA_DIR, "tasks.json")
REMOTE_JSON = os.path.join(DATA_DIR, "tasks-remote.json")
STATUS_JSON = os.path.join(DATA_DIR, "tasks-status.json")
LOCK = os.path.join(DATA_DIR, ".tasks-sync.lock")
CALENDAR_JSON = os.path.join(DATA_DIR, "calendar.json")
SERVICE = "carts"
PARALLEL = 4


# --------------------------------------------------------------------------
# Files
# --------------------------------------------------------------------------

def _read_json(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else default
    except FileNotFoundError:
        return default
    except json.JSONDecodeError as e:
        if path == TASKS_JSON:
            raise Failure(f"tasks.json is not valid JSON: {e}")
        return default


def load_config():
    """Task lists from tasks.json, accounts from calendar.json (one account
    list for calendars, address books and task lists)."""
    cfg = _read_json(TASKS_JSON, {"lists": []})
    cfg["accounts"] = shared_accounts()
    return cfg


def _save_json(path, data):
    os.makedirs(DATA_DIR, mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=DATA_DIR, prefix=".remote.", suffix=".json")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, separators=(",", ":"), ensure_ascii=False)
        f.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def _cache(path):
    data = _read_json(path, {})
    if not isinstance(data.get("lists"), dict):
        data = {"version": 1, "lists": {}}
    return data


class Locked:
    def __enter__(self):
        os.makedirs(DATA_DIR, mode=0o700, exist_ok=True)
        self.f = open(LOCK, "w")
        fcntl.flock(self.f, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc):
        fcntl.flock(self.f, fcntl.LOCK_UN)
        self.f.close()


def list_by_id(cfg, list_id):
    for l in cfg.get("lists", []):
        if l.get("id") == list_id:
            return l
    raise Failure("Unknown list")


def account_by_id(cfg, acc_id):
    for a in cfg.get("accounts", []):
        if a.get("id") == acc_id:
            return a
    raise Failure("The account for this list is missing")


def shared_accounts():
    """The accounts in calendar.json (read only, no secrets)."""
    try:
        with open(CALENDAR_JSON, encoding="utf-8") as f:
            data = json.load(f)
    except FileNotFoundError:
        return []
    except json.JSONDecodeError as e:
        raise Failure(f"calendar.json is not valid JSON: {e}")
    out = []
    for a in data.get("accounts", []) if isinstance(data, dict) else []:
        if isinstance(a, dict) and a.get("id"):
            out.append({k: a.get(k, "") for k in ("id", "provider", "server", "username")})
    return out


# --------------------------------------------------------------------------
# Keyring
# --------------------------------------------------------------------------

_auth_cache = {}


def account_auth(acc):
    """(username, password), asking the keyring once per account per run."""
    key = acc["id"]
    if key not in _auth_cache:
        pw = dav.secret_get(SERVICE, "account:" + key)
        if pw is None:
            raise Failure("No password in the keyring for this account; edit the list and sign in again")
        _auth_cache[key] = (acc.get("username", ""), pw)
    return _auth_cache[key]


def store_password(account_id, username, password, provider):
    dav.secret_set(SERVICE, "account:" + account_id, password, f"Cart's Tasks and Calendar: {username} ({provider})")


# --------------------------------------------------------------------------
# Discovery
# --------------------------------------------------------------------------

def _base(provider, server):
    base = (server or dav.PROVIDERS.get(provider, "")).strip()
    if not base:
        raise Failure("Enter the server address")
    if "://" not in base:
        base = "https://" + base
    if not base.endswith("/"):
        base += "/"
    dav.check_url(base)
    return base


def calendar_home(base, auth):
    principal = dav.principal(base, auth)
    root = dav.propfind(principal, auth, "<c:calendar-home-set/>")
    home = dav.href_of(root, ".//c:calendar-home-set/d:href")
    if not home:
        raise Failure("Server did not say where the calendars are (no calendar-home-set)")
    return urllib.parse.urljoin(principal, home)


def task_lists(base, auth):
    """Collections under the calendar home that can hold tasks."""
    home = calendar_home(base, auth)
    root = dav.propfind(home, auth, "<d:resourcetype/><d:displayname/><a:calendar-color/>"
                                    "<c:supported-calendar-component-set/><d:current-user-privilege-set/>", depth="1")
    out = []
    for resp in root.findall("d:response", dav.NS):
        href = dav.href_of(resp, "d:href")
        ok = None
        for ps in resp.findall("d:propstat", dav.NS):
            st = ps.find("d:status", dav.NS)
            if st is not None and " 200 " in (st.text or "") + " ":
                ok = ps.find("d:prop", dav.NS)
        if ok is None or href is None:
            continue
        rt = ok.find("d:resourcetype", dav.NS)
        if rt is None or rt.find("c:calendar", dav.NS) is None:
            continue
        comps = ok.find("c:supported-calendar-component-set", dav.NS)
        names = {c.get("name", "").upper() for c in comps} if comps is not None and len(comps) else None
        if names is not None and "VTODO" not in names:
            continue     # event-only calendars
        name_el = ok.find("d:displayname", dav.NS)
        color_el = ok.find("a:calendar-color", dav.NS)
        privs = ok.find("d:current-user-privilege-set", dav.NS)
        read_only = False
        if privs is not None and len(privs):
            granted = {child.tag.split("}")[-1] for p in privs.findall("d:privilege", dav.NS) for child in p}
            read_only = not ({"write", "write-content", "all", "bind"} & granted)
        url = urllib.parse.urljoin(home, href)
        try:
            dav.check_url(url)
        except Failure:
            continue
        out.append({
            "url": url,
            "name": (name_el.text or "").strip() if name_el is not None and name_el.text else href.rstrip("/").split("/")[-1],
            "color": (color_el.text or "").strip()[:7] if color_el is not None and color_el.text else "",
            "readOnly": read_only,
            # A collection that also holds events (one calendar for both).
            "mixed": names is None or "VEVENT" in names,
        })
    return out


def discover(inp):
    """-> {lists, account: {provider, server, username}}"""
    acc_id = inp.get("accountId") or ""
    if inp.get("password"):
        provider = inp.get("provider") or "caldav"
        base = _base(provider, inp.get("server", ""))
        lists = task_lists(base, (inp.get("username", ""), inp["password"]))
        if acc_id:
            store_password(acc_id, inp.get("username", ""), inp["password"], provider)
        return {"lists": lists, "account": {"provider": provider, "server": inp.get("server") or dav.PROVIDERS.get(provider, ""),
                                            "username": inp.get("username", "")}}
    cfg = load_config()
    acc = account_by_id(cfg, acc_id)
    lists = task_lists(_base(acc.get("provider", "caldav"), acc.get("server", "")), account_auth(acc))
    return {"lists": lists, "account": {k: acc[k] for k in ("provider", "server", "username") if k in acc}}


def make_list(inp):
    cfg = load_config()
    acc = account_by_id(cfg, inp.get("accountId"))
    auth = account_auth(acc)
    name = (inp.get("name") or "").strip() or "Tasks"
    home = calendar_home(_base(acc.get("provider", "caldav"), acc.get("server", "")), auth)
    url = home.rstrip("/") + "/" + str(uuid.uuid4()).upper() + "/"
    color = inp.get("color") or ""
    body = ('<?xml version="1.0" encoding="utf-8"?>'
            '<c:mkcalendar xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:a="http://apple.com/ns/ical/">'
            '<d:set><d:prop><d:displayname>' + saxutils.escape(name) + '</d:displayname>'
            + (f'<a:calendar-color>{saxutils.escape(color)}</a:calendar-color>' if color.startswith("#") else "")
            + '<c:supported-calendar-component-set><c:comp name="VTODO"/></c:supported-calendar-component-set>'
            '</d:prop></d:set></c:mkcalendar>')
    status, _, _ = dav.http("MKCALENDAR", url, body, {"Content-Type": "application/xml; charset=utf-8"}, auth)
    if status == 401:
        raise Failure("Sign-in failed: the password may have been changed")
    if status in (403, 405):
        raise Failure("This server does not let you create lists here")
    if status >= 400:
        raise Failure(f"Server refused to create the list ({status})")
    return {"list": {"url": url, "name": name, "color": color if color.startswith("#") else "", "readOnly": False, "mixed": False}}


# --------------------------------------------------------------------------
# Sync
# --------------------------------------------------------------------------

class NotModified(Exception):
    pass


def report(url, auth):
    body = ('<?xml version="1.0" encoding="utf-8"?>'
            '<c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">'
            '<d:prop><d:getetag/><c:calendar-data/></d:prop>'
            '<c:filter><c:comp-filter name="VCALENDAR"><c:comp-filter name="VTODO"/></c:comp-filter></c:filter>'
            '</c:calendar-query>')
    status, _, resp = dav.http("REPORT", url, body, {"Depth": "1", "Content-Type": "application/xml; charset=utf-8"}, auth)
    if status == 401:
        raise Failure("Sign-in failed: the password may have been revoked")
    if status == 404:
        raise Failure("This list no longer exists on the server")
    if status not in (207, 200):
        raise Failure(f"Server answered {status} to REPORT")
    root = dav.parse_xml(resp)
    items = []
    for r in root.findall("d:response", dav.NS):
        href = dav.href_of(r, "d:href")
        etag = dav.href_of(r, ".//d:getetag")
        data_el = r.find(".//c:calendar-data", dav.NS)
        if href and data_el is not None and data_el.text:
            full = urllib.parse.urljoin(url, href)
            if dav.owned(url, full):
                items.append((full, etag or "", data_el.text))
    return items


def _records(lst, items):
    out = []
    for href, etag, text in items:
        out += vtodo.records(text, lst["id"], {"href": href, "etag": etag, "readOnly": bool(lst.get("readOnly"))})
    out.sort(key=lambda t: t.get("uid", ""))
    return out


def _fetch(cfg, lst, prev):
    now = int(time.time())
    try:
        auth = account_auth(account_by_id(cfg, lst.get("accountId")))
        tag = dav.collection_tag(lst["url"], auth)
        if tag and tag == prev.get("ctag"):
            raise NotModified()
        tasks = _records(lst, report(lst["url"], auth))
        entry = {"tasks": tasks}
        if tag:
            entry["ctag"] = tag
        return entry, {"ok": True, "count": len(tasks)}, {"syncedAt": now, "error": ""}
    except NotModified:
        return None, {"ok": True, "count": len(prev.get("tasks", [])), "unchanged": True}, {"syncedAt": now, "error": ""}
    except Failure as e:
        err = str(e)
    except Exception as e:  # one bad list must not break the rest
        err = f"Unexpected error: {e.__class__.__name__}: {e}"
    return None, {"ok": False, "error": err}, {"error": err, "failedAt": now}


def sync(ids=None):
    cfg = load_config()
    results = {}
    with Locked():
        remote, status = _cache(REMOTE_JSON), _cache(STATUS_JSON)
        before = json.dumps(remote, sort_keys=True)
        known = {l.get("id") for l in cfg.get("lists", [])}
        for store in (remote["lists"], status["lists"]):
            for stale in [k for k in store if k not in known]:
                del store[stale]
        todo = [l for l in cfg.get("lists", []) if l.get("source", {}).get("type") == "caldav" and (not ids or l["id"] in ids)]
        flat = [dict(l, url=l["source"]["url"], accountId=l["source"].get("accountId"), readOnly=l["source"].get("readOnly"))
                for l in todo]
        with ThreadPoolExecutor(max_workers=PARALLEL) as pool:
            futures = {l["id"]: pool.submit(_fetch, cfg, l, remote["lists"].get(l["id"], {})) for l in flat}
        for l in flat:
            entry, result, st = futures[l["id"]].result()
            results[l["id"]] = result
            if entry is not None:
                remote["lists"][l["id"]] = entry
            else:
                remote["lists"].setdefault(l["id"], {"tasks": []})
            prev = status["lists"].get(l["id"], {})
            status["lists"][l["id"]] = dict(prev, **st) if not result["ok"] else st
        changed = json.dumps(remote, sort_keys=True) != before
        if changed or not os.path.exists(REMOTE_JSON):
            _save_json(REMOTE_JSON, remote)
        _save_json(STATUS_JSON, status)
    return {"ok": all(r["ok"] for r in results.values()), "changed": changed, "results": results}


# --------------------------------------------------------------------------
# Writes
# --------------------------------------------------------------------------

def _target(cfg, list_id):
    lst = list_by_id(cfg, list_id)
    src = lst.get("source", {})
    if src.get("type") != "caldav":
        raise Failure("Not a synced list")
    if src.get("readOnly"):
        raise Failure("This list is read-only on the server")
    flat = dict(lst, url=src["url"], readOnly=False)
    return flat, account_auth(account_by_id(cfg, src.get("accountId")))


def _get(href, auth):
    status, headers, body = dav.http("GET", href, headers={"Accept": "text/calendar"}, auth=auth)
    if status == 404:
        raise Failure("This task was deleted on the server; sync to see the latest")
    if status >= 400:
        raise Failure(f"Could not load the task from the server ({status})")
    return dav.decode(body), headers.get("ETag") or headers.get("Etag") or ""


def _write(method, href, text, auth, etag=None, create=False):
    hdrs = {"Content-Type": "text/calendar; charset=utf-8"} if text is not None else {}
    if create:
        hdrs["If-None-Match"] = "*"
    elif etag:
        hdrs["If-Match"] = etag
    status, _, _ = dav.http(method, href, text, hdrs, auth)
    if status == 412:
        raise Failure("The task changed on the server since the last sync; sync and try again")
    if status == 401:
        raise Failure("Sign-in failed: the password may have been revoked")
    if status >= 400 and not (method == "DELETE" and status == 404):
        raise Failure(f"Server refused the change ({status})")


def _refresh(lst, auth, href, gone=False):
    """Put just this object into the cache after our own write. The ctag is
    dropped so the next sync re-reads the list (others may have changed it)."""
    recs = []
    if not gone:
        text, etag = _get(href, auth)
        recs = _records(lst, [(href, etag, text)])
    with Locked():
        remote, status = _cache(REMOTE_JSON), _cache(STATUS_JSON)
        entry = remote["lists"].setdefault(lst["id"], {"tasks": []})
        entry["tasks"] = sorted([t for t in entry.get("tasks", []) if t.get("href") != href] + recs,
                                key=lambda t: t.get("uid", ""))
        entry.pop("ctag", None)
        _save_json(REMOTE_JSON, remote)
        status["lists"][lst["id"]] = dict(status["lists"].get(lst["id"], {}), syncedAt=int(time.time()), error="")
        _save_json(STATUS_JSON, status)
    return {"ok": True, "changed": True, "task": recs[0] if recs else None}


def put_task(list_id, task):
    cfg = load_config()
    lst, auth = _target(cfg, list_id)
    href = task.get("href") if dav.owned(lst["url"], task.get("href")) else None
    try:
        if href:
            original, etag = _get(href, auth)
            if not vtodo.has_task(original):
                raise Failure("That object on the server is not a task")
            _write("PUT", href, vtodo.edit_vcalendar(original, task), auth, etag or task.get("etag"))
        else:
            # The UID names the object, so subtasks created in the same go
            # can point at their parent before the server has seen it.
            uid = vtodo.safe_name(task.get("uid") or "") or str(uuid.uuid4()).upper()
            href = lst["url"].rstrip("/") + "/" + urllib.parse.quote(uid) + ".ics"
            if not dav.owned(lst["url"], href):
                raise Failure("Bad task id")
            _write("PUT", href, vtodo.new_vcalendar(task, uid), auth, create=True)
    except ValueError as e:
        raise Failure(f"Could not write the task: {e}")
    return _refresh(lst, auth, href)


def delete_task(list_id, task):
    cfg = load_config()
    lst, auth = _target(cfg, list_id)
    href = task.get("href")
    if not href or not dav.owned(lst["url"], href):
        raise Failure("Task address is outside this list; refusing to delete it")
    _write("DELETE", href, None, auth, task.get("etag"))
    return _refresh(lst, auth, href, gone=True)


def forget(list_ids, secret_keys):
    for k in secret_keys or []:
        dav.secret_clear(SERVICE, k)
    with Locked():
        remote, status = _cache(REMOTE_JSON), _cache(STATUS_JSON)
        for l in list_ids or []:
            remote["lists"].pop(l, None)
            status["lists"].pop(l, None)
        _save_json(REMOTE_JSON, remote)
        _save_json(STATUS_JSON, status)
    return {"ok": True}


# --------------------------------------------------------------------------

def read_input():
    line = sys.stdin.readline()
    if not line.strip():
        return {}
    try:
        return json.loads(line)
    except json.JSONDecodeError:
        raise Failure("Bad input")


def main(argv):
    os.umask(0o077)
    if not argv:
        print(__doc__)
        return 2
    cmd = argv[0]
    try:
        if cmd == "sync":
            out = sync(argv[1:] or None)
        elif cmd == "discover":
            out = discover(read_input())
            out["ok"] = True
        elif cmd == "make-list":
            out = make_list(read_input())
            out["ok"] = True
        elif cmd == "put":
            inp = read_input()
            out = put_task(inp["listId"], inp["task"])
        elif cmd == "delete":
            inp = read_input()
            out = delete_task(inp["listId"], inp["task"])
        elif cmd == "forget":
            inp = read_input()
            out = forget(inp.get("listIds"), inp.get("secretKeys"))
        else:
            raise Failure(f"Unknown command {cmd}")
    except Failure as e:
        out = {"ok": False, "error": str(e)}
    except KeyError as e:
        out = {"ok": False, "error": f"Missing field {e}"}
    print(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
