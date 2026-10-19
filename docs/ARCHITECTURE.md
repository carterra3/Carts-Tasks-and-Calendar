# Architecture

Cart's Tasks and Calendar is two programs that share one data folder, two stores (calendar and
tasks) and two sync helpers:

- the **bar plugin** (`carterra3.carts`: `manifest.json`, `Service.qml`,
  `BarWidget.qml`, `Panel.qml`), which runs inside Omarchy's shell and
  replaces the stock clock, and
- the **app** (`CalendarApp.qml`, started by `bin/carts`), a standalone
  Quickshell process with its own window class (`org.omarchy.carts`), so
  Hyprland tiles it like any other application.

Both load `Store.qml` (calendars, accounts, address books) and
`TaskStore.qml` (task lists, tasks), the views, the pure-JS logic
(`Events.js`, `Recur.js`, `Tz.js`, `Contacts.js`, `Palette.js`, `Model.js`,
`Tasks.js`) and talk to `sync/`.

## Decisions

- **Standalone Quickshell, not GTK.** The app reuses the plugin's views and
  Omarchy's `qs.Ui` components, so it looks and behaves like the shell.
  Quickshell only resolves modules inside the config folder, so `bin/carts`
  runs the app from `~/.cache/carts/app`, a folder of links to the repo's
  files and to `$OMARCHY_PATH/shell/{Commons,Ui}` (the plugin folder itself
  must stay free of symlinks for `omarchy plugin add/update`). The root
  needs `//@ pragma OmarchyLoadPatch`, or a bare `Color` resolves to Qt's
  own type.
- **The app quits when its window closes.** The plugin keeps syncing in the
  background. Theme changes are only pushed to the shell over IPC, so the app
  watches `theme.name` and reloads `Color` itself.
- **Two processes write `calendar.json`.** The store reloads on outside edits
  and ignores its own writes (it remembers the texts it wrote recently,
  because Quickshell's `FileView` can coalesce writes and report them late).
  Concurrent edits within milliseconds: last writer wins.
- **One sync at a time across both processes.** Periodic sync is skipped when
  the other process synced recently (`remote-status.json` `syncedAt`).
- **Times keep their zone.** Timed events are written with `TZID` +
  `VTIMEZONE`, never bare UTC, so repeats keep their wall time across
  daylight-saving changes. The helper resolves the local zone by name
  (`$TZ`, then the `/etc/localtime` link), not today's fixed offset.
- **Views are built only while visible.** Each view sits in a `Loader`, and
  the popup loads its contents only while open. Events are indexed by day
  once per store change (`Events.buildIndex`); views look their day up
  instead of scanning every event.
- **Sync is cheap when nothing changed.** ICS links use `ETag` /
  `Last-Modified`; CalDAV collections compare ctag / sync-token before a
  REPORT. Fast-changing status lives in `remote-status.json`, so an unchanged
  sync does not rewrite (and re-index) the big event cache. Feeds are fetched
  four at a time.

- **One account list.** Accounts live in calendar.json and serve calendars,
  address books and task lists alike, with one keyring entry each
  (`account:<id>`). `TaskStore` reads them from `Store` and asks it to add
  one (`ensureAccount`) or let one go (`releaseAccount`, which only removes an
  account nothing uses; `Store` reads tasks.json to see which accounts task
  lists use, so the plugin never drops an account the app's lists need).
- **Tasks on the calendar are stand-ins.** `Tasks.calendarItems` turns dated
  tasks into event-shaped records (`taskRef: "listId|uid"`) in pseudo
  calendars `tasks:<listId>`; `TaskBridge` feeds them to a Store's
  `taskEvents`/`taskCalendars`, which merges them into the day index. Every
  view draws them with no special code; the window and the popup route
  clicks (`taskRef`) to the task editor and drags (`Store.moveEvent` →
  `taskHandler.moveTask`) to a new due date. The app and the plugin each
  decide whether to fill them (two settings).
- **Recurrence of tasks lives in JS only** (`Tasks.advance`): completing a
  repeating task moves the record to its next date (the Apple Reminders /
  tasks.org / Thunderbird model) and leaves a completed copy as history. The
  helper only reads and writes fields.
- **Optimistic task writes.** An edit to a synced task shows at once
  (`TaskStore.pending`) and stays until the helper's cache file is read back;
  a refusal rolls it back with a message. Undo covers complete, reopen, skip,
  move and delete.

## Data flow

```
 Store.qml ──writes──▶ calendar.json ◀──reads── sync/calsync.py ──writes──▶ remote.json, contacts.json
     ▲   └──── runs one helper job at a time (JSON on stdin/stdout) ────┘        │
     └──────────────────────────── watches ─────────────────────────────────────┘

 TaskStore.qml ──writes──▶ tasks.json ◀──reads── sync/tasksync.py ──writes──▶ tasks-remote.json
     ▲     (accounts: calendar.json, read by both)  ┘                            │
     └──────────────────────────── watches ─────────────────────────────────────┘
```

On first start both stores run `sync/importer.py` before reading their files;
it copies data from the older standalone Calendar and Tasks apps once.

Secrets never pass through argv or the JSON files: the store hands them to
the helper on stdin and the helper keeps them in the desktop keyring
(`secret-tool`, service `carts`).

See [SECURITY.md](SECURITY.md) for how the helper treats servers.
