// Task model, views and recurrence for the Tasks mode. Pure JS (no Qt) so
// it is unit tested under node (tests/tasks.test.js). Functions that need the
// recurrence engine take it as `R` (Recur.js), as the calendar's code does.
//
// Records are the same for local tasks (tasks.json) and synced ones
// (tasks-remote.json, written by sync/tasksync.py); see sync/vtodo.py for the
// field list. Dates are local wall time: "yyyy-MM-dd" for a day,
// "yyyy-MM-ddTHH:mm" for a time.
//
// Repeating tasks keep one record whose start/due are the *current*
// occurrence. Completing it moves the dates to the next occurrence (and,
// by default, leaves a completed copy behind as history). That is what
// Apple Reminders, tasks.org and Thunderbird do on CalDAV, so the result
// looks right in those apps too.

// ---- Dates (same helpers as the calendar's Events.js) ---------------------

var MS_PER_DAY = 86400000
var MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
var DAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

function pad2(n) { n = Number(n); return (n < 10 ? "0" : "") + n }
function dateKey(y, m, d) { return y + "-" + pad2(m + 1) + "-" + pad2(d) }
function keyOf(date) { return dateKey(date.getFullYear(), date.getMonth(), date.getDate()) }
function timeKey(h, min) { return pad2(h) + ":" + pad2(min) }

function parseStamp(text) {
  var m = String(text || "").match(/^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2}))?$/)
  if (!m) return null
  return new Date(+m[1], +m[2] - 1, +m[3], m[4] ? +m[4] : 0, m[5] ? +m[5] : 0, 0, 0)
}

function stampOf(date, dayOnly) {
  var k = keyOf(date)
  return dayOnly ? k : k + "T" + timeKey(date.getHours(), date.getMinutes())
}

function addDays(date, n) { var d = new Date(date.getTime()); d.setDate(d.getDate() + n); return d }
function addDaysKey(key, n) { var d = parseStamp(key); return d ? keyOf(addDays(d, n)) : key }

function addMonthsKey(key, n) {
  var d = parseStamp(key)
  if (!d) return key
  var target = new Date(d.getFullYear(), d.getMonth() + n, 1)
  var last = new Date(target.getFullYear(), target.getMonth() + 1, 0).getDate()
  target.setDate(Math.min(d.getDate(), last))
  return keyOf(target)
}

function daysBetween(aKey, bKey) {
  var a = parseStamp(aKey), b = parseStamp(bKey)
  if (!a || !b) return 0
  return Math.round((Date.UTC(b.getFullYear(), b.getMonth(), b.getDate()) - Date.UTC(a.getFullYear(), a.getMonth(), a.getDate())) / MS_PER_DAY)
}

// 14:30, 1430, 9, 9:05, 2pm, 2:30 pm, 12am -> {h, m} or null
function parseTime(text) {
  var t = String(text || "").replace(/\s+/g, "").toLowerCase()
  if (t === "") return null
  if (t === "noon") return { h: 12, m: 0 }
  if (t === "midnight") return { h: 0, m: 0 }
  var m = t.match(/^(\d{1,2})(?::?(\d{2}))?(a|p|am|pm)?$/)
  if (!m) return null
  var h = +m[1], min = m[2] ? +m[2] : 0
  if (min > 59) return null
  if (m[3]) {
    if (h < 1 || h > 12) return null
    var pm = m[3].charAt(0) === "p"
    if (h === 12) h = pm ? 12 : 0
    else if (pm) h += 12
  } else if (h > 23) return null
  return { h: h, m: min }
}

// yyyy-MM-dd, M/D/yyyy, M/D (this year) -> Date or null
function parseDate(text, referenceYear) {
  var t = String(text || "").replace(/^\s+|\s+$/g, "")
  var m = t.match(/^(\d{4})-(\d{1,2})-(\d{1,2})$/)
  var y, mo, d
  if (m) { y = +m[1]; mo = +m[2]; d = +m[3] }
  else {
    m = t.match(/^(\d{1,2})\/(\d{1,2})(?:\/(\d{2,4}))?$/)
    if (!m) return null
    mo = +m[1]; d = +m[2]
    y = m[3] ? (+m[3] < 100 ? 2000 + +m[3] : +m[3]) : (referenceYear || new Date().getFullYear())
  }
  var date = new Date(y, mo - 1, d)
  if (date.getFullYear() !== y || date.getMonth() !== mo - 1 || date.getDate() !== d) return null
  return date
}

function formatTime(h, m, use24) {
  if (use24) return timeKey(h, m)
  var suffix = h >= 12 ? "PM" : "AM"
  var hh = h % 12 === 0 ? 12 : h % 12
  return hh + ":" + pad2(m) + " " + suffix
}

function occurrenceKeyUtc(utcMs) {
  var d = new Date(utcMs)
  return d.getUTCFullYear() + pad2(d.getUTCMonth() + 1) + pad2(d.getUTCDate()) + "T"
    + pad2(d.getUTCHours()) + pad2(d.getUTCMinutes()) + pad2(d.getUTCSeconds())
}

function newId(prefix) {
  return (prefix || "id") + "-" + Date.now().toString(36) + "-" + Math.floor(Math.random() * 0xffffff).toString(36)
}

// A UID that is also a safe object name on the server (see vtodo.safe_name).
function newUid() {
  var hex = ""
  for (var i = 0; i < 32; i++) hex += Math.floor(Math.random() * 16).toString(16)
  return (hex.substr(0, 8) + "-" + hex.substr(8, 4) + "-4" + hex.substr(13, 3) + "-" + hex.substr(16, 4) + "-" + hex.substr(20, 12)).toUpperCase()
}

function dayOf(stamp) { return String(stamp || "").substr(0, 10) }
function hasTime(stamp) { return String(stamp || "").length > 10 }

// ---- Records ----------------------------------------------------------------

var PRIORITIES = [
  { value: 0, label: "None" }, { value: 1, label: "High" }, { value: 5, label: "Medium" }, { value: 9, label: "Low" }
]

function priorityLevel(p) {
  p = Number(p) || 0
  if (p <= 0) return 0
  if (p <= 4) return 1        // high
  if (p === 5) return 2       // medium
  return 3                    // low
}
function priorityName(p) { return ["", "High", "Medium", "Low"][priorityLevel(p)] }

function isDone(t) { return !!t && (t.status === "COMPLETED" || t.status === "CANCELLED") }
function isRepeating(t) { return !!t && !!t.rrule && !!(t.start || t.due) }

function copy(r) { var o = {}; for (var k in r) o[k] = r[k]; return o }

function emptyData() { return { version: 1, lists: [], accounts: [], tasks: [] } }

