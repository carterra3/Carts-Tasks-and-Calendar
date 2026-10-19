// Event + calendar data model. Pure JS (no Qt) so it is testable under node.
// (Under node, Recur.js and Tz.js are require()d at the bottom; in QML the
// store passes them in where needed, see expandAll.)
//
// Stored shape (calendar.json), deliberately iCalendar-shaped so a future
// sync helper can map it to/from VEVENTs without guessing:
//
// {
//   "version": 1,
//   "calendars": [ { "id", "name", "color": "theme:blue" | "#rrggbb", "visible": true,
//                    "source": { "type": "local" } } ],
//   "events": [ { "uid", "calendarId", "title", "allDay",
//                 "start": "yyyy-MM-dd" | "yyyy-MM-ddTHH:mm",   // local time
//                 "end":   "yyyy-MM-dd" | "yyyy-MM-ddTHH:mm",   // all-day: inclusive last day
//                 "location", "notes", "created", "updated",
//                 "tz": "Europe/Paris",            // optional: the event's own zone
//                 "rrule": "FREQ=WEEKLY;BYDAY=MO", // optional: a repeating series
//                 "exdates": ["20261019T140000"],  // occurrences removed (keys, see occurrenceKey)
//                 "overrides": { "<key>": { start, end, title, ... } } } ]  // changed occurrences
// }
//
// A repeating event is stored once (its first occurrence's times) and
// expanded into occurrences for the views by expandAll.

var MS_PER_DAY = 86400000

function pad2(n) { n = Number(n); return (n < 10 ? "0" : "") + n }

function dateKey(y, m, d) { return y + "-" + pad2(m + 1) + "-" + pad2(d) }
function keyOf(date) { return dateKey(date.getFullYear(), date.getMonth(), date.getDate()) }

function timeKey(h, min) { return pad2(h) + ":" + pad2(min) }

// "yyyy-MM-dd" or "yyyy-MM-ddTHH:mm" -> local Date (null when malformed).
function parseStamp(text) {
  var m = String(text || "").match(/^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2}))?$/)
  if (!m) return null
  return new Date(+m[1], +m[2] - 1, +m[3], m[4] ? +m[4] : 0, m[5] ? +m[5] : 0, 0, 0)
}

function stampOf(date, allDay) {
  var k = keyOf(date)
  return allDay ? k : k + "T" + timeKey(date.getHours(), date.getMinutes())
}

function addDays(date, n) {
  var d = new Date(date.getTime())
  d.setDate(d.getDate() + n)
  return d
}

function startOfDay(date) { return new Date(date.getFullYear(), date.getMonth(), date.getDate()) }

// Half-open [start, end) span of an event in ms.
function span(ev) {
  var s = parseStamp(ev.start)
  var e = parseStamp(ev.end) || s
  if (!s) return null
  if (ev.allDay) return { start: startOfDay(s).getTime(), end: addDays(startOfDay(e), 1).getTime() }
  var end = e.getTime() > s.getTime() ? e.getTime() : s.getTime() + 1  // zero-length still shows
  return { start: s.getTime(), end: end }
}

function occursOn(ev, key) {
  var sp = span(ev)
  var day = parseStamp(key)
  if (!sp || !day) return false
  var dayStart = day.getTime()
  var dayEnd = addDays(day, 1).getTime()
  return sp.start < dayEnd && sp.end > dayStart
}

function visibleIds(calendars) {
  var out = {}
  for (var i = 0; i < (calendars || []).length; i++)
    if (calendars[i].visible !== false) out[calendars[i].id] = true
  return out
}

function compareEvents(a, b) { return compareWithSpans(a, span(a), b, span(b)) }

function compareWithSpans(a, sa, b, sb) {
  if (!!a.allDay !== !!b.allDay) return a.allDay ? -1 : 1
  var d = (sa ? sa.start : 0) - (sb ? sb.start : 0)
  if (d !== 0) return d
  return String(a.title || "").localeCompare(String(b.title || ""))
}

function eventsForDay(events, calendars, key) {
  var vis = visibleIds(calendars)
  var out = []
  for (var i = 0; i < (events || []).length; i++) {
    var ev = events[i]
    if (vis[ev.calendarId] && occursOn(ev, key)) out.push(ev)
  }
  out.sort(compareEvents)
  return out
}

// ---- Day index --------------------------------------------------------------
// Views ask "what is on day X" many times per change (42 month cells, 7 week
// columns, 60 agenda days). Scanning every event for each of those is slow, so
// the store builds this once per change and views look their day up.
//   -> { byDay: { "yyyy-MM-dd": [ev, ...] }, clipped: n }
// Each day's list holds visible events in eventsForDay order. Event objects are
// shared, never copied or annotated (they get saved back to calendar.json).
var INDEX_MAX_DAYS = 400

