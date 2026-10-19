"""VTODO (RFC 5545 tasks) <-> the app's task records. Standard library only.

A task record (the same shape for local tasks in tasks.json and for synced
ones in remote.json):

  uid, listId, title, notes,
  status       NEEDS-ACTION | IN-PROCESS | COMPLETED | CANCELLED
  completed    local stamp "yyyy-MM-ddTHH:mm" when completed, else ""
  percent      0..100
  priority     0 (none), 1..9 (1 highest; 1-4 high, 5 medium, 6-9 low)
  due, start   "yyyy-MM-dd" (a day) or "yyyy-MM-ddTHH:mm" (local wall time), or ""
  tz           zone of a timed due/start when it is not this machine's
  rrule        RRULE value of a repeating task ("" = none)
  repeatFrom   "due" (next date follows the schedule) or "completion"
  exdates      skipped occurrences (keys like ical._norm_key)
  doneKeys     occurrences another app completed with an override VTODO
  parent       UID of the parent task (RELATED-TO;RELTYPE=PARENT), or ""
  project      true for a task marked as a project (X-OMARCHY-PROJECT; a
               top-level task with subtasks counts as one anyway)
  categories   [tag, ...]
  created, updated   local stamps
  sortOrder    X-APPLE-SORT-ORDER, when present
  + href, etag, readOnly for synced tasks

Recurrence itself (what "complete" does to a repeating task) is computed in
Tasks.js, once for local and synced tasks alike; here a repeating task is
only read and written field by field.

Edits replace only the properties the app owns and keep everything else
(alarms, attachments, X- properties, other RELATED-TO types).
"""

from __future__ import annotations

import hashlib
import re
from datetime import datetime, timezone

import ical
import tzdata

STATUSES = ("NEEDS-ACTION", "IN-PROCESS", "COMPLETED", "CANCELLED")
REPEAT_FROM = "X-OMARCHY-REPEAT-FROM"
PROJECT = "X-OMARCHY-PROJECT"
PRODID = "-//Omarchy//Tasks//EN"

# Properties the form owns. RELATED-TO is owned only for the parent link.
OWNED = {"SUMMARY", "DESCRIPTION", "STATUS", "COMPLETED", "PERCENT-COMPLETE", "PRIORITY", "DUE", "DTSTART",
         "DURATION", "RRULE", "EXDATE", "CATEGORIES", REPEAT_FROM, PROJECT, "DTSTAMP", "LAST-MODIFIED", "SEQUENCE"}


# --------------------------------------------------------------------------
# A component tree that round-trips the text it does not touch
# --------------------------------------------------------------------------

class Comp:
    def __init__(self, name):
        self.name = name
        self.items = []          # raw property lines (str) and child Comps

    def props(self, name=None):
        for it in self.items:
            if isinstance(it, str):
                p = ical.parse_line(it)
                if p and (name is None or p.name == name):
                    yield p

    def prop(self, name):
        return next(self.props(name), None)

    def drop(self, pred):
        """Remove property lines for which pred(Prop) is true."""
        keep = []
        for it in self.items:
            if isinstance(it, str):
                p = ical.parse_line(it)
                if p is not None and pred(p):
                    continue
            keep.append(it)
        self.items = keep

    def add(self, lines):
        """Insert property lines after the existing ones, before children."""
        i = len(self.items)
        for j, it in enumerate(self.items):
            if isinstance(it, Comp):
                i = j
                break
        self.items[i:i] = list(lines)

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
            c = Comp(p.value.strip().upper())
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
    for t in cal.children("VTODO"):
        if t.prop("RECURRENCE-ID") is None:
            return t
    raise ValueError("no task in this object")


def has_task(text: str) -> bool:
    try:
        master_of(parse_tree(text))
        return True
    except ValueError:
        return False


# --------------------------------------------------------------------------
# Reading
# --------------------------------------------------------------------------

def _stamp(value, is_date):
    if is_date:
        return value.strftime("%Y-%m-%d")
    return value.astimezone(ical.local_zone()).strftime("%Y-%m-%dT%H:%M")


