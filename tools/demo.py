#!/usr/bin/env python3
"""Run the app on made-up data, for screenshots and trying it out.

    python3 tools/demo.py                       calendars and tasks only
    python3 tools/demo.py --radicale VENV_PY    also contacts, from a throwaway
                                                Radicale server (pip install radicale)

Everything lives in a temporary data folder (XDG_DATA_HOME), dated around
today, so your own calendars, tasks and accounts are never read or changed.
With --radicale, one keyring entry (service "carts", key "account:acc-demo")
is added for the demo server and removed on exit. Close the window (or
Ctrl+C) to end the demo; the folder is deleted afterwards unless --keep.

Quit the real app first (`carts --quit`): the app runs one instance per
config folder.
"""
import argparse
import base64
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from datetime import date, timedelta

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
USER, PASSWORD = "demo", "demo-pass"
SECRET_KEY = "account:acc-demo"

today = date.today()
monday = today - timedelta(days=today.weekday())


def d(offset):
    return (today + timedelta(days=offset)).isoformat()


def wk(weekday, hhmm=None, weeks=0):
    """A day of this week (0 = Monday), optionally with a time."""
    k = (monday + timedelta(days=weekday + 7 * weeks)).isoformat()
    return k + "T" + hhmm if hhmm else k


def event(uid, cal, title, start, end, **extra):
    e = {"uid": uid, "calendarId": cal, "title": title, "start": start, "end": end, "allDay": len(start) == 10}
    e.update(extra)
    return e


def calendar_json(server=None):
    cals = [
        {"id": "cal-personal", "name": "Personal", "color": "theme:blue", "visible": True, "source": {"type": "local"}},
        {"id": "cal-work", "name": "Work", "color": "theme:green", "visible": True, "source": {"type": "local"}},
        {"id": "cal-family", "name": "Family", "color": "theme:magenta", "visible": True, "source": {"type": "local"}},
        {"id": "cal-holidays", "name": "Holidays", "color": "theme:yellow", "visible": True, "source": {"type": "local"}},
    ]
    ev = [
        event("standup", "cal-work", "Standup", wk(0, "09:00", -2), wk(0, "09:15", -2), rrule="FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR",
              location="Video call"),
        event("yoga", "cal-personal", "Yoga", wk(0, "18:00", -2), wk(0, "19:00", -2), rrule="FREQ=WEEKLY;BYDAY=MO,WE",
              location="Riverside Studio"),
        event("oneonone", "cal-work", "1:1 with Priya", wk(1, "14:00"), wk(1, "14:30")),
        event("design", "cal-work", "Design review", wk(2, "10:00"), wk(2, "11:30"), location="Room 4B",
              notes="Walk through the new onboarding flow."),
        event("lunch", "cal-personal", "Lunch with Sam", wk(3, "12:00"), wk(3, "13:00"), location="Noodle Bar"),
        event("planning", "cal-work", "Quarterly planning", wk(3, "15:00"), wk(3, "17:00")),
        event("dentist", "cal-personal", "Dentist", wk(4, "08:30"), wk(4, "09:30")),
        event("demo", "cal-work", "Sprint demo", wk(4, "13:00"), wk(4, "14:00")),
        event("soccer", "cal-family", "Soccer practice", wk(5, "10:00", -3), wk(5, "11:30", -3), rrule="FREQ=WEEKLY;BYDAY=SA"),
        event("dinner", "cal-family", "Family dinner", wk(6, "17:30"), wk(6, "19:30"), location="Grandma's"),
        event("trash", "cal-family", "Trash day", wk(2, None, -4), wk(2, None, -4), rrule="FREQ=WEEKLY;BYDAY=WE"),
        event("conf", "cal-work", "Product conference", wk(1, None, 1), wk(3, None, 1), location="Portland"),
        event("flight", "cal-work", "Flight to PDX", wk(0, "19:40", 1), wk(0, "22:05", 1)),
        event("lake", "cal-family", "Lake weekend", wk(4, None, 2), wk(6, None, 2)),
        event("bookclub", "cal-personal", "Book club", wk(1, "19:00", -1), wk(1, "20:30", -1), rrule="FREQ=MONTHLY;BYDAY=3TU"),
        event("haircut", "cal-personal", "Haircut", wk(2, "17:00", -1), wk(2, "17:45", -1)),
        event("offsite", "cal-work", "Team offsite", wk(3, None, -2), wk(4, None, -2)),
        event("pumpkins", "cal-family", "Pumpkin carving", f"{today.year}-10-30T18:00", f"{today.year}-10-30T20:00"),
        event("halloween", "cal-holidays", "Halloween", f"{today.year}-10-31", f"{today.year}-10-31"),
        event("thanksgiving", "cal-holidays", "Thanksgiving", f"{today.year}-11-26", f"{today.year}-11-26"),
    ]
    data = {"version": 1, "accounts": [], "calendars": cals, "events": ev, "hidden": [],
            "prefs": {"windowMode": "calendar", "windowView": "week", "clockZones": ["Europe/London", "Asia/Tokyo"],
                      "tasksOnCalendar": True, "popupTasks": "list"}}
    if server:
        data["accounts"] = [{"id": "acc-demo", "provider": "caldav", "server": server, "username": USER}]
        data["addressBooks"] = [
            {"id": "ab-personal", "name": "Personal", "accountId": "acc-demo", "url": server + USER + "/personal/", "readOnly": False},
            {"id": "ab-work", "name": "Work", "accountId": "acc-demo", "url": server + USER + "/work/", "readOnly": False},
        ]
    return data


