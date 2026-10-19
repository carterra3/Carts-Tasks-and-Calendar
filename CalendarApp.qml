//@ pragma OmarchyLoadPatch
// Without the pragma (Omarchy's Quickshell patch) a bare `Color` in any file
// resolves to Qt's own Color type instead of qs.Commons.Color.

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model
import "Tasks.js" as Tasks

// Cart's Tasks and Calendar as a standalone app: its own Quickshell process (app id
// org.omarchy.carts, so Hyprland treats it like any other app), started by
// bin/carts. It shares the data dir, stores, views and sync helpers with the
// bar plugin, so both always show the same calendars and tasks.
//
// Closing the window quits the app; the bar plugin keeps syncing.
ShellRoot {
  id: app

  readonly property string home: Quickshell.env("HOME")
  readonly property string shellJsonPath: home + "/.config/omarchy/shell.json"

  // The bar widget's settings (clock format, week start) from shell.json.
  // Read only: shell.json belongs to the shell.
  property var barSettings: ({})

  readonly property bool use24h: !/AP|ap/.test(String(barSettings.format || "HH:mm"))
  // A week start chosen in either the app or the popup is a shared store
  // pref; the bar setting is the fallback.
  readonly property int weekStart: Model.normalizedWeekStart(
    store.pref("weekStart", barSettings.weekStartDay || null), Qt.locale().firstDayOfWeek)

  function toggleWeekStart() {
    store.setPref("weekStart", Model.weekStartSettingName(Model.toggledWeekStart(app.weekStart)))
  }

  function findBarEntry(data) {
    var layout = data && data.bar && data.bar.layout
    if (!layout) return null
    for (var section in layout) {
      var list = layout[section]
      if (!Array.isArray(list)) continue
      for (var i = 0; i < list.length; i++)
        if (list[i] && list[i].id === "carterra3.carts") return list[i]
    }
    return null
  }

  FileView {
    path: app.shellJsonPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try { app.barSettings = app.findBarEntry(JSON.parse(text())) || {} }
      catch (e) { /* keep the last good settings */ }
    }
  }

  Store {
    id: store
    taskEvents: bridge.items.events
    taskCalendars: bridge.items.calendars
    taskHandler: bridge
  }
  TaskStore { id: taskStore; calendarStore: store }
  // Tasks on the calendar views (Settings → "Show tasks on the calendar").
  TaskBridge {
    id: bridge
    taskStore: taskStore
    enabled: store.pref("tasksOnCalendar", true)
    showCompleted: store.pref("tasksOnCalendarCompleted", false)
  }

  CalendarWindow {
    id: win
    store: store
    taskStore: taskStore
    service: app
    visible: true
    // SUPER+W (or any close) ends the app, like a normal application.
    onVisibleChanged: if (!visible) Qt.quit()
    Component.onCompleted: {
      var key = Quickshell.env("CARTS_KEY") || ""
      var view = Quickshell.env("CARTS_VIEW") || ""
      var mode = Quickshell.env("CARTS_MODE") || ""
      if (mode) win.setMode(mode)
      win.present(key, view)
      var taskView = Quickshell.env("CARTS_TASK_VIEW") || ""
      if (taskView && Tasks.SMART.indexOf(taskView) !== -1) win.showSmart(taskView)
      if (Quickshell.env("CARTS_NEW") === "1") Qt.callLater(function() { win.newEvent() })
      if (Quickshell.env("CARTS_NEW_TASK") === "1") Qt.callLater(function() { win.newTask() })
      var openKey = Quickshell.env("CARTS_TASK") || ""
      if (openKey) app.openTaskWhenReady(openKey)
    }
  }

  // A task asked for at startup can only be found once the stores are read.
  property string _openKey: ""
  function openTaskWhenReady(key) { app._openKey = key; openTimer.restart() }
  Timer {
    id: openTimer
    interval: 200
    repeat: true
    property int tries: 0
    onTriggered: {
      if (taskStore.ready && (taskStore.taskByKey(app._openKey.split("|")[0], app._openKey.split("|").slice(1).join("|")) || ++tries > 25)) {
        stop(); tries = 0
        win.editTaskByKey(app._openKey)
      }
    }
  }

  IpcHandler {
    target: "carts"

    function present(key: string, view: string): void { win.setMode("calendar"); win.present(key, view) }
    function contacts(): void { win.setMode("contacts"); win.present("", "") }
    function tasks(view: string): void { win.setMode("tasks"); if (view && Tasks.SMART.indexOf(view) !== -1) win.showSmart(view); win.present("", "") }
    function newEvent(): void { win.present("", ""); win.newEvent() }
    function newTask(): void { win.setMode("tasks"); win.present("", ""); win.newTask() }
    function openTask(key: string): void { win.present("", ""); win.editTaskByKey(key) }
    // Quick-add syntax: "Pay rent every month on the 1st !high"
    function add(text: string): string { return taskStore.quickAdd(text, "", "") }
    function sync(): void { store.syncAll(); taskStore.syncAll() }
    function quit(): void { Qt.quit() }
  }

  // ---- Theme changes. omarchy-theme-set pushes the new palette to the
  // running shell over IPC; this process does not get that push, so it
  // re-reads the theme files itself whenever theme.name is rewritten.
  Timer {
    id: themeReload
    interval: 150
    onTriggered: {
      Color.colorsFile.reload()
      Color.shellFile.reload()
    }
  }

  FileView {
    path: Color.stateHome + "/omarchy/current/theme.name"
    watchChanges: true
    printErrors: false
    onFileChanged: { reload(); themeReload.restart() }
  }
}
