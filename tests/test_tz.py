#!/usr/bin/env python3
"""Tz.js against zoneinfo, and generated VTIMEZONE rules against zoneinfo.

Run: python3 tests/test_tz.py   (needs node on PATH for the JS half)
"""
import json
import os
import random
import shutil
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "sync"))
import ical  # noqa: E402
import tzdata  # noqa: E402

ZONES = ["America/Chicago", "Europe/London", "Australia/Lord_Howe", "Asia/Kolkata",
         "America/Sao_Paulo", "Pacific/Chatham", "America/St_Johns", "UTC", "Africa/Casablanca"]


def check_tables_js():
    node = shutil.which("node")
    if not node:
        print("node not found: skipping Tz.js checks")
        return
    rnd = random.Random(7)
    t0 = time.time()
    tables = {z: tzdata.table(z) for z in ZONES}
    print(f"tables for {len(ZONES)} zones in {time.time() - t0:.2f}s")
    cases = []
    for z in ZONES:
        zi = ZoneInfo(z)
        for _ in range(600):
            utc = datetime(1971, 1, 1, tzinfo=timezone.utc) + timedelta(minutes=rnd.randrange(0, 95 * 525600))
            wall = utc.astimezone(zi).replace(tzinfo=None)
            # A wall time maps back unambiguously only if both folds agree.
            back = {wall.replace(fold=f, tzinfo=zi).astimezone(timezone.utc) for f in (0, 1)}
            cases.append({"z": z, "utc": int(utc.timestamp() * 1000),
                          "wall": int(wall.replace(tzinfo=timezone.utc).timestamp() * 1000),
                          "unique": len(back) == 1})
    script = """
const Tz = require(process.argv[1]); const inp = JSON.parse(require('fs').readFileSync(0, 'utf8'));
let bad = [];
for (const c of inp.cases) {
  const t = inp.tables[c.z];
  if (Tz.utcToWall(t, c.utc) !== c.wall) bad.push(['toWall', c]);
  if (c.unique && Tz.wallToUtc(t, c.wall) !== c.utc) bad.push(['toUtc', c]);
}
console.log(JSON.stringify({n: inp.cases.length, bad: bad.slice(0, 5), nbad: bad.length}));
"""
    r = subprocess.run([node, "-e", script, os.path.join(ROOT, "Tz.js")],
                       input=json.dumps({"tables": tables, "cases": cases}), capture_output=True, text=True)
    out = json.loads(r.stdout or "{}") if r.returncode == 0 else {"err": r.stderr}
    assert out.get("nbad") == 0, out
    print(f"Tz.js: {out['n']} conversions match zoneinfo")


def check_vtimezone():
    """Expand each generated VTIMEZONE's rules and compare offsets with zoneinfo."""
    for z in ZONES + ["Europe/Berlin", "America/New_York", "Pacific/Auckland", "Asia/Tokyo"]:
        for year in (2026, 2027):
            lines = tzdata.vtimezone(z, year)
            text = "\r\n".join(lines)
            comps, cur = [], None
            for line in ical.unfold(text):
                p = ical.parse_line(line)
                if p.name == "BEGIN" and p.value in ("STANDARD", "DAYLIGHT"):
                    cur = []
                elif p.name == "END" and p.value in ("STANDARD", "DAYLIGHT"):
                    comps.append(cur)
                    cur = None
                elif cur is not None:
                    cur.append(p)
            # Build transitions for `year` from the rules.
            changes = []
            for props in comps:
                ds = ical.first(props, "DTSTART").value
                frm = ical.first(props, "TZOFFSETFROM").value
                to = ical.first(props, "TZOFFSETTO").value
                rr = ical.first(props, "RRULE")
                start = datetime.strptime(ds, "%Y%m%dT%H%M%S")

                def mins(v):
                    s = -1 if v[0] == "-" else 1
                    return s * (int(v[1:3]) * 60 + int(v[3:5]))
                if rr is None:
                    if ds.startswith("1970"):
                        changes.append((None, mins(to)))      # fixed offset
                    else:
                        changes.append((start - timedelta(minutes=mins(frm)), mins(to)))
                    continue
                for occ in ical.expand_rrule(start.replace(tzinfo=timezone.utc), ical.parse_rrule(rr.value),
                                             datetime(year, 12, 31, 23, 59, tzinfo=timezone.utc), False):
                    if occ.year == year:
                        utc = occ.replace(tzinfo=None) - timedelta(minutes=mins(frm))
                        changes.append((utc, mins(to)))
            changes.sort(key=lambda c: c[0] or datetime.min)
            zi = ZoneInfo(z)
            for probe_day in range(0, 365, 3):
                for hour in (0, 7, 13, 22):
                    utc = datetime(year, 1, 1) + timedelta(days=probe_day, hours=hour)
                    expected = int(utc.replace(tzinfo=timezone.utc).astimezone(zi).utcoffset().total_seconds() // 60)
                    if changes and changes[0][0] is None:
                        got = changes[0][1]
                    else:
                        before = [c for c in changes if c[0] <= utc]
                        got = before[-1][1] if before else changes[-1][1]
                    assert got == expected, (z, year, utc, got, expected)
    print("VTIMEZONE rules match zoneinfo")


if __name__ == "__main__":
    check_tables_js()
    check_vtimezone()
    print("tz tests passed")
