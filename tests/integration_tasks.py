"""The task sync helper (sync/tasksync.py) end to end against a real CalDAV
server (Radicale).

    pip install radicale          # in any venv
    <venv>/bin/python tests/integration_tasks.py

Uses a temporary data dir, a throwaway server, and test keyring entries
(removed afterwards). Never touches your own data or servers.
"""
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

HERE = os.path.dirname(os.path.abspath(__file__))
HELPER = os.path.join(HERE, "..", "sync", "tasksync.py")
USER, PASSWORD = "itest", "itest-pass"
ACC = "acc-tasks-itest"                  # in calendar.json, shared with calendars
NEW_ACC = "acc-tasks-itest-new"          # a sign-in made from the task list editor

failures = []


def check(name, ok, detail: object = ""):
    print(("ok   " if ok else "FAIL ") + name + (f"  ({detail})" if detail and not ok else ""))
    if not ok:
        failures.append(name)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


class Server:
    def __init__(self, tmp):
        self.port = free_port()
        self.base = f"http://127.0.0.1:{self.port}/"
        with open(os.path.join(tmp, "users"), "w") as f:
            f.write(f"{USER}:{PASSWORD}\n")
        conf = os.path.join(tmp, "radicale.conf")
        with open(conf, "w") as f:
            f.write(f"[server]\nhosts = 127.0.0.1:{self.port}\n[auth]\ntype = htpasswd\n"
                    f"htpasswd_filename = {tmp}/users\nhtpasswd_encryption = plain\n"
                    f"[storage]\nfilesystem_folder = {tmp}/collections\n[logging]\nlevel = warning\n")
        self.proc = subprocess.Popen([sys.executable, "-m", "radicale", "--config", conf],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(60):
            try:
                urllib.request.urlopen(self.base, timeout=1)
                break
            except urllib.error.HTTPError:
                break
            except Exception:
                time.sleep(0.1)
        self.auth = "Basic " + base64.b64encode(f"{USER}:{PASSWORD}".encode()).decode()

    def req(self, method, path, body=None, ctype="application/xml", headers=None):
        h = {"Authorization": self.auth, "Content-Type": ctype}
        h.update(headers or {})
        r = urllib.request.Request(path if path.startswith("http") else self.base + path,
                                   data=body.encode() if body else None, method=method, headers=h)
        try:
            with urllib.request.urlopen(r, timeout=5) as resp:
                return resp.status, resp.read().decode(), dict(resp.headers)
        except urllib.error.HTTPError as e:
            return e.code, "", dict(e.headers)

    def mkcal(self, slug, name, comps):
        cs = "".join(f'<c:comp name="{c}"/>' for c in comps)
        return self.req("MKCALENDAR", f"{USER}/{slug}/",
                        '<?xml version="1.0"?><c:mkcalendar xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">'
                        f'<d:set><d:prop><d:displayname>{name}</d:displayname>'
                        f'<c:supported-calendar-component-set>{cs}</c:supported-calendar-component-set>'
                        '</d:prop></d:set></c:mkcalendar>')[0]

    def stop(self):
        self.proc.terminate()


def helper(env, *args, inp=None):
    r = subprocess.run(["/usr/bin/python3", HELPER] + list(args), input=(json.dumps(inp) if inp is not None else "") + "\n",
                       capture_output=True, text=True, env=env, timeout=60)
    try:
        return json.loads(r.stdout.strip().splitlines()[-1])
    except (IndexError, json.JSONDecodeError):
        return {"ok": False, "error": "no output: " + r.stderr[-500:]}


def main():
    tmp = tempfile.mkdtemp(prefix="tasks-itest-")
    srv = Server(tmp)
    data = os.path.join(tmp, "data")
    os.makedirs(os.path.join(data, "carts"))
    env = dict(os.environ, XDG_DATA_HOME=data, TZ="America/Chicago")
    tasks_json = os.path.join(data, "carts", "tasks.json")
    remote_json = os.path.join(data, "carts", "tasks-remote.json")
    TASK_ACC = ACC
    try:
        check("mkcalendar tasks+events", srv.mkcal("home", "Home", ["VEVENT", "VTODO"]) == 201)
        check("mkcalendar events only", srv.mkcal("events", "Events only", ["VEVENT"]) == 201)

        # A new sign-in stores the password under the shared "carts" service.
        r = helper(env, "discover", inp={"provider": "caldav", "server": srv.base, "username": USER,
                                         "password": PASSWORD, "accountId": NEW_ACC})
        names = sorted(l["name"] for l in r.get("lists", []))
        check("discover with a new sign-in", r.get("ok") and names == ["Home"], r)
        check("discover reports the account", r.get("account", {}).get("username") == USER, r.get("account"))
        pw = subprocess.run(["secret-tool", "lookup", "service", "carts", "key", "account:" + NEW_ACC],
                            capture_output=True, text=True).stdout
        check("password stored in the carts keyring", pw == PASSWORD)
        subprocess.run(["secret-tool", "clear", "service", "carts", "key", "account:" + NEW_ACC])

        # The accounts live in calendar.json (shared with calendars and
        # address books); tasks.json only has lists.
        subprocess.run(["secret-tool", "store", "--label", "tasks itest", "service", "carts", "key", "account:" + ACC],
                       input=PASSWORD, text=True, check=True)
        with open(os.path.join(data, "carts", "calendar.json"), "w") as f:
            json.dump({"version": 1, "accounts": [{"id": ACC, "provider": "caldav", "server": srv.base,
                                                   "username": USER}], "calendars": []}, f)
        r = helper(env, "discover", inp={"accountId": ACC})
        check("discover with a connected account", r.get("ok") and [l["name"] for l in r.get("lists", [])] == ["Home"], r)
        home = r["lists"][0]
        cfg = {"version": 1, "lists": [
            {"id": "L1", "name": "Home", "color": "theme:blue", "source": {"type": "caldav", "accountId": ACC,
                                                                           "url": home["url"], "readOnly": False}}],
               "tasks": []}

        def save_cfg():
            with open(tasks_json, "w") as f:
                json.dump(cfg, f)
        save_cfg()

        r = helper(env, "make-list", inp={"accountId": TASK_ACC, "name": "Errands & <stuff>", "color": "#ff8800"})
        check("make-list", r.get("ok") and r["list"]["url"].startswith(srv.base), r)
        r2 = helper(env, "discover", inp={"accountId": TASK_ACC})
        made = [l for l in r2.get("lists", []) if l["url"] == r.get("list", {}).get("url")]
        check("new list is found again, task-only", made and made[0]["name"] == "Errands & <stuff>" and not made[0]["mixed"]
              and made[0]["color"].lower() == "#ff8800", made)
        cfg["lists"].append({"id": "L2", "name": "Errands", "color": "theme:green",
                             "source": {"type": "caldav", "accountId": TASK_ACC, "url": r["list"]["url"], "readOnly": False}})
        save_cfg()

        # Something another app wrote: an event and an Apple-style reminder.
        srv.req("PUT", home["url"] + "event.ics", "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:ev1\r\n"
                "DTSTART:20261020T150000Z\r\nDTEND:20261020T160000Z\r\nSUMMARY:Meeting\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n",
                "text/calendar")
        srv.req("PUT", home["url"] + "apple.ics", "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Apple//x//EN\r\nBEGIN:VTODO\r\n"
                "UID:apple-1\r\nDTSTAMP:20261001T000000Z\r\nSUMMARY:Buy milk\r\nDUE;VALUE=DATE:20261021\r\n"
                "X-APPLE-SORT-ORDER:5\r\nBEGIN:VALARM\r\nACTION:DISPLAY\r\nDESCRIPTION:Reminder\r\n"
                "TRIGGER:-PT15M\r\nEND:VALARM\r\nEND:VTODO\r\nEND:VCALENDAR\r\n", "text/calendar")

        r = helper(env, "sync")
        check("sync", r.get("ok") and r["results"]["L1"]["count"] == 1 and r["results"]["L2"]["count"] == 0, r)
        remote = json.load(open(remote_json))
        apple = remote["lists"]["L1"]["tasks"][0]
        check("only tasks are read", apple["title"] == "Buy milk" and apple["due"] == "2026-10-21", apple)
        r = helper(env, "sync")
        check("unchanged list is not re-read", r["results"]["L1"].get("unchanged") and not r["changed"], r)

        # Edit the Apple task: owned fields change, the alarm and sort order stay.
        apple.update(title="Buy oat milk", priority=1, notes="the big carton")
        r = helper(env, "put", inp={"listId": "L1", "task": apple})
        check("edit a task", r.get("ok") and r["task"]["title"] == "Buy oat milk" and r["task"]["priority"] == 1, r)
        _, text, _ = srv.req("GET", apple["href"])
        check("edit keeps the alarm and X- props", "BEGIN:VALARM" in text and "X-APPLE-SORT-ORDER:5" in text
              and "DESCRIPTION:Reminder" in text and "DESCRIPTION:the big carton" in text, text)

        # Stale etag: someone else changed it meanwhile.
        stale = dict(r["task"])
        srv.req("PUT", apple["href"], text.replace("SUMMARY:Buy oat milk", "SUMMARY:Changed elsewhere"), "text/calendar")
        r = helper(env, "delete", inp={"listId": "L1", "task": stale})
        check("delete with a stale etag is refused", not r.get("ok") and "changed on the server" in r.get("error", ""), r)

        # A repeating task, created with a chosen UID, and a subtask.
        parent = {"uid": "task-parent-1", "title": "Pay rent", "due": "2026-11-01", "rrule": "FREQ=MONTHLY;BYMONTHDAY=1",
                  "status": "NEEDS-ACTION", "priority": 0, "categories": ["bills"]}
        r = helper(env, "put", inp={"listId": "L2", "task": parent})
        check("create a repeating task", r.get("ok") and r["task"]["uid"] == "task-parent-1"
              and r["task"]["rrule"] == "FREQ=MONTHLY;BYMONTHDAY=1" and r["task"]["start"] == "2026-11-01", r)
        created = r["task"]
        check("object named after the uid", created["href"].endswith("/task-parent-1.ics"), created["href"])
        r = helper(env, "put", inp={"listId": "L2", "task": {"uid": "task-child-1", "title": "Get check", "parent": "task-parent-1"}})
        check("create a subtask", r.get("ok") and r["task"]["parent"] == "task-parent-1", r)
        r = helper(env, "put", inp={"listId": "L2", "task": {"uid": "task-parent-1", "title": "dup"}})
        check("creating over an existing uid is refused", not r.get("ok"), r)

        # Advance the series (what completing an occurrence does) + a history copy.
        nxt = dict(created, due="2026-12-01", start="2026-12-01")
        r = helper(env, "put", inp={"listId": "L2", "task": nxt})
        check("advance a repeating task", r.get("ok") and r["task"]["due"] == "2026-12-01" and r["task"]["status"] == "NEEDS-ACTION", r)
        done = {"uid": "task-done-1", "title": "Pay rent", "due": "2026-11-01", "status": "COMPLETED",
                "completed": "2026-10-30T18:00"}
        r = helper(env, "put", inp={"listId": "L2", "task": done})
        check("completed copy", r.get("ok") and r["task"]["status"] == "COMPLETED" and r["task"]["completed"] == "2026-10-30T18:00", r)

        r = helper(env, "sync", "L2")
        remote = json.load(open(remote_json))
        check("list L2 has three tasks", len(remote["lists"]["L2"]["tasks"]) == 3, remote["lists"]["L2"])

        # Deletes, and hrefs outside the list.
        evil = dict(done, href=srv.base + f"{USER}/home/apple.ics", etag="")
        r = helper(env, "delete", inp={"listId": "L2", "task": evil})
        check("delete outside the list is refused", not r.get("ok") and "outside" in r.get("error", ""), r)
        child = [t for t in remote["lists"]["L2"]["tasks"] if t["uid"] == "task-child-1"][0]
        r = helper(env, "delete", inp={"listId": "L2", "task": child})
        check("delete", r.get("ok") and srv.req("GET", child["href"])[0] == 404, r)

        r = helper(env, "discover", inp={"provider": "caldav", "server": srv.base, "username": USER, "password": "wrong"})
        check("wrong password", not r.get("ok") and "Sign-in failed" in r.get("error", ""), r)
        r = helper(env, "forget", inp={"listIds": ["L2"], "secretKeys": []})
        remote = json.load(open(remote_json))
        check("forget", r.get("ok") and "L2" not in remote["lists"])
        r = helper(env, "sync", "L1")
        check("the account still works for the other list", r.get("ok"), r)
        # Without the account in calendar.json the list cannot sync.
        with open(os.path.join(data, "carts", "calendar.json"), "w") as f:
            json.dump({"version": 1, "accounts": [], "calendars": []}, f)
        r = helper(env, "sync", "L1")
        check("missing account is reported", not r.get("ok") and "missing" in r["results"]["L1"].get("error", ""), r)
        check("the calendar's own cache is untouched", not os.path.exists(os.path.join(data, "carts", "remote.json")))
    finally:
        subprocess.run(["secret-tool", "clear", "service", "carts", "key", "account:" + ACC])
        subprocess.run(["secret-tool", "clear", "service", "carts", "key", "account:" + NEW_ACC])
        srv.stop()
        shutil.rmtree(tmp, ignore_errors=True)
    print("integration: " + ("all passed" if not failures else f"{len(failures)} FAILED"))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
