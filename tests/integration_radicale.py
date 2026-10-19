"""End-to-end test of sync/calsync.py against a real CalDAV server (Radicale)
and a local ICS feed. Uses a throwaway XDG_DATA_HOME; stores and then clears
test entries in the desktop keyring.

    pip install radicale   # in any venv
    <venv>/bin/python tests/integration_radicale.py
"""
import http.server
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CALSYNC = os.path.join(HERE, "..", "sync", "calsync.py")
PY = "/usr/bin/python3"  # the helper must work on the system python, without the venv

tmp = tempfile.mkdtemp(prefix="calsync-it-")
data_home = os.path.join(tmp, "data")
os.makedirs(os.path.join(data_home, "carts"))
env = dict(os.environ, XDG_DATA_HOME=data_home)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


# ---- Radicale
rport = free_port()
with open(os.path.join(tmp, "users"), "w") as f:
    f.write("alice:secret-pass\n")
conf = os.path.join(tmp, "radicale.conf")
with open(conf, "w") as f:
    f.write(f"""[server]
hosts = 127.0.0.1:{rport}
[auth]
type = htpasswd
htpasswd_filename = {tmp}/users
htpasswd_encryption = plain
[storage]
filesystem_folder = {tmp}/collections
[logging]
level = warning
""")
rad = subprocess.Popen([sys.executable, "-m", "radicale", "--config", conf], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

# ---- ICS feed
ics_dir = os.path.join(tmp, "www")
os.makedirs(ics_dir)
with open(os.path.join(ics_dir, "feed.ics"), "w") as f:
    f.write("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:feed-1\r\n"
            "DTSTART;VALUE=DATE:" + time.strftime("%Y%m%d") + "\r\nSUMMARY:Feed event\r\n"
            "RRULE:FREQ=WEEKLY;COUNT=3\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n")
with open(os.path.join(ics_dir, "page.html"), "w") as f:
    f.write("<html>login</html>")
hport = free_port()
handler = lambda *a, **k: http.server.SimpleHTTPRequestHandler(*a, directory=ics_dir, **k)  # noqa: E731
http.server.SimpleHTTPRequestHandler.log_message = lambda *a: None
httpd = http.server.ThreadingHTTPServer(("127.0.0.1", hport), handler)
threading.Thread(target=httpd.serve_forever, daemon=True).start()

base = f"http://127.0.0.1:{rport}/"
for _ in range(50):
    try:
        urllib.request.urlopen(base, timeout=1)
        break
    except Exception:
        time.sleep(0.1)


def run(*args, inp=None):
    r = subprocess.run([PY, CALSYNC, *args], input=(json.dumps(inp) + "\n") if inp is not None else "",
                       capture_output=True, text=True, env=env, timeout=120)
    assert r.returncode == 0, r.stderr
    return json.loads(r.stdout)


def write_cfg(cfg):
    with open(os.path.join(data_home, "carts", "calendar.json"), "w") as f:
        json.dump(cfg, f)


REMOTE = os.path.join(data_home, "carts", "remote.json")
STATUS = os.path.join(data_home, "carts", "remote-status.json")


def remote():
    with open(REMOTE) as f:
        return json.load(f)["calendars"]


def status():
    with open(STATUS) as f:
        return json.load(f)["calendars"]


ok = False
try:
    # Make a calendar collection for alice (Radicale creates the principal on first login).
    import base64
    auth = "Basic " + base64.b64encode(b"alice:secret-pass").decode()
    mk = ('<?xml version="1.0"?><c:mkcalendar xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" '
          'xmlns:a="http://apple.com/ns/ical/"><d:set><d:prop><d:displayname>Work</d:displayname>'
          '<a:calendar-color>#ff8800FF</a:calendar-color></d:prop></d:set></c:mkcalendar>')
    req = urllib.request.Request(base + "alice/work/", data=mk.encode(), method="MKCALENDAR",
                                 headers={"Authorization": auth, "Content-Type": "application/xml"})
    urllib.request.urlopen(req, timeout=5)

    bad = run("discover", inp={"provider": "caldav", "server": base, "username": "alice", "password": "nope"})
    assert not bad["ok"] and "Sign-in failed" in bad["error"], bad

    d = run("discover", inp={"provider": "caldav", "server": base, "username": "alice", "password": "secret-pass",
                             "accountId": "acc-it-test"})
    assert d["ok"], d
    work = [c for c in d["calendars"] if c["name"] == "Work"]
    assert work and work[0]["color"] == "#ff8800" and not work[0]["readOnly"], d
    print("discover ok:", [c["name"] for c in d["calendars"]])

    run("set-secret", inp={"key": "ics:cal-it-feed", "value": f"http://127.0.0.1:{hport}/feed.ics"})
    run("set-secret", inp={"key": "ics:cal-it-html", "value": f"http://127.0.0.1:{hport}/page.html"})
    cfg = {"version": 1,
           "accounts": [{"id": "acc-it-test", "provider": "caldav", "server": base, "username": "alice"}],
           "calendars": [
               {"id": "cal-it-work", "name": "Work", "color": "theme:blue",
                "source": {"type": "caldav", "accountId": "acc-it-test", "url": work[0]["url"]}},
               {"id": "cal-it-feed", "name": "Feed", "color": "theme:red", "source": {"type": "ics"}},
               {"id": "cal-it-html", "name": "Bad", "color": "theme:red", "source": {"type": "ics"}},
               {"id": "cal-local", "name": "Local", "color": "theme:green"}],
           "events": []}
    write_cfg(cfg)

    s = run("sync")
    assert s["results"]["cal-it-work"] == {"ok": True, "count": 0}, s
    assert s["results"]["cal-it-feed"]["count"] == 3, s
    assert not s["results"]["cal-it-html"]["ok"] and "did not return a calendar" in s["results"]["cal-it-html"]["error"]
    assert "cal-local" not in s["results"]
    feed = remote()["cal-it-feed"]["events"]
    assert all(e["readOnly"] and e["recurring"] for e in feed) and len({e["uid"] for e in feed}) == 3
    assert "syncedAt" not in remote()["cal-it-feed"] and status()["cal-it-feed"]["syncedAt"]
    assert "did not return a calendar" in status()["cal-it-html"]["error"]
    assert remote()["cal-it-feed"].get("lastModified") and remote()["cal-it-work"].get("ctag")
    print("ics ok")

    # Second sync: the feed answers 304, the CalDAV ctag is unchanged, so
    # remote.json is not rewritten; only the status file moves.
    mtime, st_before = os.stat(REMOTE).st_mtime_ns, status()["cal-it-feed"]["syncedAt"]
    time.sleep(1.1)
    s2 = run("sync")
    assert s2["changed"] is False, s2
    assert s2["results"]["cal-it-feed"].get("unchanged") and s2["results"]["cal-it-feed"]["count"] == 3, s2
    assert s2["results"]["cal-it-work"].get("unchanged"), s2
    assert os.stat(REMOTE).st_mtime_ns == mtime, "remote.json rewritten on an unchanged sync"
    assert status()["cal-it-feed"]["syncedAt"] > st_before
    # A changed feed is picked up (new Last-Modified, so no 304).
    with open(os.path.join(ics_dir, "feed.ics"), "w") as f:
        f.write("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:feed-2\r\n"
                "DTSTART;VALUE=DATE:" + time.strftime("%Y%m%d") + "\r\nSUMMARY:Changed\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n")
    s3 = run("sync", "cal-it-feed")
    assert s3["changed"] is True and s3["results"]["cal-it-feed"]["count"] == 1, s3
    assert remote()["cal-it-feed"]["events"][0]["title"] == "Changed"
    print("unchanged sync ok")

    day = time.strftime("%Y-%m-%d")
    p = run("put", inp={"calendarId": "cal-it-work", "event": {
        "uid": "ev-local-tmp", "calendarId": "cal-it-work", "title": "Planning, Q4", "allDay": False,
        "start": day + "T10:00", "end": day + "T11:30", "location": "Room 1", "notes": "bring\nnotes"}})
    assert p["ok"], p
    evs = remote()["cal-it-work"]["events"]
    assert len(evs) == 1 and evs[0]["title"] == "Planning, Q4" and evs[0]["start"] == day + "T10:00", evs
    assert evs[0]["end"] == day + "T11:30" and evs[0]["notes"] == "bring\nnotes" and evs[0]["href"] and evs[0]["etag"]
    assert not evs[0]["readOnly"]
    assert p["changed"] and "ctag" not in remote()["cal-it-work"], "put should refresh one href and drop the ctag"
    print("create ok")

    edited = dict(evs[0], title="Planning (moved)", start=day + "T14:00", end=day + "T15:00")
    p = run("put", inp={"calendarId": "cal-it-work", "event": edited})
    assert p["ok"], p
    evs2 = remote()["cal-it-work"]["events"]
    assert len(evs2) == 1 and evs2[0]["title"] == "Planning (moved)" and evs2[0]["start"] == day + "T14:00", evs2
    assert evs2[0]["etag"] != evs[0]["etag"] and evs2[0]["href"] == evs[0]["href"]
    print("edit ok")

    stale = run("put", inp={"calendarId": "cal-it-work", "event": dict(evs[0], title="stale")})
    # GET refreshes the etag before PUT, so a stale cached etag is not a conflict by itself;
    # the edit lands (last writer wins for our own edits).
    assert stale["ok"], stale

    dele = run("delete", inp={"calendarId": "cal-it-work", "event": remote()["cal-it-work"]["events"][0]})
    assert dele["ok"], dele
    assert remote()["cal-it-work"]["events"] == []
    print("delete ok")

    ro = run("put", inp={"calendarId": "cal-it-feed", "event": {"title": "x", "start": day, "end": day, "allDay": True}})
    assert not ro["ok"] and "Not a CalDAV" in ro["error"]

    # A full sync after our own writes matches the targeted refresh.
    s4 = run("sync", "cal-it-work")
    assert s4["ok"] and remote()["cal-it-work"]["events"] == [] and remote()["cal-it-work"].get("ctag"), s4

    # ---- Repeating events: create, this / following / all, move, delete.
    req = urllib.request.Request(base + "alice/home/", data=mk.replace("Work", "Home").encode(), method="MKCALENDAR",
                                 headers={"Authorization": auth, "Content-Type": "application/xml"})
    urllib.request.urlopen(req, timeout=5)
    cfg["calendars"].append({"id": "cal-it-home", "name": "Home", "color": "theme:green",
                             "source": {"type": "caldav", "accountId": "acc-it-test", "url": base + "alice/home/"}})
    write_cfg(cfg)
    from datetime import date as _date, timedelta as _td
    monday = _date.today() + _td(days=(7 - _date.today().weekday()) % 7 or 7)

    def occs(cal="cal-it-work"):
        return sorted(remote()[cal]["events"], key=lambda e: e["start"])

    p = run("put", inp={"calendarId": "cal-it-work", "event": {
        "calendarId": "cal-it-work", "title": "Standup", "allDay": False, "start": f"{monday}T09:00",
        "end": f"{monday}T09:15", "rrule": "FREQ=WEEKLY;COUNT=6"}})
    assert p["ok"], p
    o = occs()
    assert len(o) == 6 and all(e["recurring"] and e["recurrenceId"] and e["rrule"] == "FREQ=WEEKLY;COUNT=6" for e in o), o
    assert not any(e["readOnly"] for e in o) and len({e["href"] for e in o}) == 1
    assert all(e["start"].endswith("T09:00") for e in o)
    assert run("put", inp={"calendarId": "cal-it-work", "event": dict(o[1], title="x")})["ok"] is False   # scope required

    p = run("put", inp={"calendarId": "cal-it-work", "scope": "this", "event": dict(o[1], title="Standup (demo)")})
    assert p["ok"], p
    assert [e["title"] for e in occs()] == ["Standup", "Standup (demo)"] + ["Standup"] * 4, occs()

    p = run("delete", inp={"calendarId": "cal-it-work", "scope": "this", "event": occs()[2]})
    assert p["ok"] and len(occs()) == 5, (p, occs())

    o = occs()
    p = run("put", inp={"calendarId": "cal-it-work", "scope": "all", "event": dict(
        o[2], start=o[2]["start"][:11] + "10:00", end=o[2]["start"][:11] + "10:30")})
    assert p["ok"], p
    o = occs()
    assert len(o) == 5 and [e["start"][11:] for e in o] == ["10:00", "09:00", "10:00", "10:00", "10:00"], o
    assert o[1]["title"] == "Standup (demo)" and o[0]["end"][11:] == "10:30"

    p = run("put", inp={"calendarId": "cal-it-work", "scope": "following", "event": dict(o[3], title="Later")})
    assert p["ok"], p
    o = occs()
    assert [e["title"] for e in o] == ["Standup", "Standup (demo)", "Standup", "Later", "Later"], o
    assert len({e["href"] for e in o}) == 2 and o[3]["rrule"] == "FREQ=WEEKLY;COUNT=2", o

    # Move the "Later" series to Home: same object, other calendar.
    later = o[3]
    p = run("copy-series", inp={"calendarId": "cal-it-work", "event": later, "toCalendarId": "cal-it-home"})
    assert p["ok"], p
    p = run("delete", inp={"calendarId": "cal-it-work", "scope": "all", "event": later})
    assert p["ok"], p
    assert [e["title"] for e in occs()] == ["Standup", "Standup (demo)", "Standup"], occs()
    assert [e["title"] for e in occs("cal-it-home")] == ["Later", "Later"], occs("cal-it-home")

    g = run("get-series", inp={"calendarId": "cal-it-work", "event": occs()[0]})
    assert g["ok"] and g["series"]["rrule"].startswith("FREQ=WEEKLY;UNTIL=") and len(g["series"]["exdates"]) == 1, g
    assert list(g["series"]["overrides"].values())[0]["title"] == "Standup (demo)", g

    p = run("delete", inp={"calendarId": "cal-it-work", "scope": "following", "event": occs()[1]})
    assert p["ok"] and [e["title"] for e in occs()] == ["Standup"], (p, occs())
    p = run("delete", inp={"calendarId": "cal-it-work", "scope": "following", "event": occs()[0]})
    assert p["ok"] and occs() == [], (p, occs())
    p = run("delete", inp={"calendarId": "cal-it-home", "scope": "all", "event": occs("cal-it-home")[0]})
    assert p["ok"] and occs("cal-it-home") == []
    s5 = run("sync")
    assert remote()["cal-it-work"]["events"] == [] and remote()["cal-it-home"]["events"] == [], s5
    print("series ok")

    # ---- Contacts (CardDAV)
    mkab = ('<?xml version="1.0"?><d:mkcol xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav"><d:set><d:prop>'
            '<d:resourcetype><d:collection/><card:addressbook/></d:resourcetype><d:displayname>Contacts</d:displayname>'
            '</d:prop></d:set></d:mkcol>')
    req = urllib.request.Request(base + "alice/contacts/", data=mkab.encode(), method="MKCOL",
                                 headers={"Authorization": auth, "Content-Type": "application/xml"})
    urllib.request.urlopen(req, timeout=5)
    d = run("contacts-discover", inp={"accountId": "acc-it-test"})
    assert d["ok"] and [b["name"] for b in d["books"]] == ["Contacts"] and not d["books"][0]["readOnly"], d
    bad = run("contacts-discover", inp={"server": base, "username": "alice", "password": "wrong"})
    assert not bad["ok"] and "Sign-in failed" in bad["error"], bad
    cfg["addressBooks"] = [{"id": "ab-it", "name": "Contacts", "accountId": "acc-it-test", "url": d["books"][0]["url"]}]
    write_cfg(cfg)
    CONTACTS = os.path.join(data_home, "carts", "contacts.json")

    def people():
        with open(CONTACTS) as f:
            return json.load(f)["books"]["ab-it"]["contacts"]

    s6 = run("contacts-sync")
    assert s6["ok"] and s6["results"]["ab-it"]["count"] == 0, s6
    p = run("contact-put", inp={"bookId": "ab-it", "contact": {
        "given": "Mary", "family": "Garcia", "emails": [{"type": "home", "value": "m@example.com"}],
        "phones": [{"type": "cell", "value": "555-0100"}], "birthday": "1990-03-14", "notes": "a; b, c"}})
    assert p["ok"] and p["contact"]["fn"] == "Mary Garcia" and p["contact"]["href"], p
    assert len(people()) == 1 and people()[0]["notes"] == "a; b, c" and people()[0]["birthday"] == "1990-03-14"
    p = run("contact-put", inp={"bookId": "ab-it", "contact": dict(people()[0], given="Maria",
                                                                 phones=[{"type": "work", "value": "555-0200"}])})
    assert p["ok"] and people()[0]["fn"] == "Maria Garcia" and people()[0]["phones"] == [{"type": "work", "value": "555-0200"}], people()
    s7 = run("contacts-sync")
    assert s7["ok"] and len(people()) == 1 and people()[0]["given"] == "Maria", (s7, people())
    p = run("contact-delete", inp={"bookId": "ab-it", "contact": people()[0]})
    assert p["ok"] and people() == [], people()
    f = run("forget", inp={"calendarIds": [], "secretKeys": [], "bookIds": ["ab-it"]})
    with open(CONTACTS) as fh:
        assert "ab-it" not in json.load(fh)["books"]
    print("contacts ok")

    f = run("forget", inp={"calendarIds": ["cal-it-feed"], "secretKeys": ["ics:cal-it-feed"]})
    assert f["ok"] and "cal-it-feed" not in remote() and "cal-it-feed" not in status()
    print("forget ok")
    ok = True
finally:
    for key in ("account:acc-it-test", "ics:cal-it-feed", "ics:cal-it-html"):
        subprocess.run(["secret-tool", "clear", "service", "carts", "key", key])
    rad.terminate()
    httpd.shutdown()
    shutil.rmtree(tmp, ignore_errors=True)

print("integration tests passed" if ok else "integration tests FAILED")
sys.exit(0 if ok else 1)