def task(uid, lst, title, due="", **extra):
    t = {"uid": uid, "listId": lst, "title": title, "notes": "", "status": "NEEDS-ACTION", "completed": "", "percent": 0,
         "priority": 0, "due": due, "start": "", "rrule": "", "repeatFrom": "due", "categories": [], "parent": "",
         "created": d(-10) + "T09:00", "updated": d(-10) + "T09:00"}
    t.update(extra)
    return t


def tasks_json():
    lists = [
        {"id": "list-inbox", "name": "Inbox", "color": "theme:cyan", "visible": True, "source": {"type": "local"}},
        {"id": "list-home", "name": "Home", "color": "theme:red", "visible": True, "source": {"type": "local"}},
        {"id": "list-work", "name": "Work", "color": "theme:green", "visible": True, "source": {"type": "local"}},
    ]
    ts = [
        task("t-report", "list-work", "Send the weekly report", d(0) + "T16:00", priority=1, categories=["work"]),
        task("t-slides", "list-work", "Finish conference slides", wk(4), priority=5),
        task("t-expenses", "list-work", "Submit expenses", d(-2), priority=1),
        task("t-review", "list-work", "Review Priya's pull request", d(1)),
        task("t-rent", "list-home", "Pay rent", f"{(today.replace(day=1) + timedelta(days=32)).replace(day=1).isoformat()}",
             rrule="FREQ=MONTHLY;BYMONTHDAY=1", categories=["bills"], priority=1),
        task("t-plants", "list-home", "Water the plants", d(0), rrule="FREQ=DAILY;INTERVAL=3"),
        task("t-recycling", "list-home", "Take out recycling", wk(2), rrule="FREQ=WEEKLY;BYDAY=WE"),
        task("t-groceries", "list-inbox", "Buy oat milk and coffee", d(0), categories=["errand"]),
        task("t-call", "list-inbox", "Call the bank", d(1) + "T09:30"),
        task("t-passport", "list-inbox", "Renew passport", d(12), priority=5),
        task("t-gift", "list-inbox", "Birthday gift for Alex", d(4), categories=["errand"]),
        task("t-someday", "list-inbox", "Learn to make sourdough"),
        task("t-kitchen", "list-home", "Kitchen remodel", d(30), project=True, notes="Budget and timeline in the shared doc."),
        task("t-k1", "list-home", "Pick tiles", d(2), parent="t-kitchen"),
        task("t-k2", "list-home", "Get three quotes", d(5), parent="t-kitchen"),
        task("t-k3", "list-home", "Order cabinets", d(14), parent="t-kitchen", priority=1),
        task("t-k4", "list-home", "Measure the walls", parent="t-kitchen", status="COMPLETED", completed=d(-3) + "T18:00", percent=100),
        task("t-done", "list-inbox", "Book flights", status="COMPLETED", completed=d(-1) + "T11:00", percent=100),
    ]
    return {"version": 1, "lists": lists, "tasks": ts, "prefs": {"view": "today", "defaultList": "list-inbox"}}


