import QtQuick
import qs.Commons
import qs.Ui
import "Events.js" as Events

// Events hidden from synced calendars, with Unhide. Entries whose event has
// since gone from the source (cancelled, deleted) are marked and can be
// cleared in one go.
Column {
  id: root

  property var store: null
  property bool use24h: true
  property color fg: Color.foreground
  property string fontFamily: Style.font.family

  signal finished()
  signal picked(string key)

  readonly property var items: store ? store.hiddenView : []
  readonly property int goneCount: items.filter(function(i) { return !i.present }).length
  readonly property color dimFg: Qt.darker(fg, 1.5)
  readonly property color faintFg: Qt.darker(fg, 1.9)

  spacing: Style.space(8)
  Keys.onPressed: function(event) {
    if (event.key === Qt.Key_Escape) { root.finished(); event.accepted = true }
  }

  function whenText(e) {
    var d = Events.parseStamp(e.start)
    if (!d) return ""
    var date = Qt.formatDate(d, "ddd, MMM d, yyyy")
    if (e.series) return "All repeats (hidden from the " + Qt.formatDate(d, "MMM d") + " one)"
    if (e.allDay) return date + " · all day"
    return date + " · " + Events.timeLabel(e, Events.keyOf(d), root.use24h)
  }

  PanelSectionHeader {
    text: "HIDDEN EVENTS"
    foreground: root.fg
    fontFamily: root.fontFamily
  }

  Text {
    width: parent.width
    wrapMode: Text.Wrap
    textFormat: Text.PlainText
    text: root.items.length === 0
      ? "Nothing hidden. Open an event from a synced calendar and choose Hide."
      : "Hidden on this computer only. The shared calendars are unchanged."
    color: root.faintFg
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Repeater {
    model: root.items

    Rectangle {
      id: row
      required property var modelData
      readonly property var e: modelData.entry
      width: root.width
      height: rowCol.implicitHeight + Style.space(12)
      radius: Style.cornerRadius
      color: rowMouse.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : Util.alpha(root.fg, 0.04)

      MouseArea {
        id: rowMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        // Jump to the day it was on, so you can see what you'd be unhiding.
        onClicked: if (row.e.start) root.picked(String(row.e.start).substr(0, 10))
      }

      Rectangle {
        x: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(3)
        height: parent.height - Style.space(12)
        radius: width / 2
        color: root.store ? root.store.calendarColor(row.e.calendarId) : Color.accent
        opacity: row.modelData.present ? 1 : 0.4
      }

      Column {
        id: rowCol
        x: Style.space(18)
        width: parent.width - x - unhideBtn.width - Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        Text {
          width: parent.width
          elide: Text.ElideRight
          textFormat: Text.PlainText
          text: row.e.title || "(no title)"
          color: row.modelData.present ? root.fg : root.dimFg
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          font.strikeout: !row.modelData.present
        }
        Text {
          width: parent.width
          elide: Text.ElideRight
          textFormat: Text.PlainText
          text: root.whenText(row.e)
          color: root.dimFg
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
        Text {
          width: parent.width
          elide: Text.ElideRight
          textFormat: Text.PlainText
          text: row.modelData.calendarName + (row.modelData.present ? "" : " · no longer in the calendar")
          color: root.faintFg
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      Button {
        id: unhideBtn
        anchors.right: parent.right
        anchors.rightMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        text: "Unhide"
        iconText: "\uf06e"
        bordered: true
        foreground: root.fg
        fontFamily: root.fontFamily
        fontSize: Style.font.bodySmall
        onClicked: root.store.unhide(row.modelData.key)
      }
    }
  }

  Row {
    spacing: Style.space(8)
    Button {
      text: "Done"
      bordered: true
      selected: true
      foreground: root.fg
      fontFamily: root.fontFamily
      onClicked: root.finished()
    }
    Button {
      visible: root.goneCount > 0
      text: "Clear " + root.goneCount + " no longer in calendars"
      bordered: true
      foreground: root.fg
      fontFamily: root.fontFamily
      onClicked: root.store.clearGoneHidden()
    }
  }
}
