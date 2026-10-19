//@ pragma OmarchyLoadPatch
import QtQuick
import QtTest
import Quickshell
import qs.Commons
import "Tasks.js" as Tasks

// Projects and subtasks through the window: the project view and its quick
// add, Tab / Shift+Tab, folding, the "complete the subtasks too?" question,
// auto-completing parents, repeating parents, ^Project, moving a project with
// its subtasks. Run by tests/run_qml_tasks.py.
ShellRoot {
  id: h
  function out(s) { console.log("P|" + s) }
  function check(name, ok, detail) { h.out((ok ? "PASS " : "FAIL ") + name + (detail !== undefined ? " | " + detail : "")) }

  Store { id: calStore }
  TaskStore { id: store; calendarStore: calStore }
  CalendarWindow { id: win; store: calStore; taskStore: store; visible: true }
  TestCase { id: tc; name: "projects"; when: false }

  function type(text) { text.split("").forEach(function(ch) { tc.keyClick(ch) }) }
  function find(title) { return store.allTasks.filter(function(t) { return t.title === title })[0] || null }
  function select(title) { var t = h.find(title); win.selectedTaskKey = t.listId + "|" + t.uid }
  function proj(title) { return store.projects.filter(function(p) { return p.task.title === title })[0] || null }
  readonly property string today: store.todayKey
  property string errands: ""
  property string reviewDue: ""

  property var steps: [
    { act: function() {
        var p = h.proj("Write report")
        h.check("a task with subtasks is a project", p && p.total === 1 && p.done === 0, JSON.stringify(p))
        h.check("plain tasks are not", !h.proj("Someday"))
        win.showProject("list-inbox|T-1")
        tc.keyClick(Qt.Key_N)
        h.type("Draft intro tomorrow #desk")
        tc.keyClick(Qt.Key_Return)
      },
      until: function() { return !!h.find("Draft intro") } },
    { act: function() {
        var t = h.find("Draft intro")
        h.check("quick add in a project adds a step", t.parent === "T-1" && t.due === Tasks.addDaysKey(h.today, 1) && t.categories.join() === "desk", JSON.stringify(t))
        h.check("progress counts it", h.proj("Write report").total === 2)
        tc.keyClick(Qt.Key_Escape)
        win.showList("list-inbox")
        h.select("Someday")
        tc.keyClick(Qt.Key_Tab)
      },
      until: function() { return h.find("Someday").parent === "T-1" } },
    { act: function() {
        h.check("Tab makes it a subtask of the task above", true)
        h.select("Someday")
        tc.keyClick(Qt.Key_Backtab, Qt.ShiftModifier)
      },
      until: function() { return h.find("Someday").parent === "" } },
    { act: function() {
        h.check("Shift+Tab moves it back up", true)
        h.select("Write report")
        tc.keyClick(Qt.Key_Left)
      } },
    { act: function() {
        var rows = h.walk(win.contentItem, function(it) { return it.rows !== undefined && it.indent !== undefined }).rows
        h.check("Left folds the subtasks", store.collapsed["list-inbox|T-1"] === true && !rows.some(function(r) { return r.task.title === "Outline" }),
                rows.map(function(r) { return r.task.title }).join(","))
        tc.keyClick(Qt.Key_Right)
      } },
    { act: function() {
        h.check("Right unfolds them", !store.collapsed["list-inbox|T-1"])
        h.select("Write report")
        tc.keyClick(Qt.Key_Space)
      } },
    { act: function() {
        h.check("asks about open subtasks", store.confirmComplete && store.confirmComplete.open.length === 2 && !Tasks.isDone(h.find("Write report")))
        tc.keyClick(Qt.Key_A)
      },
      until: function() { return Tasks.isDone(h.find("Write report")) && Tasks.isDone(h.find("Outline")) && Tasks.isDone(h.find("Draft intro")) } },
    { act: function() {
        h.check("a completes the project and its steps", !h.proj("Write report"))
        tc.keyClick(Qt.Key_Z, Qt.ControlModifier)
      },
      until: function() { return !Tasks.isDone(h.find("Write report")) && !Tasks.isDone(h.find("Outline")) && !Tasks.isDone(h.find("Draft intro")) } },
    { act: function() {
        h.check("one undo reopens all three", !!h.proj("Write report"))
        store.setPref("autoCompleteParent", true)
        store.toggleComplete(h.find("Outline"))
      },
      until: function() { return Tasks.isDone(h.find("Outline")) } },
    { act: function() {
        h.check("parent stays open while a step is left", !Tasks.isDone(h.find("Write report")))
        store.toggleComplete(h.find("Draft intro"))
      },
      until: function() { return Tasks.isDone(h.find("Write report")) } },
    { act: function() {
        h.check("the last step completes the project", store.notice.indexOf("also") !== -1, store.notice)
        store.setPref("autoCompleteParent", false)
        store.toggleComplete(h.find("Write report"))     // reopen the project...
        store.toggleComplete(h.find("Draft intro"))      // ...and one step
        store.quickAdd("Weekly review every friday", "list-inbox", "")
      },
      until: function() { return !!h.find("Weekly review") && !Tasks.isDone(h.find("Write report")) && !Tasks.isDone(h.find("Draft intro")) } },
    { act: function() {
        store.quickAdd("Clear inbox ^weekly", "", "")
      },
      until: function() { return !!h.find("Clear inbox") } },
    { act: function() {
        var review = h.find("Weekly review")
        h.check("^Project adds a step to it", h.find("Clear inbox").parent === review.uid)
        store.toggleComplete(h.find("Clear inbox"))
      },
      until: function() { return Tasks.isDone(h.find("Clear inbox")) } },
    { act: function() { h.reviewDue = h.find("Weekly review").due; store.toggleComplete(h.find("Weekly review")) },
      until: function() { return store.allTasks.some(function(t) { return t.title === "Weekly review" && !Tasks.isDone(t) && t.due > h.reviewDue }) } },
    { act: function() {
        var open = store.allTasks.filter(function(t) { return t.title === "Weekly review" && !Tasks.isDone(t) })[0]
        h.check("repeating project moved on a week", open && open.due === Tasks.addDaysKey(h.reviewDue, 7), open && open.due)
        h.check("its steps reopened for next time", !Tasks.isDone(h.find("Clear inbox")))
        win.showSmart("scheduled")
      } },
    { act: function() {
        var rows = h.walk(win.contentItem, function(it) { return it.rows !== undefined && it.indent !== undefined }).rows
        var r = rows.filter(function(x) { return x.task.title === "Draft intro" })[0]
        h.check("date views name the parent", r && r.parentTitle === "Write report", r && r.parentTitle)
        h.errands = store.addLocalList("Errands", "theme:green")
        var p = Tasks.copy(h.find("Write report"))
        p.listId = h.errands
        store.saveTask(p, h.find("Write report"), function(err) { if (err) h.check("move", false, err) })
      },
      until: function() { return h.find("Write report").listId === h.errands && h.find("Outline").listId === h.errands } },
    { act: function() {
        h.check("moving a project takes its steps", h.find("Draft intro").listId === h.errands && h.find("Draft intro").parent === "T-1"
                && store.tasks.filter(function(t) { return t.listId === "list-inbox" && t.parent === "T-1" }).length === 0)
        h.check("still a project there", h.proj("Write report") && h.proj("Write report").key === h.errands + "|T-1")
        tc.keyClick(Qt.Key_P, Qt.ShiftModifier)
      } },
    { act: function() {
        var ed = h.walk(win.contentItem, function(it) { return it.formProject !== undefined })
        h.check("P opens a new project", win.drawer === "task" && ed && ed.formProject === true)
        tc.keyClick(Qt.Key_Escape)
        store.setPref("autoProjects", false)
      } },
    { act: function() {
        h.check("auto projects off: only marked ones", store.projects.length === 0, store.projects.map(function(p) { return p.task.title }).join())
        store.setPref("autoProjects", true)
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
      var ok = false
      try { ok = !s.until || s.until() } catch (e2) { ok = false }
      if (!ok && Date.now() - h.since < 10000) return
      if (!ok) h.check("step " + h.step + " condition", false, "timed out")
      h.step++
      h.acted = false
    }
  }
  Timer { interval: 120000; running: true; onTriggered: { h.out("timeout " + h.step); Qt.quit() } }
}
