// Recurrence rules (RFC 5545 RRULE) in pure JS, a port of
// sync/ical.py expand_rrule so local repeating events expand exactly like
// synced ones (tests/test_recur.py checks the two against each other).
//
// Everything here works on naive "wall" times: Date.UTC-based milliseconds
// of the wall clock in the event's own zone. Callers convert to and from real
// instants (see Tz.js), which keeps a 9:00 meeting at 9:00 across DST.

var DAY_MS = 86400000
var WEEKDAYS = ["MO", "TU", "WE", "TH", "FR", "SA", "SU"]   // Monday = 0

function dayNumber(ms) { return Math.floor(ms / DAY_MS) }
function weekday(dn) { return ((dn % 7) + 7 + 3) % 7 }      // 1970-01-01 was a Thursday
function ymd(dn) { var d = new Date(dn * DAY_MS); return { y: d.getUTCFullYear(), m: d.getUTCMonth() + 1, d: d.getUTCDate() } }
function dnOf(y, m, d) { return Math.floor(Date.UTC(y, m - 1, d) / DAY_MS) }
function daysInMonth(y, m) { return new Date(Date.UTC(y, m, 0)).getUTCDate() }
function isLeap(y) { return (y % 4 === 0 && y % 100 !== 0) || y % 400 === 0 }

function parseRule(text) {
  var rule = {}
  String(text || "").replace(/^RRULE:/i, "").split(";").forEach(function(part) {
    var i = part.indexOf("=")
    if (i > 0) rule[part.substr(0, i).toUpperCase()] = part.substr(i + 1)
  })
  return rule
}

function formatRule(rule) {
  var order = ["FREQ", "INTERVAL", "COUNT", "UNTIL", "BYMONTH", "BYMONTHDAY", "BYDAY", "BYSETPOS", "WKST"]
  var out = []
  order.forEach(function(k) { if (rule[k] !== undefined && rule[k] !== "") out.push(k + "=" + rule[k]) })
  for (var k in rule) if (order.indexOf(k) === -1 && rule[k] !== undefined && rule[k] !== "") out.push(k + "=" + rule[k])
  return out.join(";")
}

function parseByday(value) {
  var out = []
  String(value || "").split(",").forEach(function(item) {
    var m = item.trim().toUpperCase().match(/^([+-]?\d+)?(MO|TU|WE|TH|FR|SA|SU)$/)
    if (m) out.push({ n: m[1] ? parseInt(m[1], 10) : null, wd: WEEKDAYS.indexOf(m[2]) })
  })
  return out
}

function parseInts(value) {
  var out = []
  String(value || "").split(",").forEach(function(x) {
    x = x.trim()
    if (/^[+-]?\d+$/.test(x)) out.push(parseInt(x, 10))
  })
  return out
}

function monthDays(y, m) {
  var first = dnOf(y, m, 1), n = daysInMonth(y, m), out = []
  for (var i = 0; i < n; i++) out.push(first + i)
  return out
}

function applyMonthday(days, bymonthday) {
  return days.filter(function(dn) {
    var p = ymd(dn), n = daysInMonth(p.y, p.m)
    return bymonthday.indexOf(p.d) !== -1 || bymonthday.indexOf(p.d - n - 1) !== -1
  })
}

function matchingByday(byday, scope) {
  var out = {}
  byday.forEach(function(b) {
    var matches = scope.filter(function(dn) { return weekday(dn) === b.wd })
    if (b.n === null) matches.forEach(function(dn) { out[dn] = true })
    else if (matches.length && b.n !== 0 && b.n >= -matches.length && b.n <= matches.length)
      out[b.n > 0 ? matches[b.n - 1] : matches[matches.length + b.n]] = true
  })
  return out
}

function setpos(cands, bysetpos) {
  if (!bysetpos.length) return cands
  var seen = {}, out = []
  bysetpos.forEach(function(pos) {
    var v = null
    if (pos > 0 && pos <= cands.length) v = cands[pos - 1]
    else if (pos < 0 && pos >= -cands.length) v = cands[cands.length + pos]
    if (v !== null && !seen[v]) { seen[v] = true; out.push(v) }
  })
  return out.sort(function(a, b) { return a - b })
}