// Coerce whatever was on disk into the expected shape, keeping unknown keys.
function normalize(data) {
  var d = data && typeof data === "object" ? data : {}
  var out = {}
  for (var k in d) out[k] = d[k]
  out.version = 1
  out.lists = Array.isArray(d.lists) ? d.lists.filter(function(l) { return l && l.id }) : []
  out.accounts = Array.isArray(d.accounts) ? d.accounts.filter(function(a) { return a && a.id }) : []
  out.tasks = Array.isArray(d.tasks) ? d.tasks.filter(function(t) { return t && t.uid && t.listId }) : []
  return out
}

// ---- Recurrence ---------------------------------------------------------------

function wallOf(stamp) {
  var m = String(stamp || "").match(/^(\d{4})-(\d{2})-(\d{2})(?:T(\d{2}):(\d{2}))?$/)
  return m ? Date.UTC(+m[1], +m[2] - 1, +m[3], m[4] ? +m[4] : 0, m[5] ? +m[5] : 0) : NaN
}

function stampOfWall(ms, dayOnly) {
  var d = new Date(ms)
  var k = d.getUTCFullYear() + "-" + pad2(d.getUTCMonth() + 1) + "-" + pad2(d.getUTCDate())
  return dayOnly ? k : k + "T" + pad2(d.getUTCHours()) + ":" + pad2(d.getUTCMinutes())
}

// A real instant -> local wall ms (for UTC UNTIL values).
function localWallOf(utcMs) {
  var d = new Date(utcMs)
  return Date.UTC(d.getFullYear(), d.getMonth(), d.getDate(), d.getHours(), d.getMinutes(), d.getSeconds())
}

function anchorOf(t) { return t.start || t.due || "" }

// Occurrence key of a local stamp, as the helper writes them (ical._norm_key).
function occurrenceKey(stamp) {
  if (!hasTime(stamp)) return dayOf(stamp).replace(/-/g, "")
  return occurrenceKeyUtc(parseStamp(stamp).getTime())
}

var UNIT_DAYS = { DAILY: 1, WEEKLY: 7, MONTHLY: 31, YEARLY: 366 }

function isSimpleRule(rule) {
  for (var k in rule) if (["FREQ", "INTERVAL", "COUNT", "UNTIL", "WKST"].indexOf(k) === -1) return false
  return true
}

// Occurrences (wall ms) of a task's rule from its anchor, from `fromDay` on.
function _occurrences(t, R, fromDayKey, rule) {
  var anchor = anchorOf(t)
  var isDate = !hasTime(anchor)
  var a = wallOf(anchor)
  var interval = Math.max(1, parseInt(rule.INTERVAL || "1", 10) || 1)
  var span = (UNIT_DAYS[String(rule.FREQ || "").toUpperCase()] || 1) * interval * 3 + 400
  var from = wallOf(fromDayKey)
  var end = Math.max(a, from) + span * MS_PER_DAY
  var opts = { toWall: localWallOf }
  if (!/^\d+$/.test(rule.COUNT || "") && from > a) opts.windowStart = from - 2 * MS_PER_DAY
  return R.expand(a, isDate, rule, end, opts)
}

// The next occurrence of a repeating task.
//   mode "due" (default): the first occurrence after both its current date
//     and today, so a missed daily task does not leave a trail of overdue
//     copies behind; "skip": the one right after the current date;
//     "completion": interval units after `today` (repeat after completion).
// -> the task with start/due (and a COUNT) moved, or null when the series
//    has no more occurrences.
function advance(t, R, mode, todayKey) {
  if (!isRepeating(t)) return null
  var rule = R.parseRule(t.rrule)
  var freq = String(rule.FREQ || "").toUpperCase()
  if (!UNIT_DAYS[freq]) return null
  var anchor = anchorOf(t)
  var anchorDay = dayOf(anchor)
  var isDate = !hasTime(anchor)
  var a = wallOf(anchor)
  var hasCount = /^\d+$/.test(rule.COUNT || "")
  var excluded = {}
  ;(t.exdates || []).concat(t.doneKeys || []).forEach(function(k) { excluded[k] = true })
  var today = todayKey || keyOf(new Date())
  var nextWall = null, used = 1

  // After completion, the due date is what people count from ("2 weeks
  // after I did it" = due 2 weeks from today); the start moves with it.
  var ref = a
  if (mode === "completion" && isSimpleRule(rule)) {
    var n = Math.max(1, parseInt(rule.INTERVAL || "1", 10) || 1)
    var refStamp = t.due || anchor
    ref = wallOf(refStamp)
    var day = freq === "DAILY" ? addDaysKey(today, n) : freq === "WEEKLY" ? addDaysKey(today, 7 * n)
      : freq === "MONTHLY" ? addMonthsKey(today, n) : addMonthsKey(today, 12 * n)
    nextWall = wallOf(day) + (ref - wallOf(dayOf(refStamp)))
    if (rule.UNTIL) {
      var u = R.parseUntil(rule.UNTIL)
      var until = !u ? null : u.date ? u.wall + MS_PER_DAY - 1 : (u.wall !== undefined ? u.wall : localWallOf(u.utc))
      if (until !== null && nextWall > until) return null
    }
  } else {
    var after = mode === "skip" ? anchorDay : (mode === "completion" ? today : (today > anchorDay ? today : anchorDay))
    var list = _occurrences(t, R, after, rule)
    for (var i = 0; i < list.length; i++) {
      var w = list[i]
      if (stampOfWall(w, true) <= after) continue
      if (excluded[occurrenceKey(stampOfWall(w, isDate))]) continue
      nextWall = w
      used = i
      break
    }
    if (nextWall === null) return null
  }

  var shift = nextWall - ref
  var out = copy(t)
  if (t.start) out.start = stampOfWall(wallOf(t.start) + shift, !hasTime(t.start))
  if (t.due) out.due = stampOfWall(wallOf(t.due) + shift, !hasTime(t.due))
  if (hasCount) {
    var left = parseInt(rule.COUNT, 10) - used
    if (left < 1) return null
    rule.COUNT = String(left)
    out.rrule = R.formatRule(rule)
  }
  // Exceptions before the new date are history now.
  var newKey = occurrenceKey(anchorOf(out))
  var later = function(k) { return k >= newKey }
  if (out.exdates) out.exdates = out.exdates.filter(later)
  if (out.doneKeys) out.doneKeys = out.doneKeys.filter(later)
  return out
}

// A repeating task whose current date was skipped or completed by another
// app (EXDATE / a completed override) is shown at its next real occurrence.
function effective(t, R) {
  if (!isRepeating(t) || isDone(t)) return t
  var bad = (t.exdates || []).concat(t.doneKeys || [])
  if (!bad.length || bad.indexOf(occurrenceKey(anchorOf(t))) === -1) return t
  var n = advance(t, R, "skip")
  return n || t
}

