import QtQuick
import qs.Commons
import qs.Ui

// "CALENDARS" header (sync + add) and one row per calendar: click to
// show/hide, pencil to edit, badge for where it syncs from.
Column {
  id: root

  property var store: null
  property color fg: Color.foreground
  property string fontFamily: Style.font.family
  property bool showHint: true

  signal addRequested()
  signal editRequested(var cal)
  signal hiddenRequested()

  readonly property color faintFg: Qt.darker(fg, 1.9)

  spacing: Style.space(4)

  Item {
    width: parent.width
    height: addBtn.height

    PanelSectionHeader {
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: "CALENDARS"
      foreground: root.fg
      fontFamily: root.fontFamily
    }

    Row {
      anchors.right: parent.right
      anchors.rightMargin: -Style.space(6)
      anchors.verticalCenter: parent.verticalCenter

      PanelActionButton {
        visible: root.store && root.store.hasRemote
        iconText: "󰑐"
        tooltipText: root.store && root.store.syncing ? "Syncing…" : "Sync now"
        foreground: root.store && root.store.syncing ? root.faintFg : root.fg
        fontFamily: root.fontFamily
        enabled: root.store && !root.store.syncing
        onClicked: root.store.syncAll()
      }

      PanelActionButton {
        id: addBtn
        iconText: "󰐕"
        tooltipText: "Add calendar, link, or account"
        foreground: root.fg
        fontFamily: root.fontFamily
        enabled: root.store && root.store.writable
        onClicked: root.addRequested()
      }
    }
  }

  Repeater {
    model: root.store ? root.store.calendars : []

    Rectangle {
      id: calRow
      required property var modelData
      readonly property bool shown: modelData.visible !== false
      readonly property var status: root.store ? root.store.syncStatus(modelData.id) : null
      readonly property bool failed: !!(status && status.error)
      readonly property string type: root.store ? root.store.sourceType(modelData.id) : "local"
      width: root.width
      height: Style.space(28)
      radius: Style.cornerRadius
      color: calMouse.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"

      MouseArea {
        id: calMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: if (root.store) root.store.toggleCalendar(calRow.modelData.id)
      }

      Swatch {
        id: calSwatch
        x: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        swatch: root.store ? root.store.colorFor(calRow.modelData.color) : Color.accent
        filled: calRow.shown
      }

      Text {
        anchors.left: calSwatch.right
        anchors.leftMargin: Style.space(10)
        anchors.right: calBadge.left
        anchors.rightMargin: Style.space(4)
        anchors.verticalCenter: parent.verticalCenter
        elide: Text.ElideRight
        textFormat: Text.PlainText
        text: calRow.modelData.name
        color: calRow.shown ? root.fg : root.faintFg
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.strikeout: !calRow.shown
      }

      Text {
        id: calBadge
        anchors.right: calEdit.left
        anchors.verticalCenter: parent.verticalCenter
        text: calRow.failed ? "\uf071" : calRow.type === "caldav" ? "󰅟" : calRow.type === "ics" ? "󰌷" : ""
        color: calRow.failed ? Color.urgent : root.faintFg
        font.family: root.fontFamily
        font.pixelSize: Style.font.body

        MouseArea {
          id: badgeMouse
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.NoButton
        }

        PanelToolTip {
          visible: badgeMouse.containsMouse && parent.text !== ""
          text: root.store ? root.store.sourceLabel(calRow.modelData.id) + "\n" + root.store.syncLine(calRow.modelData.id) : ""
          fontFamily: root.fontFamily
        }
      }

      PanelActionButton {
        id: calEdit
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        opacity: calMouse.containsMouse ? 1 : 0.35
        iconText: "󰏫"
        tooltipText: "Edit calendar"
        foreground: root.fg
        fontFamily: root.fontFamily
        fontSize: Style.font.body
        enabled: root.store && root.store.writable
        onClicked: root.editRequested(calRow.modelData)
      }
    }
  }

  // Way into the hidden-events list; only once something is hidden.
  Rectangle {
    visible: root.store && root.store.hidden.length > 0
    width: root.width
    height: visible ? Style.space(28) : 0
    radius: Style.cornerRadius
    color: hiddenMouse.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"

    Text {
      x: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: "\uf070  Hidden events (" + (root.store ? root.store.hidden.length : 0) + ")"
      color: Qt.darker(root.fg, 1.4)
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    MouseArea {
      id: hiddenMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.hiddenRequested()
    }
  }

  Text {
    visible: root.showHint
    width: parent.width
    wrapMode: Text.Wrap
    textFormat: Text.PlainText
    text: "Click a calendar to show/hide it"
    color: root.faintFg
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
}
