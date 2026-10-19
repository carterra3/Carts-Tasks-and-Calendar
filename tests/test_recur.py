#!/usr/bin/env python3
"""Recur.js against sync/ical.py expand_rrule (and dateutil when available).

Run: python3 tests/test_recur.py   (needs node on PATH)
"""
import json
import os
import random
import shutil
import subprocess
import sys
from datetime import date, datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "sync"))
import ical  # noqa: E402

FIXED = [
    "FREQ=DAILY", "FREQ=DAILY;INTERVAL=3", "FREQ=DAILY;COUNT=10", "FREQ=DAILY;BYDAY=MO,WE,FR",
    "FREQ=WEEKLY", "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH", "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR",
    "FREQ=WEEKLY;COUNT=7;BYDAY=SA,SU", "FREQ=WEEKLY;INTERVAL=2;WKST=SU;BYDAY=TU,SU",
    "FREQ=MONTHLY", "FREQ=MONTHLY;BYMONTHDAY=-1", "FREQ=MONTHLY;BYDAY=2TU", "FREQ=MONTHLY;BYDAY=-1FR",
    "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1", "FREQ=MONTHLY;INTERVAL=3;BYMONTHDAY=15,30",
    "FREQ=MONTHLY;BYMONTHDAY=31", "FREQ=YEARLY", "FREQ=YEARLY;BYMONTH=11;BYDAY=4TH",
    "FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=29", "FREQ=YEARLY;BYDAY=20MO", "FREQ=YEARLY;INTERVAL=4;BYMONTH=11;BYDAY=1TU",
    "FREQ=DAILY;UNTIL=20270115", "FREQ=WEEKLY;UNTIL=20270301T150000Z;BYDAY=WE",
    "FREQ=MONTHLY;COUNT=24;BYDAY=1MO,3MO", "FREQ=YEARLY;BYMONTH=1,7;BYMONTHDAY=1",
]
DAYS = ["MO", "TU", "WE", "TH", "FR", "SA", "SU"]


def random_rule(rnd):
    freq = rnd.choice(["DAILY", "WEEKLY", "MONTHLY", "YEARLY"])
    parts = [f"FREQ={freq}"]
    if rnd.random() < 0.4:
        parts.append(f"INTERVAL={rnd.randint(2, 5)}")
    if freq == "WEEKLY" and rnd.random() < 0.7:
        parts.append("BYDAY=" + ",".join(sorted(rnd.sample(DAYS, rnd.randint(1, 4)), key=DAYS.index)))
    if freq == "MONTHLY":
        k = rnd.random()
        if k < 0.35:
            parts.append(f"BYDAY={rnd.choice(['1', '2', '3', '4', '-1'])}{rnd.choice(DAYS)}")
        elif k < 0.7:
            parts.append("BYMONTHDAY=" + ",".join(str(x) for x in rnd.sample([1, 5, 15, 28, 30, 31, -1, -2], rnd.randint(1, 2))))
        elif k < 0.85:
            parts.append("BYDAY=MO,TU,WE,TH,FR;BYSETPOS=" + rnd.choice(["1", "-1", "2"]))
    if freq == "YEARLY" and rnd.random() < 0.5:
        m = rnd.randint(1, 12)
        parts.append(f"BYMONTH={m};BYDAY={rnd.choice(['1', '2', '-1'])}{rnd.choice(DAYS)}")
    if freq == "DAILY" and rnd.random() < 0.2:
        parts.append("BYMONTH=" + ",".join(str(x) for x in sorted(rnd.sample(range(1, 13), 3))))
    r = rnd.random()
    if r < 0.25:
        parts.append(f"COUNT={rnd.randint(1, 40)}")
    elif r < 0.45:
        u = date(2026, 1, 1) + timedelta(days=rnd.randint(0, 900))
        parts.append("UNTIL=" + (u.strftime("%Y%m%d") if rnd.random() < 0.5 else u.strftime("%Y%m%dT235959Z")))
    return ";".join(parts)