function buildIndex(events, calendars) {
  var vis = visibleIds(calendars)
  var items = []
  for (var i = 0; i < (events || []).length; i++) {
    var ev = events[i]
    if (!vis[ev.calendarId]) continue
    var sp = span(ev)
    if (sp) items.push({ ev: ev, sp: sp })
  }
  items.sort(function(a, b) { return compareWithSpans(a.ev, a.sp, b.ev, b.sp) })
  var byDay = {}, clipped = 0
  for (var j = 0; j < items.length; j++) {
    var it = items[j]
    var cursor = startOfDay(new Date(it.sp.start))
    for (var n = 0; cursor.getTime() < it.sp.end; n++) {
      if (n >= INDEX_MAX_DAYS) {
        clipped++
        console.warn("calendar: \"" + (it.ev.title || it.ev.uid) + "\" spans more than " + INDEX_MAX_DAYS + " days; showing the first " + INDEX_MAX_DAYS)
        break
      }
      var key = keyOf(cursor)
      ;(byDay[key] || (byDay[key] = [])).push(it.ev)
      cursor = addDays(cursor, 1)
    }
  }
  return { byDay: byDay, clipped: clipped }
}

var NO_EVENTS = []
function eventsOn(index, key) { return (index && index.byDay[key]) || NO_EVENTS }

// Up to `limit` distinct calendar ids among a day's events, for month dots.
function calendarMarkers(list, limit) {
  var max = limit || 3, out = []
  for (var i = 0; i < list.length && out.length < max; i++)
    if (out.indexOf(list[i].calendarId) === -1) out.push(list[i].calendarId)
  return out
}

// { "yyyy-MM-dd": [calendarId, ...] } for the days in a month grid, at most
// `limit` distinct calendars per day — enough for colored dots under a date.
function markerMap(events, calendars, weeks, limit) {
  var max = limit || 3
  var vis = visibleIds(calendars)
  var first = weeks && weeks.length ? parseStamp(weeks[0].days[0].key) : null
  var lastWeek = weeks && weeks.length ? weeks[weeks.length - 1].days : null
  var last = lastWeek ? addDays(parseStamp(lastWeek[lastWeek.length - 1].key), 1) : null
  var out = {}
  if (!first || !last) return out
  var gridStart = first.getTime(), gridEnd = last.getTime()
  var sorted = (events || []).slice().sort(compareEvents)
  for (var i = 0; i < sorted.length; i++) {
    var ev = sorted[i]
    if (!vis[ev.calendarId]) continue
    var sp = span(ev)
    if (!sp || sp.end <= gridStart || sp.start >= gridEnd) continue
    var cursor = startOfDay(new Date(Math.max(sp.start, gridStart)))
    var guard = 0
    while (cursor.getTime() < Math.min(sp.end, gridEnd) && guard++ < 60) {
      var k = keyOf(cursor)
      var list = out[k] || (out[k] = [])
      if (list.length < max && list.indexOf(ev.calendarId) === -1) list.push(ev.calendarId)
      cursor = addDays(cursor, 1)
    }
  }
  return out
}

