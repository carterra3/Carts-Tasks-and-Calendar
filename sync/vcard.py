"""Minimal vCard (RFC 6350 / 2426) support for the contacts view.

Standard library only. Parses vCard 3.0 and 4.0 into flat contact records
and writes them back, editing a card in place so anything the app does not
show (photos it did not change, X- properties, categories, groups) is kept.
"""

from __future__ import annotations

import base64
import re
import uuid

import ical  # unfold / fold / parse_line are the same line format

TYPES_EMAIL = ("home", "work", "other")
TYPES_PHONE = ("cell", "home", "work", "main", "fax", "other")
TYPES_ADR = ("home", "work", "other")
MAX_PHOTO = 256 * 1024


# --------------------------------------------------------------------------
# Values
# --------------------------------------------------------------------------

def unescape(v: str) -> str:
    return re.sub(r"\\([\\;,nN:])", lambda m: "\n" if m.group(1) in "nN" else m.group(1), v)


def escape(v: str) -> str:
    return (v.replace("\\", "\\\\").replace(";", "\\;").replace(",", "\\,")
            .replace("\r\n", "\\n").replace("\n", "\\n"))


def split_struct(v: str) -> list[str]:
    """Split a structured value (N, ADR) on unescaped semicolons."""
    out, cur, i = [], [], 0
    while i < len(v):
        ch = v[i]
        if ch == "\\" and i + 1 < len(v):
            cur.append(v[i:i + 2])
            i += 2
            continue
        if ch == ";":
            out.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
        i += 1
    out.append("".join(cur))
    return [unescape(x) for x in out]


def _types(prop) -> list[str]:
    raw = prop.params.get("TYPE", "").split(",")
    return [t.strip().lower() for t in raw if t.strip()]


def _kind(prop, allowed, default):
    ts = _types(prop)
    if "cell" in ts or "mobile" in ts or "iphone" in ts:
        return "cell" if "cell" in allowed else default
    if "fax" in ts:
        return "fax" if "fax" in allowed else default
    for t in ("work", "home", "main"):
        if t in ts and t in allowed:
            return t
    return default


def _value(prop) -> str:
    v = prop.value
    if prop.name == "TEL" and v.lower().startswith("tel:"):
        v = v[4:]
    if prop.name == "EMAIL" and v.lower().startswith("mailto:"):
        v = v[7:]
    return unescape(v).strip()


def _norm_date(v: str) -> str:
    """BDAY in vCard forms -> yyyy-MM-dd or --MM-dd ("" when unreadable)."""
    v = v.strip()
    m = re.match(r"^(\d{4})-?(\d{2})-?(\d{2})", v)
    if m:
        return f"{m.group(1)}-{m.group(2)}-{m.group(3)}"
    m = re.match(r"^--(\d{2})-?(\d{2})", v)
    if m:
        return f"--{m.group(1)}-{m.group(2)}"
    return ""


def _photo(prop) -> str:
    """A data: URL for an inline photo (small ones only), or an http(s) URL."""
    v = prop.value.strip()
    if v.startswith("data:"):
        return v if len(v) < MAX_PHOTO * 4 // 3 + 100 else ""
    enc = prop.params.get("ENCODING", "").lower()
    if enc in ("b", "base64"):
        mime = (prop.params.get("TYPE", "jpeg") or "jpeg").lower().split(",")[0]
        if "/" not in mime:
            mime = "image/" + mime
        try:
            raw = base64.b64decode(v + "=" * (-len(v) % 4))
        except ValueError:
            return ""
        if len(raw) > MAX_PHOTO:
            return ""
        return f"data:{mime};base64," + base64.b64encode(raw).decode()
    if v.lower().startswith(("http://", "https://")):
        return v
    return ""


# --------------------------------------------------------------------------
# Parsing
# --------------------------------------------------------------------------

