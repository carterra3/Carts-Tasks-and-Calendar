import QtQuick
import qs.Commons
import qs.Ui
import "Tasks.js" as Tasks

// The popup's task list for the selected day: tasks due that day (and, on
// today, anything overdue). The box completes a task, the title opens it in
// the app. Shown when Settings → "Tasks in the bar popup" is not Off.
Column {
  id: root

  property var store: null            // TaskStore.qml
  property string dayKey: ""
  property string todayKey: ""
  property bool use24h: true
  property color fg: Color.foreground
  property string fontFamily: Style.font.family

  signal openRequested(string key)    // "listId|uid"
  signal openAllRequested()           // the app on Today
  signal newRequested()

  readonly property color dimFg: Qt.darker(fg, 1.5)
  readonly property color faintFg: Qt.darker(fg, 1.9)
  readonly property var tasks: store && store.ready ? Tasks.dueOn(store.allTasks, store.lists, dayKey, todayKey) : []
  readonly property int maxRows: 8

  spacing: Style.space(4)

  Item {
    width: parent.width
    height: Math.max(header.implicitHeight, newBtn.height)
    Caption {
      id: header
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      foreground: root.fg
      fontFamily: root.fontFamily
      text: "TASKS" + (root.tasks.length ? "  " + root.tasks.length : "")
    }
    Row {
      anchors.right: parent.right
      anchors.rightMargin: -Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      PanelActionButton {
        iconText: "\uf08e"
        tooltipText: "Open tasks"
        foreground: root.fg
        fontFamily: root.fontFamily
        onClicked: root.openAllRequested()
      }
      PanelActionButton {
        id: newBtn
        iconText: "󰐕"
        tooltipText: "New task"
        foreground: root.fg
        fontFamily: root.fontFamily
        onClicked: root.newRequested()
      }
    }
  }

  Text {
    visible: root.tasks.length === 0
    textFormat: Text.PlainText
    text: root.dayKey === root.todayKey ? "Nothing due today" : "Nothing due"
    color: root.faintFg
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  Repeater {
    model: root.tasks.slice(0, root.maxRows)
    delegate: Item {
      id: row
      required property var modelData
      readonly property var task: modelData
      readonly property bool overdue: Tasks.dayOf(task.due) < root.todayKey
      readonly property bool editable: root.store ? root.store.taskEditable(task) : false
      width: root.width
      height: Math.max(box.implicitHeight, titleCol.implicitHeight) + Style.space(6)

      Text {
        id: box
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.topMargin: Style.space(1)
        width: Style.space(22)
        textFormat: Text.PlainText
        text: "󰄱"
        color: root.store ? root.store.listColor(row.task.listId) : Color.accent
        opacity: row.editable ? 1 : 0.5
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        MouseArea {
          anchors.fill: parent
          anchors.margins: -Style.space(4)
          enabled: row.editable
          cursorShape: Qt.PointingHandCursor
          onClicked: root.store.toggleComplete(row.task)
        }
      }
      Column {
        id: titleCol
        anchors.left: box.right
        anchors.right: parent.right
        anchors.top: parent.top
        Text {
          width: parent.width
          elide: Text.ElideRight
          textFormat: Text.PlainText
          text: row.task.title || "(untitled)"
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
        Text {
          width: parent.width
          elide: Text.ElideRight
          visible: text !== ""
          textFormat: Text.PlainText
          text: {
            var bits = []
            if (row.overdue || Tasks.hasTime(row.task.due)) bits.push(Tasks.dateLabel(row.task.due, root.todayKey, root.use24h))
            var p = Tasks.priorityName(row.task.priority)
            if (p) bits.push(p)
            if (root.store && root.store.lists.length > 1) bits.push(root.store.listName(row.task.listId))
            return bits.join("  ·  ")
          }
          color: row.overdue ? Color.urgent : root.dimFg
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
      MouseArea {
        anchors.fill: titleCol
        cursorShape: Qt.PointingHandCursor
        onClicked: root.openRequested(row.task.listId + "|" + row.task.uid)
      }
    }
  }

  Text {
    visible: root.tasks.length > root.maxRows
    textFormat: Text.PlainText
    text: "+ " + (root.tasks.length - root.maxRows) + " more"
    color: root.dimFg
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.openAllRequested() }
  }
}
