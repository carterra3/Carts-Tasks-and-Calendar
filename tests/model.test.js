const assert = require("assert")
const E = require("../Events.js"), P = require("../Palette.js"), fs = require("fs")
// time/date parsing
assert.deepStrictEqual(E.parseTime("2:30pm"), {h:14,m:30})
assert.deepStrictEqual(E.parseTime("12am"), {h:0,m:0})
assert.deepStrictEqual(E.parseTime("1430"), {h:14,m:30})
assert.deepStrictEqual(E.parseTime("9"), {h:9,m:0})
assert.strictEqual(E.parseTime("25:00"), null)
assert.strictEqual(E.keyOf(E.parseDate("10/16/2026")), "2026-10-16")
assert.strictEqual(E.parseDate("2026-02-30"), null)
// build + overnight
let r = E.buildEvent({title:"Late", calendarId:"c1", startDate:"2026-10-16", startTime:"22:00", endTime:"1am"}, null, "now")
assert.ok(r.event, r.error); assert.strictEqual(r.event.end, "2026-10-17T01:00")
assert.ok(E.occursOn(r.event, "2026-10-16") && E.occursOn(r.event, "2026-10-17") && !E.occursOn(r.event, "2026-10-18"))
assert.strictEqual(E.timeLabel(r.event, "2026-10-17", true), "… – 01:00")
let ad = E.buildEvent({title:"Trip", calendarId:"c1", allDay:true, startDate:"2026-10-16", endDate:"10/18"}, null, "now").event
assert.ok(E.occursOn(ad,"2026-10-18") && !E.occursOn(ad,"2026-10-19"))
// event ending exactly at midnight does not leak into next day
let m = E.buildEvent({title:"x", calendarId:"c1", startDate:"2026-10-16", startTime:"23:00", endTime:"0:00"}, null, "").event
assert.ok(!E.occursOn(m, "2026-10-17"))
assert.strictEqual(E.buildEvent({title:"", calendarId:"c"}).error, "Give the event a title")
// round trip
let f = E.formFor(r.event, false); assert.strictEqual(f.startTime, "10:00 PM"); assert.strictEqual(f.endDate, "2026-10-17")
// markers
const cals=[{id:"c1",visible:true},{id:"c2",visible:false}]
const weeks=[{days:[{key:"2026-10-12"},{key:"2026-10-18"}]}]
let mm = E.markerMap([ad, Object.assign({},ad,{uid:"z",calendarId:"c2"})], cals, weeks)
assert.deepStrictEqual(mm["2026-10-17"], ["c1"])
// palette
const pal = P.parseColorsToml(fs.readFileSync("/usr/share/omarchy/themes/catppuccin/colors.toml","utf8"))
assert.strictEqual(P.resolve(pal, "theme:blue"), "#89b4fa")
assert.strictEqual(P.resolve({color2:"#00ff00"}, "theme:green"), "#00ff00")
assert.strictEqual(P.resolve(pal, "#ABC"), "#aabbcc")
assert.strictEqual(P.normalizeHex("abc"), "#aabbcc")
const sugg = P.suggestions(pal); assert.ok(sugg.length >= 8)
assert.strictEqual(sugg.filter(s=>s.hex==="#89b4fa").length, 1) // accent==blue deduped
assert.notStrictEqual(P.resolve(pal, P.nextSuggestion(pal, ["theme:accent"])), "#89b4fa")
// view helpers
assert.strictEqual(E.weekStartKey("2026-10-16", 1), "2026-10-12")
assert.strictEqual(E.weekStartKey("2026-10-16", 0), "2026-10-11")
assert.strictEqual(E.weekStartKey("2026-10-11", 0), "2026-10-11")
assert.strictEqual(E.addDaysKey("2026-12-31", 1), "2027-01-01")
const mk = (uid, s, e, extra) => Object.assign({uid, calendarId:"c1", title:uid, allDay:false, start:s, end:e}, extra||{})
const day = [
  mk("a","2026-10-16T09:00","2026-10-16T10:00"), mk("b","2026-10-16T09:30","2026-10-16T11:00"),
  mk("c","2026-10-16T10:00","2026-10-16T10:30"), mk("d","2026-10-16T13:00","2026-10-16T14:00"),
  mk("e","2026-10-15T22:00","2026-10-16T01:00"), mk("f","2026-10-16T12:00","2026-10-16T12:05"),
  mk("g","2026-10-15T08:00","2026-10-17T08:00"), mk("h","2026-10-16","2026-10-16",{allDay:true}),
]
const L = Object.fromEntries(E.layoutDay(day, cals, "2026-10-16").map(x => [x.ev.uid, x]))
assert.ok(!L.g && !L.h, "whole-day events go to the all-day lane")
assert.deepStrictEqual([L.a.col, L.b.col, L.c.col], [0, 1, 0]); assert.ok(L.a.cols === 2 && L.c.cols === 2)
assert.deepStrictEqual([L.d.col, L.d.cols], [0, 1])
assert.deepStrictEqual([L.e.start, L.e.end], [0, 60])          // clipped at midnight
assert.deepStrictEqual([L.f.start, L.f.end], [720, 740])       // short events get a minimum height
assert.deepStrictEqual(E.allDayFor(day, cals, "2026-10-16").map(e=>e.uid).sort(), ["g","h"])
const ag = E.agenda(day, cals, "2026-10-15", 3)
assert.deepStrictEqual(ag.map(g=>g.key), ["2026-10-15","2026-10-16","2026-10-17"])
assert.deepStrictEqual(E.agenda(day, cals, "2026-10-20", 5), [])
assert.strictEqual(E.addMonthsKey("2027-01-31", 1), "2027-02-28")
assert.strictEqual(E.addMonthsKey("2028-01-31", 1), "2028-02-29")
assert.strictEqual(E.addMonthsKey("2026-12-15", 1), "2027-01-15")
assert.strictEqual(E.stepKey("week", "2026-10-16", -1), "2026-10-09")
assert.strictEqual(E.periodTitle("week", "2026-10-01", 1), "Sep 28 – Oct 4, 2026")
assert.strictEqual(E.periodTitle("week", "2026-10-16", 1), "Oct 12 – 18, 2026")
assert.strictEqual(E.periodTitle("month", "2026-10-16", 1), "October 2026")
assert.strictEqual(E.periodTitle("day", "2026-10-16", 1), "Friday, October 16")
assert.strictEqual(E.shortTime("2026-10-16T21:30", false), "9:30p")
assert.strictEqual(E.shortTime("2026-10-16T09:00", false), "9a")
// hidden events
const occ = (n) => ({uid:"fam1@2026101"+n+"T150000", sourceUid:"fam1", calendarId:"fam", title:"Soccer", recurring:true, start:"2026-10-1"+n+"T10:00", end:"2026-10-1"+n+"T11:00"})
const single = {uid:"party", sourceUid:"party", calendarId:"fam", title:"Party", start:"2026-10-20", end:"2026-10-20", allDay:true}
const otherCal = Object.assign({}, single, {calendarId:"work"})
const feed = [occ(2), occ(3), occ(4), single, otherCal]
let hid = [E.hideEntry(occ(3), false, "t")]
assert.deepStrictEqual(E.withoutHidden(feed, hid).map(e=>e.uid), [occ(2).uid, occ(4).uid, "party", "party"])
hid = [E.hideEntry(occ(3), true, "t")]                 // whole series
assert.deepStrictEqual(E.withoutHidden(feed, hid).map(e=>e.calendarId+":"+e.uid), ["fam:party","work:party"])
hid = [E.hideEntry(single, false, "t")]                // same uid on another calendar stays
assert.deepStrictEqual(E.withoutHidden(feed, hid).map(e=>e.calendarId), ["fam","fam","fam","work"])
// survives a re-sync: fresh objects with the same identity are still hidden
const resynced = JSON.parse(JSON.stringify(feed))
assert.strictEqual(E.withoutHidden(resynced, [E.hideEntry(occ(4), false)]).length, 4)
assert.ok(E.hiddenStillPresent(E.hideEntry(occ(4), true), feed))
assert.ok(!E.hiddenStillPresent(E.hideEntry(occ(4), false), [occ(2)]))
assert.strictEqual(E.withoutHidden(feed, []), feed)
console.log("all tests passed;", sugg.length, "catppuccin swatches")