// Accepts 14:30, 1430, 9, 9:05, 2pm, 2:30 pm, 12am. Returns {h, m} or null.
function parseTime(text) {
  var t = String(text || "").replace(/\s+/g, "").toLowerCase()
  if (t === "") return null
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

// Accepts yyyy-MM-dd, M/D/yyyy, M/D (current year). Returns Date or null.
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

function formatStampTime(text, use24) {
  var d = parseStamp(text)
  return d ? formatTime(d.getHours(), d.getMinutes(), use24) : ""
}

// Label for an event as seen from a particular day: all-day, a time range,
// or a continuation marker for multi-day timed events.
function timeLabel(ev, key, use24) {
  if (ev.allDay) return "All day"
  var s = parseStamp(ev.start), e = parseStamp(ev.end) || s
  var startsToday = keyOf(s) === key
  var endsToday = keyOf(e) === key || (e.getHours() === 0 && e.getMinutes() === 0 && keyOf(addDays(e, -1)) === key)
  var a = startsToday ? formatTime(s.getHours(), s.getMinutes(), use24) : "…"
  var b = endsToday ? formatTime(e.getHours(), e.getMinutes(), use24) : "…"
  if (startsToday && e.getTime() === s.getTime()) return a
  return a + " – " + b
}

// Build an event record from editor text fields. Returns { event } or { error }.
function buildEvent(form, base, nowIso) {
  var title = String(form.title || "").replace(/^\s+|\s+$/g, "")
  if (title === "") return { error: "Give the event a title" }
  if (!form.calendarId) return { error: "Pick a calendar" }
  var startDate = parseDate(form.startDate)
  if (!startDate) return { error: "Start date not understood (try 2026-10-16 or 10/16)" }
  var endDate = form.endDate && String(form.endDate).replace(/\s+/g, "") !== "" ? parseDate(form.endDate, startDate.getFullYear()) : startDate
  if (!endDate) return { error: "End date not understood" }

  var ev = {}
  for (var k in (base || {})) ev[k] = base[k]
  ev.title = title
  ev.calendarId = form.calendarId
  ev.allDay = !!form.allDay
  ev.location = String(form.location || "")
  ev.notes = String(form.notes || "")

  if (ev.allDay) {
    if (endDate.getTime() < startDate.getTime()) return { error: "End date is before start date" }
    ev.start = stampOf(startDate, true)
    ev.end = stampOf(endDate, true)
  } else {
    var st = parseTime(form.startTime)
    if (!st) return { error: "Start time not understood (try 14:30 or 2:30pm)" }
    var s = new Date(startDate.getFullYear(), startDate.getMonth(), startDate.getDate(), st.h, st.m)
    var e
    var et = String(form.endTime || "").replace(/\s+/g, "") === "" ? null : parseTime(form.endTime)
    if (String(form.endTime || "").replace(/\s+/g, "") !== "" && !et) return { error: "End time not understood" }
    if (et) e = new Date(endDate.getFullYear(), endDate.getMonth(), endDate.getDate(), et.h, et.m)
    else e = new Date(s.getTime() + 3600000)
    // "22:00 – 01:00" on the same date means it runs past midnight.
    if (e.getTime() <= s.getTime() && keyOf(endDate) === keyOf(startDate) && et) e = addDays(e, 1)
    if (e.getTime() < s.getTime()) return { error: "End is before start" }
    ev.start = stampOf(s, false)
    ev.end = stampOf(e, false)
  }
  if (!ev.uid) { ev.uid = newId("ev"); ev.created = nowIso }
  ev.updated = nowIso
  return { event: ev }
}

// Inverse of buildEvent: editor field text for an existing event.
function formFor(ev, use24) {
  var s = parseStamp(ev.start), e = parseStamp(ev.end) || s
  return {
    title: ev.title || "",
    calendarId: ev.calendarId || "",
    allDay: !!ev.allDay,
    startDate: keyOf(s),
    endDate: keyOf(e),
    startTime: ev.allDay ? "" : formatTime(s.getHours(), s.getMinutes(), use24),
    endTime: ev.allDay ? "" : formatTime(e.getHours(), e.getMinutes(), use24),
    location: ev.location || "",
    notes: ev.notes || "",
    rrule: ev.rrule || ""
  }
}

// Sensible starting point for a new event on `key`: the next whole hour if
// the day is today, otherwise 9:00, one hour long.
function newForm(key, calendarId, now, use24) {
  var h = 9
  if (now && keyOf(now) === key) h = Math.min(23, now.getHours() + 1)
  return {
    title: "", calendarId: calendarId || "", allDay: false,
    startDate: key, endDate: key,
    startTime: formatTime(h, 0, use24), endTime: formatTime(Math.min(23, h + 1), h >= 23 ? 59 : 0, use24),
    location: "", notes: "", rrule: ""
  }
}

function newId(prefix) {
  return (prefix || "id") + "-" + Date.now().toString(36) + "-" + Math.floor(Math.random() * 0xffffff).toString(36)
}

function emptyData() {
  return { version: 1, calendars: [], events: [] }
}

// Coerce whatever was on disk into the expected shape without dropping
// anything we do not understand (future sync metadata rides along).
function normalize(data) {
  var d = data && typeof data === "object" ? data : {}
  var out = {}
  for (var k in d) out[k] = d[k]
  out.version = 1
  out.calendars = Array.isArray(d.calendars) ? d.calendars.filter(function(c) { return c && c.id }) : []
  out.events = Array.isArray(d.events) ? d.events.filter(function(e) { return e && e.uid && parseStamp(e.start) }) : []
  return out
}


// ---- View helpers ---------------------------------------------------------

function addDaysKey(key, n) {
  var d = parseStamp(key)
  return d ? keyOf(addDays(d, n)) : key
}

// First day of the week containing `key`, for weekStart 0 (Sun) .. 6 (Sat).
function weekStartKey(key, weekStart) {
  var d = parseStamp(key)
  if (!d) return key
  var back = (d.getDay() - (weekStart || 0) + 7) % 7
  return keyOf(addDays(d, -back))
}

// All-day events (and timed events covering the whole day) for a day lane.
function allDayFor(events, calendars, key) { return allDayIn(eventsForDay(events, calendars, key), key) }

// Same, from one day's list (see eventsOn).
function allDayIn(list, key) {
  return list.filter(function(ev) {
    if (ev.allDay) return true
    var sp = span(ev), day = parseStamp(key).getTime()
    return sp.start <= day && sp.end >= addDays(parseStamp(key), 1).getTime()
  })
}

// Timed events for one day laid out in side-by-side columns where they
// overlap, Google/Apple style. Minutes are clipped to the day, so an event
// running past midnight shows on both days.
//   -> [{ ev, start, end, col, cols }]   (start/end in minutes 0..1440)
function layoutDay(events, calendars, key, minMinutes) {
  return layoutList(eventsForDay(events, calendars, key), key, minMinutes)
}

// Same, from one day's list (see eventsOn).
function layoutList(list, key, minMinutes) {
  var day = parseStamp(key)
  if (!day) return []
  var dayStart = day.getTime(), dayEnd = addDays(day, 1).getTime()
  var minLen = minMinutes || 20
  var items = []
  for (var i = 0; i < list.length; i++) {
    var ev = list[i]
    if (ev.allDay) continue
    var sp = span(ev)
    if (sp.start <= dayStart && sp.end >= dayEnd) continue   // whole day: all-day lane
    if (sp.end - sp.start >= MS_PER_DAY) continue            // a day or longer: a bar in the lane
    var s = Math.max(0, Math.round((sp.start - dayStart) / 60000))
    var e = Math.min(1440, Math.round((sp.end - dayStart) / 60000))
    if (e - s < minLen) e = Math.min(1440, s + minLen)
    if (e - s < minLen) s = Math.max(0, e - minLen)
    items.push({ ev: ev, start: s, end: e, col: 0, cols: 1 })
  }
  items.sort(function(a, b) { return a.start - b.start || (b.end - b.start) - (a.end - a.start) })

  var cluster = [], colEnds = [], clusterEnd = -1
  function flush() {
    for (var k = 0; k < cluster.length; k++) cluster[k].cols = colEnds.length
    cluster = []; colEnds = []; clusterEnd = -1
  }
  for (var j = 0; j < items.length; j++) {
    var it = items[j]
    if (cluster.length && it.start >= clusterEnd) flush()
    var placed = false
    for (var c = 0; c < colEnds.length; c++) {
      if (colEnds[c] <= it.start) { it.col = c; colEnds[c] = it.end; placed = true; break }
    }
    if (!placed) { it.col = colEnds.length; colEnds.push(it.end) }
    cluster.push(it)
    clusterEnd = Math.max(clusterEnd, it.end)
  }
  flush()
  return items
}

// Upcoming days that have something on them, starting at `fromKey`.
//   -> [{ key, events }]
function agenda(events, calendars, fromKey, days) {
  var out = []
  var n = days || 30
  for (var i = 0; i < n; i++) {
    var key = addDaysKey(fromKey, i)
    var list = eventsForDay(events, calendars, key)
    if (list.length) out.push({ key: key, events: list })
  }
  return out
}

// Same, from the day index.
function agendaFrom(index, fromKey, days) {
  var out = []
  var n = days || 30
  for (var i = 0; i < n; i++) {
    var key = addDaysKey(fromKey, i)
    var list = eventsOn(index, key)
    if (list.length) out.push({ key: key, events: list })
  }
  return out
}


// Compact time for chips: "14:30" / "9a" / "9:30p".
function shortTime(text, use24) {
  var d = parseStamp(text)
  if (!d) return ""
  var h = d.getHours(), m = d.getMinutes()
  if (use24) return timeKey(h, m)
  var hh = h % 12 === 0 ? 12 : h % 12
  return hh + (m ? ":" + pad2(m) : "") + (h >= 12 ? "p" : "a")
}

// Hour label for a time grid gutter.
function hourLabel(h, use24) {
  if (use24) return pad2(h) + ":00"
  if (h === 0) return "12 AM"
  if (h === 12) return "Noon"
  return (h % 12) + (h < 12 ? " AM" : " PM")
}


var MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
var DAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

// Same day-of-month n months away, clamped (Jan 31 + 1 month = Feb 28/29).
function addMonthsKey(key, n) {
  var d = parseStamp(key)
  if (!d) return key
  var target = new Date(d.getFullYear(), d.getMonth() + n, 1)
  var last = new Date(target.getFullYear(), target.getMonth() + 1, 0).getDate()
  target.setDate(Math.min(d.getDate(), last))
  return keyOf(target)
}

// Where prev/next goes from `key` in each view.
function stepKey(view, key, delta) {
  if (view === "year") return addMonthsKey(key, 12 * delta)
  if (view === "month") return addMonthsKey(key, delta)
  if (view === "week" || view === "agenda") return addDaysKey(key, 7 * delta)
  return addDaysKey(key, delta)
}

function periodTitle(view, key, weekStart) {
  var d = parseStamp(key)
  if (!d) return ""
  if (view === "year") return String(d.getFullYear())
  if (view === "month") return MONTHS[d.getMonth()] + " " + d.getFullYear()
  if (view === "day") return DAYS[d.getDay()] + ", " + MONTHS[d.getMonth()] + " " + d.getDate()
  if (view === "agenda") return "From " + MONTHS[d.getMonth()].substr(0, 3) + " " + d.getDate()
  var a = parseStamp(weekStartKey(key, weekStart)), b = addDays(a, 6)
  var left = MONTHS[a.getMonth()].substr(0, 3) + " " + a.getDate()
  var right = (a.getMonth() === b.getMonth() ? "" : MONTHS[b.getMonth()].substr(0, 3) + " ") + b.getDate()
  return left + " – " + right + ", " + b.getFullYear()
}


// ---- Hidden events ---------------------------------------------------------
// Hiding is a local overlay on synced calendars: nothing changes on the
// server. Entries match by the event's stable identity, which survives
// re-syncs: one occurrence (its instance uid, "<UID>@<start>" for repeats)
// or a whole series (its source UID).
//   { calendarId, uid, sourceUid, series, title, start, end, allDay, recurring, hiddenAt }

function seriesUid(ev) { return ev.sourceUid || ev.uid }

function hiddenKey(entry) {
  return entry.series ? entry.calendarId + "|*|" + entry.sourceUid : entry.calendarId + "|" + entry.uid
}

function hiddenIndex(hidden) {
  var map = {}
  for (var i = 0; i < (hidden || []).length; i++) map[hiddenKey(hidden[i])] = true
  return map
}

function isHidden(index, ev) {
  return !!(index[ev.calendarId + "|" + ev.uid] || index[ev.calendarId + "|*|" + seriesUid(ev)])
}

function withoutHidden(events, hidden) {
  if (!hidden || hidden.length === 0) return events
  var index = hiddenIndex(hidden)
  return events.filter(function(ev) { return !isHidden(index, ev) })
}

function hideEntry(ev, series, nowIso) {
  return {
    calendarId: ev.calendarId, uid: series ? "" : ev.uid, sourceUid: seriesUid(ev), series: !!series,
    title: ev.title || "", start: ev.start, end: ev.end, allDay: !!ev.allDay, recurring: !!ev.recurring,
    hiddenAt: nowIso || ""
  }
}

// Does anything in `events` still match this entry? (It may have been
// deleted or cancelled at the source since it was hidden.)
function hiddenStillPresent(entry, events) {
  for (var i = 0; i < events.length; i++) {
    var ev = events[i]
    if (ev.calendarId !== entry.calendarId) continue
    if (entry.series ? seriesUid(ev) === entry.sourceUid : ev.uid === entry.uid) return true
  }
  return false
}

// Every key a hidden entry could match in `events` (both the one-occurrence
// and whole-series forms). Build once, then look entries up with
// presentKeys[hiddenKey(entry)] instead of scanning per entry.
function presentKeys(events) {
  var out = {}
  for (var i = 0; i < (events || []).length; i++) {
    var ev = events[i]
    out[ev.calendarId + "|" + ev.uid] = true
    out[ev.calendarId + "|*|" + seriesUid(ev)] = true
  }
  return out
}

// ---- Repeating local events ----------------------------------------------
// Occurrence keys match the sync helper's (ical._norm_key): UTC
// "yyyyMMddTHHmmss" for timed events, "yyyyMMdd" for all-day ones, so an
// occurrence keeps its identity whichever side expanded it.

function occurrenceKeyUtc(utcMs) {
  var d = new Date(utcMs)
  return d.getUTCFullYear() + pad2(d.getUTCMonth() + 1) + pad2(d.getUTCDate()) + "T"
    + pad2(d.getUTCHours()) + pad2(d.getUTCMinutes()) + pad2(d.getUTCSeconds())
}

function occurrenceKeyDate(stamp) { return String(stamp).substr(0, 10).replace(/-/g, "") }

// Key of an occurrence that starts at local stamp `start`.
function occurrenceKey(start, allDay) {
  return allDay ? occurrenceKeyDate(start) : occurrenceKeyUtc(parseStamp(start).getTime())
}

function localStampOfMs(ms) { return stampOf(new Date(ms), false) }

// Local wall ms (Date.UTC of local fields) for a real instant, and back.
function localWallOf(utcMs) {
  var d = new Date(utcMs)
  return Date.UTC(d.getFullYear(), d.getMonth(), d.getDate(), d.getHours(), d.getMinutes())
}
function localFromWall(wallMs) {
  var d = new Date(wallMs)
  return new Date(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate(), d.getUTCHours(), d.getUTCMinutes()).getTime()
}

var SERIES_FIELDS = { rrule: 1, exdates: 1, overrides: 1 }

// Occurrences of one stored series overlapping [fromMs, toMs).
//   Recur, Tz: the modules; table: the series' zone table (null = local).
function expandSeries(master, Recur, Tz, table, fromMs, toMs) {
  var out = []
  var s = parseStamp(master.start), e = parseStamp(master.end) || s
  if (!s || !master.rrule) return out
  var allDay = !!master.allDay
  var toWall, fromWall, startWall, lenMs
  if (allDay) {
    toWall = function(utc) { return localWallOf(utc) }
    fromWall = function(w) { return localFromWall(w) }
    startWall = Date.UTC(s.getFullYear(), s.getMonth(), s.getDate())
    lenMs = Math.round((startOfDay(e).getTime() - startOfDay(s).getTime()) / MS_PER_DAY) * MS_PER_DAY
  } else if (table) {
    toWall = function(utc) { return Tz.utcToWall(table, utc) }
    fromWall = function(w) { return Tz.wallToUtc(table, w) }
    startWall = toWall(s.getTime())
    lenMs = Math.max(0, e.getTime() - s.getTime())
  } else {
    toWall = localWallOf
    fromWall = localFromWall
    startWall = localWallOf(s.getTime())
    lenMs = Math.max(0, e.getTime() - s.getTime())
  }
  var ex = {}
  for (var i = 0; i < (master.exdates || []).length; i++) ex[master.exdates[i]] = true
  var overrides = master.overrides || {}
  var pad = (allDay ? lenMs + MS_PER_DAY : lenMs) + MS_PER_DAY
  var starts = Recur.expand(startWall, allDay, master.rrule, toWall(toMs) + MS_PER_DAY,
                            { windowStart: toWall(fromMs) - pad, toWall: toWall })
  var base = {}
  for (var k in master) if (!SERIES_FIELDS[k]) base[k] = master[k]
  for (var j = 0; j < starts.length; j++) {
    var w = starts[j]
    var occ = {}
    for (var b in base) occ[b] = base[b]
    var key
    if (allDay) {
      var sd = new Date(w), ed = new Date(w + lenMs)
      occ.start = dateKey(sd.getUTCFullYear(), sd.getUTCMonth(), sd.getUTCDate())
      occ.end = dateKey(ed.getUTCFullYear(), ed.getUTCMonth(), ed.getUTCDate())
      key = occurrenceKeyDate(occ.start)
    } else {
      var utc = fromWall(w)
      occ.start = localStampOfMs(utc)
      occ.end = localStampOfMs(utc + lenMs)
      key = occurrenceKeyUtc(utc)
    }
    if (ex[key]) continue
    var ov = overrides[key]
    if (ov) {
      if (ov.cancelled) continue
      for (var f in ov) occ[f] = ov[f]
    }
    occ.uid = master.uid + "@" + key
    occ.sourceUid = master.uid
    occ.recurrenceId = key
    occ.recurring = true
    occ.rrule = master.rrule
    var sp = span(occ)
    if (sp && sp.start < toMs && sp.end > fromMs) out.push(occ)
  }
  return out
}

// Stored local events -> what the views show: plain events as they are,
// series expanded inside [fromMs, toMs). zoneTable(name) -> table or null.
function expandAll(events, Recur, Tz, zoneTable, fromMs, toMs) {
  var out = []
  for (var i = 0; i < (events || []).length; i++) {
    var ev = events[i]
    if (!ev.rrule) { out.push(ev); continue }
    var table = ev.tz && zoneTable ? zoneTable(ev.tz) : null
    out = out.concat(expandSeries(ev, Recur, Tz, table, fromMs, toMs))
  }
  return out
}

// ---- Editing local series (mirrors sync/series.py) -------------------------
// `occ` is an occurrence as the views show it (uid "<series>@<key>",
// recurrenceId = key); `edited` is that occurrence after the user changed
// it (local start/end stamps, title, ..., rrule). Each function returns new
// records and never mutates its inputs.

var OCCURRENCE_FIELDS = ["start", "end", "allDay", "title", "location", "notes", "tz"]

function copyRecord(r) { var o = {}; for (var k in r) o[k] = r[k]; return o }

function keyInstant(key) {
  var m = String(key).match(/^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2}))?$/)
  if (!m) return null
  return m[4] ? Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6]) : Date.UTC(+m[1], +m[2] - 1, +m[3])
}

