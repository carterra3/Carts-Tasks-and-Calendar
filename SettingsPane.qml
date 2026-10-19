import QtQuick
import qs.Commons
import qs.Ui

// App settings in the drawer. Where tasks show up (the calendar views, the
// bar popup) is saved in calendar.json prefs, which the bar plugin reads
// too; the task rules (projects, completion, repeat history, default list)
// in tasks.json prefs.
Column {
  id: root

  property var calendarStore: null    // Store.qml
  property var store: null            // TaskStore.qml
  property color fg: Color.foreground
  property string fontFamily: Style.font.family

  signal finished()

  readonly property color faintFg: Qt.darker(fg, 1.9)

  spacing: Style.space(10)
  Keys.onPressed: function(event) {
    if (event.key === Qt.Key_Escape || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.finished(); event.accepted = true }
  }

  PanelSectionHeader { text: "SETTINGS"; foreground: root.fg; fontFamily: root.fontFamily }

  // ---- Calendar
  Caption { foreground: root.fg; fontFamily: root.fontFamily; text: "CALENDAR" }
  Toggle {
    id: tasksOnCalendar
    width: parent.width
    label: "Show tasks on the calendar"
    description: "Tasks with a due date appear in month, week, day, agenda and year views. Drag one to reschedule it."
    checked: root.calendarStore ? root.calendarStore.pref("tasksOnCalendar", true) : true
    foreground: root.fg
    fontFamily: root.fontFamily
    titleSize: Style.font.body
    onClicked: root.calendarStore.setPref("tasksOnCalendar", !checked)
  }
  Toggle {
    width: parent.width
    visible: tasksOnCalendar.checked
    label: "Include completed tasks"
    description: "Off: a task leaves the calendar once it is done"
    checked: root.calendarStore ? root.calendarStore.pref("tasksOnCalendarCompleted", false) : false
    foreground: root.fg
    fontFamily: root.fontFamily
    titleSize: Style.font.body
    onClicked: root.calendarStore.setPref("tasksOnCalendarCompleted", !checked)
  }

  // ---- Bar popup
  Caption { foreground: root.fg; fontFamily: root.fontFamily; text: "TASKS IN THE BAR POPUP" }
  ButtonGroup {
    focusable: false
    options: [{ value: "off", label: "Off" }, { value: "list", label: "Day list" }, { value: "calendar", label: "Day list + calendar" }]
    value: root.calendarStore ? root.calendarStore.pref("popupTasks", "list") : "list"
    foreground: root.fg
    fontFamily: root.fontFamily
    fontSize: Style.font.bodySmall
    onChanged: function(v) { root.calendarStore.setPref("popupTasks", v) }
  }
  Text {
    width: parent.width
    wrapMode: Text.Wrap
    textFormat: Text.PlainText
    text: "Day list: the selected day's tasks (and overdue ones on today) under its events, with a box to tick them off. + calendar: also on the popup's month, week and day views."
    color: root.faintFg
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  // ---- Tasks
  Caption { foreground: root.fg; fontFamily: root.fontFamily; text: "TASKS" }

  Text {
    textFormat: Text.PlainText
    text: "Completing a task with open subtasks"
    color: root.fg
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
  }
  ButtonGroup {
    focusable: false
    options: [{ value: "ask", label: "Ask" }, { value: "all", label: "Complete them too" }, { value: "none", label: "Leave them open" }]
    value: root.store ? root.store.subtasksWithParent : "ask"
    foreground: root.fg
    fontFamily: root.fontFamily
    fontSize: Style.font.bodySmall
    onChanged: function(v) { root.store.setPref("subtasksWithParent", v) }
  }

  Toggle {
    width: parent.width
    label: "Last subtask completes the parent"
    description: "Finishing the last open subtask completes its parent, all the way up"
    checked: root.store ? root.store.autoCompleteParent : false
    foreground: root.fg
    fontFamily: root.fontFamily
    titleSize: Style.font.body
    onClicked: root.store.setPref("autoCompleteParent", !root.store.autoCompleteParent)
  }

  Toggle {
    width: parent.width
    label: "Tasks with subtasks are projects"
    description: "Off: only tasks marked \u201cProject\u201d in the editor are listed under Projects"
    checked: root.store ? root.store.autoProjects : true
    foreground: root.fg
    fontFamily: root.fontFamily
    titleSize: Style.font.body
    onClicked: root.store.setPref("autoProjects", !root.store.autoProjects)
  }

  Toggle {
    width: parent.width
    label: "Keep history of repeats"
    description: "Each completion of a repeating task leaves a completed copy"
    checked: root.store ? root.store.keepHistory : true
    foreground: root.fg
    fontFamily: root.fontFamily
    titleSize: Style.font.body
    onClicked: root.store.setPref("keepHistory", !root.store.keepHistory)
  }

  Text {
    textFormat: Text.PlainText
    text: "Quick add goes to (outside a list)"
    color: root.fg
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
  }
  Dropdown {
    width: parent.width
    showLabel: false
    value: root.store ? root.store.defaultListId : ""
    options: root.store ? root.store.writableLists.map(function(l) { return { value: l.id, label: l.name } }) : []
    foreground: root.fg
    fontFamily: root.fontFamily
    onChanged: function(v) { root.store.setPref("defaultList", v) }
  }

  Button {
    text: "Done"
    bordered: true
    selected: true
    foreground: root.fg
    fontFamily: root.fontFamily
    onClicked: root.finished()
  }

  Text {
    width: parent.width
    wrapMode: Text.Wrap
    textFormat: Text.PlainText
    text: "Settings stay on this computer. Projects and subtasks themselves are stored on the task (RELATED-TO), so other CalDAV apps see the same tree."
    color: root.faintFg
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
}
