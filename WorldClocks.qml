import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Events.js" as Events
import "Tz.js" as Tz

// "TIME ZONES": world clocks for the zones the user added. The clock icon
// on a row shows that zone as a second hour column in week/day views.
Column {
  id: root

  property var store: null
  property bool use24h: true
  property color fg: Color.foreground
  property string fontFamily: Style.font.family

  readonly property color faintFg: Qt.darker(fg, 1.9)
  property bool adding: false
  property real now: Date.now()

  spacing: Style.space(4)

  SystemClock {
    precision: SystemClock.Minutes
    onDateChanged: root.now = date.getTime()
  }

  function rowInfo(zone) {
    var table = root.store ? root.store.zoneTable(zone) : null
    if (!table) return { time: "…", note: "" }
    var wall = new Date(Tz.utcToWall(table, root.now))
    var local = new Date(root.now)
    var localWall = Date.UTC(local.getFullYear(), local.getMonth(), local.getDate(), local.getHours(), local.getMinutes())
    var diffMin = Math.round((wall.getTime() - localWall) / 60000)
    var dayDiff = Math.round((Date.UTC(wall.getUTCFullYear(), wall.getUTCMonth(), wall.getUTCDate())
      - Date.UTC(local.getFullYear(), local.getMonth(), local.getDate())) / 86400000)
    var h = diffMin / 60
    var diff = diffMin === 0 ? "same time" : (diffMin > 0 ? "+" : "−") + (Math.abs(h) % 1 === 0 ? Math.abs(h) : Math.abs(h).toFixed(1)) + "h"
    return {
      time: Events.formatTime(wall.getUTCHours(), wall.getUTCMinutes(), root.use24h),
      note: (dayDiff > 0 ? "tomorrow · " : dayDiff < 0 ? "yesterday · " : "") + diff
    }
  }

  Item {
    width: parent.width
    height: addZone.height

    PanelSectionHeader {
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: "TIME ZONES"
      foreground: root.fg
      fontFamily: root.fontFamily
    }

    PanelActionButton {
      id: addZone
      anchors.right: parent.right
      anchors.rightMargin: -Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      iconText: root.adding ? "󰅖" : "󰐕"
      tooltipText: root.adding ? "Cancel" : "Add a time zone"
      foreground: root.fg
      fontFamily: root.fontFamily
      enabled: root.store && root.store.writable
      onClicked: {
        root.adding = !root.adding
        if (root.adding && root.store) root.store.loadZoneList()
      }
    }
  }

  SearchableDropdown {
    visible: root.adding
    width: parent.width
    showLabel: false
    value: ""
    placeholderText: "Search time zones…"
    options: root.store ? root.store.zoneOptions : []
    foreground: root.fg
    fontFamily: root.fontFamily
    onChanged: function(v) {
      if (v && root.store) root.store.addClockZone(v)
      root.adding = false
    }
  }

  Repeater {
    model: root.store ? root.store.clockZones : []

    Rectangle {
      id: zoneRow
      required property var modelData
      readonly property var info: { root.now; root.store.zoneTables; return root.rowInfo(modelData) }
      readonly property bool inGrid: root.store && root.store.secondZone === modelData
      width: root.width
      height: Style.space(34)
      radius: Style.cornerRadius
      color: rowMouse.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"

      MouseArea {
        id: rowMouse
        anchors.fill: parent
        hoverEnabled: true
      }

      Column {
        x: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - x - actions.width
        Text {
          width: parent.width
          elide: Text.ElideRight
          textFormat: Text.PlainText
          text: Tz.cityName(zoneRow.modelData)
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
        Text {
          width: parent.width
          elide: Text.ElideRight
          textFormat: Text.PlainText
          text: zoneRow.info.note
          color: root.faintFg
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      Row {
        id: actions
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        Text {
          anchors.verticalCenter: parent.verticalCenter
          rightPadding: Style.space(4)
          textFormat: Text.PlainText
          text: zoneRow.info.time
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }
        PanelActionButton {
          anchors.verticalCenter: parent.verticalCenter
          iconText: "\uf017"
          tooltipText: zoneRow.inGrid ? "Hide from week and day views" : "Show hours in week and day views"
          foreground: zoneRow.inGrid ? Color.accent : root.faintFg
          fontFamily: root.fontFamily
          onClicked: root.store.setPref("secondZone", zoneRow.inGrid ? "" : zoneRow.modelData)
        }
        PanelActionButton {
          anchors.verticalCenter: parent.verticalCenter
          iconText: "󰅖"
          tooltipText: "Remove"
          foreground: root.faintFg
          fontFamily: root.fontFamily
          onClicked: root.store.removeClockZone(zoneRow.modelData)
        }
      }
    }
  }
}
