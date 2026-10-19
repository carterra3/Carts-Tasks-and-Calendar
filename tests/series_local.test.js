// Local series edits (Events.series*). Run: TZ=America/Chicago node tests/series_local.test.js
const assert = require("assert")
const E = require("../Events.js"), R = require("../Recur.js"), Tz = require("../Tz.js")

if (new Date(2026, 6, 1).getTimezoneOffset() !== 300) {
  console.log("run with TZ=America/Chicago"); process.exit(1)
}
const from = Date.UTC(2026, 8, 1), to = Date.UTC(2027, 2, 1)
const occ = m => (Array.isArray(m) ? m : [m]).filter(Boolean)
  .flatMap(x => E.expandSeries(x, R, Tz, null, from, to)).sort((a, b) => a.start < b.start ? -1 : 1)
  .map(o => [o.start, o.end, o.title])
const key = stamp => E.occurrenceKey(stamp, false)
const ed = (start, end, title, extra) => Object.assign({ start, end, title: title || "Standup", allDay: false, calendarId: "c" }, extra || {})

const base = { uid: "s1", calendarId: "c", title: "Standup", start: "2026-10-19T09:00", end: "2026-10-19T09:30",
  rrule: "FREQ=WEEKLY;BYDAY=MO;COUNT=10" }
assert.strictEqual(occ(base).length, 10)
assert.deepStrictEqual(occ(base)[3], ["2026-11-09T09:00", "2026-11-09T09:30", "Standup"])   // after DST

// this
const t = E.seriesEditThis(base, key("2026-11-02T09:00"), ed("2026-11-02T10:00", "2026-11-02T10:45", "Moved"))
assert.ok(occ(t).some(o => o[0] === "2026-11-02T10:00" && o[2] === "Moved"))
assert.strictEqual(occ(t).length, 10)
assert.strictEqual(base.overrides, undefined, "inputs are not mutated")

// delete this
const d = E.seriesDeleteThis(t, key("2026-10-26T09:00"))
assert.strictEqual(occ(d).length, 9)
assert.ok(!occ(d).some(o => o[0].startsWith("2026-10-26")))
assert.strictEqual(occ(E.seriesDeleteThis(t, key("2026-11-02T09:00"))).length, 9)

// all: 9:30 from the fourth occurrence; exception and override follow
const a = E.seriesEditAll(d, key("2026-11-09T09:00"), ed("2026-11-09T09:30", "2026-11-09T10:00", "v2"), R, Tz, () => null)
const oa = occ(a)
assert.strictEqual(oa.length, 9)
assert.deepStrictEqual(oa[0], ["2026-10-19T09:30", "2026-10-19T10:00", "v2"])
assert.ok(!oa.some(o => o[0].startsWith("2026-10-26")), "exception kept")
assert.ok(oa.some(o => o[2] === "Moved"), "override kept")
// all, moved to Tuesday with the rule retargeted by the editor
const a2 = E.seriesEditAll(d, key("2026-11-09T09:00"), ed("2026-11-10T09:00", "2026-11-10T09:30", "Tue", { rrule: "FREQ=WEEKLY;BYDAY=TU;COUNT=10" }), R, Tz, () => null)
assert.deepStrictEqual(occ(a2)[0], ["2026-10-20T09:00", "2026-10-20T09:30", "Tue"])
assert.strictEqual(a2.exdates, undefined)

// following: from the 5th on, 14:00; COUNT 10 -> 4 + 6
const sp = E.seriesSplit(base, key("2026-11-16T09:00"), ed("2026-11-16T14:00", "2026-11-16T14:30", "PM", { rrule: base.rrule }), "s2", R)
assert.deepStrictEqual(occ(sp.old).map(o => o[0].slice(0, 10)), ["2026-10-19", "2026-10-26", "2026-11-02", "2026-11-09"])
assert.strictEqual(occ(sp.fresh).length, 6)
assert.deepStrictEqual(occ(sp.fresh)[0], ["2026-11-16T14:00", "2026-11-16T14:30", "PM"])
assert.ok(/COUNT=6/.test(sp.fresh.rrule) && /UNTIL=/.test(sp.old.rrule) && !/COUNT/.test(sp.old.rrule))
assert.strictEqual(E.seriesSplit(base, key("2026-10-19T09:00"), ed("2026-10-19T08:00", "2026-10-19T08:30"), "s3", R).old, null)

// delete following
const eb = E.seriesEndBefore(base, key("2026-11-16T09:00"), R)
assert.strictEqual(occ(eb.master).length, 4)
assert.strictEqual(eb.countLeft, 6)

// all-day yearly, moved a day, keeps its exception
const bd = { uid: "b", calendarId: "c", title: "B", allDay: true, start: "2020-03-10", end: "2020-03-10", rrule: "FREQ=YEARLY", exdates: ["20270310"] }
const bd2 = E.seriesEditAll(bd, "20260310", { start: "2026-03-11", end: "2026-03-11", allDay: true, title: "B" }, R, Tz, () => null)
const yrs = E.expandSeries(bd2, R, Tz, null, Date.UTC(2026, 0, 1), Date.UTC(2029, 0, 1)).map(o => o.start)
assert.deepStrictEqual(yrs, ["2026-03-11", "2028-03-11"])

