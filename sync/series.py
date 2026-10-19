"""Editing repeating events in iCalendar objects (standard library only).

A CalDAV object holding a series is one VCALENDAR with a master VEVENT (the
RRULE) and optional override VEVENTs (RECURRENCE-ID). Edits follow the usual
calendar-app scopes:

  this       one occurrence: an override VEVENT (or EXDATE to delete it)
  following  this and later ones: the master ends before it (UNTIL) and a new
             series starts here (a separate object with a new UID)
  all        the master changes; occurrences move by the same wall-clock delta

Occurrences are named by key, as ical._norm_key makes them: UTC
"yyyyMMddTHHmmss" for timed series, "yyyyMMdd" for all-day ones.

Unknown properties and components (attendees, alarms, X- properties) are kept.
"""

from __future__ import annotations

from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import ical


# --------------------------------------------------------------------------
# A small component tree that round-trips text it does not touch
# --------------------------------------------------------------------------

class Comp:
    def __init__(self, name):
        self.name = name
        self.items = []          # raw property lines (str) and child Comps

    # ---- properties
    def props(self, name=None):
        for it in self.items:
            if isinstance(it, str):
                p = ical.parse_line(it)
                if p and (name is None or p.name == name):
                    yield p

    def prop(self, name):
        return next(self.props(name), None)

    def remove(self, *names):
        keep = set(names)
        self.items = [it for it in self.items
                      if not (isinstance(it, str) and (ical.parse_line(it) or ical.Prop("", {}, "")).name in keep)]

    def add(self, lines):
        """Insert property lines after the existing ones, before children."""
        i = len(self.items)
        for j, it in enumerate(self.items):
            if isinstance(it, Comp):
                i = j
                break
        self.items[i:i] = list(lines)

    # ---- children
    def children(self, name=None):
        return [it for it in self.items if isinstance(it, Comp) and (name is None or it.name == name)]

    def lines(self):
        out = ["BEGIN:" + self.name]
        for it in self.items:
            out.extend(it.lines() if isinstance(it, Comp) else [it])
        out.append("END:" + self.name)
        return out


def parse_tree(text: str) -> Comp:
    stack = [Comp("ROOT")]
    for line in ical.unfold(text):
        p = ical.parse_line(line)
        if p and p.name == "BEGIN":
            c = Comp(p.value.upper())
            stack[-1].items.append(c)
            stack.append(c)
        elif p and p.name == "END" and len(stack) > 1:
            stack.pop()
        else:
            stack[-1].items.append(line)
    cals = stack[0].children("VCALENDAR")
    if not cals:
        raise ValueError("not an iCalendar object")
    return cals[0]


def serialize(cal: Comp) -> str:
    return "\r\n".join(ical.fold(l) for l in cal.lines()) + "\r\n"


def master_of(cal: Comp) -> Comp:
    for ev in cal.children("VEVENT"):
        if ev.prop("RECURRENCE-ID") is None:
            return ev
    raise ValueError("no master event")


def override_of(cal: Comp, key: str, zone) -> Comp | None:
    for ev in cal.children("VEVENT"):
        rid = ev.prop("RECURRENCE-ID")
        if rid is not None and occ_key(rid, zone) == key:
            return ev
    return None


def occ_key(prop, zone) -> str:
    v, is_date = ical.parse_dt(prop, zone)
    return ical._norm_key(v, is_date)


# --------------------------------------------------------------------------
# Times
# --------------------------------------------------------------------------

def master_start(master: Comp):
    """-> (value, is_date, zone): DTSTART as an aware datetime (or date)."""
    ds = master.prop("DTSTART")
    if ds is None:
        raise ValueError("series has no DTSTART")
    zone = ical.zone_for(ds.params.get("TZID"), ical.local_zone()) or ical.local_zone()
    v, is_date = ical.parse_dt(ds, zone)
    if not is_date and ds.value.strip().upper().endswith("Z"):
        zone = ical.local_zone()   # UTC series: keep wall-clock math local
    return v, is_date, zone


def master_duration(master: Comp, start, is_date):
    de, du = master.prop("DTEND"), master.prop("DURATION")
    if de is not None:
        end, _ = ical.parse_dt(de, start.tzinfo if not is_date else None)
        if is_date and isinstance(end, datetime):
            end = end.date()
        return end - start
    if du is not None:
        return ical.parse_duration(du.value)
    return timedelta(days=1) if is_date else timedelta(0)


def key_instant(key: str):
    """Occurrence key -> aware UTC datetime, or a date."""
    if "T" not in key:
        return date(int(key[0:4]), int(key[4:6]), int(key[6:8]))
    return datetime.strptime(key, "%Y%m%dT%H%M%S").replace(tzinfo=timezone.utc)


