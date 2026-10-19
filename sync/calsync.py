#!/usr/bin/env python3
"""Sync helper for Cart's Tasks and Calendar (calendars, ICS links, address books; (standard library only).

The plugin owns calendar.json (calendars, accounts, local events). This
helper only *reads* it, and is the only writer of remote.json, the cache of
events fetched from subscribed links and CalDAV accounts. Secrets (account
passwords, private iCal links) live in the desktop keyring via secret-tool,
never in either file and never on a command line.

Commands (input, when any, is one JSON line on stdin; output is one JSON line):
  sync [CAL_ID ...]   fetch remote calendars into remote.json (events) and
                      remote-status.json (when each last synced, errors)
  discover            {provider, server, username, password, accountId}
                      -> list CalDAV calendars; stores the password on success
  set-secret          {key, value}
  forget              {calendarIds: [...], secretKeys: [...]}
  put                 {calendarId, event, scope?}   create/update on a CalDAV calendar;
                      scope this|following|all for an occurrence of a series
  delete              {calendarId, event, scope?}   delete from a CalDAV calendar
  get-series          {calendarId, event} -> the series of an occurrence as a
                      local record (rrule, exdates, overrides)
  copy-series         {calendarId, event, toCalendarId}  copy a series object
                      unchanged to another CalDAV calendar
  contacts-discover   {accountId} for a known account, or {server, username,
                      password, accountId} for a new one -> address books
  contacts-sync [BOOK_ID ...]  fetch address books into contacts.json
  contact-put         {bookId, contact}   create/update a contact (vCard)
  contact-delete      {bookId, contact}
  zones               {names: [...]} -> offset tables for those zones (Tz.js)
                      plus this machine's zone name
  zone-list           -> every zone name
"""

from __future__ import annotations

import concurrent.futures
import fcntl
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dav  # noqa: E402
import ical  # noqa: E402
# HTTP plumbing and its hardening (https only, no credentials across sites on
# redirects, capped reads, hrefs kept inside their collection) live in dav.py,
# shared with tasksync.py.
from dav import (Failure, LOCAL_HOSTS, MAX_BYTES, MAX_ERROR_BYTES, PUBLIC_SUFFIXES, TIMEOUT, UA,  # noqa: E402,F401
                 _is_ip, _read_capped, _redirect_ok, check_url as _check_url, decode as _decode, http, owned as _owned)
import series  # noqa: E402
import tzdata  # noqa: E402
import vcard  # noqa: E402

