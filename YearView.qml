import QtQuick
import qs.Commons
import "Events.js" as Events

// Twelve months of the cursor's year, each a small month grid with a dot
// per calendar on days that have events. Click a day to select it, click it
// again (or double-click) to open it in Day view.
Item {
  id: root

  property var store: null
  property string cursorKey: ""
  property string todayKey: ""
  property int weekStart: 1
  property bool use24h: true
  property color fg: Color.foreground
  property string fontFamily: Style.font.family

  signal picked(string key)
  signal activated(string key)
  signal monthActivated(string key)
  signal stepRequested(int delta)

  readonly property int year: (Events.parseStamp(cursorKey) || new Date()).getFullYear()
  readonly property int columns: width >= Style.space(1100) ? 4 : width >= Style.space(760) ? 3 : 2
  readonly property real gap: Style.space(22)
  readonly property real monthWidth: (width - (columns - 1) * gap) / columns
  readonly property real cellWidth: Math.max(Style.space(16), (monthWidth - 6 * Style.space(2)) / 7)
  readonly property real cellHeight: Math.max(Style.space(20), Math.min(cellWidth * 0.9, Style.space(34)))

  WheelHandler {
    onWheel: function(event) {
      if (event.angleDelta.y === 0) return
      if (flick.contentHeight > flick.height + 1) return   // let it scroll first
      root.stepRequested(event.angleDelta.y > 0 ? -1 : 1)
    }
  }

  Flickable {
    id: flick
    anchors.fill: parent
    contentWidth: width
    contentHeight: grid.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    Grid {
      id: grid
      width: flick.width
      columns: root.columns
      columnSpacing: root.gap
      rowSpacing: Style.space(18)

      Repeater {
        model: 12

        Column {
          id: monthCol
          required property int index
          width: root.monthWidth
          spacing: Style.space(4)

          Text {
            textFormat: Text.PlainText
            text: Events.MONTHS ? Events.MONTHS[monthCol.index] : ""
            color: root.year === new Date().getFullYear() && monthCol.index === new Date().getMonth() ? Color.accent : root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.monthActivated(Events.dateKey(root.year, monthCol.index, 1))
            }
          }

          MonthGrid {
            store: root.store
            year: root.year
            month: monthCol.index
            weekStart: root.weekStart
            selectedKey: root.cursorKey
            todayKey: root.todayKey
            use24h: root.use24h
            showWeekNumbers: false
            wheelSteps: false
            cellWidth: root.cellWidth
            cellHeight: root.cellHeight
            dayFontSize: Style.font.bodySmall
            fg: root.fg
            fontFamily: root.fontFamily
            onPicked: function(key) { root.picked(key) }
            onActivated: function(key) { root.activated(key) }
          }
        }
      }
    }
  }
}