def py_expand(start, is_date, rule, wstart, wend):
    if is_date:
        occ = ical.expand_rrule(start, ical.parse_rrule(rule), wend.date(), True, window_start=wstart.date())
        return [int(datetime(o.year, o.month, o.day, tzinfo=timezone.utc).timestamp() * 1000) for o in occ]
    occ = ical.expand_rrule(start, ical.parse_rrule(rule), wend, False, window_start=wstart.date())
    return [int(o.timestamp() * 1000) for o in occ]


def main():
    node = shutil.which("node")
    if not node:
        print("node not found: skipping")
        return
    rnd = random.Random(11)
    cases = []
    rules = FIXED + [random_rule(rnd) for _ in range(400)]
    for i, rule in enumerate(rules):
        is_date = i % 5 == 0
        start = datetime(2015 + rnd.randint(0, 12), rnd.randint(1, 12), rnd.randint(1, 28),
                         rnd.choice([0, 9, 13, 23]), rnd.choice([0, 30]), tzinfo=timezone.utc)
        wstart = datetime(2026, 6, 1, tzinfo=timezone.utc)
        wend = datetime(2027, 10, 31, tzinfo=timezone.utc)
        if is_date:
            start_v = start.date()
        else:
            start_v = start
        expected = py_expand(start_v, is_date, rule, wstart - timedelta(days=1), wend)
        cases.append({"rule": rule, "date": is_date,
                      "start": int(datetime(start.year, start.month, start.day, *(() if is_date else (start.hour, start.minute)),
                                            tzinfo=timezone.utc).timestamp() * 1000),
                      "wstart": int((wstart - timedelta(days=1)).timestamp() * 1000), "wend": int(wend.timestamp() * 1000),
                      "expected": expected})
    script = r"""
const R = require(process.argv[1]); const inp = JSON.parse(require('fs').readFileSync(0, 'utf8'));
let bad = [];
for (const c of inp) {
  const got = R.expand(c.start, c.date, c.rule, c.wend, { windowStart: c.wstart, toWall: x => x });
  if (JSON.stringify(got) !== JSON.stringify(c.expected)) bad.push({ rule: c.rule, date: c.date, start: new Date(c.start).toISOString(), got: got.slice(0, 4).map(x => new Date(x).toISOString()), exp: c.expected.slice(0, 4).map(x => new Date(x).toISOString()), ng: got.length, ne: c.expected.length });
}
console.log(JSON.stringify({ n: inp.length, bad: bad.slice(0, 4), nbad: bad.length, occurrences: inp.reduce((a, c) => a + c.expected.length, 0) }));
"""
    r = subprocess.run([node, "-e", script, os.path.join(ROOT, "Recur.js")], input=json.dumps(cases), capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(r.stderr)
    out = json.loads(r.stdout)
    assert out["nbad"] == 0, json.dumps(out, indent=1)
    print(f"Recur.js matches ical.expand_rrule on {out['n']} rules ({out['occurrences']} occurrences)")

    summaries = r"""
const R = require(process.argv[1]);
const t = [["FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR", "Every weekday"], ["FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE", "Every 2 weeks on Monday and Wednesday"],
  ["FREQ=MONTHLY;BYDAY=2TU", "Monthly on the second Tuesday"], ["FREQ=MONTHLY;BYMONTHDAY=-1", "Monthly on the last day"],
  ["FREQ=YEARLY;BYMONTH=11;BYDAY=4TH", "Yearly on the fourth Thursday in November"], ["FREQ=DAILY;COUNT=5", "Daily, 5 times"],
  ["FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1", "Monthly on the last Monday, Tuesday, Wednesday, Thursday or Friday"],
  ["FREQ=WEEKLY;UNTIL=20270301T150000Z;BYDAY=WE", "Weekly on Wednesday, until Mar 1, 2027"], ["FREQ=DAILY;UNTIL=20270201T055959Z", "Daily, until Jan 31, 2027"]];
let bad = t.filter(([r, s]) => R.summary(r) !== s).map(([r, s]) => [r, R.summary(r), s]);
console.log(JSON.stringify(bad));
"""
    r = subprocess.run([node, "-e", summaries, os.path.join(ROOT, "Recur.js")], capture_output=True, text=True)
    assert r.stdout.strip() == "[]", r.stdout + r.stderr
    print("summaries ok")
    print("recur tests passed")


if __name__ == "__main__":
    main()
