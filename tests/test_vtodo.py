"""vtodo.py: reading VTODOs into task records and writing them back.

    python3 tests/test_vtodo.py
"""
import os
import sys
import unittest

os.environ["TZ"] = "America/Chicago"
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "sync"))
import ical  # noqa: E402
import vtodo  # noqa: E402

APPLE = (
    "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Apple Inc.//iOS 17//EN\r\n"
    "BEGIN:VTIMEZONE\r\nTZID:America/Chicago\r\nBEGIN:STANDARD\r\nDTSTART:20071104T020000\r\n"
    "RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=1SU\r\nTZOFFSETFROM:-0500\r\nTZOFFSETTO:-0600\r\nEND:STANDARD\r\n"
    "BEGIN:DAYLIGHT\r\nDTSTART:20070311T020000\r\nRRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU\r\n"
    "TZOFFSETFROM:-0600\r\nTZOFFSETTO:-0500\r\nEND:DAYLIGHT\r\nEND:VTIMEZONE\r\n"
    "BEGIN:VTODO\r\nUID:ABC-123\r\nCREATED:20261001T120000Z\r\nLAST-MODIFIED:20261002T120000Z\r\n"
    "DTSTAMP:20261002T120000Z\r\nSUMMARY:Water the plants\\, all of them\r\n"
    "DESCRIPTION:Front porch\\nand back\r\nDTSTART;TZID=America/Chicago:20261020T090000\r\n"
    "DUE;TZID=America/Chicago:20261020T090000\r\nRRULE:FREQ=WEEKLY;BYDAY=TU\r\n"
    "PRIORITY:1\r\nSTATUS:NEEDS-ACTION\r\nX-APPLE-SORT-ORDER:739000000\r\n"
    "CATEGORIES:home,garden\\,outdoor\r\nRELATED-TO;RELTYPE=SIBLING:OTHER-1\r\nSEQUENCE:3\r\n"
    "BEGIN:VALARM\r\nACTION:DISPLAY\r\nDESCRIPTION:Reminder\r\nTRIGGER;VALUE=DATE-TIME:20261020T140000Z\r\n"
    "END:VALARM\r\nEND:VTODO\r\nEND:VCALENDAR\r\n"
)