def fmt_like(value, is_date, zone_name):
    """;TZID=..:wall / ;VALUE=DATE:.. / :...Z text for DTSTART-like props."""
    if is_date:
        return ";VALUE=DATE:" + ical.fmt_date(value)
    return ical.fmt_in_zone(value, zone_name)


def zone_name_of(master: Comp) -> str:
    ds = master.prop("DTSTART")
    name = ical.zone_name(ds)
    return name


def until_before(key: str, is_date: bool) -> str:
    """UNTIL value ending a series just before the occurrence `key`."""
    inst = key_instant(key)
    if is_date:
        return ical.fmt_date(inst - timedelta(days=1))
    return ical.fmt_utc(inst - timedelta(seconds=1))


def _local_dt(stamp):
    return datetime.strptime(stamp, "%Y-%m-%dT%H:%M").replace(tzinfo=ical.local_zone())


def _ev_start(ev):
    if ev.get("allDay"):
        return datetime.strptime(ev["start"], "%Y-%m-%d").date()
    return _local_dt(ev["start"])


def _ev_end(ev):
    if ev.get("allDay"):
        return datetime.strptime(ev.get("end") or ev["start"], "%Y-%m-%d").date() + timedelta(days=1)
    return _local_dt(ev.get("end") or ev["start"])


# --------------------------------------------------------------------------
# Rules
# --------------------------------------------------------------------------

def rule_text(master: Comp) -> str:
    r = master.prop("RRULE")
    return r.value if r is not None else ""


def format_rule(rule: dict) -> str:
    order = ["FREQ", "INTERVAL", "COUNT", "UNTIL", "BYMONTH", "BYMONTHDAY", "BYDAY", "BYSETPOS", "WKST"]
    keys = [k for k in order if rule.get(k)] + [k for k in rule if k not in order and rule.get(k)]
    return ";".join(f"{k}={rule[k]}" for k in keys)


def count_before(master: Comp, key: str) -> int:
    """How many occurrences of the series come before occurrence `key`."""
    start, is_date, zone = master_start(master)
    rule = ical.parse_rrule(rule_text(master))
    target = key_instant(key)
    n = 0
    end = target if is_date else target + timedelta(days=1)
    for occ in ical.expand_rrule(start, rule, end, is_date):
        if (occ if is_date else occ.astimezone(timezone.utc)) >= target:
            break
        n += 1
    return n


# --------------------------------------------------------------------------
# Edits
# --------------------------------------------------------------------------

def _stamp_lines():
    now = ical.fmt_utc(datetime.now(timezone.utc))
    return [f"DTSTAMP:{now}", f"LAST-MODIFIED:{now}"]


def _bump(comp: Comp):
    seq = comp.prop("SEQUENCE")
    try:
        n = int(seq.value) + 1 if seq is not None else 0
    except ValueError:
        n = 1
    comp.remove("SEQUENCE", "DTSTAMP", "LAST-MODIFIED")
    comp.add([f"SEQUENCE:{n}"] + _stamp_lines())


def _set_text(comp: Comp, ev):
    comp.remove("SUMMARY", "LOCATION", "DESCRIPTION")
    comp.add(ical._text_props(ev))


def _set_times(comp: Comp, ev):
    comp.remove("DTSTART", "DTEND", "DURATION")
    comp.add(ical._time_props(ev))


def _ensure_zones(cal: Comp, ev):
    have = {p.value.strip() for tz in cal.children("VTIMEZONE") for p in tz.props("TZID")}
    missing = [z for z in ical.zones_needed(ev) if z not in have]
    if not missing:
        return
    tree = parse_tree("BEGIN:VCALENDAR\r\n" + "\r\n".join(ical._vtimezones(missing, ical._start_year(ev))) + "\r\nEND:VCALENDAR\r\n")
    first_event = next((i for i, it in enumerate(cal.items) if isinstance(it, Comp) and it.name == "VEVENT"), len(cal.items))
    cal.items[first_event:first_event] = tree.children("VTIMEZONE")


def _drop_overrides(cal: Comp, keep=lambda key: False, zone=None):
    cal.items = [it for it in cal.items
                 if not (isinstance(it, Comp) and it.name == "VEVENT" and it.prop("RECURRENCE-ID") is not None
                         and not keep(occ_key(it.prop("RECURRENCE-ID"), zone)))]


def _exdate_keys(master: Comp, zone):
    out = []
    for p in master.props("EXDATE"):
        for v in ical.parse_dt_list(p, zone):
            out.append(ical._norm_key(v, not isinstance(v, datetime)))
    return out


def _set_exdates(master: Comp, keys, is_date):
    master.remove("EXDATE")
    for k in sorted(set(keys)):
        inst = key_instant(k)
        master.add([f"EXDATE;VALUE=DATE:{k}" if is_date else f"EXDATE:{ical.fmt_utc(inst)}"])


