# Plan: Tasks as a mode of Cart's Tasks and Calendar

The app started as the calendar plugin and app; the standalone Tasks app was
folded in as a third mode. This file tracks that work.

## Decisions

- **One window, three modes.** Calendar, Tasks, Contacts share the toolbar,
  sidebar slot and drawer (`CalendarWindow.qml`). `Ctrl+1/2/3` switch modes
  everywhere; inside a mode the old keys stay (`c` toggles calendar/contacts
  there, but means "show completed" in Tasks, as it did in the Tasks app).
  The task editor and the settings drawer open from any mode.
- **Two stores, one data folder.** `Store` (calendar.json) and `TaskStore`
  (tasks.json) stay separate files: different writers, smaller blast radius
  when one fails to parse, no migration of the calendar's format.
- **One account list** in calendar.json, one keyring service (`carts`). The
  Tasks app's "take over the Calendar's account, copy its password" scheme is
  gone.
- **Two helpers on one HTTP layer.** `calsync.py` and `tasksync.py` keep their
  own commands and caches but share `dav.py`, so the security-relevant code
  exists once.
- **Tasks on calendar views as stand-in events** (`Tasks.calendarItems`,
  `TaskBridge`), so every view shows them without changes. Two independent
  settings: the app's calendar views (`tasksOnCalendar`,
  `tasksOnCalendarCompleted`) and the bar popup (`popupTasks`: off / day list
  / day list + calendar). Both live in calendar.json prefs because the plugin
  process has to read them.
- **One-time import** (`sync/importer.py`) from `~/.local/share/omarchy-calendar`
  and `~/.local/share/omarchy-tasks`; the old data is never changed.
- **New identity** so it can run next to the old apps: plugin
  `carterra3.carts`, command `carts`, window class `org.omarchy.carts`, data
  `~/.local/share/carts`. Task properties keep their `X-OMARCHY-*` names so
  tasks already on servers keep their project / repeat-from flags.

## Status

- [x] Fork, new identity, sanitized tests and docs, fresh history.
- [x] Task model, store, editors, sidebar and list in the app as Tasks mode.
- [x] Shared accounts (Store.ensureAccount / releaseAccount, tasks.json
      account refs), shared keyring service, tasksync.py on calendar.json.
- [x] calsync.py uses dav.py (no second copy of the HTTP hardening).
- [x] Tasks on the calendar views: click opens the task editor, drag moves
      the due date; setting to turn off, setting for completed tasks.
- [x] Popup: day list of tasks with a box to complete them; setting for
      off / day list / day list + calendar.
- [x] bin/carts: `--tasks`, `--new-task`, `--task`, `--add`; IPC to match.
- [x] Import from the old apps, with tests (fake keyring).
- [x] Tests: node, python, Radicale integration for both helpers, QML suites
      for both modes and the merged behavior.
- [ ] Live check in the real shell: plugin popup with tasks (Panel.qml cannot
      load offscreen), the import on real data, theme changes.
- [ ] Publish: create the GitHub repo, add screenshots to the README.

## Later

- Show the next few occurrences of a repeating task on the calendar.
- Bar label option with today's open task count.
- Quick add from the popup.
- Rename the mode-neutral files (`CalendarApp.qml`, `CalendarWindow.qml`) once
  nothing depends on the paths.
- The year view builds twelve months at once and takes seconds on first
  show (offscreen); build months lazily.
