// node tests/tasks.test.js — task model, recurrence and quick add.
process.env.TZ = "America/Chicago"
var R = require("../Recur.js")
var T = require("../Tasks.js")

var failed = 0, passed = 0
function eq(name, got, want) {
  var a = JSON.stringify(got), b = JSON.stringify(want)
  if (a === b) passed++
  else { failed++; console.log("FAIL " + name + "\n   got  " + a + "\n   want " + b) }
}

function task(fields) {
  var t = { uid: "u1", listId: "L", title: "t", status: "NEEDS-ACTION", completed: "", percent: 0, priority: 0,
            due: "", start: "", rrule: "", repeatFrom: "due", categories: [], parent: "" }
  for (var k in fields) t[k] = fields[k]
  return t
}
function next(t, mode, today) { var n = T.advance(t, R, mode, today); return n ? [n.start, n.due, n.rrule] : null }

// ---- advance: following the schedule ("due" mode)
var TODAY = "2026-10-19"   // a Monday
eq("daily, done on the day", next(task({ due: "2026-10-19", rrule: "FREQ=DAILY" }), "due", TODAY), ["", "2026-10-20", "FREQ=DAILY"])
eq("daily, overdue: no trail of missed copies", next(task({ due: "2026-10-16", rrule: "FREQ=DAILY" }), "due", TODAY), ["", "2026-10-20", "FREQ=DAILY"])
eq("daily, done early", next(task({ due: "2026-10-25", rrule: "FREQ=DAILY" }), "due", TODAY), ["", "2026-10-26", "FREQ=DAILY"])
eq("weekly on Tuesday, done late on Wednesday", next(task({ due: "2026-10-20", rrule: "FREQ=WEEKLY;BYDAY=TU" }), "due", "2026-10-21"),
   ["", "2026-10-27", "FREQ=WEEKLY;BYDAY=TU"])
eq("every 2 weeks on Mo/We/Fr", next(task({ start: "2026-10-23", due: "2026-10-23", rrule: "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE,FR" }), "due", TODAY),
   ["2026-11-02", "2026-11-02", "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE,FR"])
eq("monthly on the 31st skips short months", next(task({ due: "2026-10-31", rrule: "FREQ=MONTHLY;BYMONTHDAY=31" }), "due", TODAY),
   ["", "2026-12-31", "FREQ=MONTHLY;BYMONTHDAY=31"])
eq("yearly on Feb 29 waits for a leap year", next(task({ due: "2024-02-29", rrule: "FREQ=YEARLY" }), "due", "2024-03-01"), ["", "2028-02-29", "FREQ=YEARLY"])
eq("monthly on the last Friday", next(task({ due: "2026-10-30", rrule: "FREQ=MONTHLY;BYDAY=-1FR" }), "due", TODAY), ["", "2026-11-27", "FREQ=MONTHLY;BYDAY=-1FR"])
eq("timed: wall time kept across DST", next(task({ due: "2026-10-27T09:00", rrule: "FREQ=WEEKLY" }), "due", TODAY), ["", "2026-11-03T09:00", "FREQ=WEEKLY"])
eq("start and due move together", next(task({ start: "2026-10-12", due: "2026-10-16", rrule: "FREQ=WEEKLY;BYDAY=MO" }), "due", TODAY),
   ["2026-10-26", "2026-10-30", "FREQ=WEEKLY;BYDAY=MO"])
eq("timed start, timed due", next(task({ start: "2026-10-19T08:00", due: "2026-10-19T17:30", rrule: "FREQ=DAILY" }), "due", TODAY),
   ["2026-10-20T08:00", "2026-10-20T17:30", "FREQ=DAILY"])
eq("old series (since 2020) still reaches today", next(task({ due: "2020-01-06", rrule: "FREQ=WEEKLY" }), "due", TODAY), ["", "2026-10-26", "FREQ=WEEKLY"])

