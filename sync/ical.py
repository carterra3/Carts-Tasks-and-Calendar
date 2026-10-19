"""Minimal iCalendar (RFC 5545) support for the calendar plugin.

Standard library only, so the plugin works on a stock Omarchy install:
  * parse VCALENDAR text into VEVENT property lists (unfolding, params, escapes)
  * expand recurrences (RRULE/RDATE/EXDATE/RECURRENCE-ID) inside a window
  * convert to the plugin's flat event records in local time
  * build new VEVENTs and edit existing ones in place (keeping everything we
    do not understand: attendees, alarms, X- properties)
"""

from __future__ import annotations

import calendar as _cal
import functools
import hashlib
import os
import re
import uuid
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import tzdata

# Outlook/Exchange feeds name zones the Windows way. Common ones only; anything
# unknown falls back to the feed's X-WR-TIMEZONE or local time.
WINDOWS_ZONES = {
    "Dateline Standard Time": "Etc/GMT+12", "UTC-11": "Etc/GMT+11",
    "Hawaiian Standard Time": "Pacific/Honolulu", "Alaskan Standard Time": "America/Anchorage",
    "Pacific Standard Time": "America/Los_Angeles", "Pacific Standard Time (Mexico)": "America/Tijuana",
    "US Mountain Standard Time": "America/Phoenix", "Mountain Standard Time": "America/Denver",
    "Central America Standard Time": "America/Guatemala", "Central Standard Time": "America/Chicago",
    "Central Standard Time (Mexico)": "America/Mexico_City", "Canada Central Standard Time": "America/Regina",
    "SA Pacific Standard Time": "America/Bogota", "Eastern Standard Time": "America/New_York",
    "US Eastern Standard Time": "America/Indianapolis", "Atlantic Standard Time": "America/Halifax",
    "Newfoundland Standard Time": "America/St_Johns", "E. South America Standard Time": "America/Sao_Paulo",
    "Argentina Standard Time": "America/Buenos_Aires", "SA Eastern Standard Time": "America/Cayenne",
    "UTC": "UTC", "Coordinated Universal Time": "UTC", "GMT Standard Time": "Europe/London",
    "Greenwich Standard Time": "Atlantic/Reykjavik", "W. Europe Standard Time": "Europe/Berlin",
    "Central Europe Standard Time": "Europe/Budapest", "Romance Standard Time": "Europe/Paris",
    "Central European Standard Time": "Europe/Warsaw", "W. Central Africa Standard Time": "Africa/Lagos",
    "GTB Standard Time": "Europe/Bucharest", "E. Europe Standard Time": "Europe/Chisinau",
    "FLE Standard Time": "Europe/Kiev", "Israel Standard Time": "Asia/Jerusalem",
    "Egypt Standard Time": "Africa/Cairo", "South Africa Standard Time": "Africa/Johannesburg",
    "Russian Standard Time": "Europe/Moscow", "Turkey Standard Time": "Europe/Istanbul",
    "Arabian Standard Time": "Asia/Dubai", "Arab Standard Time": "Asia/Riyadh",
    "Iran Standard Time": "Asia/Tehran", "Pakistan Standard Time": "Asia/Karachi",
    "India Standard Time": "Asia/Kolkata", "Nepal Standard Time": "Asia/Katmandu",
    "Bangladesh Standard Time": "Asia/Dhaka", "SE Asia Standard Time": "Asia/Bangkok",
    "China Standard Time": "Asia/Shanghai", "Singapore Standard Time": "Asia/Singapore",
    "Taipei Standard Time": "Asia/Taipei", "W. Australia Standard Time": "Australia/Perth",
    "Tokyo Standard Time": "Asia/Tokyo", "Korea Standard Time": "Asia/Seoul",
    "Cen. Australia Standard Time": "Australia/Adelaide", "AUS Central Standard Time": "Australia/Darwin",
    "E. Australia Standard Time": "Australia/Brisbane", "AUS Eastern Standard Time": "Australia/Sydney",
    "Tasmania Standard Time": "Australia/Hobart", "New Zealand Standard Time": "Pacific/Auckland",
}

