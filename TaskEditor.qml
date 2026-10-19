import QtQuick
import qs.Commons
import qs.Ui
import "Tasks.js" as Tasks
import "Recur.js" as Recur

// New / edit task form for the window's drawer. Storage (local or CalDAV)
// is the store's job. openNew(listId[, parentUid]) / openEdit(task) drive
// it; finished(key) is emitted when done ("" when cancelled).
Column {
  id: root

  property var store: null
  property bool use24h: true
  property color fg: Color.foreground
  property string fontFamily: Style.font.family

  signal finished(string key)

  property var editing: null            // the task as it was, or null for a new one
  property string formListId: ""
  property int formPriority: 0
  property string formRepeatFrom: "due"
  property string formParent: ""
  property bool formProject: false
  property string formError: ""
  property bool saving: false
  property bool confirmDelete: false
  property bool readOnly: false

  readonly property bool isNew: editing === null
  readonly property color dimFg: Qt.darker(fg, 1.5)
  readonly property color faintFg: Qt.darker(fg, 1.9)
  readonly property string todayKey: store ? store.todayKey : Tasks.keyOf(new Date())
  readonly property string dueKey: { var k = Tasks.parseDateField(dueField.text, root.todayKey); return k ? k : "" }
  readonly property string ruleNow: { var r = repeatEditor.ruleText(); return r === null ? "" : r }
  readonly property bool repeating: repeatEditor.preset !== "none"
  readonly property bool simpleRule: {
    var r = Recur.parseRule(root.ruleNow)
    for (var k in r) if (["FREQ", "INTERVAL", "COUNT", "UNTIL", "WKST"].indexOf(k) === -1) return false
    return true
  }
  readonly property var children_: editing && store ? store.allTasks.filter(function(t) { return t.parent === root.editing.uid && t.listId === root.editing.listId })
    .sort(Tasks.comparator("due")) : []

  spacing: Style.space(8)
  focus: readOnly
  Keys.onPressed: function(event) {
    if (event.key === Qt.Key_Escape) { root.cancel(); event.accepted = true }
    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { event.accepted = true; root.save() }
  }

  function reset() {
    root.formError = ""
    root.saving = false
    root.confirmDelete = false
    subField.text = ""
  }

  function fill(f) {
    titleField.text = f.title
    root.formListId = f.listId
    dueField.text = f.dueDate
    timeField.text = f.dueTime
    startField.text = f.startDate
    root.formPriority = f.priority
    root.formRepeatFrom = f.repeatFrom
    root.formParent = f.parent
    root.formProject = !!f.project
    tagsField.text = f.categories
    notesField.text = f.notes
    repeatEditor.load(f.rrule || "", f.dueDate || f.startDate || root.todayKey)
  }

  // false when there is no writable list to put it in.
  function openNew(listId, parentUid, due, asProject) {
    var target = listId && store.listWritable(listId) ? listId : store.defaultListId
    if (!target) return false
    root.editing = null
    root.readOnly = false
    reset()
    var f = Tasks.formFor({ listId: target, parent: parentUid || "", due: due || "", project: !!asProject }, root.use24h)
    fill(f)
    Qt.callLater(function() { titleField.forceActiveFocus() })
    return true
  }

  function openEdit(t) {
    root.editing = t
    root.readOnly = !store.taskEditable(t)
    reset()
    fill(Tasks.formFor(t, root.use24h))
    Qt.callLater(function() {
      if (root.readOnly) root.forceActiveFocus()
      else { titleField.forceActiveFocus(); titleField.selectAll() }
    })
  }

  function setDue(key) { dueField.text = key }

  function build() {
    var rule = repeatEditor.ruleText()
    if (rule === null) return { error: "Repeat end date not understood (try 2026-12-31)" }
    // A repeat without a date starts today.
    var due = dueField.text
    if (rule && due.replace(/\s+/g, "") === "" && startField.text.replace(/\s+/g, "") === "") due = root.todayKey
    return Tasks.buildTask({
      title: titleField.text, listId: root.formListId, notes: notesField.text,
      dueDate: due, dueTime: timeField.text, startDate: startField.text,
      priority: root.formPriority, rrule: rule, repeatFrom: root.simpleRule ? root.formRepeatFrom : "due",
      categories: tagsField.text, parent: root.formParent, project: root.formProject
    }, root.editing, store.nowStamp(), root.todayKey)
  }

  function cancel() {
    if (root.saving) return
    root.editing = null
    reset()
    root.finished("")
  }

  function save() {
    if (!store || root.saving) return
    if (root.readOnly) { cancel(); return }
    var res = build()
    if (res.error) { root.formError = res.error; return }
    var t = res.task
    // A parent from another list would be a dangling link.
    if (t.parent && !store.taskByKey(t.listId, t.parent)) t.parent = ""
    root.formError = ""
    root.saving = store.isRemote(t.listId) || (root.editing && store.isRemote(root.editing.listId))
    store.saveTask(t, root.editing, function(err) {
      root.saving = false
      if (err) { root.formError = err; return }
      root.editing = null
      root.finished(t.listId + "|" + t.uid)
    })
  }

  function remove() {
    if (!store || !root.editing || root.saving) return
    if (!root.confirmDelete) { root.confirmDelete = true; return }
    var t = root.editing
    root.saving = store.isRemote(t.listId)
    store.deleteTask(t, function(err) {
      root.saving = false
      if (err) { root.formError = err; root.confirmDelete = false; return }
      root.editing = null
      root.finished("")
    })
  }

  function toggleDone() {
    if (!root.editing || root.readOnly) return
    var t = root.editing
    root.editing = null
    store.toggleComplete(t)
    root.finished(t.listId + "|" + t.uid)
  }

  function skip() {
    if (!root.editing || root.readOnly) return
    var t = root.editing
    root.editing = null
    store.skipOccurrence(t)
    root.finished(t.listId + "|" + t.uid)
  }

  function addSubtask() {
    var text = subField.text.replace(/^\s+|\s+$/g, "")
    if (!text || !root.editing) return
    var err = store.quickAdd(text, root.editing.listId, root.editing.uid)
    if (err) root.formError = err
    else subField.text = ""
  }

  readonly property var parentOptions: {
    if (!store || !root.formListId) return []
    var own = root.editing ? [root.editing.uid].concat(Tasks.descendants(store.allTasks, root.editing.uid).map(function(t) { return t.uid })) : []
    var opts = [{ value: "", label: "Not a subtask" }]
    store.allTasks.forEach(function(t) {
      if (t.listId !== root.formListId || Tasks.isDone(t) || own.indexOf(t.uid) !== -1) return
      opts.push({ value: t.uid, label: t.title })
    })
    return opts
  }

  // ------------------------------------------------------------------ form
  PanelSectionHeader {
    text: (root.formProject && !root.formParent ? (root.readOnly ? "PROJECT" : root.isNew ? "NEW PROJECT" : "EDIT PROJECT")
      : root.readOnly ? "TASK" : root.isNew ? "NEW TASK" : "EDIT TASK")
    foreground: root.fg
    fontFamily: root.fontFamily
  }

  Text {
    visible: root.readOnly
    width: parent.width
    wrapMode: Text.Wrap
    textFormat: Text.PlainText
    text: "󰌾  This list is read-only on the server."
    color: root.dimFg
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  TextField {
    id: titleField
    width: parent.width
    placeholderText: "Title"
    readOnly: root.readOnly
    foreground: root.fg
    font.family: root.fontFamily
  }

  Dropdown {
    width: parent.width
    showLabel: false
    enabled: !root.readOnly && !root.saving
    value: root.formListId
    options: root.store ? (root.readOnly ? root.store.lists.filter(function(l) { return l.id === root.formListId }) : root.store.writableLists)
      .map(function(l) { return { value: l.id, label: l.name } }) : []
    foreground: root.fg
    fontFamily: root.fontFamily
    onChanged: function(v) { root.formListId = v; if (root.formParent && !root.store.taskByKey(v, root.formParent)) root.formParent = "" }
    Swatch {
      anchors.right: parent.right
      anchors.rightMargin: Style.space(30)
      anchors.verticalCenter: parent.verticalCenter
      swatch: root.store ? root.store.listColor(root.formListId) : Color.accent
    }
  }
  Text {
    visible: root.store && root.store.isRemote(root.formListId)
    width: parent.width
    wrapMode: Text.Wrap
    textFormat: Text.PlainText
    text: root.store ? root.store.sourceLabel(root.formListId) : ""
    color: root.faintFg
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Caption { foreground: root.fg; fontFamily: root.fontFamily; text: "DUE" }
  Row {
    width: parent.width
    spacing: Style.space(8)
    TextField {
      id: dueField
      width: (parent.width - parent.spacing) * 0.58
      placeholderText: "No date  (fri, 10/31…)"
      readOnly: root.readOnly
      foreground: root.fg
      font.family: root.fontFamily
      onTextChanged: if (root.dueKey) repeatEditor.startKey = root.dueKey
    }
    TextField {
      id: timeField
      width: (parent.width - parent.spacing) * 0.42
      placeholderText: "Time"
      readOnly: root.readOnly
      foreground: root.fg
      font.family: root.fontFamily
    }
  }
  Flow {
    visible: !root.readOnly
    width: parent.width
    spacing: Style.space(6)
    Repeater {
      model: [
        { label: "Today", key: function() { return root.todayKey } },
        { label: "Tomorrow", key: function() { return Tasks.addDaysKey(root.todayKey, 1) } },
        { label: "Next week", key: function() { var d = Tasks.parseStamp(root.todayKey); return Tasks.addDaysKey(root.todayKey, ((8 - d.getDay()) % 7) || 7) } },
        { label: "No date", key: function() { return "" } }
      ]
      Button {
        required property var modelData
        text: modelData.label
        bordered: true
        selected: modelData.key() === root.dueKey && (root.dueKey !== "" || dueField.text === "")
        horizontalPadding: Style.space(8)
        fontSize: Style.font.caption
        foreground: root.fg
        fontFamily: root.fontFamily
        onClicked: { root.setDue(modelData.key()); if (!modelData.key()) timeField.text = "" }
      }
    }
  }
  Text {
    readonly property string label: root.dueKey ? Tasks.dateLabel(root.dueKey, root.todayKey, root.use24h) + " · " + Qt.formatDate(Tasks.parseStamp(root.dueKey), "dddd, MMMM d, yyyy") : ""
    visible: label !== "" && dueField.text !== root.dueKey
    width: parent.width
    textFormat: Text.PlainText
    text: label
    color: root.faintFg
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Caption { foreground: root.fg; fontFamily: root.fontFamily; text: "PRIORITY" }
  ButtonGroup {
    focusable: false
    enabled: !root.readOnly
    options: [{ value: "0", label: "None" }, { value: "9", label: "Low" }, { value: "5", label: "Medium" }, { value: "1", label: "High" }]
    value: String(root.formPriority)
    foreground: root.fg
    fontFamily: root.fontFamily
    fontSize: Style.font.bodySmall
    onChanged: function(v) { root.formPriority = +v }
  }

  RepeatEditor {
    id: repeatEditor
    width: parent.width
    visible: !root.readOnly || preset !== "none"
    readOnly: root.readOnly
    allDay: timeField.text.replace(/\s+/g, "") === ""
    fg: root.fg
    fontFamily: root.fontFamily
  }

  Column {
    visible: root.repeating
    width: parent.width
    spacing: Style.space(6)

    Text {
      visible: !root.dueKey && !root.readOnly
      width: parent.width
      wrapMode: Text.Wrap
      textFormat: Text.PlainText
      text: "A repeating task needs a due date; it starts from today if you leave it empty."
      color: root.faintFg
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Caption { visible: root.simpleRule; foreground: root.fg; fontFamily: root.fontFamily; text: "NEXT DATE COUNTS FROM" }
    ButtonGroup {
      focusable: false
      visible: root.simpleRule
      enabled: !root.readOnly
      options: [{ value: "due", label: "The due date" }, { value: "completion", label: "When I complete it" }]
      value: root.formRepeatFrom
      foreground: root.fg
      fontFamily: root.fontFamily
      fontSize: Style.font.bodySmall
      onChanged: function(v) { root.formRepeatFrom = v }
    }
    Text {
      width: parent.width
      wrapMode: Text.Wrap
      textFormat: Text.PlainText
      text: {
        if (root.formRepeatFrom === "completion" && root.simpleRule)
          return "Completing it sets the next due date " + Recur.summary(root.ruleNow).toLowerCase().replace(/^every /, "").replace(/^(daily|weekly|monthly|yearly)/, function(m) { return ({ daily: "a day", weekly: "a week", monthly: "a month", yearly: "a year" })[m] }) + " after that day."
        var due = root.dueKey || root.todayKey
        var next = Tasks.upcoming({ due: due, start: "", rrule: root.ruleNow }, Recur, 3, root.todayKey)
        return "Next: " + [due].concat(next).filter(function(k, i, a) { return k && a.indexOf(k) === i }).slice(0, 4)
          .map(function(k) { return Tasks.dateLabel(k, root.todayKey, root.use24h) }).join(", ")
          + ". Done late? The next one is the first date after today."
      }
      color: root.faintFg
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  Caption { foreground: root.fg; fontFamily: root.fontFamily; text: "MORE" }
  TextField {
    id: startField
    width: parent.width
    visible: !root.readOnly || text !== ""
    placeholderText: "Start date (optional)"
    readOnly: root.readOnly
    foreground: root.fg
    font.family: root.fontFamily
  }
  TextField {
    id: tagsField
    width: parent.width
    visible: !root.readOnly || text !== ""
    placeholderText: "Tags, comma separated"
    readOnly: root.readOnly
    foreground: root.fg
    font.family: root.fontFamily
  }
  SearchableDropdown {
    width: parent.width
    visible: root.parentOptions.length > 1 && (!root.readOnly || root.formParent !== "")
    enabled: !root.readOnly
    showLabel: false
    value: root.formParent
    placeholderText: "Search tasks…"
    options: root.parentOptions.map(function(o) { return o.value === "" ? o : { value: o.value, label: "Subtask of: " + o.label } })
    foreground: root.fg
    fontFamily: root.fontFamily
    onChanged: function(v) { root.formParent = v }
  }
  Toggle {
    visible: !root.formParent && !root.readOnly
    width: parent.width
    label: "Project"
    description: root.children_.length ? "It has subtasks, so it is listed under Projects anyway" : "List it under Projects even before it has steps"
    checked: root.formProject
    foreground: root.fg
    fontFamily: root.fontFamily
    titleSize: Style.font.body
    onClicked: root.formProject = !root.formProject
  }
  TextBox {
    id: notesField
    width: parent.width
    readOnly: root.readOnly
    placeholderText: "Notes"
    foreground: root.fg
  }

  // ---- subtasks of an existing task
  Column {
    visible: !root.isNew
    width: parent.width
    spacing: Style.space(4)

    Caption { foreground: root.fg; fontFamily: root.fontFamily; text: (root.formProject ? "STEPS" : "SUBTASKS") + (root.children_.length ? "  " + root.children_.filter(Tasks.isDone).length + "/" + root.children_.length : "") }
    Repeater {
      model: root.children_
      Item {
        id: sub
        required property var modelData
        width: root.width
        height: Style.space(26)
        Rectangle {
          id: subCheck
          anchors.verticalCenter: parent.verticalCenter
          x: Style.space(2)
          width: Style.space(14)
          height: width
          radius: width / 2
          color: Tasks.isDone(sub.modelData) ? Color.accent : "transparent"
          border.width: Math.max(1, Style.space(2))
          border.color: Color.accent
          MouseArea {
            anchors.fill: parent
            anchors.margins: -Style.space(4)
            cursorShape: Qt.PointingHandCursor
            enabled: !root.readOnly
            onClicked: root.store.toggleComplete(sub.modelData)
          }
        }
        Text {
          anchors.left: subCheck.right
          anchors.leftMargin: Style.space(8)
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          elide: Text.ElideRight
          textFormat: Text.PlainText
          text: sub.modelData.title + (sub.modelData.due ? "  ·  " + Tasks.dateLabel(sub.modelData.due, root.todayKey, root.use24h) : "")
          color: Tasks.isDone(sub.modelData) ? root.faintFg : root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.strikeout: Tasks.isDone(sub.modelData)
        }
      }
    }
    TextField {
      id: subField
      visible: !root.readOnly
      width: parent.width
      placeholderText: "Add a subtask (Enter)"
      foreground: root.fg
      font.family: root.fontFamily
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.addSubtask(); event.accepted = true }
      }
    }
  }

  Text {
    visible: root.formError !== ""
    width: parent.width
    wrapMode: Text.Wrap
    textFormat: Text.PlainText
    text: root.formError
    color: Color.urgent
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  Flow {
    width: parent.width
    spacing: Style.space(8)
    Button {
      visible: !root.readOnly
      text: root.saving ? "Saving…" : "Save"
      enabled: !root.saving
      bordered: true
      selected: true
      foreground: root.fg
      fontFamily: root.fontFamily
      onClicked: root.save()
    }
    Button {
      text: root.readOnly ? "Close" : "Cancel"
      enabled: !root.saving
      bordered: true
      foreground: root.fg
      fontFamily: root.fontFamily
      onClicked: root.cancel()
    }
    Button {
      visible: !root.isNew && !root.readOnly
      enabled: !root.saving
      text: root.editing && Tasks.isDone(root.editing) ? "Reopen" : root.editing && Tasks.isRepeating(root.editing) ? "Complete this one" : "Complete"
      iconText: "󰄬"
      bordered: true
      foreground: root.fg
      fontFamily: root.fontFamily
      onClicked: root.toggleDone()
    }
    Button {
      visible: !root.isNew && !root.readOnly && root.editing && Tasks.isRepeating(root.editing) && !Tasks.isDone(root.editing)
      enabled: !root.saving
      text: "Skip"
      iconText: "󰒭"
      tooltipText: "Move to the next date without completing"
      bordered: true
      foreground: root.fg
      fontFamily: root.fontFamily
      onClicked: root.skip()
    }
    Button {
      visible: !root.isNew && !root.readOnly
      enabled: !root.saving
      text: root.confirmDelete ? (root.children_.length ? "Really delete it and its subtasks?" : "Really delete?") : "Delete"
      bordered: true
      foreground: root.confirmDelete ? Color.urgent : root.fg
      fontFamily: root.fontFamily
      onClicked: root.remove()
    }
  }

  Text {
    visible: !root.readOnly
    width: parent.width
    wrapMode: Text.Wrap
    textFormat: Text.PlainText
    text: "Enter saves, Esc cancels. Dates take 2026-10-31, 10/31, fri, tomorrow, in 3 days."
    color: root.faintFg
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
}