// COUNT and UNTIL
var c3 = task({ due: "2026-10-19", rrule: "FREQ=DAILY;COUNT=3" })
var c2 = T.advance(c3, R, "due", TODAY)
eq("COUNT counts down", [c2.due, c2.rrule], ["2026-10-20", "FREQ=DAILY;COUNT=2"])
var c1 = T.advance(c2, R, "due", "2026-10-20")
eq("COUNT counts down again", [c1.due, c1.rrule], ["2026-10-21", "FREQ=DAILY;COUNT=1"])
eq("COUNT exhausted", T.advance(c1, R, "due", "2026-10-21"), null)
eq("COUNT skipping missed days counts them", next(task({ due: "2026-10-15", rrule: "FREQ=DAILY;COUNT=10" }), "due", TODAY),
   ["", "2026-10-20", "FREQ=DAILY;COUNT=5"])
eq("COUNT runs out while catching up", T.advance(task({ due: "2026-10-01", rrule: "FREQ=DAILY;COUNT=5" }), R, "due", TODAY), null)
eq("UNTIL (date) ends the series", T.advance(task({ due: "2026-10-27", rrule: "FREQ=WEEKLY;UNTIL=20261101" }), R, "due", TODAY), null)
eq("UNTIL (date) keeps the last one", next(task({ due: "2026-10-20", rrule: "FREQ=WEEKLY;UNTIL=20261027" }), "due", TODAY),
   ["", "2026-10-27", "FREQ=WEEKLY;UNTIL=20261027"])
eq("UNTIL in UTC for timed tasks", next(task({ due: "2026-10-20T21:00", rrule: "FREQ=DAILY;UNTIL=20261022T025959Z" }), "due", "2026-10-20"),
   ["", "2026-10-21T21:00", "FREQ=DAILY;UNTIL=20261022T025959Z"])
eq("UNTIL in UTC stops on time", T.advance(task({ due: "2026-10-21T21:00", rrule: "FREQ=DAILY;UNTIL=20261022T025959Z" }), R, "due", "2026-10-21"), null)

// Exceptions
eq("EXDATE skipped", next(task({ due: "2026-10-19", rrule: "FREQ=DAILY", exdates: ["20261020"] }), "due", TODAY), ["", "2026-10-21", "FREQ=DAILY"])
var ex = T.advance(task({ due: "2026-10-19", rrule: "FREQ=DAILY", exdates: ["20261001", "20261025"], doneKeys: ["20261002"] }), R, "due", TODAY)
eq("old exceptions dropped, later kept", [ex.exdates, ex.doneKeys], [["20261025"], []])
eq("timed EXDATE (UTC key)", next(task({ due: "2026-10-19T09:00", rrule: "FREQ=DAILY", exdates: ["20261020T140000"] }), "due", TODAY),
   ["", "2026-10-21T09:00", "FREQ=DAILY"])

// skip and effective
eq("skip moves one occurrence even when overdue", next(task({ due: "2026-10-10", rrule: "FREQ=DAILY" }), "skip", TODAY), ["", "2026-10-11", "FREQ=DAILY"])
var other = task({ due: "2026-10-19", start: "2026-10-19", rrule: "FREQ=WEEKLY", doneKeys: ["20261019"] })
eq("completed elsewhere: shown at the next one", [T.effective(other, R).due, T.effective(other, R).start], ["2026-10-26", "2026-10-26"])
eq("effective leaves normal tasks alone", T.effective(task({ due: "2026-10-19", rrule: "FREQ=WEEKLY" }), R).due, "2026-10-19")
eq("upcoming", T.upcoming(task({ due: "2026-10-19", rrule: "FREQ=WEEKLY;BYDAY=MO,TH" }), R, 3, TODAY), ["2026-10-22", "2026-10-26", "2026-10-29"])

// ---- repeat after completion
eq("every 2 weeks after completion", next(task({ due: "2026-10-01", rrule: "FREQ=WEEKLY;INTERVAL=2", repeatFrom: "completion" }), "completion", TODAY),
   ["", "2026-11-02", "FREQ=WEEKLY;INTERVAL=2"])
eq("after completion keeps the time and the gap", next(task({ start: "2026-09-28T08:00", due: "2026-10-01T09:00", rrule: "FREQ=WEEKLY;INTERVAL=2" }), "completion", TODAY),
   ["2026-10-30T08:00", "2026-11-02T09:00", "FREQ=WEEKLY;INTERVAL=2"])
eq("monthly after completion clamps to the month's end", next(task({ due: "2026-01-10", rrule: "FREQ=MONTHLY" }), "completion", "2027-01-31"),
   ["", "2027-02-28", "FREQ=MONTHLY"])
