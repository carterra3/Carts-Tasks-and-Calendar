"""Recurrence + parsing tests for sync/ical.py.

Run with plain python3. If python-dateutil is importable, every rule is also
cross-checked against dateutil.rrule as an oracle:
    python3 tests/test_ical.py
"""
import os
import sys
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "sync"))
import ical  # noqa: E402

try:
    from dateutil import rrule as du
except ImportError:
    du = None

NY = ZoneInfo("America/New_York")
END = datetime(2028, 12, 31, tzinfo=NY)

RULES = [
    "FREQ=DAILY;COUNT=10",
    "FREQ=DAILY;INTERVAL=3;UNTIL=20270301T000000Z",
    "FREQ=WEEKLY;BYDAY=MO,WE,FR;COUNT=20",
    "FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,TH;UNTIL=20271231T235959Z",
    "FREQ=WEEKLY;INTERVAL=2;WKST=SU;BYDAY=TU,SU;COUNT=12",
    "FREQ=WEEKLY;COUNT=30",
    "FREQ=MONTHLY;BYDAY=2TU;COUNT=15",
    "FREQ=MONTHLY;BYDAY=-1FR;COUNT=15",
    "FREQ=MONTHLY;BYMONTHDAY=31;COUNT=10",
    "FREQ=MONTHLY;BYMONTHDAY=-1;COUNT=14",
    "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1;COUNT=12",
    "FREQ=MONTHLY;INTERVAL=3;COUNT=8",
    "FREQ=MONTHLY;BYDAY=FR;BYMONTHDAY=13;COUNT=5",
    "FREQ=YEARLY;COUNT=5",
    "FREQ=YEARLY;BYMONTH=11;BYDAY=4TH;COUNT=6",
    "FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU;COUNT=5",
    "FREQ=YEARLY;BYDAY=20MO;COUNT=4",
    "FREQ=YEARLY;BYMONTH=1,7;BYMONTHDAY=1;COUNT=6",
    "FREQ=DAILY;BYDAY=SA,SU;COUNT=9",
]

failures = 0


def check(name, got, want):
    global failures
    if got != want:
        failures += 1
        print(f"FAIL {name}\n  got  {got[:8]}... ({len(got)})\n  want {want[:8]}... ({len(want)})")


def ours(rule, dtstart, end=END):
    return list(ical.expand_rrule(dtstart, ical.parse_rrule(rule), end, False))


starts = [datetime(2026, 10, 16, 9, 30, tzinfo=NY), datetime(2027, 1, 31, 18, 0, tzinfo=NY)]
if du:
    for rule in RULES:
        for dtstart in starts:
            got = ours(rule, dtstart)
            naive = dtstart.replace(tzinfo=None)
            r = du.rrulestr(rule.replace("Z", ""), dtstart=naive) if "UNTIL" in rule else du.rrulestr(rule, dtstart=naive)
            want = []
            for occ in r:
                aware = occ.replace(tzinfo=NY)
                if aware > END:
                    break
                want.append(aware)
            if "UNTIL" in rule:  # dateutil compared naive; ours compares the real UTC instant
                until = datetime.strptime(rule.split("UNTIL=")[1][:15], "%Y%m%dT%H%M%S").replace(tzinfo=timezone.utc)
                want = [w for w in want if w <= until]
            check(f"{rule} @ {dtstart:%Y-%m-%d %H:%M}", got, want)
    print(f"oracle: {len(RULES) * len(starts)} rule/start pairs checked against dateutil")
else:
    print("dateutil not installed; skipping oracle comparison")

# DST: a weekly 09:30 New York meeting stays 09:30 local across the November change.
occ = ours("FREQ=WEEKLY;COUNT=4", datetime(2026, 10, 23, 9, 30, tzinfo=NY))
assert [o.hour for o in occ] == [9, 9, 9, 9], occ
assert occ[2].utcoffset() != occ[0].utcoffset()  # crossed Nov 1

