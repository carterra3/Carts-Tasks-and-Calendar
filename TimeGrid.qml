import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Events.js" as Events
import "Tz.js" as Tz

// Week/day time grid: day headers, an all-day lane, and a scrolling 24-hour
// grid with events laid out side by side where they overlap. `days` = 7 for
// a week, 1 for a single day (or anything in between).
Item {
  id: root

  property var store: null
  property string startKey: ""
  property int days: 7
  property string selectedKey: ""
  property string todayKey: ""
  property bool use24h: true
  property real hourHeight: Style.space(40)
  property real visibleHours: 10            // drives implicitHeight only
  // A second zone's hours down the left edge of the gutter (world-clock
  // style), from the store's secondZone pref.
  readonly property string secondZone: store ? store.secondZone : ""
  readonly property var secondTable: store && secondZone ? store.zoneTable(secondZone) : null
  readonly property real secondGutter: secondTable ? Style.space(46) : 0
  property real gutterWidth: Style.space(52) + secondGutter

  // Label for local hour h (on the first shown day) in the second zone.
  function secondLabel(h) {
    var d = Events.parseStamp(root.startKey)
    if (!d || !root.secondTable) return ""
    var wall = new Date(Tz.utcToWall(root.secondTable, new Date(d.getFullYear(), d.getMonth(), d.getDate(), h).getTime()))
    var hh = wall.getUTCHours(), mm = wall.getUTCMinutes()
    if (mm !== 0) return Events.formatTime(hh, mm, root.use24h).replace(" AM", "a").replace(" PM", "p")
    return Events.hourLabel(hh, root.use24h)
  }
  property color fg: Color.foreground
  property string fontFamily: Style.font.family

  signal picked(string key)
  signal eventPicked(var ev)
  signal slotActivated(string key, int minutes)
  // Drag results: an event moved/resized (the changed record), or a time
  // range dragged out on empty space.
  signal eventMoved(var ev, var changed)
  signal rangeSelected(string key, int startMinutes, int endMinutes)

  // ---- Dragging. One drag at a time:
  //   { mode: "move" | "resize" | "create", ev, col, startMin, endMin }
  // ("move" also carries dayDelta/minuteDelta against where it started).
  property var dragInfo: null
  readonly property int snapMinutes: 15
  function canDrag(ev) { return !!store && !!ev && store.eventEditable(ev) }
  function snap(m) { return Math.round(m / snapMinutes) * snapMinutes }
  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
  function colAt(x) { return clamp(Math.floor((x - gutterWidth) / columnWidth), 0, days - 1) }

  function commitDrag() {
    var d = root.dragInfo
    root.dragInfo = null
    if (!d) return
    if (d.mode === "create") {
      root.rangeSelected(root.dayKeys[d.col], d.startMin, Math.max(d.startMin + snapMinutes, d.endMin))
      return
    }
    var ev = d.ev
    if (d.mode === "resize") {
      var day = Events.parseStamp(root.dayKeys[d.col])
      var end = new Date(day.getFullYear(), day.getMonth(), day.getDate(), Math.floor(d.endMin / 60), d.endMin % 60)
      var stamp = Events.stampOf(end, false)
      if (stamp !== ev.end) root.eventMoved(ev, Events.resized(ev, stamp))
      return
    }
    if (d.dayDelta === 0 && d.minuteDelta === 0) return
    var s = Events.parseStamp(ev.start)
    var ns = new Date(s.getFullYear(), s.getMonth(), s.getDate() + d.dayDelta, s.getHours(), s.getMinutes() + d.minuteDelta)
    root.eventMoved(ev, Events.moved(ev, Events.stampOf(ns, false)))
  }

  readonly property var calendars: store ? store.calendars : []
  readonly property var dayIndex: store ? store.dayIndex : null
  readonly property var dayKeys: {
    var out = []
    for (var i = 0; i < days; i++) out.push(Events.addDaysKey(startKey, i))
    return out
  }
  readonly property real columnWidth: Math.max(Style.space(30), (width - gutterWidth) / Math.max(1, days))
  readonly property var dayLists: dayKeys.map(function(k) { return Events.eventsOn(root.dayIndex, k) })
  // All-day events and anything a day or longer: bars across the lane.
  readonly property var lane: Events.layoutBars(dayLists, dayKeys, Events.isLaneEvent)
  // One layout per shown day, shared by the columns and scrollToStart.
  readonly property var dayLayouts: dayKeys.map(function(k, i) { return Events.layoutList(root.dayLists[i], k) })
  property bool laneExpanded: false
  readonly property int laneMaxRows: 3
  // Rows of bars drawn; with more than fit, the last row says "+N more".
  readonly property int laneBarRows: laneExpanded || lane.rows <= laneMaxRows ? lane.rows : laneMaxRows - 1
  readonly property int allDayRows: laneBarRows + (laneBarRows < lane.rows ? 1 : 0)
  function hiddenOn(day) {
    var n = 0
    for (var i = 0; i < lane.bars.length; i++) {
      var b = lane.bars[i]
      if (b.row >= root.laneBarRows && b.first <= day && b.last >= day) n++
    }
    return n
  }
  readonly property real allDayRowHeight: Style.space(18)
  readonly property real headerHeight: Style.space(days === 1 ? 26 : 38)

  // Minute of day, refreshed every minute, for the "now" line.
  property int nowMinute: new Date().getHours() * 60 + new Date().getMinutes()

  implicitWidth: gutterWidth + days * Style.space(90)
  implicitHeight: headerHeight + allDayLane.height + Style.space(4) + visibleHours * hourHeight

  function calColor(id) { return store ? store.calendarColor(id) : Color.accent }

  // Land the view on the working day: an hour before now if today is shown,
  // otherwise just before the first event of the range, otherwise 8:00.
  function scrollToStart() {
    var minute = 8 * 60
    if (root.dayKeys.indexOf(root.todayKey) !== -1) minute = Math.max(0, root.nowMinute - 60)
    else {
      var first = 24 * 60
      for (var i = 0; i < root.dayKeys.length; i++) {
        var lay = root.dayLayouts[i] || []
        for (var j = 0; j < lay.length; j++) first = Math.min(first, lay[j].start)
      }
      if (first < 24 * 60) minute = Math.max(0, first - 30)
    }
    flick.contentY = Math.max(0, Math.min(flick.contentHeight - flick.height, minute / 60 * root.hourHeight))
  }

  // Re-aim when the range changes, and when the size settles (a tile's
  // final size arrives after creation) unless the user has scrolled since.
  property bool userScrolled: false
  onStartKeyChanged: { userScrolled = false; laneExpanded = false; Qt.callLater(scrollToStart) }
  onDaysChanged: { userScrolled = false; Qt.callLater(scrollToStart) }
  onHourHeightChanged: if (!userScrolled) Qt.callLater(scrollToStart)
  onHeightChanged: if (!userScrolled) Qt.callLater(scrollToStart)
  onVisibleChanged: if (visible) { userScrolled = false; Qt.callLater(scrollToStart) }
  Component.onCompleted: Qt.callLater(scrollToStart)

  // Ticks on the minute boundary (not 60 s after load), so the bar and its
  // label change when the clock in the bar does.
  SystemClock {
    id: nowClock
    precision: SystemClock.Minutes
    onDateChanged: root.nowMinute = date.getHours() * 60 + date.getMinutes()
  }

  readonly property bool showsToday: dayKeys.indexOf(todayKey) !== -1
  readonly property real nowY: nowMinute / 60 * hourHeight

  // ---- Zone captions over the gutter when a second zone is shown.
  Column {
    visible: root.secondTable !== null
    y: Math.max(0, (root.headerHeight - height) / 2)
    width: root.gutterWidth - Style.space(6)
    Text {
      width: parent.width
      horizontalAlignment: Text.AlignRight
      elide: Text.ElideLeft
      textFormat: Text.PlainText
      text: Tz.cityName(root.store ? root.store.localZone : "")
      color: Qt.darker(root.fg, 1.5)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }
    Text {
      width: root.secondGutter
      elide: Text.ElideRight
      textFormat: Text.PlainText
      text: Tz.cityName(root.secondZone)
      color: Qt.darker(root.fg, 1.9)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // ---- Day headers
  Row {
    id: header
    x: root.gutterWidth
    height: root.headerHeight

    Repeater {
      model: root.dayKeys

      Item {
        id: head
        required property var modelData
        readonly property date date: Events.parseStamp(modelData)
        readonly property bool isToday: modelData === root.todayKey
        readonly property bool isSelected: modelData === root.selectedKey
        width: root.columnWidth
        height: root.headerHeight

        Rectangle {
          anchors.fill: parent
          anchors.margins: Style.space(1)
          radius: Style.cornerRadius
          color: head.isSelected ? Style.selectedFillFor(root.fg, Color.accent)
            : headMouse.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"
        }

        Column {
          anchors.centerIn: parent
          visible: root.days > 1

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            textFormat: Text.PlainText
            text: Qt.formatDate(head.date, "ddd").toUpperCase()
            color: Qt.darker(root.fg, 1.5)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.letterSpacing: 1
            font.bold: true
          }
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            textFormat: Text.PlainText
            text: head.date.getDate()
            color: head.isToday ? Color.accent : root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: head.isToday || head.isSelected
          }
        }

        Text {
          visible: root.days === 1
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: Qt.formatDate(head.date, "dddd, MMMM d")
          color: head.isToday ? Color.accent : root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }

        MouseArea {
          id: headMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.picked(head.modelData)
        }
      }
    }
  }

  // ---- All-day lane
  Item {
    id: allDayLane
    y: header.height
    width: root.width
    height: root.allDayRows > 0 ? root.allDayRows * (root.allDayRowHeight + Style.space(2)) + Style.space(4) : 0
    visible: root.allDayRows > 0

    Text {
      width: root.gutterWidth - Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      horizontalAlignment: Text.AlignRight
      textFormat: Text.PlainText
      text: "all-day"
      color: Qt.darker(root.fg, 1.9)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Repeater {
      model: root.lane.bars.filter(function(b) { return b.row < root.laneBarRows })

      Rectangle {
        id: bar
        required property var modelData
        readonly property color tint: root.calColor(modelData.ev.calendarId)
        // Days the bar is being dragged by (drag sideways to move it).
        property int dayShift: 0
        z: dayShift !== 0 ? 3 : 0
        x: root.gutterWidth + (modelData.first + dayShift) * root.columnWidth + Style.space(1) + (modelData.cutStart ? 0 : Style.space(1))
        y: Style.space(2) + modelData.row * (root.allDayRowHeight + Style.space(2))
        width: (modelData.last - modelData.first + 1) * root.columnWidth - Style.space(2)
          - (modelData.cutStart ? 0 : Style.space(1)) - (modelData.cutEnd ? 0 : Style.space(1))
        height: root.allDayRowHeight
        radius: Math.min(Style.cornerRadius, Style.space(3))
        color: Util.alpha(tint, barMouse.containsMouse ? 0.5 : 0.32)

        Text {
          x: Style.space(4)
          width: parent.width - Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          elide: Text.ElideRight
          textFormat: Text.PlainText
          text: (bar.modelData.cutStart ? "‹ " : "")
            + (bar.modelData.ev.allDay ? "" : Events.shortTime(bar.modelData.ev.start, root.use24h) + " ")
            + bar.modelData.ev.title + (bar.modelData.cutEnd ? "  ›" : "")
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
          property real pressX: 0
          property bool moving: false
          onPressed: function(mouse) { pressX = mouse.x; moving = false }
          onPositionChanged: function(mouse) {
            if (!pressed || !root.canDrag(bar.modelData.ev)) return
            if (!moving && Math.abs(mouse.x - pressX) < Style.space(6)) return
            moving = true
            bar.dayShift = Math.round((mouse.x - pressX) / root.columnWidth)
          }
          onReleased: {
            var shift = bar.dayShift
            bar.dayShift = 0
            if (!moving) { root.eventPicked(bar.modelData.ev); return }
            moving = false
            if (shift !== 0) root.eventMoved(bar.modelData.ev, Events.movedByDays(bar.modelData.ev, shift))
          }
          onCanceled: { moving = false; bar.dayShift = 0 }
        }
      }
    }

    // "+N more" under each day whose bars did not all fit; click to show all.
    Repeater {
      model: root.laneBarRows < root.lane.rows ? root.dayKeys.length : 0

      Text {
        required property int index
        readonly property int hidden: root.hiddenOn(index)
        visible: hidden > 0
        x: root.gutterWidth + index * root.columnWidth + Style.space(4)
        y: Style.space(2) + root.laneBarRows * (root.allDayRowHeight + Style.space(2))
        height: root.allDayRowHeight
        verticalAlignment: Text.AlignVCenter
        textFormat: Text.PlainText
        text: "+" + hidden + " more"
        color: Qt.darker(root.fg, 1.5)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: root.laneExpanded = true
        }
      }
    }

    Text {
      visible: root.laneExpanded && root.lane.rows > root.laneMaxRows
      x: Style.space(2)
      y: parent.height - height - Style.space(2)
      width: root.gutterWidth - Style.space(6)
      horizontalAlignment: Text.AlignRight
      textFormat: Text.PlainText
      text: "less"
      color: Qt.darker(root.fg, 1.5)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.laneExpanded = false }
    }
  }

  Rectangle {
    y: allDayLane.y + allDayLane.height + Style.space(2)
    width: root.width
    height: Style.spacing.hairline
    color: root.fg
    opacity: 0.12
  }

  // ---- Hours
  Flickable {
    id: flick
    y: allDayLane.y + allDayLane.height + Style.space(4)
    width: root.width
    height: root.height - y
    contentWidth: width
    contentHeight: 24 * root.hourHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    onMovementStarted: root.userScrolled = true

    Item {
      id: hours
      width: flick.width
      height: flick.contentHeight

      Repeater {
        model: 24
        Item {
          required property int index
          y: index * root.hourHeight
          width: parent.width
          height: root.hourHeight

          Rectangle {
            x: root.gutterWidth
            width: parent.width - root.gutterWidth
            height: Style.spacing.hairline
            color: root.fg
            opacity: 0.08
          }
          Text {
            visible: root.secondTable !== null && index > 0
            width: root.secondGutter - Style.space(4)
            y: -height / 2
            textFormat: Text.PlainText
            text: root.secondLabel(index)
            color: Qt.darker(root.fg, 2.3)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          Text {
            // Make way for the current-time label when it sits on this hour.
            visible: index > 0 && Math.abs(index * 60 - root.nowMinute) > 12
            width: root.gutterWidth - Style.space(6)
            y: -height / 2
            horizontalAlignment: Text.AlignRight
            textFormat: Text.PlainText
            text: Events.hourLabel(index, root.use24h)
            color: Qt.darker(root.fg, 1.9)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }

      Repeater {
        model: root.dayKeys

        Item {
          id: dayCol
          required property var modelData
          required property int index
          readonly property var laid: root.dayLayouts[index] || []
          x: root.gutterWidth + index * root.columnWidth
          width: root.columnWidth
          height: parent.height

          Rectangle {
            anchors.fill: parent
            color: dayCol.modelData === root.todayKey ? Util.alpha(Color.accent, 0.04) : "transparent"
          }

          Rectangle {
            width: Style.spacing.hairline
            height: parent.height
            color: root.fg
            opacity: 0.08
          }

          // Click empty time to add an event at that day and half hour (a
          // ghost block under the pointer shows where); drag to pick a range.
          MouseArea {
            id: slotMouse
            anchors.fill: parent
            hoverEnabled: true
            preventStealing: true
            cursorShape: Qt.PointingHandCursor
            readonly property int hoverMinutes: Math.max(0, Math.min(23 * 60 + 30, Math.floor(mouseY / root.hourHeight * 2) * 30))
            property real pressY: 0
            property bool creating: false
            onPressed: function(mouse) { pressY = mouse.y; creating = false }
            onPositionChanged: function(mouse) {
              if (!pressed) return
              if (!creating && Math.abs(mouse.y - pressY) < Style.space(8)) return
              creating = true
              var a = root.clamp(Math.floor(pressY / root.hourHeight * 60 / root.snapMinutes) * root.snapMinutes, 0, 1440 - root.snapMinutes)
              var b = root.clamp(root.snap(mouse.y / root.hourHeight * 60), 0, 1440)
              root.dragInfo = { mode: "create", col: dayCol.index, startMin: Math.min(a, b), endMin: Math.max(a + root.snapMinutes, b) }
            }
            onReleased: function(mouse) {
              if (creating) { creating = false; root.commitDrag(); return }
              var minutes = Math.max(0, Math.min(23 * 60 + 30, Math.floor(mouse.y / root.hourHeight * 2) * 30))
              root.slotActivated(dayCol.modelData, minutes)
            }
            onCanceled: { creating = false; root.dragInfo = null }
          }

          Rectangle {
            visible: slotMouse.containsMouse && !root.dragInfo
            x: Style.space(2)
            y: slotMouse.hoverMinutes / 60 * root.hourHeight + 1
            width: parent.width - Style.space(4)
            height: root.hourHeight / 2 - 2
            radius: Math.min(Style.cornerRadius, Style.space(4))
            color: Util.alpha(Color.accent, 0.12)
            border.width: Style.spacing.hairline
            border.color: Util.alpha(Color.accent, 0.5)

            Text {
              x: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - Style.space(8)
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: "+ " + Events.formatTime(Math.floor(slotMouse.hoverMinutes / 60), slotMouse.hoverMinutes % 60, root.use24h)
              color: Color.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              visible: parent.height >= Style.space(12)
            }
          }

          Repeater {
            model: dayCol.laid

            Rectangle {
              id: block
              required property var modelData
              readonly property color tint: root.calColor(modelData.ev.calendarId)
              readonly property real slotWidth: (dayCol.width - Style.space(4)) / modelData.cols
              readonly property bool editable: root.canDrag(modelData.ev)
              // The event ends inside this column (its bottom edge is its end).
              readonly property bool endsHere: Events.lastDayKey(modelData.ev) === dayCol.modelData && modelData.end < 1440
              readonly property bool dragged: root.dragInfo !== null && root.dragInfo.ev === modelData.ev && root.dragInfo.mode !== "create"
              x: Style.space(2) + modelData.col * slotWidth
              y: modelData.start / 60 * root.hourHeight + 1
              width: slotWidth - Style.space(2)
              height: Math.max(Style.space(14), (modelData.end - modelData.start) / 60 * root.hourHeight - 2)
              radius: Math.min(Style.cornerRadius, Style.space(4))
              color: Util.alpha(tint, blockMouse.containsMouse ? 0.42 : 0.28)
              border.width: Style.spacing.hairline
              border.color: Util.alpha(tint, 0.7)
              clip: true
              opacity: dragged ? 0.35 : 1

              Rectangle {
                width: Style.space(3)
                height: parent.height
                color: block.tint
              }

              Column {
                x: Style.space(6)
                y: Style.space(2)
                width: parent.width - Style.space(8)

                Text {
                  width: parent.width
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  text: (block.modelData.ev.recurring ? "\uf01e " : "") + block.modelData.ev.title
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
                Text {
                  visible: block.height > Style.space(30)
                  width: parent.width
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  text: Events.timeLabel(block.modelData.ev, dayCol.modelData, root.use24h)
                    + (block.modelData.ev.location ? " · " + block.modelData.ev.location : "")
                  color: Qt.darker(root.fg, 1.3)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              // Grip for resizing, on events that end in this column.
              Rectangle {
                visible: block.editable && block.endsHere && blockMouse.containsMouse
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                anchors.bottomMargin: Style.space(2)
                width: Style.space(18)
                height: Math.max(2, Style.space(2))
                radius: height / 2
                color: Util.alpha(root.fg, 0.6)
              }

              // Click opens it; drag moves it (snapping to 15 minutes, across
              // days too); drag the bottom edge to change when it ends.
              MouseArea {
                id: blockMouse
                anchors.fill: parent
                hoverEnabled: true
                preventStealing: true
                readonly property bool onEdge: block.editable && block.endsHere && mouseY > height - Style.space(7)
                cursorShape: onEdge ? Qt.SizeVerCursor : (pressed && moving ? Qt.ClosedHandCursor : Qt.PointingHandCursor)
                property real pressX: 0
                property real pressY: 0
                property bool moving: false
                property bool resizing: false
                onPressed: function(mouse) {
                  pressX = mouse.x; pressY = mouse.y; moving = false
                  resizing = block.editable && block.endsHere && mouse.y > height - Style.space(7)
                }
                onPositionChanged: function(mouse) {
                  if (!pressed || !block.editable) return
                  if (!moving && Math.abs(mouse.x - pressX) + Math.abs(mouse.y - pressY) < Style.space(6)) return
                  moving = true
                  var p = mapToItem(hours, mouse.x, mouse.y)
                  var m = block.modelData
                  if (resizing) {
                    var end = root.clamp(root.snap(p.y / root.hourHeight * 60), m.start + root.snapMinutes, 1440)
                    root.dragInfo = { mode: "resize", ev: m.ev, col: dayCol.index, startMin: m.start, endMin: end }
                    return
                  }
                  var len = m.end - m.start
                  var start = root.clamp(root.snap(p.y / root.hourHeight * 60 - pressY / root.hourHeight * 60), 0, 1440 - root.snapMinutes)
                  var col = root.colAt(p.x)
                  root.dragInfo = { mode: "move", ev: m.ev, col: col, startMin: start, endMin: Math.min(1440, start + len),
                                    dayDelta: col - dayCol.index, minuteDelta: start - m.start }
                }
                onReleased: {
                  if (moving) { moving = false; root.commitDrag() }
                  else root.eventPicked(block.modelData.ev)
                }
                onCanceled: { moving = false; root.dragInfo = null }
              }
            }
          }

        }
      }

      // Where a drag will land: the moved/resized event or the new range.
      Rectangle {
        visible: root.dragInfo !== null
        z: 4
        readonly property var d: root.dragInfo || ({ col: 0, startMin: 0, endMin: 0 })
        readonly property color tint: d.ev ? root.calColor(d.ev.calendarId) : Color.accent
        x: root.gutterWidth + d.col * root.columnWidth + Style.space(2)
        y: d.startMin / 60 * root.hourHeight + 1
        width: root.columnWidth - Style.space(4)
        height: Math.max(Style.space(14), (d.endMin - d.startMin) / 60 * root.hourHeight - 2)
        radius: Math.min(Style.cornerRadius, Style.space(4))
        color: Util.alpha(tint, 0.45)
        border.width: Math.max(1, Style.space(1))
        border.color: tint

        Text {
          x: Style.space(6)
          y: Style.space(2)
          width: parent.width - Style.space(8)
          elide: Text.ElideRight
          textFormat: Text.PlainText
          text: Events.formatTime(Math.floor(parent.d.startMin / 60), parent.d.startMin % 60, root.use24h) + " – "
            + Events.formatTime(Math.floor(parent.d.endMin / 60) % 24, parent.d.endMin % 60, root.use24h)
            + (parent.d.ev ? "  " + parent.d.ev.title : "")
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }

      // ---- Current time. A strong bar with a dot across today's column, a
      // faint guide across every other day shown (so another day's events
      // can be read against "now"), and the time itself in the hour gutter.
      Item {
        id: nowMarker
        z: 5
        y: root.nowY
        width: parent.width
        height: 1

        Rectangle {
          x: root.gutterWidth
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width - root.gutterWidth
          height: Math.max(1, Style.space(1))
          color: Color.urgent
          opacity: 0.35
        }

        Repeater {
          model: root.dayKeys

          Rectangle {
            required property var modelData
            required property int index
            visible: modelData === root.todayKey
            x: root.gutterWidth + index * root.columnWidth
            anchors.verticalCenter: parent.verticalCenter
            width: root.columnWidth
            height: Math.max(2, Style.space(2))
            color: Color.urgent

            Rectangle {
              x: -width / 2
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(9)
              height: width
              radius: width / 2
              color: Color.urgent
            }
          }
        }

        Rectangle {
          x: Style.space(2) + root.secondGutter
          anchors.verticalCenter: parent.verticalCenter
          width: root.gutterWidth - root.secondGutter - Style.space(6)
          height: nowLabel.implicitHeight + Style.space(4)
          radius: Math.min(Style.cornerRadius, height / 2)
          color: root.showsToday ? Color.urgent : Color.background
          border.width: root.showsToday ? 0 : Math.max(1, Style.space(1))
          border.color: Util.alpha(Color.urgent, 0.6)

          Text {
            id: nowLabel
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: Events.shortTime(Events.keyOf(new Date()) + "T"
              + (Math.floor(root.nowMinute / 60) < 10 ? "0" : "") + Math.floor(root.nowMinute / 60) + ":"
              + (root.nowMinute % 60 < 10 ? "0" : "") + (root.nowMinute % 60), root.use24h)
            color: root.showsToday ? Color.background : Util.alpha(Color.urgent, 0.85)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }
      }
    }
  }
}