eq("after completion counts down COUNT", next(task({ due: "2026-10-10", rrule: "FREQ=DAILY;INTERVAL=3;COUNT=4" }), "completion", TODAY),
   ["", "2026-10-22", "FREQ=DAILY;INTERVAL=3;COUNT=3"])
eq("after completion respects UNTIL", T.advance(task({ due: "2026-10-10", rrule: "FREQ=WEEKLY;UNTIL=20261025" }), R, "completion", TODAY), null)
eq("after completion with BY parts: next matching day", next(task({ due: "2026-10-12", rrule: "FREQ=WEEKLY;BYDAY=MO,TH" }), "completion", TODAY),
   ["", "2026-10-22", "FREQ=WEEKLY;BYDAY=MO,TH"])

// ---- complete / reopen
var rent = task({ uid: "rent", due: "2026-11-01", start: "2026-11-01", rrule: "FREQ=MONTHLY;BYMONTHDAY=1", href: "h", etag: "e" })
var res = T.complete(rent, R, "2026-10-30T18:00", { newUid: "copy-1" })
eq("complete repeating: series moves on", [res.update.uid, res.update.due, res.update.status, res.update.href, res.next], ["rent", "2026-12-01", "NEEDS-ACTION", "h", "2026-12-01"])
eq("complete repeating: history copy", [res.create.uid, res.create.due, res.create.status, res.create.completed, res.create.rrule, res.create.href, res.create.historyOf],
   ["copy-1", "2026-11-01", "COMPLETED", "2026-10-30T18:00", undefined, undefined, "rent"])
eq("complete repeating without history", T.complete(rent, R, "2026-10-30T18:00", { keepHistory: false }).create, null)
var last = T.complete(task({ due: "2026-10-19", rrule: "FREQ=DAILY;COUNT=1" }), R, "2026-10-19T10:00")
eq("last occurrence completes the task", [last.update.status, last.update.completed, last.create, last.next], ["COMPLETED", "2026-10-19T10:00", null, ""])
var plain = T.complete(task({ due: "2026-10-19" }), R, "2026-10-19T10:00")
eq("complete plain", [plain.update.status, plain.update.percent, plain.create], ["COMPLETED", 100, null])
var back = T.reopen(plain.update, "2026-10-19T11:00")
eq("reopen", [back.status, back.completed, back.percent], ["NEEDS-ACTION", "", 0])