# Full document: TZID, EXDATE, RECURRENCE-ID override, cancelled instance,
# all-day multi-day, Windows TZID, folded lines and escapes.
DOC = """BEGIN:VCALENDAR\r
VERSION:2.0\r
X-WR-TIMEZONE:America/Chicago\r
BEGIN:VEVENT\r
UID:weekly-1\r
DTSTART;TZID=America/New_York:20261019T100000\r
DTEND;TZID=America/New_York:20261019T103000\r
RRULE:FREQ=WEEKLY;COUNT=5\r
EXDATE;TZID=America/New_York:20261026T100000\r
SUMMARY:Weekly\\, sync\r
DESCRIPTION:line one\\nline two that is long enough to need folding when writt\r
 en out by a producer\r
END:VEVENT\r
BEGIN:VEVENT\r
UID:weekly-1\r
RECURRENCE-ID;TZID=America/New_York:20261102T100000\r
DTSTART;TZID=America/New_York:20261102T150000\r
DTEND;TZID=America/New_York:20261102T153000\r
SUMMARY:Weekly (moved)\r
END:VEVENT\r
BEGIN:VEVENT\r
UID:weekly-1\r
RECURRENCE-ID;TZID=America/New_York:20261109T100000\r
STATUS:CANCELLED\r
DTSTART;TZID=America/New_York:20261109T100000\r
END:VEVENT\r
BEGIN:VEVENT\r
UID:trip\r
DTSTART;VALUE=DATE:20261120\r
DTEND;VALUE=DATE:20261123\r
SUMMARY:Trip\r
END:VEVENT\r
BEGIN:VEVENT\r
UID:outlook\r
DTSTART;TZID="Pacific Standard Time":20261201T090000\r
DURATION:PT1H\r
SUMMARY:Outlook thing\r
END:VEVENT\r
BEGIN:VEVENT\r
UID:old\r
DTSTART:20200101T120000Z\r
SUMMARY:Out of window\r
END:VEVENT\r
END:VCALENDAR\r
"""
CHI = ZoneInfo("America/Chicago")
ws, we = datetime(2026, 1, 1, tzinfo=CHI), datetime(2027, 12, 31, tzinfo=CHI)
recs = ical.events_from_text(DOC, "c1", ws, we, {"readOnly": True}, default_zone=None)
by = {}
for r in recs:
    by.setdefault(r["sourceUid"], []).append(r)
weekly = sorted(by["weekly-1"], key=lambda r: r["start"])
titles = [(r["title"], r["start"]) for r in weekly]
local = ical.local_zone()


def loc(y, mo, d, h, mi, zone=NY):
    return datetime(y, mo, d, h, mi, tzinfo=zone).astimezone(local).strftime("%Y-%m-%dT%H:%M")


expected = [("Weekly, sync", loc(2026, 10, 19, 10, 0)), ("Weekly (moved)", loc(2026, 11, 2, 15, 0)),
            ("Weekly, sync", loc(2026, 11, 16, 10, 0))]
assert titles == expected, titles
assert weekly[0]["notes"].startswith("line one\nline two") and "writt" + "en" in weekly[0]["notes"], weekly[0]["notes"]
assert weekly[0]["recurring"] and weekly[0]["readOnly"]
assert len({r["uid"] for r in weekly}) == 3
trip = by["trip"][0]
assert (trip["allDay"], trip["start"], trip["end"]) == (True, "2026-11-20", "2026-11-22"), trip
out = by["outlook"][0]
assert out["start"] == loc(2026, 12, 1, 9, 0, ZoneInfo("America/Los_Angeles")), out
assert "old" not in by

# Writing: new event round-trips; editing keeps unknown properties.
ev = {"title": "Lunch; with, Sam", "allDay": False, "start": "2026-10-20T12:00", "end": "2026-10-20T13:00",
      "location": "Cafe", "notes": "a\nb"}
text = ical.new_vcalendar(ev, "new-1")
back = ical.events_from_text(text, "c", ws, we)[0]
assert (back["title"], back["start"], back["end"], back["notes"]) == ("Lunch; with, Sam", "2026-10-20T12:00", "2026-10-20T13:00", "a\nb"), back
orig = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:x\r\nDTSTART;TZID=America/New_York:20261020T090000\r\nDURATION:PT1H\r\nSUMMARY:Old\r\nATTENDEE;CN=Bob:mailto:bob@example.com\r\nSEQUENCE:3\r\nBEGIN:VALARM\r\nTRIGGER:-PT10M\r\nACTION:DISPLAY\r\nEND:VALARM\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
edited = ical.edit_vcalendar(orig, dict(ev, title="New"))
assert "ATTENDEE;CN=Bob" in edited and "BEGIN:VALARM" in edited and "SEQUENCE:4" in edited and "DURATION" not in edited
assert edited.count("SUMMARY:") == 1 and "SUMMARY:New" in edited
back = ical.events_from_text(edited, "c", ws, we)[0]
assert (back["start"], back["end"]) == ("2026-10-20T12:00", "2026-10-20T13:00"), back
allday = ical.new_vcalendar({"title": "Off", "allDay": True, "start": "2026-12-24", "end": "2026-12-26"}, "ad")
assert "DTEND;VALUE=DATE:20261227" in allday
back = ical.events_from_text(allday, "c", ws, we)[0]
assert (back["start"], back["end"]) == ("2026-12-24", "2026-12-26")
assert ical.is_recurring_text(DOC) and not ical.is_recurring_text(allday)

