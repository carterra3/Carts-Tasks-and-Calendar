# Cart's Tasks and Calendar

A calendar, task list and address book for [Omarchy](https://omarchy.org),
built on its shell (Quickshell). Two parts share their data, views and sync
helpers:

- **The bar plugin** (`carterra3.carts`) replaces `omarchy.clock`. It keeps
  the same label and the right-click format ring, and adds a pop-out
  calendar that can list the day's tasks.
- **The app** is a full window that Hyprland tiles like any other app, with
  three modes:
  - **Calendar**: month, week, day, agenda and year views, events with their
    own time zones, repeating events, drag to move or resize, world clocks,
    and (optionally) your tasks on the same views.
  - **Tasks**: smart lists, projects and subtasks, natural-language quick add,
    repeating tasks, synced as standard CalDAV `VTODO`s.
  - **Contacts**: CardDAV address books.

Calendars can be local, subscribed links (ICS), or CalDAV accounts (iCloud,
Fastmail, Nextcloud, any CalDAV server); task lists local or CalDAV. One
account serves calendars, task lists and address books. No notifications, by
design.

## Install

```
git clone https://github.com/carterra3/carts-tasks-and-calendar
carts-tasks-and-calendar/bin/carts --install
```

`--install` adds **Cart's Tasks and Calendar** to the app launcher
(`~/.local/share/applications/carts.desktop`) and links `carts` into
`~/.local/bin`. Then open it from the launcher or run `carts`.

For the bar clock and popup, also link the repo as a plugin and put it on the
bar in place of `omarchy.clock` in `~/.config/omarchy/shell.json`, then run
`omarchy restart shell`:

```
ln -s "$PWD/carts-tasks-and-calendar" ~/.config/omarchy/plugins/carterra3.carts
```

Needs Omarchy's shell (Quickshell), `python3` (standard library only),
`secret-tool` (libsecret) for the keyring, and `wl-copy` for "copy" in
contacts.

## Bar

| Input        | Action                                             |
|--------------|----------------------------------------------------|
| Left click   | Open / close the popup                             |
| Right click  | Cycle clock format (same ring as the stock clock; saved to shell.json) |
| Middle click | Timezone picker                                    |
| Hover        | Today's events                                     |

A 12-hour label (`AP` in the format) makes the popup, the app and the editor
12-hour too.

## Popup

Top row: **Month / Week / Day / Agenda**, size (compact → normal → large),
and **open in the app**. View and size are saved in shell.json
(`popoutView`, `popoutSize`).

| Size | Layout |
|------|--------|
| compact | single column: view, then the selected day's events |
| normal | view + side pane (day's events, calendars, editors) |
| large | bigger view; month cells list event titles |

- **Adding by clicking:** in Week/Day view, click empty time to add an event
  at that day and half hour (a "+ time" ghost shows where). In Month view, the
  first click selects a day and a second click adds an event on it.
- **While editing**, clicking a day moves the event there, and clicking a time
  slot moves it to that day and time. Both keep its length.
- Keys: arrows/hjkl move the day, `[` `]` previous/next period, `t` today,
  `n`/Enter new event, `m` `w` `d` `a` views, `s` size, `o` open the app,
  `r` sync, Esc close. Week start: click the **W** column header.
- **Tasks** (Settings → *Tasks in the bar popup*):
  - *Day list* (default): under the selected day's events, the tasks due that
    day, and on today anything overdue. The box completes a task; clicking
    its title opens it in the app. `+` opens a new-task form in the app.
  - *Day list + calendar*: the tasks also show on the popup's views, and can
    be dragged to another day.
  - *Off*.

## The app

`bin/carts` starts it as its own Quickshell process (window class
`org.omarchy.carts`), so it survives `omarchy restart shell`. Opening it
again focuses the running window, and closing the window quits it.

```
carts [KEY [VIEW]]     open or focus, optionally on a day (yyyy-MM-dd)
                       and view (month|week|day|agenda|year)
carts --new            open with a new-event form
carts --tasks [VIEW]   open on the tasks (today|scheduled|all|important|completed)
carts --new-task       open with a new-task form
carts --task LIST|UID  open a task in the editor
carts --add TEXT       add a task to the running app, e.g. from a key binding:
                       carts --add "Call the bank tomorrow 9am !high"
carts --contacts       open on the contacts
carts --toggle         open, or quit if it is running
carts --quit
```

The popup's window button, `o`, the launcher entry and
`omarchy-shell carterra3.carts openWindow` all go through this script.

Layout: toolbar (calendar / tasks / contacts switch, Today, ‹ ›, the period,
views, sync, settings, **New event**), a sidebar (mini month, calendars, world
clocks), the main view filling the tile, and a drawer on the right for editors
and settings. On narrow tiles the sidebar steps aside while the drawer is
open. The theme follows `omarchy theme set` live.

Everywhere: `Ctrl+1` `Ctrl+2` `Ctrl+3` calendar / tasks / contacts
(`Ctrl+Tab` cycles), `Ctrl+,` settings.

Keys (calendar): arrows/hjkl move the day, `[` `]` or PageUp/PageDown
previous/next period, `t` today, `n`/Enter new event, `y` `m` `w` `d` `a`
views, `r` sync, `c` contacts, Esc closes the drawer.

### Views

- **Month**: event chips per day; multi-day and all-day events are bars
  across the week rows.
- **Week / Day**: a 24-hour grid with overlapping events side by side, an
  all-day lane with spanning bars, and a "now" line. It opens on the working
  part of the day.
- **Agenda**: the next 90 days, grouped by day.
- **Year**: twelve small months with a dot per calendar on busy days. Click a
  day to select it and again to open it in Day view. Click a month name to
  open the month.

### Drag

- Week/Day: drag an event to move it (to another day and/or time), drag its
  bottom edge to resize, drag on empty time to create an event for that range.
  All-day bars move by whole days.
- Month: drag a chip or a bar to another day. Times are kept.
- Moves snap to 15 minutes. The change shows at once and is saved in the
  background. If the server refuses it, the event goes back and a message
  says why.
- Dragging an occurrence of a repeating event opens the editor at the new time
  and asks whether the move applies to this event, this and following, or
  all events.

### Events

- Times accept `14:30`, `2:30pm`, `2pm`, `1430`; dates accept `2026-10-16`,
  `10/16`, `10/16/26`.
- **Time zone**: each timed event can have its own zone (searchable picker).
  The form shows times in that zone with your local time underneath, and the
  event keeps its wall time in that zone across daylight-saving changes.
  Saved to CalDAV with `TZID` + `VTIMEZONE`.
- **Repeat**: daily, weekly on chosen days, every weekday, monthly by date or
  by "2nd Tuesday", yearly, with an interval and an end (never / on a date /
  after N times). Rules from other apps that don't fit the presets are kept
  and shown as a summary.
- Changing or deleting one occurrence asks **This event / This and following /
  All events**. This works for local calendars and CalDAV accounts (override
  instances, `EXDATE`, and splitting the series with `UNTIL`).
- The calendar dropdown moves an event between local and account calendars.

### Time zones

- **TIME ZONES** in the sidebar lists world clocks with their offset from you.
  `+` adds a zone.
- The clock icon on a row shows that zone as a second hour column in Week/Day
  view.

## Tasks

The app's second mode (`Ctrl+2`, the toolbar switch, or `carts --tasks`).
Tasks are standard iCalendar `VTODO`s, so they show up in Apple Reminders,
Thunderbird, tasks.org/DAVx5, Nextcloud Tasks and anything else that reads
CalDAV tasks.

### Using it

- **Smart lists**: Today (due today and overdue), Scheduled (by day for a
  week, then by month), All (by list, subtasks nested), Important (high
  priority), Completed. The eye on a list hides it from the smart lists.
- **Quick add** at the top of the list (`n`). It understands:
  - dates: `today`, `tomorrow`, `fri`, `next monday`, `next week`, `in 3 days`,
    `oct 31`, `10/31`, `2026-10-31`, optionally after `on`/`due`/`by`
  - times: `at 5pm`, `5pm`, `17:30`, `noon`, `tonight`
  - repeats: `daily`, `every day`, `every 3 days`, `every other week`,
    `every weekday`, `every tue and fri`, `every mon,wed,fri`, `every month on the 1st`,
    `every 15th`, `every oct 31`, `yearly`; add `after completion` to count from when
    you finish it
  - `!high` / `!med` / `!low` (or `!!!` `!!` `!`), `#tag`, `@List`,
    `^Project` (adds it as a step of that project or task; first words are enough)
  A preview under the field shows what it understood. Adding in Today makes
  the task due today; adding in Important makes it high priority.
- **Editor** (`e`/Enter or double-click): title, list (changing it moves the
  task and its subtasks, also between this computer and a server), due date
  and time, priority, repeat, start date, tags, "subtask of", Project, notes,
  and the task's subtasks.
- Keys: `j`/`k` move, `space`/`x` complete, `s` skip a repeat, `e` edit,
  `n` quick add, `N` new task form, `P` new project, `Tab` / `Shift+Tab`
  make a subtask of the task above / move up a level, `←`/`→` (`h`/`l`) fold
  and unfold subtasks, `g` open the selected project, `t` due today,
  `.` postpone a day, `p` cycle priority, `Delete` delete (with subtasks),
  `Ctrl+Z` undo, `/` search (`#tag` filters tags), `c` show completed,
  `1`–`5` smart lists, `[` `]` previous/next view, `r` sync, Esc closes the drawer.
  (In calendar and contacts mode `c` still switches between those two.)

### Projects and subtasks

Any task can have subtasks, nested as deep as you like (shown up to five
levels). They are stored as the standard parent link
(`RELATED-TO;RELTYPE=PARENT`), so Thunderbird, tasks.org, Nextcloud Tasks and
Evolution show the same tree (Apple Reminders shows them flat over CalDAV).

- **Projects** in the sidebar: every open top-level task that has subtasks,
  plus tasks marked **Project** in the editor (stored as
  `X-OMARCHY-PROJECT:TRUE`, which other apps ignore, so tags stay free for
  contexts). A ring shows progress over every task under it. Turn off "Tasks
  with subtasks are projects" in Settings to list only marked ones.
- **Project view**: the project's progress, due date and notes at the top,
  its steps as a tree below; quick add there adds steps.
- **Building the tree**: `Tab` puts a task under the one above it,
  `Shift+Tab` moves it up a level, `^Project` in quick add, "Subtask of" in
  the editor, or "Add a subtask" in a task's editor. Folding is remembered.
- In Today and Scheduled, subtasks show their parent's name (`↳ Kitchen remodel`).
- **Completing** a task with open subtasks asks whether to complete them too
  (`a` all / `o` only this one), or always does one or the other (Settings).
  Optionally, finishing the last subtask completes its parent, all the way up.
  A repeating parent reopens its completed subtasks when it moves on.
  One `Ctrl+Z` undoes the whole thing.
- Moving a task to another list takes its subtasks along; deleting one
  deletes them (undo brings them back).

### Repeating tasks

A repeating task is one record whose due (and start) date is the current
occurrence, with an `RRULE`, like Apple Reminders, tasks.org and Thunderbird
store them. Completing it:

1. moves the dates to the next occurrence. When it is done late, the next
   date is the first one **after today**, so a missed daily task does not
   leave a trail of overdue copies (completing early moves it one step);
2. leaves a completed copy behind as history (turn off with "Keep a completed
   copy each time" in the editor's repeat section);
3. counts down `COUNT` and stops at `UNTIL`; the last occurrence completes
   the task for good.

**After completion** (`every 6 weeks after completion`, or "Next date counts
from: When I complete it"): the next due date is the interval after the day
you completed it, keeping the time and the gap to the start date. Stored as
`X-OMARCHY-REPEAT-FROM:COMPLETION`; other apps see a normal repeating task.

`s` (or **Skip**) moves to the next date without completing. Undo puts the
task back as it was and removes the history copy.

Repeats are daily, weekly on chosen days, every weekday, monthly by date or
by "2nd Tuesday", yearly, with an interval and an end (never, on a date,
after N times). Rules from other apps that the presets cannot show are kept
and summarized. Occurrences other apps completed or skipped (`EXDATE`,
completed `RECURRENCE-ID` overrides) are honored: the task shows at its next
real date.

### Lists and accounts

`+` next to LISTS:

- **From an account**: any account already connected (for calendars, address
  books or other lists), or a new sign-in. Pick the collections that can hold
  tasks, or **create a new list on the server** (MKCALENDAR, tasks only).
  Collections that also hold events are marked; Tasks shows only their tasks
  and the calendar only their events.
- **On this computer**: a local list in tasks.json.

Editing a list: rename, color (theme colors follow `omarchy theme set`),
default list for quick add, show in smart lists (and on the calendar), sync
now, remove (server lists are only unsubscribed; nothing is deleted on the
server). Removing the last calendar, address book or list of an account
removes the account and its keyring password.

Task lists sync at startup, every 10 minutes, when the window is shown (if
stale) and with `r`. A list whose ctag/sync-token is unchanged is not
downloaded again. Edits go straight to the server with `If-Match`, so a task
changed elsewhere is not overwritten. Editing a synced task replaces only the
properties the form owns (`SUMMARY`, `DESCRIPTION`, `STATUS`, `COMPLETED`,
`PERCENT-COMPLETE`, `PRIORITY`, `DTSTART`, `DUE`, `RRULE`, `EXDATE`,
`CATEGORIES`, the parent `RELATED-TO`) and keeps everything else: alarms,
attachments, `X-APPLE-SORT-ORDER` and other apps' properties.

### Tasks on the calendar

With Settings → *Show tasks on the calendar* on (the default), tasks with a
due date appear in the calendar views in their list's color, marked with a
box: a date-only due as an all-day item, a timed one as a 30-minute block.
Click one to open it in the task editor (without leaving the calendar); drag
it to give it a new date or time. Completed tasks leave the calendar unless
*Include completed tasks* is on. A list hidden from the smart lists is hidden
here too. A repeating task shows its current occurrence.

## Settings

The gear in the toolbar (`Ctrl+,`):

| Setting | Where it is saved |
|---|---|
| Show tasks on the calendar · include completed ones | calendar.json prefs |
| Tasks in the bar popup: off / day list / day list + calendar | calendar.json prefs (the plugin reads it) |
| Completing a task with open subtasks · last subtask completes the parent · tasks with subtasks are projects · keep history of repeats · default list for quick add | tasks.json prefs |

## Hiding synced events

Open an event from a synced calendar (link or account) and choose **Hide**.
For a repeating event, choose **Hide this one** or **Hide all repeats**.

- Hiding is local only. Nothing changes on the server or for anyone else
  sharing the calendar. Hidden events stay hidden across syncs because they're
  matched by the event's UID (plus the occurrence's start time for one repeat).
- An **Undo** bar shows for 10 seconds after hiding.
- **Hidden events (N)** under Calendars lists everything hidden, with
  **Unhide** on each. Clicking an entry jumps to its day. Entries whose event
  has since been cancelled or deleted at the source are marked "no longer in
  the calendar", and one button clears them all.
- On writable account calendars, **Delete for everyone** still removes the event
  from the server. Use Hide when you only want it out of your own view.

## Colors and themes

A calendar's color is stored as either:

- `theme:<role>` (e.g. `theme:blue`, `theme:bright_magenta`, `theme:accent`):
  resolved against the active theme's `colors.toml` each time it is drawn, so
  it changes when you run `omarchy theme set`. New calendars default to the
  first theme color no other calendar is using.
- `#rrggbb`: a fixed custom color that stays the same in every theme.

## Remote calendars

`+` next to CALENDARS offers three kinds:

| Kind | Works with | Access |
|------|-----------|--------|
| **Local** | this computer | read/write |
| **Link** | Google "Secret address in iCal format", Outlook "Publish a calendar" ICS link, Proton "Share with anyone" link, iCloud public calendars, any `.ics`/`webcal://` URL | read-only |
| **Account** | iCloud (app-specific password), Fastmail (app password), Nextcloud (app password), any CalDAV server | read/write |

- Links and account passwords are stored in the desktop keyring (`secret-tool`,
  service `carts`), never in the JSON files or on a command line.
- Calendars sync on startup, every 15 minutes, when the popup or app opens
  (if the last sync is over 5 minutes old), and from the sync button. The
  plugin and the app share the cache, so one doesn't sync right after the
  other did.
- Unchanged calendars are cheap to check: ICS links use `ETag` /
  `Last-Modified` when the server sends them, and CalDAV calendars compare
  their ctag/sync-token before downloading anything.
- Repeating remote events are expanded from 120 days back to 400 days ahead.
- Removing a remote calendar only unsubscribes it here. Nothing is deleted on
  the server.
- Plain `http://` is only allowed to this machine (local test servers).
  Passwords are never sent on a redirect to another site.
- Google can take several hours to update a secret iCal feed.

## Contacts

The app's third mode, for CardDAV address books: `Ctrl+3`, the toolbar's
switch, `c` from the calendar, or `carts --contacts`.

- `+` next to ADDRESS BOOKS adds books from an account already connected for
  calendars (same keyring password) or a new sign-in: iCloud
  (`contacts.icloud.com`), Fastmail (`carddav.fastmail.com`), Nextcloud, or
  any CardDAV server.
- Click a book in the sidebar to show only its contacts. The pencil renames
  it (here only) or removes it (nothing is deleted on the server).
- Search matches names, company, email, phone digits, address and notes.
- The card shows phones, emails, addresses, websites, birthday (with age)
  and notes. Click a value to call, mail, open it or look up the address;
  right-click copies it.
- **New contact** / **Edit** write straight to the server, with `If-Match` on
  edits so a contact changed elsewhere is not overwritten. Edits replace only
  the fields the form shows; photos, groups and other properties on the card
  are kept. Changing the address book moves the contact (create there, delete
  here). Delete asks first.
- Keys: `↑↓`/`j k` move, `/` search (Esc clears it), `n` new, `e`/Enter edit,
  `r` sync, `c` back to the calendar.
- Contacts sync at startup, with the calendars, and when the contacts view
  opens.

## Data

All in `~/.local/share/carts/` (directory mode 700):

| File | Contents | Written by |
|------|----------|------------|
| `calendar.json` | calendars, accounts and address books (no secrets), local events, hidden events, app prefs | the plugin and the app |
| `backups/` | copies of calendar.json from before writes (at most one a minute, newest 60 kept) | the plugin and the app |
| `remote.json` | cache of events from links and accounts | `sync/calsync.py` |
| `remote-status.json` | last sync time / error per calendar | `sync/calsync.py` |
| `contacts.json` | cache of contacts per address book | `sync/calsync.py` |
| `tasks.json` | task lists (no secrets), local tasks, task prefs | the plugin and the app |
| `backups/tasks-*.json` | copies of tasks.json from before writes | the plugin and the app |
| `tasks-remote.json` | cache of tasks from CalDAV lists | `sync/tasksync.py` |
| `tasks-status.json` | last sync time / error per task list | `sync/tasksync.py` |

calendar.json and tasks.json are watched, so edits from the other process (or
by hand) show up live. If one fails to parse, nothing writes to it until it is
fixed. Passwords and private links are in the desktop keyring (`secret-tool`,
service `carts`; accounts under `account:<id>`, links under
`ics:<calendarId>`).

`sync/` holds standard-library Python helpers: `calsync.py` (calendars, ICS
links, address books), `tasksync.py` (task lists), both on `dav.py` (HTTP and
WebDAV with the hardening in [docs/SECURITY.md](docs/SECURITY.md)), plus
`ical.py`, `series.py`, `tzdata.py`, `vcard.py`, `vtodo.py` and
`importer.py`. The QML runs each one job at a time and passes secrets over
stdin.

### Coming from the separate Calendar or Tasks apps

The first time Cart's Tasks and Calendar starts, `sync/importer.py` copies the data of the older
standalone apps (`~/.local/share/omarchy-calendar`,
`~/.local/share/omarchy-tasks`) and their keyring entries into its own. The
Tasks app's accounts are folded into the calendar's (matched by the account
they were taken over from, or by provider, server and username). The old
folders and keyring entries are only read, so the old apps keep working. It
runs once: not when its data folder already has data, and never again after
`.imported` is written. `python3 sync/importer.py --dry-run` shows what it
would do; `CARTS_NO_IMPORT=1` skips it.

## Structure

- `Service.qml`: the plugin's single instance: stores, IPC, launcher entry.
- `BarWidget.qml` + `Panel.qml` (+ `PopupTasks.qml`): bar label and popup.
- `CalendarApp.qml` + `CalendarWindow.qml`: the app's root and its window
  (all three modes).
- `Store.qml`: calendars, accounts, address books and their caches, the
  helper queue, the theme palette, zone tables.
- `TaskStore.qml`: task lists, tasks and their cache, the task helper queue,
  optimistic writes, undo. `TaskBridge.qml` puts tasks on a Store's views.
- Tasks: `Sidebar`, `TaskList`, `TaskEditor` (+ `RepeatEditor`),
  `ListEditor`; `SettingsPane` for the settings drawer.
- Views: `MainView`, `MonthGrid`, `TimeGrid`, `AgendaList`, `YearView`,
  `CalendarList`, `WorldClocks`, `HiddenList`, `UndoBar`.
- Editors: `EventEditor` (+ `RepeatEditor`), `CalendarEditor`.
- Contacts: `ContactsView`, `ContactEditor`, `AddressBookList`,
  `AddressBookEditor`.
- Logic without Qt (unit tested under node): `Events.js`, `Recur.js`,
  `Tz.js`, `Contacts.js`, `Palette.js`, `Model.js`, `Tasks.js`.

## IPC

Plugin (popup and app launcher):

```
omarchy-shell carterra3.carts toggle|open|close|newEvent|newCalendar|subscribe|connectAccount|sync|cycleFormat|cycleView|cycleSize|openWindow|closeWindow|toggleWindow|newEventWindow|openTasks|newTaskWindow
```

e.g. bind `omarchy-shell carterra3.carts newEvent` to a key. The app
itself answers `quickshell ipc -p CalendarApp.qml call carts
present KEY VIEW | tasks VIEW | contacts | newEvent | newTask | openTask KEY |
add TEXT | sync | quit`, which is what `bin/carts` uses (`add` returns an
error message, or nothing when the task was added).

## Tests

- `node tests/model.test.js`: dates, events, layout, palette
- `node tests/series_local.test.js`: editing local repeating events
- `node tests/contacts.test.js`: contact search, sorting, form validation
- `node tests/tasks.test.js`: task recurrence (schedule, after completion,
  COUNT, UNTIL, EXDATE, DST, a 400-rule property walk), quick add, views,
  the form, tasks on the calendar and in the popup
- `node tests/bench.js [DATA_DIR]`: view query timings on your own data
  (read only)
- `python3 tests/test_ical.py`: iCalendar parsing and recurrence. With
  python-dateutil installed it also checks 38 rules against `dateutil.rrule`.
- `python3 tests/test_recur.py`: `Recur.js` against the Python expansion
- `python3 tests/test_series.py`, `tests/test_series_ics.py`: series edits
  (this / following / all) and how they are written to iCalendar
- `python3 tests/test_tz.py`: zone tables and conversions
- `python3 tests/test_vcard.py`: vCard 3/4 parsing and in-place editing
- `python3 tests/test_calsync.py`: URL and redirect checks, sync bookkeeping
- `python3 tests/test_vtodo.py`: reading and writing VTODOs
- `python3 tests/test_importer.py`: the one-time import (with a fake
  `secret-tool`, so your keyring is not touched)
- With Radicale installed in a venv (`pip install radicale`):
  - `<venv>/bin/python tests/integration_radicale.py`: `calsync.py` end to
    end against a real CalDAV/CardDAV server and an ICS feed.
  - `<venv>/bin/python tests/integration_tasks.py`: `tasksync.py` end to end
    (shared accounts, MKCALENDAR, sync, edits keeping alarms, 412 conflicts,
    href checks).
  - `<venv>/bin/python tests/run_qml.py [SUITE ...]`: the calendar QML suites
    in `tests/qml/` (app window and shortcuts, drag, editor time zones,
    contacts), headless against the real components.
  - `<venv>/bin/python tests/run_qml_tasks.py [SUITE ...]`: the `tasks_*`
    suites (tasks window and keys, editors, projects, tasks on the calendar,
    settings, offscreen renders; set `SHOT_DIR` to save PNGs).

All of them use temporary data and remove their test keyring entries.

## Demo data

`python3 tools/demo.py` opens the app on made-up calendars and tasks dated
around today, in a temporary data folder, for screenshots or a test drive.
Add `--radicale <python with radicale>` for demo contacts from a throwaway
local server. Close the window to end it; nothing of yours is read or
changed. Quit the app first (`carts --quit`).

## Known limits

- Remote repeating events are only expanded within the sync window (120 days
  back, 400 ahead).
- Contacts: no contact groups, no adding or changing photos (existing ones
  are kept), and birthdays are not shown on the calendar.
- Tasks: no notifications (alarms from other apps are kept but not shown);
  timed tasks in another time zone are shown and repeated in local time; no
  drag to reorder in the list (the "Server order" sort follows
  `X-APPLE-SORT-ORDER`); the calendar shows a repeating task's current
  occurrence only.
- Tasks written here mark projects and "repeat after completion" with
  `X-OMARCHY-PROJECT` / `X-OMARCHY-REPEAT-FROM` (other apps ignore them).
