"""Time zone data for the calendar (standard library only).

QML's JavaScript only knows the machine's own zone, so the helper hands it
offset tables built from zoneinfo, and writes VTIMEZONE blocks for the zones
events are saved in.
"""

from __future__ import annotations

import functools
import zoneinfo
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

TABLE_FROM = 1970
TABLE_TO = 2070
WEEKDAYS = ["MO", "TU", "WE", "TH", "FR", "SA", "SU"]


def valid(name: str) -> bool:
    try:
        ZoneInfo(name)
        return True
    except (ZoneInfoNotFoundError, ValueError, TypeError):
        return False


@functools.lru_cache(maxsize=None)
def table(name: str, y0: int = TABLE_FROM, y1: int = TABLE_TO):
    """{"t": [utc seconds], "o": [offset minutes]}: the offset in force from
    each t on. t[0] is the start of y0 and carries the offset then."""
    z = ZoneInfo(name)

    def off(t):
        return int(t.astimezone(z).utcoffset().total_seconds() // 60)

    t = datetime(y0, 1, 1, tzinfo=timezone.utc)
    end = datetime(y1 + 1, 1, 1, tzinfo=timezone.utc)
    ts, os_ = [int(t.timestamp())], [off(t)]
    step = timedelta(days=1)
    cur = off(t)
    while t < end:
        nxt = t + step
        o = off(nxt)
        if o != cur:
            lo, hi = t, nxt          # off(lo) == cur, off(hi) != cur
            while hi - lo > timedelta(minutes=1):
                mid = lo + (hi - lo) / 2
                mid = mid.replace(second=0, microsecond=0)
                if mid <= lo:
                    break
                if off(mid) == cur:
                    lo = mid
                else:
                    hi = mid
            ts.append(int(hi.timestamp()))
            os_.append(o)
            cur = o
        t = nxt
    return {"t": ts, "o": os_}


def all_zones():
    return sorted(z for z in zoneinfo.available_timezones()
                  if "/" in z and not z.startswith(("Etc/", "SystemV/", "posix/", "right/"))) + ["UTC"]


# --------------------------------------------------------------------------
# VTIMEZONE
# --------------------------------------------------------------------------

def _fmt_offset(minutes: int) -> str:
    sign = "-" if minutes < 0 else "+"
    m = abs(minutes)
    return f"{sign}{m // 60:02d}{m % 60:02d}"


def _transitions_in(name, year):
    tb = table(name)
    lo = datetime(year, 1, 1, tzinfo=timezone.utc).timestamp()
    hi = datetime(year + 1, 1, 1, tzinfo=timezone.utc).timestamp()
    out = []
    for i in range(1, len(tb["t"])):
        if lo <= tb["t"][i] < hi:
            out.append((tb["t"][i], tb["o"][i - 1], tb["o"][i]))
    return out


def _nth_weekday(year, month, byday):
    """The day in year/month an RRULE BYDAY value like 2SU or -1SU picks."""
    n, wd = int(byday[:-2]), WEEKDAYS.index(byday[-2:])
    days = [datetime(year, month, d) for d in range(1, 32) if _valid_day(year, month, d)]
    matches = [d for d in days if d.weekday() == wd]
    return matches[n - 1] if n > 0 else matches[n]


def _valid_day(year, month, day):
    try:
        datetime(year, month, day)
        return True
    except ValueError:
        return False


def _rule_of(name, ts, before, after):
    """(kind, month, byday, wall) for one transition."""
    z = ZoneInfo(name)
    wall = datetime.fromtimestamp(ts, timezone.utc).replace(tzinfo=None) + timedelta(minutes=before)
    nxt = wall.replace(day=1, month=wall.month % 12 + 1, year=wall.year + (wall.month == 12))
    last_day = (nxt - timedelta(days=1)).day
    byday = (f"-1{WEEKDAYS[wall.weekday()]}" if wall.day + 7 > last_day
             else f"{(wall.day - 1) // 7 + 1}{WEEKDAYS[wall.weekday()]}")
    abbr = datetime.fromtimestamp(ts, timezone.utc).astimezone(z).tzname() or name
    kind = "DAYLIGHT" if after > before else "STANDARD"
    return kind, wall.month, byday, wall, abbr


def vtimezone(name: str, year: int | None = None, years: int = 12) -> list[str]:
    """VTIMEZONE lines for `name` from `year` on.

    Regular daylight saving (same nth-weekday rule every year) becomes two
    yearly RRULEs. Irregular zones (e.g. Morocco around Ramadan) get dated
    transitions (RDATE) for `years` years. No DST: one fixed offset.
    """
    z = ZoneInfo(name)
    year = year or datetime.now().year
    lines = ["BEGIN:VTIMEZONE", f"TZID:{name}"]
    per_year = [_transitions_in(name, y) for y in range(year, year + years)]
    if not any(per_year):
        at = datetime(year, 7, 1, tzinfo=timezone.utc).astimezone(z)
        off = int((at.utcoffset() or timedelta(0)).total_seconds() // 60)
        abbr = at.tzname() or name
        lines += ["BEGIN:STANDARD", "DTSTART:19700101T000000", f"TZOFFSETFROM:{_fmt_offset(off)}",
                  f"TZOFFSETTO:{_fmt_offset(off)}", f"TZNAME:{abbr}", "END:STANDARD"]
        lines.append("END:VTIMEZONE")
        return lines

    signature = lambda trs: [(_rule_of(name, *t)[:3], t[1], t[2]) for t in trs]  # noqa: E731
    first = signature(per_year[0])
    regular = len(per_year[0]) == 2 and all(signature(trs) == first for trs in per_year)
    if regular:
        for ts, before, after in per_year[0]:
            kind, month, byday, wall, abbr = _rule_of(name, ts, before, after)
            onset = _nth_weekday(1970, month, byday).replace(hour=wall.hour, minute=wall.minute)
            lines += [f"BEGIN:{kind}", f"DTSTART:{onset.strftime('%Y%m%dT%H%M%S')}",
                      f"RRULE:FREQ=YEARLY;BYMONTH={month};BYDAY={byday}",
                      f"TZOFFSETFROM:{_fmt_offset(before)}", f"TZOFFSETTO:{_fmt_offset(after)}",
                      f"TZNAME:{abbr}", f"END:{kind}"]
    else:
        # The offset in force when the range starts, then every change.
        jan1 = datetime(year, 1, 1, tzinfo=timezone.utc)
        off0 = int((jan1.astimezone(z).utcoffset() or timedelta(0)).total_seconds() // 60)
        lines += ["BEGIN:STANDARD", f"DTSTART:{jan1.strftime('%Y%m%dT%H%M%S')}",
                  f"TZOFFSETFROM:{_fmt_offset(off0)}", f"TZOFFSETTO:{_fmt_offset(off0)}",
                  f"TZNAME:{jan1.astimezone(z).tzname() or name}", "END:STANDARD"]
        for trs in per_year:
            for ts, before, after in trs:
                kind, _, _, wall, abbr = _rule_of(name, ts, before, after)
                lines += [f"BEGIN:{kind}", f"DTSTART:{wall.strftime('%Y%m%dT%H%M%S')}",
                          f"TZOFFSETFROM:{_fmt_offset(before)}", f"TZOFFSETTO:{_fmt_offset(after)}",
                          f"TZNAME:{abbr}", f"END:{kind}"]
    lines.append("END:VTIMEZONE")
    return lines