def edit_this(text: str, key: str, ev) -> str:
    """Change one occurrence: add or update its override VEVENT."""
    cal = parse_tree(text)
    master = master_of(cal)
    start, is_date, zone = master_start(master)
    ov = override_of(cal, key, zone)
    if ov is None:
        ov = Comp("VEVENT")
        # Start from the master's own properties (attendees, alarms, ...),
        # minus the ones that describe the series.
        for it in master.items:
            if isinstance(it, Comp):
                ov.items.append(it)
                continue
            p = ical.parse_line(it)
            if p and p.name in ("RRULE", "RDATE", "EXDATE", "EXRULE", "SEQUENCE", "DTSTAMP", "LAST-MODIFIED",
                                "CREATED", "DTSTART", "DTEND", "DURATION"):
                continue
            ov.items.append(it)
        inst = key_instant(key)
        if is_date:
            rid = f"RECURRENCE-ID;VALUE=DATE:{key}"
        else:
            zn = zone_name_of(master)
            rid = "RECURRENCE-ID" + (ical.fmt_in_zone(inst, zn) if zn else ":" + ical.fmt_utc(inst))
        ov.add([rid])
        cal.items.append(ov)
    _ensure_zones(cal, ev)
    _set_times(ov, ev)
    _set_text(ov, ev)
    _bump(ov)
    return serialize(cal)


def edit_all(text: str, key: str, ev) -> str:
    """Change the whole series. The occurrence `key` was edited into `ev`
    (local times); every occurrence moves by the same wall-clock change.
    ev["rrule"], when present, replaces the rule; a different rule (or a
    switch between all-day and timed) drops exceptions and overrides, which
    referred to the old pattern."""
    cal = parse_tree(text)
    master = master_of(cal)
    start, is_date, zone = master_start(master)
    old_rule = rule_text(master)
    new_rule = ev.get("rrule", old_rule) or ""
    new_is_date = bool(ev.get("allDay"))
    inst = key_instant(key)

    if new_is_date or is_date:
        occ_old = inst if is_date else inst.astimezone(zone).date()
        occ_new = _ev_start(ev) if new_is_date else _ev_start(ev).date()
        old_master = start if is_date else start.astimezone(zone).date()
        day_shift = occ_new - occ_old
        new_master_day = old_master + day_shift
        length = _ev_end(ev) - _ev_start(ev)
        if new_is_date:
            series = dict(ev, start=new_master_day.isoformat(),
                          end=(new_master_day + length - timedelta(days=1)).isoformat())
        else:
            s = datetime.combine(new_master_day, _ev_start(ev).timetz())
            series = dict(ev, start=s.strftime("%Y-%m-%dT%H:%M"), end=(s + length).strftime("%Y-%m-%dT%H:%M"))
        shift = day_shift if (is_date and new_is_date) else None
    else:
        new_zone_name = ical.event_zone(ev)
        new_zone = ZoneInfo(new_zone_name) if new_zone_name else zone
        old_occ_wall = inst.astimezone(zone).replace(tzinfo=None)
        old_master_wall = start.astimezone(zone).replace(tzinfo=None)
        new_occ_wall = _ev_start(ev).astimezone(new_zone).replace(tzinfo=None)
        new_master_wall = new_occ_wall - (old_occ_wall - old_master_wall)
        new_master = new_master_wall.replace(tzinfo=new_zone)
        length = _ev_end(ev) - _ev_start(ev)
        to_local = lambda d: d.astimezone(ical.local_zone()).strftime("%Y-%m-%dT%H:%M")  # noqa: E731
        series = dict(ev, start=to_local(new_master), end=to_local(new_master + length))
        shift = new_occ_wall - old_occ_wall if new_zone_name == (zone_name_of(master) or ical.local_zone_name()) else None

    pattern_changed = (ical.parse_rrule(new_rule) != ical.parse_rrule(old_rule)) or new_is_date != is_date
    _ensure_zones(cal, series)
    _set_times(master, series)
    _set_text(master, series)
    master.remove("RRULE")
    if new_rule:
        master.add(["RRULE:" + new_rule])
    if pattern_changed or shift is None:
        master.remove("EXDATE", "RDATE")
        _drop_overrides(cal)
    elif shift:
        # Exceptions and overrides name occurrences by their old start.
        moved = lambda k: ical._norm_key(key_instant(k) + shift, "T" not in k)  # noqa: E731
        _set_exdates(master, [moved(k) for k in _exdate_keys(master, zone)], is_date)
        for ov in cal.children("VEVENT"):
            rid = ov.prop("RECURRENCE-ID")
            if rid is None:
                continue
            old = key_instant(occ_key(rid, zone))
            ov.remove("RECURRENCE-ID")
            zn = zone_name_of(master)
            if is_date:
                ov.add([f"RECURRENCE-ID;VALUE=DATE:{ical.fmt_date(old + shift)}"])
            else:
                ov.add(["RECURRENCE-ID" + (ical.fmt_in_zone(old + shift, zn) if zn else ":" + ical.fmt_utc(old + shift))])
    _bump(master)
    return serialize(cal)