# ---- Long-running series reach the window (they used to yield nothing once
# the 2000-period limit ran out before the window).
WS, WE = datetime(2026, 6, 1, tzinfo=CHI), datetime(2027, 11, 1, tzinfo=CHI)


def series(dtstart, rule, extra=""):
    doc = ("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:s\r\nDTSTART;TZID=America/Chicago:" + dtstart +
           "\r\nDURATION:PT30M\r\nRRULE:" + rule + "\r\n" + extra + "SUMMARY:s\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n")
    return sorted(r["start"] for r in ical.events_from_text(doc, "c", WS, WE))


def oracle(dtstart, rule):
    start = datetime.strptime(dtstart, "%Y%m%dT%H%M%S")
    until = None
    if "UNTIL=" in rule:  # dateutil compares naive; ours compares the real UTC instant
        until = datetime.strptime(rule.split("UNTIL=")[1][:15], "%Y%m%dT%H%M%S").replace(tzinfo=timezone.utc)
    out = []
    for occ in du.rrulestr(rule.replace("Z", ""), dtstart=start):
        aware = occ.replace(tzinfo=CHI)
        if aware > WE or (until and aware > until):
            break
        if aware + timedelta(minutes=30) >= WS:
            out.append(aware.astimezone(local).strftime("%Y-%m-%dT%H:%M"))
    return out


LONG = [
    ("20150101T090000", "FREQ=DAILY"),
    ("19800107T090000", "FREQ=WEEKLY"),
    ("19800107T090000", "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH"),
    ("20190103T080000", "FREQ=DAILY;INTERVAL=3"),
    ("20000111T100000", "FREQ=MONTHLY;BYDAY=2TU"),
    ("20000131T100000", "FREQ=MONTHLY;INTERVAL=5;BYMONTHDAY=-1"),
    ("19500704T120000", "FREQ=YEARLY"),
    ("19511122T120000", "FREQ=YEARLY;INTERVAL=3;BYMONTH=11;BYDAY=4TH"),
    ("20150101T090000", "FREQ=DAILY;COUNT=5000"),
    ("20150101T090000", "FREQ=DAILY;UNTIL=20261231T235959Z"),
]
for dtstart, rule in LONG:
    got = series(dtstart, rule)
    assert got, f"{rule} from {dtstart}: no occurrences"
    if du:
        check(f"long {rule} @ {dtstart}", got, oracle(dtstart, rule))
assert len(series("20150101T090000", "FREQ=DAILY")) == (WE - WS).days   # Jun 1 2026 .. Oct 31 2027
assert series("20150101T090000", "FREQ=DAILY;COUNT=100") == []   # all before the window

# ---- Local zone is a named zone, so times across a DST change convert with
# that date's offset (not today's).
os.environ["TZ"] = "America/Chicago"
ical.local_zone.cache_clear()
assert getattr(ical.local_zone(), "key", "") == "America/Chicago", ical.local_zone()
assert ical._stamp(datetime(2026, 12, 15, 15, 0, tzinfo=timezone.utc), False) == "2026-12-15T09:00"
assert ical._stamp(datetime(2026, 7, 15, 14, 0, tzinfo=timezone.utc), False) == "2026-07-15T09:00"
# Written with the zone's name, not as UTC, so repeats keep their wall time.
assert ical._time_props({"start": "2026-12-15T09:00", "end": "2026-12-15T10:00"}) == \
    ["DTSTART;TZID=America/Chicago:20261215T090000", "DTEND;TZID=America/Chicago:20261215T100000"]