def parse_line(line: str):
    """ical.parse_line, but every TYPE parameter is kept (Apple writes
    "TEL;type=CELL;type=VOICE;type=pref", and vCard 4 "TYPE=\"voice,home\"")."""
    p = ical.parse_line(line)
    if p is None:
        return None
    head = line[:len(line) - len(p.value) - 1]
    types = []
    for part in ical._split_unquoted(head, ";")[1:]:
        if "=" in part:
            k, v = part.split("=", 1)
            if k.strip().upper() == "TYPE":
                types += [t for t in v.strip('"').split(",") if t]
    if types:
        p.params["TYPE"] = ",".join(types)
    return p


def cards(text: str) -> list[list]:
    """Prop lists, one per VCARD in `text`."""
    out, cur = [], None
    for line in ical.unfold(text):
        p = parse_line(line)
        if p is None:
            continue
        # Apple groups properties as "item1.EMAIL": keep the group out of the name.
        if "." in p.name:
            p = ical.Prop(p.name.split(".", 1)[1], p.params, p.value)
        if p.name == "BEGIN" and p.value.upper() == "VCARD":
            cur = []
        elif p.name == "END" and p.value.upper() == "VCARD":
            if cur is not None:
                out.append(cur)
            cur = None
        elif cur is not None:
            cur.append(p)
    return out


def record(props) -> dict:
    get = lambda name: next((p for p in props if p.name == name), None)  # noqa: E731
    rec = {"uid": "", "fn": "", "given": "", "family": "", "additional": "", "prefix": "", "suffix": "",
           "org": "", "title": "", "emails": [], "phones": [], "addresses": [], "urls": [],
           "birthday": "", "notes": "", "photo": ""}
    uid = get("UID")
    rec["uid"] = _value(uid).replace("urn:uuid:", "") if uid else ""
    n = get("N")
    if n:
        parts = split_struct(n.value) + [""] * 5
        rec["family"], rec["given"], rec["additional"], rec["prefix"], rec["suffix"] = [x.strip() for x in parts[:5]]
    fn = get("FN")
    rec["fn"] = unescape(fn.value).strip() if fn else ""
    org = get("ORG")
    if org:
        rec["org"] = " · ".join(x for x in split_struct(org.value) if x.strip())
    title = get("TITLE")
    rec["title"] = unescape(title.value).strip() if title else ""
    for p in props:
        if p.name == "EMAIL" and _value(p):
            rec["emails"].append({"type": _kind(p, TYPES_EMAIL, "other"), "value": _value(p)})
        elif p.name == "TEL" and _value(p):
            rec["phones"].append({"type": _kind(p, TYPES_PHONE, "other"), "value": _value(p)})
        elif p.name == "ADR":
            a = split_struct(p.value) + [""] * 7
            pobox, ext, street, city, region, code, country = [x.strip() for x in a[:7]]
            street = "\n".join(x for x in (street, ext, pobox) if x)
            if any((street, city, region, code, country)):
                rec["addresses"].append({"type": _kind(p, TYPES_ADR, "other"), "street": street, "city": city,
                                         "region": region, "code": code, "country": country})
        elif p.name == "URL" and _value(p):
            rec["urls"].append(_value(p))
    bday = get("BDAY")
    rec["birthday"] = _norm_date(bday.value) if bday else ""
    note = get("NOTE")
    rec["notes"] = unescape(note.value) if note else ""
    photo = get("PHOTO")
    rec["photo"] = _photo(photo) if photo else ""
    if not rec["fn"]:
        rec["fn"] = " ".join(x for x in (rec["prefix"], rec["given"], rec["additional"], rec["family"], rec["suffix"]) if x) \
            or rec["org"] or (rec["emails"][0]["value"] if rec["emails"] else "")
    return rec


def records(text: str, extra=None) -> list[dict]:
    out = []
    for props in cards(text):
        r = record(props)
        if extra:
            r.update(extra)
        out.append(r)
    return out


# --------------------------------------------------------------------------
# Writing
# --------------------------------------------------------------------------

EDITED = {"FN", "N", "ORG", "TITLE", "EMAIL", "TEL", "ADR", "URL", "BDAY", "NOTE", "REV"}


