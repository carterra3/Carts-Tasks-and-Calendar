#!/usr/bin/env python3
"""Events.expandSeries: local repeating events, across DST and zones.

Node runs with TZ=America/Chicago; expected values come from zoneinfo.
Run: python3 tests/test_series.py
"""
import json
import os
import shutil
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "sync"))
import tzdata  # noqa: E402

CHI = ZoneInfo("America/Chicago")
PAR = ZoneInfo("Europe/Paris")

SCRIPT = r"""
const E = require(process.argv[1] + '/Events.js'), R = require(process.argv[1] + '/Recur.js'), Tz = require(process.argv[1] + '/Tz.js');
const inp = JSON.parse(require('fs').readFileSync(0, 'utf8'));
const out = {};
for (const [name, c] of Object.entries(inp.cases)) {
  const table = c.master.tz ? inp.tables[c.master.tz] : null;
  out[name] = E.expandSeries(c.master, R, Tz, table, Date.parse(c.from), Date.parse(c.to))
    .map(o => ({ start: o.start, end: o.end, uid: o.uid, title: o.title, recurrenceId: o.recurrenceId }));
}
console.log(JSON.stringify(out));
"""


def local(dt):
    return dt.astimezone(CHI).strftime("%Y-%m-%dT%H:%M")


def key(dt):
    return dt.astimezone(timezone.utc).strftime("%Y%m%dT%H%M%S")


def main():
    node = shutil.which("node")
    if not node:
        print("node not found: skipping")
        return
    cases = {
        # Weekly Monday 9:00 Chicago across the November DST change: stays 9:00.
        "weekly_dst": {"master": {"uid": "a", "calendarId": "c", "title": "Standup", "start": "2026-10-19T09:00",
                                  "end": "2026-10-19T09:30", "rrule": "FREQ=WEEKLY;BYDAY=MO"},
                       "from": "2026-10-18T00:00:00Z", "to": "2026-11-17T00:00:00Z"},
        # Series in Paris at 18:00 Paris time; Europe and the US change DST on
        # different dates, so the local time shifts between them.
        "paris": {"master": {"uid": "p", "calendarId": "c", "title": "Call", "tz": "Europe/Paris",
                             "start": "2026-10-19T11:00", "end": "2026-10-19T12:00", "rrule": "FREQ=DAILY;COUNT=20"},
                  "from": "2026-10-01T00:00:00Z", "to": "2026-12-01T00:00:00Z"},
        # Exceptions and overrides.
        "edits": {"master": {"uid": "e", "calendarId": "c", "title": "Gym", "start": "2026-10-20T18:00",
                             "end": "2026-10-20T19:00", "rrule": "FREQ=DAILY;COUNT=5",
                             "exdates": [key(datetime(2026, 10, 21, 18, 0, tzinfo=CHI))],
                             "overrides": {key(datetime(2026, 10, 22, 18, 0, tzinfo=CHI)): {"title": "Gym (late)", "start": "2026-10-22T20:00", "end": "2026-10-22T21:00"},
                                           key(datetime(2026, 10, 23, 18, 0, tzinfo=CHI)): {"cancelled": True}}},
                  "from": "2026-10-01T00:00:00Z", "to": "2026-12-01T00:00:00Z"},
        # All-day, two days long, yearly; window in the middle of a long series.
        "allday": {"master": {"uid": "d", "calendarId": "c", "title": "Trip", "allDay": True, "start": "2019-07-03",
                              "end": "2019-07-04", "rrule": "FREQ=YEARLY"},
                   "from": "2026-01-01T00:00:00Z", "to": "2028-01-01T00:00:00Z"},
    }
    tables = {"Europe/Paris": tzdata.table("Europe/Paris")}
    env = dict(os.environ, TZ="America/Chicago")
    r = subprocess.run([node, "-e", SCRIPT, ROOT], input=json.dumps({"cases": cases, "tables": tables}),
                       capture_output=True, text=True, env=env)
    if r.returncode != 0:
        raise SystemExit(r.stderr)
    got = json.loads(r.stdout)

    # weekly_dst
    exp = []
    d = datetime(2026, 10, 19, 9, 0)
    while d < datetime(2026, 11, 17):
        a = d.replace(tzinfo=CHI)
        exp.append({"start": local(a), "end": local(a + timedelta(minutes=30)), "recurrenceId": key(a)})
        d += timedelta(days=7)
    assert [{k: o[k] for k in ("start", "end", "recurrenceId")} for o in got["weekly_dst"]] == exp, got["weekly_dst"]
    assert got["weekly_dst"][0]["uid"] == "a@" + exp[0]["recurrenceId"]

    # paris: 18:00 Paris every day for 20 days from Oct 19.
    exp = []
    for i in range(20):
        a = datetime(2026, 10, 19, 18, 0, tzinfo=PAR) + timedelta(days=0)
        a = datetime.combine((datetime(2026, 10, 19) + timedelta(days=i)).date(), datetime.min.time().replace(hour=18), tzinfo=PAR)
        exp.append({"start": local(a), "end": local(a + timedelta(hours=1)), "recurrenceId": key(a)})
    assert [{k: o[k] for k in ("start", "end", "recurrenceId")} for o in got["paris"]] == exp, (got["paris"][:9], exp[:9])
    hours = sorted({o["start"][11:] for o in got["paris"]})
    assert hours == ["11:00", "12:00"], hours   # the week Europe has changed and the US has not

    # edits
    titles = [(o["start"], o["title"]) for o in got["edits"]]
    assert titles == [("2026-10-20T18:00", "Gym"), ("2026-10-22T20:00", "Gym (late)"), ("2026-10-24T18:00", "Gym")], titles

    # allday
    assert [(o["start"], o["end"]) for o in got["allday"]] == [("2026-07-03", "2026-07-04"), ("2027-07-03", "2027-07-04")], got["allday"]
    assert got["allday"][0]["recurrenceId"] == "20260703"
    print("series tests passed")


if __name__ == "__main__":
    main()