function seriesKey(master) { return occurrenceKey(master.start, !!master.allDay) }

function seriesEditThis(master, key, edited) {
  var out = copyRecord(master)
  var ov = {}
  for (var i = 0; i < OCCURRENCE_FIELDS.length; i++) {
    var f = OCCURRENCE_FIELDS[i]
    if (edited[f] !== undefined) ov[f] = edited[f]
  }
  var overrides = copyRecord(master.overrides || {})
  overrides[key] = ov
  out.overrides = overrides
  out.updated = edited.updated || out.updated
  return out
}

function seriesDeleteThis(master, key) {
  var out = copyRecord(master)
  out.exdates = (master.exdates || []).filter(function(k) { return k !== key }).concat([key])
  if (master.overrides && master.overrides[key]) {
    var overrides = copyRecord(master.overrides)
    delete overrides[key]
    out.overrides = overrides
  }
  return out
}

// End the series before occurrence `key`. -> { master: record or null when
// nothing is left, countLeft: what remained of a COUNT, else null }
function seriesEndBefore(master, key, Recur) {
  if (key <= seriesKey(master)) return { master: null, countLeft: null }
  var rule = Recur.parseRule(master.rrule)
  var countLeft = null
  var allDay = !!master.allDay
  if (/^\d+$/.test(rule.COUNT || "")) {
    var before = 0
    var s = parseStamp(master.start)
    var startWall = allDay ? Date.UTC(s.getFullYear(), s.getMonth(), s.getDate()) : localWallOf(s.getTime())
    var target = keyInstant(key)
    var targetWall = allDay ? target : localWallOf(target)
    var starts = Recur.expand(startWall, allDay, master.rrule, targetWall + MS_PER_DAY, { toWall: localWallOf })
    for (var i = 0; i < starts.length && starts[i] < targetWall; i++) before++
    countLeft = Math.max(0, parseInt(rule.COUNT, 10) - before)
    delete rule.COUNT
  }
  var inst = keyInstant(key)
  if (allDay) {
    var d = new Date(inst - MS_PER_DAY)
    rule.UNTIL = String(d.getUTCFullYear()) + pad2(d.getUTCMonth() + 1) + pad2(d.getUTCDate())
  } else rule.UNTIL = occurrenceKeyUtc(inst - 1000) + "Z"
  var out = copyRecord(master)
  out.rrule = Recur.formatRule(rule)
  out.exdates = (master.exdates || []).filter(function(k) { return k < key })
  var overrides = {}
  for (var ok in (master.overrides || {})) if (ok < key) overrides[ok] = master.overrides[ok]
  out.overrides = overrides
  return { master: out, countLeft: countLeft }
}