CARDS = {
    "personal": [("Sam Rivera", "Rivera;Sam", "sam@example.com", "555-0101", ""),
                 ("Alex Chen", "Chen;Alex", "alex@example.com", "555-0102", ""),
                 ("Jordan Lee", "Lee;Jordan", "jordan@example.org", "555-0103", ""),
                 ("Riverside Studio", ";;;", "hello@riverside.example", "555-0150", "Riverside Studio")],
    "work": [("Priya Patel", "Patel;Priya", "priya@acme.example", "555-0201", "Acme Corp"),
             ("Marcus Brown", "Brown;Marcus", "marcus@acme.example", "555-0202", "Acme Corp"),
             ("Dana Kim", "Kim;Dana", "dana@acme.example", "555-0203", "Acme Corp")],
}


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def start_radicale(py, root):
    port = free_port()
    users = os.path.join(root, "users")
    with open(users, "w") as f:
        f.write(f"{USER}:{PASSWORD}\n")
    conf = os.path.join(root, "radicale.conf")
    with open(conf, "w") as f:
        f.write(f"[server]\nhosts = 127.0.0.1:{port}\n[auth]\ntype = htpasswd\nhtpasswd_filename = {users}\n"
                f"htpasswd_encryption = plain\n[storage]\nfilesystem_folder = {root}/collections\n[logging]\nlevel = warning\n")
    proc = subprocess.Popen([py, "-m", "radicale", "--config", conf], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    base = f"http://127.0.0.1:{port}/"
    auth = "Basic " + base64.b64encode(f"{USER}:{PASSWORD}".encode()).decode()

    def req(method, path, body, ctype):
        r = urllib.request.Request(base + path, data=body.encode(), method=method,
                                   headers={"Authorization": auth, "Content-Type": ctype})
        try:
            with urllib.request.urlopen(r, timeout=10) as resp:
                return resp.status
        except urllib.error.HTTPError as e:
            return e.code

    for _ in range(60):
        try:
            urllib.request.urlopen(base, timeout=1)
            break
        except urllib.error.HTTPError:
            break
        except Exception:
            time.sleep(0.2)
    names = {"personal": "Personal", "work": "Work"}
    for slug, cards in CARDS.items():
        req("MKCOL", f"{USER}/{slug}/",
            '<?xml version="1.0"?><d:mkcol xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav"><d:set><d:prop>'
            '<d:resourcetype><d:collection/><card:addressbook/></d:resourcetype>'
            f'<d:displayname>{names[slug]}</d:displayname></d:prop></d:set></d:mkcol>', "application/xml")
        for i, (fn, n, email, tel, org) in enumerate(cards):
            uid = f"{slug}-{i}"
            card = (f"BEGIN:VCARD\r\nVERSION:3.0\r\nUID:{uid}\r\nFN:{fn}\r\nN:{n};;;\r\nEMAIL;TYPE=WORK:{email}\r\n"
                    f"TEL;TYPE=CELL:{tel}\r\n" + (f"ORG:{org}\r\n" if org else "") + "END:VCARD\r\n")
            req("PUT", f"{USER}/{slug}/{uid}.vcf", card, "text/vcard")
    return proc, base


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--radicale", metavar="PYTHON", help="python with radicale installed, for demo contacts")
    ap.add_argument("--keep", action="store_true", help="keep the demo folder")
    args = ap.parse_args()

    # bin/carts builds the app's config folder (links to the repo and
    # Omarchy's Commons/Ui) and prints where it is.
    app = os.path.join(subprocess.run([os.path.join(REPO, "bin", "carts"), "--config-dir"], capture_output=True,
                                      text=True, check=True).stdout.strip(), "CalendarApp.qml")
    if subprocess.run(["quickshell", "list", "-p", app], capture_output=True, text=True).stdout.count("Instance"):
        print("The app is running; quit it first: carts --quit", file=sys.stderr)
        return 1

    root = tempfile.mkdtemp(prefix="carts-demo-")
    data = os.path.join(root, "data", "carts")
    os.makedirs(data, mode=0o700)
    radicale, server = None, None
    try:
        if args.radicale:
            radicale, server = start_radicale(args.radicale, root)
            subprocess.run(["secret-tool", "store", "--label", "Cart's Tasks and Calendar: demo", "service", "carts",
                            "key", SECRET_KEY], input=PASSWORD, text=True, check=True)
        with open(os.path.join(data, "calendar.json"), "w") as f:
            json.dump(calendar_json(server), f, indent=2)
        with open(os.path.join(data, "tasks.json"), "w") as f:
            json.dump(tasks_json(), f, indent=2)
        env = dict(os.environ, XDG_DATA_HOME=os.path.join(root, "data"), CARTS_NO_IMPORT="1", QS_APP_ID="org.omarchy.carts")
        print("Demo data in", root, "- close the window to end the demo", flush=True)
        subprocess.run(["quickshell", "-n", "-p", app], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except KeyboardInterrupt:
        pass
    finally:
        if args.radicale:
            subprocess.run(["secret-tool", "clear", "service", "carts", "key", SECRET_KEY])
        if radicale:
            radicale.terminate()
        if not args.keep:
            shutil.rmtree(root, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