WEEKDAYS = ["MO", "TU", "WE", "TH", "FR", "SA", "SU"]  # datetime.weekday() order


# --------------------------------------------------------------------------
# Parsing
# --------------------------------------------------------------------------

class Prop:
    __slots__ = ("name", "params", "value")

    def __init__(self, name, params, value):
        self.name = name
        self.params = params
        self.value = value

    def __repr__(self):
        return f"Prop({self.name!r}, {self.params!r}, {self.value!r})"


def unfold(text: str) -> list[str]:
    lines = []
    for raw in text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        if raw[:1] in (" ", "\t") and lines:
            lines[-1] += raw[1:]
        elif raw:
            lines.append(raw)
    return lines


def _split_unquoted(text: str, sep: str) -> list[str]:
    out, cur, quoted = [], [], False
    for ch in text:
        if ch == '"':
            quoted = not quoted
        if ch == sep and not quoted:
            out.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    out.append("".join(cur))
    return out


def parse_line(line: str) -> Prop | None:
    # Name and params end at the first colon outside quotes.
    quoted = False
    for i, ch in enumerate(line):
        if ch == '"':
            quoted = not quoted
        elif ch == ":" and not quoted:
            head, value = line[:i], line[i + 1:]
            break
    else:
        return None
    parts = _split_unquoted(head, ";")
    params = {}
    for p in parts[1:]:
        if "=" in p:
            k, v = p.split("=", 1)
            params[k.upper()] = v.strip('"')
    return Prop(parts[0].upper(), params, value)


def unescape(value: str) -> str:
    return re.sub(r"\\([\\;,nN])", lambda m: "\n" if m.group(1) in "nN" else m.group(1), value)


def escape(value: str) -> str:
    return (value.replace("\\", "\\\\").replace(";", "\\;").replace(",", "\\,")
            .replace("\r\n", "\\n").replace("\n", "\\n"))


def parse_components(text: str, wanted=("VEVENT",)):
    """Return (calendar_props, [component prop lists]) for wanted component types."""
    cal_props, comps, stack = [], [], []
    for line in unfold(text):
        prop = parse_line(line)
        if prop is None:
            continue
        if prop.name == "BEGIN":
            stack.append((prop.value.upper(), []))
            continue
        if prop.name == "END":
            if stack:
                kind, props = stack.pop()
                if kind in wanted and (not stack or stack[-1][0] == "VCALENDAR"):
                    comps.append(props)
            continue
        if stack:
            if stack[-1][0] == "VCALENDAR":
                cal_props.append(prop)
            else:
                stack[-1][1].append(prop)
    return cal_props, comps


def first(props, name):
    for p in props:
        if p.name == name:
            return p
    return None


def all_of(props, name):
    return [p for p in props if p.name == name]


# --------------------------------------------------------------------------
# Dates and zones
# --------------------------------------------------------------------------

@functools.lru_cache(maxsize=1)
def local_zone():
    """The machine's named zone (e.g. America/Chicago), not just today's offset.

    datetime.now().astimezone().tzinfo is a fixed offset (CDT, -05:00), which
    puts every time on the far side of a daylight-saving change an hour off.
    """
    tz = os.environ.get("TZ", "").lstrip(":")
    if tz:
        try:
            return ZoneInfo(tz)
        except (ZoneInfoNotFoundError, ValueError):
            if os.path.isfile(tz):
                try:
                    with open(tz, "rb") as f:
                        return ZoneInfo.from_file(f, key=tz)
                except (OSError, ValueError):
                    pass
    try:
        target = os.path.realpath("/etc/localtime")
        if "zoneinfo/" in target:
            return ZoneInfo(target.split("zoneinfo/", 1)[1])
    except (OSError, ZoneInfoNotFoundError, ValueError):
        pass
    try:
        with open("/etc/localtime", "rb") as f:
            return ZoneInfo.from_file(f, key="localtime")
    except (OSError, ValueError):
        pass
    return datetime.now().astimezone().tzinfo