// "This and following": -> { old: record or null, fresh: new series record }
function seriesSplit(master, key, edited, newUid, Recur) {
  var ended = seriesEndBefore(master, key, Recur)
  var ruleText = edited.rrule !== undefined ? edited.rrule : master.rrule
  var fresh = copyRecord(edited)
  delete fresh.recurring; delete fresh.recurrenceId; delete fresh.sourceUid
  fresh.uid = newUid
  fresh.calendarId = edited.calendarId || master.calendarId
  delete fresh.exdates; delete fresh.overrides
  if (ruleText) {
    var rule = Recur.parseRule(ruleText)
    if (ended.countLeft !== null && !rule.UNTIL) rule.COUNT = String(Math.max(1, ended.countLeft))
    fresh.rrule = Recur.formatRule(rule)
  } else delete fresh.rrule
  return { old: ended.master, fresh: fresh }
}

// The whole series. Occurrences move by the wall-clock change made to the
// edited occurrence (in the series' zone); exceptions and changed
// occurrences follow, unless the pattern itself changed.
//   tables(zone) -> offset table or null (machine zone)
function seriesEditAll(master, key, edited, Recur, Tz, tables) {
  var out = copyRecord(master)
  for (var i = 0; i < OCCURRENCE_FIELDS.length; i++) {
    var f = OCCURRENCE_FIELDS[i]
    if (f !== "start" && f !== "end" && edited[f] !== undefined) out[f] = edited[f]
  }
  if (edited.calendarId) out.calendarId = edited.calendarId
  if (edited.tz === undefined || edited.tz === "") delete out.tz
  out.updated = edited.updated || out.updated
  var newRule = edited.rrule !== undefined ? edited.rrule : master.rrule
  var allDay = !!edited.allDay, wasAllDay = !!master.allDay
  var patternChanged = Recur.formatRule(Recur.parseRule(newRule)) !== Recur.formatRule(Recur.parseRule(master.rrule)) || allDay !== wasAllDay
  var shiftKey = null   // key -> key for exceptions/overrides, or null to drop them
  var es = parseStamp(edited.start), ee = parseStamp(edited.end) || es
  if (allDay || wasAllDay) {
    var oldOcc = wasAllDay ? keyInstant(key) : localWallOf(keyInstant(key)) - localWallOf(keyInstant(key)) % MS_PER_DAY
    var newOcc = Date.UTC(es.getFullYear(), es.getMonth(), es.getDate())
    var ms = parseStamp(master.start)
    var newMaster = Date.UTC(ms.getFullYear(), ms.getMonth(), ms.getDate()) + (newOcc - oldOcc)
    var nm = new Date(newMaster)
    var startDay = new Date(nm.getUTCFullYear(), nm.getUTCMonth(), nm.getUTCDate())
    if (allDay) {
      var lenDays = Math.round((startOfDay(ee).getTime() - startOfDay(es).getTime()) / MS_PER_DAY)
      out.start = keyOf(startDay)
      out.end = keyOf(addDays(startDay, lenDays))
    } else {
      var st = new Date(startDay.getFullYear(), startDay.getMonth(), startDay.getDate(), es.getHours(), es.getMinutes())
      out.start = stampOf(st, false)
      out.end = stampOf(new Date(st.getTime() + (ee.getTime() - es.getTime())), false)
    }
    out.allDay = allDay
    if (allDay && wasAllDay) {
      var dayShift = newOcc - oldOcc
      shiftKey = function(k) { var d = new Date(keyInstant(k) + dayShift); return String(d.getUTCFullYear()) + pad2(d.getUTCMonth() + 1) + pad2(d.getUTCDate()) }
    }
  } else {
    var oldZone = master.tz || "", newZone = edited.tz || ""
    var tOld = oldZone ? tables(oldZone) : null, tNew = newZone ? tables(newZone) : null
    var toWallOld = function(u) { return tOld ? Tz.utcToWall(tOld, u) : localWallOf(u) }
    var toWallNew = function(u) { return tNew ? Tz.utcToWall(tNew, u) : localWallOf(u) }
    var fromWallNew = function(w) { return tNew ? Tz.wallToUtc(tNew, w) : localFromWall(w) }
    var fromWallOld = function(w) { return tOld ? Tz.wallToUtc(tOld, w) : localFromWall(w) }
    var oldOccWall = toWallOld(keyInstant(key))
    var oldMasterWall = toWallOld(parseStamp(master.start).getTime())
    var newOccWall = toWallNew(es.getTime())
    var newMasterUtc = fromWallNew(newOccWall - (oldOccWall - oldMasterWall))
    out.start = stampOf(new Date(newMasterUtc), false)
    out.end = stampOf(new Date(newMasterUtc + (ee.getTime() - es.getTime())), false)
    if (newZone) out.tz = newZone
    if (oldZone === newZone) {
      var wallShift = newOccWall - oldOccWall
      shiftKey = function(k) { return occurrenceKeyUtc(fromWallOld(toWallOld(keyInstant(k)) + wallShift)) }
    }
  }
  out.rrule = newRule
  if (patternChanged || !shiftKey) { delete out.exdates; delete out.overrides }
  else {
    out.exdates = (master.exdates || []).map(shiftKey)
    var overrides = {}
    for (var k in (master.overrides || {})) overrides[shiftKey(k)] = master.overrides[k]
    out.overrides = overrides
  }
  if (!newRule) { delete out.rrule; delete out.exdates; delete out.overrides }
  return out
}

