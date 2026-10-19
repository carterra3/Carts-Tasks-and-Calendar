#!/usr/bin/env python3
"""sync/vcard.py: parsing and in-place editing. Run: python3 tests/test_vcard.py"""
import base64
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "sync"))
import vcard  # noqa: E402

PNG = base64.b64encode(b"\x89PNG\r\n\x1a\n" + b"\x00" * 64).decode()
APPLE = "\r\n".join([
    "BEGIN:VCARD", "VERSION:3.0", "PRODID:-//Apple Inc.//iPhone OS 18.0//EN",
    "N:Garcia;Mary;Ann;;", "FN:Mary Garcia", "ORG:Acme\\, Inc.;Research",
    "item1.EMAIL;type=INTERNET;type=pref:mary@example.com", "item1.X-ABLABEL:_$!<Other>!$_",
    "EMAIL;type=INTERNET;type=HOME:m@home.example",
    "TEL;type=CELL;type=VOICE;type=pref:(555) 010-2000", "TEL;type=WORK;type=VOICE:555 010 3000",
    "item2.ADR;type=HOME;type=pref:;;1 Main St\\nApt 2;Lincoln;NE;68508;USA", "item2.X-ABLABEL:_$!<Home>!$_",
    "item3.X-SOCIALPROFILE;type=twitter:x-apple:mgarcia", "item3.X-ABLABEL:twitter",
    "BDAY;value=date:1990-03-14", "NOTE:Likes tea\\; hates coffee\\nSecond line",
    "PHOTO;ENCODING=b;TYPE=PNG:" + PNG, "X-CUSTOM:keep", "CATEGORIES:family,friends",
    "UID:ABC-123", "END:VCARD", ""])
V4 = "\r\n".join([
    "BEGIN:VCARD", "VERSION:4.0", "FN:Dr. Hal Garcia", "N:Garcia;Hal;;Dr.;",
    "TEL;VALUE=uri;TYPE=\"voice,home\":tel:+1-555-555-0100", "EMAIL;TYPE=work:hal@work.example",
    "BDAY:--0704", "URL:https://example.com/~hal", "UID:urn:uuid:4fbe8971-0bc3-424c-9c26-36c3e1eff6b1",
    "END:VCARD", ""])

recs = vcard.records(APPLE + V4, {"bookId": "b1"})
assert len(recs) == 2
m, h = recs
assert m["fn"] == "Mary Garcia" and m["given"] == "Mary" and m["family"] == "Garcia" and m["additional"] == "Ann", m
assert m["org"] == "Acme, Inc. · Research", m["org"]
assert m["emails"] == [{"type": "other", "value": "mary@example.com"}, {"type": "home", "value": "m@home.example"}], m["emails"]
assert m["phones"] == [{"type": "cell", "value": "(555) 010-2000"}, {"type": "work", "value": "555 010 3000"}], m["phones"]
assert m["addresses"][0] == {"type": "home", "street": "1 Main St\nApt 2", "city": "Lincoln", "region": "NE", "code": "68508", "country": "USA"}
assert m["birthday"] == "1990-03-14" and m["notes"] == "Likes tea; hates coffee\nSecond line" and m["uid"] == "ABC-123"
assert m["photo"].startswith("data:image/png;base64,") and m["bookId"] == "b1"
assert h["fn"] == "Dr. Hal Garcia" and h["prefix"] == "Dr." and h["phones"] == [{"type": "home", "value": "+1-555-555-0100"}]
assert h["birthday"] == "--07-04" and h["urls"] == ["https://example.com/~hal"] and h["uid"] == "4fbe8971-0bc3-424c-9c26-36c3e1eff6b1"

# Edit in place: our fields replaced, everything else kept.
edited = dict(m, given="Maria", emails=[{"type": "work", "value": "maria@acme.example"}],
              phones=m["phones"][:1], notes="New; note, with commas", org="Acme, Inc.")
out = vcard.edit_vcard(APPLE, edited)
again = vcard.records(out)[0]
assert again["fn"] == "Maria Ann Garcia" and again["given"] == "Maria", again
assert again["emails"] == [{"type": "work", "value": "maria@acme.example"}], again["emails"]
assert again["phones"] == [{"type": "cell", "value": "(555) 010-2000"}] and again["notes"] == "New; note, with commas"
assert again["org"] == "Acme, Inc." and again["addresses"] == m["addresses"] and again["birthday"] == "1990-03-14"
assert again["photo"] == m["photo"] and again["uid"] == "ABC-123"
assert "X-CUSTOM:keep" in out and "CATEGORIES:family,friends" in out and "PRODID:-//Apple" in out
assert "item3.X-SOCIALPROFILE" in out and "item3.X-ABLABEL:twitter" in out      # unrelated labels kept
assert "item1.X-ABLABEL" not in out and "item2.X-ABLABEL" not in out           # labels of replaced props dropped
assert all(len(l.encode()) <= 75 for l in out.split("\r\n")), "folded"

# New card round trip.
c = {"given": "Ezra", "family": "Garcia", "emails": [{"type": "home", "value": "ezra@example.com"}],
     "phones": [{"type": "cell", "value": "555-0199"}], "birthday": "2019-05-01",
     "addresses": [{"type": "home", "street": "1 Main St", "city": "Lincoln", "region": "NE", "code": "68508", "country": ""}]}
n = vcard.records(vcard.new_vcard(c, "U-1"))[0]
assert n["fn"] == "Ezra Garcia" and n["uid"] == "U-1" and n["emails"] == c["emails"] and n["phones"] == c["phones"]
assert n["birthday"] == "2019-05-01" and n["addresses"][0]["city"] == "Lincoln"
print("vcard tests passed")
