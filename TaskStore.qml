import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Tasks.js" as Tasks
import "Palette.js" as Palette
import "Recur.js" as Recur

// Everything Tasks mode persists, the synced-task cache, the task sync helper
// and the theme palette.
//
//   ~/.local/share/carts/tasks.json          task lists, local tasks, task prefs (written here)
//   ~/.local/share/carts/tasks-remote.json   tasks from CalDAV lists (sync/tasksync.py)
//   ~/.local/share/carts/tasks-status.json   last sync / error per list (sync/tasksync.py)
//
// Accounts are the calendar store's (calendar.json), shared with calendars
// and address books: set `calendarStore`. Passwords go from the form to the
// keyring through the helper's stdin, never into a file or onto a command
// line.
Item {
  id: root
  visible: false

  readonly property string home: Quickshell.env("HOME")
  readonly property string dataHome: Quickshell.env("XDG_DATA_HOME") || (home + "/.local/share")
  readonly property string dataDir: dataHome + "/carts"
  readonly property string dataPath: dataDir + "/tasks.json"
  readonly property string remotePath: dataDir + "/tasks-remote.json"
  readonly property string statusPath: dataDir + "/tasks-status.json"
  readonly property string helperPath: decodeURIComponent(String(Qt.resolvedUrl("sync/tasksync.py")).replace(/^file:\/\//, ""))
  readonly property string importerPath: decodeURIComponent(String(Qt.resolvedUrl("sync/importer.py")).replace(/^file:\/\//, ""))

  // The calendar Store: owner of the accounts.
  property var calendarStore: null

  property int syncMinutes: 10

  property var lists: []
  readonly property var accounts: calendarStore ? calendarStore.accounts : []
  property var tasks: []            // local tasks only
  property var extra: ({})          // unknown top-level keys ride along on save

  property var remote: ({})         // listId -> { tasks, ctag }
  property var remoteStatus: ({})   // listId -> { syncedAt, error, failedAt }

  // The day, for views and recurrence ("today" moves at midnight).
  property string todayKey: Tasks.keyOf(new Date())
  function nowStamp() { return Tasks.stampOf(new Date(), false) }

  // Edits on their way to a server, shown at once ("listId|uid" -> record,
  // or null for a task being deleted).
  property var pending: ({})
  function _setPending(t, rec) {
    var next = {}
    for (var k in root.pending) next[k] = root.pending[k]
    next[t.listId + "|" + t.uid] = rec
    root.pending = next
  }
  function _clearPending(t) {
    var next = {}
    for (var k in root.pending) if (k !== t.listId + "|" + t.uid) next[k] = root.pending[k]
    root.pending = next
  }
  // A write that worked stays shown until the helper's cache file has been
  // read back (otherwise the task blinks to its old state in between).
  property var _settling: []
  function _settle(t) {
    root._settling = root._settling.concat([t])
    settleTimer.restart()
  }
  function _settled() {
    var list = root._settling
    root._settling = []
    list.forEach(function(t) { root._clearPending(t) })
  }
  Timer { id: settleTimer; interval: 3000; onTriggered: root._settled() }

  readonly property var remoteTasks: {
    var out = []
    for (var i = 0; i < lists.length; i++) {
      var entry = remote[lists[i].id]
      if (entry && entry.tasks && lists[i].source && lists[i].source.type === "caldav") out = out.concat(entry.tasks)
    }
    return out
  }

  // Every task, with pending edits applied and repeating tasks shown at
  // their current occurrence.
  readonly property var allTasks: {
    var all = tasks.concat(remoteTasks)
    var p = root.pending, seen = {}, out = []
    for (var i = 0; i < all.length; i++) {
      var k = all[i].listId + "|" + all[i].uid
      seen[k] = true
      var t = p.hasOwnProperty(k) ? p[k] : all[i]
      if (t) out.push(Tasks.effective(t, Recur))
    }
    for (var pk in p) if (!seen[pk] && p[pk]) out.push(p[pk])   // created, not synced back yet
    return out
  }
  readonly property var counts: Tasks.counts(allTasks, lists, todayKey)

  function taskByKey(listId, uid) {
    for (var i = 0; i < allTasks.length; i++) if (allTasks[i].uid === uid && allTasks[i].listId === listId) return allTasks[i]
    return null
  }
  function _stored(listId, uid) {
    var src = sourceType(listId) === "local" ? root.tasks : ((root.remote[listId] || {}).tasks || [])
    for (var i = 0; i < src.length; i++) if (src[i].uid === uid && src[i].listId === listId) return src[i]
    return null
  }

  property bool ready: false
  property bool writable: true
  property string problem: ""
  property string _lastWritten: ""
  property var _ownWrites: []
  property int _pendingSaves: 0
  readonly property bool _savePending: _pendingSaves > 0
  property real _saveStartedAt: 0

  // ---- Helper state
  property var _queue: []
  property var _job: null
  readonly property bool busy: _job !== null || _queue.length > 0
  property bool syncing: false
  property real lastSyncAt: 0

  // ---- Palette
  property var palette: ({})
  readonly property var suggestions: Palette.suggestions(palette)
  readonly property string themeFallback: String(Color.accent)
  function colorFor(spec) { return Palette.resolve(root.palette, spec, root.themeFallback) }

  // ---- Lists
  function listById(id) {
    for (var i = 0; i < lists.length; i++) if (lists[i].id === id) return lists[i]
    return null
  }
  function accountById(id) {
    for (var i = 0; i < accounts.length; i++) if (accounts[i].id === id) return accounts[i]
    return null
  }
  function sourceType(id) {
    var l = listById(id)
    return l && l.source && l.source.type ? l.source.type : "local"
  }
  function isRemote(id) { return sourceType(id) === "caldav" }
  function listWritable(id) {
    var l = listById(id)
    if (!l) return false
    if (sourceType(id) === "local") return root.writable
    return !(l.source && l.source.readOnly)
  }
  function taskEditable(t) { return !!t && !t.readOnly && listWritable(t.listId) }
  readonly property var writableLists: lists.filter(function(l) { return root.listWritable(l.id) })
  readonly property bool hasRemote: lists.some(function(l) { return l.source && l.source.type === "caldav" })

  function listColor(id) { var l = listById(id); return l ? colorFor(l.color) : themeFallback }
  function listName(id) { var l = listById(id); return l ? l.name : "" }

  function providerName(p) {
    return ({ icloud: "iCloud", fastmail: "Fastmail", nextcloud: "Nextcloud", caldav: "CalDAV" })[p] || "CalDAV"
  }
  function hostOf(server) { return String(server || "").replace(/^[a-z]+:\/\//i, "").split(/[\/:]/)[0] }
  function accountLabel(acc) {
    if (!acc) return "CalDAV"
    var host = hostOf(acc.server)
    return providerName(acc.provider) + " · " + acc.username
      + (host && acc.provider !== "icloud" && acc.provider !== "fastmail" ? " · " + host.split(".")[0] : "")
  }
  function sourceLabel(id) {
    var l = listById(id)
    if (!l || !l.source || l.source.type !== "caldav") return "On this computer"
    return accountLabel(accountById(l.source.accountId)) + (l.source.readOnly ? " · read-only" : "")
  }
  function syncStatus(id) { return remoteStatus[id] || null }
  function ago(seconds) {
    if (!seconds) return "never"
    var mins = Math.round((Date.now() / 1000 - seconds) / 60)
    if (mins < 1) return "just now"
    if (mins < 60) return mins + " min ago"
    var hours = Math.round(mins / 60)
    if (hours < 48) return hours + " h ago"
    return Math.round(hours / 24) + " days ago"
  }
  function syncLine(id) {
    if (!isRemote(id)) return ""
    var st = syncStatus(id)
    if (!st) return root.syncing ? "Syncing…" : "Not synced yet"
    if (st.error) return "⚠ " + st.error
    return "Synced " + ago(st.syncedAt)
  }
  function suggestedColor(extraUsed) {
    var used = lists.map(function(l) { return l.color })
    return Palette.nextSuggestion(root.palette, used.concat(extraUsed || []))
  }

  // The list new tasks go to when no list is chosen (smart views).
  readonly property string defaultListId: {
    var want = pref("defaultList", "")
    if (want && listWritable(want)) return want
    for (var i = 0; i < lists.length; i++) if (lists[i].visible !== false && listWritable(lists[i].id)) return lists[i].id
    return writableLists.length ? writableLists[0].id : ""
  }
  function listByName(name) {
    var n = String(name || "").toLowerCase()
    if (!n) return null
    for (var i = 0; i < lists.length; i++) if (String(lists[i].name).toLowerCase() === n) return lists[i]
    for (var j = 0; j < lists.length; j++) if (String(lists[j].name).toLowerCase().indexOf(n) === 0) return lists[j]
    return null
  }

  // ---- Persistence
  function apply(raw) {
    if (root.ready && (raw === root._lastWritten || root._ownWrites.indexOf(raw) !== -1)) return
    var parsed
    try { parsed = JSON.parse(raw) }
    catch (e) {
      root.writable = false
      root.problem = "tasks.json is not valid JSON; leaving it alone until it is fixed"
      console.warn("[tasks] " + root.problem + ": " + e)
      root.ready = true
      return
    }
    var data = Tasks.normalize(parsed)
    var rest = {}
    for (var k in data) if (["lists", "tasks", "version", "accounts"].indexOf(k) === -1) rest[k] = data[k]
    root.extra = rest
    root.lists = data.lists
    root.tasks = data.tasks
    root.writable = true
    root.problem = ""
    var first = !root.ready
    root.ready = true
    if (first) {
      var pend = root._pendingPrefs
      root._pendingPrefs = {}
      for (var pk in pend) setPref(pk, pend[pk])
      if (root.hasRemote) Qt.callLater(function() { if (!root.syncedWithin(120)) root.syncAll() })
    }
  }

  function save() {
    if (!root.writable || !root.ready) return false
    var out = { version: 1 }
    for (var k in root.extra) out[k] = root.extra[k]
    out.lists = root.lists
    out.tasks = root.tasks
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

  // Before a write, at most once a minute, the file on disk goes to backups/
  // (newest 60 kept).
  readonly property string backupDir: dataDir + "/backups"
  property real _lastBackupAt: 0
  function backupBeforeWrite() {
    if (!root.ready || Date.now() - root._lastBackupAt < 60000 || backupProc.running) return
    root._lastBackupAt = Date.now()
    backupProc.command = ["sh", "-c",
      'umask 077; mkdir -p "$2" && [ -s "$1" ] && cp "$1" "$2/tasks-$(date +%Y%m%d-%H%M%S).json"; '
      + 'ls -1t "$2"/tasks-*.json 2>/dev/null | tail -n +61 | while read -r f; do rm -f -- "$f"; done',
      "sh", root.dataPath, root.backupDir]
    backupProc.running = true
  }
  Process { id: backupProc }

  function seed() {
    root.lists = [{ id: Tasks.newId("list"), name: "Tasks", color: "theme:accent", visible: true, source: { type: "local" } }]
    root.tasks = []
    root.extra = {}
    root.writable = true
    root.ready = true
    save()
  }

  function applyRemote(raw) {
    try { var d = JSON.parse(raw); root.remote = d && d.lists ? d.lists : {} }
    catch (e) { console.warn("[tasks] tasks-remote.json unreadable: " + e) }
    if (root._settling.length) root._settled()
  }
  function applyStatus(raw) {
    try { var d = JSON.parse(raw); root.remoteStatus = d && d.lists ? d.lists : {} }
    catch (e) { console.warn("[tasks] tasks-status.json unreadable: " + e) }
  }

  // ---- Prefs
  readonly property var prefs: extra && extra.prefs ? extra.prefs : ({})
  function pref(name, fallback) { return prefs[name] !== undefined ? prefs[name] : fallback }
  property var _pendingPrefs: ({})
  function setPref(name, value) {
    if (!root.ready) {
      var p = {}
      for (var k0 in root._pendingPrefs) p[k0] = root._pendingPrefs[k0]
      p[name] = value
      root._pendingPrefs = p
      return
    }
    if (JSON.stringify(prefs[name]) === JSON.stringify(value)) return
    var next = {}
    for (var k in prefs) next[k] = prefs[k]
    next[name] = value
    var ex = {}
    for (var e in extra) ex[e] = extra[e]
    ex.prefs = next
    root.extra = ex
    save()
  }
  readonly property bool keepHistory: pref("keepHistory", true)

  // ---- Helper queue (one helper at a time; waits for tasks.json to land)
  function runHelper(args, input, callback) {
    root._queue = root._queue.concat([{ args: args, input: input, callback: callback }])
    Qt.callLater(root._pump)
  }
  function _pump() {
    if (root._job || root._queue.length === 0) return
    // Wait for tasks.json and calendar.json (accounts) to land.
    var calSaving = root.calendarStore && root.calendarStore._savePending && Date.now() - root.calendarStore._saveStartedAt < 3000
    if (calSaving || (root._savePending && Date.now() - root._saveStartedAt < 3000)) { pumpRetry.restart(); return }
    if (root._savePending) root._pendingSaves = 0
    var job = root._queue[0]
    root._queue = root._queue.slice(1)
    root._job = job
    root.syncing = ["sync", "put", "delete"].indexOf(job.args[0]) !== -1
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
    var cmd = job ? job.args[0] : ""
    var touches = ["sync", "put", "delete", "forget"].indexOf(cmd) !== -1
    if (touches && (!result || result.changed !== false)) remoteFile.reload()
    if (touches) statusFile.reload()
    if (cmd === "sync") root.lastSyncAt = Date.now()
    if (job && typeof job.callback === "function") {
      try { job.callback(result) } catch (e) { console.warn("[tasks] callback: " + e) }
    }
    Qt.callLater(root._pump)
  }

  function syncAll(callback) {
    if (!root.hasRemote) { root.lastSyncAt = Date.now(); if (callback) callback({ ok: true }); return }
    for (var i = 0; i < root._queue.length; i++)
      if (root._queue[i].args[0] === "sync" && root._queue[i].args.length === 1 && !callback) return
    runHelper(["sync"], null, callback)
  }
  function syncList(id, callback) { runHelper(["sync", id], null, callback) }
  function syncIfStale() {
    if (!root.busy && root.hasRemote && Date.now() - root.lastSyncAt > 3 * 60000 && !syncedWithin(3 * 60)) syncAll()
  }
  function syncedWithin(seconds) {
    var newest = 0
    for (var id in root.remoteStatus) {
      var st = root.remoteStatus[id]
      if (st && !st.error && st.syncedAt > newest) newest = st.syncedAt
    }
    return newest > 0 && Date.now() / 1000 - newest < seconds
  }

  // ---- List mutations
  function addLocalList(name, color) {
    var l = { id: Tasks.newId("list"), name: name, color: color, visible: true, source: { type: "local" } }
    root.lists = root.lists.concat([l])
    save()
    return l.id
  }

  // form: { accountId } (an account already connected), or { provider,
  // server, username, password } for a new sign-in.
  // callback(res) with res.lists, res.account, res.accountId.
  function discoverLists(form, callback) {
    var input = {}
    for (var k in form) input[k] = form[k]
    if (!input.accountId) input.accountId = Tasks.newId("acc")
    var id = input.accountId
    runHelper(["discover"], input, function(res) { res.accountId = id; callback(res) })
  }

  function _keepAccount(accountId, account) {
    if (accountById(accountId) || !account || !root.calendarStore) return
    root.calendarStore.ensureAccount(accountId, account)
  }

  function addAccountLists(accountId, account, picks) {
    _keepAccount(accountId, account)
    var have = {}
    for (var i = 0; i < lists.length; i++) if (lists[i].source && lists[i].source.url) have[lists[i].source.url] = true
    var used = [], added = []
    picks.forEach(function(p) {
      if (have[p.url]) return
      var color = root.suggestedColor(used)
      used.push(color)
      added.push({ id: Tasks.newId("list"), name: p.name, color: color, visible: true,
                   source: { type: "caldav", accountId: accountId, url: p.url, readOnly: !!p.readOnly, serverColor: p.color || "", mixed: !!p.mixed } })
    })
    root.lists = root.lists.concat(added)
    save()
    if (added.length) syncAll()
    return added.map(function(l) { return l.id })
  }

  // Create a task list on the server (MKCALENDAR) and add it here.
  function makeRemoteList(accountId, account, name, color, callback) {
    _keepAccount(accountId, account)
    save()
    runHelper(["make-list"], { accountId: accountId, name: name, color: /^#/.test(color) ? color : "" }, function(res) {
      if (!res.ok) { callback(res); return }
      var ids = root.addAccountLists(accountId, null, [res.list])
      if (ids.length) root.updateList(ids[0], { color: color || root.lists[root.lists.length - 1].color })
      callback({ ok: true, listId: ids[0] || "" })
    })
  }

  // Sign-in worked but nothing was added: drop the stored password.
  function abandonAccount(accountId) {
    if (accountById(accountId)) return
    runHelper(["forget"], { listIds: [], secretKeys: ["account:" + accountId] }, null)
  }

  function updateList(id, changes) {
    root.lists = root.lists.map(function(l) {
      if (l.id !== id) return l
      var c = Tasks.copy(l)
      for (var k in changes) c[k] = changes[k]
      return c
    })
    save()
  }
  function toggleList(id) { var l = listById(id); if (l) updateList(id, { visible: l.visible === false }) }
  function moveList(id, delta) {
    var i = lists.findIndex(function(l) { return l.id === id })
    var j = i + delta
    if (i < 0 || j < 0 || j >= lists.length) return
    var next = lists.slice()
    var tmp = next[i]; next[i] = next[j]; next[j] = tmp
    root.lists = next
    save()
  }

  // Remote lists are only unsubscribed; nothing is deleted on the server.
  // A local list takes its tasks with it.
  function removeList(id) {
    var l = listById(id)
    if (!l) return
    var type = sourceType(id)
    root.lists = root.lists.filter(function(x) { return x.id !== id })
    root.tasks = root.tasks.filter(function(t) { return t.listId !== id })
    if (pref("defaultList", "") === id) setPref("defaultList", "")
    save()
    if (type === "caldav") {
      runHelper(["forget"], { listIds: [id], secretKeys: [] }, null)
      // The account goes too when nothing else (calendars, address books,
      // other lists) uses it.
      var accId = l.source.accountId
      var stillUsed = root.lists.map(function(x) { return x.source && x.source.accountId }).filter(function(a) { return !!a })
      if (root.calendarStore) root.calendarStore.releaseAccount(accId, stillUsed)
    }
  }

  // ---- Task writes
  function _upsertLocal(t) {
    var next = [], placed = false
    for (var i = 0; i < root.tasks.length; i++) {
      if (root.tasks[i].uid === t.uid && root.tasks[i].listId === t.listId) { next.push(t); placed = true }
      else next.push(root.tasks[i])
    }
    if (!placed) next.push(t)
    root.tasks = next
    save()
  }
  function _removeLocal(t) {
    root.tasks = root.tasks.filter(function(x) { return !(x.uid === t.uid && x.listId === t.listId) })
    save()
  }
  function _plain(t) {
    var out = {}
    for (var k in t) if (["href", "etag", "readOnly", "historyOf"].indexOf(k) === -1) out[k] = t[k]
    return out
  }

  // Write one record where its list lives. callback(error or "", saved record)
  function _put(t, callback) {
    var done = callback || function() {}
    if (!listWritable(t.listId)) { done("This list is read-only"); return }
    if (!isRemote(t.listId)) { _upsertLocal(_plain(t)); done("", t); return }
    _setPending(t, t)
    runHelper(["put"], { listId: t.listId, task: t }, function(res) {
      if (res.ok) root._settle(t)
      else root._clearPending(t)
      done(res.ok ? "" : res.error, res.task || null)
    })
  }
  function _delete(t, callback) {
    var done = callback || function() {}
    if (!listWritable(t.listId)) { done("This list is read-only"); return }
    if (!isRemote(t.listId)) { _removeLocal(t); done(""); return }
    _setPending(t, null)
    runHelper(["delete"], { listId: t.listId, task: t }, function(res) {
      if (res.ok) root._settle(t)
      else root._clearPending(t)
      done(res.ok ? "" : res.error)
    })
  }

  // Save an edited (or new) task. `original` is the task as it was (null
  // for a new one). Changing its list moves it: created there, then removed
  // here. callback(error or "")
  function saveTask(t, original, callback) {
    var done = callback || function() {}
    if (!original || original.listId === t.listId) {
      var rec = original ? t : _plain(t)
      _put(rec, function(err) { done(err) })
      return
    }
    // Subtasks go along (created after their parent, removed before it).
    var subs = Tasks.descendants(root.allTasks, original.uid).filter(function(x) { return x.listId === original.listId }).map(root._now)
    var creates = [_plain(t)].concat(subs.map(function(x) { var c = root._plain(x); c.listId = t.listId; return c }))
    var removes = subs.slice().reverse().concat([original])
    var i = 0, j = 0
    function del(err) {
      if (err) { done("Copied, but could not remove the original: " + err); return }
      if (j >= removes.length) { done(""); return }
      root._delete(removes[j++], del)
    }
    function put(err) {
      if (err) { done(err); return }
      if (i >= creates.length) { del(""); return }
      root._put(creates[i++], put)
    }
    put("")
  }

  // ---- Undo (complete, skip, delete, ...): the last action, for a few seconds.
  // { kind, title, before: [records as they were], created: [records added],
  //   removed: [records deleted] }
  property var lastAction: null
  property string notice: ""
  property bool noticeError: false
  signal failed(string error)
  function flash(text, isError) { root.notice = text; root.noticeError = !!isError; noticeTimer.restart() }
  function _report(err) { if (err) { root.flash(err, true); root.failed(err) } }

  Timer { id: noticeTimer; interval: root.noticeError ? 7000 : 8000; onTriggered: { root.notice = ""; root.lastAction = null } }

  // Completing a parent that still has open subtasks: "ask" (the window
  // shows confirmComplete), "all" or "none".
  readonly property string subtasksWithParent: pref("subtasksWithParent", "ask")
  // Completing the last open subtask completes its parent too.
  readonly property bool autoCompleteParent: pref("autoCompleteParent", false)
  // Top-level tasks with subtasks count as projects (else only marked ones).
  readonly property bool autoProjects: pref("autoProjects", true)
  property var confirmComplete: null        // { task, open: [subtasks] } while asking

  function _now(t) { return root._stored(t.listId, t.uid) || t }

  // Complete or reopen. Repeating tasks move to their next date (and leave a
  // completed copy behind when keepHistory is on); their completed subtasks
  // reopen for the next round. opts.subtasks: "all" | "none" answers the
  // question about open subtasks.
  function toggleComplete(t, callback, opts) {
    var done = callback || function() {}
    opts = opts || {}
    root.confirmComplete = null
    if (!taskEditable(t)) { done("This list is read-only"); return }
    var now = nowStamp()
    if (Tasks.isDone(t)) {
      _apply("reopen", t.title, [Tasks.reopen(t, now)], [], "Reopened \u201c" + t.title + "\u201d", done)
      return
    }
    var repeating = Tasks.isRepeating(t)
    var open = repeating ? [] : Tasks.openDescendants(root.allTasks, t)
    var choice = opts.subtasks || root.subtasksWithParent
    if (open.length && choice === "ask") { root.confirmComplete = { task: t, open: open }; done(""); return }
    var res = Tasks.complete(t, Recur, now, { keepHistory: root.keepHistory })
    var updates = [res.update], creates = res.create ? [res.create] : []
    var extra = []
    if (choice === "all") open.forEach(function(x) { updates.push(Tasks.complete(x, Recur, now, { keepHistory: false }).update) })
    if (repeating && res.next) Tasks.doneDescendants(root.allTasks, t).forEach(function(x) { updates.push(Tasks.reopen(x, now)) })
    if (root.autoCompleteParent && !res.next) {
      var after = root.allTasks.map(function(x) { return x.uid === t.uid && x.listId === t.listId ? res.update : x })
      Tasks.parentsToComplete(after, res.update).forEach(function(p) {
        updates.push(Tasks.complete(p, Recur, now, { keepHistory: false }).update)
        extra.push(p.title)
      })
    }
    var msg = res.next ? "Done \u2014 next: " + Tasks.dateLabel(res.next, root.todayKey, true) : "Completed \u201c" + t.title + "\u201d"
    if (choice === "all" && open.length) msg += " and " + open.length + " subtask" + (open.length > 1 ? "s" : "")
    if (extra.length) msg += " \u2014 also \u201c" + extra.join("\u201d, \u201c") + "\u201d"
    _apply("complete", t.title, updates, creates, msg, done)
  }

  // Write updates and creations in order, remembering the old records for undo.
  function _apply(kind, title, updates, creates, message, done) {
    root.lastAction = { kind: kind, title: title, before: updates.map(root._now), created: creates, removed: [] }
    if (message) root.flash(message)
    var queue = updates.concat(creates)
    var i = 0
    function next(err) {
      if (err) { root._report(err); done(err); return }
      if (i >= queue.length) { done(""); return }
      root._put(queue[i++], next)
    }
    next("")
  }

  // Move a repeating task to its next date without completing it.
  function skipOccurrence(t, callback) {
    var done = callback || function() {}
    if (!taskEditable(t) || !Tasks.isRepeating(t)) { done("Not a repeating task"); return }
    var next = Tasks.advance(t, Recur, "skip", root.todayKey)
    if (!next) { done("This was the last one; complete it instead"); root.flash("This was the last one; complete it instead", true); return }
    var now = nowStamp()
    next.updated = now
    var updates = [next].concat(Tasks.doneDescendants(root.allTasks, t).map(function(x) { return Tasks.reopen(x, now) }))
    _apply("skip", t.title, updates, [], "Skipped \u2014 next: " + Tasks.dateLabel(next.due || next.start, root.todayKey, true), done)
  }

  // Make `t` a subtask of `parentUid` ("" = top level), in the same list.
  function setParent(t, parentUid, callback) {
    var done = callback || function() {}
    if (!taskEditable(t)) { done("This list is read-only"); return }
    if (parentUid && (parentUid === t.uid || Tasks.descendants(root.allTasks, t.uid).some(function(x) { return x.uid === parentUid }))) { done("A task cannot be its own subtask"); return }
    var r = Tasks.copy(t)
    r.parent = parentUid || ""
    if (r.parent) r.project = false
    r.updated = nowStamp()
    if (r.parent) root.setCollapsed(t.listId + "|" + r.parent, false)
    _apply("move", t.title, [r], [], "", function(err) { done(err) })
  }

  // Delete a task and its subtasks.
  function deleteTask(t, callback) {
    var done = callback || function() {}
    if (!taskEditable(t)) { done("This list is read-only"); return }
    var all = [_stored(t.listId, t.uid) || t].concat(Tasks.descendants(root.allTasks, t.uid).filter(function(x) { return x.listId === t.listId }).map(root._now))
    root.lastAction = { kind: "delete", title: t.title, before: [], created: [], removed: all }
    root.flash("Deleted \u201c" + t.title + "\u201d" + (all.length > 1 ? " and " + (all.length - 1) + " subtask" + (all.length > 2 ? "s" : "") : ""))
    var i = 0
    function nextOne(err) {
      if (err) { root._report(err); done(err); return }
      if (i >= all.length) { done(""); return }
      root._delete(all[i++], nextOne)
    }
    nextOne("")
  }

  // Put everything back as it was before the last action.
  function undo() {
    var a = root.lastAction
    if (!a) return
    root.lastAction = null
    root.notice = ""
    var jobs = []
    a.before.forEach(function(b) {
      jobs.push(function(next) {
        // Remote records changed etag with our write: take the current one's.
        var cur = root._stored(b.listId, b.uid)
        var rec = Tasks.copy(b)
        if (cur) { rec.href = cur.href; rec.etag = cur.etag }
        root._put(rec, next)
      })
    })
    a.created.forEach(function(c) { jobs.push(function(next) { root._delete(root._stored(c.listId, c.uid) || c, next) }) })
    a.removed.forEach(function(r) { jobs.push(function(next) { root._put(root._plain(r), next) }) })
    var i = 0
    function run(err) {
      if (err) { root._report(err); return }
      if (i < jobs.length) jobs[i++](run)
    }
    run("")
  }

  // ---- Projects and folded subtasks
  readonly property var projects: Tasks.projects(allTasks, lists, { autoProjects: root.autoProjects })
  readonly property var collapsed: pref("collapsed", ({}))
  function setCollapsed(key, folded) {
    if (!!root.collapsed[key] === !!folded) return
    var next = {}
    for (var k in root.collapsed) if (k !== key) next[k] = true
    if (folded) next[key] = true
    setPref("collapsed", next)
  }
  function toggleCollapsed(key) { setCollapsed(key, !root.collapsed[key]) }

  // An open task by (part of) its title, projects first, for "^Project".
  function findParent(name, listId) {
    var n = String(name || "").toLowerCase()
    if (!n) return null
    var pool = root.projects.map(function(p) { return p.task })
      .concat(root.allTasks.filter(function(t) { return !Tasks.isDone(t) }))
      .filter(function(t) { return !listId || t.listId === listId })
    for (var i = 0; i < pool.length; i++) if (String(pool[i].title).toLowerCase() === n) return pool[i]
    for (var j = 0; j < pool.length; j++) if (String(pool[j].title).toLowerCase().indexOf(n) === 0) return pool[j]
    return null
  }

  // Quick edits from the list.
  function setDue(t, stamp) {
    if (!taskEditable(t)) return
    var r = {}
    for (var k in t) r[k] = t[k]
    if (r.start && r.due && Tasks.dayOf(r.start) > Tasks.dayOf(stamp)) r.start = ""
    r.due = stamp
    if (r.rrule && !stamp) r.rrule = ""
    r.updated = nowStamp()
    _put(r, root._report)
  }
  function postpone(t, days) {
    if (!t.due) { setDue(t, Tasks.addDaysKey(root.todayKey, days)); return }
    var from = Tasks.dayOf(t.due) < root.todayKey ? root.todayKey : Tasks.dayOf(t.due)
    setDue(t, Tasks.addDaysKey(from, days) + String(t.due).substr(10))
  }
  function cyclePriority(t) {
    if (!taskEditable(t)) return
    var order = [0, 9, 5, 1]
    var lvl = Tasks.priorityLevel(t.priority)
    var cur = [0, 1, 5, 9][lvl]
    var r = {}
    for (var k in t) r[k] = t[k]
    r.priority = order[(order.indexOf(cur) + 1) % order.length]
    r.updated = nowStamp()
    _put(r, root._report)
  }

  // Quick add: "Pay rent every month on the 1st #bills !high".
  // defaults: { due, priority } for what the text does not say (adding in
  // Today means due today). -> "" or an error
  function quickAdd(text, listId, parentUid, defaults) {
    var q = Tasks.parseQuick(text, root.todayKey, Recur)
    if (defaults && defaults.due && !q.due) q.due = defaults.due
    if (defaults && defaults.priority && !q.priority) q.priority = defaults.priority
    var target = listId
    if (q.list) { var l = listByName(q.list); if (l && listWritable(l.id)) target = l.id }
    if (q.project) {
      var p = findParent(q.project, "")
      if (!p) return "No project or task called \u201c" + q.project + "\u201d"
      parentUid = p.uid
      target = p.listId
    }
    if (!target || !listWritable(target)) target = root.defaultListId
    if (!target) return "Add a list first"
    if (parentUid && !taskByKey(target, parentUid)) parentUid = ""
    var now = nowStamp()
    var t = { uid: Tasks.newUid(), listId: target, title: q.title, notes: "", status: "NEEDS-ACTION", completed: "", percent: 0,
              priority: q.priority, due: q.due, start: "", rrule: q.rrule, repeatFrom: q.repeatFrom, categories: q.categories,
              parent: parentUid || "", created: now, updated: now }
    if (parentUid) setCollapsed(target + "|" + parentUid, false)
    _put(t, root._report)
    return ""
  }

  Timer {
    interval: 60000
    running: true
    repeat: true
    onTriggered: { var k = Tasks.keyOf(new Date()); if (k !== root.todayKey) root.todayKey = k }
  }

  // ---- Files and processes
  Process {
    id: mkdir
    command: ["sh", "-c", 'mkdir -p "$1/backups" && chmod 700 "$1" "$1/backups" && chmod 600 "$1"/*.json "$1"/backups/*.json 2>/dev/null; '
      + 'python3 "$2" >/dev/null 2>&1; true', "sh", root.dataDir, root.importerPath]
    running: true
    onExited: {
      dataFile.path = root.dataPath
      remoteFile.path = root.remotePath
      statusFile.path = root.statusPath
    }
  }

  Process {
    id: helper
    stdinEnabled: true
    onStarted: { var job = root._job; write((job && job.input ? JSON.stringify(job.input) : "") + "\n") }
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root._finish(text) }
  }

  Timer { id: pumpRetry; interval: 250; onTriggered: root._pump() }

  Timer {
    interval: Math.max(1, root.syncMinutes) * 60000
    running: root.ready && root.hasRemote
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
      else { root.writable = false; root.problem = "Could not read " + root.dataPath + " (" + FileViewError.toString(error) + ")"; root.ready = true }
    }
    onSaveFailed: function(error) {
      root._pendingSaves = Math.max(0, root._pendingSaves - 1)
      root.problem = "Could not save tasks (" + FileViewError.toString(error) + ")"
      Qt.callLater(root._pump)
    }
    onSaved: {
      root._pendingSaves = 0
      if (root.problem.indexOf("Could not save") === 0) root.problem = ""
      Qt.callLater(root._pump)
    }
  }
  FileView { id: remoteFile; watchChanges: true; printErrors: false; onLoaded: root.applyRemote(text()); onFileChanged: reload() }
  FileView { id: statusFile; watchChanges: true; printErrors: false; onLoaded: root.applyStatus(text()); onFileChanged: reload() }

  // ---- Theme palette (see the calendar's Store for why both watchers).
  FileView {
    id: paletteFile
    path: Color.currentThemePath + "/colors.toml"
    watchChanges: false
    printErrors: false
    onLoaded: root.palette = Palette.parseColorsToml(text())
  }
  Timer { id: paletteReload; interval: 120; onTriggered: paletteFile.reload() }
  Connections {
    target: Color
    function onAccentChanged() { paletteReload.restart() }
    function onForegroundChanged() { paletteReload.restart() }
    function onBackgroundChanged() { paletteReload.restart() }
    function onUrgentChanged() { paletteReload.restart() }
  }
  FileView {
    path: Color.stateHome + "/omarchy/current/theme.name"
    watchChanges: true
    printErrors: false
    onFileChanged: { reload(); paletteReload.restart() }
  }
}
