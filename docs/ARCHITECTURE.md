# Architecture

Carts is two programs that share one data folder, one store and one sync
helper:

- the **bar plugin** (`carterra3.carts`: `manifest.json`, `Service.qml`,
  `BarWidget.qml`, `Panel.qml`), which runs inside Omarchy's shell and
  replaces the stock clock, and
- the **app** (`CalendarApp.qml`, started by `bin/carts`), a standalone
  Quickshell process with its own window class (`org.omarchy.carts`), so
  Hyprland tiles it like any other application.

Both load `Store.qml`, the views, the pure-JS logic (`Events.js`, `Recur.js`,
`Tz.js`, `Contacts.js`, `Palette.js`, `Model.js`) and talk to `sync/`.

## Decisions

- **Standalone Quickshell, not GTK.** The app reuses the plugin's views and
  Omarchy's `qs.Ui` components, so it looks and behaves like the shell.
  Quickshell only resolves modules inside the config folder, so the app's
  root file lives at the repo root and `bin/carts` creates gitignored
  `Commons`/`Ui` symlinks to `$OMARCHY_PATH/shell/`. The root needs
  `//@ pragma OmarchyLoadPatch`, or a bare `Color` resolves to Qt's own type.
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

## Data flow

```
 Store.qml ──writes──▶ calendar.json ◀──reads── sync/calsync.py ──writes──▶ remote.json
     ▲   └──── runs one helper job at a time (JSON on stdin/stdout) ────┘        │
     └──────────────────────────── watches ─────────────────────────────────────┘
```

Secrets never pass through argv or the JSON files: the store hands them to
the helper on stdin and the helper keeps them in the desktop keyring
(`secret-tool`, service `carts`).

See [SECURITY.md](SECURITY.md) for how the helper treats servers.
