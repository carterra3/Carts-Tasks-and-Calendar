// Time zone conversions from offset tables (sync/tzdata.py `table`).
// Pure JS so it runs under node for tests. QML's Date only knows the machine's
// own zone; every other zone goes through a table:
//   { t: [utc seconds...], o: [offset minutes...] }  offset o[i] from t[i] on.
//
// "Wall" values are naive {y, m (0-11), d, h, mi} in some zone; they are
// handled as UTC-based millisecond numbers (Date.UTC) so no local-zone
// arithmetic sneaks in.

function offsetAt(table, ms) {
  if (!table || !table.t || table.t.length === 0) return 0
  var s = ms / 1000, t = table.t
  if (s < t[0]) return table.o[0]
  var lo = 0, hi = t.length - 1
  while (lo < hi) {
    var mid = (lo + hi + 1) >> 1
    if (t[mid] <= s) lo = mid
    else hi = mid - 1
  }
  return table.o[lo]
}

// Naive wall ms (Date.UTC of the wall fields) -> real UTC ms. In a spring-
// forward gap the time is pushed forward by the gap (09:30 that does not
// exist becomes 10:30), like most calendar apps.
function wallToUtc(table, wallMs) {
  var off1 = offsetAt(table, wallMs - offsetAt(table, wallMs) * 60000)
  var utc = wallMs - off1 * 60000
  var off2 = offsetAt(table, utc)
  if (off2 !== off1) utc = wallMs - off2 * 60000
  return utc
}

function utcToWall(table, utcMs) { return utcMs + offsetAt(table, utcMs) * 60000 }

function pad2(n) { return (n < 10 ? "0" : "") + n }

// Wall ms -> "yyyy-MM-dd" / "yyyy-MM-ddTHH:mm"
function wallStamp(wallMs, allDay) {
  var d = new Date(wallMs)
  var k = d.getUTCFullYear() + "-" + pad2(d.getUTCMonth() + 1) + "-" + pad2(d.getUTCDate())
  return allDay ? k : k + "T" + pad2(d.getUTCHours()) + ":" + pad2(d.getUTCMinutes())
}

// "yyyy-MM-dd[THH:mm]" -> wall ms (or NaN)
function stampWall(stamp) {
  var m = String(stamp || "").match(/^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2}))?$/)
  if (!m) return NaN
  return Date.UTC(+m[1], +m[2] - 1, +m[3], m[4] ? +m[4] : 0, m[5] ? +m[5] : 0)
}

// Machine-local stamp <-> stamp in a zone. `table` null means the machine's
// own zone (identity). All-day stamps never convert: a date is a date.
function localToZone(stamp, table) {
  if (!table || String(stamp).length <= 10) return stamp
  var m = String(stamp).match(/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})$/)
  if (!m) return stamp
  var utc = new Date(+m[1], +m[2] - 1, +m[3], +m[4], +m[5]).getTime()
  return wallStamp(utcToWall(table, utc), false)
}

function zoneToLocal(stamp, table) {
  if (!table || String(stamp).length <= 10) return stamp
  var wall = stampWall(stamp)
  if (isNaN(wall)) return stamp
  var d = new Date(wallToUtc(table, wall))
  return d.getFullYear() + "-" + pad2(d.getMonth() + 1) + "-" + pad2(d.getDate()) + "T" + pad2(d.getHours()) + ":" + pad2(d.getMinutes())
}

// "+05:30" / "−06:00" style label for an offset in minutes.
function offsetLabel(minutes) {
  var sign = minutes < 0 ? "−" : "+"
  var m = Math.abs(minutes)
  return "UTC" + sign + pad2(Math.floor(m / 60)) + ":" + pad2(m % 60)
}

// Short city-ish label: "America/Argentina/Buenos_Aires" -> "Buenos Aires".
function cityName(zone) {
  var s = String(zone || "")
  return s.substr(s.lastIndexOf("/") + 1).replace(/_/g, " ")
}

if (typeof module !== "undefined") {
  module.exports = {
    offsetAt: offsetAt, wallToUtc: wallToUtc, utcToWall: utcToWall, wallStamp: wallStamp,
    stampWall: stampWall, localToZone: localToZone, zoneToLocal: zoneToLocal,
    offsetLabel: offsetLabel, cityName: cityName
  }
}
