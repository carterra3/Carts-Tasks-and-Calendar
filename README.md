# Carts: Tasks and Calendar for Omarchy

A calendar, task list and address book for [Omarchy](https://omarchy.org),
built on its shell (Quickshell). Two parts share their data, views and sync
helper:

- **The bar plugin** (`carterra3.carts`) replaces `omarchy.clock`. It keeps
  the same label and the right-click format ring, and adds a pop-out
  calendar.
- **The app** is a full window that Hyprland tiles like any other app. It has
  month, week, day, agenda and year views, events with their own time zones,
  repeating events, drag to move or resize, world clocks, and a contacts mode
  for CardDAV address books.

Calendars can be local, subscribed links (ICS), or CalDAV accounts (iCloud,
Fastmail, Nextcloud, any CalDAV server). No notifications, by design.

> **Status:** tasks (CalDAV `VTODO`) are being merged in as a third mode; see
> [docs/plan.md](docs/plan.md).

## Install

```
git clone https://github.com/carterra3/carts-tasks-and-calendar
ln -s "$PWD/carts-tasks-and-calendar" ~/.config/omarchy/plugins/carterra3.carts
```

Then add `carterra3.carts` to the bar in `~/.config/omarchy/shell.json` (in
place of `omarchy.clock`) and run `omarchy restart shell`. The plugin writes a
launcher entry (`~/.local/share/applications/carts.desktop`), so **Carts**
shows up in the app launcher. To run the app from a terminal, link
`bin/carts` into your `PATH` (e.g. `ln -s "$PWD/carts-tasks-and-calendar/bin/carts" ~/.local/bin/`).

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

## The app

`bin/carts` starts it as its own Quickshell process (window class
`org.omarchy.carts`), so it survives `omarchy restart shell`. Opening it
again focuses the running window, and closing the window quits it.

```
carts [KEY [VIEW]]   open or focus, optionally on a day (yyyy-MM-dd)
                     and view (month|week|day|agenda|year)
carts --new          open with a new-event form
carts --contacts     open on the contacts
carts --toggle       open, or quit if it is running
carts --quit
```

The popup's window button, `o`, the launcher entry and
`omarchy-shell carterra3.carts openWindow` all go through this script.

Layout: toolbar (calendar/contacts switch, Today, ‹ ›, the period, views,
sync, **New event**), a sidebar (mini month, calendars, world clocks), the
main view filling the tile, and a drawer on the right for editors. On
narrow tiles the sidebar steps aside while the drawer is open. The theme
follows `omarchy theme set` live.

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

The app's second mode, for CardDAV address books: the toolbar's
calendar/contacts switch, `c`, or `carts --contacts`.

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

calendar.json is watched, so edits from the other process (or by hand) show
up live. If it fails to parse, nothing writes to it until it is fixed.

`sync/` is a standard-library Python helper (`calsync.py` for HTTP, CalDAV,
CardDAV and the keyring, `ical.py`, `series.py`, `tzdata.py`, `vcard.py`).
The QML runs it one job at a time and passes secrets over stdin.

## Structure

- `Service.qml`: the plugin's single instance: store, IPC, launcher entry.
- `BarWidget.qml` + `Panel.qml`: bar label and popup.
- `CalendarApp.qml` + `CalendarWindow.qml`: the app's root and its window.
- `Store.qml`: everything persisted, the remote caches, the helper queue,
  the theme palette, zone tables.
- Views: `MainView`, `MonthGrid`, `TimeGrid`, `AgendaList`, `YearView`,
  `CalendarList`, `WorldClocks`, `HiddenList`, `UndoBar`.
- Editors: `EventEditor` (+ `RepeatEditor`), `CalendarEditor`.
- Contacts: `ContactsView`, `ContactEditor`, `AddressBookList`,
  `AddressBookEditor`.
- Logic without Qt (unit tested under node): `Events.js`, `Recur.js`,
  `Tz.js`, `Contacts.js`, `Palette.js`, `Model.js`.

## IPC

Plugin (popup and app launcher):

```
omarchy-shell carterra3.carts toggle|open|close|newEvent|newCalendar|subscribe|connectAccount|sync|cycleFormat|cycleView|cycleSize|openWindow|closeWindow|toggleWindow|newEventWindow
```

e.g. bind `omarchy-shell carterra3.carts newEvent` to a key. The app
itself answers `quickshell ipc -p CalendarApp.qml call carts
present KEY VIEW | newEvent | contacts | sync | quit`, which is what
`bin/carts` uses.

## Tests

- `node tests/model.test.js`: dates, events, layout, palette
- `node tests/series_local.test.js`: editing local repeating events
- `node tests/contacts.test.js`: contact search, sorting, form validation
- `node tests/bench.js`: view query timings on a 340-event calendar
- `python3 tests/test_ical.py`: iCalendar parsing and recurrence. With
  python-dateutil installed it also checks 38 rules against `dateutil.rrule`.
- `python3 tests/test_recur.py`: `Recur.js` against the Python expansion
- `python3 tests/test_series.py`, `tests/test_series_ics.py`: series edits
  (this / following / all) and how they are written to iCalendar
- `python3 tests/test_tz.py`: zone tables and conversions
- `python3 tests/test_vcard.py`: vCard 3/4 parsing and in-place editing
- `python3 tests/test_calsync.py`: URL and redirect checks, sync bookkeeping
- With Radicale installed in a venv (`pip install radicale`):
  - `<venv>/bin/python tests/integration_radicale.py`: the helper end to end
    against a real CalDAV/CardDAV server and an ICS feed.
  - `<venv>/bin/python tests/run_qml.py [SUITE ...]`: the QML suites in
    `tests/qml/` (app window and shortcuts, drag, editor time zones,
    contacts), headless against the real components.

Both use a temporary data dir and remove their test keyring entries.

## Known limits

- Remote repeating events are only expanded within the sync window (120 days
  back, 400 ahead).
- Contacts: no contact groups, no adding or changing photos (existing ones
  are kept), and birthdays are not shown on the calendar.
