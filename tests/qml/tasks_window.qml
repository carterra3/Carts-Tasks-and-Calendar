//@ pragma OmarchyLoadPatch
import QtQuick
import QtTest
import Quickshell
import qs.Commons
import "Tasks.js" as Tasks

// The window as a whole: keys, quick add, completing a repeating task (local
// and on a CalDAV server reached through the Calendar app's account), undo,
// delete. Run by tests/run_qml_tasks.py.
ShellRoot {
  id: h
  function out(s) { console.log("W|" + s) }
  function check(name, ok, detail) { h.out((ok ? "PASS " : "FAIL ") + name + (detail !== undefined ? " | " + detail : "")) }

  Store { id: calStore }
  TaskStore { id: store; calendarStore: calStore }
  CalendarWindow { id: win; store: calStore; taskStore: store; visible: true }
  TestCase { id: tc; name: "window"; when: false }

  function type(text) { text.split("").forEach(function(ch) { tc.keyClick(ch) }) }
  function find(title, listId) {
    return store.allTasks.filter(function(t) { return t.title === title && (!listId || t.listId === listId) })
  }
  function select(t) { win.selectedTaskKey = t.listId + "|" + t.uid }
  readonly property string today: store.todayKey
  property string remoteList: ""
  property var res: null

  // Each step: act once, wait until `until` holds (or 15 s), then check.
  property var steps: [
    { act: function() {
        h.check("starts on Today", win.taskView === "today", win.taskView)
        h.check("today count", store.counts.today === 1, store.counts.today)
        tc.keyClick(Qt.Key_3)
      } },
    { act: function() {
        h.check("3 = All", win.taskView === "all", win.taskView)
        tc.keyClick(Qt.Key_N)
      } },
    { act: function() { h.type("Water plants every 3 days !high"); tc.keyClick(Qt.Key_Return) },
      until: function() { return h.find("Water plants").length === 1 } },
    { act: function() {
        var t = h.find("Water plants")[0]
        h.check("quick add parsed", t.rrule === "FREQ=DAILY;INTERVAL=3" && t.due === h.today && t.priority === 1 && t.listId === "list-inbox",
                JSON.stringify(t))
        h.select(t)
        tc.keyClick(Qt.Key_Escape)      // leaves the quick-add field
        tc.keyClick(Qt.Key_Space)
      },
      until: function() { return h.find("Water plants").length === 2 } },
    { act: function() {
        var all = h.find("Water plants")
        var open = all.filter(function(t) { return !Tasks.isDone(t) })[0]
        var done = all.filter(Tasks.isDone)[0]
        h.check("space completes: series moves 3 days", open && open.due === Tasks.addDaysKey(h.today, 3), open && open.due)
        h.check("completed copy kept", done && done.due === h.today && !done.rrule && done.completed.indexOf(h.today) === 0, done && JSON.stringify(done))
        h.check("undo offered", store.lastAction && store.lastAction.kind === "complete" && store.notice.indexOf("next") !== -1, store.notice)
        tc.keyClick(Qt.Key_Z, Qt.ControlModifier)
      },
      until: function() { return h.find("Water plants").length === 1 } },
    { act: function() {
        var t = h.find("Water plants")[0]
        h.check("ctrl+z undoes the completion", t.due === h.today && !Tasks.isDone(t), JSON.stringify(t))
        tc.keyClick(Qt.Key_N, Qt.ShiftModifier)
      } },
    { act: function() {
        h.check("N opens a new task", win.drawer === "task", win.drawer)
        tc.keyClick(Qt.Key_Escape)
      } },
    { act: function() {
        h.check("Esc closes the drawer", win.drawer === "", win.drawer)
        h.select(h.find("Write report")[0])
        tc.keyClick(Qt.Key_E)
      } },
    { act: function() {
        h.check("e edits the selected task", win.drawer === "task" && h.walk(win.contentItem, function(it) { return it.editing !== undefined && it.editing && it.editing.title === "Write report" }) !== null)
        tc.keyClick(Qt.Key_Escape)
        h.select(h.find("Write report")[0])
        tc.keyClick(Qt.Key_Delete)
      },
      until: function() { return h.find("Write report").length === 0 } },
    { act: function() {
        h.check("Delete takes the subtasks too", h.find("Outline").length === 0)
        tc.keyClick(Qt.Key_Z, Qt.ControlModifier)
      },
      until: function() { return h.find("Write report").length === 1 && h.find("Outline").length === 1 } },
    { act: function() {
        h.check("undo brings both back", h.find("Outline")[0].parent === "T-1")
        h.check("keys work after the editor closed", (function() { tc.keyClick(Qt.Key_1); return win.taskView === "today" })())
        // Lists from the account the calendars use.
        store.discoverLists({ accountId: "acc-cal-qml" }, function(r) { h.res = r })
      },
      until: function() { return h.res !== null } },
    { act: function() {
        h.check("discover via the shared account", h.res.ok && h.res.lists.length === 1 && h.res.accountId === "acc-cal-qml", JSON.stringify(h.res))
        var ids = store.addAccountLists(h.res.accountId, h.res.account, h.res.lists)
        h.remoteList = ids[0]
        h.check("no second account", calStore.accounts.length === 1, JSON.stringify(calStore.accounts))
      },
      until: function() { return h.find("Take out recycling").length === 1 } },
    { act: function() {
        var t = h.find("Take out recycling")[0]
        h.check("synced reminder is overdue", t.due === Tasks.addDaysKey(h.today, -1) && t.rrule === "FREQ=WEEKLY", JSON.stringify(t))
        h.check("events are not tasks", h.find("Meeting").length === 0)
        h.check("overdue counted", store.counts.overdue === 1, store.counts.overdue)
        win.showList(h.remoteList)
        h.select(t)
        tc.keyClick(Qt.Key_X)
      },
      until: function() { return h.find("Take out recycling").length === 2 && !store.busy && Object.keys(store.pending).length === 0 } },
    { act: function() {
        var all = h.find("Take out recycling")
        var open = all.filter(function(t) { return !Tasks.isDone(t) })[0]
        var done = all.filter(Tasks.isDone)[0]
        h.check("remote: next week, saved on the server", open && open.due === Tasks.addDaysKey(h.today, 6) && !!open.href, open && JSON.stringify(open))
        h.check("remote: history copy on the server", done && !!done.href && done.status === "COMPLETED", done && JSON.stringify(done))
        tc.keyClick(Qt.Key_Z, Qt.ControlModifier)
      },
      until: function() { return h.find("Take out recycling").length === 1 && !store.busy && Object.keys(store.pending).length === 0 } },
    { act: function() {
        var t = h.find("Take out recycling")[0]
        h.check("remote undo", t.due === Tasks.addDaysKey(h.today, -1) && !Tasks.isDone(t), JSON.stringify(t))
        h.select(t)
        tc.keyClick(Qt.Key_S)
      },
      until: function() { var t = h.find("Take out recycling")[0]; return t && t.due === Tasks.addDaysKey(h.today, 6) && !store.busy } },
    { act: function() {
        h.check("s skips to the next date", true)
        h.check("no errors from the helper", store.notice.indexOf("⚠") === -1 && !store.noticeError, store.notice)
        tc.keyClick(Qt.Key_1)
        tc.keyClick(Qt.Key_N)
        h.type("Buy milk")
        tc.keyClick(Qt.Key_Return)
      },
      until: function() { return h.find("Buy milk").length === 1 } },
    { act: function() {
        var t = h.find("Buy milk")[0]
        h.check("quick add in Today is due today", t.due === h.today && t.listId === "list-inbox", JSON.stringify(t))
        tc.keyClick(Qt.Key_Escape)
        tc.keyClick(Qt.Key_J)
        h.check("Esc leaves quick add; j moves again", !!win.selectedTaskKey, win.selectedTaskKey)
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