def _when(prop, zone):
    """-> (stamp, zone name or "") for a DUE/DTSTART-like property."""
    if prop is None:
        return "", ""
    try:
        v, is_date = ical.parse_dt(prop, zone)
    except ValueError:
        return "", ""
    return _stamp(v, is_date), ("" if is_date else ical.zone_name(prop))


def _text(comp, name):
    p = comp.prop(name)
    return ical.unescape(p.value) if p is not None else ""


def _int(comp, name, lo, hi, default=0):
    p = comp.prop(name)
    try:
        return max(lo, min(hi, int(p.value.strip()))) if p is not None else default
    except ValueError:
        return default


def _split_list(value):
    """CATEGORIES value -> items (commas split, escaped commas kept)."""
    out, cur, esc = [], [], False
    for ch in value:
        if esc:
            cur.append(ch)
            esc = False
        elif ch == "\\":
            esc = True
            cur.append(ch)
        elif ch == ",":
            out.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    out.append("".join(cur))
    return [ical.unescape(x).strip() for x in out if x.strip()]


def _parent(comp):
    for p in comp.props("RELATED-TO"):
        if p.params.get("RELTYPE", "PARENT").upper() == "PARENT" and p.value.strip():
            return p.value.strip()
    return ""


def _uid(comp):
    p = comp.prop("UID")
    if p is not None and p.value.strip():
        return p.value.strip()
    seed = "|".join(x.value for x in (comp.prop("DTSTART"), comp.prop("DUE"), comp.prop("SUMMARY")) if x is not None)
    return "nouid-" + hashlib.sha1(seed.encode("utf-8")).hexdigest()[:16]


def _occ_key(prop, zone):
    v, is_date = ical.parse_dt(prop, zone)
    return ical._norm_key(v, is_date)


def record_of(task: Comp, overrides=(), list_id="", extra=None):
    zone = ical.local_zone()
    due, due_tz = _when(task.prop("DUE"), zone)
    start, start_tz = _when(task.prop("DTSTART"), zone)
    if not due and start and task.prop("DURATION") is not None:
        # DTSTART + DURATION is the other way to give a task a due time.
        try:
            v, is_date = ical.parse_dt(task.prop("DTSTART"), zone)
            due = _stamp(v + ical.parse_duration(task.prop("DURATION").value), is_date)
        except (ValueError, TypeError):
            pass
    status = _text(task, "STATUS").strip().upper()
    if status not in STATUSES:
        status = "NEEDS-ACTION"
    completed = ""
    cp = task.prop("COMPLETED")
    if cp is not None:
        try:
            v, is_date = ical.parse_dt(cp, timezone.utc)
            completed = _stamp(v, False) if not is_date else v.strftime("%Y-%m-%dT00:00")
        except ValueError:
            pass
    if completed and status == "NEEDS-ACTION":
        status = "COMPLETED"      # some clients only set COMPLETED
    rrule = task.prop("RRULE")
    exdates = []
    for p in task.props("EXDATE"):
        for v in ical.parse_dt_list(p, zone):
            exdates.append(ical._norm_key(v, not isinstance(v, datetime)))
    done_keys = []
    for ov in overrides:
        st = ov.prop("STATUS")
        if (st is not None and st.value.strip().upper() in ("COMPLETED", "CANCELLED")) or ov.prop("COMPLETED") is not None:
            try:
                done_keys.append(_occ_key(ov.prop("RECURRENCE-ID"), zone))
            except ValueError:
                pass
    cats = []
    for p in task.props("CATEGORIES"):
        cats += _split_list(p.value)
    rf = task.prop(REPEAT_FROM)
    pj = task.prop(PROJECT)
    rec = {
        "uid": _uid(task),
        "listId": list_id,
        "title": _text(task, "SUMMARY") or "(no title)",
        "notes": _text(task, "DESCRIPTION"),
        "status": status,
        "completed": completed,
        "percent": _int(task, "PERCENT-COMPLETE", 0, 100),
        "priority": _int(task, "PRIORITY", 0, 9),
        "due": due,
        "start": start,
        "rrule": rrule.value.strip() if rrule is not None else "",
        "repeatFrom": "completion" if rf is not None and rf.value.strip().upper() == "COMPLETION" else "due",
        "exdates": sorted(set(exdates)),
        "doneKeys": sorted(set(done_keys)),
        "parent": _parent(task),
        "project": pj is not None and pj.value.strip().upper() in ("TRUE", "1", "YES"),
        "categories": cats,
        "created": _when(task.prop("CREATED"), timezone.utc)[0],
        "updated": _when(task.prop("LAST-MODIFIED"), timezone.utc)[0],
    }
    tz = due_tz or start_tz
    if tz and tz != ical.local_zone_name():
        rec["tz"] = tz
    so = task.prop("X-APPLE-SORT-ORDER")
    if so is not None and re.fullmatch(r"-?\d+", so.value.strip()):
        rec["sortOrder"] = int(so.value.strip())
    rec.update(extra or {})
    return rec