// What completing a task writes.
// -> { update: record to save, create: record to add (history copy) or null,
//      next: the next date ("" when done for good) }
function complete(t, R, nowStamp, opts) {
  opts = opts || {}
  var now = nowStamp || stampOf(new Date(), false)
  var today = dayOf(now)
  if (isRepeating(t)) {
    var next = advance(t, R, t.repeatFrom === "completion" ? "completion" : "due", today)
    if (next) {
      next.status = "NEEDS-ACTION"
      next.completed = ""
      next.percent = 0
      next.updated = now
      var hist = null
      if (opts.keepHistory !== false) {
        hist = copy(t)
        ;["href", "etag", "rrule", "exdates", "doneKeys", "repeatFrom", "sortOrder", "readOnly"].forEach(function(k) { delete hist[k] })
        hist.uid = opts.newUid || newUid()
        hist.status = "COMPLETED"
        hist.completed = now
        hist.percent = 100
        hist.created = hist.updated = now
        hist.historyOf = t.uid
      }
      return { update: next, create: hist, next: next.due || next.start }
    }
  }
  var done = copy(t)
  done.status = "COMPLETED"
  done.completed = now
  done.percent = 100
  done.updated = now
  return { update: done, create: null, next: "" }
}

function reopen(t, nowStamp) {
  var out = copy(t)
  out.status = "NEEDS-ACTION"
  out.completed = ""
  out.percent = 0
  out.updated = nowStamp || stampOf(new Date(), false)
  return out
}

// The next few dates of a repeating task, for the editor ("Next: ...").
function upcoming(t, R, n, todayKey) {
  var out = []
  var cur = t
  for (var i = 0; i < n && cur; i++) {
    cur = advance(cur, R, "skip", todayKey)
    if (cur) out.push(cur.due || cur.start)
  }
  return out
}

// ---- Labels -------------------------------------------------------------------

// "Today", "Tomorrow", "Fri", "Oct 31", "Oct 31, 2027" (+ time).
function dateLabel(stamp, todayKey, use24) {
  var d = parseStamp(stamp)
  if (!d) return ""
  var day = dayOf(stamp)
  var diff = daysBetween(todayKey, day)
  var text
  if (diff === 0) text = "Today"
  else if (diff === 1) text = "Tomorrow"
  else if (diff === -1) text = "Yesterday"
  else if (diff > 1 && diff < 7) text = DAYS[d.getDay()].substr(0, 3)
  else {
    text = MONTHS[d.getMonth()].substr(0, 3) + " " + d.getDate()
    if (String(d.getFullYear()) !== todayKey.substr(0, 4)) text += ", " + d.getFullYear()
  }
  if (hasTime(stamp)) text += " " + formatTime(d.getHours(), d.getMinutes(), use24)
  return text
}

// "overdue" | "today" | "soon" | "later" | "" for coloring a due date.
function dueState(t, todayKey, nowStamp) {
  if (!t.due || isDone(t)) return ""
  var day = dayOf(t.due)
  if (day < todayKey) return "overdue"
  if (day === todayKey) return hasTime(t.due) && nowStamp && t.due < nowStamp ? "overdue" : "today"
  if (daysBetween(todayKey, day) <= 2) return "soon"
  return "later"
}

// ---- Views --------------------------------------------------------------------

function matches(t, query) {
  var q = String(query || "").toLowerCase().replace(/^\s+|\s+$/g, "")
  if (!q) return true
  var words = q.split(/\s+/)
  var hay = (String(t.title || "") + "\n" + String(t.notes || "")).toLowerCase()
  var tags = (t.categories || []).map(function(c) { return String(c).toLowerCase() })
  return words.every(function(w) {
    if (w.charAt(0) === "#" && w.length > 1) return tags.indexOf(w.substr(1)) !== -1
    return hay.indexOf(w) !== -1 || tags.some(function(c) { return c.indexOf(w) !== -1 })
  })
}

function compareTitle(a, b) {
  return String(a.title || "").toLowerCase().localeCompare(String(b.title || "").toLowerCase())
}

function comparator(mode) {
  // By day; on the same day timed tasks come first, in time order.
  var byDue = function(a, b) {
    var ad = a.due || "", bd = b.due || ""
    if (ad === bd) return 0
    if (!ad) return 1
    if (!bd) return -1
    var da = dayOf(ad), db = dayOf(bd)
    if (da !== db) return da < db ? -1 : 1
    if (hasTime(ad) !== hasTime(bd)) return hasTime(ad) ? -1 : 1
    return ad < bd ? -1 : 1
  }
  var byPriority = function(a, b) {
    var pa = priorityLevel(a.priority) || 9, pb = priorityLevel(b.priority) || 9
    return pa - pb
  }
  var byManual = function(a, b) {
    var sa = a.sortOrder, sb = b.sortOrder
    if (sa === undefined && sb === undefined) return 0
    if (sa === undefined) return 1
    if (sb === undefined) return -1
    return sa - sb
  }
  var byCreated = function(a, b) { return String(b.created || "").localeCompare(String(a.created || "")) }
  var chain = mode === "priority" ? [byPriority, byDue] : mode === "title" ? [] : mode === "created" ? [byCreated]
    : mode === "manual" ? [byManual, byDue] : [byDue, byPriority]
  return function(a, b) {
    for (var i = 0; i < chain.length; i++) { var c = chain[i](a, b); if (c) return c }
    var t = compareTitle(a, b)
    return t || String(a.uid).localeCompare(String(b.uid))
  }
}

function byCompletedDesc(a, b) { return String(b.completed || "").localeCompare(String(a.completed || "")) || compareTitle(a, b) }

// Subtask counts per parent uid ({ all, done }), done ones included.
function childCounts(allTasks) {
  var counts = {}
  allTasks.forEach(function(t) {
    if (!t.parent) return
    var c = counts[t.parent] = counts[t.parent] || { all: 0, done: 0 }
    c.all++
    if (isDone(t)) c.done++
  })
  return counts
}

function _titles(allTasks) {
  var out = {}
  allTasks.forEach(function(t) { out[t.listId + "|" + t.uid] = t.title })
  return out
}

