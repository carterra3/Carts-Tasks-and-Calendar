import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// The plugin's single always-on half. Bar widgets are created per screen (and
// recreated on every hot reload); the data store, the sync helper, the
// calendar window and the IPC route must exist exactly once, so they live
// here. Bar widgets reach it through bar.shell.serviceFor().
Scope {
  id: root

  property string omarchyPath: ""
  property var shell: null
  property var manifest: null

  readonly property alias store: store
  readonly property alias taskStore: taskStore

  // The bar widget that hosts the popout, and its settings (clock format,
  // week start), handed over by the widget itself.
  property var popoutHost: null
  property var barSettings: ({})

  readonly property bool use24h: !/AP|ap/.test(String(barSettings.format || "dddd HH:mm"))
  readonly property int weekStart: {
    var names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
    var v = String(barSettings.weekStartDay || "").toLowerCase()
    for (var i = 0; i < 7; i++) if (names[i] === v || names[i].substr(0, 3) === v) return i
    return Qt.locale().firstDayOfWeek
  }

  // The full calendar is a separate app (CalendarApp.qml, started by
  // bin/carts), so it survives shell restarts and gets its own
  // window class. Asking for "the window" means asking the launcher.
  readonly property string launcherPath: decodeURIComponent(String(Qt.resolvedUrl("bin/carts")).replace(/^file:\/\//, ""))

  function openWindow(key, view) { Quickshell.execDetached([root.launcherPath, key || "", view || ""]) }
  function closeWindow() { Quickshell.execDetached([root.launcherPath, "--quit"]) }
  function toggleWindow() { Quickshell.execDetached([root.launcherPath, "--toggle"]) }
  function newEventWindow() { Quickshell.execDetached([root.launcherPath, "--new"]) }
  function openTasksWindow() { Quickshell.execDetached([root.launcherPath, "--tasks", "today"]) }
  function newTaskWindow() { Quickshell.execDetached([root.launcherPath, "--new-task"]) }
  function openTask(key) { Quickshell.execDetached([root.launcherPath, "--task", key]) }

  function popout(method) {
    if (root.popoutHost && typeof root.popoutHost[method] === "function") root.popoutHost[method]()
  }

  Store {
    id: store
    taskEvents: bridge.items.events
    taskCalendars: bridge.items.calendars
    taskHandler: bridge
  }
  TaskStore { id: taskStore; calendarStore: store }
  // Tasks on the popup's views (Settings → "Tasks in the bar popup" →
  // "Day list + calendar"). The day list itself is PopupTasks in Panel.
  TaskBridge {
    id: bridge
    taskStore: taskStore
    enabled: store.pref("popupTasks", "list") === "calendar"
  }

  IpcHandler {
    target: "carterra3.carts"

    function toggle(): void { root.popout("togglePanel") }
    function open(): void { root.popout("open") }
    function show(): void { root.popout("open") }
    function close(): void { root.popout("close") }
    function hide(): void { root.popout("close") }
    function refresh(): void { root.popout("refresh") }
    function cycleFormat(): void { root.popout("cycleFormat") }
    function newEvent(): void { root.popout("newEvent") }
    function newCalendar(): void { root.popout("newCalendar") }
    function subscribe(): void { root.popout("subscribe") }
    function connectAccount(): void { root.popout("connectAccount") }
    function cycleView(): void { root.popout("cycleView") }
    function cycleSize(): void { root.popout("cycleSize") }
    function sync(): void { store.syncAll(); taskStore.syncAll() }
    function openWindow(): void { root.openWindow() }
    function openTasks(): void { root.openTasksWindow() }
    function newTaskWindow(): void { root.newTaskWindow() }
    function closeWindow(): void { root.closeWindow() }
    function toggleWindow(): void { root.toggleWindow() }
    function newEventWindow(): void { root.newEventWindow() }
  }

  // ---- Launcher entry, so the app opens with SUPER+SPACE like any other. Only a file carrying our marker is ever
  // written; a hand-written entry at that path is left alone.
  readonly property string desktopPath: Quickshell.env("HOME") + "/.local/share/applications/carts.desktop"
  readonly property string desktopEntry: "[Desktop Entry]\n"
    + "Type=Application\n"
    + "Name=Cart's Tasks and Calendar\n"
    + "GenericName=Calendar and Tasks\n"
    + "Comment=Calendar, tasks and contacts for Omarchy\n"
    + "Exec=\"" + root.launcherPath + "\"\n"
    + "Icon=x-office-calendar\n"
    + "Categories=Office;Calendar;\n"
    + "Keywords=calendar;events;agenda;schedule;tasks;todo;reminders;contacts;\n"
    + "StartupWMClass=org.omarchy.carts\n"
    + "NoDisplay=false\n"
    + "X-Carts-Managed=true\n"

  FileView {
    id: desktopFile
    path: root.desktopPath
    printErrors: false
    onLoaded: if (text().indexOf("X-Carts-Managed") !== -1 && text() !== root.desktopEntry) setText(root.desktopEntry)
    onLoadFailed: function(error) {
      if (error === FileViewError.FileNotFound) mkApps.running = true
    }
  }

  Process {
    id: mkApps
    command: ["mkdir", "-p", Quickshell.env("HOME") + "/.local/share/applications"]
    onExited: desktopFile.setText(root.desktopEntry)
  }
}