// ---- quick add (today is Monday 2026-10-19)
function q(text) { var r = T.parseQuick(text, TODAY, R); return [r.title, r.due, r.rrule, r.priority, r.categories, r.list, r.repeatFrom] }
eq("qa rent", q("Pay rent every month on the 1st #bills !high"), ["Pay rent", "2026-11-01", "FREQ=MONTHLY;BYMONTHDAY=1", 1, ["bills"], "", "due"])
eq("qa tomorrow at 5pm", q("Call mom tomorrow at 5pm"), ["Call mom", "2026-10-20T17:00", "", 0, [], "", "due"])
eq("qa weekday", q("Stretch every weekday"), ["Stretch", "2026-10-19", "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR", 0, [], "", "due"])
eq("qa list + weekday", q("Review @Work fri"), ["Review", "2026-10-23", "", 0, [], "Work", "due"])
eq("qa two weekdays", q("Take out trash every tue and fri"), ["Take out trash", "2026-10-20", "FREQ=WEEKLY;BYDAY=TU,FR", 0, [], "", "due"])
eq("qa weekday list with commas", q("Gym every mon,wed,fri 6am"), ["Gym", "2026-10-19T06:00", "FREQ=WEEKLY;BYDAY=MO,WE,FR", 0, [], "", "due"])
eq("qa every 3 days", q("Water plants every 3 days"), ["Water plants", "2026-10-19", "FREQ=DAILY;INTERVAL=3", 0, [], "", "due"])
eq("qa after completion", q("Haircut every 6 weeks after completion"), ["Haircut", "2026-10-19", "FREQ=WEEKLY;INTERVAL=6", 0, [], "", "completion"])
eq("qa every other week", q("Plan every other week"), ["Plan", "2026-10-19", "FREQ=WEEKLY;INTERVAL=2", 0, [], "", "due"])
eq("qa every 15th", q("Pay card every 15th"), ["Pay card", "2026-11-15", "FREQ=MONTHLY;BYMONTHDAY=15", 0, [], "", "due"])
eq("qa yearly date", q("Anniversary every oct 31"), ["Anniversary", "2026-10-31", "FREQ=YEARLY;BYMONTH=10;BYMONTHDAY=31", 0, [], "", "due"])
eq("qa plain", q("Buy milk"), ["Buy milk", "", "", 0, [], "", "due"])
eq("qa month day + time", q("Dentist oct 31 at 10:30"), ["Dentist", "2026-10-31T10:30", "", 0, [], "", "due"])
eq("qa past M/D means next year", q("Taxes 4/15"), ["Taxes", "2027-04-15", "", 0, [], "", "due"])
eq("qa next monday 9am", q("Meeting next monday 9am"), ["Meeting", "2026-10-26T09:00", "", 0, [], "", "due"])
eq("qa in 2 weeks", q("Read in 2 weeks"), ["Read", "2026-11-02", "", 0, [], "", "due"])
eq("qa numbers stay in the title", q("Fix bug 123 and buy 2 apples"), ["Fix bug 123 and buy 2 apples", "", "", 0, [], "", "due"])
eq("qa bangs", q("Thing !!"), ["Thing", "", "", 5, [], "", "due"])
eq("qa 'on' + weekday", q("Call plumber on friday"), ["Call plumber", "2026-10-23", "", 0, [], "", "due"])
eq("qa time alone means today", q("Standup at 9:15"), ["Standup", "2026-10-19T09:15", "", 0, [], "", "due"])
eq("qa daily word", q("Vitamins daily 8am"), ["Vitamins", "2026-10-19T08:00", "FREQ=DAILY", 0, [], "", "due"])
eq("qa leading frequency word is title", q("Weekly review every friday"), ["Weekly review", "2026-10-23", "FREQ=WEEKLY;BYDAY=FR", 0, [], "", "due"])
eq("qa frequency word before an every", q("Call daily planner every monday"), ["Call daily planner", "2026-10-19", "FREQ=WEEKLY;BYDAY=MO", 0, [], "", "due"])
eq("qa 'Daily standup' stays a title", q("Daily standup"), ["Daily standup", "", "", 0, [], "", "due"])
eq("qa today", q("Ship it today !low"), ["Ship it", "2026-10-19", "", 9, [], "", "due"])
eq("qa only a date keeps the text as title", q("tomorrow"), ["tomorrow", "2026-10-20", "", 0, [], "", "due"])
eq("qa list with underscores", q("Paint @home_projects"), ["Paint", "", "", 0, [], "home projects", "due"])

// ---- views
var L = [{ id: "A", name: "Home" }, { id: "B", name: "Work" }, { id: "C", name: "Hidden", visible: false }]
var all = [
  task({ uid: "1", listId: "A", title: "overdue", due: "2026-10-17" }),
  task({ uid: "2", listId: "A", title: "today b", due: "2026-10-19", priority: 5 }),
  task({ uid: "3", listId: "B", title: "today a", due: "2026-10-19T08:00", priority: 1 }),
  task({ uid: "4", listId: "B", title: "next week", due: "2026-10-28" }),
  task({ uid: "5", listId: "A", title: "no date #x", categories: ["errand"] }),
  task({ uid: "6", listId: "A", title: "child", parent: "5" }),
  task({ uid: "7", listId: "A", title: "done child", parent: "5", status: "COMPLETED", completed: "2026-10-19T09:00" }),
  task({ uid: "8", listId: "C", title: "hidden list", due: "2026-10-19" }),
  task({ uid: "9", listId: "B", title: "tomorrow", due: "2026-10-20" }),
  task({ uid: "10", listId: "B", title: "far", due: "2026-12-05" })
]
function titles(secs) { return secs.map(function(s) { return [s.title, s.rows.map(function(r) { return r.task.title + (r.depth ? "@" + r.depth : "") })] }) }
eq("today view", titles(T.sections(all, { view: "today", todayKey: TODAY, lists: L })),
   [["Overdue", ["overdue"]], ["Today", ["today a", "today b"]]])