// ---- Spanning bars (all-day lanes, month rows) -------------------------------
// Multi-day events read best as one bar across the days they cover, like
// every calendar app draws them.

// Last day an event covers (its end is exclusive for timed events).
function lastDayKey(ev) {
  var sp = span(ev)
  if (!sp) return ""
  return keyOf(new Date(Math.max(sp.start, sp.end - 1)))
}

// Bars in the all-day lane of a time grid: all-day events and timed events
// lasting a day or more (shorter ones go in the hour columns).
function isLaneEvent(ev) {
  if (ev.allDay) return true
  var sp = span(ev)
  return !!sp && sp.end - sp.start >= MS_PER_DAY
}

// Bars in a month row: anything all-day or covering more than one date.
function isMultiDay(ev) {
  if (ev.allDay) return true
  var sp = span(ev)
  return !!sp && keyOf(new Date(sp.start)) !== lastDayKey(ev)
}

// Lay out bars over consecutive days.
//   lists: each day's events (eventsOn order), keys: the days' keys,
//   pick(ev): which events become bars.
//   -> { bars: [{ ev, first, last, row, cutStart, cutEnd }], rows, perDay: [n bars per day] }
// first/last are day indexes; cutStart/cutEnd mark bars running past the row.
function layoutBars(lists, keys, pick) {
  var seen = {}, items = []
  for (var d = 0; d < lists.length; d++) {
    var list = lists[d] || []
    for (var i = 0; i < list.length; i++) {
      var ev = list[i]
      if (seen[ev.uid + "|" + ev.calendarId] || !pick(ev)) continue
      seen[ev.uid + "|" + ev.calendarId] = true
      var firstKey = keyOf(new Date(span(ev).start)), lastKey = lastDayKey(ev)
      var first = keys.indexOf(firstKey), last = keys.indexOf(lastKey)
      items.push({ ev: ev, first: first === -1 ? (firstKey < keys[0] ? 0 : d) : first,
                   last: last === -1 ? (lastKey > keys[keys.length - 1] ? keys.length - 1 : d) : last,
                   cutStart: firstKey < keys[0], cutEnd: lastKey > keys[keys.length - 1] })
    }
  }
  // Earlier first, then longer, so long bars sit on top and short ones fill gaps.
  items.sort(function(a, b) {
    return a.first - b.first || (b.last - b.first) - (a.last - a.first) || compareEvents(a.ev, b.ev)
  })
  var rowsUsed = []   // rowsUsed[row][day] = true
  var perDay = keys.map(function() { return 0 })
  for (var j = 0; j < items.length; j++) {
    var it = items[j], row = 0
    for (;; row++) {
      var free = true
      if (!rowsUsed[row]) rowsUsed[row] = []
      for (var c = it.first; c <= it.last; c++) if (rowsUsed[row][c]) { free = false; break }
      if (free) break
    }
    for (var c2 = it.first; c2 <= it.last; c2++) { rowsUsed[row][c2] = true; perDay[c2]++ }
    it.row = row
  }
  return { bars: items, rows: rowsUsed.length, perDay: perDay }
}