assert ical._time_props({"start": "2026-07-15T09:00", "end": "2026-07-15T10:00"})[0] == "DTSTART;TZID=America/Chicago:20260715T090000"
# An event in another zone: local 09:00 Chicago (CST) is 16:00 in Paris.
assert ical._time_props({"start": "2026-12-15T09:00", "end": "2026-12-15T10:00", "tz": "Europe/Paris"}) == \
    ["DTSTART;TZID=Europe/Paris:20261215T160000", "DTEND;TZID=Europe/Paris:20261215T170000"]
# Unknown zone names fall back to the machine's.
assert ical._time_props({"start": "2026-12-15T09:00", "end": "2026-12-15T10:00", "tz": "Mars/Base"})[0] == \
    "DTSTART;TZID=America/Chicago:20261215T090000"
# New objects carry a VTIMEZONE for every zone they use.
_new = ical.new_vcalendar({"start": "2026-12-15T09:00", "end": "2026-12-15T10:00", "title": "x", "tz": "Europe/Paris"}, "U1")
assert "BEGIN:VTIMEZONE\r\nTZID:Europe/Paris" in _new and _new.index("VTIMEZONE") < _new.index("BEGIN:VEVENT")
_allday = ical.new_vcalendar({"start": "2026-12-15", "end": "2026-12-15", "allDay": True, "title": "x"}, "U2")
assert "VTIMEZONE" not in _allday
# Reading keeps the event's zone when it is not the machine's.
_recs = ical.events_from_text(_new, "c", datetime(2026, 12, 1, tzinfo=timezone.utc), datetime(2027, 1, 1, tzinfo=timezone.utc))
assert _recs[0]["start"] == "2026-12-15T09:00" and _recs[0]["tz"] == "Europe/Paris", _recs
_recs = ical.events_from_text(ical.new_vcalendar({"start": "2026-12-15T09:00", "end": "2026-12-15T10:00", "title": "x"}, "U3"),
                              "c", datetime(2026, 12, 1, tzinfo=timezone.utc), datetime(2027, 1, 1, tzinfo=timezone.utc))
assert "tz" not in _recs[0], _recs
# Editing adds a missing VTIMEZONE once, and leaves a VALARM's own
# DESCRIPTION/SUMMARY alone (only the event's are replaced).
_orig = ("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:a\r\nDTSTART:20261215T150000Z\r\n"
         "SUMMARY:old\r\nDESCRIPTION:old notes\r\nBEGIN:VALARM\r\nACTION:DISPLAY\r\nDESCRIPTION:Reminder\r\n"
         "TRIGGER:-PT15M\r\nEND:VALARM\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n")
_ed = ical.edit_vcalendar(_orig, {"start": "2026-12-15T10:00", "end": "2026-12-15T11:00", "title": "new"})
assert _ed.count("BEGIN:VTIMEZONE") == 1 and _ed.index("VTIMEZONE") < _ed.index("BEGIN:VEVENT"), _ed
assert "DESCRIPTION:Reminder" in _ed and "SUMMARY:new" in _ed and "old notes" not in _ed, _ed
assert ical.edit_vcalendar(_ed, {"start": "2026-12-15T10:00", "end": "2026-12-15T11:00", "title": "new"}).count("BEGIN:VTIMEZONE") == 1
# Round trip on the far side of the change.
dec = ical.new_vcalendar({"title": "x", "allDay": False, "start": "2026-12-15T09:00", "end": "2026-12-15T10:00"}, "dec")
assert ical.events_from_text(dec, "c", ws, we)[0]["start"] == "2026-12-15T09:00"
os.environ["TZ"] = "Europe/Berlin"
ical.local_zone.cache_clear()
assert ical._stamp(datetime(2026, 12, 15, 15, 0, tzinfo=timezone.utc), False) == "2026-12-15T16:00"
del os.environ["TZ"]
ical.local_zone.cache_clear()

# ---- fold(): 75-octet lines, never splitting a UTF-8 character, round trips
for text in ["x" * 300, "é" * 100, "a" + "😀" * 40, "DESCRIPTION:" + "日本語のテキスト" * 20, "short"]:
    folded = ical.fold(text)
    assert all(len(l.encode("utf-8")) <= 75 for l in folded.split("\r\n")), text[:20]
    assert folded.replace("\r\n ", "") == text

if failures:
    print(f"{failures} oracle mismatches")
    sys.exit(1)
print("ical tests passed")