def zone_for(tzid: str | None, default=None):
    if not tzid:
        return default
    tzid = tzid.strip().strip('"')
    for candidate in (tzid, WINDOWS_ZONES.get(tzid), tzid.lstrip("/")):
        if not candidate:
            continue
        try:
            return ZoneInfo(candidate)
        except (ZoneInfoNotFoundError, ValueError):
            pass
    # Some producers prefix IANA names with a vendor path.
    m = re.search(r"([A-Za-z]+/[A-Za-z_]+(?:/[A-Za-z_]+)?)$", tzid)
    if m:
        try:
            return ZoneInfo(m.group(1))
        except (ZoneInfoNotFoundError, ValueError):
            pass
    return default


def zone_name(prop: Prop | None, default_zone=None) -> str:
    """IANA name of a DTSTART's zone ("" for UTC, floating or unknown)."""
    if prop is None or prop.value.strip().upper().endswith("Z"):
        return ""
    z = zone_for(prop.params.get("TZID"), None)
    key = getattr(z, "key", None) if z is not None else None
    return key or ""


def local_zone_name() -> str:
    return getattr(local_zone(), "key", "") or ""


def parse_dt(prop: Prop, default_zone):
    """-> (value, is_date). value is a date, or an aware datetime."""
    raw = prop.value.strip().split(",")[0]
    if prop.params.get("VALUE", "").upper() == "DATE" or re.fullmatch(r"\d{8}", raw):
        return date(int(raw[0:4]), int(raw[4:6]), int(raw[6:8])), True
    m = re.fullmatch(r"(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})?(Z?)", raw)
    if not m:
        raise ValueError(f"bad date-time {raw!r}")
    y, mo, d, h, mi, s, z = m.groups()
    naive = datetime(int(y), int(mo), int(d), int(h), int(mi), int(s or 0))
    if z:
        return naive.replace(tzinfo=timezone.utc), False
    zone = zone_for(prop.params.get("TZID"), default_zone) or default_zone
    return naive.replace(tzinfo=zone), False


def parse_dt_list(prop: Prop, default_zone):
    out = []
    for raw in prop.value.split(","):
        raw = raw.strip()
        if not raw or "/" in raw:  # PERIOD values: not supported, skip
            continue
        out.append(parse_dt(Prop(prop.name, prop.params, raw), default_zone)[0])
    return out


def parse_duration(text: str) -> timedelta:
    m = re.fullmatch(r"([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?", text.strip())
    if not m:
        return timedelta(0)
    sign, w, d, h, mi, s = m.groups()
    td = timedelta(weeks=int(w or 0), days=int(d or 0), hours=int(h or 0), minutes=int(mi or 0), seconds=int(s or 0))
    return -td if sign == "-" else td