def records(text, list_id="", extra=None):
    """Task records for every VTODO series in a VCALENDAR document."""
    try:
        cal = parse_tree(text)
    except ValueError:
        return []
    masters, overrides = [], {}
    for t in cal.children("VTODO"):
        if t.prop("RECURRENCE-ID") is not None:
            overrides.setdefault(_uid(t), []).append(t)
        else:
            masters.append(t)
    return [record_of(t, overrides.get(_uid(t), ()), list_id, extra) for t in masters]


# --------------------------------------------------------------------------
# Writing
# --------------------------------------------------------------------------

def _is_day(stamp):
    return bool(re.fullmatch(r"\d{4}-\d{2}-\d{2}", stamp or ""))


def _local_dt(stamp):
    return datetime.strptime(stamp, "%Y-%m-%dT%H:%M").replace(tzinfo=ical.local_zone())


def task_zone(task) -> str:
    tz = (task.get("tz") or "").strip()
    if tz and tzdata.valid(tz):
        return tz
    return ical.local_zone_name()


def _dt_line(name, stamp, zone):
    if _is_day(stamp):
        return f"{name};VALUE=DATE:" + stamp.replace("-", "")
    return name + ical.fmt_in_zone(_local_dt(stamp), zone)


def _times(task):
    """(start stamp, due stamp) as they will be written. RFC 5545 wants
    DTSTART for a repeating task and the same value type on both, so a
    repeating task with only a due date starts on it, and a day-only start
    next to a timed due becomes midnight of that day."""
    due, start = task.get("due") or "", task.get("start") or ""
    if not _is_day(due) and due and not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}", due):
        raise ValueError(f"bad due date {due!r}")
    if start and not _is_day(start) and not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}", start):
        raise ValueError(f"bad start date {start!r}")
    if task.get("rrule") and not start:
        start = due
    if due and start:
        if _is_day(start) and not _is_day(due):
            start = start + "T00:00"
        elif not _is_day(start) and _is_day(due):
            start = start[:10]
    return start, due


def zones_needed(task):
    start, due = _times(task)
    if (start and not _is_day(start)) or (due and not _is_day(due)):
        z = task_zone(task)
        return [z] if z and z != "UTC" else []
    return []


def _escape_cat(c):
    return ical.escape(c)


