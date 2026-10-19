//@ pragma OmarchyLoadPatch
import QtQuick
import Quickshell
import qs.Commons
import "Tasks.js" as Tasks

// The list and task editors against the store and a real CalDAV server:
// adding lists through an account already connected for calendars, creating a list on the
// server, a repeating task from the form, moving a task between a local
// list and the server, subtasks, delete. Run by tests/run_qml_tasks.py.
ShellRoot {
  id: h
  function out(s) { console.log("E|" + s) }
  function check(name, ok, detail) { h.out((ok ? "PASS " : "FAIL ") + name + (detail !== undefined ? " | " + detail : "")) }

  Store { id: calStore }
  TaskStore { id: store; calendarStore: calStore }

  FloatingWindow {
    visible: true
    implicitWidth: 420
    implicitHeight: 900
    color: Color.background
    Column {
      width: 380
      ListEditor { id: lists; width: parent.width; store: store; onFinished: h.finishedLists++ }
      TaskEditor { id: editor; width: parent.width; store: store; use24h: true; onFinished: function(key) { h.lastKey = key; h.finishedTasks++ } }
    }
  }

  property int finishedLists: 0
  property int finishedTasks: 0
  property string lastKey: ""
  property string groceries: ""
  property string errands: ""
  readonly property string today: store.todayKey
  function find(title) { return store.allTasks.filter(function(t) { return t.title === title }) }
  function listNamed(n) { return store.lists.filter(function(l) { return l.name === n })[0] }

  property var steps: [
    { act: function() {
        lists.openNew("account")
        h.check("connected account offered first", lists.source === "acc:acc-cal-qml", lists.source)
        lists.save()
      },
      until: function() { return lists.picking } },
    { act: function() {
        h.check("found the shared calendar", lists.discovered.length === 1 && lists.discovered[0].mixed, JSON.stringify(lists.discovered))
        h.check("mixed calendar pre-ticked when nothing else", lists.discovered[0].picked)
        // Create a task-only list on the server instead.
        var f = h.walk(lists, function(it) { return it.placeholderText === "e.g. Tasks, Groceries" })
        f.text = "Groceries"
        lists.createRemote()
      },
      until: function() { return h.finishedLists === 1 } },
    { act: function() {
        var g = h.listNamed("Groceries")
        h.check("list created on the server", g && g.source.type === "caldav" && !g.source.mixed && /\/qmltaskseditors\//.test(g.source.url), JSON.stringify(g))
        h.groceries = g ? g.id : ""
        h.check("still one shared account", calStore.accounts.length === 1 && calStore.accounts[0].id === "acc-cal-qml", JSON.stringify(calStore.accounts))
        lists.openNew("account")
        h.check("the account is offered again", lists.source === "acc:acc-cal-qml" && lists.accountOptions.length === 2, JSON.stringify(lists.accountOptions))
        lists.save()
      },
      until: function() { return lists.picking } },
    { act: function() {
        h.check("Groceries shows as added", lists.discovered.some(function(l) { return l.name === "Groceries" && l.already }), JSON.stringify(lists.discovered))
        lists.cancel()
        lists.openNew("local")
        h.walk(lists, function(it) { return it.placeholderText === "List name" }).text = "Errands"
        lists.save()
      },
      until: function() { return h.finishedLists === 3 } },
    { act: function() {
        h.errands = h.listNamed("Errands").id
        h.check("cancelling kept the account", store.accounts.length === 1)
        editor.openNew(h.errands)
        var first = Tasks.addMonthsKey(h.today.substr(0, 8) + "01", 1)
        editor.fill({ title: "Pay rent", listId: h.errands, notes: "landlord", dueDate: first, dueTime: "", startDate: "", priority: 1,
                      rrule: "FREQ=MONTHLY;BYMONTHDAY=1", repeatFrom: "due", categories: "bills, home", parent: "" })
        editor.save()
      },
      until: function() { return h.finishedTasks === 1 } },
    { act: function() {
        var t = h.find("Pay rent")[0]
        h.check("repeating task from the form", t && t.rrule === "FREQ=MONTHLY;BYMONTHDAY=1" && t.due.substr(8) === "01" && t.priority === 1
                && t.categories.join() === "bills,home" && t.listId === h.errands, JSON.stringify(t))
        editor.openNew(h.errands)
        editor.fill({ title: "Stretch", listId: h.errands, notes: "", dueDate: "", dueTime: "", startDate: "", priority: 0,
                      rrule: "FREQ=DAILY", repeatFrom: "completion", categories: "", parent: "" })
        editor.save()
      },
      until: function() { return h.finishedTasks === 2 } },
    { act: function() {
        var t = h.find("Stretch")[0]
        h.check("repeat without a date starts today", t && t.due === h.today && t.repeatFrom === "completion", JSON.stringify(t))
        editor.openNew(h.errands)
        editor.fill({ title: "", listId: h.errands, notes: "", dueDate: "", dueTime: "", startDate: "", priority: 0, rrule: "", repeatFrom: "due", categories: "", parent: "" })
        editor.save()
        h.check("empty title refused", editor.formError === "Give the task a title", editor.formError)
        editor.fill({ title: "Bad", listId: h.errands, notes: "", dueDate: "someday soon", dueTime: "", startDate: "", priority: 0, rrule: "", repeatFrom: "due", categories: "", parent: "" })
        editor.save()
        h.check("bad date refused", editor.formError.indexOf("not understood") !== -1, editor.formError)
        editor.cancel()
        // Subtask, then move the parent to the server list.
        var rent = h.find("Pay rent")[0]
        store.quickAdd("Get the checkbook", h.errands, rent.uid)
        editor.openEdit(rent)
        var f = Tasks.formFor(rent, true)
        f.listId = h.groceries
        f.title = "Pay rent (moved)"
        editor.fill(f)
        editor.save()
      },
      until: function() { return h.finishedTasks === 4 && !store.busy && Object.keys(store.pending).length === 0 } },
    { act: function() {
        var moved = h.find("Pay rent (moved)")
        h.check("moved to the server list, same uid", moved.length === 1 && moved[0].listId === h.groceries && !!moved[0].href
                && moved[0].rrule === "FREQ=MONTHLY;BYMONTHDAY=1" && moved[0].notes === "landlord", JSON.stringify(moved))
        h.check("gone from the local list", store.tasks.filter(function(t) { return t.title.indexOf("Pay rent") === 0 }).length === 0)
        var sub = h.find("Get the checkbook")[0]
        h.check("its subtask moved along", sub && sub.listId === h.groceries && !!sub.href && sub.parent === moved[0].uid, sub && JSON.stringify(sub))
        // Complete the moved series from the editor.
        editor.openEdit(moved[0])
        editor.toggleDone()
      },
      until: function() { return h.find("Pay rent (moved)").length === 2 && !store.busy && Object.keys(store.pending).length === 0 } },
    { act: function() {
        var open = h.find("Pay rent (moved)").filter(function(t) { return !Tasks.isDone(t) })[0]
        h.check("completed from the editor: next month", open && open.due === Tasks.addMonthsKey(h.find("Pay rent (moved)").filter(Tasks.isDone)[0].due, 1), open && open.due)
        editor.openEdit(open)
        editor.remove()
        h.check("delete asks first", editor.confirmDelete && h.find("Pay rent (moved)").length === 2)
        editor.remove()
      },
      until: function() { return h.find("Pay rent (moved)").length === 1 && !store.busy && Object.keys(store.pending).length === 0 } },
    { act: function() {
        h.check("deleted on the server", h.find("Pay rent (moved)").every(Tasks.isDone))
        store.syncAll()
      },
      until: function() { return !store.busy } },
    { act: function() {
        h.check("a full sync agrees", h.find("Pay rent (moved)").length === 1 && h.find("Pay rent (moved)")[0].status === "COMPLETED")
        var g = store.listById(h.groceries)
        lists.openEdit(g)
        lists.remove()
        lists.remove()
        h.check("removing a server list only unsubscribes", !store.listById(h.groceries) && store.accounts.length === 0)
      } }
  ]

  function walk(item, pred) {
    if (!item) return null
    if (pred(item)) return item
    var kids = item.children || []
    for (var i = 0; i < kids.length; i++) { var r = walk(kids[i], pred); if (r) return r }
    if (item.contentItem && item.contentItem !== item) return walk(item.contentItem, pred)
    return null
  }

  property int step: 0
  property bool acted: false
  property real since: 0
  Timer {
    interval: 300; repeat: true; running: store.ready
    onTriggered: {
      if (h.step >= h.steps.length) { h.out("done"); Qt.quit(); return }
      var s = h.steps[h.step]
      if (!h.acted) {
        h.acted = true
        h.since = Date.now()
        try { s.act() } catch (e) { h.check("step " + h.step, false, String(e)) }
        return
      }
      var ok = !s.until || s.until()
      if (!ok && Date.now() - h.since < 15000) return
      if (!ok) h.check("step " + h.step + " condition", false, "timed out")
      h.step++
      h.acted = false
    }
  }
  Timer { interval: 120000; running: true; onTriggered: { h.out("timeout " + h.step); Qt.quit() } }
}