// Children under their parents (when the parent is in the same set), as
// rows { task, depth, children, done, kids, collapsed }. `collapsed` maps
// "listId|uid" -> true for parents whose subtasks are folded away.
function tree(tasks, cmp, allTasks, collapsed) {
  var byUid = {}
  tasks.forEach(function(t) { byUid[t.uid] = t })
  var kids = {}
  var roots = []
  tasks.forEach(function(t) {
    if (t.parent && byUid[t.parent] && t.parent !== t.uid) (kids[t.parent] = kids[t.parent] || []).push(t)
    else roots.push(t)
  })
  var counts = childCounts(allTasks || tasks)
  var fold = collapsed || {}
  var rows = [], seen = {}
  function walk(t, depth) {
    if (seen[t.uid]) return
    seen[t.uid] = true
    var c = counts[t.uid] || { all: 0, done: 0 }
    var mine = kids[t.uid] || []
    var folded = mine.length > 0 && !!fold[t.listId + "|" + t.uid]
    rows.push({ task: t, depth: Math.min(depth, 4), children: c.all, done: c.done, kids: mine.length, collapsed: folded, parentTitle: "" })
    if (folded) { descendantsIn(mine, kids).forEach(function(k) { seen[k.uid] = true }); return }
    mine.sort(cmp).forEach(function(k) { walk(k, depth + 1) })
  }
  roots.sort(cmp).forEach(function(t) { walk(t, 0) })
  tasks.forEach(function(t) { if (!seen[t.uid]) walk(t, 0) })   // cycles
  return rows
}

function descendantsIn(list, kids) {
  var out = []
  list.forEach(function(k) { out.push(k); out = out.concat(descendantsIn(kids[k.uid] || [], kids)) })
  return out
}

// Rows without nesting (date views); subtasks name their parent instead.
function flatRows(tasks, cmp, allTasks) {
  var counts = childCounts(allTasks || tasks)
  var titles = _titles(allTasks || tasks)
  return tasks.slice().sort(cmp).map(function(t) {
    var c = counts[t.uid] || { all: 0, done: 0 }
    return { task: t, depth: 0, children: c.all, done: c.done, kids: 0, collapsed: false,
             parentTitle: t.parent ? (titles[t.listId + "|" + t.parent] || "") : "" }
  })
}

// ---- Projects -------------------------------------------------------------------
//
// A project is an open top-level task that is marked as one (`project`) or,
// unless autoProjects is off, simply has subtasks. Its progress counts every
// task under it.

function projects(tasks, lists, opts) {
  opts = opts || {}
  var auto = opts.autoProjects !== false
  var shown = {}
  ;(lists || []).forEach(function(l) { shown[l.id] = l.visible !== false })
  var kids = {}
  tasks.forEach(function(t) { if (t.parent) (kids[t.listId + "|" + t.parent] = kids[t.listId + "|" + t.parent] || []).push(t) })
  var out = []
  tasks.forEach(function(t) {
    if (t.parent || isDone(t) || shown[t.listId] === false) return
    var key = t.listId + "|" + t.uid
    if (!t.project && !(auto && kids[key])) return
    var all = [], frontier = [key], seen = {}
    seen[key] = true
    while (frontier.length) {
      var k = frontier.shift()
      ;(kids[k] || []).forEach(function(c) {
        var ck = c.listId + "|" + c.uid
        if (seen[ck]) return
        seen[ck] = true
        all.push(c)
        frontier.push(ck)
      })
    }
    var done = all.filter(isDone).length
    out.push({ task: t, key: key, total: all.length, done: done, open: all.length - done })
  })
  return out.sort(function(a, b) { return comparator("due")(a.task, b.task) })
}

function projectByKey(list, key) {
  for (var i = 0; i < list.length; i++) if (list[i].key === key) return list[i]
  return null
}

// ---- Moving tasks in the tree -------------------------------------------------------

// Tab: the task becomes a subtask of the sibling row above it.
// -> new parent uid, or null when there is none.
function indentTarget(rows, index) {
  var r = rows[index]
  if (!r) return null
  for (var i = index - 1; i >= 0; i--) {
    if (rows[i].depth < r.depth) return null
    if (rows[i].depth === r.depth && rows[i].task.listId === r.task.listId) return rows[i].task.uid
  }
  return null
}

// Shift+Tab: up one level (the parent's parent, or top level). -> uid,
// "" for top level, or null when it is already at the top.
function outdentTarget(t, allTasks) {
  if (!t || !t.parent) return null
  for (var i = 0; i < allTasks.length; i++) {
    var p = allTasks[i]
    if (p.uid === t.parent && p.listId === t.listId) return p.parent || ""
  }
  return ""
}

// ---- Completion rules -----------------------------------------------------------------

function openDescendants(allTasks, t) {
  return descendants(allTasks, t.uid).filter(function(x) { return x.listId === t.listId && !isDone(x) })
}

// The parents that become complete when `t` is (all their other subtasks
// already are), nearest first.
function parentsToComplete(allTasks, t) {
  var out = []
  var cur = t
  var doneNow = {}
  doneNow[t.uid] = true
  while (cur && cur.parent) {
    var parent = null
    for (var i = 0; i < allTasks.length; i++) if (allTasks[i].uid === cur.parent && allTasks[i].listId === cur.listId) parent = allTasks[i]
    if (!parent || isDone(parent) || isRepeating(parent)) break
    var siblings = allTasks.filter(function(x) { return x.parent === parent.uid && x.listId === parent.listId })
    if (!siblings.every(function(x) { return isDone(x) || doneNow[x.uid] })) break
    out.push(parent)
    doneNow[parent.uid] = true
    cur = parent
  }
  return out
}

// Completed subtasks of a repeating task, reopened when it moves on.
function doneDescendants(allTasks, t) {
  return descendants(allTasks, t.uid).filter(function(x) { return x.listId === t.listId && isDone(x) && !x.historyOf })
}

var SMART = ["today", "scheduled", "all", "important", "completed"]
var SMART_LABELS = { today: "Today", scheduled: "Scheduled", all: "All", important: "Important", completed: "Completed" }

function inSmart(view, t, todayKey) {
  if (view === "completed") return isDone(t)
  if (isDone(t)) return false
  if (view === "today") return t.due ? dayOf(t.due) <= todayKey : (!!t.start && dayOf(t.start) === todayKey)
  if (view === "scheduled") return !!t.due
  if (view === "important") return priorityLevel(t.priority) === 1
  return true
}

function counts(tasks, lists, todayKey) {
  var out = { today: 0, scheduled: 0, all: 0, important: 0, completed: 0, overdue: 0, lists: {} }
  var shown = {}
  lists.forEach(function(l) { shown[l.id] = l.visible !== false; out.lists[l.id] = 0 })
  tasks.forEach(function(t) {
    if (!isDone(t) && out.lists[t.listId] !== undefined) out.lists[t.listId]++
    if (!shown[t.listId]) return
    SMART.forEach(function(v) { if (inSmart(v, t, todayKey)) out[v]++ })
    if (!isDone(t) && t.due && dayOf(t.due) < todayKey) out.overdue++
  })
  return out
}