// ---- Moving by drag ----------------------------------------------------------

// The event moved so it starts at `startStamp`, keeping its length. A
// date-only stamp on a timed event keeps the time of day (dragging across
// days in month view).
function moved(ev, startStamp) {
  var out = {}
  for (var k in ev) out[k] = ev[k]
  var s = parseStamp(ev.start), e = parseStamp(ev.end) || s
  var ns = parseStamp(startStamp)
  if (!s || !ns) return out
  if (ev.allDay) {
    var days = Math.round((startOfDay(ns).getTime() - startOfDay(s).getTime()) / MS_PER_DAY)
    out.start = keyOf(addDays(s, days))
    out.end = keyOf(addDays(e, days))
    return out
  }
  if (String(startStamp).length <= 10) ns = new Date(ns.getFullYear(), ns.getMonth(), ns.getDate(), s.getHours(), s.getMinutes())
  var len = e.getTime() - s.getTime()
  out.start = stampOf(ns, false)
  out.end = stampOf(new Date(ns.getTime() + len), false)
  return out
}

// Shift by whole days (month view, all-day lane).
function movedByDays(ev, days) {
  var s = parseStamp(ev.start)
  return moved(ev, ev.allDay ? keyOf(addDays(s, days)) : stampOf(addDays(s, days), false))
}

