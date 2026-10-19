import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Events.js" as Events
import "Palette.js" as Palette
import "Recur.js" as Recur
import "Tz.js" as Tz
import "Contacts.js" as Contacts

// Owns everything the calendar persists, the remote-calendar cache, the sync
// helper, and the live theme palette.
//
//   ~/.local/share/carts/calendar.json  calendars, accounts, local events (written here)
//   ~/.local/share/carts/remote.json    events fetched from links/accounts (written by sync/calsync.py)
//
// Secrets (account passwords, private iCal links) go straight from the form
// to the desktop keyring through the helper's stdin; they are never written
// to either file or passed on a command line.
Item {
  id: root
  visible: false

  readonly property string home: Quickshell.env("HOME")
  readonly property string dataHome: Quickshell.env("XDG_DATA_HOME") || (home + "/.local/share")
  readonly property string dataDir: dataHome + "/carts"
  readonly property string dataPath: dataDir + "/calendar.json"
  readonly property string remotePath: dataDir + "/remote.json"
  readonly property string statusPath: dataDir + "/remote-status.json"
  readonly property string contactsPath: dataDir + "/contacts.json"
  readonly property string helperPath: decodeURIComponent(String(Qt.resolvedUrl("sync/calsync.py")).replace(/^file:\/\//, ""))
  readonly property string importerPath: decodeURIComponent(String(Qt.resolvedUrl("sync/importer.py")).replace(/^file:\/\//, ""))
  readonly property string tasksPath: dataDir + "/tasks.json"

  property int syncMinutes: 15

  property var calendars: []
  property var accounts: []
  // CardDAV address books: { id, name, accountId, url, readOnly }
  property var addressBooks: []
  property var events: []          // local events only
  // Unknown top-level keys from disk ride along untouched on save.
  property var extra: ({})

  // calId -> { events, ... } (remote.json, rewritten only when events change)
  property var remote: ({})
  // calId -> { syncedAt, error, failedAt } (remote-status.json, every sync)
  property var remoteStatus: ({})
  readonly property var remoteEvents: {
    var out = []
    for (var i = 0; i < calendars.length; i++) {
      var entry = remote[calendars[i].id]
      if (entry && entry.events) out = out.concat(entry.events)
    }
    return out
  }
  // Local repeating events are stored once and expanded here, over a window
  // wide enough for any view (two years back, three ahead).
  readonly property real expandFrom: new Date(new Date().getFullYear() - 2, 0, 1).getTime()
  readonly property real expandTo: new Date(new Date().getFullYear() + 3, 11, 31).getTime()
  readonly property var localEvents: Events.expandAll(events, Recur, Tz, function(z) { return root.zoneTable(z) }, expandFrom, expandTo)
  // Edits on their way to a server, shown right away (calendarId|uid -> record).
  property var pending: ({})
  function setPending(ev, changed) {
    var next = {}
    for (var k in root.pending) next[k] = root.pending[k]
    next[ev.calendarId + "|" + ev.uid] = changed
    root.pending = next
  }
  function clearPending(ev) {
    var next = {}
    for (var k in root.pending) if (k !== ev.calendarId + "|" + ev.uid) next[k] = root.pending[k]
    root.pending = next
  }
  // Everything, including events the user hid; views use allEvents.
  readonly property var rawEvents: {
    var all = localEvents.concat(remoteEvents)
    var p = root.pending
    var any = false
    for (var k in p) { any = true; break }
    if (!any) return all
    return all.map(function(e) { return p[e.calendarId + "|" + e.uid] || e })
  }

  // A drag moved/resized `ev` into `changed` (not for repeating events,
  // which go through the editor to ask which occurrences).
  function moveEvent(ev, changed, callback) {
    var done = callback || function() {}
    if (ev && ev.taskRef) {
      if (root.taskHandler) root.taskHandler.moveTask(ev, changed, done)
      else done("Tasks are not available here")
      return
    }
    if (!eventEditable(ev)) { done("This event is read-only"); return }
    changed.updated = new Date().toISOString()
    var remote = isRemote(ev.calendarId)
    if (remote) setPending(ev, changed)
    saveEvent(changed, ev, function(err) {
      if (remote) Qt.callLater(function() { root.clearPending(ev) })
      done(err)
    })
  }
  readonly property var allEvents: Events.withoutHidden(rawEvents, hidden)

  // Tasks shown on the calendar: event-shaped stand-ins made by the task
  // store (TaskEvents.js), each with `taskRef` set, plus one pseudo calendar
  // per task list ("tasks:<listId>") for their colors. Whoever owns this
  // store decides whether to fill these (the app and the popup each have a
  // setting); empty means no tasks on the calendar.
  property var taskEvents: []
  property var taskCalendars: []
  // { moveTask(ev, changed, done), openTask(ev) } from the owner, for drags
  // and clicks on a task in the views.
  property var taskHandler: null
  function taskCalendarById(id) {
    for (var i = 0; i < taskCalendars.length; i++) if (taskCalendars[i].id === id) return taskCalendars[i]
    return null
  }

  // Visible events by day, built once per change; views look their days up
  // here instead of scanning every event (see Events.buildIndex).
  readonly property var dayIndex: taskEvents.length
    ? Events.buildIndex(allEvents.concat(taskEvents), calendars.concat(taskCalendars))
    : Events.buildIndex(allEvents, calendars)
  function eventsOn(key) { return Events.eventsOn(dayIndex, key) }

  // Hidden synced events (see Events.js "Hidden events"). Stored in
  // calendar.json, applied after every sync, never sent to the server.
  property var hidden: []
  readonly property var hiddenView: {
    var present = Events.presentKeys(rawEvents)
    return hidden.map(function(h, i) {
      var cal = calendarById(h.calendarId)
      return {
        index: i, entry: h, key: Events.hiddenKey(h),
        calendarName: cal ? cal.name : "(removed calendar)",
        present: !!present[Events.hiddenKey(h)]
      }
    }).sort(function(a, b) { return String(a.entry.start).localeCompare(String(b.entry.start)) })
  }
  // The last hide, for a short-lived "Undo" in whichever view did it.
  property var lastHidden: null
  readonly property bool hasRemote: {
    for (var i = 0; i < calendars.length; i++) if (isRemote(calendars[i].id)) return true
    return false
  }

  property bool ready: false
  // False when the file exists but could not be parsed: we refuse to write
  // rather than replace someone's data with an empty calendar.
  property bool writable: true
  property string problem: ""
  property string _lastWritten: ""
  // Every text we wrote recently. A change notice for one of our own earlier
  // writes can arrive after a later save, and reading the file at that
  // moment returns the older text; treating that as an outside edit would
  // roll memory back and the next save would erase the newer change. Only
  // text that is not ours counts as an outside edit.
  property var _ownWrites: []
  // Writes in flight. Overlapping saves each report back, so this counts
  // rather than flags.
  property int _pendingSaves: 0
  readonly property bool _savePending: _pendingSaves > 0
  property real _saveStartedAt: 0

  // ---- Sync helper state
  property var _queue: []
  property var _job: null
  readonly property bool busy: _job !== null || _queue.length > 0
  property bool syncing: false
  property real lastSyncAt: 0

  // ---- Theme palette. Keyed by colors.toml role (blue, bright_red, ...).
  property var palette: ({})
  readonly property var suggestions: Palette.suggestions(palette)
  readonly property string themeFallback: String(Color.accent)

  function colorFor(spec) { return Palette.resolve(root.palette, spec, root.themeFallback) }

  function calendarById(id) {
    for (var i = 0; i < calendars.length; i++) if (calendars[i].id === id) return calendars[i]
    return null
  }

  function accountById(id) {
    for (var i = 0; i < accounts.length; i++) if (accounts[i].id === id) return accounts[i]
    return null
  }

  function sourceType(id) {
    var cal = calendarById(id)
    return cal && cal.source && cal.source.type ? cal.source.type : "local"
  }

  function isRemote(id) { var t = sourceType(id); return t === "ics" || t === "caldav" }

  // Can events be created/edited in this calendar from here?
  function calendarWritable(id) {
    var cal = calendarById(id)
    if (!cal) return false
    var t = sourceType(id)
    if (t === "local") return root.writable
    if (t === "caldav") return !(cal.source && cal.source.readOnly)
    return false
  }

  function eventEditable(ev) {
    if (!ev) return false
    if (ev.taskRef) return !!ev.taskEditable && !!root.taskHandler
    if (ev.readOnly) return false
    return calendarWritable(ev.calendarId)
  }

  // The stored record of a local series an occurrence belongs to.
  function localSeries(occ) {
    if (!occ || !occ.recurring || sourceType(occ.calendarId) !== "local") return null
    for (var i = 0; i < events.length; i++) if (events[i].uid === occ.sourceUid) return events[i]
    return null
  }

  // Older remote.json files carried the status inline; use it until the
  // helper has written remote-status.json.
  function syncStatus(id) { return remoteStatus[id] || remote[id] || null }

  function providerName(p) {
    return ({ icloud: "iCloud", fastmail: "Fastmail", nextcloud: "Nextcloud", caldav: "CalDAV" })[p] || "CalDAV"
  }

  function sourceLabel(id) {
    var cal = calendarById(id)
    if (!cal || !cal.source) return "On this computer"
    if (cal.source.type === "ics") return (cal.source.label || "Subscribed link") + " link · read-only"
    if (cal.source.type === "caldav") {
      var acc = accountById(cal.source.accountId)
      var who = acc ? (providerName(acc.provider) + " · " + acc.username) : "CalDAV"
      return who + (cal.source.readOnly ? " · read-only" : "")
    }
    return "On this computer"
  }

  function ago(seconds) {
    if (!seconds) return "never"
    var mins = Math.round((Date.now() / 1000 - seconds) / 60)
    if (mins < 1) return "just now"
    if (mins < 60) return mins + " min ago"
    var hours = Math.round(mins / 60)
    if (hours < 48) return hours + " h ago"
    return Math.round(hours / 24) + " days ago"
  }

  function syncLine(calId) {
    if (!isRemote(calId)) return ""
    var st = syncStatus(calId)
    if (!st) return root.syncing ? "Syncing…" : "Not synced yet"
    if (st.error) return "⚠ " + st.error
    return "Synced " + ago(st.syncedAt)
  }

  function calendarColor(id) {
    var cal = calendarById(id) || (String(id).indexOf("tasks:") === 0 ? taskCalendarById(id) : null)
    return cal ? colorFor(cal.color) : themeFallback
  }

  function suggestedColor(extraUsed) {
    var used = []
    for (var i = 0; i < calendars.length; i++) used.push(calendars[i].color)
    return Palette.nextSuggestion(root.palette, used.concat(extraUsed || []))
  }

  // ---- Persistence
  function apply(raw) {
    if (root.ready && (raw === root._lastWritten || root._ownWrites.indexOf(raw) !== -1)) return
    var parsed
    try {
      parsed = JSON.parse(raw)
    } catch (e) {
      root.writable = false
      root.problem = "calendar.json is not valid JSON; leaving it alone until it is fixed"
      console.warn("[calendar] " + root.problem + ": " + e)
      root.ready = true
      return
    }
    var data = Events.normalize(parsed)
    var rest = {}
    for (var k in data) if (k !== "calendars" && k !== "events" && k !== "version" && k !== "accounts" && k !== "hidden" && k !== "addressBooks") rest[k] = data[k]
    root.extra = rest
    root.accounts = Array.isArray(data.accounts) ? data.accounts : []
    root.addressBooks = Array.isArray(data.addressBooks) ? data.addressBooks.filter(function(b) { return b && b.id && b.url }) : []
    root.hidden = Array.isArray(data.hidden) ? data.hidden.filter(function(h) { return h && h.calendarId && (h.uid || h.sourceUid) }) : []
    root.calendars = data.calendars
    root.events = data.events
    root.writable = true
    root.problem = ""
    var first = !root.ready
    root.ready = true
    if (first) {
      var pending = root._pendingPrefs
      root._pendingPrefs = {}
      for (var pk in pending) setPref(pk, pending[pk])
    }
    if (first && root.hasRemote) Qt.callLater(function() { if (!root.syncedWithin(120)) root.syncAll() })
    if (first && root.addressBooks.length) Qt.callLater(function() { if (!root.contactsSyncedWithin(120)) root.syncContacts() })
  }

  function save() {
    // Never before the file has been read: an empty store must not replace it.
    if (!root.writable || !root.ready) return false
    var out = { version: 1 }
    for (var k in root.extra) out[k] = root.extra[k]
    out.accounts = root.accounts
    if (root.addressBooks.length) out.addressBooks = root.addressBooks
    out.calendars = root.calendars
    out.events = root.events
    out.hidden = root.hidden
    var text = JSON.stringify(out, null, 2) + "\n"
    if (text === root._lastWritten) return true
    backupBeforeWrite()
    root._lastWritten = text
    root._ownWrites = root._ownWrites.concat([text]).slice(-20)
    root._pendingSaves = root._pendingSaves + 1
    root._saveStartedAt = Date.now()
    dataFile.setText(text)
    return true
  }

  // ---- Backups. Before a write, at most once a minute, the file as it is
  // on disk is copied to backups/; the newest 60 copies are kept.
  readonly property string backupDir: dataDir + "/backups"
  property real _lastBackupAt: 0

  function backupBeforeWrite() {
    if (!root.ready || Date.now() - root._lastBackupAt < 60000 || backupProc.running) return
    root._lastBackupAt = Date.now()
    backupProc.command = ["sh", "-c",
      'umask 077; mkdir -p "$2" && [ -s "$1" ] && cp "$1" "$2/calendar-$(date +%Y%m%d-%H%M%S).json"; '
      + 'ls -1t "$2"/calendar-*.json 2>/dev/null | tail -n +61 | while read -r f; do rm -f -- "$f"; done',
      "sh", root.dataPath, root.backupDir]
    backupProc.running = true
  }

  Process { id: backupProc }

  function seed() {
    root.calendars = [{ id: Events.newId("cal"), name: "Personal", color: "theme:accent", visible: true, source: { type: "local" } }]
    root.events = []
    root.accounts = []
    root.hidden = []
    root.extra = {}
    root.writable = true
    root.ready = true
    save()
  }

  function applyRemote(raw) {
    try {
      var data = JSON.parse(raw)
      root.remote = data && data.calendars ? data.calendars : {}
    } catch (e) {
      console.warn("[calendar] remote.json unreadable: " + e)
    }
  }

  function applyStatus(raw) {
    try {
      var data = JSON.parse(raw)
      root.remoteStatus = data && data.calendars ? data.calendars : {}
    } catch (e) {
      console.warn("[calendar] remote-status.json unreadable: " + e)
    }
  }

  // ---- Helper job queue. One helper at a time; jobs wait for any pending
  // calendar.json write so the helper never reads a stale config.
  function runHelper(args, input, callback) {
    root._queue = root._queue.concat([{ args: args, input: input, callback: callback }])
    Qt.callLater(root._pump)
  }

  function _pump() {
    if (root._job || root._queue.length === 0) return
    // Wait for calendar.json to land, but never forever: a write that never
    // reports back must not wedge every later sync.
    if (root._savePending && Date.now() - root._saveStartedAt < 3000) { pumpRetry.restart(); return }
    if (root._savePending) root._pendingSaves = 0   // a write that never reported back
    var job = root._queue[0]
    root._queue = root._queue.slice(1)
    root._job = job
    root.syncing = ["sync", "put", "delete", "copy-series"].indexOf(job.args[0]) !== -1
    helper.command = ["python3", root.helperPath].concat(job.args)
    helper.running = true
  }

  function _finish(raw) {
    var job = root._job
    var result
    try { result = JSON.parse(String(raw || "").trim().split("\n").pop()) }
    catch (e) { result = { ok: false, error: "Sync helper failed" + (raw ? ": " + String(raw).slice(0, 200) : " (is python3 installed?)") } }
    root._job = null
    root.syncing = false
    // "changed": false means remote.json was left alone: skip re-reading and
    // re-indexing it. The status file always changes.
    var cmd = job ? job.args[0] : ""
    var touchesCache = ["sync", "put", "delete", "forget", "copy-series"].indexOf(cmd) !== -1
    if (["contacts-sync", "contact-put", "contact-delete", "forget"].indexOf(cmd) !== -1) contactsFile.reload()
    if (touchesCache && (!result || result.changed !== false)) remoteFile.reload()
    if (touchesCache) statusFile.reload()
    if (job && job.args[0] === "sync") root.lastSyncAt = Date.now()
    if (job && typeof job.callback === "function") {
      try { job.callback(result) } catch (e) { console.warn("[calendar] callback: " + e) }
    }
    Qt.callLater(root._pump)
  }

  function syncAll(callback) {
    if (root.addressBooks.length) syncContacts()
    if (!root.hasRemote) { root.lastSyncAt = Date.now(); if (callback) callback({ ok: true }); return }
    for (var i = 0; i < root._queue.length; i++)
      if (root._queue[i].args[0] === "sync" && root._queue[i].args.length === 1 && !callback) return
    runHelper(["sync"], null, callback)
  }

  function syncCalendar(id, callback) { runHelper(["sync", id], null, callback) }

  function syncIfStale() {
    if (root.busy) return
    if (root.hasRemote && Date.now() - root.lastSyncAt > 5 * 60000 && !syncedWithin(5 * 60)) syncAll()
    else if (root.addressBooks.length && !contactsSyncedWithin(5 * 60)) syncContacts()
  }

  // The bar plugin and the app both run this store (in separate processes)
  // and share remote-status.json; neither needs to sync if the other just did.
  function syncedWithin(seconds) {
    var newest = 0
    for (var id in root.remoteStatus) {
      var st = root.remoteStatus[id]
      if (st && !st.error && st.syncedAt > newest) newest = st.syncedAt
    }
    return newest > 0 && Date.now() / 1000 - newest < seconds
  }

  // ---- Time zones. QML only knows this machine's zone; other zones come
  // as offset tables from the helper (see Tz.js), fetched on demand.
  property string localZone: ""
  property var zoneTables: ({})
  property var _zonesWanted: ({})

  // null for the machine's own zone (no conversion needed) or an unknown one.
  function zoneTable(name) {
    if (!name || name === root.localZone) return null
    return root.zoneTables[name] || null
  }

  function ensureZones(names) {
    var missing = []
    for (var i = 0; i < (names || []).length; i++) {
      var n = names[i]
      if (n && n !== root.localZone && !root.zoneTables[n] && !root._zonesWanted[n]) missing.push(n)
    }
    if (missing.length === 0 && root.localZone !== "") return
    var wanted = {}
    for (var w in root._zonesWanted) wanted[w] = true
    for (var j = 0; j < missing.length; j++) wanted[missing[j]] = true
    root._zonesWanted = wanted
    runHelper(["zones"], { names: missing }, function(res) {
      if (!res || !res.ok) return
      var next = {}
      for (var k in root.zoneTables) next[k] = root.zoneTables[k]
      for (var z in res.tables) if (z !== res.local) next[z] = res.tables[z]
      root.localZone = res.local || ""
      root.zoneTables = next
    })
  }

  // Zones any event or setting refers to.
  readonly property var zonesInUse: {
    var seen = {}, out = []
    var lists = [events, remoteEvents]
    for (var l = 0; l < lists.length; l++)
      for (var i = 0; i < lists[l].length; i++) {
        var z = lists[l][i].tz
        if (z && !seen[z]) { seen[z] = true; out.push(z) }
      }
    var extraZones = clockZones.concat(secondZone ? [secondZone] : [])
    for (var j = 0; j < extraZones.length; j++) if (!seen[extraZones[j]]) { seen[extraZones[j]] = true; out.push(extraZones[j]) }
    return out
  }

  // World clocks in the sidebar, and the zone shown as a second hour
  // column in week/day views ("" = none).
  readonly property var clockZones: pref("clockZones", [])
  readonly property string secondZone: pref("secondZone", "")

  function addClockZone(z) {
    if (!z || clockZones.indexOf(z) !== -1) return
    setPref("clockZones", clockZones.concat([z]))
  }
  function removeClockZone(z) {
    setPref("clockZones", clockZones.filter(function(x) { return x !== z }))
    if (secondZone === z) setPref("secondZone", "")
  }

  // Every zone name, for pickers (fetched once, on first use).
  property var zoneList: []
  property bool _zoneListRequested: false
  function loadZoneList() {
    if (root._zoneListRequested) return
    root._zoneListRequested = true
    runHelper(["zone-list"], null, function(res) { if (res && res.ok) root.zoneList = res.zones })
  }
  readonly property var zoneOptions: zoneList.map(function(z) { return { value: z, label: z.replace(/_/g, " ") } })
  onZonesInUseChanged: if (root.ready) ensureZones(zonesInUse)
  onReadyChanged: if (root.ready) ensureZones(zonesInUse)

  // ---- UI preferences that are not bar settings (the window's view, size).
  readonly property var prefs: extra && extra.prefs ? extra.prefs : ({})

  function pref(name, fallback) {
    return prefs[name] !== undefined ? prefs[name] : fallback
  }

  // Prefs set before calendar.json has loaded (the app restoring its view
  // at startup) are applied once it has.
  property var _pendingPrefs: ({})

  function setPref(name, value) {
    if (!root.ready) {
      var p = {}
      for (var k0 in root._pendingPrefs) p[k0] = root._pendingPrefs[k0]
      p[name] = value
      root._pendingPrefs = p
      return
    }
    if (prefs[name] === value) return
    var next = {}
    for (var k in prefs) next[k] = prefs[k]
    next[name] = value
    var ex = {}
    for (var e in extra) ex[e] = extra[e]
    ex.prefs = next
    root.extra = ex
    save()
  }

  // ---- Calendar mutations
  function addCalendar(name, color) {
    var cal = { id: Events.newId("cal"), name: name, color: color, visible: true, source: { type: "local" } }
    root.calendars = root.calendars.concat([cal])
    save()
    return cal.id
  }

  function linkLabel(url) {
    var u = String(url).toLowerCase()
    if (u.indexOf("calendar.google.com") !== -1) return "Google"
    if (u.indexOf("outlook.") !== -1 || u.indexOf("office365") !== -1 || u.indexOf("live.com") !== -1) return "Outlook"
    if (u.indexOf("proton.me") !== -1 || u.indexOf("protonmail") !== -1) return "Proton"
    if (u.indexOf("icloud.com") !== -1) return "iCloud"
    if (u.indexOf("fastmail") !== -1) return "Fastmail"
    var m = u.match(/^[a-z]+:\/\/([^\/:]+)/)
    return m ? m[1] : "Subscribed"
  }

  // Private link (Google secret iCal address, Outlook published calendar,
  // Proton share link, iCloud public calendar...). The URL is a credential,
  // so it goes to the keyring and only a label is kept in calendar.json.
  // callback({ ok, error?, warning? })
  function addSubscription(name, url, color, callback) {
    var id = Events.newId("cal")
    var clean = String(url || "").trim()
    runHelper(["set-secret"], { key: "ics:" + id, value: clean, label: "Cart's Tasks and Calendar link: " + name }, function(res) {
      if (!res.ok) { callback(res); return }
      var cal = { id: id, name: name, color: color, visible: true, source: { type: "ics", label: root.linkLabel(clean) } }
      root.calendars = root.calendars.concat([cal])
      root.save()
      root.syncCalendar(id, function(r) {
        var st = r.results && r.results[id]
        callback(st && !st.ok ? { ok: true, warning: st.error } : { ok: true })
      })
    })
  }

  function replaceSubscriptionUrl(id, url, callback) {
    var cal = calendarById(id)
    var clean = String(url || "").trim()
    runHelper(["set-secret"], { key: "ics:" + id, value: clean, label: "Cart's Tasks and Calendar link: " + (cal ? cal.name : id) }, function(res) {
      if (!res.ok) { callback(res); return }
      var src = {}
      for (var k in cal.source) src[k] = cal.source[k]
      src.label = root.linkLabel(clean)
      root.updateCalendar(id, { source: src })
      root.syncCalendar(id, callback)
    })
  }

  // Step 1 of adding an account: sign in and list calendars. The helper
  // stores the password in the keyring only if sign-in succeeds.
  function discoverAccount(form, callback) {
    var accountId = form.accountId || Events.newId("acc")
    runHelper(["discover"], {
      provider: form.provider, server: form.server, username: form.username,
      password: form.password, accountId: accountId
    }, function(res) {
      res.accountId = accountId
      callback(res)
    })
  }

  // Step 2: keep the account and the calendars the user ticked. Each gets a
  // distinct theme color (the server's own color is kept for reference).
  function addAccountCalendars(accountId, provider, server, username, picks) {
    if (!accountById(accountId))
      root.accounts = root.accounts.concat([{ id: accountId, provider: provider, server: server, username: username }])
    var used = []
    var added = []
    var existing = {}
    for (var i = 0; i < calendars.length; i++)
      if (calendars[i].source && calendars[i].source.url) existing[calendars[i].source.url] = true
    for (var j = 0; j < picks.length; j++) {
      var p = picks[j]
      if (existing[p.url]) continue
      var color = suggestedColor(used)
      used.push(color)
      added.push({
        id: Events.newId("cal"), name: p.name, color: color, visible: true,
        source: { type: "caldav", accountId: accountId, url: p.url, readOnly: !!p.readOnly, serverColor: p.color || "" }
      })
    }
    root.calendars = root.calendars.concat(added)
    save()
    syncAll()
    return added.length
  }

  // ---- Accounts are shared by calendars, address books and task lists
  // (tasks.json, read here only for which accounts its lists use).
  property var taskAccountIds: []
  function applyTasksFile(raw) {
    try {
      var d = JSON.parse(raw)
      var ids = []
      ;(d && Array.isArray(d.lists) ? d.lists : []).forEach(function(l) {
        var a = l && l.source && l.source.accountId
        if (a && ids.indexOf(a) === -1) ids.push(a)
      })
      root.taskAccountIds = ids
    } catch (e) { /* keep the last good copy */ }
  }
  // taskIds: the task lists' account ids when the caller knows better than
  // tasks.json on disk (a task store that has not saved yet).
  function accountInUse(accId, taskIds) {
    return root.calendars.some(function(c) { return c.source && c.source.accountId === accId })
      || root.addressBooks.some(function(b) { return b.accountId === accId })
      || (taskIds || root.taskAccountIds).indexOf(accId) !== -1
  }
  // Add an account record (no secret: the helper stored it on sign-in).
  function ensureAccount(accountId, acc) {
    if (!accountId || accountById(accountId) || !acc) return
    root.accounts = root.accounts.concat([{ id: accountId, provider: acc.provider || "caldav", server: acc.server || "", username: acc.username || "" }])
    save()
  }
  // Drop an account nothing uses any more, with its keyring password.
  function releaseAccount(accId, taskIds) {
    if (!accId || !accountById(accId) || accountInUse(accId, taskIds)) return
    root.accounts = root.accounts.filter(function(a) { return a.id !== accId })
    save()
    runHelper(["forget"], { calendarIds: [], secretKeys: ["account:" + accId] }, null)
  }

  // Sign-in succeeded but the user backed out: drop the stored password.
  function abandonAccount(accountId) {
    if (accountById(accountId)) return
    runHelper(["forget"], { calendarIds: [], secretKeys: ["account:" + accountId] }, null)
  }

  function updateCalendar(id, changes) {
    var next = []
    for (var i = 0; i < calendars.length; i++) {
      var c = calendars[i]
      if (c.id === id) {
        var copy = {}
        for (var k in c) copy[k] = c[k]
        for (var j in changes) copy[j] = changes[j]
        c = copy
      }
      next.push(c)
    }
    root.calendars = next
    save()
  }

  function toggleCalendar(id) {
    var cal = calendarById(id)
    if (cal) updateCalendar(id, { visible: cal.visible === false })
  }

  // Removing a remote calendar only unsubscribes here; nothing is deleted on
  // the server. The last calendar of an account takes the account (and its
  // keyring password) with it.
  function removeCalendar(id) {
    var cal = calendarById(id)
    var type = sourceType(id)
    var secrets = []
    if (type === "ics") secrets.push("ics:" + id)
    root.calendars = root.calendars.filter(function(c) { return c.id !== id })
    root.events = root.events.filter(function(e) { return e.calendarId !== id })
    root.hidden = root.hidden.filter(function(h) { return h.calendarId !== id })
    if (type === "caldav") {
      var accId = cal.source.accountId
      if (!accountInUse(accId)) {
        root.accounts = root.accounts.filter(function(a) { return a.id !== accId })
        secrets.push("account:" + accId)
      }
    }
    save()
    if (type !== "local") runHelper(["forget"], { calendarIds: [id], secretKeys: secrets }, null)
  }

  function eventCount(calendarId) {
    var n = 0
    var list = allEvents
    for (var i = 0; i < list.length; i++) if (list[i].calendarId === calendarId) n++
    return n
  }

  // ---- Hiding synced events
  function canHide(ev) { return !!ev && isRemote(ev.calendarId) }

  function hideEvent(ev, series) {
    if (!canHide(ev)) return
    var entry = Events.hideEntry(ev, series, new Date().toISOString())
    var key = Events.hiddenKey(entry)
    // Hiding a whole series supersedes hidden single occurrences of it.
    var kept = root.hidden.filter(function(h) {
      if (Events.hiddenKey(h) === key) return false
      return !(series && !h.series && h.calendarId === entry.calendarId && h.sourceUid === entry.sourceUid)
    })
    root.hidden = kept.concat([entry])
    root.lastHidden = { key: key, title: entry.title, series: !!series }
    undoTimer.restart()
    save()
  }

  function unhide(key) {
    root.hidden = root.hidden.filter(function(h) { return Events.hiddenKey(h) !== key })
    if (root.lastHidden && root.lastHidden.key === key) root.lastHidden = null
    save()
  }

  function undoHide() { if (root.lastHidden) unhide(root.lastHidden.key) }

  // Entries whose event is gone from the source (cancelled, deleted).
  function clearGoneHidden() {
    var present = Events.presentKeys(rawEvents)
    root.hidden = root.hidden.filter(function(h) { return !!present[Events.hiddenKey(h)] })
    save()
  }

  Timer {
    id: undoTimer
    interval: 10000
    onTriggered: root.lastHidden = null
  }

  // ---- Local event mutations
  function upsertEvent(ev) {
    var next = []
    var replaced = false
    for (var i = 0; i < events.length; i++) {
      if (events[i].uid === ev.uid) { next.push(ev); replaced = true }
      else next.push(events[i])
    }
    if (!replaced) next.push(ev)
    root.events = next
    save()
  }

  function removeEvent(uid) {
    root.events = root.events.filter(function(e) { return e.uid !== uid })
    save()
  }

  function _stripRemote(ev) {
    var out = {}
    for (var k in ev) if (k !== "href" && k !== "etag" && k !== "sourceUid" && k !== "readOnly" && k !== "recurring" && k !== "recurrenceId") out[k] = ev[k]
    return out
  }

  // Occurrence fields only (what a series edit takes from the editor).
  function _occurrencePart(ev) {
    var out = _stripRemote(ev)
    delete out.uid; delete out.exdates; delete out.overrides
    return out
  }

  function _replaceLocal(uid, records) {
    var next = []
    var placed = false
    for (var i = 0; i < events.length; i++) {
      if (events[i].uid === uid) {
        if (!placed) { next = next.concat(records); placed = true }
      } else next.push(events[i])
    }
    if (!placed) next = next.concat(records)
    root.events = next
    save()
  }

  function _tables() { return function(z) { return root.zoneTable(z) } }

  // Save a validated event wherever its calendar lives, moving it between
  // backends when its calendar changed. `original` is the event as it was
  // before editing (null for new). For an occurrence of a repeating event,
  // `scope` says what changes: "this", "following" or "all".
  // callback(errorString or "")
  function saveEvent(ev, original, callback, scope) {
    var done = callback || function() {}
    if (original && original.recurring) { _saveOccurrence(ev, original, scope, done); return }
    var targetType = sourceType(ev.calendarId)
    var origType = original ? sourceType(original.calendarId) : ""
    var sameCalendar = !!original && original.calendarId === ev.calendarId

    if (targetType === "local") {
      var local = _stripRemote(ev)
      if (origType === "caldav") {
        local.uid = Events.newId("ev")
        runHelper(["delete"], { calendarId: original.calendarId, event: original }, function(res) {
          if (!res.ok) { done(res.error); return }
          root.upsertEvent(local)
          done("")
        })
        return
      }
      upsertEvent(local)
      done("")
      return
    }

    if (targetType !== "caldav" || !calendarWritable(ev.calendarId)) { done("This calendar is read-only"); return }
    var payload = sameCalendar && origType === "caldav" ? ev : _stripRemote(ev)
    runHelper(["put"], { calendarId: ev.calendarId, event: payload }, function(res) {
      if (!res.ok) { done(res.error); return }
      if (original && !sameCalendar) {
        if (origType === "local") { root.removeEvent(original.uid); done(""); return }
        if (origType === "caldav") {
          root.runHelper(["delete"], { calendarId: original.calendarId, event: original }, function(r2) {
            done(r2.ok ? "" : "Copied, but could not remove the original: " + r2.error)
          })
          return
        }
      }
      done("")
    })
  }

  function _saveOccurrence(ev, original, scope, done) {
    if (["this", "following", "all"].indexOf(scope) === -1) { done("Choose which events to change"); return }
    var fromType = sourceType(original.calendarId), toType = sourceType(ev.calendarId)
    var moving = ev.calendarId !== original.calendarId
    if (moving && scope !== "all") { done("Moving a repeating event to another calendar moves the whole series"); return }
    if (!calendarWritable(ev.calendarId) || !calendarWritable(original.calendarId)) { done("This calendar is read-only"); return }
    var key = original.recurrenceId
    var edited = _occurrencePart(ev)
    edited.updated = new Date().toISOString()

    if (fromType === "local") {
      var master = localSeries(original)
      if (!master) { done("This repeating event is no longer stored here"); return }
      if (scope === "this") { _replaceLocal(master.uid, [Events.seriesEditThis(master, key, edited)]); done(""); return }
      if (scope === "following") {
        var sp = Events.seriesSplit(master, key, edited, Events.newId("ev"), Recur)
        _replaceLocal(master.uid, sp.old ? [sp.old, sp.fresh] : [sp.fresh])
        done("")
        return
      }
      var all = Events.seriesEditAll(master, key, edited, Recur, Tz, _tables())
      if (toType === "local") { _replaceLocal(master.uid, [all]); done(""); return }
      // Local series to an account: create it there, then drop it here.
      // Changed occurrences stay behind (only exceptions travel).
      var payload = _stripRemote(all)
      delete payload.overrides
      runHelper(["put"], { calendarId: ev.calendarId, event: payload }, function(res) {
        if (!res.ok) { done(res.error); return }
        root.removeEvent(master.uid)
        done("")
      })
      return
    }

    if (fromType !== "caldav") { done("This calendar is read-only"); return }
    // Synced series: edit on the server, then move if asked.
    var occ = {}
    for (var k in edited) occ[k] = edited[k]
    occ.href = original.href; occ.etag = original.etag; occ.recurring = true; occ.recurrenceId = key
    occ.calendarId = original.calendarId
    runHelper(["put"], { calendarId: original.calendarId, event: occ, scope: scope }, function(res) {
      if (!res.ok) { done(res.error); return }
      if (!moving) { done(""); return }
      if (toType === "caldav") {
        root.runHelper(["copy-series"], { calendarId: original.calendarId, event: original, toCalendarId: ev.calendarId }, function(r2) {
          if (!r2.ok) { done("Changed, but could not move it: " + r2.error); return }
          root.runHelper(["delete"], { calendarId: original.calendarId, event: original, scope: "all" }, function(r3) {
            done(r3.ok ? "" : "Copied, but could not remove the original: " + r3.error)
          })
        })
        return
      }
      root.runHelper(["get-series"], { calendarId: original.calendarId, event: original }, function(r2) {
        if (!r2.ok) { done("Changed, but could not move it: " + r2.error); return }
        var local = r2.series
        local.uid = Events.newId("ev")
        local.calendarId = ev.calendarId
        local.created = local.updated = new Date().toISOString()
        root.upsertEvent(local)
        root.runHelper(["delete"], { calendarId: original.calendarId, event: original, scope: "all" }, function(r3) {
          done(r3.ok ? "" : "Copied, but could not remove the original: " + r3.error)
        })
      })
    })
  }

  // scope as in saveEvent, for occurrences of a repeating event.
  function deleteEvent(ev, callback, scope) {
    var done = callback || function() {}
    var t = sourceType(ev.calendarId)
    if (ev.recurring && ["this", "following", "all"].indexOf(scope) === -1) { done("Choose which events to delete"); return }
    if (t === "local") {
      if (!ev.recurring) { removeEvent(ev.uid); done(""); return }
      var master = localSeries(ev)
      if (!master) { done("This repeating event is no longer stored here"); return }
      if (scope === "all") removeEvent(master.uid)
      else if (scope === "this") _replaceLocal(master.uid, [Events.seriesDeleteThis(master, ev.recurrenceId)])
      else {
        var ended = Events.seriesEndBefore(master, ev.recurrenceId, Recur)
        if (ended.master) _replaceLocal(master.uid, [ended.master])
        else removeEvent(master.uid)
      }
      done("")
      return
    }
    if (t !== "caldav") { done("This calendar is read-only"); return }
    runHelper(["delete"], { calendarId: ev.calendarId, event: ev, scope: scope }, function(res) { done(res.ok ? "" : res.error) })
  }

  // Private data dir: event titles/notes and account usernames are nobody
  // else's business. Atomic writes create fresh files, so the directory mode
  // is what actually protects them.
  Process {
    id: mkdir
    command: ["sh", "-c",
      'mkdir -p "$1/backups" && chmod 700 "$1" "$1/backups" && chmod 600 "$1"/*.json "$1"/backups/*.json 2>/dev/null; '
      // First start: bring data over from the separate Calendar / Tasks
      // apps (sync/importer.py; runs once, never changes the old data).
      + 'python3 "$2" >/dev/null 2>&1; true',
      "sh", root.dataDir, root.importerPath]
    running: true
    onExited: {
      tasksFile.path = root.tasksPath
      dataFile.path = root.dataPath
      remoteFile.path = root.remotePath
      statusFile.path = root.statusPath
      contactsFile.path = root.contactsPath
    }
  }

  // Secrets ride in on stdin, never argv (argv is world-readable in /proc).
  Process {
    id: helper
    stdinEnabled: true
    onStarted: {
      var job = root._job
      write((job && job.input ? JSON.stringify(job.input) : "") + "\n")
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root._finish(text)
    }
  }

  Timer {
    id: pumpRetry
    interval: 250
    onTriggered: root._pump()
  }

  Timer {
    interval: Math.max(1, root.syncMinutes) * 60000
    running: root.ready && (root.hasRemote || root.addressBooks.length > 0)
    repeat: true
    onTriggered: if (!root.syncedWithin(root.syncMinutes * 60 * 0.8)) root.syncAll()
  }

  FileView {
    id: dataFile
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.apply(text())
    onFileChanged: reload()
    onLoadFailed: function(error) {
      if (error === FileViewError.FileNotFound) root.seed()
      else {
        root.writable = false
        root.problem = "Could not read " + root.dataPath + " (" + FileViewError.toString(error) + ")"
        root.ready = true
      }
    }
    onSaveFailed: function(error) {
      root._pendingSaves = Math.max(0, root._pendingSaves - 1)
      root.problem = "Could not save calendar (" + FileViewError.toString(error) + ")"
      Qt.callLater(root._pump)
    }
    onSaved: {
      // One notice can cover several quick writes; the file is current now.
      root._pendingSaves = 0
      if (root.problem.indexOf("Could not save") === 0) root.problem = ""
      Qt.callLater(root._pump)
    }
  }

  FileView {
    id: remoteFile
    watchChanges: true
    printErrors: false
    onLoaded: root.applyRemote(text())
    onFileChanged: reload()
  }

  FileView {
    id: statusFile
    watchChanges: true
    printErrors: false
    onLoaded: root.applyStatus(text())
    onFileChanged: reload()
  }

  // ---- Contacts (CardDAV address books; the app's Contacts view).
  // contacts.json is written by the helper only, like remote.json.
  property var contactBooks: ({})          // bookId -> { contacts, syncedAt, error }
  readonly property var contacts: {
    var out = []
    for (var i = 0; i < addressBooks.length; i++) {
      var entry = contactBooks[addressBooks[i].id]
      if (entry && entry.contacts) out = out.concat(entry.contacts)
    }
    return out.sort(Contacts.compare)
  }
  property bool contactsSyncing: false

  function bookById(id) {
    for (var i = 0; i < addressBooks.length; i++) if (addressBooks[i].id === id) return addressBooks[i]
    return null
  }
  function bookStatus(id) { return contactBooks[id] || null }
  // Like syncedWithin, for address books (contacts.json is shared too).
  function contactsSyncedWithin(seconds) {
    for (var i = 0; i < addressBooks.length; i++) {
      var st = contactBooks[addressBooks[i].id]
      if (!st || st.error || !st.syncedAt || Date.now() / 1000 - st.syncedAt >= seconds) return false
    }
    return true
  }
  function bookWritable(id) { var b = bookById(id); return !!b && !b.readOnly }
  function bookCount(id) { var st = contactBooks[id]; return st && st.contacts ? st.contacts.length : 0 }
  readonly property var writableBooks: addressBooks.filter(function(b) { return !b.readOnly })

  function bookLabel(id) {
    var b = bookById(id)
    if (!b) return ""
    var acc = accountById(b.accountId)
    return (acc ? providerName(acc.provider) + " · " + acc.username : "CardDAV") + (b.readOnly ? " · read-only" : "")
  }

  function bookSyncLine(id) {
    var st = contactBooks[id]
    if (!st || (!st.syncedAt && !st.error)) return root.contactsSyncing ? "Syncing…" : "Not synced yet"
    if (st.error) return "⚠ " + st.error
    return "Synced " + ago(st.syncedAt)
  }

  function renameAddressBook(id, name) {
    root.addressBooks = root.addressBooks.map(function(b) {
      if (b.id !== id) return b
      var copy = {}
      for (var k in b) copy[k] = b[k]
      copy.name = name
      return copy
    })
    save()
  }

  function applyContacts(raw) {
    try {
      var data = JSON.parse(raw)
      root.contactBooks = data && data.books ? data.books : {}
    } catch (e) {
      console.warn("[calendar] contacts.json unreadable: " + e)
    }
  }

  function syncContacts(callback) {
    if (!root.addressBooks.length) { if (callback) callback({ ok: true }); return }
    for (var i = 0; i < root._queue.length; i++) if (root._queue[i].args[0] === "contacts-sync" && !callback) return
    root.contactsSyncing = true
    runHelper(["contacts-sync"], null, function(res) {
      root.contactsSyncing = false
      if (callback) callback(res)
    })
  }

  // form: { accountId } for an account already here, or { server,
  // username, password, accountId: new id } for a new one.
  function discoverBooks(form, callback) {
    var accountId = form.accountId || Events.newId("acc")
    var input = {}
    for (var k in form) input[k] = form[k]
    input.accountId = accountId
    runHelper(["contacts-discover"], input, function(res) {
      res.accountId = accountId
      callback(res)
    })
  }

  function addAddressBooks(accountId, newAccount, picks) {
    if (newAccount && !accountById(accountId))
      root.accounts = root.accounts.concat([{ id: accountId, provider: newAccount.provider || "caldav", server: newAccount.server, username: newAccount.username }])
    var have = {}
    for (var i = 0; i < addressBooks.length; i++) have[addressBooks[i].url] = true
    var added = picks.filter(function(p) { return !have[p.url] }).map(function(p) {
      return { id: Events.newId("ab"), name: p.name, accountId: accountId, url: p.url, readOnly: !!p.readOnly }
    })
    root.addressBooks = root.addressBooks.concat(added)
    save()
    syncContacts()
    return added.length
  }

  // Only unsubscribes here; nothing is deleted on the server.
  function removeAddressBook(id) {
    var book = bookById(id)
    if (!book) return
    root.addressBooks = root.addressBooks.filter(function(b) { return b.id !== id })
    var secrets = []
    if (!accountInUse(book.accountId)) {
      root.accounts = root.accounts.filter(function(a) { return a.id !== book.accountId })
      secrets.push("account:" + book.accountId)
    }
    save()
    runHelper(["forget"], { calendarIds: [], secretKeys: secrets, bookIds: [id] }, null)
  }

  // callback(errorString or "", savedContact)
  function saveContact(contact, callback) {
    var done = callback || function() {}
    if (!bookWritable(contact.bookId)) { done("This address book is read-only"); return }
    runHelper(["contact-put"], { bookId: contact.bookId, contact: contact }, function(res) {
      done(res.ok ? "" : res.error, res.contact || null)
    })
  }

  function deleteContact(contact, callback) {
    var done = callback || function() {}
    runHelper(["contact-delete"], { bookId: contact.bookId, contact: contact }, function(res) { done(res.ok ? "" : res.error) })
  }

  // Moving between address books: create in the new one, then delete.
  // `contact` is the record to write (edits included) with the bookId,
  // href and etag it has now.
  function moveContact(contact, toBookId, callback) {
    var done = callback || function() {}
    var copy = {}
    for (var k in contact) if (k !== "href" && k !== "etag" && k !== "uid") copy[k] = contact[k]
    copy.bookId = toBookId
    saveContact(copy, function(err, saved) {
      if (err) { done(err); return }
      root.deleteContact(contact, function(err2) { done(err2 ? "Copied, but could not remove the original: " + err2 : "", saved) })
    })
  }

  FileView {
    id: tasksFile
    watchChanges: true
    printErrors: false
    onLoaded: root.applyTasksFile(text())
    onFileChanged: reload()
  }

  FileView {
    id: contactsFile
    watchChanges: true
    printErrors: false
    onLoaded: root.applyContacts(text())
    onFileChanged: reload()
  }

  // ---- Theme tracking. omarchy-theme-set swaps the theme directory and then
  // pushes the new palette into the running shell over IPC, which lands on
  // the Color singleton. Any of its base colors changing is our cue to
  // re-read colors.toml for the full named palette (Color only keeps four).
  FileView {
    id: paletteFile
    path: Color.currentThemePath + "/colors.toml"
    watchChanges: false
    printErrors: false
    onLoaded: root.palette = Palette.parseColorsToml(text())
  }

  Timer {
    id: paletteReload
    interval: 120
    onTriggered: paletteFile.reload()
  }

  Connections {
    target: Color
    function onAccentChanged() { paletteReload.restart() }
    function onForegroundChanged() { paletteReload.restart() }
    function onBackgroundChanged() { paletteReload.restart() }
    function onUrgentChanged() { paletteReload.restart() }
  }

  // Belt and braces for theme changes that do not move any of Color's four
  // base colors: theme.name is rewritten on every `omarchy theme set`.
  FileView {
    path: Color.stateHome + "/omarchy/current/theme.name"
    watchChanges: true
    printErrors: false
    onFileChanged: { reload(); paletteReload.restart() }
  }
}