// Sections for the main list.
//   opts: { view: smart name or "list", listId, query, sort, showCompleted,
//           todayKey, lists (for names/visibility) }
// -> [{ key, title, rows: [{task, depth, children, done}], collapsible }]
function sections(tasks, opts) {
  var today = opts.todayKey
  var view = opts.view || "today"
  var shown = {}, names = {}
  ;(opts.lists || []).forEach(function(l) { shown[l.id] = l.visible !== false; names[l.id] = l.name })
  var cmp = comparator(opts.sort || "due")
  var fold = opts.collapsed || {}
  var inProject = null
  if (view === "project") {
    var pk = String(opts.projectKey || "").split("|")
    var proj = tasks.filter(function(t) { return t.listId === pk[0] && t.uid === pk[1] })[0]
    inProject = {}
    if (proj) descendants(tasks.filter(function(t) { return t.listId === proj.listId }), proj.uid).forEach(function(t) { inProject[t.uid] = true })
  }
  var base = tasks.filter(function(t) {
    if (view === "list") return t.listId === opts.listId
    if (view === "project") return !!inProject[t.uid] && t.listId === String(opts.projectKey).split("|")[0]
    return shown[t.listId] !== false
  }).filter(function(t) { return matches(t, opts.query) })
  var open = base.filter(function(t) { return !isDone(t) })
  var done = base.filter(isDone).sort(byCompletedDesc)
  var out = []
  function push(key, title, rows, extra) {
    if (!rows.length) return
    var s = { key: key, title: title, rows: rows }
    for (var k in extra || {}) s[k] = extra[k]
    out.push(s)
  }

  if (view === "completed") {
    var groups = {}, order = []
    done.forEach(function(t) {
      var day = dayOf(t.completed) || "earlier"
      if (!groups[day]) { groups[day] = []; order.push(day) }
      groups[day].push(t)
    })
    order.forEach(function(day) {
      push("done-" + day, day === "earlier" ? "Earlier" : dateLabel(day, today, true),
           flatRows(groups[day], function() { return 0 }, tasks))
    })
    return out
  }

  if (view === "today" || view === "scheduled") {
    var list = open.filter(function(t) { return inSmart(view, t, today) })
    var overdue = list.filter(function(t) { return t.due && dayOf(t.due) < today })
    push("overdue", "Overdue", flatRows(overdue, cmp, tasks), { tone: "urgent" })
    if (view === "today") {
      push("today", "Today", flatRows(list.filter(function(t) { return overdue.indexOf(t) === -1 }), cmp, tasks))
    } else {
      var byDay = {}, days = []
      // The next seven days one by one, then the rest of this month, then by month.
      var order = function(b) { return b === "later-month" ? today.substr(0, 7) + "-32" : b.length === 7 ? b + "-00" : b }
      list.forEach(function(t) {
        if (overdue.indexOf(t) !== -1) return
        var d = dayOf(t.due)
        var bucket = daysBetween(today, d) < 7 ? d : (d.substr(0, 7) === today.substr(0, 7) ? "later-month" : d.substr(0, 7))
        if (!byDay[bucket]) { byDay[bucket] = []; days.push(bucket) }
        byDay[bucket].push(t)
      })
      days.sort(function(x, y) { return order(x) < order(y) ? -1 : order(x) > order(y) ? 1 : 0 })
      days.forEach(function(b) {
        var title
        if (b === "later-month") title = "Later this month"
        else if (b.length === 7) { var p = parseStamp(b + "-01"); title = MONTHS[p.getMonth()] + (b.substr(0, 4) !== today.substr(0, 4) ? " " + b.substr(0, 4) : "") }
        else title = dateLabel(b, today, true) + (daysBetween(today, b) > 1 ? " · " + MONTHS[parseStamp(b).getMonth()].substr(0, 3) + " " + parseStamp(b).getDate() : "")
        push("day-" + b, title, flatRows(byDay[b], cmp, tasks))
      })
    }
  } else if (view === "important") {
    push("important", "Important", flatRows(open.filter(function(t) { return priorityLevel(t.priority) === 1 }), cmp, tasks))
  } else if (view === "all") {
    var lists = (opts.lists || []).filter(function(l) { return shown[l.id] !== false })
    lists.forEach(function(l) {
      push("list-" + l.id, l.name, tree(open.filter(function(t) { return t.listId === l.id }), cmp, tasks, fold), { listId: l.id })
    })
  } else {
    push("open", "", tree(open, cmp, tasks, fold), view === "project" ? { listId: String(opts.projectKey).split("|")[0] } : {})
  }

  if (opts.showCompleted && view !== "completed") {
    var doneHere = view === "list" || view === "all" || view === "project" ? done : done.filter(function(t) { return view !== "important" || priorityLevel(t.priority) === 1 })
    if (view === "today") doneHere = doneHere.filter(function(t) { return dayOf(t.completed) === today })
    var titles = _titles(tasks)
    push("completed", "Completed", doneHere.slice(0, 200).map(function(t) {
      return { task: t, depth: 0, children: 0, done: 0, kids: 0, collapsed: false,
               parentTitle: t.parent && view !== "project" ? (titles[t.listId + "|" + t.parent] || "") : "" }
    }), { completed: true })
  }
  return out
}

function rowsOf(secs) {
  var out = []
  secs.forEach(function(s) { s.rows.forEach(function(r) { out.push(r) }) })
  return out
}

// ---- Quick add ------------------------------------------------------------------
//
// "Pay rent every month on the 1st #bills !high"
// "Call mom tomorrow at 5pm"   "Stretch every weekday"   "Review @Work fri"
// -> { title, due, rrule, repeatFrom, priority, categories, list }

var WD = ["su", "mo", "tu", "we", "th", "fr", "sa"]
var WD_FULL = { sun: 0, sunday: 0, mon: 1, monday: 1, tue: 2, tues: 2, tuesday: 2, wed: 3, wednesday: 3,
  thu: 4, thur: 4, thurs: 4, thursday: 4, fri: 5, friday: 5, sat: 6, saturday: 6 }
var MONTH_IDX = { jan: 0, january: 0, feb: 1, february: 1, mar: 2, march: 2, apr: 3, april: 3, may: 4, jun: 5, june: 5,
  jul: 6, july: 6, aug: 7, august: 7, sep: 8, sept: 8, september: 8, oct: 9, october: 9, nov: 10, november: 10, dec: 11, december: 11 }
var RULE_DAY = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]

function _ordinal(text) {
  var m = String(text).match(/^(\d{1,2})(st|nd|rd|th)?$/)
  return m ? +m[1] : null
}

function _nextWeekday(todayKey, wd, strictlyAfter) {
  var d = parseStamp(todayKey)
  var diff = (wd - d.getDay() + 7) % 7
  if (diff === 0 && strictlyAfter) diff = 7
  return keyOf(addDays(d, diff))
}

