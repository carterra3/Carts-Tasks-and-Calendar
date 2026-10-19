//@ pragma OmarchyLoadPatch
import QtQuick
import QtTest
import Quickshell
import qs.Commons
import "Tasks.js" as Tasks
import "Events.js" as Events

// Tasks and the calendar together: tasks on the calendar views and the
// setting that turns them off, clicking and dragging one, completed tasks,
// the mode keys, the settings drawer, the popup's task list, and accounts
// shared between calendars and task lists. Wired like CalendarApp.qml.
// Run by tests/run_qml_tasks.py.
ShellRoot {
  id: h
  function out(s) { console.log("C|" + s) }
  function check(name, ok, detail) { h.out((ok ? "PASS " : "FAIL ") + name + (detail !== undefined ? " | " + detail : "")) }

  Store {
    id: calStore
    taskEvents: bridge.items.events
    taskCalendars: bridge.items.calendars
    taskHandler: bridge
  }
  TaskStore { id: store; calendarStore: calStore }
  TaskBridge {
    id: bridge
    taskStore: store
    enabled: calStore.pref("tasksOnCalendar", true)
    showCompleted: calStore.pref("tasksOnCalendarCompleted", false)
  }
  CalendarWindow { id: win; store: calStore; taskStore: store; visible: true }
  TestCase { id: tc; name: "tasks_calendar"; when: false }

  // The popup's task list (outside a window, so the keys stay with `win`).
  PopupTasks { id: popup; visible: false; width: 330; store: store; dayKey: h.today; todayKey: h.today }

  readonly property string today: store.todayKey
  readonly property string collection: Quickshell.env("QML_TEST_COLLECTION")
  function standIns(key) { return calStore.eventsOn(key).filter(function(e) { return !!e.taskRef }) }
  function standIn(key, ref) { return h.standIns(key).filter(function(e) { return e.taskRef === ref })[0] || null }
  function task(uid) { return store.taskByKey("list-inbox", uid) }
  property string listId: ""

  property var steps: [
    { act: function() {
        win.setMode("calendar")
        win.present(h.today, "month")
        var s = h.standIn(h.today, "list-inbox|T-1")
        h.check("a task due today is on the calendar", !!s && s.title.indexOf("Write report") > 0 && s.allDay, JSON.stringify(s))
        h.check("only dated tasks", h.standIns(h.today).length === 1, h.standIns(h.today).length)
        h.check("in its list's color", calStore.calendarColor("tasks:list-inbox") === calStore.colorFor("theme:blue"))
        h.check("editable", calStore.eventEditable(s))
        h.check("pseudo calendars stay out of the calendar list", calStore.calendars.every(function(c) { return String(c.id).indexOf("tasks:") !== 0 }))
        calStore.setPref("tasksOnCalendar", false)
      },
      until: function() { return h.standIns(h.today).length === 0 } },
    { act: function() {
        h.check("the setting takes tasks off the calendar", h.standIns(h.today).length === 0)
        calStore.setPref("tasksOnCalendar", true)
      },
      until: function() { return h.standIns(h.today).length === 1 } },
    { act: function() {
        // Clicking a task in a calendar view opens the task editor, in place.
        win.editEvent(h.standIn(h.today, "list-inbox|T-1"))
        h.check("click opens the task editor", win.drawer === "task" && win.calendarMode, win.drawer + " " + win.mode)
        tc.keyClick(Qt.Key_Escape)
        h.check("Esc closes it", win.drawer === "", win.drawer)
        h.check("popup lists today's task", popup.tasks.length === 1 && popup.tasks[0].uid === "T-1", popup.tasks.length)
        // Dragging it two days on.
        var s = h.standIn(h.today, "list-inbox|T-1")
        calStore.moveEvent(s, Events.movedByDays(s, 2), function(err) { if (err) h.check("move", false, err) })
      },
      until: function() { return h.task("T-1") && h.task("T-1").due === Tasks.addDaysKey(h.today, 2) } },
    { act: function() {
        var key = Tasks.addDaysKey(h.today, 2)
        h.check("drag moved the due date", h.task("T-1").due === key, h.task("T-1").due)
        h.check("and the task on the calendar", !!h.standIn(key, "list-inbox|T-1") && !h.standIn(h.today, "list-inbox|T-1"))
        h.check("popup: nothing due today now", popup.tasks.length === 0, popup.tasks.length)
        popup.dayKey = key
        h.check("popup: the task on its new day", popup.tasks.length === 1)
        popup.dayKey = Qt.binding(function() { return h.today })
        // A timed task.
        store.quickAdd("Call the plumber tomorrow at 2:30pm", "list-inbox", "", {})
      },
      until: function() { return h.standIns(Tasks.addDaysKey(h.today, 1)).length === 1 } },
    { act: function() {
        var key = Tasks.addDaysKey(h.today, 1)
        var s = h.standIns(key)[0]
        h.check("timed task is a timed block", s && !s.allDay && s.start === key + "T14:30" && s.end === key + "T15:00", JSON.stringify(s))
        calStore.moveEvent(s, Events.moved(s, key + "T09:15"), function(err) { if (err) h.check("move timed", false, err) })
      },
      until: function() { return store.allTasks.some(function(t) { return t.title === "Call the plumber" && t.due === Tasks.addDaysKey(h.today, 1) + "T09:15" }) } },
    { act: function() {
        h.check("drag in the week grid sets the time", true)
        store.toggleComplete(h.task("T-1"), null, { subtasks: "none" })
      },
      until: function() { return Tasks.isDone(h.task("T-1")) && !h.standIn(Tasks.addDaysKey(h.today, 2), "list-inbox|T-1") } },
    { act: function() {
        h.check("completed tasks leave the calendar", true)
        calStore.setPref("tasksOnCalendarCompleted", true)
      },
      until: function() { return !!h.standIn(Tasks.addDaysKey(h.today, 2), "list-inbox|T-1") } },
    { act: function() {
        var s = h.standIn(Tasks.addDaysKey(h.today, 2), "list-inbox|T-1")
        h.check("…unless asked for", s.taskDone && s.title.indexOf("Write report") > 0, JSON.stringify(s))
        // Mode keys.
        tc.keyClick(Qt.Key_2, Qt.ControlModifier)
        h.check("Ctrl+2 = tasks", win.tasksMode && calStore.pref("windowMode", "") === "tasks", win.mode)
        tc.keyClick(Qt.Key_3, Qt.ControlModifier)
        h.check("Ctrl+3 = contacts", win.contactsMode, win.mode)
        tc.keyClick(Qt.Key_Tab, Qt.ControlModifier)
        h.check("Ctrl+Tab cycles", win.calendarMode, win.mode)
        tc.keyClick(Qt.Key_Comma, Qt.ControlModifier)
        h.check("Ctrl+, opens settings", win.drawer === "settings", win.drawer)
        tc.keyClick(Qt.Key_2, Qt.ControlModifier)
        h.check("settings stay open across modes", win.drawer === "settings" && win.tasksMode, win.drawer)
        tc.keyClick(Qt.Key_Escape)
        h.check("tasks keys work after", (function() { tc.keyClick(Qt.Key_3); return win.taskView === "all" })(), win.taskView)
        tc.keyClick(Qt.Key_1, Qt.ControlModifier)
        // Accounts are shared: a task list from the calendars' account.
        h.listId = store.addAccountLists("acc-cal-qml", null, [{ url: h.collection, name: "Home", readOnly: false }])[0] || ""
      },
      until: function() { return calStore.taskAccountIds.indexOf("acc-cal-qml") !== -1 } },
    { act: function() {
        h.check("the calendar store sees the task list's account", true)
        h.check("no account copy", calStore.accounts.length === 1, JSON.stringify(calStore.accounts))
        calStore.releaseAccount("acc-cal-qml")
        h.check("an account in use by a task list is kept", !!calStore.accountById("acc-cal-qml"))
        store.removeList(h.listId)
      },
      until: function() { return !calStore.accountById("acc-cal-qml") } },
    { act: function() { h.check("removing its last list releases the account", calStore.accounts.length === 0) } }
  ]

  property int step: 0
  property bool acted: false
  property real since: 0
  Timer {
    interval: 300; repeat: true; running: store.ready && calStore.ready
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