eq("scheduled view", titles(T.sections(all, { view: "scheduled", todayKey: TODAY, lists: L })),
   [["Overdue", ["overdue"]], ["Today", ["today a", "today b"]], ["Tomorrow", ["tomorrow"]], ["Later this month", ["next week"]], ["December", ["far"]]])
eq("list view: subtasks under their parent", titles(T.sections(all, { view: "list", listId: "A", todayKey: TODAY, lists: L })),
   [["", ["overdue", "today b", "no date #x", "child@1"]]])
var rows = T.rowsOf(T.sections(all, { view: "list", listId: "A", todayKey: TODAY, lists: L }))
eq("subtask counts include done ones", [rows[2].children, rows[2].done], [2, 1])
eq("show completed", titles(T.sections(all, { view: "list", listId: "A", todayKey: TODAY, lists: L, showCompleted: true })).pop(),
   ["Completed", ["done child"]])
eq("search by tag", titles(T.sections(all, { view: "all", todayKey: TODAY, lists: L, query: "#errand" })), [["Home", ["no date #x"]]])
eq("search words", titles(T.sections(all, { view: "all", todayKey: TODAY, lists: L, query: "TODAY b" })), [["Home", ["today b"]]])
eq("important", titles(T.sections(all, { view: "important", todayKey: TODAY, lists: L })), [["Important", ["today a"]]])
eq("priority sort", titles(T.sections(all, { view: "list", listId: "B", todayKey: TODAY, lists: L, sort: "priority" })),
   [["", ["today a", "tomorrow", "next week", "far"]]])
var cnt = T.counts(all, L, TODAY)
eq("counts", [cnt.today, cnt.scheduled, cnt.all, cnt.important, cnt.completed, cnt.overdue, cnt.lists.A, cnt.lists.C], [3, 6, 8, 1, 1, 1, 4, 1])

// ---- labels
eq("labels", [T.dateLabel("2026-10-19", TODAY), T.dateLabel("2026-10-20T17:00", TODAY, false), T.dateLabel("2026-10-23", TODAY),
              T.dateLabel("2026-11-05", TODAY), T.dateLabel("2027-01-02", TODAY), T.dateLabel("2026-10-18", TODAY)],
   ["Today", "Tomorrow 5:00 PM", "Fri", "Nov 5", "Jan 2, 2027", "Yesterday"])
eq("due states", [T.dueState(all[0], TODAY), T.dueState(all[1], TODAY), T.dueState(all[2], TODAY, "2026-10-19T09:00"), T.dueState(all[8], TODAY), T.dueState(all[9], TODAY)],
   ["overdue", "today", "overdue", "soon", "later"])

// ---- editor form
function build(form, base) { return T.buildTask(form, base || null, "2026-10-19T12:00", TODAY) }
eq("needs a title", build({ title: " ", listId: "A" }).error, "Give the task a title")
eq("bad date", build({ title: "x", listId: "A", dueDate: "someday" }).error.indexOf("not understood") > 0, true)
eq("repeat needs a date", build({ title: "x", listId: "A", rrule: "FREQ=DAILY" }).error, "A repeating task needs a due date")
eq("start after due", build({ title: "x", listId: "A", dueDate: "2026-10-20", startDate: "2026-10-21" }).error, "The task starts after it is due")
var b = build({ title: " x ", listId: "A", dueDate: "fri", dueTime: "5pm", rrule: "FREQ=WEEKLY", repeatFrom: "completion", categories: "#a, b ,", priority: 1 }).task
eq("build", [b.title, b.due, b.rrule, b.repeatFrom, b.categories, b.priority, b.status, b.uid.length], ["x", "2026-10-23T17:00", "FREQ=WEEKLY", "completion", ["a", "b"], 1, "NEEDS-ACTION", 36])
var e = build({ title: "y", listId: "B", dueDate: "", startDate: "" }, all[1]).task
eq("edit keeps the uid, clears the date", [e.uid, e.due, e.listId], ["2", "", "B"])
var keepDates = build(T.formFor(task({ due: "2026-10-19", start: "2026-10-19", rrule: "FREQ=DAILY" })), task({ due: "2026-10-19", start: "2026-10-19", rrule: "FREQ=DAILY" })).task
eq("start equal to due is not a separate start", [keepDates.start, keepDates.due], ["", "2026-10-19"])
eq("form", T.formFor(task({ due: "2026-10-20T17:00", start: "2026-10-18", priority: 3, categories: ["a", "b"] }), false),
   { title: "t", listId: "L", notes: "", dueDate: "2026-10-20", dueTime: "5:00 PM", startDate: "2026-10-18", priority: 1, rrule: "", repeatFrom: "due", categories: "a, b", parent: "", project: false })