def fmt_utc(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def fmt_date(d: date) -> str:
    return d.strftime("%Y%m%d")


# --------------------------------------------------------------------------
# Recurrence
# --------------------------------------------------------------------------

def parse_rrule(text: str) -> dict:
    rule = {}
    for part in text.split(";"):
        if "=" in part:
            k, v = part.split("=", 1)
            rule[k.upper()] = v
    return rule


def _byday(value):
    """'1MO,-1FR,TU' -> [(1, 0), (-1, 4), (None, 1)]"""
    out = []
    for item in value.split(","):
        m = re.fullmatch(r"([+-]?\d+)?(MO|TU|WE|TH|FR|SA|SU)", item.strip().upper())
        if m:
            out.append((int(m.group(1)) if m.group(1) else None, WEEKDAYS.index(m.group(2))))
    return out


def _ints(value):
    return [int(x) for x in value.split(",") if x.strip().lstrip("+-").isdigit()]


def _days_matching_byday(year, month, byday, scope_days):
    """Days (as date) in scope_days matching BYDAY entries, honoring ordinals."""
    out = set()
    for ordinal, wd in byday:
        matches = [d for d in scope_days if d.weekday() == wd]
        if ordinal is None:
            out.update(matches)
        elif matches and -len(matches) <= ordinal <= len(matches) and ordinal != 0:
            out.add(matches[ordinal - 1] if ordinal > 0 else matches[ordinal])
    return out


def _month_days(year, month):
    return [date(year, month, d) for d in range(1, _cal.monthrange(year, month)[1] + 1)]


def _apply_monthday(days, bymonthday):
    out = []
    for d in days:
        n = _cal.monthrange(d.year, d.month)[1]
        if d.day in bymonthday or (d.day - n - 1) in bymonthday:
            out.append(d)
    return out


def _setpos(cands, bysetpos):
    if not bysetpos:
        return cands
    out = []
    for pos in bysetpos:
        if 0 < pos <= len(cands):
            out.append(cands[pos - 1])
        elif 0 > pos >= -len(cands):
            out.append(cands[pos])
    return sorted(set(out))


def expand_rrule(dtstart, rule: dict, window_end, is_date: bool, limit=2000, window_start=None):
    """Yield occurrence starts (same type/zone as dtstart) up to window_end.

    Expansion runs on the wall clock of dtstart's zone, so a weekly 9:00
    meeting stays at 9:00 across DST changes, as RFC 5545 requires.

    window_start (a date) lets a rule without COUNT jump straight to the
    period containing it, so a daily series that began years ago still
    reaches the window. `limit` counts periods from there on; walking in from
    DTSTART (needed with COUNT, which counts earlier occurrences) has its own
    much larger cap.
    """
    freq = rule.get("FREQ", "").upper()
    if freq not in ("DAILY", "WEEKLY", "MONTHLY", "YEARLY"):
        yield dtstart
        return
    interval = max(1, int(rule.get("INTERVAL", "1") or 1))
    count = int(rule["COUNT"]) if rule.get("COUNT", "").isdigit() else None
    until = None
    if rule.get("UNTIL"):
        u = rule["UNTIL"]
        zone = None if is_date else dtstart.tzinfo
        try:
            uval, udate = parse_dt(Prop("UNTIL", {}, u), zone)
        except ValueError:
            uval, udate = None, False
        if uval is not None:
            if is_date:
                until = uval if udate else uval.date()
            else:
                until = (datetime.combine(uval, datetime.max.time()).replace(tzinfo=dtstart.tzinfo)
                         if udate else uval)
    byday = _byday(rule["BYDAY"]) if rule.get("BYDAY") else []
    bymonth = _ints(rule.get("BYMONTH", "")) if rule.get("BYMONTH") else []
    bymonthday = _ints(rule.get("BYMONTHDAY", "")) if rule.get("BYMONTHDAY") else []
    bysetpos = _ints(rule.get("BYSETPOS", "")) if rule.get("BYSETPOS") else []
    wkst = WEEKDAYS.index(rule.get("WKST", "MO").upper()) if rule.get("WKST", "MO").upper() in WEEKDAYS else 0

    start_day = dtstart if is_date else dtstart.date()
    tod = None if is_date else dtstart.timetz()
    end_day = window_end if isinstance(window_end, date) and not isinstance(window_end, datetime) else window_end.date()
    if until is not None:
        uday = until if is_date else until.date()
        end_day = min(end_day, uday)

    def to_value(d):
        if is_date:
            return d
        return datetime.combine(d, dtstart.time()).replace(tzinfo=dtstart.tzinfo)

    produced = 0
    periods = 0
    walked = 0
    cursor = start_day
    wday = None
    if window_start is not None:
        wday = window_start.date() if isinstance(window_start, datetime) else window_start
    if count is None and wday is not None and wday > start_day:
        if freq == "DAILY":
            cursor = start_day + timedelta(days=(wday - start_day).days // interval * interval)
        elif freq == "WEEKLY":
            first_week = start_day - timedelta(days=(start_day.weekday() - wkst) % 7)
            weeks = (wday - first_week).days // 7 // interval * interval
            cursor = first_week + timedelta(weeks=weeks)
        elif freq == "MONTHLY":
            months = ((wday.year - start_day.year) * 12 + wday.month - start_day.month) // interval * interval
            m0 = start_day.month - 1 + months
            cursor = date(start_day.year + m0 // 12, m0 % 12 + 1, 1)
        else:
            cursor = date(start_day.year + (wday.year - start_day.year) // interval * interval, 1, 1)
    while True:
        if wday is None or cursor >= wday - timedelta(days=366):
            periods += 1
            if periods > limit:
                return
        else:
            walked += 1
            if walked > 200000:
                return
        if freq == "DAILY":
            cands = [cursor]
            if bymonth:
                cands = [d for d in cands if d.month in bymonth]
            if bymonthday:
                cands = _apply_monthday(cands, bymonthday)
            if byday:
                wds = {wd for _, wd in byday}
                cands = [d for d in cands if d.weekday() in wds]
            nxt = cursor + timedelta(days=interval)
        elif freq == "WEEKLY":
            week_start = cursor - timedelta(days=(cursor.weekday() - wkst) % 7)
            days = [week_start + timedelta(days=i) for i in range(7)]
            wds = {wd for _, wd in byday} if byday else {start_day.weekday()}
            cands = [d for d in days if d.weekday() in wds]
            if bymonth:
                cands = [d for d in cands if d.month in bymonth]
            cursor = week_start
            nxt = week_start + timedelta(weeks=interval)
        elif freq == "MONTHLY":
            y, m = cursor.year, cursor.month
            if bymonth and m not in bymonth:
                cands = []
            else:
                days = _month_days(y, m)
                if byday or bymonthday:
                    cands = days
                    if bymonthday:
                        cands = _apply_monthday(cands, bymonthday)
                    if byday:
                        allowed = _days_matching_byday(y, m, byday, days)
                        cands = [d for d in cands if d in allowed]
                else:
                    cands = [d for d in days if d.day == start_day.day]
            m2 = m - 1 + interval
            nxt = date(y + m2 // 12, m2 % 12 + 1, 1)
            cursor = date(y, m, 1)
        else:  # YEARLY
            y = cursor.year
            months = bymonth or (list(range(1, 13)) if (bymonthday or byday) else [start_day.month])
            cands = []
            if byday and not bymonth and not bymonthday:
                year_days = [date(y, 1, 1) + timedelta(days=i) for i in range(366 if _cal.isleap(y) else 365)]
                cands = sorted(_days_matching_byday(y, None, byday, year_days))
            else:
                for m in months:
                    days = _month_days(y, m)
                    if bymonthday or byday:
                        sel = days
                        if bymonthday:
                            sel = _apply_monthday(sel, bymonthday)
                        if byday:
                            allowed = _days_matching_byday(y, m, byday, days)
                            sel = [d for d in sel if d in allowed]
                        cands.extend(sel)
                    elif start_day.day <= len(days):
                        cands.append(date(y, m, start_day.day))
            nxt = date(y + interval, 1, 1)
            cursor = date(y, 1, 1)

        cands = _setpos(sorted(cands), bysetpos)
        for d in cands:
            if d < start_day:
                continue
            if d > end_day:
                return
            value = to_value(d)
            if until is not None and not is_date and value > until:
                return
            yield value
            produced += 1
            if count is not None and produced >= count:
                return
        if cursor > end_day:
            return
        cursor = nxt


# --------------------------------------------------------------------------
# Conversion to plugin records
# --------------------------------------------------------------------------

def _stamp(value, is_date):
    if is_date:
        return value.strftime("%Y-%m-%d")
    return value.astimezone(local_zone()).strftime("%Y-%m-%dT%H:%M")


def _norm_key(value, is_date):
    """Comparable identity for an occurrence start (RECURRENCE-ID / EXDATE)."""
    if is_date or not isinstance(value, datetime):
        return value.strftime("%Y%m%d") if isinstance(value, date) else str(value)
    return value.astimezone(timezone.utc).strftime("%Y%m%dT%H%M%S")


def _record(props, start, is_date, duration, calendar_id, base_uid, recurring, extra):
    end = start + duration
    tz = "" if is_date else zone_name(first(props, "DTSTART"))
    if is_date:
        last = end - timedelta(days=1)
        if last < start:
            last = start
        end_text = last.strftime("%Y-%m-%d")
    else:
        end_text = _stamp(end, False)
    summary = first(props, "SUMMARY")
    loc = first(props, "LOCATION")
    desc = first(props, "DESCRIPTION")
    rec = {
        "uid": base_uid + ("@" + _norm_key(start, is_date) if recurring else ""),
        "sourceUid": base_uid,
        "calendarId": calendar_id,
        "title": unescape(summary.value) if summary else "(no title)",
        "allDay": is_date,
        "start": _stamp(start, is_date),
        "end": end_text,
        "location": unescape(loc.value) if loc else "",
        "notes": unescape(desc.value) if desc else "",
        "recurring": recurring,
    }
    if tz and tz != local_zone_name():
        rec["tz"] = tz
    rec.update(extra)
    return rec


def events_from_text(text, calendar_id, window_start, window_end, extra=None, default_zone=None):
    """Expanded plugin records for every VEVENT in an iCalendar document.

    window_start/window_end are aware datetimes. `extra` is merged into each
    record (e.g. href/etag/readOnly).
    """
    extra = extra or {}
    cal_props, comps = parse_components(text)
    wr_tz = first(cal_props, "X-WR-TIMEZONE")
    zone = default_zone or zone_for(wr_tz.value if wr_tz else None, local_zone()) or local_zone()

    masters, overrides = {}, {}
    for props in comps:
        uid_p = first(props, "UID")
        if uid_p and uid_p.value.strip():
            uid = uid_p.value.strip()
        else:
            # No UID (some hand-made feeds): derive a stable one, so hiding
            # an event keeps working across syncs.
            ds_p, sm_p = first(props, "DTSTART"), first(props, "SUMMARY")
            seed = (ds_p.value if ds_p else "") + "|" + (sm_p.value if sm_p else "")
            uid = "nouid-" + hashlib.sha1(seed.encode("utf-8")).hexdigest()[:16]
        status = first(props, "STATUS")
        rid = first(props, "RECURRENCE-ID")
        if rid:
            try:
                rv, rdate = parse_dt(rid, zone)
                overrides.setdefault(uid, {})[_norm_key(rv, rdate)] = props
            except ValueError:
                pass
            continue
        if status and status.value.upper() == "CANCELLED":
            masters[uid] = None
            continue
        masters[uid] = props

    wstart_day = window_start.date()
    wend_day = window_end.date()
    out = []
    for uid, props in masters.items():
        if props is None:
            continue
        ds = first(props, "DTSTART")
        if ds is None:
            continue
        try:
            start, is_date = parse_dt(ds, zone)
        except ValueError:
            continue
        de = first(props, "DTEND")
        dur = first(props, "DURATION")
        if de is not None:
            try:
                end, end_is_date = parse_dt(de, zone)
                if is_date and not end_is_date:
                    end = end.date()
                elif not is_date and end_is_date:
                    end = datetime.combine(end, datetime.min.time()).replace(tzinfo=start.tzinfo)
                duration = end - start
            except (ValueError, TypeError):
                duration = timedelta(days=1) if is_date else timedelta(0)
        elif dur is not None:
            duration = parse_duration(dur.value)
        else:
            duration = timedelta(days=1) if is_date else timedelta(0)
        if duration < timedelta(0):
            duration = timedelta(0)

        rrule = first(props, "RRULE")
        recurring = rrule is not None or bool(all_of(props, "RDATE"))
        if not recurring:
            if _overlaps(start, duration, is_date, wstart_day, wend_day, window_start, window_end):
                out.append(_record(props, start, is_date, duration, calendar_id, uid, False, extra))
            continue

        exdates = set()
        for ex in all_of(props, "EXDATE"):
            for v in parse_dt_list(ex, zone):
                exdates.add(_norm_key(v, is_date or not isinstance(v, datetime)))
        starts = []
        if rrule is not None:
            # Occurrences that started before the window but are still running count;
            # a day of slack covers zone differences.
            skip_to = (wstart_day - duration if is_date else (window_start - duration).date()) - timedelta(days=1)
            starts.extend(expand_rrule(start, parse_rrule(rrule.value), wend_day if is_date else window_end, is_date,
                                       window_start=skip_to))
        else:
            starts.append(start)
        for rd in all_of(props, "RDATE"):
            for v in parse_dt_list(rd, zone):
                if is_date and isinstance(v, datetime):
                    v = v.date()
                starts.append(v)
        seen = set()
        ov = overrides.get(uid, {})
        # Repeating occurrences say which series rule they belong to and
        # which occurrence they are (RECURRENCE-ID form), for editing.
        sextra = dict(extra, rrule=rrule.value if rrule is not None else "")
        for occ in sorted(set(starts), key=lambda v: _norm_key(v, is_date)):
            key = _norm_key(occ, is_date)
            if key in exdates or key in seen:
                continue
            seen.add(key)
            if key in ov:
                continue  # handled below
            if _overlaps(occ, duration, is_date, wstart_day, wend_day, window_start, window_end):
                rec = _record(props, occ, is_date, duration, calendar_id, uid, True, sextra)
                rec["recurrenceId"] = key
                out.append(rec)
        for key, oprops in ov.items():
            ostatus = first(oprops, "STATUS")
            if ostatus and ostatus.value.upper() == "CANCELLED":
                continue
            ods = first(oprops, "DTSTART")
            try:
                ostart, odate = parse_dt(ods, zone) if ods else (None, is_date)
            except ValueError:
                continue
            if ostart is None:
                continue
            ode = first(oprops, "DTEND")
            odur = first(oprops, "DURATION")
            if ode is not None:
                try:
                    oend, _ = parse_dt(ode, zone)
                    oduration = oend - ostart
                except (ValueError, TypeError):
                    oduration = duration
            elif odur is not None:
                oduration = parse_duration(odur.value)
            else:
                oduration = duration
            if _overlaps(ostart, oduration, odate, wstart_day, wend_day, window_start, window_end):
                rec = _record(oprops, ostart, odate, oduration, calendar_id, uid, True, sextra)
                rec["uid"] = uid + "@" + key
                rec["recurrenceId"] = key
                out.append(rec)
    return out


def _overlaps(start, duration, is_date, wstart_day, wend_day, wstart, wend):
    if is_date:
        end = start + max(duration, timedelta(days=1))
        return start <= wend_day and end > wstart_day
    end = start + duration
    return start <= wend and end >= wstart


# --------------------------------------------------------------------------
# Writing
# --------------------------------------------------------------------------

def fold(line: str) -> str:
    """Split at 75 octets (RFC 5545 3.1), never inside a UTF-8 character."""
    out, cur, size = [], [], 0
    for ch in line:
        n = len(ch.encode("utf-8"))
        if size + n > 75:
            out.append("".join(cur))
            cur, size = [" "], 1
        cur.append(ch)
        size += n
    out.append("".join(cur))
    return "\r\n".join(out)


def event_zone(ev) -> str:
    """The zone a timed event is written in: its own, else this machine's."""
    tz = (ev.get("tz") or "").strip()
    if tz and tzdata.valid(tz):
        return tz
    return local_zone_name()


def _local_dt(stamp: str) -> datetime:
    return datetime.strptime(stamp, "%Y-%m-%dT%H:%M").replace(tzinfo=local_zone())


def fmt_in_zone(dt: datetime, zone: str) -> str:
    """DTSTART-style value: "TZID=<zone>:<wall>" or a UTC value when no zone."""
    if not zone:
        return ":" + fmt_utc(dt)
    return f";TZID={zone}:" + dt.astimezone(ZoneInfo(zone)).strftime("%Y%m%dT%H%M%S")


def _time_props(ev):
    """DTSTART/DTEND lines for a plugin event record (start/end are local
    wall time). Timed events are written in the event's zone with a TZID,
    never as bare UTC, so a repeating 9:00 stays at 9:00 across DST."""
    if ev.get("allDay"):
        s = datetime.strptime(ev["start"], "%Y-%m-%d").date()
        e = datetime.strptime(ev.get("end") or ev["start"], "%Y-%m-%d").date() + timedelta(days=1)
        return [f"DTSTART;VALUE=DATE:{fmt_date(s)}", f"DTEND;VALUE=DATE:{fmt_date(e)}"]
    zone = event_zone(ev)
    s = _local_dt(ev["start"])
    e = _local_dt(ev.get("end") or ev["start"])
    return ["DTSTART" + fmt_in_zone(s, zone), "DTEND" + fmt_in_zone(e, zone)]


def zones_needed(ev) -> list[str]:
    if ev.get("allDay"):
        return []
    z = event_zone(ev)
    return [z] if z and z != "UTC" else []


def _vtimezones(zones, year=None):
    out = []
    for z in zones:
        out += tzdata.vtimezone(z, year)
    return out


def _text_props(ev):
    lines = ["SUMMARY:" + escape(ev.get("title", ""))]
    if ev.get("location"):
        lines.append("LOCATION:" + escape(ev["location"]))
    if ev.get("notes"):
        lines.append("DESCRIPTION:" + escape(ev["notes"]))
    return lines


def _start_year(ev):
    try:
        return int(str(ev.get("start", ""))[:4]) - 1
    except ValueError:
        return None


def new_vcalendar(ev, uid):
    now = fmt_utc(datetime.now(timezone.utc))
    body = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Omarchy//Calendar Plugin//EN", "CALSCALE:GREGORIAN"]
    body += _vtimezones(zones_needed(ev), _start_year(ev))
    body += ["BEGIN:VEVENT", f"UID:{uid}", f"DTSTAMP:{now}", f"CREATED:{now}", f"LAST-MODIFIED:{now}"]
    body += _time_props(ev) + _text_props(ev)
    body += ["SEQUENCE:0", "END:VEVENT", "END:VCALENDAR"]
    return "\r\n".join(fold(l) for l in body) + "\r\n"


REPLACED = {"DTSTART", "DTEND", "DURATION", "SUMMARY", "LOCATION", "DESCRIPTION", "DTSTAMP", "LAST-MODIFIED", "SEQUENCE"}


def _defined_zones(lines) -> set[str]:
    out, in_tz = set(), False
    for line in lines:
        prop = parse_line(line)
        if not prop:
            continue
        if prop.name == "BEGIN" and prop.value.upper() == "VTIMEZONE":
            in_tz = True
        elif prop.name == "END" and prop.value.upper() == "VTIMEZONE":
            in_tz = False
        elif in_tz and prop.name == "TZID":
            out.add(prop.value.strip())
    return out


def edit_vcalendar(original: str, ev) -> str:
    """Rewrite the master VEVENT's time/text properties, keeping the rest.

    A VTIMEZONE is added for the event's zone when the object lacks one.
    """
    lines = unfold(original)
    missing = [z for z in zones_needed(ev) if z not in _defined_zones(lines)]
    out, in_event, depth, ev_depth, seq, done = [], False, 0, 0, 0, False
    for line in lines:
        prop = parse_line(line)
        if prop and prop.name == "BEGIN":
            depth += 1
            if prop.value.upper() == "VEVENT" and not done and not in_event:
                if missing:
                    out += _vtimezones(missing, _start_year(ev))
                    missing = []
                in_event, ev_depth = True, depth
                out.append(line)
                continue
        if prop and prop.name == "END":
            depth -= 1
            if prop.value.upper() == "VEVENT" and in_event:
                now = fmt_utc(datetime.now(timezone.utc))
                out += _time_props(ev) + _text_props(ev)
                out += [f"DTSTAMP:{now}", f"LAST-MODIFIED:{now}", f"SEQUENCE:{seq + 1}"]
                out.append(line)
                in_event, done = False, True
                continue
        # Only the event's own properties: a VALARM inside keeps its
        # DESCRIPTION/SUMMARY (an alarm without them is invalid).
        if in_event and prop and depth == ev_depth:
            if prop.name == "SEQUENCE":
                try:
                    seq = int(prop.value)
                except ValueError:
                    seq = 0
                continue
            if prop.name in REPLACED:
                continue
        out.append(line)
    return "\r\n".join(fold(l) for l in out) + "\r\n"


def is_recurring_text(text: str) -> bool:
    _, comps = parse_components(text)
    return any(first(c, "RRULE") or first(c, "RDATE") or first(c, "RECURRENCE-ID") for c in comps)
