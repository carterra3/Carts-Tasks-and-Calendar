"""Unit tests for the security checks in sync/calsync.py (no network).

    python3 tests/test_calsync.py
"""
import io
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "sync"))
import calsync  # noqa: E402
from calsync import Failure, _check_url, _owned, _redirect_ok, _read_capped  # noqa: E402


def raises(fn, *args):
    try:
        fn(*args)
    except Failure:
        return True
    return False


# ---- Allowed address types
assert _check_url("https://caldav.icloud.com/")
assert _check_url("http://127.0.0.1:5232/")
assert _check_url("http://localhost/x")
assert raises(_check_url, "http://caldav.example.com/")
assert raises(_check_url, "file:///etc/passwd")
assert raises(_check_url, "ftp://example.com/cal.ics")
assert raises(_check_url, "https:///nohost")

# ---- Redirects carrying a password
ic = "https://caldav.icloud.com/"
assert _redirect_ok(ic, "https://p52-caldav.icloud.com/123/", True)
assert _redirect_ok(ic, "https://caldav.icloud.com/other", True)
assert _redirect_ok(ic, "https://icloud.com/x", True)
assert not _redirect_ok(ic, "https://evilicloud.com/", True)            # the old endswith() hole
assert not _redirect_ok(ic, "https://icloud.com.evil.net/", True)
assert not _redirect_ok(ic, "http://p52-caldav.icloud.com/", True)       # downgrade
assert not _redirect_ok(ic, "file:///etc/passwd", True)
assert _redirect_ok("https://icloud.com/", "https://p52-caldav.icloud.com/", True)
# Public suffixes do not vouch for their siblings
assert not _redirect_ok("https://cal.co.uk/", "https://evil.co.uk/", True)
assert not _redirect_ok("https://me.duckdns.org/", "https://evil.duckdns.org/", True)
assert _redirect_ok("https://me.duckdns.org/", "https://dav.me.duckdns.org/", True)
assert _redirect_ok("https://dav.example.co.uk/", "https://cal.example.co.uk/", True)
# IP addresses only match themselves
assert not _redirect_ok("https://192.168.1.5/", "https://10.168.1.5/", True)
assert _redirect_ok("http://127.0.0.1:5232/a", "http://127.0.0.1:5232/b", True)
# Without a password any https hop is fine (Google feed links redirect), still no downgrade
assert _redirect_ok("https://calendar.google.com/x.ics", "https://www.googleapis.com/y", False)
assert not _redirect_ok("https://calendar.google.com/x.ics", "http://example.com/y", False)

# ---- Event addresses must stay inside their calendar
cal = "https://dav.example.com/cal/"
assert _owned(cal, "https://dav.example.com/cal/abc.ics")
assert _owned("https://dav.example.com/cal", "https://dav.example.com/cal/abc.ics")
assert not _owned(cal, "https://dav.example.com/cal/")                  # the collection itself
assert not _owned("https://dav.example.com/cal", "https://dav.example.com/cal2/abc.ics")
assert not _owned(cal, "https://evil.example.net/cal/abc.ics")
assert not _owned(cal, "http://dav.example.com/cal/abc.ics")
assert not _owned(cal, "https://dav.example.com:8443/cal/abc.ics")
assert not _owned(cal, "https://dav.example.com/cal/../other/abc.ics")
assert not _owned(cal, None)
assert not _owned(cal, "https://dav.example.com/cal/..")                 # trailing dot segment
assert not _owned(cal, "https://dav.example.com/cal/%2e%2e")
assert not _owned(cal, "https://dav.example.com/cal/./x/..")
assert not _owned(cal, "https://dav.example.com/cal/%2e%2e%2fother/x.ics")

# ---- Response size cap
assert _read_capped(io.BytesIO(b"x" * 1000), 2000) == b"x" * 1000
assert raises(_read_capped, io.BytesIO(b"x" * 3000), 2000)

# ---- Wired in: REPORT drops foreign hrefs; delete refuses them
REPORT = b"""<?xml version="1.0"?><d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
<d:response><d:href>/cal/good.ics</d:href><d:propstat><d:prop><d:getetag>"1"</d:getetag>
<c:calendar-data>BEGIN:VCALENDAR</c:calendar-data></d:prop></d:propstat></d:response>
<d:response><d:href>https://evil.example.net/steal</d:href><d:propstat><d:prop><d:getetag>"2"</d:getetag>
<c:calendar-data>BEGIN:VCALENDAR</c:calendar-data></d:prop></d:propstat></d:response>
<d:response><d:href>/cal2/sneaky.ics</d:href><d:propstat><d:prop><d:getetag>"3"</d:getetag>
<c:calendar-data>BEGIN:VCALENDAR</c:calendar-data></d:prop></d:propstat></d:response>
</d:multistatus>"""
calls = []
real_http = calsync.http
calsync.http = lambda *a, **k: (calls.append(a) or (207, {}, REPORT))
items = calsync.caldav_report("https://dav.example.com/cal/", ("u", "p"))
assert [i[0] for i in items] == ["https://dav.example.com/cal/good.ics"], items

cfg = {"calendars": [{"id": "c", "source": {"type": "caldav", "accountId": "a", "url": "https://dav.example.com/cal/"}}],
       "accounts": [{"id": "a", "username": "u"}]}