// A date phrase at the start of `words` -> { key, used } or null.
function _datePhrase(words, todayKey) {
  var w0 = words[0], w1 = words[1], w2 = words[2]
  if (!w0) return null
  var today = parseStamp(todayKey)
  if (w0 === "today" || w0 === "tod") return { key: todayKey, used: 1 }
  if (w0 === "tonight") return { key: todayKey, used: 1, time: { h: 20, m: 0 } }
  if (w0 === "tomorrow" || w0 === "tmr" || w0 === "tmrw" || w0 === "tom") return { key: addDaysKey(todayKey, 1), used: 1 }
  if (w0 === "yesterday") return { key: addDaysKey(todayKey, -1), used: 1 }
  if (w0 === "next" && w1 === "week") return { key: _nextWeekday(todayKey, 1, true), used: 2 }
  if (w0 === "next" && w1 === "month") return { key: keyOf(new Date(today.getFullYear(), today.getMonth() + 1, 1)), used: 2 }
  if (w0 === "next" && WD_FULL[w1] !== undefined) return { key: _nextWeekday(todayKey, WD_FULL[w1], true), used: 2 }
  if (WD_FULL[w0] !== undefined) return { key: _nextWeekday(todayKey, WD_FULL[w0], false), used: 1 }
  if (w0 === "in" && /^\d+$/.test(w1 || "") && w2) {
    var n = +w1, unit = w2.replace(/s$/, "")
    if (unit === "day") return { key: addDaysKey(todayKey, n), used: 3 }
    if (unit === "week") return { key: addDaysKey(todayKey, 7 * n), used: 3 }
    if (unit === "month") return { key: addMonthsKey(todayKey, n), used: 3 }
    if (unit === "year") return { key: addMonthsKey(todayKey, 12 * n), used: 3 }
  }
  var d = parseDate(w0, today.getFullYear())
  if (d) {
    // M/D without a year that has passed means next year.
    var hasYear = /^\d{4}-/.test(w0) || /^\d{1,2}\/\d{1,2}\/\d{2,4}$/.test(w0)
    if (!hasYear && keyOf(d) < todayKey) d = new Date(d.getFullYear() + 1, d.getMonth(), d.getDate())
    return { key: keyOf(d), used: 1 }
  }
  // "oct 31", "october 31st", "31 oct"
  var mo = MONTH_IDX[w0], day = _ordinal(w1 || "")
  var used = 2
  if (mo === undefined) { mo = MONTH_IDX[w1]; day = _ordinal(w0) }
  if (mo !== undefined && day) {
    var year = today.getFullYear()
    if (/^\d{4}$/.test(w2 || "")) { year = +w2; used = 3 }
    var dt = new Date(year, mo, day)
    if (dt.getMonth() !== mo) return null
    if (used === 2 && keyOf(dt) < todayKey) dt = new Date(year + 1, mo, day)
    return { key: keyOf(dt), used: used }
  }
  return null
}

function _timePhrase(words) {
  var w0 = words[0], w1 = words[1]
  if (!w0) return null
  // "at 5", "at 17:30", "5pm", "5 pm", "17:30", "noon"
  var at = w0 === "at" || w0 === "@"
  var a = at ? w1 : w0
  var b = at ? words[2] : w1
  if (!a) return null
  if (b === "am" || b === "pm") { var t2 = parseTime(a + b); if (t2) return { time: t2, used: (at ? 1 : 0) + 2 } }
  if (at || /(am|pm|a|p)$/.test(a) || /^\d{1,2}:\d{2}$/.test(a) || a === "noon" || a === "midnight") {
    var t = parseTime(a)
    if (t && (at || !/^\d+$/.test(a))) return { time: t, used: at ? 2 : 1 }
  }
  return null
}

// "every ..." at the start of `words` -> { rule, used, firstKey?, fromCompletion } or null
function _repeatPhrase(words, todayKey) {
  var w = words
  if (w[0] === "daily") return { rule: { FREQ: "DAILY" }, used: 1 }
  if (w[0] === "weekly") return { rule: { FREQ: "WEEKLY" }, used: 1 }
  if (w[0] === "monthly") return { rule: { FREQ: "MONTHLY" }, used: 1 }
  if (w[0] === "yearly" || w[0] === "annually") return { rule: { FREQ: "YEARLY" }, used: 1 }
  if (w[0] !== "every" && w[0] !== "each") return null
  var i = 1, n = 1
  if (w[i] === "other") { n = 2; i++ }
  else if (/^\d+$/.test(w[i] || "")) { n = +w[i]; i++ }
  var word = w[i] || ""
  var unit = word.replace(/s$/, "")
  var rule = null
  if (unit === "day") rule = { FREQ: "DAILY" }
  else if (unit === "week") rule = { FREQ: "WEEKLY" }
  else if (unit === "month") rule = { FREQ: "MONTHLY" }
  else if (unit === "year") rule = { FREQ: "YEARLY" }
  else if (word === "weekday" || word === "weekdays") { rule = { FREQ: "WEEKLY", BYDAY: "MO,TU,WE,TH,FR" }; n = 1 }
  else if (word === "weekend" || word === "weekends") { rule = { FREQ: "WEEKLY", BYDAY: "SA,SU" } }
  else if (WD_FULL[word.split(",")[0]] !== undefined) {
    var days = []
    while (i < w.length) {
      var parts = w[i].split(",").filter(function(x) { return x })
      var ok = parts.length && parts.every(function(p) { return WD_FULL[p] !== undefined })
      if (ok) { parts.forEach(function(p) { if (days.indexOf(WD_FULL[p]) === -1) days.push(WD_FULL[p]) }); i++; continue }
      if ((w[i] === "and" || w[i] === "&") && WD_FULL[(w[i + 1] || "").replace(/,$/, "")] !== undefined) { i++; continue }
      break
    }
    days.sort(function(a, b) { return ((a + 6) % 7) - ((b + 6) % 7) })
    rule = { FREQ: "WEEKLY", BYDAY: days.map(function(d) { return RULE_DAY[d] }).join(",") }
    i--
  } else if (_ordinal(word)) {
    rule = { FREQ: "MONTHLY", BYMONTHDAY: String(_ordinal(word)) }
  } else if (MONTH_IDX[word] !== undefined && _ordinal(w[i + 1] || "")) {
    rule = { FREQ: "YEARLY", BYMONTH: String(MONTH_IDX[word] + 1), BYMONTHDAY: String(_ordinal(w[i + 1])) }
    i++
  } else return null
  i++
  if (n > 1) rule.INTERVAL = String(n)
  // "every month on the 15th", "every year on oct 31"
  if (rule.FREQ === "MONTHLY" && w[i] === "on" && w[i + 1] === "the" && _ordinal(w[i + 2] || "")) { rule.BYMONTHDAY = String(_ordinal(w[i + 2])); i += 3 }
  else if (rule.FREQ === "MONTHLY" && w[i] === "on" && _ordinal(w[i + 1] || "")) { rule.BYMONTHDAY = String(_ordinal(w[i + 1])); i += 2 }
  else if (rule.FREQ === "WEEKLY" && !rule.BYDAY && w[i] === "on" && WD_FULL[w[i + 1]] !== undefined) { rule.BYDAY = RULE_DAY[WD_FULL[w[i + 1]]]; i += 2 }
  var fromCompletion = false
  if ((w[i] === "after" || w[i] === "from") && /^(completion|completed|done|completing|finishing)$/.test(w[i + 1] || "")) { fromCompletion = true; i += 2 }
  return { rule: rule, used: i, fromCompletion: fromCompletion }
}

