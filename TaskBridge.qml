import QtQuick
import "Tasks.js" as Tasks

// Puts tasks on a calendar Store: hand `items` to the Store's taskEvents /
// taskCalendars and the bridge itself to its taskHandler. Used by the app
// (CalendarApp.qml) and the bar plugin (Service.qml), each with its own
// setting for `enabled`.
QtObject {
  id: root

  property var taskStore: null
  property bool enabled: true
  property bool showCompleted: false

  readonly property var noItems: ({ events: [], calendars: [] })
  readonly property var items: enabled && taskStore && taskStore.ready
    ? Tasks.calendarItems(taskStore.allTasks, taskStore.lists, {
        showCompleted: showCompleted,
        editable: function(t) { return root.taskStore.taskEditable(t) } })
    : noItems

  // The task behind a stand-in event ("listId|uid" in ev.taskRef).
  function taskFor(ev) {
    var ref = String(ev && ev.taskRef || "")
    var i = ref.indexOf("|")
    return i > 0 && taskStore ? taskStore.taskByKey(ref.substr(0, i), ref.substr(i + 1)) : null
  }

  // Store.taskHandler: a drag in a calendar view gives the task a new due
  // date (all-day items) or time (timed ones). done(error or "")
  function moveTask(ev, changed, done) {
    var t = taskFor(ev)
    if (!t) { done("That task is gone"); return }
    if (!taskStore.taskEditable(t)) { done("This list is read-only"); return }
    var due = Tasks.dueFromMove(ev, changed)
    if (due && due !== t.due) taskStore.setDue(t, due)
    done("")
  }
}