def _owned_lines(task, seq):
    start, due = _times(task)
    zone = task_zone(task)
    status = task.get("status") if task.get("status") in STATUSES else "NEEDS-ACTION"
    lines = ["SUMMARY:" + ical.escape(task.get("title") or "")]
    if task.get("notes"):
        lines.append("DESCRIPTION:" + ical.escape(task["notes"]))
    lines.append("STATUS:" + status)
    if status == "COMPLETED":
        done = task.get("completed") or datetime.now(ical.local_zone()).strftime("%Y-%m-%dT%H:%M")
        lines.append("COMPLETED:" + ical.fmt_utc(_local_dt(done if not _is_day(done) else done + "T00:00")))
        lines.append("PERCENT-COMPLETE:100")
    elif int(task.get("percent") or 0) > 0:
        lines.append("PERCENT-COMPLETE:%d" % max(0, min(99, int(task["percent"]))))
    if int(task.get("priority") or 0) > 0:
        lines.append("PRIORITY:%d" % max(1, min(9, int(task["priority"]))))
    if start:
        lines.append(_dt_line("DTSTART", start, zone))
    if due:
        lines.append(_dt_line("DUE", due, zone))
    if task.get("rrule"):
        lines.append("RRULE:" + str(task["rrule"]).replace("RRULE:", ""))
        day = _is_day(start or due)
        for k in sorted(set(task.get("exdates") or [])):
            if day and "T" not in k:
                lines.append(f"EXDATE;VALUE=DATE:{k}")
            elif "T" in k:
                lines.append("EXDATE:" + k + "Z")
        if task.get("repeatFrom") == "completion":
            lines.append(REPEAT_FROM + ":COMPLETION")
    cats = [c for c in (task.get("categories") or []) if str(c).strip()]
    if cats:
        lines.append("CATEGORIES:" + ",".join(_escape_cat(str(c).strip()) for c in cats))
    if task.get("parent"):
        lines.append("RELATED-TO;RELTYPE=PARENT:" + str(task["parent"]).strip())
    if task.get("project"):
        lines.append(PROJECT + ":TRUE")
    now = ical.fmt_utc(datetime.now(timezone.utc))
    lines += [f"DTSTAMP:{now}", f"LAST-MODIFIED:{now}", f"SEQUENCE:{seq}"]
    return lines


def _ensure_zones(cal: Comp, task):
    have = {p.value.strip() for tz in cal.children("VTIMEZONE") for p in tz.props("TZID")}
    missing = [z for z in zones_needed(task) if z not in have]
    if not missing:
        return
    start, due = _times(task)
    try:
        year = int((start or due)[:4]) - 1
    except ValueError:
        year = None
    tree = parse_tree("BEGIN:VCALENDAR\r\n" + "\r\n".join(ical._vtimezones(missing, year)) + "\r\nEND:VCALENDAR\r\n")
    first = next((i for i, it in enumerate(cal.items) if isinstance(it, Comp) and it.name == "VTODO"), len(cal.items))
    cal.items[first:first] = tree.children("VTIMEZONE")


def _owned_prop(p):
    if p.name == "RELATED-TO":
        return p.params.get("RELTYPE", "PARENT").upper() == "PARENT"
    return p.name in OWNED


def apply(cal: Comp, task) -> Comp:
    master = master_of(cal)
    seq = master.prop("SEQUENCE")
    try:
        n = int(seq.value) + 1 if seq is not None else 0
    except ValueError:
        n = 1
    lines = _owned_lines(task, n)      # validates before anything changes
    master.drop(_owned_prop)
    master.add(lines)
    _ensure_zones(cal, task)
    return cal


def edit_vcalendar(original: str, task) -> str:
    return serialize(apply(parse_tree(original), task))


def new_vcalendar(task, uid) -> str:
    now = ical.fmt_utc(datetime.now(timezone.utc))
    text = ("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:" + PRODID + "\r\nCALSCALE:GREGORIAN\r\n"
            f"BEGIN:VTODO\r\nUID:{uid}\r\nCREATED:{now}\r\nEND:VTODO\r\nEND:VCALENDAR\r\n")
    cal = parse_tree(text)
    apply(cal, task)
    master_of(cal).drop(lambda p: p.name == "SEQUENCE")
    master_of(cal).add(["SEQUENCE:0"])
    return serialize(cal)


SAFE_UID = re.compile(r"[A-Za-z0-9@._-]{1,200}")


def safe_name(uid: str) -> str | None:
    """The UID itself as an object name, when it is safe in a URL path."""
    return uid if uid and SAFE_UID.fullmatch(uid) and uid not in (".", "..") else None