def display_name(c) -> str:
    fn = " ".join(x for x in (c.get("prefix"), c.get("given"), c.get("additional"), c.get("family"), c.get("suffix")) if x)
    return fn or (c.get("fn") or "").strip() or c.get("org") or ""


def _lines(c) -> list[str]:
    import time
    out = ["FN:" + escape(display_name(c) or "Unnamed"),
           "N:" + ";".join(escape(c.get(k) or "") for k in ("family", "given", "additional", "prefix", "suffix"))]
    if c.get("org"):
        out.append("ORG:" + ";".join(escape(x.strip()) for x in c["org"].split(" · ")))
    if c.get("title"):
        out.append("TITLE:" + escape(c["title"]))
    for e in c.get("emails") or []:
        if e.get("value", "").strip():
            t = e.get("type") if e.get("type") in TYPES_EMAIL else "other"
            out.append(f"EMAIL;TYPE=INTERNET,{t.upper()}:" + escape(e["value"].strip()))
    for ph in c.get("phones") or []:
        if ph.get("value", "").strip():
            t = ph.get("type") if ph.get("type") in TYPES_PHONE else "other"
            tt = {"cell": "CELL,VOICE", "fax": "FAX", "main": "MAIN"}.get(t, t.upper() + ",VOICE")
            out.append(f"TEL;TYPE={tt}:" + escape(ph["value"].strip()))
    for a in c.get("addresses") or []:
        if not any(a.get(k) for k in ("street", "city", "region", "code", "country")):
            continue
        t = a.get("type") if a.get("type") in TYPES_ADR else "other"
        parts = ["", "", a.get("street", ""), a.get("city", ""), a.get("region", ""), a.get("code", ""), a.get("country", "")]
        out.append(f"ADR;TYPE={t.upper()}:" + ";".join(escape(x) for x in parts))
    for u in c.get("urls") or []:
        if u.strip():
            out.append("URL:" + u.strip())   # URIs are not text-escaped
    b = (c.get("birthday") or "").strip()
    if re.match(r"^\d{4}-\d{2}-\d{2}$", b):
        out.append("BDAY;VALUE=DATE:" + b.replace("-", ""))
    elif re.match(r"^--\d{2}-\d{2}$", b):
        out.append("BDAY:--" + b[2:].replace("-", ""))
    if c.get("notes"):
        out.append("NOTE:" + escape(c["notes"]))
    out.append("REV:" + time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()))
    return out


def new_vcard(c, uid=None) -> str:
    uid = uid or str(uuid.uuid4()).upper()
    body = ["BEGIN:VCARD", "VERSION:3.0", "PRODID:-//Omarchy//Calendar Contacts//EN", f"UID:{uid}"] + _lines(c) + ["END:VCARD"]
    return "\r\n".join(ical.fold(l) for l in body) + "\r\n"


def edit_vcard(original: str, c) -> str:
    """Replace the fields the editor owns in the first VCARD; keep the rest.
    Apple's X-ABLABEL lines go with the grouped properties they label."""
    lines = ical.unfold(original)
    dropped_groups = set()
    for line in lines:
        p = ical.parse_line(line)
        if p and "." in p.name and p.name.split(".", 1)[1] in EDITED:
            dropped_groups.add(p.name.split(".", 1)[0])
    out, in_card, done = [], False, False
    for line in lines:
        p = ical.parse_line(line)
        group, name = (p.name.split(".", 1) if p and "." in p.name else ("", p.name if p else ""))
        if p and name == "BEGIN" and p.value.upper() == "VCARD" and not done:
            in_card = True
            out.append(line)
            continue
        if p and name == "END" and p.value.upper() == "VCARD" and in_card:
            out += _lines(c)
            out.append(line)
            in_card, done = False, True
            continue
        if in_card and p and (name in EDITED or (name == "X-ABLABEL" and group in dropped_groups)):
            continue
        out.append(line)
    return "\r\n".join(ical.fold(l) for l in out) + "\r\n"
