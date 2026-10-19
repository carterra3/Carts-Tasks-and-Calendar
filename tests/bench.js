// Benchmark the view queries on your own data (read only).
//   node tests/bench.js [DATA_DIR]      (default: ~/.local/share/carts)
// Baseline before the day index (341 events): agenda60 21 ms, week 4.5 ms,
// month 13.6 ms.
const E = require("../Events.js"), fs = require("fs")
const home = (process.argv[2] || (process.env.XDG_DATA_HOME || process.env.HOME + "/.local/share") + "/carts").replace(/\/?$/, "/")
const c = JSON.parse(fs.readFileSync(home + "calendar.json"))
let ev = c.events || []
if (fs.existsSync(home + "remote.json")) {
  const r = JSON.parse(fs.readFileSync(home + "remote.json"))
  for (const k in r.calendars) ev = ev.concat(r.calendars[k].events || [])
}
const cals = c.calendars, today = E.keyOf(new Date())
function t(name, f) {
  const s = process.hrtime.bigint()
  for (let i = 0; i < 20; i++) f()
  console.log(name.padEnd(28), (Number(process.hrtime.bigint() - s) / 20e6).toFixed(2), "ms")
}
console.log("events", ev.length)
console.log("-- old: scan every event per day")
t("agenda60", () => E.agenda(ev, cals, today, 60))
t("week layout+allday", () => { for (let i = 0; i < 7; i++) { const k = E.addDaysKey(today, i); E.layoutDay(ev, cals, k); E.allDayFor(ev, cals, k) } })
t("month chips 42 days", () => { for (let i = 0; i < 42; i++) E.eventsForDay(ev, cals, E.addDaysKey(today, i - 14)) })
console.log("-- new: day index (built once per store change)")
t("buildIndex", () => E.buildIndex(ev, cals))
const ix = E.buildIndex(ev, cals)
t("agenda60", () => E.agendaFrom(ix, today, 60))
t("week layout+allday", () => { for (let i = 0; i < 7; i++) { const k = E.addDaysKey(today, i), l = E.eventsOn(ix, k); E.layoutList(l, k); E.allDayIn(l, k) } })
t("month chips 42 days", () => { for (let i = 0; i < 42; i++) E.eventsOn(ix, E.addDaysKey(today, i - 14)) })