// "20261231" / "20261231T235959Z" / "20261231T235959" -> { wall?: ms, utc?: ms, date: bool }
function parseUntil(text) {
  var m = String(text || "").match(/^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})?(Z?))?$/)
  if (!m) return null
  var ms = Date.UTC(+m[1], +m[2] - 1, +m[3], m[4] ? +m[4] : 0, m[5] ? +m[5] : 0, m[6] ? +m[6] : 0)
  if (!m[4]) return { date: true, wall: ms }
  return m[7] ? { date: false, utc: ms } : { date: false, wall: ms }
}

// Occurrence starts (wall ms) of a rule, up to windowEnd (wall ms), in order.
//   startWall: DTSTART as wall ms; isDate: all-day.
//   opts.windowStart (wall ms): lets a rule without COUNT jump to the window.
//   opts.toWall(utcMs): converts a UTC UNTIL to wall time in the event's zone.
//   opts.limit: periods walked from the window on (default 2000).
function expand(startWall, isDate, ruleText, windowEnd, opts) {
  opts = opts || {}
  var rule = typeof ruleText === "string" ? parseRule(ruleText) : (ruleText || {})
  var freq = String(rule.FREQ || "").toUpperCase()
  if (["DAILY", "WEEKLY", "MONTHLY", "YEARLY"].indexOf(freq) === -1) return [startWall]
  var interval = Math.max(1, parseInt(rule.INTERVAL || "1", 10) || 1)
  var count = /^\d+$/.test(rule.COUNT || "") ? parseInt(rule.COUNT, 10) : null
  var limit = opts.limit || 2000
  var startDay = dayNumber(startWall)
  var tod = isDate ? 0 : startWall - startDay * DAY_MS

  var until = null   // wall ms (timed) or day number (date)
  if (rule.UNTIL) {
    var u = parseUntil(rule.UNTIL)
    if (u) {
      if (isDate) until = dayNumber(u.wall !== undefined ? u.wall : u.utc)
      else if (u.date) until = u.wall + DAY_MS - 1
      else until = u.wall !== undefined ? u.wall : (opts.toWall ? opts.toWall(u.utc) : u.utc)
    }
  }
  var byday = rule.BYDAY ? parseByday(rule.BYDAY) : []
  var bymonth = rule.BYMONTH ? parseInts(rule.BYMONTH) : []
  var bymonthday = rule.BYMONTHDAY ? parseInts(rule.BYMONTHDAY) : []
  var bysetpos = rule.BYSETPOS ? parseInts(rule.BYSETPOS) : []
  var wkstName = String(rule.WKST || "MO").toUpperCase()
  var wkst = WEEKDAYS.indexOf(wkstName) !== -1 ? WEEKDAYS.indexOf(wkstName) : 0

  var endDay = dayNumber(windowEnd)
  if (until !== null) endDay = Math.min(endDay, isDate ? until : dayNumber(until))

  var out = [], produced = 0, periods = 0, walked = 0
  var cursor = startDay
  var wday = opts.windowStart !== undefined && opts.windowStart !== null ? dayNumber(opts.windowStart) : null
  var s = ymd(startDay)
  if (count === null && wday !== null && wday > startDay) {
    var w = ymd(wday)
    if (freq === "DAILY") cursor = startDay + Math.floor((wday - startDay) / interval) * interval
    else if (freq === "WEEKLY") {
      var firstWeek = startDay - ((weekday(startDay) - wkst + 7) % 7)
      cursor = firstWeek + Math.floor((wday - firstWeek) / 7 / interval) * interval * 7
    } else if (freq === "MONTHLY") {
      var months = Math.floor(((w.y - s.y) * 12 + w.m - s.m) / interval) * interval
      var m0 = s.m - 1 + months
      cursor = dnOf(s.y + Math.floor(m0 / 12), (m0 % 12) + 1, 1)
    } else cursor = dnOf(s.y + Math.floor((w.y - s.y) / interval) * interval, 1, 1)
  }

  while (true) {
    if (wday === null || cursor >= wday - 366) {
      if (++periods > limit) return out
    } else if (++walked > 200000) return out
    var cands, nxt
    var c = ymd(cursor)
    if (freq === "DAILY") {
      cands = [cursor]
      if (bymonth.length) cands = cands.filter(function(dn) { return bymonth.indexOf(ymd(dn).m) !== -1 })
      if (bymonthday.length) cands = applyMonthday(cands, bymonthday)
      if (byday.length) {
        var wds = byday.map(function(b) { return b.wd })
        cands = cands.filter(function(dn) { return wds.indexOf(weekday(dn)) !== -1 })
      }
      nxt = cursor + interval
    } else if (freq === "WEEKLY") {
      var weekStart = cursor - ((weekday(cursor) - wkst + 7) % 7)
      var wanted = byday.length ? byday.map(function(b) { return b.wd }) : [weekday(startDay)]
      cands = []
      for (var i = 0; i < 7; i++) if (wanted.indexOf(weekday(weekStart + i)) !== -1) cands.push(weekStart + i)
      if (bymonth.length) cands = cands.filter(function(dn) { return bymonth.indexOf(ymd(dn).m) !== -1 })
      cursor = weekStart
      nxt = weekStart + 7 * interval
    } else if (freq === "MONTHLY") {
      if (bymonth.length && bymonth.indexOf(c.m) === -1) cands = []
      else {
        var days = monthDays(c.y, c.m)
        if (byday.length || bymonthday.length) {
          cands = days
          if (bymonthday.length) cands = applyMonthday(cands, bymonthday)
          if (byday.length) {
            var allowed = matchingByday(byday, days)
            cands = cands.filter(function(dn) { return allowed[dn] })
          }
        } else cands = days.filter(function(dn) { return ymd(dn).d === s.d })
      }
      var m2 = c.m - 1 + interval
      nxt = dnOf(c.y + Math.floor(m2 / 12), (m2 % 12) + 1, 1)
      cursor = dnOf(c.y, c.m, 1)
    } else {   // YEARLY
      var y = c.y
      var monthsList = bymonth.length ? bymonth
        : ((bymonthday.length || byday.length) ? [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12] : [s.m])
      cands = []
      if (byday.length && !bymonth.length && !bymonthday.length) {
        var yearDays = [], first = dnOf(y, 1, 1), n = isLeap(y) ? 366 : 365
        for (var k = 0; k < n; k++) yearDays.push(first + k)
        var allowedY = matchingByday(byday, yearDays)
        cands = yearDays.filter(function(dn) { return allowedY[dn] })
      } else {
        monthsList.forEach(function(mm) {
          if (mm < 1 || mm > 12) return
          var mdays = monthDays(y, mm)
          if (bymonthday.length || byday.length) {
            var sel = mdays
            if (bymonthday.length) sel = applyMonthday(sel, bymonthday)
            if (byday.length) {
              var allowedM = matchingByday(byday, mdays)
              sel = sel.filter(function(dn) { return allowedM[dn] })
            }
            cands = cands.concat(sel)
          } else if (s.d <= mdays.length) cands.push(dnOf(y, mm, s.d))
        })
      }
      nxt = dnOf(y + interval, 1, 1)
      cursor = dnOf(y, 1, 1)
    }

    cands = setpos(cands.slice().sort(function(a, b) { return a - b }), bysetpos)
    for (var j = 0; j < cands.length; j++) {
      var dn = cands[j]
      if (dn < startDay) continue
      if (dn > endDay) return out
      var value = dn * DAY_MS + tod
      if (until !== null && !isDate && value > until) return out
      out.push(value)
      produced++
      if (count !== null && produced >= count) return out
    }
    if (cursor > endDay) return out
    cursor = nxt
  }
}