class Read(unittest.TestCase):
    def test_apple_reminder(self):
        [t] = vtodo.records(APPLE, "L1", {"href": "h", "etag": "e"})
        self.assertEqual(t["uid"], "ABC-123")
        self.assertEqual(t["listId"], "L1")
        self.assertEqual(t["title"], "Water the plants, all of them")
        self.assertEqual(t["notes"], "Front porch\nand back")
        self.assertEqual(t["due"], "2026-10-20T09:00")
        self.assertEqual(t["start"], "2026-10-20T09:00")
        self.assertEqual(t["rrule"], "FREQ=WEEKLY;BYDAY=TU")
        self.assertEqual(t["repeatFrom"], "due")
        self.assertEqual(t["priority"], 1)
        self.assertEqual(t["status"], "NEEDS-ACTION")
        self.assertEqual(t["categories"], ["home", "garden,outdoor"])
        self.assertEqual(t["parent"], "")
        self.assertEqual(t["sortOrder"], 739000000)
        self.assertEqual(t["created"], "2026-10-01T07:00")
        self.assertNotIn("tz", t)
        self.assertEqual((t["href"], t["etag"]), ("h", "e"))

    def test_dates_completed_and_parent(self):
        text = ("BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nUID:k\r\nSUMMARY:x\r\nDUE;VALUE=DATE:20261103\r\n"
                "COMPLETED:20261019T150000Z\r\nRELATED-TO:PARENT-UID\r\nEND:VTODO\r\nEND:VCALENDAR\r\n")
        [t] = vtodo.records(text)
        self.assertEqual(t["due"], "2026-11-03")
        self.assertEqual(t["start"], "")
        self.assertEqual(t["status"], "COMPLETED")        # COMPLETED alone counts
        self.assertEqual(t["completed"], "2026-10-19T10:00")
        self.assertEqual(t["parent"], "PARENT-UID")

    def test_other_zone_and_duration(self):
        text = ("BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nUID:z\r\nSUMMARY:call\r\n"
                "DTSTART;TZID=Europe/Paris:20261020T180000\r\nDURATION:PT1H\r\nEND:VTODO\r\nEND:VCALENDAR\r\n")
        [t] = vtodo.records(text)
        self.assertEqual(t["start"], "2026-10-20T11:00")
        self.assertEqual(t["due"], "2026-10-20T12:00")
        self.assertEqual(t["tz"], "Europe/Paris")

    def test_overrides_from_other_apps(self):
        text = ("BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nUID:r\r\nSUMMARY:daily\r\nDTSTART;VALUE=DATE:20261001\r\n"
                "DUE;VALUE=DATE:20261001\r\nRRULE:FREQ=DAILY\r\nEXDATE;VALUE=DATE:20261003\r\nEND:VTODO\r\n"
                "BEGIN:VTODO\r\nUID:r\r\nRECURRENCE-ID;VALUE=DATE:20261001\r\nSTATUS:COMPLETED\r\nEND:VTODO\r\n"
                "BEGIN:VTODO\r\nUID:r\r\nRECURRENCE-ID;VALUE=DATE:20261002\r\nSUMMARY:moved\r\nEND:VTODO\r\n"
                "END:VCALENDAR\r\n")
        recs = vtodo.records(text)
        self.assertEqual(len(recs), 1)
        self.assertEqual(recs[0]["exdates"], ["20261003"])
        self.assertEqual(recs[0]["doneKeys"], ["20261001"])

    def test_events_are_ignored(self):
        text = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:e\r\nDTSTART:20261001T100000Z\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
        self.assertEqual(vtodo.records(text), [])
        self.assertFalse(vtodo.has_task(text))

    def test_repeat_from_completion(self):
        text = ("BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nUID:c\r\nSUMMARY:haircut\r\nDUE;VALUE=DATE:20261101\r\n"
                "RRULE:FREQ=WEEKLY;INTERVAL=6\r\nX-OMARCHY-REPEAT-FROM:COMPLETION\r\nEND:VTODO\r\nEND:VCALENDAR\r\n")
        self.assertEqual(vtodo.records(text)[0]["repeatFrom"], "completion")


def lines_of(text):
    return ical.unfold(text)