calsync.load_config = lambda: cfg
calsync.secret_get = lambda key: "pw"
calls.clear()
try:
    calsync.delete_event("c", {"href": "https://evil.example.net/cal/x.ics", "etag": "1"})
    raise AssertionError("delete of a foreign href went through")
except Failure as e:
    assert "outside this calendar" in str(e)
assert calls == [], calls                                                 # nothing was sent
calsync.http = real_http


# ---- sync(): status split out, unchanged runs leave remote.json alone,
# failures keep cached events, old files migrate.
import json as _json
import tempfile as _tempfile
d = _tempfile.mkdtemp()
calsync.DATA_DIR, calsync.REMOTE_JSON = d, os.path.join(d, "remote.json")
calsync.STATUS_JSON, calsync.LOCK = os.path.join(d, "remote-status.json"), os.path.join(d, ".lock")
calsync.load_config = lambda: {"calendars": [
    {"id": "a", "source": {"type": "ics"}}, {"id": "b", "source": {"type": "ics"}}, {"id": "l", "source": {"type": "local"}}]}
with open(calsync.REMOTE_JSON, "w") as f:   # old format: status inline, plus a removed calendar
    _json.dump({"version": 1, "calendars": {"a": {"events": [{"uid": "old"}], "syncedAt": 5, "error": ""},
                                            "gone": {"events": [], "syncedAt": 1}}}, f)
feeds = {"a": ([{"uid": "a1"}], {}), "b": ([{"uid": "b1"}], {"etag": "\"x\""})}
def fake_fetch(cal, prev=None):
    v = feeds[cal["id"]]
    if isinstance(v, Exception):
        raise v
    return v
calsync.fetch_ics = fake_fetch
r1 = calsync.sync()
rem, st = _json.load(open(calsync.REMOTE_JSON)), _json.load(open(calsync.STATUS_JSON))
assert r1["ok"] and r1["changed"], r1
assert set(rem["calendars"]) == {"a", "b"} and set(st["calendars"]) == {"a", "b"}
assert "syncedAt" not in rem["calendars"]["a"] and st["calendars"]["a"]["syncedAt"] > 5
assert rem["calendars"]["b"]["etag"] == "\"x\"" and rem["calendars"]["b"]["window"]
assert open(calsync.REMOTE_JSON).read().count("\n") == 1                        # compact
os.utime(calsync.REMOTE_JSON, (1, 1))
feeds["b"] = ([{"uid": "b2", "start": "2026-01-02"}, {"uid": "b1", "start": "2026-01-01"}], {"etag": "\"x\""})
calsync.sync()
os.utime(calsync.REMOTE_JSON, (1, 1))
feeds["b"] = ([{"uid": "b1", "start": "2026-01-01"}, {"uid": "b2", "start": "2026-01-02"}], {"etag": "\"x\""})
r2 = calsync.sync()   # same events, different order (Google shuffles): unchanged
assert r2["changed"] is False and os.stat(calsync.REMOTE_JSON).st_mtime == 1, r2
feeds["b"] = calsync.Failure("boom")
r3 = calsync.sync()
st = _json.load(open(calsync.STATUS_JSON))["calendars"]
assert not r3["ok"] and r3["changed"] is False and os.stat(calsync.REMOTE_JSON).st_mtime == 1
assert st["b"]["error"] == "boom" and st["b"]["failedAt"] and st["b"]["syncedAt"]  # last good sync kept
assert [e["uid"] for e in _json.load(open(calsync.REMOTE_JSON))["calendars"]["b"]["events"]] == ["b1", "b2"]
feeds["b"] = calsync.NotModified()
r4 = calsync.sync(["b"])
assert r4["results"] == {"b": {"ok": True, "count": 2, "unchanged": True}} and r4["changed"] is False, r4
assert _json.load(open(calsync.STATUS_JSON))["calendars"]["b"]["error"] == ""
# A migrated file is rewritten once even when the events are the same.
with open(calsync.REMOTE_JSON, "w") as f:
    _json.dump({"version": 1, "calendars": {"a": {"events": [{"uid": "a1"}], "window": calsync._today(), "syncedAt": 9},
                                            "b": {"events": [{"uid": "b1"}], "etag": "\"x\"", "window": calsync._today()}}}, f)
feeds["b"] = ([{"uid": "b1"}], {"etag": "\"x\""})
calsync.sync()
assert "syncedAt" not in _json.load(open(calsync.REMOTE_JSON))["calendars"]["a"]

# ---- one keyring lookup per account per run
lookups = []
calsync.secret_get = lambda key: (lookups.append(key), "pw")[1]
calsync._auth_cache.clear()
for _ in range(5):
    assert calsync.account_auth({"id": "acc", "username": "u"}) == ("u", "pw")
assert lookups == ["account:acc"], lookups

# ---- address books live on a different host for some providers
assert calsync.card_server("icloud", "https://caldav.icloud.com/") == "https://contacts.icloud.com/"
assert calsync.card_server("fastmail", "https://caldav.fastmail.com/") == "https://carddav.fastmail.com/"
assert calsync.card_server("nextcloud", "https://c.example/remote.php/dav/") == "https://c.example/remote.php/dav/"
assert calsync.card_server(None, "https://dav.example/") == "https://dav.example/"

print("calsync tests passed")
