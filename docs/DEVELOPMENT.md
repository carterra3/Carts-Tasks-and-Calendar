# Development

Notes for working on Cart's Tasks and Calendar. See also
[ARCHITECTURE.md](ARCHITECTURE.md) and [SECURITY.md](SECURITY.md).

## Running from a checkout

`bin/carts` runs the app from `~/.cache/carts/app`, a folder of links to the
repo's QML/JS and `sync/` plus Omarchy's `qs.Commons` / `qs.Ui` (Quickshell
only finds modules inside the config folder, and `omarchy plugin` refuses
symlinks inside a plugin folder). Edits to the repo hot-reload the running
app. `bin/carts --config-dir` prints the folder.

For the bar plugin, link the checkout as `~/.config/omarchy/plugins/carterra3.carts`
and run `omarchy restart shell` after changes to `Service.qml` or the IPC.

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
itself answers `quickshell ipc -p ~/.cache/carts/app/CalendarApp.qml call carts
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

## Data files

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
WebDAV with the hardening in [docs/SECURITY.md](SECURITY.md)), plus
`ical.py`, `series.py`, `tzdata.py`, `vcard.py`, `vtodo.py` and
`importer.py`. The QML runs each one job at a time and passes secrets over
stdin.

### Import from the earlier standalone apps

The first time the app or plugin starts, `sync/importer.py` copies the data
of the older standalone apps (`~/.local/share/omarchy-calendar`,
`~/.local/share/omarchy-tasks`) and their keyring entries into its own. The
Tasks app's accounts are folded into the calendar's (matched by the account
they were taken over from, or by provider, server and username). The old
folders and keyring entries are only read, so the old apps keep working. It
runs once: not when its data folder already has data, and never again after
`.imported` is written. `python3 sync/importer.py --dry-run` shows what it
would do; `CARTS_NO_IMPORT=1` skips it.