DATA_DIR = os.path.join(os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share"), "carts")
CALENDAR_JSON = os.path.join(DATA_DIR, "calendar.json")
REMOTE_JSON = os.path.join(DATA_DIR, "remote.json")
# Sync times and errors change on every run; events usually don't. Keeping
# them apart means an unchanged sync leaves the big event file untouched, so
# the shell doesn't reload and re-index it.
STATUS_JSON = os.path.join(DATA_DIR, "remote-status.json")
STATUS_KEYS = ("syncedAt", "error", "failedAt")
CONTACTS_JSON = os.path.join(DATA_DIR, "contacts.json")
PARALLEL = 4
LOCK = os.path.join(DATA_DIR, ".sync.lock")
SERVICE = "carts"
PAST_DAYS = 120
FUTURE_DAYS = 400

NS = {"d": "DAV:", "c": "urn:ietf:params:xml:ns:caldav", "a": "http://apple.com/ns/ical/", "cs": "http://calendarserver.org/ns/",
      "card": "urn:ietf:params:xml:ns:carddav"}

PROVIDERS = {
    "icloud": "https://caldav.icloud.com/",
    "fastmail": "https://caldav.fastmail.com/",
    "nextcloud": "",
    "caldav": "",
}
CARD_PROVIDERS = {
    "icloud": "https://contacts.icloud.com/",
    "fastmail": "https://carddav.fastmail.com/",
}


# --------------------------------------------------------------------------
# Secrets
# --------------------------------------------------------------------------

def secret_get(key: str) -> str | None:
    try:
        r = subprocess.run(["secret-tool", "lookup", "service", SERVICE, "key", key],
                           capture_output=True, text=True, timeout=30)
    except FileNotFoundError:
        raise Failure("secret-tool not found (install libsecret)")
    except subprocess.TimeoutExpired:
        raise Failure("Keyring did not answer (is it locked?)")
    return r.stdout if r.returncode == 0 and r.stdout else None


def secret_set(key: str, value: str, label: str):
    try:
        r = subprocess.run(["secret-tool", "store", f"--label={label}", "service", SERVICE, "key", key],
                           input=value, capture_output=True, text=True, timeout=60)
    except FileNotFoundError:
        raise Failure("secret-tool not found (install libsecret)")
    except subprocess.TimeoutExpired:
        raise Failure("Keyring did not answer (is it locked?)")
    if r.returncode != 0:
        raise Failure("Could not save to the keyring: " + (r.stderr.strip() or "unknown error"))


def secret_clear(key: str):
    try:
        subprocess.run(["secret-tool", "clear", "service", SERVICE, "key", key], capture_output=True, timeout=30)
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass


# --------------------------------------------------------------------------
# HTTP
# --------------------------------------------------------------------------

# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------

def load_config():
    try:
        with open(CALENDAR_JSON, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return {"calendars": [], "accounts": []}
    except json.JSONDecodeError as e:
        raise Failure(f"calendar.json is not valid JSON: {e}")


def calendar_by_id(cfg, cal_id):
    for c in cfg.get("calendars", []):
        if c.get("id") == cal_id:
            return c
    raise Failure("Unknown calendar")


def account_by_id(cfg, acc_id):
    for a in cfg.get("accounts", []):
        if a.get("id") == acc_id:
            return a
    raise Failure("Account for this calendar is missing")


_auth_cache = {}
_auth_lock = threading.Lock()   # one keyring prompt at a time when fetching in parallel


def account_auth(acc):
    """(username, password), asking the keyring once per account per run."""
    key = acc["id"]
    with _auth_lock:
        return _account_auth_locked(acc, key)


def _account_auth_locked(acc, key):
    if key not in _auth_cache:
        pw = secret_get("account:" + key)
        if pw is None:
            raise Failure("No password in the keyring for this account; edit the calendar and reconnect")
        _auth_cache[key] = (acc.get("username", ""), pw)
    return _auth_cache[key]


def _load_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
            if isinstance(data, dict) and isinstance(data.get("calendars"), dict):
                return data
    except (FileNotFoundError, json.JSONDecodeError):
        pass
    return {"version": 1, "calendars": {}}


def _save_json(path, data):
    os.makedirs(DATA_DIR, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=DATA_DIR, prefix=".remote.", suffix=".json")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, separators=(",", ":"), ensure_ascii=False)
        f.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def load_remote():
    """Event cache. Older files kept sync status in here; move it out."""
    data = _load_json(REMOTE_JSON)
    status = load_status()
    for cid, entry in data["calendars"].items():
        old = {k: entry.pop(k) for k in STATUS_KEYS if k in entry}
        if old:
            data["_migrated"] = True
            status["calendars"].setdefault(cid, old)
    data["_status"] = status
    return data


def save_remote(data):
    _save_json(REMOTE_JSON, data)


def load_status():
    return _load_json(STATUS_JSON)


def save_status(data):
    _save_json(STATUS_JSON, data)


class Locked:
    def __enter__(self):
        os.makedirs(DATA_DIR, mode=0o700, exist_ok=True)
        self.f = open(LOCK, "w")
        fcntl.flock(self.f, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc):
        fcntl.flock(self.f, fcntl.LOCK_UN)
        self.f.close()


def window():
    now = datetime.now().astimezone()
    return now - timedelta(days=PAST_DAYS), now + timedelta(days=FUTURE_DAYS)


# --------------------------------------------------------------------------
# ICS subscriptions
# --------------------------------------------------------------------------

def _today():
    return datetime.now().astimezone().date().isoformat()


class NotModified(Exception):
    """The source has not changed since the cached copy; keep its events."""


def fetch_ics(cal, prev=None):
    """-> (events, cache fields). Raises NotModified on a 304.

    Validators are only sent when the cached events were expanded for today's
    window: the window moves daily, and repeating events need re-expanding.
    """
    prev = prev or {}
    url = secret_get("ics:" + cal["id"])
    if not url:
        raise Failure("No link stored in the keyring for this calendar; edit it and paste the link again")
    url = url.strip()
    if url.lower().startswith("webcal://"):
        url = "https://" + url[9:]
    _check_url(url)
    hdrs = {"Accept": "text/calendar, */*"}
    if prev.get("window") == _today():
        if prev.get("etag"):
            hdrs["If-None-Match"] = prev["etag"]
        if prev.get("lastModified"):
            hdrs["If-Modified-Since"] = prev["lastModified"]
    status, headers, body = http("GET", url, headers=hdrs)
    if status == 304 and len(hdrs) > 1:
        raise NotModified()
    if status == 404:
        raise Failure("Link not found (404); it may have been reset or unpublished")
    if status in (401, 403):
        raise Failure(f"Link refused ({status}); it may have been reset or made private")
    if status >= 400:
        raise Failure(f"Server error {status}")
    text = _decode(body)
    if "BEGIN:VCALENDAR" not in text[:4096].upper():
        raise Failure("That link did not return a calendar (got a web page?); use the iCal/ICS address")
    ws, we = window()
    h = {k.lower(): v for k, v in headers.items()}
    cache = {k: v for k, v in (("etag", h.get("etag")), ("lastModified", h.get("last-modified"))) if v}
    return ical.events_from_text(text, cal["id"], ws, we, {"readOnly": True}), cache


# --------------------------------------------------------------------------
# CalDAV
# --------------------------------------------------------------------------

def _xml(body: bytes):
    try:
        return ET.fromstring(body)
    except ET.ParseError:
        raise Failure("Server sent a response that is not valid XML")


def propfind(url, auth, props_xml, depth="0"):
    body = f'<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:a="http://apple.com/ns/ical/" xmlns:cs="http://calendarserver.org/ns/" xmlns:card="urn:ietf:params:xml:ns:carddav"><d:prop>{props_xml}</d:prop></d:propfind>'
    status, _, resp = http("PROPFIND", url, body, {"Depth": depth, "Content-Type": "application/xml; charset=utf-8"}, auth)
    if status == 401:
        raise Failure("Sign-in failed: check the username and app-specific password")
    if status == 403:
        raise Failure("The server refused access (403)")
    if status not in (207, 200):
        raise Failure(f"Server answered {status} to PROPFIND")
    return _xml(resp)


def _href_of(root, path):
    el = root.find(path, NS)
    return el.text.strip() if el is not None and el.text else None


def discover(provider, server, username, password):
    base = (server or PROVIDERS.get(provider, "")).strip()
    if not base:
        raise Failure("Enter the server address")
    if "://" not in base:
        base = "https://" + base
    if not base.endswith("/"):
        base += "/"
    _check_url(base)
    auth = (username, password)

    principal = None
    tried = []
    for cand in (base, urllib.parse.urljoin(base, "/.well-known/caldav")):
        try:
            root = propfind(cand, auth, "<d:current-user-principal/>")
        except Failure as e:
            if "Sign-in failed" in str(e):
                raise
            tried.append(str(e))
            continue
        href = _href_of(root, ".//d:current-user-principal/d:href")
        if href:
            principal = urllib.parse.urljoin(cand, href)
            break
    if not principal:
        raise Failure("Could not find a CalDAV account at that address" + (f" ({tried[-1]})" if tried else ""))

    root = propfind(principal, auth, "<c:calendar-home-set/>")
    home = _href_of(root, ".//c:calendar-home-set/d:href")
    if not home:
        raise Failure("Server did not say where the calendars are (no calendar-home-set)")
    home = urllib.parse.urljoin(principal, home)

    root = propfind(home, auth, "<d:resourcetype/><d:displayname/><a:calendar-color/>"
                                "<c:supported-calendar-component-set/><d:current-user-privilege-set/>", depth="1")
    out = []
    for resp in root.findall("d:response", NS):
        href = _href_of(resp, "d:href")
        ok = None
        for ps in resp.findall("d:propstat", NS):
            st = ps.find("d:status", NS)
            if st is not None and " 200 " in (st.text or "") + " ":
                ok = ps.find("d:prop", NS)
        if ok is None or href is None:
            continue
        rt = ok.find("d:resourcetype", NS)
        if rt is None or rt.find("c:calendar", NS) is None:
            continue
        comps = ok.find("c:supported-calendar-component-set", NS)
        if comps is not None and len(comps) and not any(c.get("name", "").upper() == "VEVENT" for c in comps):
            continue  # reminders/tasks lists
        name_el = ok.find("d:displayname", NS)
        color_el = ok.find("a:calendar-color", NS)
        privs = ok.find("d:current-user-privilege-set", NS)
        read_only = False
        if privs is not None and len(privs):
            names = {child.tag.split("}")[-1] for p in privs.findall("d:privilege", NS) for child in p}
            read_only = not ({"write", "write-content", "all", "bind"} & names)
        color = (color_el.text or "").strip()[:7] if color_el is not None and color_el.text else ""
        cal_url = urllib.parse.urljoin(home, href)
        try:
            _check_url(cal_url)
        except Failure:
            continue
        out.append({
            "url": cal_url,
            "name": (name_el.text or "").strip() if name_el is not None and name_el.text else href.rstrip("/").split("/")[-1],
            "color": color,
            "readOnly": read_only,
        })
    if not out:
        raise Failure("Signed in, but found no event calendars")
    return out


def caldav_report(url, auth):
    ws, we = window()
    fmt = lambda d: d.astimezone(timezone.utc).strftime("%Y%m%dT%H%M%SZ")  # noqa: E731
    body = ('<?xml version="1.0" encoding="utf-8"?>'
            '<c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">'
            '<d:prop><d:getetag/><c:calendar-data/></d:prop>'
            '<c:filter><c:comp-filter name="VCALENDAR"><c:comp-filter name="VEVENT">'
            f'<c:time-range start="{fmt(ws)}" end="{fmt(we)}"/>'
            '</c:comp-filter></c:comp-filter></c:filter></c:calendar-query>')
    status, _, resp = http("REPORT", url, body, {"Depth": "1", "Content-Type": "application/xml; charset=utf-8"}, auth)
    if status == 401:
        raise Failure("Sign-in failed: the app-specific password may have been revoked")
    if status == 404:
        raise Failure("Calendar no longer exists on the server")
    if status not in (207, 200):
        raise Failure(f"Server answered {status} to REPORT")
    root = _xml(resp)
    items = []
    for r in root.findall("d:response", NS):
        href = _href_of(r, "d:href")
        etag = _href_of(r, ".//d:getetag")
        data_el = r.find(".//c:calendar-data", NS)
        if href and data_el is not None and data_el.text:
            full = urllib.parse.urljoin(url, href)
            # Only objects inside this collection: a server must not be able
            # to point later edits/deletes (with our password) elsewhere.
            if _owned(url, full):
                items.append((full, etag, data_el.text))
    return items


def collection_tag(url, auth):
    """The collection's change tag (CalendarServer ctag or DAV sync-token), or "".

    Any change to any event in the calendar changes it, so an equal tag means
    the REPORT would return what we already have.
    """
    try:
        root = propfind(url, auth, "<cs:getctag/><d:sync-token/>")
    except Failure:
        return ""
    ctag = _href_of(root, ".//cs:getctag") or ""
    token = _href_of(root, ".//d:sync-token") or ""
    return (ctag + "|" + token) if (ctag or token) else ""


def _caldav_events(cal_id, src, items):
    ws, we = window()
    events = []
    for href, etag, text in items:
        extra = {"href": href, "etag": etag or "", "readOnly": bool(src.get("readOnly"))}
        events.extend(ical.events_from_text(text, cal_id, ws, we, extra))
    return events


def fetch_caldav(cfg, cal, prev=None):
    """-> (events, cache fields). Raises NotModified when the ctag is unchanged."""
    prev = prev or {}
    src = cal.get("source", {})
    acc = account_by_id(cfg, src.get("accountId"))
    auth = account_auth(acc)
    tag = collection_tag(src["url"], auth)
    if tag and tag == prev.get("ctag") and prev.get("window") == _today():
        raise NotModified()
    events = _caldav_events(cal["id"], src, caldav_report(src["url"], auth))
    return events, ({"ctag": tag} if tag else {})


def _fetch_one(cfg, cal, prev):
    """Fetch one calendar. -> (entry or None when unchanged, result, status)."""
    kind = cal.get("source", {}).get("type")
    now = int(time.time())
    try:
        events, cache = fetch_ics(cal, prev) if kind == "ics" else fetch_caldav(cfg, cal, prev)
        # Servers list events in any order (Google shuffles its feeds on
        # every request); a stable order lets an unchanged feed compare equal.
        events.sort(key=lambda e: (e.get("start", ""), e.get("uid", "")))
        entry = dict(cache, events=events, window=_today())
        return entry, {"ok": True, "count": len(events)}, {"syncedAt": now, "error": ""}
    except NotModified:
        return None, {"ok": True, "count": len(prev.get("events", [])), "unchanged": True}, {"syncedAt": now, "error": ""}
    except Failure as e:
        err = str(e)
    except Exception as e:  # keep one bad feed from breaking the rest
        err = f"Unexpected error: {e.__class__.__name__}: {e}"
    return None, {"ok": False, "error": err}, {"error": err, "failedAt": now}


def sync(ids=None):
    """Fetch remote calendars (in parallel); write remote.json only on change.

    -> {"ok", "changed", "results": {cal_id: {...}}}. "changed" false means
    remote.json was not rewritten (remote-status.json always is).
    """
    cfg = load_config()
    results = {}
    with Locked():
        remote = load_remote()
        status = remote.pop("_status")
        migrated = remote.pop("_migrated", False)
        before = json.dumps(remote, sort_keys=True)
        known = {c["id"] for c in cfg.get("calendars", [])}
        for store in (remote["calendars"], status["calendars"]):
            for stale in [k for k in store if k not in known]:
                del store[stale]
        todo = [c for c in cfg.get("calendars", [])
                if c.get("source", {}).get("type") in ("ics", "caldav") and (not ids or c["id"] in ids)]
        with concurrent.futures.ThreadPoolExecutor(max_workers=PARALLEL) as pool:
            futures = {c["id"]: pool.submit(_fetch_one, cfg, c, remote["calendars"].get(c["id"], {})) for c in todo}
        for cal in todo:   # merge in config order, on this thread
            entry, result, st = futures[cal["id"]].result()
            results[cal["id"]] = result
            if entry is not None:
                remote["calendars"][cal["id"]] = entry
            else:
                remote["calendars"].setdefault(cal["id"], {"events": []})
            prev = status["calendars"].get(cal["id"], {})
            status["calendars"][cal["id"]] = dict(prev, **st) if not result["ok"] else st
        changed = json.dumps(remote, sort_keys=True) != before
        if changed or migrated or not os.path.exists(REMOTE_JSON):
            save_remote(remote)
        save_status(status)
    return {"ok": all(r["ok"] for r in results.values()), "changed": changed, "results": results}


def _refresh_href(cal_id, src, auth, href, gone=False):
    """Update just one object in the cache after our own PUT/DELETE.

    The calendar's ctag is dropped (it changed on the server, and other
    changes may have landed too), so the next sync does a full REPORT.
    """
    events = []
    if not gone:
        status, headers, body = http("GET", href, headers={"Accept": "text/calendar"}, auth=auth)
        if status >= 400:
            raise Failure(f"Could not read the event back ({status})")
        etag = headers.get("ETag") or headers.get("Etag") or ""
        events = _caldav_events(cal_id, src, [(href, etag, _decode(body))])
    with Locked():
        remote = load_remote()
        status = remote.pop("_status")
        remote.pop("_migrated", None)
        entry = remote["calendars"].setdefault(cal_id, {"events": []})
        entry["events"] = [e for e in entry.get("events", []) if e.get("href") != href] + events
        entry.pop("ctag", None)
        save_remote(remote)
        status["calendars"][cal_id] = {"syncedAt": int(time.time()), "error": ""}
        save_status(status)
    return {"ok": True, "changed": True, "results": {cal_id: {"ok": True, "count": len(entry["events"])}}}


def _refresh_after_write(cal_id, src, auth, href, gone=False):
    try:
        return _refresh_href(cal_id, src, auth, href, gone)
    except Exception:  # anything odd: fall back to a full sync of this calendar
        return sync([cal_id])


def _caldav_target(cfg, cal_id):
    cal = calendar_by_id(cfg, cal_id)
    src = cal.get("source", {})
    if src.get("type") != "caldav":
        raise Failure("Not a CalDAV calendar")
    if src.get("readOnly"):
        raise Failure("This calendar is read-only on the server")
    acc = account_by_id(cfg, src.get("accountId"))
    return cal, src, account_auth(acc)


def _get_object(href, auth):
    status, headers, body = http("GET", href, headers={"Accept": "text/calendar"}, auth=auth)
    if status == 404:
        raise Failure("This event was deleted on the server")
    if status >= 400:
        raise Failure(f"Could not load the event from the server ({status})")
    return _decode(body), headers.get("ETag") or headers.get("Etag") or ""


def _write(method, href, text, auth, etag=None, create=False):
    hdrs = {"Content-Type": "text/calendar; charset=utf-8"} if text is not None else {}
    if create:
        hdrs["If-None-Match"] = "*"
    elif etag:
        hdrs["If-Match"] = etag
    status, _, _ = http(method, href, text, hdrs, auth)
    if status == 412:
        raise Failure("The event changed on the server since the last sync; sync and try again")
    if status == 401:
        raise Failure("Sign-in failed: the app-specific password may have been revoked")
    if status >= 400 and not (method == "DELETE" and status == 404):
        raise Failure(f"Server refused the change ({status})")


def _new_href(src):
    uid = str(uuid.uuid4()).upper()
    return uid, src["url"].rstrip("/") + "/" + uid + ".ics"


def _series_target(cfg, cal_id, ev):
    """(src, auth, href, key) for an occurrence of a synced series."""
    cal, src, auth = _caldav_target(cfg, cal_id)
    href = ev.get("href")
    if not href or not _owned(src["url"], href):
        raise Failure("Event has no server address in this calendar; sync and try again")
    key = ev.get("recurrenceId") or ""
    if not key:
        raise Failure("Not an occurrence of a repeating event")
    return src, auth, href, key


def put_event(cal_id, ev, scope=None):
    cfg = load_config()
    cal, src, auth = _caldav_target(cfg, cal_id)
    # An href is only meaningful on the calendar it came from; an event moved
    # here from another calendar is created fresh.
    href = ev.get("href") if _owned(src["url"], ev.get("href")) else None
    if href and ev.get("recurring"):
        if scope not in ("this", "following", "all"):
            raise Failure("Choose which events of the series to change")
        src, auth, href, key = _series_target(cfg, cal_id, ev)
        original, etag = _get_object(href, auth)
        try:
            if scope == "this":
                _write("PUT", href, series.edit_this(original, key, ev), auth, etag)
            elif scope == "all":
                _write("PUT", href, series.edit_all(original, key, ev), auth, etag)
            else:
                uid, new_href = _new_href(src)
                old_text, new_text = series.split(original, key, ev, uid)
                _write("PUT", new_href, new_text, auth, create=True)
                if old_text is None:
                    _write("DELETE", href, None, auth, etag)
                else:
                    _write("PUT", href, old_text, auth, etag)
                _refresh_after_write(cal_id, src, auth, new_href)
                return _refresh_after_write(cal_id, src, auth, href, gone=old_text is None)
        except (ValueError, KeyError) as e:
            raise Failure(f"Could not change the series: {e}")
        return _refresh_after_write(cal_id, src, auth, href)
    if href:
        original, etag = _get_object(href, auth)
        if ical.is_recurring_text(original):
            raise Failure("Choose which events of the series to change")
        text = ical.edit_vcalendar(original, ev)
        if ev.get("rrule"):
            text = series.add_rule(text, ev["rrule"])
        _write("PUT", href, text, auth, etag or ev.get("etag"))
    else:
        uid, href = _new_href(src)
        _write("PUT", href, series.new_vcalendar(ev, uid), auth, create=True)
    return _refresh_after_write(cal_id, src, auth, href)


def delete_event(cal_id, ev, scope=None):
    cfg = load_config()
    cal, src, auth = _caldav_target(cfg, cal_id)
    href = ev.get("href")
    if not href:
        raise Failure("Event has no server address; sync and try again")
    if not _owned(src["url"], href):
        raise Failure("Event address is outside this calendar; refusing to delete it")
    if ev.get("recurring") and scope in ("this", "following"):
        src, auth, href, key = _series_target(cfg, cal_id, ev)
        original, etag = _get_object(href, auth)
        try:
            if scope == "this":
                _write("PUT", href, series.delete_this(original, key), auth, etag)
                return _refresh_after_write(cal_id, src, auth, href)
            text, _ = series.end_before(original, key)
        except (ValueError, KeyError) as e:
            raise Failure(f"Could not change the series: {e}")
        if text is not None:
            _write("PUT", href, text, auth, etag)
            return _refresh_after_write(cal_id, src, auth, href)
    elif ev.get("recurring") and scope != "all":
        raise Failure("Choose which events of the series to delete")
    _write("DELETE", href, None, auth, None if ev.get("recurring") else ev.get("etag"))
    return _refresh_after_write(cal_id, src, auth, href, gone=True)


def get_series(cal_id, ev):
    cfg = load_config()
    src, auth, href, _ = _series_target(cfg, cal_id, ev)
    text, _ = _get_object(href, auth)
    try:
        return {"series": series.series_record(text)}
    except ValueError as e:
        raise Failure(f"Could not read the series: {e}")


def copy_series(cal_id, ev, to_cal_id):
    cfg = load_config()
    _, _, href, _ = _series_target(cfg, cal_id, ev)
    _, src, auth = _caldav_target(cfg, cal_id)
    text, _ = _get_object(href, auth)
    _, to_src, to_auth = _caldav_target(cfg, to_cal_id)
    # Same UID on the new calendar: the object is the same event, moved.
    uid_prop = series.master_of(series.parse_tree(text)).prop("UID")
    name = uid_prop.value.strip() if uid_prop is not None else str(uuid.uuid4()).upper()
    safe = "".join(ch for ch in name if ch.isalnum() or ch in "-_.@") or str(uuid.uuid4()).upper()
    new_href = to_src["url"].rstrip("/") + "/" + urllib.parse.quote(safe) + ".ics"
    _write("PUT", new_href, text, to_auth, create=True)
    return _refresh_after_write(to_cal_id, to_src, to_auth, new_href)


# --------------------------------------------------------------------------
# CardDAV (contacts)
# --------------------------------------------------------------------------

def _principal(base, auth, well_known="/.well-known/carddav"):
    tried = []
    for cand in (base, urllib.parse.urljoin(base, well_known)):
        try:
            root = propfind(cand, auth, "<d:current-user-principal/>")
        except Failure as e:
            if "Sign-in failed" in str(e):
                raise
            tried.append(str(e))
            continue
        href = _href_of(root, ".//d:current-user-principal/d:href")
        if href:
            return urllib.parse.urljoin(cand, href)
    raise Failure("Could not find an account at that address" + (f" ({tried[-1]})" if tried else ""))


def discover_books(server, username, password):
    base = (server or "").strip()
    if not base:
        raise Failure("Enter the server address")
    if "://" not in base:
        base = "https://" + base
    if not base.endswith("/"):
        base += "/"
    _check_url(base)
    auth = (username, password)
    principal = _principal(base, auth)
    root = propfind(principal, auth, "<card:addressbook-home-set/>")
    home = _href_of(root, ".//card:addressbook-home-set/d:href")
    if not home:
        raise Failure("This account has no address books (no addressbook-home-set)")
    home = urllib.parse.urljoin(principal, home)
    root = propfind(home, auth, "<d:resourcetype/><d:displayname/><d:current-user-privilege-set/>", depth="1")
    out = []
    for resp in root.findall("d:response", NS):
        href = _href_of(resp, "d:href")
        ok = None
        for ps in resp.findall("d:propstat", NS):
            st = ps.find("d:status", NS)
            if st is not None and " 200 " in (st.text or "") + " ":
                ok = ps.find("d:prop", NS)
        if ok is None or href is None:
            continue
        rt = ok.find("d:resourcetype", NS)
        if rt is None or rt.find("card:addressbook", NS) is None:
            continue
        name_el = ok.find("d:displayname", NS)
        privs = ok.find("d:current-user-privilege-set", NS)
        read_only = False
        if privs is not None and len(privs):
            names = {child.tag.split("}")[-1] for p in privs.findall("d:privilege", NS) for child in p}
            read_only = not ({"write", "write-content", "all", "bind"} & names)
        url = urllib.parse.urljoin(home, href)
        try:
            _check_url(url)
        except Failure:
            continue
        out.append({"url": url, "readOnly": read_only,
                    "name": (name_el.text or "").strip() if name_el is not None and name_el.text else href.rstrip("/").split("/")[-1]})
    if not out:
        raise Failure("Signed in, but found no address books")
    return out


def card_server(provider, server):
    """Where to look for address books. iCloud and Fastmail serve contacts
    from a different host than calendars, so a CalDAV account's stored
    server is no use there; elsewhere (Nextcloud, Radicale, ...) it is."""
    return CARD_PROVIDERS.get(provider) or server or ""


def contacts_discover(inp):
    if inp.get("password"):
        books = discover_books(card_server(inp.get("provider"), inp.get("server", "")),
                               inp.get("username", ""), inp["password"])
        if inp.get("accountId"):
            secret_set("account:" + inp["accountId"], inp["password"],
                       f"Cart's Tasks and Calendar: {inp.get('username', '')} (contacts)")
        return {"books": books}
    cfg = load_config()
    acc = account_by_id(cfg, inp.get("accountId"))
    user, password = account_auth(acc)
    return {"books": discover_books(card_server(acc.get("provider"), acc.get("server", "")), user, password)}


def book_by_id(cfg, book_id):
    for b in cfg.get("addressBooks", []):
        if b.get("id") == book_id:
            return b
    raise Failure("Unknown address book")


def load_contacts():
    try:
        with open(CONTACTS_JSON, encoding="utf-8") as f:
            data = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        data = {}
    if not isinstance(data, dict):
        data = {}
    if not isinstance(data.get("books"), dict):
        data["books"] = {}
    data.setdefault("version", 1)
    return data


def _book_report(url, auth):
    body = ('<?xml version="1.0" encoding="utf-8"?>'
            '<card:addressbook-query xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav">'
            '<d:prop><d:getetag/><card:address-data/></d:prop></card:addressbook-query>')
    status, _, resp = http("REPORT", url, body, {"Depth": "1", "Content-Type": "application/xml; charset=utf-8"}, auth)
    if status == 401:
        raise Failure("Sign-in failed: the password may have been changed")
    if status == 404:
        raise Failure("Address book no longer exists on the server")
    if status not in (207, 200):
        raise Failure(f"Server answered {status} to REPORT")
    root = _xml(resp)
    items = []
    for r in root.findall("d:response", NS):
        href = _href_of(r, "d:href")
        etag = _href_of(r, ".//d:getetag")
        data_el = r.find(".//card:address-data", NS)
        if href and data_el is not None and data_el.text:
            full = urllib.parse.urljoin(url, href)
            if _owned(url, full):
                items.append((full, etag or "", data_el.text))
    return items


def _book_records(book, items):
    out = []
    for href, etag, text in items:
        out += vcard.records(text, {"href": href, "etag": etag, "bookId": book["id"], "readOnly": bool(book.get("readOnly"))})
    out.sort(key=lambda c: (c.get("fn") or "").lower())
    return out


def contacts_sync(ids=None):
    cfg = load_config()
    books = [b for b in cfg.get("addressBooks", []) if not ids or b.get("id") in ids]
    results = {}
    with Locked():
        data = load_contacts()
        before = json.dumps(data, sort_keys=True)
        known = {b.get("id") for b in cfg.get("addressBooks", [])}
        for stale in [k for k in data["books"] if k not in known]:
            del data["books"][stale]
        now = int(time.time())
        for book in books:
            entry = data["books"].setdefault(book["id"], {"contacts": []})
            try:
                auth = account_auth(account_by_id(cfg, book.get("accountId")))
                tag = collection_tag(book["url"], auth)
                if not (tag and tag == entry.get("ctag")):
                    entry["contacts"] = _book_records(book, _book_report(book["url"], auth))
                    if tag:
                        entry["ctag"] = tag
                entry.update(syncedAt=now, error="")
                results[book["id"]] = {"ok": True, "count": len(entry["contacts"])}
            except Failure as e:
                entry.update(error=str(e), failedAt=now)
                results[book["id"]] = {"ok": False, "error": str(e)}
            except Exception as e:  # one bad book must not break the rest
                entry.update(error=f"Unexpected error: {e.__class__.__name__}: {e}", failedAt=now)
                results[book["id"]] = {"ok": False, "error": entry["error"]}
        if json.dumps(data, sort_keys=True) != before or not os.path.exists(CONTACTS_JSON):
            _save_json(CONTACTS_JSON, data)
    return {"ok": all(r["ok"] for r in results.values()), "results": results}


def _book_target(cfg, book_id):
    book = book_by_id(cfg, book_id)
    if book.get("readOnly"):
        raise Failure("This address book is read-only on the server")
    return book, account_auth(account_by_id(cfg, book.get("accountId")))


def _refresh_contact(book, auth, href, gone=False):
    recs = []
    if not gone:
        status, headers, body = http("GET", href, headers={"Accept": "text/vcard"}, auth=auth)
        if status >= 400:
            raise Failure(f"Could not read the contact back ({status})")
        recs = _book_records(book, [(href, headers.get("ETag") or headers.get("Etag") or "", _decode(body))])
    with Locked():
        data = load_contacts()
        entry = data["books"].setdefault(book["id"], {"contacts": []})
        entry["contacts"] = sorted([c for c in entry.get("contacts", []) if c.get("href") != href] + recs,
                                   key=lambda c: (c.get("fn") or "").lower())
        entry.pop("ctag", None)
        _save_json(CONTACTS_JSON, data)
    return {"ok": True, "contact": recs[0] if recs else None}


def contact_put(book_id, contact):
    cfg = load_config()
    book, auth = _book_target(cfg, book_id)
    href = contact.get("href") if _owned(book["url"], contact.get("href")) else None
    if href:
        status, headers, body = http("GET", href, headers={"Accept": "text/vcard"}, auth=auth)
        if status == 404:
            raise Failure("This contact was deleted on the server")
        if status >= 400:
            raise Failure(f"Could not load the contact ({status})")
        text = vcard.edit_vcard(_decode(body), contact)
        etag = headers.get("ETag") or headers.get("Etag") or contact.get("etag")
        hdrs = {"Content-Type": "text/vcard; charset=utf-8"}
        if etag:
            hdrs["If-Match"] = etag
    else:
        uid = str(uuid.uuid4()).upper()
        href = book["url"].rstrip("/") + "/" + uid + ".vcf"
        text = vcard.new_vcard(contact, uid)
        hdrs = {"Content-Type": "text/vcard; charset=utf-8", "If-None-Match": "*"}
    status, _, _ = http("PUT", href, text, hdrs, auth)
    if status == 412:
        raise Failure("The contact changed on the server since the last sync; sync and try again")
    if status == 401:
        raise Failure("Sign-in failed: the password may have been changed")
    if status >= 400:
        raise Failure(f"Server refused the change ({status})")
    return _refresh_contact(book, auth, href)


def contact_delete(book_id, contact):
    cfg = load_config()
    book, auth = _book_target(cfg, book_id)
    href = contact.get("href")
    if not href or not _owned(book["url"], href):
        raise Failure("Contact address is outside this address book; refusing to delete it")
    hdrs = {"If-Match": contact["etag"]} if contact.get("etag") else {}
    status, _, _ = http("DELETE", href, None, hdrs, auth)
    if status == 412:
        raise Failure("The contact changed on the server since the last sync; sync and try again")
    if status >= 400 and status != 404:
        raise Failure(f"Server refused the delete ({status})")
    return _refresh_contact(book, auth, href, gone=True)


def forget(cal_ids, secret_keys, book_ids=None):
    for k in secret_keys or []:
        secret_clear(k)
    with Locked():
        remote = load_remote()
        status = remote.pop("_status")
        remote.pop("_migrated", None)
        for c in cal_ids or []:
            remote["calendars"].pop(c, None)
            status["calendars"].pop(c, None)
        save_remote(remote)
        save_status(status)
        if book_ids:
            data = load_contacts()
            for b in book_ids:
                data["books"].pop(b, None)
            _save_json(CONTACTS_JSON, data)
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
            inp = read_input()
            cals = discover(inp.get("provider", "caldav"), inp.get("server", ""), inp.get("username", ""), inp.get("password", ""))
            if inp.get("accountId"):
                secret_set("account:" + inp["accountId"], inp.get("password", ""),
                           f"Cart's Tasks and Calendar: {inp.get('username', '')} ({inp.get('provider', 'caldav')})")
            out = {"ok": True, "calendars": cals,
                   "server": (inp.get("server") or PROVIDERS.get(inp.get("provider"), ""))}
        elif cmd == "set-secret":
            inp = read_input()
            secret_set(inp["key"], inp["value"], inp.get("label") or "Cart's Tasks and Calendar")
            out = {"ok": True}
        elif cmd == "forget":
            inp = read_input()
            out = forget(inp.get("calendarIds"), inp.get("secretKeys"), inp.get("bookIds"))
        elif cmd == "contacts-discover":
            out = contacts_discover(read_input())
            out["ok"] = True
        elif cmd == "contacts-sync":
            out = contacts_sync(argv[1:] or None)
        elif cmd == "contact-put":
            inp = read_input()
            out = contact_put(inp["bookId"], inp["contact"])
        elif cmd == "contact-delete":
            inp = read_input()
            out = contact_delete(inp["bookId"], inp["contact"])
        elif cmd == "zones":
            inp = read_input()
            names = [n for n in (inp.get("names") or []) if isinstance(n, str) and tzdata.valid(n)]
            local = ical.local_zone_name()
            if local and local not in names:
                names.append(local)
            out = {"ok": True, "local": local, "tables": {n: tzdata.table(n) for n in names[:40]}}
        elif cmd == "zone-list":
            out = {"ok": True, "zones": tzdata.all_zones()}
        elif cmd == "put":
            inp = read_input()
            out = put_event(inp["calendarId"], inp["event"], inp.get("scope"))
            out["ok"] = True
        elif cmd == "delete":
            inp = read_input()
            out = delete_event(inp["calendarId"], inp["event"], inp.get("scope"))
            out["ok"] = True
        elif cmd == "get-series":
            inp = read_input()
            out = get_series(inp["calendarId"], inp["event"])
            out["ok"] = True
        elif cmd == "copy-series":
            inp = read_input()
            out = copy_series(inp["calendarId"], inp["event"], inp["toCalendarId"])
            out["ok"] = True
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