// A series moved from one date to another (dates as "yyyy-MM-dd"): keep the
// rule saying the same thing about the new date. Weekly days shift by the
// same number of days; a monthly day, nth weekday or yearly date follows.
function retarget(ruleText, fromKey, toKey) {
  if (!ruleText || fromKey === toKey) return ruleText
  var r = parseRule(ruleText)
  var a = fromKey.split("-").map(Number), b = toKey.split("-").map(Number)
  var from = Date.UTC(a[0], a[1] - 1, a[2]), to = Date.UTC(b[0], b[1] - 1, b[2])
  var shift = Math.round((to - from) / DAY_MS)
  var toWd = weekday(Math.floor(to / DAY_MS))
  var freq = String(r.FREQ || "").toUpperCase()
  var byday = r.BYDAY ? parseByday(r.BYDAY) : []
  if (freq === "WEEKLY" && byday.length && byday.every(function(x) { return x.n === null })) {
    var days = byday.map(function(x) { return (((x.wd + shift) % 7) + 7) % 7 })
    days.sort(function(x, y) { return x - y })
    r.BYDAY = days.filter(function(d, i) { return days.indexOf(d) === i }).map(function(d) { return WEEKDAYS[d] }).join(",")
  } else if (freq === "MONTHLY" && byday.length === 1 && byday[0].n !== null) {
    var last = b[2] + 7 > new Date(Date.UTC(b[0], b[1], 0)).getUTCDate()
    var n = byday[0].n < 0 && last ? -1 : Math.ceil(b[2] / 7)
    r.BYDAY = n + WEEKDAYS[toWd]
  } else if ((freq === "MONTHLY" || freq === "YEARLY") && r.BYMONTHDAY && String(r.BYMONTHDAY).indexOf(",") === -1 && +r.BYMONTHDAY > 0) {
    r.BYMONTHDAY = String(b[2])
  }
  if (freq === "YEARLY" && r.BYMONTH && String(r.BYMONTH).indexOf(",") === -1) r.BYMONTH = String(b[1])
  return formatRule(r)
}

