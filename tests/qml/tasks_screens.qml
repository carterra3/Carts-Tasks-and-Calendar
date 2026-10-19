//@ pragma OmarchyLoadPatch
import QtQuick
import Quickshell
import qs.Commons
import "Tasks.js" as Tasks

// Renders the window offscreen in a few states and, when SHOT_DIR is set,
// saves PNGs there (for looking at the layout without opening a window on
// the desktop). Checks only that every view renders. Run by tests/run_qml_tasks.py.
ShellRoot {
  id: h
  function out(s) { console.log("S|" + s) }
  function check(name, ok, detail) { h.out((ok ? "PASS " : "FAIL ") + name + (detail !== undefined ? " | " + detail : "")) }

  readonly property string dir: Quickshell.env("SHOT_DIR") || ""
  Store {
    id: calStore
    taskEvents: bridge.items.events
    taskCalendars: bridge.items.calendars
    taskHandler: bridge
  }
  TaskStore { id: store; calendarStore: calStore }
  TaskBridge { id: bridge; taskStore: store; enabled: calStore.pref("tasksOnCalendar", true) }

  // The bar popup's task list, on its own (the popup needs the bar).
  FloatingWindow {
    id: popupWin
    visible: true
    implicitWidth: 360
    implicitHeight: 320
    color: Color.background
    PopupTasks { id: popupTasks; x: 15; y: 15; width: 330; store: store; dayKey: store.todayKey; todayKey: store.todayKey }
  }
  CalendarWindow { id: win; store: calStore; taskStore: store; visible: true; implicitWidth: 1280; implicitHeight: 800 }

  property int saved: 0
  function shot(name) {
    win.contentItem.children[0].grabToImage(function(r) {
      if (h.dir) r.saveToFile(h.dir + "/" + name + ".png")
      h.saved++
      h.check("render " + name, r.image !== undefined)
    })
  }

  property var res: null
  property var steps: [
    { act: function() {
        ["Call mom tomorrow at 5pm", "Pay rent every month on the 1st #bills !high", "Stretch every weekday 7am",
         "Renew passport oct 31 !!", "Water plants every 3 days", "Haircut every 6 weeks after completion",
         "Buy oat milk #errand", "Book dentist next monday !low", "Backup laptop every sunday"].forEach(function(t) { store.quickAdd(t, "list-inbox", "") })
        store.discoverLists({ accountId: "acc-cal-qml" }, function(r) { h.res = r })
      },
      until: function() { return h.res !== null } },
    { act: function() { store.addAccountLists(h.res.accountId, h.res.account, h.res.lists) },
      until: function() { return store.allTasks.some(function(t) { return t.title === "Take out recycling" }) } },
    { act: function() { win.showSmart("today") } },
    { act: function() { h.shot("1-today") } },
    { act: function() { win.showSmart("scheduled") } },
    { act: function() { h.shot("2-scheduled") } },
    { act: function() { win.showList("list-inbox"); store.setPref("showCompleted", true) } },
    { act: function() {
        var t = store.allTasks.filter(function(x) { return x.title === "Pay rent" })[0]
        win.editTask(t)
      } },
    { act: function() { h.shot("3-list-editor") } },
    { act: function() { win.closeDrawer(); win.openListEditor(null) } },
    { act: function() { h.shot("4-add-list") } },
    { act: function() { win.closeDrawer(); win.showSmart("all") } },
    { act: function() { h.shot("5-all") } },
    { act: function() {
        ["Pick tiles tomorrow ^write", "Call plumber ^write #phone", "Order cabinets in 2 weeks ^write !high"].forEach(function(t) { store.quickAdd(t, "", "") })
      },
      until: function() { return store.projects.length > 0 && store.projects[0].total >= 4 } },
    { act: function() {
        var o = store.allTasks.filter(function(t) { return t.title === "Outline" })[0]
        store.toggleComplete(o)
        win.showProject(store.projects[0].key)
      } },
    { act: function() { h.shot("6-project") } },
    { act: function() { win.drawer = "settings" } },
    { act: function() { h.shot("7-settings") } },
    // Calendar mode with the tasks on it.
    { act: function() {
        win.closeDrawer()
        calStore.calendars = [{ id: "cal-home", name: "Home", color: "theme:green", visible: true, source: { type: "local" } }]
        calStore.events = calStore.events.concat([
          { uid: "e1", calendarId: "cal-home", title: "Standup", start: store.todayKey + "T09:00", end: store.todayKey + "T09:15", allDay: false },
          { uid: "e2", calendarId: "cal-home", title: "Lunch with Sam", start: store.todayKey + "T12:00", end: store.todayKey + "T13:00", allDay: false }])
        win.setMode("calendar")
        win.present(store.todayKey, "month")
      } },
    { act: function() { h.shot("8-month-with-tasks") } },
    { act: function() { win.setView("week") } },
    { act: function() { h.shot("9-week-with-tasks") } },
    { act: function() {
        popupTasks.grabToImage(function(r) {
          if (h.dir) r.saveToFile(h.dir + "/10-popup-tasks.png")
          h.saved++
          h.check("render 10-popup-tasks", r.image !== undefined && popupTasks.tasks.length > 0, popupTasks.tasks.length)
        })
      } },
    { act: function() { h.check("saved", h.saved === 10, h.saved) } }
  ]

  property int step: 0
  property bool acted: false
  property real since: 0
  Timer {
    interval: 600; repeat: true; running: store.ready
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
  Timer { interval: 90000; running: true; onTriggered: { h.out("timeout " + h.step); Qt.quit() } }
}
