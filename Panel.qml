import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "Events.js" as Events
import "Recur.js" as Recur

// The bar popout. Four views (month / week / day / agenda) in three sizes
// (compact / normal / large), plus the editors. Everything it draws comes
// from shared components that the full window (CalendarWindow.qml) uses too.
//
//   normal, large   main view on the left, side pane on the right
//   compact         one column: main view, then the side pane under it
//
// The side pane is the selected day's events + the calendar list, or an
// editor. View and size are bar settings (popoutView / popoutSize), so they
// persist in shell.json like the clock format does.
Panel {
  id: root
  moduleName: "carterra3.carts"
  ipcTarget: "carterra3.carts"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var service: null
  readonly property var store: service ? service.store : null
  readonly property var barIdentity: hostWidget || root

  readonly property bool use24h: hostWidget ? hostWidget.use24h : true

  // ---- Dates
  property string todayKey: Events.keyOf(new Date())
  property string cursorKey: Events.keyOf(new Date())
  readonly property date cursorDate: Events.parseStamp(cursorKey) || new Date()
  // Shared with the app through a store pref; the bar setting is the fallback.
  readonly property int weekStart: Model.normalizedWeekStart(
    store ? store.pref("weekStart", setting("weekStartDay", null)) : setting("weekStartDay", null), Qt.locale().firstDayOfWeek)

  // ---- View and size
  readonly property var views: ["month", "week", "day", "agenda"]
  readonly property var sizes: ["compact", "normal", "large"]
  readonly property string view: views.indexOf(setting("popoutView", "month")) !== -1 ? setting("popoutView", "month") : "month"
  readonly property string size: sizes.indexOf(setting("popoutSize", "normal")) !== -1 ? setting("popoutSize", "normal") : "normal"
  readonly property bool compact: size === "compact"
  readonly property bool large: size === "large"

  // Pane: "day" (agenda + calendars) | "event" | "calendar" | "hidden"
  property string mode: "day"

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dimFg: Qt.darker(fg, 1.5)
  readonly property color faintFg: Qt.darker(fg, 1.9)

  readonly property real sideWidth: Style.space(large ? 360 : 330)

  // ---- Open / close
  function open() {
    root.todayKey = Events.keyOf(new Date())
    if (root.mode === "day") root.cursorKey = root.todayKey
    if (store) store.syncIfStale()
    root.controller.show()
    Qt.callLater(function() { if (root.opened) setCenterHoverRevealSuppressed(true) })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    // Dismissing the popup abandons an open editor rather than leaving a
    // half-filled form waiting for the next unrelated click on the clock.
    if (root.mode === "event" && !eventEditor.saving) eventEditor.cancel()
    else if (root.mode === "calendar" && !calendarEditor.saving) calendarEditor.cancel()
    else if (root.mode === "hidden") root.mode = "day"
    root.controller.hide()
  }

  function toggle() { root.opened ? root.close() : root.open() }
  function refresh() { root.todayKey = Events.keyOf(new Date()) }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]
    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function setView(v) { if (v !== root.view) persistSettings({ popoutView: v }) }
  function setSize(s) { if (s !== root.size) persistSettings({ popoutSize: s }) }
  function cycleView() { setView(views[(views.indexOf(view) + 1) % views.length]) }
  function cycleSize() { setSize(sizes[(sizes.indexOf(size) + 1) % sizes.length]) }

  function toggleWeekStart() {
    var name = Model.weekStartSettingName(Model.toggledWeekStart(root.weekStart))
    if (root.store) root.store.setPref("weekStart", name)
    persistSettings({ weekStartDay: name })
  }

  // ---- Navigation
  function pick(key) {
    root.cursorKey = key
    if (root.mode === "event") eventEditor.setDay(key)
  }
  function step(delta) { pick(Events.stepKey(root.view, root.cursorKey, delta)) }
  function moveDays(n) { pick(Events.addDaysKey(root.cursorKey, n)) }
  function goToday() { root.todayKey = Events.keyOf(new Date()); pick(root.todayKey) }

  function openInWindow() {
    var key = root.cursorKey, v = root.view
    root.close()
    if (root.service) root.service.openWindow(key, v)
  }

  // A click that means "here": add an event, or move the one being edited.
  function activate(key, minutes) {
    if (root.mode === "event" && !eventEditor.readOnly) {
      root.cursorKey = key
      eventEditor.setSlot(key, minutes)
    } else openNewEvent(key, minutes)
  }

  // ---- Editors
  function openNewEvent(key, minutes, endMinutes) {
    if (!root.opened) root.open()
    if (!store) return
    if (key) root.cursorKey = key
    root.mode = "event"
    if (!eventEditor.openNew(root.cursorKey, minutes, endMinutes)) openNewCalendar("local")
  }

  function openEditEvent(ev) {
    root.mode = "event"
    eventEditor.openEdit(ev)
  }

  // A drag moved an event. Repeating ones open in the editor at the new
  // time, which asks which occurrences to move.
  function moveEvent(ev, changed) {
    if (!store) return
    if (ev.recurring) {
      if (changed.start.substr(0, 10) !== ev.start.substr(0, 10))
        changed.rrule = Recur.retarget(ev.rrule || "", ev.start.substr(0, 10), changed.start.substr(0, 10))
      root.mode = "event"
      eventEditor.openMoved(ev, changed)
      return
    }
    store.moveEvent(ev, changed, function(err) {
      if (err) { root.mode = "event"; eventEditor.openEdit(ev); eventEditor.formError = err }
    })
  }

  function openHidden() {
    if (!root.opened) root.open()
    root.mode = "hidden"
    Qt.callLater(function() { hiddenList.forceActiveFocus() })
  }

  function openNewCalendar(kind) {
    if (!root.opened) root.open()
    root.mode = "calendar"
    calendarEditor.openNew(kind || "local")
  }

  function openEditCalendar(cal) {
    root.mode = "calendar"
    calendarEditor.openEdit(cal)
  }

  function backToDay() {
    root.mode = "day"
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  SystemClock {
    precision: SystemClock.Minutes
    onDateChanged: {
      var k = Events.keyOf(date)
      if (k === root.todayKey) return
      var follow = root.cursorKey === root.todayKey && root.mode === "day"
      root.todayKey = k
      if (follow) root.cursorKey = k
    }
  }

  // ---------------------------------------------------------------- layout
  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    // contentWidth is the whole card, so the padding and border are ours to add
    // (fittedContentHeight adds them itself for the height).
    contentWidth: panel.fittedContentWidth(mainColumn.width
      + (root.compact ? 0 : root.sideWidth + contentRow.spacing * 2 + Style.spacing.hairline)
      + panel.padding * 2 + Border.left(panel.borderSpec) + Border.right(panel.borderSpec) + Style.space(4))
    contentHeight: panel.fittedContentHeight(root.compact
      ? mainColumn.implicitHeight
      : Math.max(mainColumn.implicitHeight, sidePane.implicitHeight + sideScroll.topMargin))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.mode !== "day"
      onMoveRequested: function(dx, dy) { root.moveDays(dx + dy * 7) }
      onActivateRequested: root.openNewEvent()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "[") root.step(-1)
        else if (t === "]") root.step(1)
        else if (t === "t" || t === "T") root.goToday()
        else if (t === "n" || t === "N") root.openNewEvent()
        else if (t === "m") root.setView("month")
        else if (t === "w") root.setView("week")
        else if (t === "d") root.setView("day")
        else if (t === "a") root.setView("agenda")
        else if (t === "s") root.cycleSize()
        else if (t === "o") root.openInWindow()
        else if (t === "r" && root.store) root.store.syncAll()
      }

      // Compact scrolls as one column; the other sizes scroll only the side pane.
      Flickable {
        id: outerScroll
        anchors.fill: parent
        contentWidth: contentRow.implicitWidth
        contentHeight: contentRow.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: root.compact && contentHeight > height

        Row {
          id: contentRow
          spacing: Style.space(20)

          // ======================= main column =======================
          Column {
            id: mainColumn
            spacing: Style.space(8)
            width: Math.max(mainView.implicitWidth, Style.space(root.compact ? 320 : 360))

            // ---- controls: views on the left, size + window on the right
            Item {
              width: parent.width
              height: Math.max(viewGroup.implicitHeight, sizeBtn.height)

              ButtonGroup {
                id: viewGroup
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                options: [
                  { value: "month", label: root.compact ? "M" : "Month", tooltip: "Month  (m)" },
                  { value: "week", label: root.compact ? "W" : "Week", tooltip: "Week  (w)" },
                  { value: "day", label: root.compact ? "D" : "Day", tooltip: "Day  (d)" },
                  { value: "agenda", label: root.compact ? "A" : "Agenda", tooltip: "Agenda  (a)" }
                ]
                value: root.view
                focusable: false
                fontSize: Style.font.bodySmall
                foreground: root.fg
                fontFamily: root.fontFamily
                onChanged: function(v) { root.setView(v) }
              }

              Row {
                anchors.right: parent.right
                anchors.rightMargin: -Style.space(6)
                anchors.verticalCenter: parent.verticalCenter

                PanelActionButton {
                  id: sizeBtn
                  iconText: root.large ? "\uf066" : "\uf065"
                  tooltipText: "Size: " + root.size + " (s cycles)"
                  foreground: root.fg
                  fontFamily: root.fontFamily
                  fontSize: Style.font.body
                  onClicked: root.cycleSize()
                }
                PanelActionButton {
                  iconText: "\uf08e"
                  tooltipText: "Open as a window  (o)"
                  foreground: root.fg
                  fontFamily: root.fontFamily
                  fontSize: Style.font.body
                  onClicked: root.openInWindow()
                }
              }
            }

            // ---- hero: today. Clicking it comes back to today.
            Item {
              visible: !root.compact
              width: parent.width
              height: visible ? heroRow.height : 0

              Row {
                id: heroRow
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Style.space(14)

                Text {
                  anchors.baseline: heroDate.baseline
                  text: "󰃭"
                  color: heroMouse.containsMouse ? Style.hoverStateColor(root.fg, Color.accent) : root.fg
                  font.family: root.fontFamily
                  font.pixelSize: root.large ? 40 : 30
                }

                Text {
                  id: heroDate
                  textFormat: Text.PlainText
                  text: Qt.formatDate(Events.parseStamp(root.todayKey), "MMMM d")
                  color: heroMouse.containsMouse ? Style.hoverStateColor(root.fg, Color.accent) : root.fg
                  font.family: root.fontFamily
                  font.pixelSize: root.large ? 44 : 34
                  font.bold: true
                }
              }

              MouseArea {
                id: heroMouse
                anchors.fill: heroRow
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.goToday()
              }
            }

            // ---- period navigation
            Item {
              width: parent.width
              height: periodLabel.implicitHeight + Style.space(10)

              Text {
                id: periodLabel
                textFormat: Text.PlainText
                anchors.centerIn: parent
                width: parent.width - Style.space(70)
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                text: Events.periodTitle(root.view, root.cursorKey, root.weekStart).toUpperCase()
                color: Qt.darker(root.fg, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.letterSpacing: 1

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.goToday()
                }
              }

              PanelActionButton {
                anchors.left: parent.left
                anchors.leftMargin: -Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰅁"
                tooltipText: "Previous  ["
                foreground: root.fg
                fontFamily: root.fontFamily
                onClicked: root.step(-1)
              }

              PanelActionButton {
                anchors.right: parent.right
                anchors.rightMargin: -Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰅂"
                tooltipText: "Next  ]"
                foreground: root.fg
                fontFamily: root.fontFamily
                onClicked: root.step(1)
              }
            }

            // ---- the view (hidden in compact while an editor is open)
            MainView {
              id: mainView
              visible: !(root.compact && root.mode !== "day")
              // Built only while the popup is on screen (panel.visible lasts
              // through the fade-out, so closing still shows the content).
              active: panel.visible
              anchors.horizontalCenter: parent.horizontalCenter
              height: visible ? implicitHeight : 0
              width: implicitWidth
              store: root.store
              view: root.view
              cursorKey: root.cursorKey
              todayKey: root.todayKey
              weekStart: root.weekStart
              use24h: root.use24h
              fg: root.fg
              fontFamily: root.fontFamily

              monthCellWidth: Style.space(root.compact ? 44 : root.large ? 92 : 48)
              monthCellHeight: Style.space(root.compact ? 32 : root.large ? 80 : 40)
              maxChips: root.large ? 3 : 0
              showWeekNumbers: !root.compact
              timeGridWidth: Style.space(root.compact ? 320 : root.large ? 880 : 520)
              hourHeight: Style.space(root.compact ? 26 : root.large ? 44 : 34)
              visibleHours: root.large ? 11 : 9
              agendaWidth: Style.space(root.compact ? 320 : root.large ? 640 : 460)
              agendaHeight: Style.space(root.compact ? 300 : root.large ? 600 : 400)
              agendaDays: root.large ? 60 : 30

              onPicked: function(key) { root.pick(key) }
              onActivated: function(key, minutes) { root.activate(key, minutes) }
              onEventPicked: function(ev) { root.openEditEvent(ev) }
              onStepRequested: function(d) { root.step(d) }
              onWeekStartToggleRequested: root.toggleWeekStart()
              onEventMoved: function(ev, changed) { root.moveEvent(ev, changed) }
              onRangeSelected: function(key, a, b) { root.openNewEvent(key, a, b) }
            }

            // compact: the side pane is reparented in here
            Item {
              id: compactSlot
              visible: root.compact
              width: parent.width
              height: root.compact ? sidePane.implicitHeight : 0
            }
          }

          Rectangle {
            visible: !root.compact
            width: visible ? Style.spacing.hairline : 0
            height: keyCatcher.height
            color: root.fg
            opacity: 0.1
          }

          Flickable {
            id: sideScroll
            visible: !root.compact
            width: visible ? root.sideWidth : 0
            height: keyCatcher.height
            topMargin: Style.space(6)
            contentWidth: width
            contentHeight: sideSlot.height
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight + topMargin > height

            Item {
              id: sideSlot
              width: sideScroll.width
              height: root.compact ? 0 : sidePane.implicitHeight
            }
          }
        }
      }
    }
  }

  // ---- Side pane: one instance, reparented between the two layouts so an
  // editor keeps its state when the size changes under it.
  Column {
    id: sidePane
    parent: root.compact ? compactSlot : sideSlot
    width: parent ? parent.width : root.sideWidth
    spacing: Style.space(8)

    UndoBar {
      width: parent.width
      store: root.store
      fg: root.fg
      fontFamily: root.fontFamily
    }

    // ---- day: selected day + calendars
    Column {
      visible: root.mode === "day"
      width: parent.width
      spacing: Style.space(8)

      Text {
        visible: root.store && root.store.problem !== ""
        width: parent.width
        wrapMode: Text.Wrap
        textFormat: Text.PlainText
        text: root.store ? root.store.problem : ""
        color: Color.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Item {
        width: parent.width
        height: Math.max(dayHeading.implicitHeight, addEventBtn.height)

        Column {
          id: dayHeading
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter

          Text {
            textFormat: Text.PlainText
            text: Qt.formatDate(root.cursorDate, "dddd")
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: root.compact ? Style.font.title : Style.font.heading
            font.bold: true
          }
          Text {
            textFormat: Text.PlainText
            text: Qt.formatDate(root.cursorDate, "MMMM d, yyyy") + (root.cursorKey === root.todayKey ? "  ·  today" : "")
            color: root.dimFg
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        PanelActionButton {
          id: addEventBtn
          anchors.right: parent.right
          anchors.rightMargin: -Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
          iconText: "󰐕"
          tooltipText: "New event  (n / Enter)"
          foreground: root.fg
          fontFamily: root.fontFamily
          onClicked: root.openNewEvent()
        }
      }

      AgendaList {
        width: parent.width
        store: root.store
        fromKey: root.cursorKey
        days: 1
        todayKey: root.todayKey
        use24h: root.use24h
        fg: root.fg
        fontFamily: root.fontFamily
        onEventPicked: function(ev) { root.openEditEvent(ev) }
      }

      Item { visible: !root.compact; width: 1; height: Style.space(4) }
      PanelSeparator { visible: !root.compact; width: parent.width; foreground: root.fg }

      CalendarList {
        visible: !root.compact
        width: parent.width
        store: root.store
        fg: root.fg
        fontFamily: root.fontFamily
        onAddRequested: root.openNewCalendar("local")
        onEditRequested: function(cal) { root.openEditCalendar(cal) }
        onHiddenRequested: root.openHidden()
      }

      // Compact has no calendar list; keep the way into hidden events.
      Text {
        visible: root.compact && root.store && root.store.hidden.length > 0
        textFormat: Text.PlainText
        text: "\uf070  Hidden events (" + (root.store ? root.store.hidden.length : 0) + ")"
        color: root.dimFg
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.openHidden() }
      }
    }

    HiddenList {
      id: hiddenList
      visible: root.mode === "hidden"
      width: parent.width
      store: root.store
      use24h: root.use24h
      fg: root.fg
      fontFamily: root.fontFamily
      onFinished: root.backToDay()
      onPicked: function(key) { root.cursorKey = key }
    }

    EventEditor {
      id: eventEditor
      visible: root.mode === "event"
      width: parent.width
      store: root.store
      use24h: root.use24h
      fg: root.fg
      fontFamily: root.fontFamily
      onFinished: function(key) {
        if (key) root.cursorKey = key
        root.backToDay()
      }
    }

    CalendarEditor {
      id: calendarEditor
      visible: root.mode === "calendar"
      width: parent.width
      store: root.store
      fg: root.fg
      fontFamily: root.fontFamily
      onFinished: root.backToDay()
    }
  }
}