// ---- Human summaries -------------------------------------------------------

var DAY_NAMES = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
var MONTH_NAMES = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
var ORDINALS = { "1": "first", "2": "second", "3": "third", "4": "fourth", "5": "fifth", "-1": "last", "-2": "second-to-last" }

function ordinalDay(n) {
  var s = ["th", "st", "nd", "rd"], v = n % 100
  return n + (s[(v - 20) % 10] || s[v] || s[0])
}

// "Every 2 weeks on Monday and Wednesday, 10 times" etc.
function summary(ruleText) {
  if (!ruleText) return ""
  var r = parseRule(ruleText)
  var freq = String(r.FREQ || "").toUpperCase()
  var n = Math.max(1, parseInt(r.INTERVAL || "1", 10) || 1)
  var unit = { DAILY: "day", WEEKLY: "week", MONTHLY: "month", YEARLY: "year" }[freq]
  if (!unit) return "Custom repeat"
  var text = n === 1 ? (freq === "DAILY" ? "Daily" : freq === "WEEKLY" ? "Weekly" : freq === "MONTHLY" ? "Monthly" : "Yearly")
    : "Every " + n + " " + unit + "s"
  var byday = parseByday(r.BYDAY)
  var plain = byday.filter(function(b) { return b.n === null }).map(function(b) { return b.wd }).sort()
  if (freq === "WEEKLY" || freq === "DAILY") {
    if (plain.join() === "0,1,2,3,4" && byday.length === 5) text = n === 1 ? "Every weekday" : text + " on weekdays"
    else if (plain.length) text += " on " + listJoin(plain.map(function(w) { return DAY_NAMES[w] }))
  } else if (freq === "MONTHLY" || freq === "YEARLY") {
    var pos = r.BYSETPOS ? parseInts(r.BYSETPOS) : []
    if (byday.length === 1 && byday[0].n !== null)
      text += " on the " + (ORDINALS[String(byday[0].n)] || byday[0].n) + " " + DAY_NAMES[byday[0].wd]
    else if (byday.length && pos.length === 1)
      text += " on the " + (ORDINALS[String(pos[0])] || pos[0]) + " " + listJoin(byday.map(function(b) { return DAY_NAMES[b.wd] }), "or")
    else if (r.BYMONTHDAY) {
      var md = parseInts(r.BYMONTHDAY)
      text += " on the " + listJoin(md.map(function(d) { return d === -1 ? "last day" : ordinalDay(d) }))
    }
    if (freq === "YEARLY" && r.BYMONTH) text += " in " + listJoin(parseInts(r.BYMONTH).map(function(m) { return MONTH_NAMES[m - 1] }))
  }
  if (r.COUNT) text += ", " + r.COUNT + " time" + (r.COUNT === "1" ? "" : "s")
  else if (r.UNTIL) {
    var u = parseUntil(r.UNTIL)
    if (u) {
      // A UTC end (timed series) is shown on this machine's calendar day.
      var d = new Date(u.wall !== undefined ? u.wall : u.utc)
      var local = u.wall === undefined
      var mo = local ? d.getMonth() : d.getUTCMonth(), da = local ? d.getDate() : d.getUTCDate()
      var yr = local ? d.getFullYear() : d.getUTCFullYear()
      text += ", until " + MONTH_NAMES[mo].substr(0, 3) + " " + da + ", " + yr
    }
  }
  return text
}

function listJoin(items, word) {
  if (items.length <= 1) return items.join("")
  return items.slice(0, -1).join(", ") + " " + (word || "and") + " " + items[items.length - 1]
}

if (typeof module !== "undefined") {
  module.exports = {
    WEEKDAYS: WEEKDAYS, parseRule: parseRule, formatRule: formatRule, parseByday: parseByday,
    parseUntil: parseUntil, expand: expand, summary: summary, weekday: weekday, dayNumber: dayNumber,
    retarget: retarget
  }
}