class Write(unittest.TestCase):
    def test_edit_keeps_what_it_does_not_own(self):
        [t] = vtodo.records(APPLE)
        t.update(title="Water plants", due="2026-10-27T09:00", start="2026-10-27T09:00", priority=5,
                 categories=["home"], notes="")
        out = vtodo.edit_vcalendar(APPLE, t)
        lines = lines_of(out)
        self.assertIn("SUMMARY:Water plants", lines)
        self.assertIn("DUE;TZID=America/Chicago:20261027T090000", lines)
        self.assertIn("DTSTART;TZID=America/Chicago:20261027T090000", lines)
        self.assertIn("PRIORITY:5", lines)
        self.assertIn("CATEGORIES:home", lines)
        self.assertIn("SEQUENCE:4", lines)
        self.assertIn("X-APPLE-SORT-ORDER:739000000", lines)
        self.assertIn("RELATED-TO;RELTYPE=SIBLING:OTHER-1", lines)
        # The alarm keeps its own DESCRIPTION; the task's notes are gone.
        self.assertIn("DESCRIPTION:Reminder", lines)
        self.assertEqual(sum(1 for l in lines if l.startswith("DESCRIPTION")), 1)
        self.assertEqual(sum(1 for l in lines if l.startswith("BEGIN:VTIMEZONE")), 1)
        [back] = vtodo.records(out)
        self.assertEqual(back["title"], "Water plants")
        self.assertEqual(back["rrule"], "FREQ=WEEKLY;BYDAY=TU")

    def test_complete_and_reopen(self):
        [t] = vtodo.records(APPLE)
        t.update(status="COMPLETED", completed="2026-10-19T10:00", rrule="")
        out = vtodo.edit_vcalendar(APPLE, t)
        lines = lines_of(out)
        self.assertIn("STATUS:COMPLETED", lines)
        self.assertIn("COMPLETED:20261019T150000Z", lines)
        self.assertIn("PERCENT-COMPLETE:100", lines)
        self.assertNotIn("RRULE:FREQ=WEEKLY;BYDAY=TU", lines)   # (the VTIMEZONE keeps its own)
        [back] = vtodo.records(out)
        back.update(status="NEEDS-ACTION", completed="", percent=0)
        lines = lines_of(vtodo.edit_vcalendar(out, back))
        self.assertIn("STATUS:NEEDS-ACTION", lines)
        self.assertFalse(any(l.startswith("COMPLETED") or l.startswith("PERCENT") for l in lines))

    def test_new_repeating_task_gets_dtstart(self):
        out = vtodo.new_vcalendar({"title": "Rent", "due": "2026-11-01", "rrule": "FREQ=MONTHLY;BYMONTHDAY=1",
                                   "exdates": ["20261201"], "repeatFrom": "due", "parent": "P-1",
                                   "categories": ["bills", "a;b"]}, "NEW-1")
        lines = lines_of(out)
        self.assertIn("UID:NEW-1", lines)
        self.assertIn("DTSTART;VALUE=DATE:20261101", lines)
        self.assertIn("DUE;VALUE=DATE:20261101", lines)
        self.assertIn("RRULE:FREQ=MONTHLY;BYMONTHDAY=1", lines)
        self.assertIn("EXDATE;VALUE=DATE:20261201", lines)
        self.assertIn("RELATED-TO;RELTYPE=PARENT:P-1", lines)
        self.assertIn("SEQUENCE:0", lines)
        self.assertFalse(any("VTIMEZONE" in l for l in lines))
        [back] = vtodo.records(out)
        self.assertEqual(back["categories"], ["bills", "a;b"])
        self.assertEqual(back["exdates"], ["20261201"])

    def test_mixed_value_types_are_aligned(self):
        lines = lines_of(vtodo.new_vcalendar({"title": "x", "start": "2026-10-20", "due": "2026-10-21T17:00"}, "U"))
        self.assertIn("DTSTART;TZID=America/Chicago:20261020T000000", lines)
        self.assertIn("DUE;TZID=America/Chicago:20261021T170000", lines)
        self.assertTrue(any(l == "TZID:America/Chicago" for l in lines))

    def test_timed_task_in_its_own_zone(self):
        lines = lines_of(vtodo.new_vcalendar({"title": "x", "due": "2026-10-20T11:00", "tz": "Europe/Paris"}, "U"))
        self.assertIn("DUE;TZID=Europe/Paris:20261020T180000", lines)

    def test_parent_link_replaced_only(self):
        text = APPLE.replace("RELATED-TO;RELTYPE=SIBLING:OTHER-1\r\n",
                             "RELATED-TO;RELTYPE=SIBLING:OTHER-1\r\nRELATED-TO:OLD-PARENT\r\n")
        [t] = vtodo.records(text)
        self.assertEqual(t["parent"], "OLD-PARENT")
        t["parent"] = ""
        lines = lines_of(vtodo.edit_vcalendar(text, t))
        self.assertIn("RELATED-TO;RELTYPE=SIBLING:OTHER-1", lines)
        self.assertFalse(any("OLD-PARENT" in l for l in lines))

    def test_bad_dates_refused_before_changing_anything(self):
        with self.assertRaises(ValueError):
            vtodo.edit_vcalendar(APPLE, {"title": "x", "due": "next tuesday"})

    def test_project_flag_round_trips(self):
        out = vtodo.new_vcalendar({"title": "Kitchen remodel", "project": True}, "P")
        self.assertIn("X-OMARCHY-PROJECT:TRUE", lines_of(out))
        [t] = vtodo.records(out)
        self.assertTrue(t["project"])
        t["project"] = False
        self.assertNotIn("X-OMARCHY-PROJECT:TRUE", lines_of(vtodo.edit_vcalendar(out, t)))
        self.assertFalse(vtodo.records(APPLE)[0]["project"])

    def test_safe_names(self):
        self.assertEqual(vtodo.safe_name("task-abc_1@x.y"), "task-abc_1@x.y")
        for bad in ("", "..", "a/b", "a b", "%2e%2e", "x" * 300):
            self.assertIsNone(vtodo.safe_name(bad), bad)


if __name__ == "__main__":
    unittest.main(verbosity=1)