// First day on/after today that a rule lands on ("every monday" said on a
// Wednesday is next Monday). Rules without BY parts start today.
function firstDay(ruleText, R, todayKey) {
  var rule = R.parseRule(ruleText)
  if (!rule.BYDAY && !rule.BYMONTHDAY && !rule.BYMONTH) return todayKey
  var probe = {}
  for (var k in rule) if (k !== "COUNT" && k !== "UNTIL" && k !== "INTERVAL") probe[k] = rule[k]
  var days = R.expand(wallOf(todayKey), true, probe, wallOf(addDaysKey(todayKey, 800)), {})
  for (var i = 0; i < days.length; i++) {
    var d = stampOfWall(days[i], true)
    if (d >= todayKey) return d
  }
  return todayKey
}

function parseQuick(text, todayKey, R) {
  var raw = String(text || "").replace(/\s+/g, " ").replace(/^\s+|\s+$/g, "")
  var out = { title: "", due: "", rrule: "", repeatFrom: "due", priority: 0, categories: [], list: "", project: "" }
  var tokens = raw.split(" ").filter(function(x) { return x !== "" })
  var keep = []
  var date = null, time = null, repeat = null
  var i = 0
  while (i < tokens.length) {
    var tok = tokens[i]
    var lower = tok.toLowerCase()
    var rest = tokens.slice(i).map(function(x) { return x.toLowerCase() })
    if (/^!+$/.test(tok) && tok.length <= 3) { out.priority = [0, 9, 5, 1][tok.length]; i++; continue }
    var pm = lower.match(/^!(high|hi|h|1|medium|med|m|2|low|lo|l|3)$/)
    if (pm) { out.priority = /^(high|hi|h|1)$/.test(pm[1]) ? 1 : /^(low|lo|l|3)$/.test(pm[1]) ? 9 : 5; i++; continue }
    if (/^#[^\s#]+$/.test(tok)) { out.categories.push(tok.substr(1)); i++; continue }
    if (/^\^[^\s^]+$/.test(tok)) { out.project = tok.substr(1).replace(/_/g, " "); i++; continue }
    if (/^@[^\s@]+$/.test(tok) && !_timePhrase(rest)) { out.list = tok.substr(1).replace(/_/g, " "); i++; continue }
    if (!repeat) {
      var rp = _repeatPhrase(rest, todayKey)
      // A bare "weekly" / "daily" is part of the title when it starts it
      // ("Weekly review") or an explicit "every ..." comes later.
      var bare = rp && rest[0] !== "every" && rest[0] !== "each"
      if (bare && (keep.length === 0 || rest.slice(1).some(function(w) { return w === "every" || w === "each" }))) rp = null
      if (rp) { repeat = rp; i += rp.used; continue }
    }
    var lead = (lower === "on" || lower === "due" || lower === "by") ? 1 : 0
    if (!date) {
      var dp = _datePhrase(rest.slice(lead), todayKey)
      if (dp) { date = dp; if (dp.time && !time) time = dp.time; i += lead + dp.used; continue }
    }
    if (!time) {
      var tp = _timePhrase(rest)
      if (tp) { time = tp.time; i += tp.used; continue }
    }
    keep.push(tok)
    i++
  }
  out.title = keep.join(" ")
  if (repeat) {
    out.rrule = R.formatRule(repeat.rule)
    if (repeat.fromCompletion) out.repeatFrom = "completion"
    if (!date) date = { key: firstDay(out.rrule, R, todayKey) }
  }
  if (!date && time) date = { key: todayKey }
  if (date) out.due = date.key + (time ? "T" + timeKey(time.h, time.m) : "")
  if (!out.title) out.title = raw
  return out
}

// ---- Editor form ------------------------------------------------------------------

function formFor(t, use24) {
  var d = parseStamp(t.due), s = parseStamp(t.start)
  return {
    title: t.title || "",
    listId: t.listId || "",
    notes: t.notes || "",
    dueDate: t.due ? dayOf(t.due) : "",
    dueTime: d && hasTime(t.due) ? formatTime(d.getHours(), d.getMinutes(), use24) : "",
    startDate: t.start && t.start !== t.due ? dayOf(t.start) : "",
    priority: priorityLevel(t.priority) === 1 ? 1 : priorityLevel(t.priority) === 2 ? 5 : priorityLevel(t.priority) === 3 ? 9 : 0,
    rrule: t.rrule || "",
    repeatFrom: t.repeatFrom === "completion" ? "completion" : "due",
    categories: (t.categories || []).join(", "),
    parent: t.parent || "",
    project: !!t.project
  }
}

// Words like "tomorrow" or "fri" in a date field.
function parseDateField(text, todayKey) {
  var t = String(text || "").replace(/^\s+|\s+$/g, "").toLowerCase()
  if (t === "") return ""
  var d = parseDate(t, parseStamp(todayKey).getFullYear())
  if (d) return keyOf(d)
  var p = _datePhrase(t.split(/\s+/), todayKey)
  return p && p.used === t.split(/\s+/).length ? p.key : null
}

// -> { task } or { error }
function buildTask(form, base, nowStamp, todayKey) {
  var title = String(form.title || "").replace(/^\s+|\s+$/g, "")
  if (title === "") return { error: "Give the task a title" }
  if (!form.listId) return { error: "Pick a list" }
  var dueDay = parseDateField(form.dueDate, todayKey)
  if (dueDay === null) return { error: "Due date not understood (try 2026-10-31, 10/31 or \"fri\")" }
  var time = null
  if (String(form.dueTime || "").replace(/\s+/g, "") !== "") {
    time = parseTime(form.dueTime)
    if (!time) return { error: "Due time not understood (try 17:00 or 5pm)" }
    if (!dueDay) dueDay = todayKey
  }
  var startDay = parseDateField(form.startDate, todayKey)
  if (startDay === null) return { error: "Start date not understood" }
  if (startDay && dueDay && startDay > dueDay) return { error: "The task starts after it is due" }
  if (form.rrule && !dueDay && !startDay) return { error: "A repeating task needs a due date" }
  var t = base ? copy(base) : {}
  t.title = title
  t.listId = form.listId
  t.notes = String(form.notes || "")
  t.due = dueDay ? dueDay + (time ? "T" + timeKey(time.h, time.m) : "") : ""
  t.start = startDay || ""
  // A start on the due day itself says nothing.
  if (t.start && t.start === dayOf(t.due) && !hasTime(t.due)) t.start = ""
  if (base && base.start && base.due && base.start === base.due && !form.startDate) t.start = ""
  t.priority = Number(form.priority) || 0
  t.rrule = form.rrule || ""
  t.repeatFrom = form.rrule && form.repeatFrom === "completion" ? "completion" : "due"
  if (!t.rrule) { delete t.exdates; delete t.doneKeys }
  t.categories = String(form.categories || "").split(",").map(function(c) { return c.replace(/^\s*#?|\s+$/g, "") }).filter(function(c) { return c })
  t.parent = form.parent || ""
  t.project = !t.parent && !!form.project
  t.updated = nowStamp
  if (!base) {
    t.uid = newUid()
    t.status = "NEEDS-ACTION"
    t.completed = ""
    t.percent = 0
    t.created = nowStamp
  }
  return { task: t }
}

// Every task under `uid` (children, their children, ...).
function descendants(tasks, uid) {
  var out = [], frontier = [uid], seen = {}
  seen[uid] = true
  while (frontier.length) {
    var p = frontier.shift()
    tasks.forEach(function(t) {
      if (t.parent === p && !seen[t.uid]) { seen[t.uid] = true; out.push(t); frontier.push(t.uid) }
    })
  }
  return out
}

// ---- Tasks on the calendar ------------------------------------------------
// Tasks with a due date drawn by the calendar views as event-shaped stand-ins.
// A date-only due is an all-day item; a timed due is a 30-minute block. Each
// carries `taskRef` ("listId|uid") so the window can tell them from events,
// and lives in a pseudo calendar "tasks:<listId>" with the list's color.
//   opts: { showCompleted, editable(task) -> bool }
// -> { events: [...], calendars: [...] }
var TASK_MINUTES = 30
var TASK_OPEN = "\u{f0131}"     // nerd font checkbox-blank-outline
var TASK_DONE = "\u{f0132}"     // checkbox-marked
function calendarItems(tasks, lists, opts) {
  opts = opts || {}
  var shown = {}, cals = []
  ;(lists || []).forEach(function(l) {
    if (l.visible === false) return
    shown[l.id] = true
    cals.push({ id: "tasks:" + l.id, name: l.name, color: l.color, visible: true, source: { type: "tasks" } })
  })
  var events = []
  ;(tasks || []).forEach(function(t) {
    if (!t.due || !shown[t.listId]) return
    var done = isDone(t)
    if (done && !opts.showCompleted) return
    var timed = hasTime(t.due)
    var start = String(t.due), end = start
    if (timed) {
      var d = parseStamp(start)
      if (!d) return
      end = stampOf(new Date(d.getTime() + TASK_MINUTES * 60000), false)
    }
    events.push({
      uid: "task:" + t.listId + "|" + t.uid,
      calendarId: "tasks:" + t.listId,
      title: (done ? TASK_DONE : TASK_OPEN) + " " + (t.title || "(untitled)"),
      start: start, end: end, allDay: !timed,
      taskRef: t.listId + "|" + t.uid,
      taskDone: done,
      taskEditable: opts.editable ? !!opts.editable(t) : true,
      readOnly: true
    })
  })
  return { events: events, calendars: cals }
}

// The due stamp a drag on the calendar gives a task (`changed` is the moved
// stand-in): all-day items keep a date-only due, timed ones take the new time.
function dueFromMove(ev, changed) {
  if (!changed || !changed.start) return ""
  return ev.allDay ? dayOf(changed.start) : String(changed.start).substr(0, 16)
}

// Tasks for one day in the popup: due that day, and on today also anything
// overdue. Open tasks only, overdue first, then by time, priority and title.
function dueOn(tasks, lists, key, todayKey) {
  var shown = {}
  ;(lists || []).forEach(function(l) { if (l.visible !== false) shown[l.id] = true })
  var out = (tasks || []).filter(function(t) {
    if (!t.due || isDone(t) || !shown[t.listId]) return false
    var d = dayOf(t.due)
    return d === key || (key === todayKey && d < todayKey)
  })
  return out.sort(function(a, b) {
    var ao = dayOf(a.due) < key ? 0 : 1, bo = dayOf(b.due) < key ? 0 : 1
    if (ao !== bo) return ao - bo
    var at = hasTime(a.due) ? a.due.substr(11) : "99", bt = hasTime(b.due) ? b.due.substr(11) : "99"
    if (dayOf(a.due) !== dayOf(b.due)) return dayOf(a.due) < dayOf(b.due) ? -1 : 1
    if (at !== bt) return at < bt ? -1 : 1
    var ap = priorityLevel(a.priority) || 4, bp = priorityLevel(b.priority) || 4
    if (ap !== bp) return ap - bp
    return compareTitle(a, b)
  })
}

if (typeof module !== "undefined") {
  module.exports = {
    pad2: pad2, dateKey: dateKey, keyOf: keyOf, parseStamp: parseStamp, stampOf: stampOf, addDaysKey: addDaysKey,
    addMonthsKey: addMonthsKey, daysBetween: daysBetween, parseTime: parseTime, parseDate: parseDate, formatTime: formatTime,
    occurrenceKeyUtc: occurrenceKeyUtc, occurrenceKey: occurrenceKey, newId: newId, newUid: newUid, dayOf: dayOf, hasTime: hasTime,
    priorityLevel: priorityLevel, priorityName: priorityName, isDone: isDone, isRepeating: isRepeating, normalize: normalize,
    advance: advance, effective: effective, complete: complete, reopen: reopen, upcoming: upcoming,
    dateLabel: dateLabel, dueState: dueState, matches: matches, comparator: comparator, tree: tree, sections: sections,
    rowsOf: rowsOf, counts: counts, inSmart: inSmart, parseQuick: parseQuick, firstDay: firstDay, formFor: formFor,
    buildTask: buildTask, parseDateField: parseDateField, descendants: descendants, SMART: SMART, SMART_LABELS: SMART_LABELS,
    projects: projects, projectByKey: projectByKey, indentTarget: indentTarget, outdentTarget: outdentTarget,
    openDescendants: openDescendants, parentsToComplete: parentsToComplete, doneDescendants: doneDescendants,
    childCounts: childCounts, flatRows: flatRows, calendarItems: calendarItems, dueFromMove: dueFromMove, dueOn: dueOn
  }
}
