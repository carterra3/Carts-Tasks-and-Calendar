import QtQuick
import qs.Commons
import qs.Ui
import "Tasks.js" as Tasks
import "Recur.js" as Recur

// The main area: a quick-add field, then the tasks of the chosen smart list
// or list in sections (Overdue / Today / days / Completed ...). Subtasks sit
// under their parent in list views. Editing happens in the window's drawer.
Item {
  id: root

  property var store: null
  property string view: "today"
  property string listId: ""
  property string projectKey: ""          // "listId|uid" in the project view
  property string query: ""
  property string sort: "due"
  property bool showCompleted: false
  property string selectedKey: ""        // "listId|uid"
  property bool use24h: true
  // Off while another mode fills the window: no sections are built.
  property bool active: true
  property color fg: Color.foreground
  property string fontFamily: Style.font.family

  signal selectRequested(string key)
  signal editRequested(var task)
  signal addListRequested()
  signal leaveRequested()           // Esc in the quick-add field: keys back to the list

  readonly property color dimFg: Qt.darker(fg, 1.5)
  readonly property color faintFg: Qt.darker(fg, 1.9)
  readonly property string todayKey: store ? store.todayKey : Tasks.keyOf(new Date())
  readonly property bool listView: view === "list"
  readonly property bool projectView: view === "project"
  readonly property var project: projectView && store ? Tasks.projectByKey(store.projects, projectKey) : null
  readonly property var projectTask: projectView && store ? store.taskByKey(projectKey.split("|")[0], projectKey.split("|")[1]) : null
  readonly property bool treeView: listView || projectView || view === "all"

  readonly property var sections: store && active ? Tasks.sections(store.allTasks, {
    view: view, listId: listId, projectKey: projectKey, query: query, sort: sort, showCompleted: showCompleted,
    todayKey: todayKey, lists: store.lists, collapsed: store.collapsed
  }) : []
  readonly property var rows: Tasks.rowsOf(sections)
  readonly property var items: {
    var out = []
    for (var i = 0; i < sections.length; i++) {
      var s = sections[i]
      if (s.title !== "") out.push({ kind: "header", section: s })
      for (var j = 0; j < s.rows.length; j++) out.push({ kind: "task", row: s.rows[j], section: s })
    }
    return out
  }
  function keyOf(t) { return t ? t.listId + "|" + t.uid : "" }
  readonly property int currentIndex: {
    for (var i = 0; i < rows.length; i++) if (keyOf(rows[i].task) === selectedKey) return i
    return -1
  }
  readonly property var current: currentIndex >= 0 ? rows[currentIndex].task : null

  // Where quick-add puts a task.
  readonly property string targetListId: listView ? listId : projectTask ? projectTask.listId : (store ? store.defaultListId : "")
  readonly property string targetParent: projectTask ? projectTask.uid : ""
  readonly property bool canAdd: !!store && targetListId !== "" && store.listWritable(targetListId)

  onRowsChanged: if (currentIndex < 0 && rows.length) Qt.callLater(function() { if (root.currentIndex < 0 && root.rows.length) root.selectRequested(root.keyOf(root.rows[0].task)) })

  function move(delta) {
    if (!rows.length) return
    var i = currentIndex < 0 ? 0 : Math.max(0, Math.min(rows.length - 1, currentIndex + delta))
    selectRequested(keyOf(rows[i].task))
    for (var j = 0; j < items.length; j++) if (items[j].kind === "task" && items[j].row === rows[i]) { listView_.positionViewAtIndex(j, ListView.Contain); break }
  }

  // Added in Today: due today; in Important: high priority (so it stays in view).
  readonly property var quickDefaults: view === "today" || view === "scheduled" ? { due: todayKey } : view === "important" ? { priority: 1 } : ({})

  // Tab / Shift+Tab: subtask of the row above / up one level.
  function indent() {
    var t = current
    if (!t || !treeView || !store) return
    var target = Tasks.indentTarget(rows, currentIndex)
    if (target === null) { store.flash("Nothing above to put it under", true); return }
    store.setParent(t, target, function(err) { if (err) store.flash(err, true) })
  }
  function outdent() {
    var t = current
    if (!t || !store) return
    var target = Tasks.outdentTarget(t, store.allTasks)
    if (target === null) return
    // Not out of the project being shown.
    if (projectTask && target === "") return
    store.setParent(t, target, function(err) { if (err) store.flash(err, true) })
  }
  // Fold (false) or unfold (true) the selected task's subtasks; folding on a
  // subtask selects its parent first.
  function unfold(open) {
    var r = currentIndex >= 0 ? rows[currentIndex] : null
    if (!r || !store) return
    if (r.kids > 0 && r.collapsed === open) { store.setCollapsed(keyOf(r.task), !open); return }
    if (!open && r.task.parent) {
      var p = store.taskByKey(r.task.listId, r.task.parent)
      if (p && rows.some(function(x) { return x.task === p || keyOf(x.task) === keyOf(p) })) selectRequested(keyOf(p))
    }
  }

  function focusQuickAdd() { quickField.forceActiveFocus(); quickField.selectAll() }

  function submitQuick() {
    var text = quickField.text.replace(/^\s+|\s+$/g, "")
    if (!text || !store) return
    var err = store.quickAdd(text, root.targetListId, root.targetParent, root.quickDefaults)
    if (err) { quickError.text = err; return }
    quickError.text = ""
    quickField.text = ""
  }

  function preview(text) {
    if (!store || !String(text).replace(/\s+/g, "")) return ""
    var q = Tasks.parseQuick(text, root.todayKey, Recur)
    if (root.quickDefaults.due && !q.due) q.due = root.quickDefaults.due
    if (root.quickDefaults.priority && !q.priority) q.priority = root.quickDefaults.priority
    var bits = []
    if (q.due) bits.push("󰃭 " + Tasks.dateLabel(q.due, root.todayKey, root.use24h))
    if (q.rrule) bits.push("󰑖 " + Recur.summary(q.rrule) + (q.repeatFrom === "completion" ? " after completion" : ""))
    if (q.priority) bits.push("! " + Tasks.priorityName(q.priority))
    if (q.categories.length) bits.push(q.categories.map(function(c) { return "#" + c }).join(" "))
    var l = q.list ? store.listByName(q.list) : null
    var target = l && store.listWritable(l.id) ? l.id : root.targetListId
    var parent = q.project ? store.findParent(q.project, "") : null
    if (q.project) bits.push(parent ? "↳ " + parent.title : "⚠ no project \u201c" + q.project + "\u201d")
    else if (root.projectTask) bits.push("↳ " + root.projectTask.title)
    bits.push("→ " + store.listName(parent ? parent.listId : target))
    return "\u201c" + q.title + "\u201d  " + bits.join("  ·  ")
  }

  function priorityColor(p) {
    var lvl = Tasks.priorityLevel(p)
    return lvl === 1 ? Color.urgent : lvl === 2 ? Color.accent : lvl === 3 ? root.dimFg : root.faintFg
  }

  // ------------------------------------------------------------ quick add
  Column {
    id: top
    width: parent.width
    spacing: Style.space(4)
    visible: root.store && root.store.lists.length > 0 && root.view !== "completed"

    // The project's own card: due date, progress, notes.
    Rectangle {
      visible: root.projectTask !== null
      width: parent.width
      height: visible ? projCol.implicitHeight + Style.space(20) : 0
      radius: Style.cornerRadius
      color: Util.alpha(root.store && root.projectTask ? root.store.listColor(root.projectTask.listId) : Color.accent, 0.08)
      Column {
        id: projCol
        x: Style.space(12)
        y: Style.space(10)
        width: parent.width - Style.space(24)
        spacing: Style.space(6)
        Row {
          spacing: Style.space(14)
          Text {
            textFormat: Text.PlainText
            text: !root.project ? "" : root.project.total ? root.project.done + " of " + root.project.total + " done" : "No steps yet"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }
          Text {
            visible: root.projectTask && !!root.projectTask.due
            textFormat: Text.PlainText
            text: root.projectTask && root.projectTask.due ? "󰃭 due " + Tasks.dateLabel(root.projectTask.due, root.todayKey, root.use24h) : ""
            color: root.projectTask && Tasks.dueState(root.projectTask, root.todayKey) === "overdue" ? Color.urgent : root.dimFg
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
          Text {
            visible: root.projectTask && Tasks.isDone(root.projectTask)
            textFormat: Text.PlainText
            text: "󰄬 completed"
            color: Color.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }
        Rectangle {
          width: parent.width
          height: Style.space(4)
          radius: height / 2
          color: Util.alpha(root.fg, 0.1)
          Rectangle {
            width: parent.width * (root.project && root.project.total ? root.project.done / root.project.total : 0)
            height: parent.height
            radius: parent.radius
            color: root.store && root.projectTask ? root.store.listColor(root.projectTask.listId) : Color.accent
          }
        }
        Text {
          visible: root.projectTask && !!root.projectTask.notes
          width: parent.width
          wrapMode: Text.Wrap
          maximumLineCount: 4
          elide: Text.ElideRight
          textFormat: Text.PlainText
          text: root.projectTask ? (root.projectTask.notes || "") : ""
          color: root.dimFg
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
        Row {
          spacing: Style.space(8)
          Button {
            text: "Edit project"
            bordered: true
            fontSize: Style.font.caption
            foreground: root.fg
            fontFamily: root.fontFamily
            onClicked: root.editRequested(root.projectTask)
          }
          Button {
            visible: root.store && root.projectTask && root.store.taskEditable(root.projectTask)
            text: root.projectTask && Tasks.isDone(root.projectTask) ? "Reopen project" : "Complete project"
            bordered: true
            fontSize: Style.font.caption
            foreground: root.fg
            fontFamily: root.fontFamily
            onClicked: root.store.toggleComplete(root.projectTask)
          }
        }
      }
    }

    TextField {
      id: quickField
      width: parent.width
      enabled: root.canAdd
      placeholderText: !root.canAdd ? "This list is read-only" : root.projectTask ? "Add a step to " + root.projectTask.title + "  (n)"
        : "Add a task to " + root.store.listName(root.targetListId) + "  —  try \u201cPay rent every month on the 1st !high\u201d  (n)"
      foreground: root.fg
      font.family: root.fontFamily
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.submitQuick(); event.accepted = true }
        else if (event.key === Qt.Key_Escape) { quickField.text = ""; quickError.text = ""; root.leaveRequested(); event.accepted = true }
        else if (event.key === Qt.Key_Down && quickField.text === "") { root.leaveRequested(); root.move(0); event.accepted = true }
      }
    }
    Text {
      id: quickHint
      width: parent.width
      visible: text !== ""
      elide: Text.ElideRight
      textFormat: Text.PlainText
      text: quickError.text !== "" ? "" : root.preview(quickField.text)
      color: root.dimFg
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
    Text {
      id: quickError
      width: parent.width
      visible: text !== ""
      textFormat: Text.PlainText
      color: Color.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // ---------------------------------------------------------- empty states
  Column {
    visible: root.store && root.store.lists.length === 0
    anchors.centerIn: parent
    width: Math.min(parent.width - Style.space(40), Style.space(420))
    spacing: Style.space(12)
    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.Wrap
      textFormat: Text.PlainText
      text: "Add a list on this computer, or connect a CalDAV account (the ones the Calendar uses are offered first)."
      color: root.dimFg
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }
    Button {
      anchors.horizontalCenter: parent.horizontalCenter
      text: "Add a list"
      iconText: "󰐕"
      bordered: true
      selected: true
      foreground: root.fg
      fontFamily: root.fontFamily
      onClicked: root.addListRequested()
    }
  }

  Text {
    visible: root.store && root.store.lists.length > 0 && root.items.length === 0
    anchors.horizontalCenter: parent.horizontalCenter
    y: top.y + top.height + Style.space(40)
    width: parent.width - Style.space(40)
    horizontalAlignment: Text.AlignHCenter
    wrapMode: Text.Wrap
    textFormat: Text.PlainText
    text: root.query !== "" ? "No tasks match \u201c" + root.query + "\u201d"
      : root.view === "today" ? "Nothing due today."
      : root.view === "completed" ? "No completed tasks yet."
      : root.view === "important" ? "No high-priority tasks."
      : root.view === "scheduled" ? "No tasks with a due date."
      : root.projectView ? "No open steps. Add one above."
      : "No tasks here yet."
    color: root.faintFg
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
  }

  // ------------------------------------------------------------------- list
  ListView {
    id: listView_
    y: top.visible ? top.y + top.height + Style.space(10) : 0
    width: parent.width
    height: parent.height - y
    clip: true
    topMargin: Style.space(2)
    boundsBehavior: Flickable.StopAtBounds
    model: root.items
    reuseItems: false

    delegate: Item {
      id: cell
      required property var modelData
      readonly property bool header: modelData.kind === "header"
      readonly property var task: header ? null : modelData.row.task
      readonly property var row: header ? null : modelData.row
      readonly property bool done: !header && Tasks.isDone(task)
      readonly property bool selected: !header && root.keyOf(task) === root.selectedKey
      readonly property string state_: header ? "" : Tasks.dueState(task, root.todayKey, root.store ? root.store.nowStamp() : "")
      readonly property bool editable: !header && root.store && root.store.taskEditable(task)
      width: ListView.view.width
      height: header ? Style.space(34) : Math.max(Style.space(40), textCol.implicitHeight + Style.space(16))

      // ---- section header
      Text {
        visible: cell.header
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Style.space(6)
        x: Style.space(4)
        textFormat: Text.PlainText
        text: cell.header ? cell.modelData.section.title.toUpperCase() + "   " + cell.modelData.section.rows.length : ""
        color: cell.header && cell.modelData.section.tone === "urgent" ? Color.urgent : Qt.darker(root.fg, 1.4)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.letterSpacing: 1
        font.bold: true
      }

      // ---- task row
      Rectangle {
        visible: !cell.header
        anchors.fill: parent
        anchors.bottomMargin: Style.space(2)
        radius: Style.cornerRadius
        color: cell.selected ? Util.alpha(Color.accent, 0.15) : rowMouse.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"

        MouseArea {
          id: rowMouse
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.LeftButton
          onClicked: root.selectRequested(root.keyOf(cell.task))
          onDoubleClicked: root.editRequested(cell.task)
        }

        // Fold/unfold subtasks
        Text {
          id: chevron
          visible: !cell.header && cell.row.kids > 0
          x: Style.space(4) + (cell.row ? cell.row.depth : 0) * Style.space(24)
          y: textCol.y + (titleText.height - height) / 2
          width: Style.space(16)
          horizontalAlignment: Text.AlignHCenter
          text: cell.row && cell.row.collapsed ? "󰅂" : "󰅀"
          color: chevMouse.containsMouse ? root.fg : root.faintFg
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          MouseArea {
            id: chevMouse
            anchors.fill: parent
            anchors.margins: -Style.space(4)
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.store.toggleCollapsed(root.keyOf(cell.task))
          }
        }

        // Checkbox
        Rectangle {
          id: check
          x: (root.treeView ? Style.space(24) : Style.space(10)) + (cell.row ? cell.row.depth : 0) * Style.space(24)
          y: textCol.y + (titleText.height - height) / 2
          width: Style.space(18)
          height: width
          radius: width / 2
          color: cell.done ? Util.alpha(root.store ? root.store.listColor(cell.task.listId) : Color.accent, 0.85)
            : checkMouse.containsMouse ? Util.alpha(root.store ? root.store.listColor(cell.task.listId) : Color.accent, 0.2) : "transparent"
          border.width: Math.max(1, Style.space(2))
          border.color: cell.header ? "transparent" : Tasks.priorityLevel(cell.task.priority) === 1 && !cell.done ? Color.urgent
            : (root.store ? root.store.listColor(cell.task.listId) : Color.accent)
          opacity: cell.editable ? 1 : 0.5
          Text {
            anchors.centerIn: parent
            visible: cell.done || checkMouse.containsMouse
            text: "󰄬"
            color: cell.done ? Color.background : root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          MouseArea {
            id: checkMouse
            anchors.fill: parent
            anchors.margins: -Style.space(6)
            hoverEnabled: true
            cursorShape: cell.editable ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: {
              root.selectRequested(root.keyOf(cell.task))
              if (cell.editable) root.store.toggleComplete(cell.task)
            }
          }
          PanelToolTip {
            visible: checkMouse.containsMouse && !cell.header && Tasks.isRepeating(cell.task) && !cell.done
            text: "Complete this one; it comes back " + (cell.task && cell.task.repeatFrom === "completion" ? "after completion" : "on its next date")
            fontFamily: root.fontFamily
          }
        }

        Column {
          id: textCol
          anchors.left: check.right
          anchors.leftMargin: Style.space(12)
          anchors.right: prio.left
          anchors.rightMargin: Style.space(8)
          y: meta.visible ? Style.space(8) : (cell.height - Style.space(2) - titleText.height) / 2
          spacing: Style.space(2)

          Text {
            id: titleText
            width: parent.width
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: cell.header ? "" : cell.task.title
            color: cell.done ? root.faintFg : root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.strikeout: cell.done
          }

          Row {
            id: meta
            width: parent.width
            spacing: Style.space(10)
            clip: true
            visible: metaDue.visible || metaRepeat.visible || metaList.visible || metaTags.visible || metaSubs.visible || metaNotes.visible || metaStart.visible || metaParent.visible

            Text {
              id: metaDue
              visible: !cell.header && (cell.done ? !!cell.task.completed : !!cell.task.due)
              textFormat: Text.PlainText
              text: cell.header ? "" : cell.done ? "󰄬 " + Tasks.dateLabel(cell.task.completed, root.todayKey, root.use24h)
                : "󰃭 " + Tasks.dateLabel(cell.task.due, root.todayKey, root.use24h)
              color: cell.state_ === "overdue" ? Color.urgent : cell.state_ === "today" ? Color.accent : root.dimFg
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: cell.state_ === "overdue" || cell.state_ === "today"
            }
            Text {
              id: metaStart
              visible: !cell.header && !cell.done && !!cell.task.start && cell.task.start !== cell.task.due && Tasks.dayOf(cell.task.start) > root.todayKey
              textFormat: Text.PlainText
              text: cell.header ? "" : "starts " + Tasks.dateLabel(Tasks.dayOf(cell.task.start), root.todayKey, root.use24h)
              color: root.faintFg
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            Text {
              id: metaRepeat
              visible: !cell.header && !cell.done && Tasks.isRepeating(cell.task)
              textFormat: Text.PlainText
              text: cell.header || !cell.task.rrule ? "" : "󰑖 " + Recur.summary(cell.task.rrule) + (cell.task.repeatFrom === "completion" ? " after done" : "")
              color: root.dimFg
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            Row {
              id: metaList
              visible: !cell.header && !root.listView && !root.projectView && !(cell.modelData.section && cell.modelData.section.listId)
              spacing: Style.space(4)
              Swatch {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(8)
                swatch: cell.header || !root.store ? Color.accent : root.store.listColor(cell.task.listId)
              }
              Text {
                textFormat: Text.PlainText
                text: cell.header || !root.store ? "" : root.store.listName(cell.task.listId)
                color: root.faintFg
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
            Text {
              id: metaParent
              visible: !cell.header && cell.row.parentTitle !== ""
              textFormat: Text.PlainText
              text: cell.header ? "" : "↳ " + cell.row.parentTitle
              color: root.dimFg
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            Text {
              id: metaSubs
              visible: !cell.header && cell.row.children > 0
              textFormat: Text.PlainText
              text: cell.header ? "" : "󰘍 " + cell.row.done + "/" + cell.row.children + (cell.row.collapsed ? " folded" : "")
              color: root.faintFg
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            Text {
              id: metaTags
              visible: !cell.header && (cell.task.categories || []).length > 0
              textFormat: Text.PlainText
              text: cell.header ? "" : (cell.task.categories || []).map(function(c) { return "#" + c }).join(" ")
              color: Color.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            Text {
              id: metaNotes
              visible: !cell.header && !!cell.task.notes
              text: "󰎞"
              color: root.faintFg
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        Text {
          id: prio
          anchors.right: parent.right
          anchors.rightMargin: Style.space(12)
          y: textCol.y + (titleText.height - height) / 2
          visible: !cell.header && Tasks.priorityLevel(cell.task.priority) > 0 && !cell.done
          textFormat: Text.PlainText
          text: cell.header ? "" : ["", "!!!", "!!", "!"][Tasks.priorityLevel(cell.task.priority)]
          color: cell.header ? root.fg : root.priorityColor(cell.task.priority)
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }
      }
    }
  }
}
