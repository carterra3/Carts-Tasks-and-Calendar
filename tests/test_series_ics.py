#!/usr/bin/env python3
"""sync/series.py: this / following / all edits on iCalendar series.

Run: python3 tests/test_series_ics.py
"""
import os
import sys
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "sync"))
os.environ["TZ"] = "America/Chicago"
import ical  # noqa: E402
import series  # noqa: E402

ical.local_zone.cache_clear()
WS = datetime(2026, 9, 1, tzinfo=timezone.utc)
WE = datetime(2027, 3, 1, tzinfo=timezone.utc)

BASE = "\r\n".join([
    "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:test",
    "BEGIN:VEVENT", "UID:series-1", "DTSTAMP:20260101T000000Z",
    "DTSTART;TZID=America/Chicago:20261019T090000", "DTEND;TZID=America/Chicago:20261019T093000",
    "RRULE:FREQ=WEEKLY;BYDAY=MO;COUNT=10", "SUMMARY:Standup", "X-CUSTOM:keep me",
    "ATTENDEE;CN=Pat:mailto:pat@example.com",
    "BEGIN:VALARM", "ACTION:DISPLAY", "DESCRIPTION:Reminder", "TRIGGER:-PT10M", "END:VALARM",
    "END:VEVENT", "END:VCALENDAR", ""])


def occ(text):
    return [(r["start"], r["end"], r["title"]) for r in sorted(ical.events_from_text(text, "c", WS, WE), key=lambda r: r["start"])]


def key(stamp):   # local stamp -> occurrence key
    return ical._local_dt(stamp).astimezone(timezone.utc).strftime("%Y%m%dT%H%M%S")


def ev(start, end, title="Standup", **kw):
    return dict(start=start, end=end, title=title, allDay=False, **kw)


base = occ(BASE)
assert len(base) == 10 and base[0][0] == "2026-10-19T09:00" and base[3][0] == "2026-11-09T09:00", base   # DST: still 9:00

# ---- this: move the third Monday to 10:00 and rename it
t = series.edit_this(BASE, key("2026-11-02T09:00"), ev("2026-11-02T10:00", "2026-11-02T10:45", "Standup (moved)"))
o = occ(t)
assert len(o) == 10 and ("2026-11-02T10:00", "2026-11-02T10:45", "Standup (moved)") in o, o
assert "X-CUSTOM:keep me" in t and t.count("DESCRIPTION:Reminder") == 2, t   # override inherits alarms etc.
# editing the same occurrence again updates the override, not a second one
t2 = series.edit_this(t, key("2026-11-02T09:00"), ev("2026-11-02T11:00", "2026-11-02T11:30", "Again"))
assert t2.count("RECURRENCE-ID") == 1 and ("2026-11-02T11:00", "2026-11-02T11:30", "Again") in occ(t2)

# ---- delete this
d = series.delete_this(t, key("2026-10-26T09:00"))
od = occ(d)
assert len(od) == 9 and not any(x[0].startswith("2026-10-26") for x in od), od
d2 = series.delete_this(t, key("2026-11-02T09:00"))     # deleting an overridden one drops the override
assert "RECURRENCE-ID" not in d2 and len(occ(d2)) == 9

# ---- all: move the series to 9:30 from the fourth occurrence; overrides/exdates follow
t3 = series.delete_this(t, key("2026-10-26T09:00"))
a = series.edit_all(t3, key("2026-11-09T09:00"), ev("2026-11-09T09:30", "2026-11-09T10:00", "Standup v2"))
oa = occ(a)
assert all(x[0].endswith("09:30") or x[2] == "Standup (moved)" for x in oa), oa
assert len(oa) == 9 and not any(x[0].startswith("2026-10-26") for x in oa), oa         # exception kept
assert ("2026-11-02T10:00", "2026-11-02T10:45", "Standup (moved)") in oa, oa              # override kept
assert oa[0] == ("2026-10-19T09:30", "2026-10-19T10:00", "Standup v2"), oa
assert "ATTENDEE;CN=Pat" in a and "X-CUSTOM" in a

# ---- all with a new rule drops exceptions and overrides
a2 = series.edit_all(t3, key("2026-11-09T09:00"), ev("2026-11-09T09:00", "2026-11-09T09:30", rrule="FREQ=WEEKLY;BYDAY=MO,WE;COUNT=4"))
oa2 = occ(a2)
assert [x[0] for x in oa2] == ["2026-10-19T09:00", "2026-10-21T09:00", "2026-10-26T09:00", "2026-10-28T09:00"], oa2
assert "EXDATE" not in a2 and "RECURRENCE-ID" not in a2

# ---- following: from the 5th occurrence on, 14:00; COUNT=10 splits 4 + 6
old, new = series.split(BASE, key("2026-11-16T09:00"), ev("2026-11-16T14:00", "2026-11-16T14:30", "Afternoon"), "series-2")
oo, on = occ(old), occ(new)
assert [x[0][:10] for x in oo] == ["2026-10-19", "2026-10-26", "2026-11-02", "2026-11-09"], oo
assert len(on) == 6 and on[0] == ("2026-11-16T14:00", "2026-11-16T14:30", "Afternoon") and on[-1][0] == "2026-12-21T14:00", on
assert "UID:series-2" in new and "COUNT=6" in new and "UNTIL=" in old and "COUNT" not in old.split("RRULE:")[1].split("\r\n")[0]
# following from the first occurrence: nothing left of the old series
old1, new1 = series.split(BASE, key("2026-10-19T09:00"), ev("2026-10-19T08:00", "2026-10-19T08:30"), "series-3")
assert old1 is None and len(occ(new1)) == 10

# ---- delete following
t4, left = series.end_before(BASE, key("2026-11-16T09:00"))
assert len(occ(t4)) == 4 and left == 6
assert series.end_before(BASE, key("2026-10-19T09:00")) == (None, None)

# ---- all-day yearly series moved by a day keeps its exception
AD = "\r\n".join(["BEGIN:VCALENDAR", "VERSION:2.0", "BEGIN:VEVENT", "UID:bday", "DTSTART;VALUE=DATE:20200310",
                  "DTEND;VALUE=DATE:20200311", "RRULE:FREQ=YEARLY", "EXDATE;VALUE=DATE:20270310", "SUMMARY:B",
                  "END:VEVENT", "END:VCALENDAR", ""])
ad = series.edit_all(AD, "20260310", {"start": "2026-03-11", "end": "2026-03-11", "allDay": True, "title": "B"})
yrs = [r["start"] for r in ical.events_from_text(ad, "c", datetime(2026, 1, 1, tzinfo=timezone.utc), datetime(2029, 1, 1, tzinfo=timezone.utc))]
assert sorted(yrs) == ["2026-03-11", "2028-03-11"], yrs

# ---- new series and the local-record round trip
n = series.new_vcalendar({"start": "2026-10-20T18:00", "end": "2026-10-20T19:00", "title": "Gym",
                          "rrule": "FREQ=DAILY;COUNT=3", "exdates": [key("2026-10-21T18:00")]}, "g1")
assert [x[0] for x in occ(n)] == ["2026-10-20T18:00", "2026-10-22T18:00"], occ(n)
rec = series.series_record(t)
assert rec["rrule"] == "FREQ=WEEKLY;BYDAY=MO;COUNT=10" and rec["start"] == "2026-10-19T09:00", rec
assert rec["overrides"][key("2026-11-02T09:00")]["title"] == "Standup (moved)", rec
print("series ics tests passed")