eq("descendants", T.descendants(all, "5").map(function(t) { return t.uid }), ["6", "7"])
eq("normalize drops broken records", T.normalize({ lists: [{ id: "a" }, null], tasks: [{ uid: "x", listId: "a" }, { uid: "y" }], other: 1 }),
   { lists: [{ id: "a" }], tasks: [{ uid: "x", listId: "a" }], other: 1, version: 1, accounts: [] })

// ---- projects and subtasks
var P = [
  task({ uid: "p1", listId: "A", title: "Kitchen remodel", due: "2026-11-30" }),
  task({ uid: "c1", listId: "A", title: "Pick tiles", parent: "p1", due: "2026-10-19" }),
  task({ uid: "c2", listId: "A", title: "Call plumber", parent: "p1" }),
  task({ uid: "g1", listId: "A", title: "Measure", parent: "c2", status: "COMPLETED", completed: "2026-10-18T10:00" }),
  task({ uid: "g2", listId: "A", title: "Get quotes", parent: "c2" }),
  task({ uid: "m1", listId: "A", title: "Marked, no subtasks yet", project: true }),
  task({ uid: "x1", listId: "A", title: "Plain task" }),
  task({ uid: "h1", listId: "C", title: "Hidden list project", project: true }),
  task({ uid: "d1", listId: "A", title: "Done project", project: true, status: "COMPLETED", completed: "2026-10-01T10:00" })
]
var pr = T.projects(P, L, {})
eq("projects: subtasks or marked, open, shown lists", pr.map(function(p) { return [p.task.title, p.done, p.total] }),
   [["Kitchen remodel", 1, 4], ["Marked, no subtasks yet", 0, 0]])
eq("projects: auto off keeps only marked ones", T.projects(P, L, { autoProjects: false }).map(function(p) { return p.task.title }), ["Marked, no subtasks yet"])
eq("project view: the tree under it", titles(T.sections(P, { view: "project", projectKey: "A|p1", todayKey: TODAY, lists: L })),
   [["", ["Pick tiles", "Call plumber", "Get quotes@1"]]])
eq("project view with completed", titles(T.sections(P, { view: "project", projectKey: "A|p1", todayKey: TODAY, lists: L, showCompleted: true })).pop(),
   ["Completed", ["Measure"]])
var lrows = T.rowsOf(T.sections(P, { view: "list", listId: "A", todayKey: TODAY, lists: L, collapsed: { "A|c2": true } }))
eq("collapse folds the subtasks away", lrows.map(function(r) { return r.task.title + "@" + r.depth + (r.collapsed ? "+" : "") }),
   ["Kitchen remodel@0", "Pick tiles@1", "Call plumber@1+", "Marked, no subtasks yet@0", "Plain task@0"])
eq("today names the parent", T.rowsOf(T.sections(P, { view: "today", todayKey: TODAY, lists: L })).map(function(r) { return [r.task.title, r.parentTitle] }),
   [["Pick tiles", "Kitchen remodel"]])
var rows2 = T.rowsOf(T.sections(P, { view: "list", listId: "A", todayKey: TODAY, lists: L }))
function at(title) { for (var i = 0; i < rows2.length; i++) if (rows2[i].task.title === title) return i; return -1 }
eq("indent under the sibling above", [T.indentTarget(rows2, at("Call plumber")), T.indentTarget(rows2, at("Plain task")), T.indentTarget(rows2, at("Pick tiles")),
   T.indentTarget(rows2, at("Kitchen remodel"))], ["c1", "m1", null, null])
