import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "Events.js" as Events

// Month grid shared by the popout (any size), the window's main view, and the
// window's mini sidebar month. Six rows always, so it never changes height.
//
// maxChips = 0 draws a colored dot per calendar under the date (small
// sizes); maxChips > 0 lists that many event titles per day and "+N more".
Item {
  id: root

  property var store: null
  property int year: new Date().getFullYear()
  property int month: new Date().getMonth()
  property int weekStart: 1
  property string selectedKey: ""
  property string todayKey: ""
  property bool use24h: true

  property real cellWidth: Style.space(48)
  property real cellHeight: Style.space(40)
  property real cellSpacing: Style.space(2)
  property bool showWeekNumbers: true
  property real weekColumnWidth: showWeekNumbers ? Style.space(28) : 0
  property real gutterWidth: showWeekNumbers ? Style.space(12) : 0
  property int maxChips: 0
  property real dayFontSize: Style.font.body

  property color fg: Color.foreground
  property string fontFamily: Style.font.family

  signal picked(string key)
  signal activated(string key)
  signal eventPicked(var ev)
  signal stepRequested(int delta)
  signal weekStartToggleRequested()
  signal eventMoved(var ev, var changed)

  // ---- Dragging an event to another day: the day under the pointer.
  property string dropKey: ""
  property var draggedEv: null
  function canDrag(ev) { return !!store && !!ev && store.eventEditable(ev) }
  function keyAt(item, x, y) {
    var p = item.mapToItem(gridColumn, x, y)
    var top = headerRow.height + gridColumn.spacing
    var row = Math.floor((p.y - top) / (root.cellHeight + gridColumn.spacing))
    var cellsX = root.showWeekNumbers ? root.weekColumnWidth + root.gutterWidth + 2 * root.cellSpacing : 0
    var col = Math.floor((p.x - cellsX) / (root.cellWidth + root.cellSpacing))
    if (row < 0 || row >= root.weeks.length || col < 0 || col > 6) return ""
    return root.weeks[row].days[col].key
  }
  // dragFrom: the day the drag started on (a bar's grabbed day).
  function finishDrag(ev, fromKey) {
    var to = root.dropKey
    root.dropKey = ""
    root.draggedEv = null
    if (!to || !fromKey || to === fromKey) return
    var days = Math.round((Events.parseStamp(to).getTime() - Events.parseStamp(fromKey).getTime()) / 86400000)
    if (days !== 0) root.eventMoved(ev, Events.movedByDays(ev, days))
  }

  readonly property var labelLocale: Qt.locale("en_US")
  readonly property var weekdays: Model.weekdayOrder(weekStart)
  readonly property var weeks: Model.monthGrid(year, month, weekStart, todayKey)
  readonly property var calendars: store ? store.calendars : []
  readonly property var dayIndex: store ? store.dayIndex : null
  readonly property string nextWeekStartLabel: labelLocale.dayName(Model.toggledWeekStart(weekStart), Locale.LongFormat)

  readonly property real headerHeight: Style.space(16)
  readonly property real chipHeight: Style.space(16)
  // Where chips and bars start inside a cell: under the date number.
  readonly property real chipTop: Style.space(4) + dayFontSize * 1.35 + Style.space(2)

  implicitWidth: gridColumn.implicitWidth
  implicitHeight: gridColumn.implicitHeight

  function calColor(id) { return store ? store.calendarColor(id) : Color.accent }

  // Off where the grid sits in something that scrolls (the year view).
  property bool wheelSteps: true

  WheelHandler {
    enabled: root.wheelSteps
    onWheel: function(event) {
      if (event.angleDelta.y === 0) return
      root.stepRequested(event.angleDelta.y > 0 ? -1 : 1)
    }
  }

  Column {
    id: gridColumn
    spacing: Style.space(2)

    Row {
      id: headerRow
      spacing: root.cellSpacing

      Rectangle {
        visible: root.showWeekNumbers
        width: root.weekColumnWidth
        height: root.headerHeight
        radius: Style.cornerRadius
        color: weekStartMouse.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"

        Text {
          anchors.centerIn: parent
          text: "W"
          color: weekStartMouse.containsMouse ? Style.hoverStateColor(root.fg, Color.accent) : Qt.darker(root.fg, 1.9)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        MouseArea {
          id: weekStartMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.weekStartToggleRequested()
        }

        PanelToolTip {
          visible: weekStartMouse.containsMouse
          text: "Start weeks on " + root.nextWeekStartLabel
          fontFamily: root.fontFamily
        }
      }

      Item { visible: root.showWeekNumbers; width: root.gutterWidth; height: 1 }

      Repeater {
        model: root.weekdays
        Text {
          required property var modelData
          textFormat: Text.PlainText
          width: root.cellWidth
          height: root.headerHeight
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
          text: String(root.labelLocale.dayName(modelData, Locale.ShortFormat)).toUpperCase()
          color: Qt.darker(root.fg, 1.5)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.letterSpacing: 1
          font.bold: true
        }
      }
    }

    Repeater {
      model: root.weeks

      Item {
        id: weekRow
        required property var modelData
        readonly property var keys: modelData.days.map(function(d) { return d.key })
        // Multi-day and all-day events as bars across the row (title mode only).
        readonly property var lane: root.maxChips > 0
          ? Events.layoutBars(keys.map(function(k) { return Events.eventsOn(root.dayIndex, k) }), keys, Events.isMultiDay)
          : ({ bars: [], rows: 0, perDay: [0, 0, 0, 0, 0, 0, 0] })
        readonly property int barRows: lane.rows <= root.maxChips ? lane.rows : Math.max(0, root.maxChips - 1)
        // Per day: bar rows actually drawn over it, so a day's chips start
        // right under its own bars rather than under the week's tallest.
        readonly property var rowsOver: {
          var out = [0, 0, 0, 0, 0, 0, 0]
          for (var i = 0; i < lane.bars.length; i++) {
            var b = lane.bars[i]
            if (b.row >= barRows) continue
            for (var d = b.first; d <= b.last; d++) out[d] = Math.max(out[d], b.row + 1)
          }
          return out
        }
        readonly property real cellsX: root.showWeekNumbers ? root.weekColumnWidth + root.gutterWidth + 2 * root.cellSpacing : 0
        function hiddenBarsOn(day) {
          var n = 0
          for (var i = 0; i < lane.bars.length; i++) {
            var b = lane.bars[i]
            if (b.row >= barRows && b.first <= day && b.last >= day) n++
          }
          return n
        }

        width: weekCells.width
        height: weekCells.height

        Row {
          id: weekCells
          spacing: root.cellSpacing

          Text {
            visible: root.showWeekNumbers
            textFormat: Text.PlainText
            width: root.weekColumnWidth
            height: root.cellHeight
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: root.maxChips > 0 ? Text.AlignTop : Text.AlignVCenter
            topPadding: root.maxChips > 0 ? Style.space(6) : 0
            text: weekRow.modelData.week
            color: Qt.darker(root.fg, 1.9)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Item { visible: root.showWeekNumbers; width: root.gutterWidth; height: root.cellHeight }

          Repeater {
            model: weekRow.modelData.days

            Rectangle {
              id: cell
              required property var modelData
              required property int index
              readonly property bool selected: modelData.key === root.selectedKey
              readonly property var onDay: Events.eventsOn(root.dayIndex, modelData.key)
              readonly property var dots: root.maxChips > 0 ? [] : Events.calendarMarkers(onDay, 3)
              // Single-day events; multi-day ones are bars over the row.
              readonly property var dayEvents: root.maxChips > 0 ? onDay.filter(function(e) { return !Events.isMultiDay(e) }) : []
              readonly property int hiddenBars: root.maxChips > 0 ? weekRow.hiddenBarsOn(index) : 0
              readonly property int slots: Math.max(0, root.maxChips - weekRow.rowsOver[index])
              readonly property int shownChips: dayEvents.length + hiddenBars > slots ? Math.max(0, slots - 1) : dayEvents.length
              readonly property int moreCount: dayEvents.length - shownChips + hiddenBars

              width: root.cellWidth
              height: root.cellHeight
              radius: Style.cornerRadius
              clip: true
              color: selected
                ? Style.selectedFillFor(root.fg, Color.accent)
                : (cellMouse.containsMouse ? Style.hoverFillFor(root.fg, Color.accent)
                   : (root.maxChips > 0 ? Util.alpha(root.fg, modelData.inMonth ? 0.03 : 0.0) : "transparent"))
              border.width: root.dropKey === modelData.key ? Math.max(1, Style.space(2)) : modelData.today ? Style.spacing.hairline : 0
              border.color: root.dropKey === modelData.key ? Color.accent : Style.normalBorderFor(root.fg, Color.accent)

              MouseArea {
                id: cellMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                // First click selects the day, a click on the selected day adds
                // an event on it (double-click does both at once).
                onClicked: {
                  if (cell.selected) root.activated(cell.modelData.key)
                  else root.picked(cell.modelData.key)
                }
              }

              Text {
                visible: cell.selected && cellMouse.containsMouse
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.rightMargin: Style.space(4)
                anchors.topMargin: Style.space(2)
                text: "+"
                color: Color.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }

              // Date number: centered for compact cells, top-left when listing titles.
              Text {
                id: dayNumber
                textFormat: Text.PlainText
                x: root.maxChips > 0 ? Style.space(6) : (parent.width - width) / 2
                y: root.maxChips > 0 ? Style.space(4)
                  : (parent.height - height) / 2 - (cell.dots.length > 0 ? Style.space(4) : 0)
                text: cell.modelData.day
                color: cell.selected
                  ? Style.selectedStateColor(root.fg, Color.accent)
                  : cell.modelData.inMonth
                    ? (cell.modelData.weekend ? Qt.darker(root.fg, 1.45) : root.fg)
                    : Qt.darker(root.fg, 2.2)
                font.family: root.fontFamily
                font.pixelSize: root.dayFontSize
                font.bold: cell.modelData.today || cell.selected
              }

              Row {
                visible: root.maxChips === 0
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                anchors.bottomMargin: Style.space(5)
                spacing: Style.space(3)
                opacity: cell.modelData.inMonth ? 1 : 0.45

                Repeater {
                  model: cell.dots
                  Rectangle {
                    required property var modelData
                    width: Style.space(5)
                    height: width
                    radius: width / 2
                    color: root.calColor(modelData)
                  }
                }
              }

              Column {
                visible: root.maxChips > 0
                x: Style.space(3)
                y: root.chipTop + weekRow.rowsOver[cell.index] * (root.chipHeight + Style.space(1))
                width: parent.width - Style.space(6)
                spacing: Style.space(1)
                opacity: cell.modelData.inMonth ? 1 : 0.55

                Repeater {
                  model: cell.dayEvents.slice(0, cell.shownChips)

                  Rectangle {
                    id: chip
                    required property var modelData
                    readonly property color tint: root.calColor(modelData.calendarId)
                    width: parent.width
                    height: root.chipHeight
                    radius: Math.min(Style.cornerRadius, Style.space(3))
                    color: chipMouse.containsMouse ? Util.alpha(tint, 0.18) : "transparent"
                    opacity: root.draggedEv === modelData ? 0.4 : 1

                    Rectangle {
                      x: Style.space(2)
                      anchors.verticalCenter: parent.verticalCenter
                      width: Style.space(5)
                      height: width
                      radius: width / 2
                      color: chip.tint
                    }

                    Text {
                      x: Style.space(10)
                      width: parent.width - x - Style.space(2)
                      anchors.verticalCenter: parent.verticalCenter
                      elide: Text.ElideRight
                      textFormat: Text.PlainText
                      text: Events.shortTime(chip.modelData.start, root.use24h) + " " + chip.modelData.title
                      color: root.fg
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }

                    MouseArea {
                      id: chipMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      preventStealing: true
                      cursorShape: Qt.PointingHandCursor
                      property point pressAt: Qt.point(0, 0)
                      property bool moving: false
                      onPressed: function(mouse) { pressAt = Qt.point(mouse.x, mouse.y); moving = false }
                      onPositionChanged: function(mouse) {
                        if (!pressed || !root.canDrag(chip.modelData)) return
                        if (!moving && Math.abs(mouse.x - pressAt.x) + Math.abs(mouse.y - pressAt.y) < Style.space(6)) return
                        moving = true
                        root.draggedEv = chip.modelData
                        root.dropKey = root.keyAt(chipMouse, mouse.x, mouse.y)
                      }
                      onReleased: {
                        if (!moving) { root.eventPicked(chip.modelData); return }
                        moving = false
                        root.finishDrag(chip.modelData, cell.modelData.key)
                      }
                      onCanceled: { moving = false; root.dropKey = ""; root.draggedEv = null }
                    }
                  }
                }

                Text {
                  visible: cell.moreCount > 0
                  x: Style.space(4)
                  textFormat: Text.PlainText
                  text: "+" + cell.moreCount + " more"
                  color: Qt.darker(root.fg, 1.5)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.picked(cell.modelData.key)
                  }
                }
              }
            }
          }
        }

        // Bars for multi-day events, over the cells they cover.
        Repeater {
          model: weekRow.lane.bars.filter(function(b) { return b.row < weekRow.barRows })

          Rectangle {
            id: bar
            required property var modelData
            readonly property color tint: root.calColor(modelData.ev.calendarId)
            readonly property bool inMonth: weekRow.modelData.days[modelData.first].inMonth || weekRow.modelData.days[modelData.last].inMonth
            x: weekRow.cellsX + modelData.first * (root.cellWidth + root.cellSpacing) + (modelData.cutStart ? 0 : Style.space(3))
            y: root.chipTop + modelData.row * (root.chipHeight + Style.space(1))
            width: (modelData.last - modelData.first + 1) * (root.cellWidth + root.cellSpacing) - root.cellSpacing
              - (modelData.cutStart ? 0 : Style.space(3)) - (modelData.cutEnd ? 0 : Style.space(3))
            height: root.chipHeight
            radius: Math.min(Style.cornerRadius, Style.space(3))
            color: Util.alpha(tint, barMouse.containsMouse ? 0.45 : 0.3)
            opacity: root.draggedEv === modelData.ev ? 0.4 : inMonth ? 1 : 0.55

            Text {
              x: Style.space(4)
              width: parent.width - Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: (bar.modelData.cutStart ? "‹ " : "")
                + (bar.modelData.ev.allDay || bar.modelData.cutStart ? "" : Events.shortTime(bar.modelData.ev.start, root.use24h) + " ")
                + bar.modelData.ev.title
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            MouseArea {
              id: barMouse
              anchors.fill: parent
              hoverEnabled: true
              preventStealing: true
              cursorShape: Qt.PointingHandCursor
              property point pressAt: Qt.point(0, 0)
              property string grabbedKey: ""
              property bool moving: false
              onPressed: function(mouse) {
                pressAt = Qt.point(mouse.x, mouse.y); moving = false
                grabbedKey = root.keyAt(barMouse, mouse.x, mouse.y)
              }
              onPositionChanged: function(mouse) {
                if (!pressed || !root.canDrag(bar.modelData.ev)) return
                if (!moving && Math.abs(mouse.x - pressAt.x) + Math.abs(mouse.y - pressAt.y) < Style.space(6)) return
                moving = true
                root.draggedEv = bar.modelData.ev
                root.dropKey = root.keyAt(barMouse, mouse.x, mouse.y)
              }
              onReleased: {
                if (!moving) { root.eventPicked(bar.modelData.ev); return }
                moving = false
                root.finishDrag(bar.modelData.ev, grabbedKey)
              }
              onCanceled: { moving = false; root.dropKey = ""; root.draggedEv = null }
            }
          }
        }
      }
    }
  }

  // Hairline down the week-number gutter, beside the day rows only.
  Rectangle {
    visible: root.showWeekNumbers
    x: root.weekColumnWidth + root.cellSpacing + Math.round((root.gutterWidth - width) / 2)
    y: headerRow.height + gridColumn.spacing
    width: Style.spacing.hairline
    height: gridColumn.height - headerRow.height - gridColumn.spacing
    color: root.fg
    opacity: 0.1
  }
}
