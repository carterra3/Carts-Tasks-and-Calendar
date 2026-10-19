import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Events.js" as Events
import "Recur.js" as Recur
import "Contacts.js" as Contacts
import "Tasks.js" as Tasks

// The app's window (see CalendarApp.qml): toolbar, sidebar, the main area
// filling the tile, and a drawer on the right for editors and settings. Three
// modes share it:
//   calendar  sidebar: mini month, calendars, world clocks; main: MainView
//   tasks     sidebar: smart lists, projects, lists; main: TaskList
//   contacts  sidebar: address books; main: ContactsView
// The task editor can open from any mode (a task clicked on the calendar).
// `service` is the app root: use24h, weekStart, toggleWeekStart().
FloatingWindow {
  id: win

  property var store: null
  property var taskStore: null
  property var service: null

  readonly property bool use24h: service ? service.use24h : true
  readonly property int weekStart: service ? service.weekStart : 1

  property string view: store ? store.pref("windowView", "month") : "month"
  property string cursorKey: Events.keyOf(new Date())
  property string todayKey: Events.keyOf(new Date())
  // "" | "event" | "calendar" | "hidden" | "contact" | "book" | "task" | "list" | "settings"
  property string drawer: ""
  // "calendar", "tasks" or "contacts": which part of the app fills the window.
  property string mode: store ? store.pref("windowMode", "calendar") : "calendar"
  property string contactsBook: ""     // address book filter, "" = all
  property string contactKey: ""       // selected contact
  readonly property bool contactsMode: mode === "contacts"
  readonly property bool tasksMode: mode === "tasks"
  readonly property bool calendarMode: !contactsMode && !tasksMode

  // ---- Tasks mode (prefs in tasks.json)
  property string taskView: taskStore ? taskStore.pref("view", "today") : "today"
  property string taskListId: taskStore ? taskStore.pref("listId", "") : ""
  property string projectKey: taskStore ? taskStore.pref("projectKey", "") : ""
  property string selectedTaskKey: ""
  readonly property string taskSort: taskStore ? taskStore.pref("sort", "due") : "due"
  readonly property bool showCompleted: taskStore ? taskStore.pref("showCompleted", false) : false
  readonly property var currentList: taskStore && taskView === "list" ? taskStore.listById(taskListId) : null
  readonly property var currentProject: taskStore && taskView === "project" ? taskStore.taskByKey(projectKey.split("|")[0], projectKey.split("|")[1]) : null

  readonly property color fg: Color.foreground
  readonly property string fontFamily: Style.font.family

  title: "Cart's Tasks and Calendar"
  color: Color.background
  implicitWidth: 1180
  implicitHeight: 780
  minimumSize: Qt.size(720, 480)

  // Called by the service: show (or re-show) the window, optionally on a
  // given day/view, and ask Hyprland to focus it if it was already open.
  function present(key, v) {
    if (key) win.cursorKey = key
    if (v) setView(v)
    var wasVisible = win.visible
    win.visible = true
    // Hyprland's Lua dispatcher syntax (Omarchy 4 config).
    if (wasVisible) Quickshell.execDetached(["hyprctl", "dispatch", "hl.dsp.focus({ window = \"class:^org\\\\.omarchy\\\\.carts$\" })"])
    Qt.callLater(function() { if (win.drawer === "") focusRoot.takeFocus() })
  }

  function setView(v) {
    win.view = v
    if (store) store.setPref("windowView", v)
  }

  function setMode(m) {
    if (m !== "contacts" && m !== "tasks") m = "calendar"
    if (m === win.mode) return
    // Settings and the task editor make sense in every mode; the rest
    // belong to the mode they were opened in.
    if (win.drawer !== "" && win.drawer !== "settings" && !(win.drawer === "task" && m === "tasks")) win.drawer = ""
    win.mode = m
    if (store) store.setPref("windowMode", m)
    if (m === "contacts" && store) store.syncContacts()
    if (m === "tasks" && taskStore) taskStore.syncIfStale()
    Qt.callLater(function() { focusRoot.takeFocus() })
  }
  function cycleMode(delta) {
    var order = ["calendar", "tasks", "contacts"]
    setMode(order[(order.indexOf(win.mode) + delta + order.length) % order.length])
  }

  // ---- Tasks
  function showSmart(name) {
    win.taskView = name
    if (taskStore) taskStore.setPref("view", name)
  }
  function showList(id) {
    win.taskView = "list"
    win.taskListId = id
    if (taskStore) { taskStore.setPref("view", "list"); taskStore.setPref("listId", id) }
  }
  function showProject(key) {
    win.taskView = "project"
    win.projectKey = key
    if (taskStore) { taskStore.setPref("view", "project"); taskStore.setPref("projectKey", key) }
  }
  // Every entry of the tasks sidebar in order, for [ and ].
  function taskStep(delta) {
    var entries = Tasks.SMART.map(function(s) { return { smart: s } })
      .concat(taskStore ? taskStore.projects.map(function(p) { return { project: p.key } }) : [])
      .concat(taskStore ? taskStore.lists.map(function(l) { return { list: l.id } }) : [])
    var i = 0
    for (; i < entries.length; i++)
      if ((entries[i].smart && entries[i].smart === win.taskView) || (entries[i].list && win.taskView === "list" && entries[i].list === win.taskListId)
          || (entries[i].project && win.taskView === "project" && entries[i].project === win.projectKey)) break
    var e = entries[(i + delta + entries.length) % entries.length]
    if (e.smart) showSmart(e.smart)
    else if (e.project) showProject(e.project)
    else showList(e.list)
  }
  function newTask(due) {
    if (!taskStore) return
    win.drawer = "task"
    var inProject = win.tasksMode ? win.currentProject : null
    var listId = inProject ? inProject.listId : win.tasksMode && win.taskView === "list" ? win.taskListId : ""
    if (!due && win.tasksMode && win.taskView === "today") due = taskStore.todayKey
    if (!taskEditor.openNew(listId, inProject ? inProject.uid : "", due || "")) openListEditor(null)
  }
  function newProject() {
    if (!taskStore) return
    win.drawer = "task"
    if (!taskEditor.openNew(win.taskView === "list" ? win.taskListId : "", "", "", true)) openListEditor(null)
  }
  function editTask(t) {
    if (!t) return
    win.selectedTaskKey = t.listId + "|" + t.uid
    win.drawer = "task"
    taskEditor.openEdit(t)
  }
  // "listId|uid", e.g. a task clicked on the calendar or opened over IPC.
  function editTaskByKey(key) {
    if (!taskStore || !key) return false
    var i = String(key).indexOf("|")
    var t = i > 0 ? taskStore.taskByKey(key.substr(0, i), key.substr(i + 1)) : null
    if (!t) { win.flash("That task is gone"); return false }
    editTask(t)
    return true
  }
  function openListEditor(l) {
    win.drawer = "list"
    if (l) listEditor.openEdit(l)
    else listEditor.openNew()
  }
  function toggleSettings() {
    if (win.drawer === "settings") win.closeDrawer()
    else win.drawer = "settings"
  }
  // Keep a list or project view pointing at something that still exists.
  Connections {
    target: win.taskStore
    function onListsChanged() { if (win.taskView === "list" && win.taskStore.ready && !win.taskStore.listById(win.taskListId)) win.showSmart("today") }
    function onAllTasksChanged() { if (win.taskView === "project" && win.taskStore.ready && !win.currentProject && !win.taskStore.busy) goneTimer.restart() }
  }
  // (a moment's grace: a project moving lists is briefly in neither)
  Timer { id: goneTimer; interval: 1500; onTriggered: if (win.taskView === "project" && !win.currentProject) win.showSmart("today") }

  function newContact() {
    if (!store) return
    setMode("contacts")
    if (!store.writableBooks.length) { openBookEditor(null); return }
    win.drawer = "contact"
    contactEditor.openNew(win.contactsBook)
  }

  function editContact(c) {
    if (!c || !store || !store.bookWritable(c.bookId)) return
    win.contactKey = Contacts.keyOf(c)
    win.drawer = "contact"
    contactEditor.openEdit(c)
  }

  function openBookEditor(book) {
    win.drawer = "book"
    if (book) bookEditor.openEdit(book)
    else bookEditor.openNew()
  }

  function flash(text) { win.notice = text; win.noticeError = false; noticeTimer.restart() }

  function step(delta) { win.cursorKey = Events.stepKey(win.view, win.cursorKey, delta) }
  function goToday() { win.todayKey = Events.keyOf(new Date()); win.cursorKey = win.todayKey }

  function pick(key) {
    win.cursorKey = key
    if (win.drawer === "event") eventEditor.setDay(key)
  }

  // A click that means "here": add an event, or move the one being edited.
  function activate(key, minutes) {
    if (win.drawer === "event" && !eventEditor.readOnly) {
      win.cursorKey = key
      eventEditor.setSlot(key, minutes)
    } else newEvent(key, minutes)
  }

  function newEvent(key, minutes) {
    if (!store) return
    if (key) win.cursorKey = key
    win.drawer = "event"
    if (!eventEditor.openNew(win.cursorKey, minutes)) openCalendarEditor(null, "local")
  }

  // Drags from the views.
  property string notice: ""
  property bool noticeError: true
  function moveEvent(ev, changed) {
    if (!store) return
    if (ev.recurring) {
      if (Events.keyOf(Events.parseStamp(changed.start)) !== Events.keyOf(Events.parseStamp(ev.start)))
        changed.rrule = Recur.retarget(ev.rrule || "", ev.start.substr(0, 10), changed.start.substr(0, 10))
      win.drawer = "event"
      eventEditor.openMoved(ev, changed)
      return
    }
    store.moveEvent(ev, changed, function(err) {
      if (err) { win.notice = err; win.noticeError = true; noticeTimer.restart() }
    })
  }

  function newRange(key, startMin, endMin) {
    if (!store) return
    win.cursorKey = key
    win.drawer = "event"
    if (!eventEditor.openNew(key, startMin, endMin)) openCalendarEditor(null, "local")
  }

  Timer { id: noticeTimer; interval: win.noticeError ? 6000 : 2500; onTriggered: win.notice = "" }

  function editEvent(ev) {
    if (ev && ev.taskRef) { editTaskByKey(ev.taskRef); return }
    win.drawer = "event"
    eventEditor.openEdit(ev)
  }

  function openCalendarEditor(cal, kind) {
    win.drawer = "calendar"
    if (cal) calendarEditor.openEdit(cal)
    else calendarEditor.openNew(kind || "local")
  }

  function closeDrawer() {
    win.drawer = ""
    Qt.callLater(function() { focusRoot.takeFocus() })
  }

  Timer {
    interval: 60000
    running: win.visible
    repeat: true
    onTriggered: {
      var k = Events.keyOf(new Date())
      if (k !== win.todayKey) {
        var follow = win.cursorKey === win.todayKey
        win.todayKey = k
        if (follow) win.cursorKey = k
      }
    }
  }

  onVisibleChanged: if (visible) {
    if (store) store.syncIfStale()
    if (taskStore) taskStore.syncIfStale()
  }

  FocusScope {
    id: focusRoot
    anchors.fill: parent
    focus: true

    // Take keyboard focus back from whatever has it inside the window (an
    // editor field, the search box). forceActiveFocus() alone is a no-op
    // here: the scope already counts as focused through that child, and a
    // field keeps focus even after its drawer is hidden, so every shortcut
    // would keep going to it.
    function takeFocus() {
      for (var i = 0; i < 10; i++) {
        var f = Window.activeFocusItem
        if (!f || f === focusRoot) break
        f.focus = false
      }
      focusRoot.forceActiveFocus()
    }

    // Shortcuts apply only while no editor is open, so typing in a form
    // never moves the calendar underneath it.
    Keys.onPressed: function(event) {
      var t = event.text
      var k = event.key
      var ctrl = event.modifiers & Qt.ControlModifier
      // Modes: Ctrl+1/2/3, or Ctrl+Tab / Ctrl+Shift+Tab to cycle; Ctrl+,
      // settings. Also with the settings drawer open, never over an editor
      // (switching would drop its unsaved form).
      if (ctrl && (win.drawer === "" || win.drawer === "settings")) {
        if (k >= Qt.Key_1 && k <= Qt.Key_3) { win.setMode(["calendar", "tasks", "contacts"][k - Qt.Key_1]); event.accepted = true; return }
        if (k === Qt.Key_Tab || k === Qt.Key_Backtab) { win.cycleMode(k === Qt.Key_Backtab || (event.modifiers & Qt.ShiftModifier) ? -1 : 1); event.accepted = true; return }
        if (k === Qt.Key_Comma) { win.toggleSettings(); event.accepted = true; return }
      }
      if (win.drawer !== "") {
        if (event.key === Qt.Key_Escape) { win.closeDrawer(); event.accepted = true }
        return
      }
      if (win.tasksMode) { taskKeys(event); return }
      if (t === "c" || t === "C") { win.setMode(win.contactsMode ? "calendar" : "contacts"); event.accepted = true; return }
      if (win.contactsMode) {
        if (k === Qt.Key_Down || t === "j") contactsView.move(1)
        else if (k === Qt.Key_Up || t === "k") contactsView.move(-1)
        else if (k === Qt.Key_PageDown) contactsView.move(10)
        else if (k === Qt.Key_PageUp) contactsView.move(-10)
        else if (t === "/" || (k === Qt.Key_F && (event.modifiers & Qt.ControlModifier))) { searchField.forceActiveFocus(); searchField.selectAll() }
        else if (t === "n" || t === "N") win.newContact()
        else if (t === "e" || k === Qt.Key_Return || k === Qt.Key_Enter) win.editContact(contactsView.current)
        else if (t === "r" && win.store) win.store.syncContacts()
        else if (k === Qt.Key_Escape && searchField.text !== "") searchField.text = ""
        else return
        event.accepted = true
        return
      }
      if (k === Qt.Key_Left || t === "h") win.cursorKey = Events.addDaysKey(win.cursorKey, -1)
      else if (k === Qt.Key_Right || t === "l") win.cursorKey = Events.addDaysKey(win.cursorKey, 1)
      else if (k === Qt.Key_Up || t === "k") win.cursorKey = Events.addDaysKey(win.cursorKey, -7)
      else if (k === Qt.Key_Down || t === "j") win.cursorKey = Events.addDaysKey(win.cursorKey, 7)
      else if (t === "[" || k === Qt.Key_PageUp) win.step(-1)
      else if (t === "]" || k === Qt.Key_PageDown) win.step(1)
      else if (t === "t" || t === "T") win.goToday()
      else if (t === "n" || t === "N" || k === Qt.Key_Return || k === Qt.Key_Enter) win.newEvent()
      else if (t === "m") win.setView("month")
      else if (t === "w") win.setView("week")
      else if (t === "d") win.setView("day")
      else if (t === "a") win.setView("agenda")
      else if (t === "y") win.setView("year")
      else if (t === "r" && win.store) { win.store.syncAll(); if (win.taskStore && win.store.pref("tasksOnCalendar", true)) win.taskStore.syncAll() }
      else return
      event.accepted = true
    }

    // Tasks mode keys (as in the old standalone Tasks app).
    function taskKeys(event) {
      var t = event.text, k = event.key
      var ts = win.taskStore
      if (!ts) return
      // Answering "complete the open subtasks too?"
      if (ts.confirmComplete) {
        var ask = ts.confirmComplete
        if (k === Qt.Key_Return || k === Qt.Key_Enter || t === "a") ts.toggleComplete(ask.task, null, { subtasks: "all" })
        else if (t === "o") ts.toggleComplete(ask.task, null, { subtasks: "none" })
        else if (k === Qt.Key_Escape) ts.confirmComplete = null
        event.accepted = true
        return
      }
      var cur = taskList.current
      var ctrl = event.modifiers & Qt.ControlModifier
      if (ctrl && k === Qt.Key_Z) ts.undo()
      else if (k === Qt.Key_Down || t === "j") taskList.move(1)
      else if (k === Qt.Key_Up || t === "k") taskList.move(-1)
      else if (k === Qt.Key_PageDown) taskList.move(10)
      else if (k === Qt.Key_PageUp) taskList.move(-10)
      else if (k === Qt.Key_N && (event.modifiers & Qt.ShiftModifier)) win.newTask()
      else if (t === "n") taskList.focusQuickAdd()
      else if (t === "/" || (ctrl && k === Qt.Key_F)) { taskSearch.forceActiveFocus(); taskSearch.selectAll() }
      else if (t === "e" || k === Qt.Key_Return || k === Qt.Key_Enter) win.editTask(cur)
      else if (k === Qt.Key_Backtab || (k === Qt.Key_Tab && (event.modifiers & Qt.ShiftModifier))) taskList.outdent()
      else if (k === Qt.Key_Tab) taskList.indent()
      else if (k === Qt.Key_Left || t === "h") taskList.unfold(false)
      else if (k === Qt.Key_Right || t === "l") taskList.unfold(true)
      else if (k === Qt.Key_P && (event.modifiers & Qt.ShiftModifier)) win.newProject()
      else if (t === "g" && cur && ts.projects.some(function(p) { return p.key === cur.listId + "|" + cur.uid })) win.showProject(cur.listId + "|" + cur.uid)
      else if ((t === " " || t === "x") && cur) ts.toggleComplete(cur)
      else if (t === "s" && cur && Tasks.isRepeating(cur)) ts.skipOccurrence(cur)
      else if (t === "t" && cur) ts.setDue(cur, ts.todayKey + String(cur.due || "").substr(10))
      else if (t === "." && cur) ts.postpone(cur, 1)
      else if (t === "p" && cur) ts.cyclePriority(cur)
      else if (k === Qt.Key_Delete && cur) ts.deleteTask(cur)
      else if (t === "c") ts.setPref("showCompleted", !win.showCompleted)
      else if (t === "r") ts.syncAll()
      else if (t === "[") win.taskStep(-1)
      else if (t === "]") win.taskStep(1)
      else if (t >= "1" && t <= "5") win.showSmart(Tasks.SMART[+t - 1])
      else if (k === Qt.Key_Escape && taskSearch.text !== "") taskSearch.text = ""
      else return
      event.accepted = true
    }

    // ---------------------------------------------------------------- toolbar
    Item {
      id: toolbar
      x: Style.space(16)
      y: Style.space(10)
      width: parent.width - Style.space(32)
      height: Style.space(40)
      // Narrow tiles: one-letter view buttons and an icon-only New button.
      readonly property bool compact: width < Style.space(1000)

      Row {
        id: navRow
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(8)

        ButtonGroup {
          anchors.verticalCenter: parent.verticalCenter
          options: [
            { value: "calendar", label: "", icon: "󰃭", tooltip: "Calendar  (Ctrl+1)" },
            { value: "tasks", label: "", icon: "󰄲", tooltip: "Tasks  (Ctrl+2)" },
            { value: "contacts", label: "", icon: "󰀉", tooltip: "Contacts  (Ctrl+3)" }
          ]
          value: win.mode
          focusable: false
          foreground: win.fg
          fontFamily: win.fontFamily
          onChanged: function(v) { win.setMode(v) }
        }

        Button {
          anchors.verticalCenter: parent.verticalCenter
          visible: win.calendarMode
          text: "Today"
          bordered: true
          foreground: win.fg
          fontFamily: win.fontFamily
          onClicked: win.goToday()
        }
        PanelActionButton {
          anchors.verticalCenter: parent.verticalCenter
          visible: win.calendarMode
          iconText: "󰅁"
          tooltipText: "Previous  ["
          foreground: win.fg
          fontFamily: win.fontFamily
          onClicked: win.step(-1)
        }
        PanelActionButton {
          anchors.verticalCenter: parent.verticalCenter
          visible: win.calendarMode
          iconText: "󰅂"
          tooltipText: "Next  ]"
          foreground: win.fg
          fontFamily: win.fontFamily
          onClicked: win.step(1)
        }
      }

      Swatch {
        id: listSwatch
        visible: win.tasksMode && win.currentList !== null
        anchors.left: navRow.right
        anchors.leftMargin: Style.space(14)
        anchors.verticalCenter: parent.verticalCenter
        width: visible ? Style.space(14) : 0
        swatch: win.currentList && win.taskStore ? win.taskStore.colorFor(win.currentList.color) : Color.accent
      }
      Text {
        anchors.left: listSwatch.visible ? listSwatch.right : navRow.right
        anchors.leftMargin: listSwatch.visible ? Style.space(8) : Style.space(14)
        anchors.verticalCenter: parent.verticalCenter
        width: Math.max(0, actionRow.x - x - Style.space(12))
        elide: Text.ElideRight
        textFormat: Text.PlainText
        text: win.contactsMode ? (win.contactsBook && win.store && win.store.bookById(win.contactsBook) ? win.store.bookById(win.contactsBook).name : "Contacts")
          : win.tasksMode ? (win.currentList ? win.currentList.name : win.currentProject ? "󰉋 " + win.currentProject.title : Tasks.SMART_LABELS[win.taskView] || "Tasks")
          : Events.periodTitle(win.view, win.cursorKey, win.weekStart)
        color: win.fg
        font.family: win.fontFamily
        font.pixelSize: toolbar.compact ? Style.font.title : Style.font.display
        font.bold: true
      }

      Row {
        id: actionRow
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(10)

        TextField {
          id: searchField
          anchors.verticalCenter: parent.verticalCenter
          visible: win.contactsMode && win.store && win.store.addressBooks.length > 0
          width: toolbar.compact ? Style.space(180) : Style.space(280)
          placeholderText: "Search contacts  (/)"
          foreground: win.fg
          font.family: win.fontFamily
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) { text = ""; focusRoot.takeFocus(); event.accepted = true }
            else if (event.key === Qt.Key_Down || event.key === Qt.Key_Up) { contactsView.move(event.key === Qt.Key_Down ? 1 : -1); event.accepted = true }
            else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { focusRoot.takeFocus(); event.accepted = true }
          }
        }

        TextField {
          id: taskSearch
          anchors.verticalCenter: parent.verticalCenter
          visible: win.tasksMode
          width: toolbar.compact ? Style.space(150) : Style.space(240)
          placeholderText: "Search  (/)  #tag"
          foreground: win.fg
          font.family: win.fontFamily
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) { text = ""; focusRoot.takeFocus(); event.accepted = true }
            else if (event.key === Qt.Key_Down || event.key === Qt.Key_Up) { taskList.move(event.key === Qt.Key_Down ? 1 : -1); event.accepted = true }
            else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { focusRoot.takeFocus(); event.accepted = true }
          }
        }
        Dropdown {
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(toolbar.compact ? 120 : 150)
          showLabel: false
          visible: win.tasksMode && win.taskView !== "completed"
          value: win.taskSort
          options: [{ value: "due", label: "By due date" }, { value: "priority", label: "By priority" },
                    { value: "title", label: "By title" }, { value: "created", label: "Newest first" }, { value: "manual", label: "Server order" }]
          foreground: win.fg
          fontFamily: win.fontFamily
          onChanged: function(v) { win.taskStore.setPref("sort", v) }
        }
        PanelActionButton {
          anchors.verticalCenter: parent.verticalCenter
          visible: win.tasksMode && win.taskView !== "completed"
          iconText: win.showCompleted ? "󰄲" : "󰄱"
          tooltipText: (win.showCompleted ? "Hide" : "Show") + " completed  (c)"
          foreground: win.showCompleted ? Color.accent : win.fg
          fontFamily: win.fontFamily
          onClicked: win.taskStore.setPref("showCompleted", !win.showCompleted)
        }

        ButtonGroup {
          anchors.verticalCenter: parent.verticalCenter
          visible: win.calendarMode
          options: [
            { value: "year", label: toolbar.compact ? "Y" : "Year", tooltip: "y" },
            { value: "month", label: toolbar.compact ? "M" : "Month", tooltip: "m" },
            { value: "week", label: toolbar.compact ? "W" : "Week", tooltip: "w" },
            { value: "day", label: toolbar.compact ? "D" : "Day", tooltip: "d" },
            { value: "agenda", label: toolbar.compact ? "A" : "Agenda", tooltip: "a" }
          ]
          value: win.view
          focusable: false
          foreground: win.fg
          fontFamily: win.fontFamily
          onChanged: function(v) { win.setView(v) }
        }
        PanelActionButton {
          anchors.verticalCenter: parent.verticalCenter
          readonly property bool busy: win.tasksMode ? !!win.taskStore && win.taskStore.syncing
            : win.store && (win.contactsMode ? win.store.contactsSyncing : win.store.syncing)
          visible: win.tasksMode ? !!win.taskStore && win.taskStore.hasRemote
            : win.store && (win.contactsMode ? win.store.addressBooks.length > 0 : win.store.hasRemote)
          iconText: "󰑐"
          tooltipText: busy ? "Syncing…" : "Sync now  (r)"
          foreground: busy ? Qt.darker(win.fg, 1.9) : win.fg
          fontFamily: win.fontFamily
          enabled: !busy
          onClicked: win.tasksMode ? win.taskStore.syncAll() : win.contactsMode ? win.store.syncContacts() : win.store.syncAll()
        }
        PanelActionButton {
          anchors.verticalCenter: parent.verticalCenter
          iconText: "\uf013"
          tooltipText: "Settings  (Ctrl+,)"
          foreground: win.drawer === "settings" ? Color.accent : win.fg
          fontFamily: win.fontFamily
          onClicked: win.toggleSettings()
        }
        Button {
          anchors.verticalCenter: parent.verticalCenter
          readonly property string label: win.contactsMode ? "New contact" : win.tasksMode ? "New task" : "New event"
          text: toolbar.compact ? "" : label
          tooltipText: toolbar.compact ? label + (win.tasksMode ? "  (N)" : "  (n)") : ""
          iconText: "󰐕"
          bordered: true
          selected: true
          foreground: win.fg
          fontFamily: win.fontFamily
          onClicked: win.contactsMode ? win.newContact() : win.tasksMode ? win.newTask() : win.newEvent()
        }
      }
    }

    // Errors from drags (e.g. the server refused the change).
    Rectangle {
      z: 11
      visible: win.notice !== ""
      width: Math.min(Style.space(460), mainView.width)
      height: noticeText.implicitHeight + Style.space(16)
      x: mainView.x + (mainView.width - width) / 2
      y: parent.height - height - Style.space(70)
      radius: Style.cornerRadius
      color: Qt.tint(Color.background, Util.alpha(win.noticeError ? Color.urgent : Color.accent, 0.3))
      Text {
        id: noticeText
        anchors.centerIn: parent
        width: parent.width - Style.space(20)
        wrapMode: Text.Wrap
        textFormat: Text.PlainText
        text: (win.noticeError ? "⚠ " : "") + win.notice
        color: win.fg
        font.family: win.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
      MouseArea { anchors.fill: parent; onClicked: win.notice = "" }
    }

    // Undo for the last hide, floating over the bottom of the main view.
    UndoBar {
      id: hideUndo
      z: 10
      width: Math.min(Style.space(420), mainView.width)
      x: mainView.x + (mainView.width - width) / 2
      y: parent.height - height - Style.space(20)
      store: win.store
      fg: win.fg
      fontFamily: win.fontFamily
      color: Qt.tint(Color.background, Util.alpha(Color.accent, 0.25))
    }

    // ---------------------------------------- "complete the subtasks too?"
    Rectangle {
      id: askBar
      z: 11
      readonly property var ask: win.taskStore ? win.taskStore.confirmComplete : null
      visible: ask !== null
      width: Math.min(Style.space(560), mainView.width)
      height: askCol.implicitHeight + Style.space(16)
      x: mainView.x + (mainView.width - width) / 2
      y: parent.height - height - Style.space(20)
      radius: Style.cornerRadius
      color: Qt.tint(Color.background, Util.alpha(Color.accent, 0.3))
      Column {
        id: askCol
        x: Style.space(12)
        y: Style.space(8)
        width: parent.width - Style.space(24)
        spacing: Style.space(6)
        Text {
          width: parent.width
          wrapMode: Text.Wrap
          textFormat: Text.PlainText
          text: askBar.ask ? "\u201c" + askBar.ask.task.title + "\u201d has " + askBar.ask.open.length + " open subtask" + (askBar.ask.open.length > 1 ? "s" : "") + ". Complete them too?" : ""
          color: win.fg
          font.family: win.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
        Row {
          spacing: Style.space(8)
          Button {
            text: "Complete all  (a)"
            bordered: true
            selected: true
            fontSize: Style.font.bodySmall
            foreground: win.fg
            fontFamily: win.fontFamily
            onClicked: win.taskStore.toggleComplete(askBar.ask.task, null, { subtasks: "all" })
          }
          Button {
            text: "Only this one  (o)"
            bordered: true
            fontSize: Style.font.bodySmall
            foreground: win.fg
            fontFamily: win.fontFamily
            onClicked: win.taskStore.toggleComplete(askBar.ask.task, null, { subtasks: "none" })
          }
          Button {
            text: "Cancel"
            bordered: true
            fontSize: Style.font.bodySmall
            foreground: win.fg
            fontFamily: win.fontFamily
            onClicked: win.taskStore.confirmComplete = null
          }
        }
      }
    }

    // ------------------------------------------ task notices + undo
    // (completing, skipping, deleting; from any mode)
    Rectangle {
      id: taskUndoBar
      z: 10
      readonly property bool shown: !!win.taskStore && win.taskStore.notice !== "" && !askBar.visible
      visible: shown
      width: Math.min(Style.space(480), mainView.width)
      height: Math.max(taskNoticeText.implicitHeight, taskUndoBtn.implicitHeight) + Style.space(12)
      x: mainView.x + (mainView.width - width) / 2
      y: parent.height - height - Style.space(20) - (hideUndo.visible ? hideUndo.height + Style.space(8) : 0)
      radius: Style.cornerRadius
      color: Qt.tint(Color.background, Util.alpha(win.taskStore && win.taskStore.noticeError ? Color.urgent : Color.accent, 0.28))
      Text {
        id: taskNoticeText
        x: Style.space(12)
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - (taskUndoBtn.visible ? taskUndoBtn.width : 0) - Style.space(28)
        wrapMode: Text.Wrap
        textFormat: Text.PlainText
        text: win.taskStore ? (win.taskStore.noticeError ? "⚠ " : "") + win.taskStore.notice : ""
        color: win.fg
        font.family: win.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
      Button {
        id: taskUndoBtn
        visible: !!win.taskStore && win.taskStore.lastAction !== null && !win.taskStore.noticeError
        anchors.right: parent.right
        anchors.rightMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        text: "Undo"
        foreground: win.fg
        fontFamily: win.fontFamily
        fontSize: Style.font.bodySmall
        onClicked: win.taskStore.undo()
      }
      MouseArea { anchors.fill: taskNoticeText; onClicked: win.taskStore.notice = "" }
    }

    // ---------------------------------------------------------------- sidebar
    // A half-width tile cannot hold sidebar + view + editor; the sidebar
    // steps aside while an editor is open there.
    readonly property bool sidebarShown: !(win.drawer !== "" && win.width < Style.space(1300))

    Flickable {
      id: sidebar
      visible: focusRoot.sidebarShown
      x: Style.space(16)
      y: toolbar.y + toolbar.height + Style.space(12)
      width: visible ? Style.space(250) : 0
      height: parent.height - y - Style.space(12)
      contentWidth: width
      contentHeight: sideColumn.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds

      Column {
        id: sideColumn
        width: sidebar.width
        spacing: Style.space(14)

        AddressBookList {
          visible: win.contactsMode
          width: sideColumn.width
          store: win.store
          selectedBook: win.contactsBook
          fg: win.fg
          fontFamily: win.fontFamily
          onSelected: function(id) { win.contactsBook = id }
          onAddRequested: win.openBookEditor(null)
          onEditRequested: function(book) { win.openBookEditor(book) }
        }

        Sidebar {
          visible: win.tasksMode
          width: sideColumn.width
          store: win.taskStore
          view: win.taskView
          listId: win.taskListId
          projectKey: win.projectKey
          fg: win.fg
          fontFamily: win.fontFamily
          onProjectPicked: function(key) { win.showProject(key) }
          onNewProjectRequested: win.newProject()
          onSmartPicked: function(name) { win.showSmart(name) }
          onListPicked: function(id) { win.showList(id) }
          onAddRequested: win.openListEditor(null)
          onEditRequested: function(l) { win.openListEditor(l) }
        }

        Text {
          visible: win.tasksMode && !!win.taskStore && win.taskStore.problem !== ""
          width: sideColumn.width
          wrapMode: Text.Wrap
          textFormat: Text.PlainText
          text: win.taskStore ? "⚠ " + win.taskStore.problem : ""
          color: Color.urgent
          font.family: win.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          visible: win.calendarMode
          textFormat: Text.PlainText
          text: Qt.formatDate(Events.parseStamp(win.cursorKey) || new Date(), "MMMM yyyy").toUpperCase()
          color: Qt.darker(win.fg, 1.4)
          font.family: win.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.letterSpacing: 1
          font.bold: true
        }

        MonthGrid {
          visible: win.calendarMode
          store: win.store
          year: (Events.parseStamp(win.cursorKey) || new Date()).getFullYear()
          month: (Events.parseStamp(win.cursorKey) || new Date()).getMonth()
          weekStart: win.weekStart
          selectedKey: win.cursorKey
          todayKey: win.todayKey
          showWeekNumbers: false
          cellWidth: (sideColumn.width - 6 * cellSpacing) / 7
          cellHeight: Style.space(28)
          dayFontSize: Style.font.bodySmall
          fg: win.fg
          fontFamily: win.fontFamily
          onPicked: function(key) { win.pick(key) }
          onActivated: function(key) { win.activate(key, -1) }
          onStepRequested: function(d) { win.cursorKey = Events.addMonthsKey(win.cursorKey, d) }
        }

        CalendarList {
          visible: win.calendarMode
          width: sideColumn.width
          store: win.store
          fg: win.fg
          fontFamily: win.fontFamily
          onAddRequested: win.openCalendarEditor(null, "local")
          onEditRequested: function(cal) { win.openCalendarEditor(cal) }
          onHiddenRequested: { win.drawer = "hidden"; Qt.callLater(function() { hiddenList.forceActiveFocus() }) }
        }

        WorldClocks {
          visible: win.calendarMode
          width: sideColumn.width
          store: win.store
          use24h: win.use24h
          fg: win.fg
          fontFamily: win.fontFamily
        }

        Text {
          width: sideColumn.width
          wrapMode: Text.Wrap
          textFormat: Text.PlainText
          text: (win.contactsMode
            ? "Keys: ↑↓ / j k move · / search · n new · e edit · r sync · c calendar"
            : win.tasksMode
            ? "Keys: j k move · space complete · s skip repeat · e edit · n quick add · N new · P new project · Tab / Shift+Tab subtask / up a level · ← → fold · g open project · t due today · . postpone a day · p priority · Del delete · Ctrl+Z undo · / search · c completed · 1–5 [ ] views · r sync"
            : "Keys: ←→↑↓ move · [ ] previous/next · t today · n new · y m w d a views · r sync · c contacts")
            + " · Ctrl+1 2 3 calendar / tasks / contacts · Ctrl+, settings"
          color: Qt.darker(win.fg, 1.9)
          font.family: win.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }

    Rectangle {
      visible: sidebar.visible
      x: sidebar.x + sidebar.width + Style.space(12)
      y: sidebar.y
      width: Style.spacing.hairline
      height: sidebar.height
      color: win.fg
      opacity: 0.1
    }

    // -------------------------------------------------------------- main view
    MainView {
      id: mainView
      x: sidebar.visible ? sidebar.x + sidebar.width + Style.space(24) : Style.space(16)
      y: sidebar.y
      width: (drawerPane.visible ? drawerPane.x - Style.space(16) : parent.width - Style.space(16)) - x
      height: sidebar.height
      visible: win.calendarMode
      fill: true
      active: win.visible && win.calendarMode
      store: win.store
      view: win.view
      cursorKey: win.cursorKey
      todayKey: win.todayKey
      weekStart: win.weekStart
      use24h: win.use24h
      hourHeight: Style.space(48)
      agendaDays: 90
      fg: win.fg
      fontFamily: win.fontFamily
      onPicked: function(key) { win.pick(key) }
      onActivated: function(key, minutes) { win.activate(key, minutes) }
      onEventPicked: function(ev) { win.editEvent(ev) }
      onStepRequested: function(d) { win.step(d) }
      onOpenRequested: function(key, v) { win.cursorKey = key; win.setView(v) }
      onEventMoved: function(ev, changed) { win.moveEvent(ev, changed) }
      onRangeSelected: function(key, a, b) { win.newRange(key, a, b) }
      onWeekStartToggleRequested: if (win.service) win.service.toggleWeekStart()
    }

    TaskList {
      id: taskList
      visible: win.tasksMode
      active: win.visible && win.tasksMode
      x: mainView.x
      y: mainView.y
      width: mainView.width
      height: mainView.height
      store: win.taskStore
      view: win.taskView
      listId: win.taskListId
      projectKey: win.projectKey
      query: taskSearch.text
      sort: win.taskSort
      showCompleted: win.showCompleted
      selectedKey: win.selectedTaskKey
      use24h: win.use24h
      fg: win.fg
      fontFamily: win.fontFamily
      onSelectRequested: function(key) { win.selectedTaskKey = key }
      onEditRequested: function(t) { win.editTask(t) }
      onAddListRequested: win.openListEditor(null)
      onLeaveRequested: focusRoot.takeFocus()
    }

    ContactsView {
      id: contactsView
      visible: win.contactsMode
      x: mainView.x
      y: mainView.y
      width: mainView.width
      height: mainView.height
      store: win.store
      bookId: win.contactsBook
      query: searchField.text
      selectedKey: win.contactKey
      fg: win.fg
      fontFamily: win.fontFamily
      onSelectRequested: function(key) { win.contactKey = key }
      onEditRequested: function(c) { win.editContact(c) }
      onNewRequested: win.newContact()
      onAddBookRequested: win.openBookEditor(null)
      onNotice: function(text) { win.flash(text) }
    }

    // ----------------------------------------------------------------- drawer
    Rectangle {
      id: drawerPane
      visible: win.drawer !== ""
      x: parent.width - width - Style.space(16)
      y: sidebar.y
      width: Style.space(win.drawer === "task" || win.drawer === "list" || win.drawer === "settings" ? 380 : 360)
      height: sidebar.height
      radius: Style.cornerRadius
      color: Util.alpha(win.fg, 0.04)
      border.width: Style.spacing.hairline
      border.color: Util.alpha(win.fg, 0.1)

      Flickable {
        id: drawerScroll
        anchors.fill: parent
        anchors.margins: Style.space(14)
        contentWidth: width
        contentHeight: win.drawer === "event" ? eventEditor.implicitHeight
          : win.drawer === "hidden" ? hiddenList.implicitHeight
          : win.drawer === "contact" ? contactEditor.implicitHeight
          : win.drawer === "book" ? bookEditor.implicitHeight
          : win.drawer === "task" ? taskEditor.implicitHeight
          : win.drawer === "list" ? listEditor.implicitHeight
          : win.drawer === "settings" ? settingsPane.implicitHeight : calendarEditor.implicitHeight
        topMargin: Style.space(4)
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        EventEditor {
          id: eventEditor
          visible: win.drawer === "event"
          width: drawerScroll.width
          store: win.store
          use24h: win.use24h
          fg: win.fg
          fontFamily: win.fontFamily
          onFinished: function(key) {
            if (key) win.cursorKey = key
            win.closeDrawer()
          }
        }

        HiddenList {
          id: hiddenList
          visible: win.drawer === "hidden"
          width: drawerScroll.width
          store: win.store
          use24h: win.use24h
          fg: win.fg
          fontFamily: win.fontFamily
          onFinished: win.closeDrawer()
          onPicked: function(key) { win.cursorKey = key }
        }

        CalendarEditor {
          id: calendarEditor
          visible: win.drawer === "calendar"
          width: drawerScroll.width
          store: win.store
          fg: win.fg
          fontFamily: win.fontFamily
          onFinished: win.closeDrawer()
        }

        ContactEditor {
          id: contactEditor
          visible: win.drawer === "contact"
          width: drawerScroll.width
          store: win.store
          fg: win.fg
          fontFamily: win.fontFamily
          onFinished: function(key) {
            if (key) win.contactKey = key
            win.closeDrawer()
          }
        }

        TaskEditor {
          id: taskEditor
          visible: win.drawer === "task"
          width: drawerScroll.width
          store: win.taskStore
          use24h: win.use24h
          fg: win.fg
          fontFamily: win.fontFamily
          onFinished: function(key) {
            if (key) win.selectedTaskKey = key
            win.closeDrawer()
          }
        }

        ListEditor {
          id: listEditor
          visible: win.drawer === "list"
          width: drawerScroll.width
          store: win.taskStore
          fg: win.fg
          fontFamily: win.fontFamily
          onAdded: function(id) { if (id) { win.setMode("tasks"); win.showList(id) } }
          onFinished: win.closeDrawer()
        }

        SettingsPane {
          id: settingsPane
          visible: win.drawer === "settings"
          width: drawerScroll.width
          calendarStore: win.store
          store: win.taskStore
          fg: win.fg
          fontFamily: win.fontFamily
          onFinished: win.closeDrawer()
        }

        AddressBookEditor {
          id: bookEditor
          visible: win.drawer === "book"
          width: drawerScroll.width
          store: win.store
          fg: win.fg
          fontFamily: win.fontFamily
          onAdded: function(id) { win.contactsBook = "" }
          onFinished: {
            if (win.contactsBook && win.store && !win.store.bookById(win.contactsBook)) win.contactsBook = ""
            win.closeDrawer()
          }
        }
      }
    }
  }
}
