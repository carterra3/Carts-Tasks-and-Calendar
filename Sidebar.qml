import QtQuick
import qs.Commons
import qs.Ui
import "Tasks.js" as Tasks

// Smart lists (Today, Scheduled, All, Important, Completed) with counts,
// then LISTS: one row per list (click to open, pencil to edit, eye to
// show/hide it in the smart lists).
Column {
  id: root

  property var store: null
  property string view: "today"          // a smart list name, or "list"
  property string listId: ""
  property string projectKey: ""
  property color fg: Color.foreground
  property string fontFamily: Style.font.family

  signal smartPicked(string name)
  signal listPicked(string id)
  signal projectPicked(string key)
  signal newProjectRequested()
  signal addRequested()
  signal editRequested(var list)

  readonly property color faintFg: Qt.darker(fg, 1.9)
  readonly property var icons: ({ today: "󰃶", scheduled: "󰃭", all: "󰄬", important: "󰈻", completed: "󰄲" })

  spacing: Style.space(2)

  component Row_: Rectangle {
    id: row
    property bool selected: false
    property string icon: ""
    property color iconColor: root.fg
    property string label: ""
    property string count: ""
    property bool urgentCount: false
    property bool dim: false
    signal clicked()
    width: root.width
    height: Style.space(30)
    radius: Style.cornerRadius
    color: selected ? Util.alpha(Color.accent, 0.18) : mouse.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"

    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: row.clicked()
    }
  }

  Repeater {
    model: Tasks.SMART

    Row_ {
      id: smartRow
      required property string modelData
      required property int index
      selected: root.view === modelData
      label: Tasks.SMART_LABELS[modelData]
      onClicked: root.smartPicked(modelData)

      Text {
        id: smartIcon
        x: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(18)
        text: root.icons[smartRow.modelData]
        color: smartRow.modelData === "important" ? Color.urgent : smartRow.modelData === "today" ? Color.accent : Qt.darker(root.fg, 1.3)
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }
      Text {
        anchors.left: smartIcon.right
        anchors.leftMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: smartRow.label
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: smartRow.selected
      }
      Text {
        anchors.right: parent.right
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        readonly property int n: root.store ? root.store.counts[smartRow.modelData] : 0
        readonly property int overdue: root.store && smartRow.modelData === "today" ? root.store.counts.overdue : 0
        visible: n > 0 && smartRow.modelData !== "completed"
        textFormat: Text.PlainText
        text: String(n)
        color: overdue > 0 ? Color.urgent : root.faintFg
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: overdue > 0
      }
    }
  }

  Item { width: 1; height: Style.space(10) }

  // ---- projects: open top-level tasks with subtasks (or marked as one)
  Item {
    width: parent.width
    height: addProjectBtn.height

    PanelSectionHeader {
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: "PROJECTS"
      foreground: root.fg
      fontFamily: root.fontFamily
    }
    PanelActionButton {
      id: addProjectBtn
      anchors.right: parent.right
      anchors.rightMargin: -Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      iconText: "󰐕"
      tooltipText: "New project"
      foreground: root.fg
      fontFamily: root.fontFamily
      enabled: root.store && root.store.writableLists.length > 0
      onClicked: root.newProjectRequested()
    }
  }

  Text {
    visible: root.store && root.store.projects.length === 0
    width: parent.width
    wrapMode: Text.Wrap
    textFormat: Text.PlainText
    text: "A task with subtasks shows up here. Tab makes a task a subtask of the one above."
    color: root.faintFg
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Repeater {
    model: root.store ? root.store.projects : []

    Row_ {
      id: projRow
      required property var modelData
      readonly property real progress: modelData.total ? modelData.done / modelData.total : 0
      selected: root.view === "project" && root.projectKey === modelData.key
      onClicked: root.projectPicked(modelData.key)

      // Progress ring: a pie in the list's color.
      Canvas {
        id: ring
        x: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(16)
        height: width
        readonly property color c: root.store ? root.store.listColor(projRow.modelData.task.listId) : Color.accent
        readonly property real p: projRow.progress
        onCChanged: requestPaint()
        onPChanged: requestPaint()
        onPaint: {
          var ctx = getContext("2d")
          ctx.reset()
          var r = width / 2
          ctx.lineWidth = Math.max(1.5, width / 9)
          ctx.strokeStyle = c
          ctx.beginPath(); ctx.arc(r, r, r - ctx.lineWidth / 2, 0, 2 * Math.PI); ctx.stroke()
          if (p > 0) {
            ctx.fillStyle = c
            ctx.beginPath(); ctx.moveTo(r, r)
            ctx.arc(r, r, r - ctx.lineWidth * 1.6, -Math.PI / 2, -Math.PI / 2 + 2 * Math.PI * p)
            ctx.closePath(); ctx.fill()
          }
        }
      }
      Text {
        anchors.left: ring.right
        anchors.leftMargin: Style.space(10)
        anchors.right: projCount.left
        anchors.rightMargin: Style.space(4)
        anchors.verticalCenter: parent.verticalCenter
        elide: Text.ElideRight
        textFormat: Text.PlainText
        text: projRow.modelData.task.title
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: projRow.selected
      }
      Text {
        id: projCount
        anchors.right: parent.right
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: projRow.modelData.total ? projRow.modelData.done + "/" + projRow.modelData.total : ""
        color: root.faintFg
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }
  }

  Item { width: 1; height: Style.space(10) }

  Item {
    width: parent.width
    height: addBtn.height

    PanelSectionHeader {
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: "LISTS"
      foreground: root.fg
      fontFamily: root.fontFamily
    }
    PanelActionButton {
      id: addBtn
      anchors.right: parent.right
      anchors.rightMargin: -Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      iconText: "󰐕"
      tooltipText: "Add a list or connect an account"
      foreground: root.fg
      fontFamily: root.fontFamily
      enabled: root.store && root.store.writable
      onClicked: root.addRequested()
    }
  }

  Repeater {
    model: root.store ? root.store.lists : []

    Row_ {
      id: listRow
      required property var modelData
      readonly property bool shown: modelData.visible !== false
      readonly property var status: root.store ? root.store.syncStatus(modelData.id) : null
      readonly property bool failed: !!(status && status.error)
      readonly property bool remote: !!(modelData.source && modelData.source.type === "caldav")
      selected: root.view === "list" && root.listId === modelData.id
      onClicked: root.listPicked(modelData.id)

      Swatch {
        id: listSwatch
        x: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        swatch: root.store ? root.store.colorFor(listRow.modelData.color) : Color.accent
        filled: listRow.shown
      }
      Text {
        anchors.left: listSwatch.right
        anchors.leftMargin: Style.space(12)
        anchors.right: listTail.left
        anchors.rightMargin: Style.space(4)
        anchors.verticalCenter: parent.verticalCenter
        elide: Text.ElideRight
        textFormat: Text.PlainText
        text: listRow.modelData.name
        color: listRow.shown ? root.fg : root.faintFg
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: listRow.selected
      }
      Row {
        id: listTail
        anchors.right: parent.right
        anchors.rightMargin: Style.space(2)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        Text {
          id: badge
          anchors.verticalCenter: parent.verticalCenter
          visible: listRow.failed || listRow.remote
          text: listRow.failed ? "\uf071" : "󰅟"
          color: listRow.failed ? Color.urgent : root.faintFg
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          MouseArea { id: badgeMouse; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
          PanelToolTip {
            visible: badgeMouse.containsMouse
            text: root.store ? root.store.sourceLabel(listRow.modelData.id) + "\n" + root.store.syncLine(listRow.modelData.id) : ""
            fontFamily: root.fontFamily
          }
        }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(26)
          horizontalAlignment: Text.AlignRight
          readonly property int n: root.store && root.store.counts.lists[listRow.modelData.id] !== undefined ? root.store.counts.lists[listRow.modelData.id] : 0
          visible: !listMouseHover.hovered
          textFormat: Text.PlainText
          text: n > 0 ? String(n) : ""
          color: root.faintFg
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
        PanelActionButton {
          visible: listMouseHover.hovered
          iconText: listRow.shown ? "\uf06e" : "\uf070"
          tooltipText: listRow.shown ? "Shown in Today/Scheduled/All (click to hide)" : "Hidden from Today/Scheduled/All (click to show)"
          foreground: root.fg
          fontFamily: root.fontFamily
          fontSize: Style.font.bodySmall
          onClicked: root.store.toggleList(listRow.modelData.id)
        }
        PanelActionButton {
          visible: listMouseHover.hovered
          iconText: "󰏫"
          tooltipText: "Edit list"
          foreground: root.fg
          fontFamily: root.fontFamily
          fontSize: Style.font.bodySmall
          enabled: root.store && root.store.writable
          onClicked: root.editRequested(listRow.modelData)
        }
      }
      // Hover for the whole row without stealing its clicks.
      HoverHandler { id: listMouseHover }
    }
  }
}