function resized(ev, endStamp) {
  var out = {}
  for (var k in ev) out[k] = ev[k]
  out.end = endStamp
  return out
}

if (typeof module !== "undefined") {
  module.exports = {
    dateKey: dateKey, keyOf: keyOf, parseStamp: parseStamp, stampOf: stampOf, span: span,
    occursOn: occursOn, eventsForDay: eventsForDay, markerMap: markerMap, parseTime: parseTime,
    parseDate: parseDate, formatTime: formatTime, formatStampTime: formatStampTime,
    timeLabel: timeLabel, buildEvent: buildEvent, formFor: formFor, newForm: newForm,
    newId: newId, emptyData: emptyData, normalize: normalize, compareEvents: compareEvents,
    buildIndex: buildIndex, eventsOn: eventsOn, calendarMarkers: calendarMarkers, allDayIn: allDayIn,
    layoutList: layoutList, agendaFrom: agendaFrom,
    addDaysKey: addDaysKey, weekStartKey: weekStartKey, allDayFor: allDayFor, layoutDay: layoutDay, agenda: agenda, shortTime: shortTime, hourLabel: hourLabel,
    addMonthsKey: addMonthsKey, stepKey: stepKey, periodTitle: periodTitle,
    hiddenKey: hiddenKey, hiddenIndex: hiddenIndex, isHidden: isHidden, withoutHidden: withoutHidden,
    hideEntry: hideEntry, hiddenStillPresent: hiddenStillPresent, presentKeys: presentKeys,
    occurrenceKey: occurrenceKey, occurrenceKeyUtc: occurrenceKeyUtc, expandSeries: expandSeries, expandAll: expandAll,
    seriesEditThis: seriesEditThis, seriesDeleteThis: seriesDeleteThis, seriesEndBefore: seriesEndBefore,
    seriesSplit: seriesSplit, seriesEditAll: seriesEditAll, keyInstant: keyInstant,
    lastDayKey: lastDayKey, isLaneEvent: isLaneEvent, isMultiDay: isMultiDay, layoutBars: layoutBars,
    moved: moved, movedByDays: movedByDays, resized: resized
  }
}