// ---- Day index matches the per-day scan it replaces
;(function() {
  const ix = (evs, cs) => E.buildIndex(evs, cs)
  const cal2 = [{id:"a",visible:true},{id:"b",visible:true},{id:"h",visible:false}]
  const mk = (o) => Object.assign({uid:"u"+Math.random(), calendarId:"a", title:"t", allDay:false}, o)
  const evs = [
    mk({title:"overnight", start:"2026-10-16T22:00", end:"2026-10-17T01:00"}),
    mk({title:"to midnight", start:"2026-10-16T23:00", end:"2026-10-17T00:00"}),
    mk({title:"zero", start:"2026-10-16T09:00", end:"2026-10-16T09:00"}),
    mk({title:"trip", allDay:true, start:"2026-10-15", end:"2026-10-18"}),
    mk({title:"multi timed", calendarId:"b", start:"2026-10-14T08:00", end:"2026-10-19T12:00"}),
    mk({title:"dst", start:"2026-10-31T23:00", end:"2026-11-01T03:00"}),
    mk({title:"hidden cal", calendarId:"h", start:"2026-10-16T10:00", end:"2026-10-16T11:00"}),
    mk({title:"bad", start:"nope", end:""}),
  ]
  const idx = ix(evs, cal2)
  for (let i = 0; i < 30; i++) {
    const k = E.addDaysKey("2026-10-10", i)
    assert.deepStrictEqual(E.eventsOn(idx, k).map(e => e.title), E.eventsForDay(evs, cal2, k).map(e => e.title), k)
  }
  assert.deepStrictEqual(E.eventsOn(idx, "2026-10-17").map(e => e.title), ["trip", "multi timed", "overnight"])
  assert.ok(!E.eventsOn(idx, "2026-10-16").some(e => e.title === "hidden cal"))
  assert.deepStrictEqual(E.eventsOn(null, "2026-10-16"), [])
  // layoutList / allDayIn / agendaFrom agree with the old entry points
  for (const k of ["2026-10-14", "2026-10-16", "2026-10-17", "2026-11-01"]) {
    const strip = l => l.map(x => [x.ev.title, x.start, x.end, x.col, x.cols])
    assert.deepStrictEqual(strip(E.layoutList(E.eventsOn(idx, k), k)), strip(E.layoutDay(evs, cal2, k)), k)
    assert.deepStrictEqual(E.allDayIn(E.eventsOn(idx, k), k), E.allDayFor(evs, cal2, k), k)
  }
  assert.deepStrictEqual(E.agendaFrom(idx, "2026-10-12", 30), E.agenda(evs, cal2, "2026-10-12", 30))
  // month dots: same as markerMap
  const wk = [{days:[{key:"2026-10-12"},{key:"2026-10-25"}]}]
  const mm2 = E.markerMap(evs, cal2, [{days:[{key:"2026-10-12"},{key:"2026-11-08"}]}], 3)
  for (const k in mm2) assert.deepStrictEqual(E.calendarMarkers(E.eventsOn(idx, k), 3), mm2[k], k)
  // a very long event is clipped, not looped forever
  const forever = mk({title:"forever", allDay:true, start:"2020-01-01", end:"2030-01-01"})
  const warn = console.warn; console.warn = () => {}
  const big = E.buildIndex([forever], cal2)
  console.warn = warn
  assert.strictEqual(big.clipped, 1)
  assert.strictEqual(Object.keys(big.byDay).length, 400)
  // index never adds fields to the events (they are saved as-is)
  assert.deepStrictEqual(Object.keys(evs[0]).sort(), ["allDay","calendarId","end","start","title","uid"])

  // Optional check against your own data (read only):
  //   CARTS_REAL_DATA=1 node tests/model.test.js
  const home = (process.env.XDG_DATA_HOME || process.env.HOME + "/.local/share") + "/carts/"
  if (process.env.CARTS_REAL_DATA && fs.existsSync(home + "calendar.json")) {
    const c = JSON.parse(fs.readFileSync(home + "calendar.json"))
    let all = c.events || []
    if (fs.existsSync(home + "remote.json")) {
      const r = JSON.parse(fs.readFileSync(home + "remote.json"))
      for (const id in r.calendars) all = all.concat(r.calendars[id].events || [])
    }
    const ri = E.buildIndex(all, c.calendars)
    const from = E.addDaysKey(E.keyOf(new Date()), -30)
    for (let i = 0; i < 90; i++) {
      const k = E.addDaysKey(from, i)
      assert.deepStrictEqual(E.eventsOn(ri, k).map(e => e.uid), E.eventsForDay(all, c.calendars, k).map(e => e.uid), "real " + k)
    }
    console.log("day index matches on real data (" + all.length + " events)")
  }
})()
console.log("day index tests passed")

// presentKeys agrees with hiddenStillPresent
;(function() {
  const evs = [{calendarId:"a", uid:"x@1", sourceUid:"x"}, {calendarId:"a", uid:"y"}, {calendarId:"b", uid:"z@2", sourceUid:"z"}]
  const entries = [
    {calendarId:"a", uid:"x@1", series:false}, {calendarId:"a", uid:"x@9", series:false},
    {calendarId:"a", sourceUid:"x", series:true}, {calendarId:"b", sourceUid:"x", series:true},
    {calendarId:"a", sourceUid:"y", series:true}, {calendarId:"b", uid:"z@2", series:false}, {calendarId:"a", uid:"z@2", series:false},
  ]
  const pk = E.presentKeys(evs)
  for (const h of entries) assert.strictEqual(!!pk[E.hiddenKey(h)], E.hiddenStillPresent(h, evs), JSON.stringify(h))
  console.log("presentKeys tests passed")
})()