def end_before(text: str, key: str):
    """End the series just before occurrence `key`.

    -> (new text, or None when `key` is the first occurrence: nothing is
       left and the object should be deleted; count_left: occurrences the
       series still had from `key` on when it was COUNT-limited, else None)
    """
    cal = parse_tree(text)
    master = master_of(cal)
    start, is_date, zone = master_start(master)
    if key <= ical._norm_key(start, is_date):
        return None, None
    rule = ical.parse_rrule(rule_text(master))
    count_left = None
    if rule.get("COUNT", "").isdigit():
        before = count_before(master, key)
        count_left = max(0, int(rule["COUNT"]) - before)
        rule.pop("COUNT")
    rule["UNTIL"] = until_before(key, is_date)
    master.remove("RRULE")
    master.add(["RRULE:" + format_rule(rule)])
    _set_exdates(master, [k for k in _exdate_keys(master, zone) if k < key], is_date)
    _drop_overrides(cal, keep=lambda k: k < key, zone=zone)
    _bump(master)
    return serialize(cal), count_left


def split(text: str, key: str, ev, new_uid: str):
    """'This and following': -> (old object text, or None to delete it;
    new object text, a series starting at the edited occurrence)."""
    old_text, count_left = end_before(text, key)
    base = ev.get("rrule") if ev.get("rrule") is not None else rule_text(master_of(parse_tree(text)))
    rule = ical.parse_rrule(base) if base else {}
    if rule and count_left is not None and "UNTIL" not in rule:
        rule["COUNT"] = str(max(1, count_left))   # what was left of a COUNT-limited series
    new_ev = dict(ev, rrule=format_rule(rule) if rule.get("FREQ") else "")
    new_ev.pop("exdates", None)
    return old_text, new_vcalendar(new_ev, new_uid)


def delete_this(text: str, key: str) -> str:
    cal = parse_tree(text)
    master = master_of(cal)
    start, is_date, zone = master_start(master)
    _set_exdates(master, _exdate_keys(master, zone) + [key], is_date)
    _drop_overrides(cal, keep=lambda k: k != key, zone=zone)
    _bump(master)
    return serialize(cal)


def add_rule(text: str, rule: str) -> str:
    """Make a single event repeat."""
    cal = parse_tree(text)
    master = master_of(cal)
    master.remove("RRULE")
    master.add(["RRULE:" + rule])
    return serialize(cal)


def new_vcalendar(ev, uid):
    """ical.new_vcalendar plus RRULE/EXDATE for a series."""
    text = ical.new_vcalendar(ev, uid)
    if not ev.get("rrule"):
        return text
    cal = parse_tree(text)
    master = master_of(cal)
    master.add(["RRULE:" + ev["rrule"]])
    if ev.get("exdates"):
        _set_exdates(master, ev["exdates"], bool(ev.get("allDay")))
    return serialize(cal)


def _fields(props, start, is_date, duration):
    rec = ical._record(props, start, is_date, duration, "", "", False, {})
    return {k: rec[k] for k in ("title", "allDay", "start", "end", "location", "notes") if k in rec}


def series_record(text: str):
    """The master as a local series record (for moving a synced series to a
    local calendar); overrides become local overrides by key."""
    cal = parse_tree(text)
    master = master_of(cal)
    start, is_date, zone = master_start(master)
    dur = master_duration(master, start, is_date)
    out = _fields(list(master.props()), start, is_date, dur)
    zn = zone_name_of(master)
    if zn and zn != ical.local_zone_name() and not is_date:
        out["tz"] = zn
    out["rrule"] = rule_text(master)
    out["exdates"] = _exdate_keys(master, zone)
    overrides = {}
    for ov in cal.children("VEVENT"):
        rid = ov.prop("RECURRENCE-ID")
        if rid is None:
            continue
        k = occ_key(rid, zone)
        status = ov.prop("STATUS")
        if status is not None and status.value.upper() == "CANCELLED":
            overrides[k] = {"cancelled": True}
            continue
        ods = ov.prop("DTSTART")
        if ods is None:
            continue
        os_, odate = ical.parse_dt(ods, zone)
        odur = master_duration(ov, os_, odate) if (ov.prop("DTEND") or ov.prop("DURATION")) else dur
        overrides[k] = _fields(list(ov.props()), os_, odate, odur)
    if overrides:
        out["overrides"] = overrides
    return out