console.log("local series tests passed")

// ---- spanning bars
{
  const keys = ["2026-10-19", "2026-10-20", "2026-10-21", "2026-10-22", "2026-10-23", "2026-10-24", "2026-10-25"]
  const evs = [
    { uid: "trip", calendarId: "c", title: "Trip", allDay: true, start: "2026-10-17", end: "2026-10-20" },     // starts before the row
    { uid: "conf", calendarId: "c", title: "Conf", allDay: true, start: "2026-10-20", end: "2026-10-22" },
    { uid: "red", calendarId: "c", title: "Red-eye", start: "2026-10-22T22:00", end: "2026-10-23T06:00" },    // timed, crosses midnight
    { uid: "long", calendarId: "c", title: "Long", start: "2026-10-23T10:00", end: "2026-10-26T12:00" },      // runs past the row
    { uid: "one", calendarId: "c", title: "Lunch", start: "2026-10-21T12:00", end: "2026-10-21T13:00" },
  ]
  const idx = E.buildIndex(evs, [{ id: "c" }])
  const lists = keys.map(k => E.eventsOn(idx, k))
  const month = E.layoutBars(lists, keys, E.isMultiDay)
  const byTitle = Object.fromEntries(month.bars.map(b => [b.ev.title, b]))
  assert.deepStrictEqual(Object.keys(byTitle).sort(), ["Conf", "Long", "Red-eye", "Trip"])
  assert.ok(byTitle.Trip.first === 0 && byTitle.Trip.last === 1 && byTitle.Trip.cutStart && !byTitle.Trip.cutEnd)
  assert.ok(byTitle.Conf.first === 1 && byTitle.Conf.last === 3 && byTitle.Conf.row !== byTitle.Trip.row)
  assert.ok(byTitle["Red-eye"].first === 3 && byTitle["Red-eye"].last === 4)
  assert.ok(byTitle.Long.first === 4 && byTitle.Long.last === 6 && byTitle.Long.cutEnd)
  assert.deepStrictEqual(month.perDay, [1, 2, 1, 2, 2, 1, 1])
  // Time grid lane: all-day + a day or longer; the red-eye stays in the hour columns.
  const lane = E.layoutBars(lists, keys, E.isLaneEvent)
  assert.deepStrictEqual(lane.bars.map(b => b.ev.title).sort(), ["Conf", "Long", "Trip"])
  assert.ok(!E.layoutList(lists[4], keys[4]).some(x => x.ev.title === "Long"))
  assert.ok(E.layoutList(lists[4], keys[4]).some(x => x.ev.title === "Red-eye"))
  console.log("bar layout tests passed")
}

// ---- moving
{
  const ev = { uid: "m", calendarId: "c", title: "M", start: "2026-10-20T22:00", end: "2026-10-21T01:00" }
  assert.deepStrictEqual([E.moved(ev, "2026-10-22T09:15").start, E.moved(ev, "2026-10-22T09:15").end], ["2026-10-22T09:15", "2026-10-22T12:15"])
  assert.deepStrictEqual([E.moved(ev, "2026-10-25").start, E.moved(ev, "2026-10-25").end], ["2026-10-25T22:00", "2026-10-26T01:00"])
  // the night before DST ends (2:00 Nov 1): ends 01:00, still before the change
  assert.deepStrictEqual([E.movedByDays(ev, 11).start, E.movedByDays(ev, 11).end], ["2026-10-31T22:00", "2026-11-01T01:00"])
  const ad = { uid: "a", calendarId: "c", title: "A", allDay: true, start: "2026-10-30", end: "2026-11-02" }
  assert.deepStrictEqual([E.movedByDays(ad, 3).start, E.movedByDays(ad, 3).end], ["2026-11-02", "2026-11-05"])
  assert.strictEqual(R.retarget("FREQ=WEEKLY;BYDAY=MO,WE", "2026-10-19", "2026-10-20"), "FREQ=WEEKLY;BYDAY=TU,TH")
  assert.strictEqual(R.retarget("FREQ=WEEKLY;BYDAY=SU", "2026-10-18", "2026-10-17"), "FREQ=WEEKLY;BYDAY=SA")
  assert.strictEqual(R.retarget("FREQ=MONTHLY;BYDAY=3MO", "2026-10-19", "2026-10-20"), "FREQ=MONTHLY;BYDAY=3TU")
  assert.strictEqual(R.retarget("FREQ=MONTHLY;BYDAY=-1FR", "2026-10-30", "2026-10-29"), "FREQ=MONTHLY;BYDAY=-1TH")
  assert.strictEqual(R.retarget("FREQ=MONTHLY;BYMONTHDAY=15;COUNT=5", "2026-10-15", "2026-10-16"), "FREQ=MONTHLY;COUNT=5;BYMONTHDAY=16")
  assert.strictEqual(R.retarget("FREQ=YEARLY;BYMONTH=3;BYMONTHDAY=10", "2026-03-10", "2026-04-02"), "FREQ=YEARLY;BYMONTH=4;BYMONTHDAY=2")
  assert.strictEqual(R.retarget("FREQ=DAILY", "2026-10-19", "2026-10-25"), "FREQ=DAILY")
  console.log("move tests passed")
}
