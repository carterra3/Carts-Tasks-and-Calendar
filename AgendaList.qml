import QtQuick
import qs.Commons
import qs.Ui
import "Events.js" as Events

// Event list: one day (the popout's side pane) or the next N days grouped
// by date (the Agenda view). Sizes to its content; callers scroll it.
Column {
  id: root

  property var store: null
  property string fromKey: ""
  property int days: 1
  property bool showHeaders: days > 1
  property string todayKey: ""
  property bool use24h: true
  property string emptyText: days > 1 ? "Nothing in the next " + days + " days" : "Nothing scheduled"
  property color fg: Color.foreground
  property string fontFamily: Style.font.family

  signal eventPicked(var ev)
  signal picked(string key)

  readonly property var groups: Events.agendaFrom(store ? store.dayIndex : null, fromKey, days)

  spacing: Style.space(6)

  function calColor(id) { return store ? store.calendarColor(id) : Color.accent }

  Text {
    visible: root.groups.length === 0
    textFormat: Text.PlainText
    text: root.emptyText
    color: Qt.darker(root.fg, 1.9)
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    topPadding: Style.space(4)
    bottomPadding: Style.space(4)
  }

  Repeater {
    model: root.groups

    Column {
      id: group
      required property var modelData
      width: root.width
      spacing: Style.space(4)

      Item {
        visible: root.showHeaders
        width: parent.width
        height: visible ? groupTitle.implicitHeight + Style.space(4) : 0

        Text {
          id: groupTitle
          y: Style.space(4)
          textFormat: Text.PlainText
          text: Qt.formatDate(Events.parseStamp(group.modelData.key), "dddd, MMMM d")
            + (group.modelData.key === root.todayKey ? "  ·  today"
               : group.modelData.key === Events.addDaysKey(root.todayKey, 1) ? "  ·  tomorrow" : "")
          color: group.modelData.key === root.todayKey ? Color.accent : Qt.darker(root.fg, 1.3)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.picked(group.modelData.key)
          }
        }
      }

      Repeater {
        model: group.modelData.events

        Rectangle {
          id: evRow
          required property var modelData
          width: group.width
          height: evCol.implicitHeight + Style.space(12)
          radius: Style.cornerRadius
          color: evMouse.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : Util.alpha(root.fg, 0.04)

          Rectangle {
            x: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(3)
            height: parent.height - Style.space(12)
            radius: width / 2
            color: root.calColor(evRow.modelData.calendarId)
          }

          Column {
            id: evCol
            x: Style.space(18)
            width: parent.width - x - Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(1)

            Text {
              width: parent.width
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: Events.timeLabel(evRow.modelData, group.modelData.key, root.use24h)
                + (evRow.modelData.recurring ? "  ↻" : "")
              color: Qt.darker(root.fg, 1.5)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            Text {
              width: parent.width
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: evRow.modelData.title
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }
            Text {
              visible: text !== ""
              width: parent.width
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: evRow.modelData.location || ""
              color: Qt.darker(root.fg, 1.5)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          MouseArea {
            id: evMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.eventPicked(evRow.modelData)
          }
        }
      }
    }
  }
}