eq("outdent", [T.outdentTarget(P[4], P), T.outdentTarget(P[1], P), T.outdentTarget(P[0], P)], ["p1", "", null])
eq("open descendants", T.openDescendants(P, P[0]).map(function(t) { return t.uid }), ["c1", "c2", "g2"])
eq("last subtask completes its parents", T.parentsToComplete(P, P[4]).map(function(t) { return t.uid }), ["c2"])
var P2 = P.map(function(t) { return t.uid === "c1" ? T.complete(t, R, "2026-10-19T10:00").update : t })
eq("... all the way up", T.parentsToComplete(P2, P2[4]).map(function(t) { return t.uid }), ["c2", "p1"])
eq("not while others are open", T.parentsToComplete(P, P[1]).map(function(t) { return t.uid }), [])
eq("done descendants (for repeating parents)", T.doneDescendants(P, P[0]).map(function(t) { return t.uid }), ["g1"])
eq("qa ^project", (function() { var r = T.parseQuick("Order tiles ^kitchen_remodel tomorrow #errand", TODAY, R); return [r.title, r.project, r.due, r.categories] })(),
   ["Order tiles", "kitchen remodel", "2026-10-20", ["errand"]])
var pt = build({ title: "Proj", listId: "A", project: true }).task
var st = build({ title: "Sub", listId: "A", project: true, parent: "p1" }).task
eq("project flag only on top-level tasks", [pt.project, st.project], [true, false])

// ---- property: skipping one by one walks exactly the rule's expansion
;(function() {
  var seed = 12345
  function rnd(n) { seed = (seed * 1103515245 + 12345) % 2147483648; return seed % n }
  var freqs = ["DAILY", "WEEKLY", "MONTHLY", "YEARLY"], days = ["MO", "TU", "WE", "TH", "FR", "SA", "SU"]
  var bad = 0, ran = 0
  for (var n = 0; n < 400; n++) {
    var rule = { FREQ: freqs[rnd(4)] }
    if (rnd(2)) rule.INTERVAL = String(1 + rnd(3))
    if (rule.FREQ === "WEEKLY" && rnd(2)) rule.BYDAY = days.filter(function() { return rnd(3) === 0 }).join(",") || "MO"
    if (rule.FREQ === "MONTHLY" && rnd(3) === 0) rule.BYMONTHDAY = String(1 + rnd(31))
    if (rule.FREQ === "MONTHLY" && !rule.BYMONTHDAY && rnd(3) === 0) rule.BYDAY = (rnd(2) ? "-1" : String(1 + rnd(4))) + days[rnd(7)]
    if (rnd(3) === 0) rule.COUNT = String(1 + rnd(12))
    else if (rnd(3) === 0) rule.UNTIL = "2027" + T.pad2(1 + rnd(12)) + "15"
    var timed = rnd(2) === 0
    var anchor = "2026-" + T.pad2(1 + rnd(12)) + "-" + T.pad2(1 + rnd(28)) + (timed ? "T" + T.pad2(rnd(24)) + ":" + T.pad2(rnd(4) * 15) : "")
    var text = R.formatRule(rule)
    var wall = function(s) { var m = s.match(/^(\d+)-(\d+)-(\d+)(?:T(\d+):(\d+))?$/); return Date.UTC(+m[1], +m[2] - 1, +m[3], +(m[4] || 0), +(m[5] || 0)) }
    var fmt = function(ms) { var d = new Date(ms); var k = d.getUTCFullYear() + "-" + T.pad2(d.getUTCMonth() + 1) + "-" + T.pad2(d.getUTCDate()); return timed ? k + "T" + T.pad2(d.getUTCHours()) + ":" + T.pad2(d.getUTCMinutes()) : k }
    var all = R.expand(wall(anchor), !timed, text, wall("2031-01-01"), {}).map(fmt)
    if (all[0] !== anchor) continue          // DTSTART not on the rule: not what apps write
    var want = all.slice(1, 9)
    ran++
    var got = [], cur = task({ due: anchor, rrule: text })
    for (var i = 0; i < 8 && cur; i++) { cur = T.advance(cur, R, "skip", "2000-01-01"); if (cur) got.push(cur.due) }
    if (JSON.stringify(got) !== JSON.stringify(want)) {
      if (bad++ < 3) console.log("FAIL walk " + anchor + " " + text + "\n   got  " + JSON.stringify(got) + "\n   want " + JSON.stringify(want))
    }
  }
  if (bad || ran < 150) { failed++; console.log("walk: " + bad + " bad of " + ran + " run") }
  else passed++
})()

// ---- Tasks on the calendar (calendarItems), drags (dueFromMove), the popup (dueOn)
;(function() {
  var lists = [{ id: "L", name: "Home", color: "theme:blue" }, { id: "H", name: "Hidden", color: "#ff0000", visible: false }]
  var ts = [
    task({ uid: "a", title: "Pay rent", due: "2026-10-20" }),
    task({ uid: "b", title: "Call", due: "2026-10-20T14:45", priority: 1 }),
    task({ uid: "c", title: "Done one", due: "2026-10-20", status: "COMPLETED", completed: "2026-10-19T10:00" }),
    task({ uid: "d", title: "No date" }),
    task({ uid: "e", listId: "H", title: "In a hidden list", due: "2026-10-20" }),
    task({ uid: "f", title: "Overdue", due: "2026-10-17" })
  ]
  var items = T.calendarItems(ts, lists, { editable: function(t) { return t.uid !== "a" } })
  eq("one pseudo calendar per shown list", items.calendars.map(function(c) { return [c.id, c.color, c.visible] }), [["tasks:L", "theme:blue", true]])
  eq("dated, open, shown tasks only", items.events.map(function(e) { return e.taskRef }), ["L|a", "L|b", "L|f"])
  var a = items.events[0], b = items.events[1]
  eq("date-only due is all day", [a.start, a.end, a.allDay, a.calendarId], ["2026-10-20", "2026-10-20", true, "tasks:L"])
  eq("timed due is a 30 minute block", [b.start, b.end, b.allDay], ["2026-10-20T14:45", "2026-10-20T15:15", false])
  eq("title marked as a task", a.title.indexOf("Pay rent") > 0 && a.title.charAt(0) !== "P", true)
  eq("editable flag from the store", [a.taskEditable, b.taskEditable, a.readOnly], [false, true, true])
  var withDone = T.calendarItems(ts, lists, { showCompleted: true })
  eq("completed tasks when asked", withDone.events.map(function(e) { return [e.taskRef, e.taskDone] }),
     [["L|a", false], ["L|b", false], ["L|c", true], ["L|f", false]])
  eq("uids never clash with events", items.events.every(function(e) { return e.uid.indexOf("task:") === 0 }), true)

  eq("drag an all-day task: date only", T.dueFromMove(a, { start: "2026-10-23", end: "2026-10-23" }), "2026-10-23")
  eq("drag an all-day task in the week grid: still date only", T.dueFromMove(a, { start: "2026-10-23T09:00" }), "2026-10-23")
  eq("drag a timed task: new time", T.dueFromMove(b, { start: "2026-10-21T09:15", end: "2026-10-21T09:45" }), "2026-10-21T09:15")
  eq("no start: nothing", T.dueFromMove(b, {}), "")

  eq("popup today: overdue first, then timed, then untimed",
     T.dueOn(ts, lists, "2026-10-20", "2026-10-20").map(function(t) { return t.uid }), ["f", "b", "a"])
  eq("popup another day: that day only", T.dueOn(ts, lists, "2026-10-17", "2026-10-20").map(function(t) { return t.uid }), ["f"])
  eq("popup future day without overdue", T.dueOn(ts, lists, "2026-10-21", "2026-10-20").map(function(t) { return t.uid }), [])

  // The stand-ins go through the calendar's own day index unchanged.
  var E = require("../Events.js")
  var cals = [{ id: "cal", visible: true }].concat(items.calendars)
  var idx = E.buildIndex([{ uid: "ev", calendarId: "cal", title: "Lunch", start: "2026-10-20T12:00", end: "2026-10-20T13:00", allDay: false }].concat(items.events), cals)
  eq("indexed with events", E.eventsOn(idx, "2026-10-20").map(function(e) { return e.uid }), ["task:L|a", "ev", "task:L|b"])
  eq("overdue task on its own day", E.eventsOn(idx, "2026-10-17").map(function(e) { return e.uid }), ["task:L|f"])
})()

console.log(failed ? failed + " FAILED, " + passed + " passed" : "all " + passed + " passed")
process.exit(failed ? 1 : 0)
