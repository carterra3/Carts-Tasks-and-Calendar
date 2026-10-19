import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Events.js" as Events
import "Recur.js" as Recur
import "Contacts.js" as Contacts

// The app's window (see CalendarApp.qml): toolbar, sidebar (mini month +
// calendars), the main view filling the tile, and a drawer for the
// event/calendar editors. In contacts mode the sidebar lists address books,
// the main area is ContactsView and the drawer holds the contact editors. `service` is the app root: use24h, weekStart,
// toggleWeekStart().
FloatingWindow {
  id: win

  property var store: null
  property var service: null

  readonly property bool use24h: service ? service.use24h : true
  readonly property int weekStart: service ? service.weekStart : 1

  property string view: store ? store.pref("windowView", "month") : "month"
  property string cursorKey: Events.keyOf(new Date())
  property string todayKey: Events.keyOf(new Date())
  property string drawer: ""           // "" | "event" | "calendar" | "hidden" | "contact" | "book"
  // "calendar" or "contacts": which half of the app fills the window.
  property string mode: store ? store.pref("windowMode", "calendar") : "calendar"
  property string contactsBook: ""     // address book filter, "" = all
  property string contactKey: ""       // selected contact
  readonly property bool contactsMode: mode === "contacts"

  readonly property color fg: Color.foreground
  readonly property string fontFamily: Style.font.family

  title: "Carts"
  color: Color.background
  implicitWidth: 1180
  implicitHeight: 780
  minimumSize: Qt.size(720, 480)

  // Called by the service: show (or re-show) the window, optionally on a
  // given day/view, and ask Hyprland to focus it if it was already open.
  function present(key, v) {
    if (key) win.cursorKey = key
    if (v) setView(v)
    var wasVisible = win.visible
    win.visible = true
    // Hyprland's Lua dispatcher syntax (Omarchy 4 config).
    if (wasVisible) Quickshell.execDetached(["hyprctl", "dispatch", "hl.dsp.focus({ window = \"class:^org\\.omarchy\\.calendar$\" })"])
    Qt.callLater(function() { if (win.drawer === "") focusRoot.takeFocus() })
  }

  function setView(v) {
    win.view = v
    if (store) store.setPref("windowView", v)
  }

  function setMode(m) {
    if (m !== "contacts") m = "calendar"
    if (m === win.mode) return
    if (win.drawer !== "") win.drawer = ""
    win.mode = m
    if (store) store.setPref("windowMode", m)
    if (m === "contacts" && store) store.syncContacts()
    Qt.callLater(function() { focusRoot.takeFocus() })
  }

  function newContact() {
    if (!store) return
    setMode("contacts")
    if (!store.writableBooks.length) { openBookEditor(null); return }
    win.drawer = "contact"
    contactEditor.openNew(win.contactsBook)
  }

  function editContact(c) {
    if (!c || !store || !store.bookWritable(c.bookId)) return
    win.contactKey = Contacts.keyOf(c)
    win.drawer = "contact"
    contactEditor.openEdit(c)
  }

  function openBookEditor(book) {
    win.drawer = "book"
    if (book) bookEditor.openEdit(book)
    else bookEditor.openNew()
  }

  function flash(text) { win.notice = text; win.noticeError = false; noticeTimer.restart() }

  function step(delta) { win.cursorKey = Events.stepKey(win.view, win.cursorKey, delta) }
  function goToday() { win.todayKey = Events.keyOf(new Date()); win.cursorKey = win.todayKey }

  function pick(key) {
    win.cursorKey = key
    if (win.drawer === "event") eventEditor.setDay(key)
  }

  // A click that means "here": add an event, or move the one being edited.
  function activate(key, minutes) {
    if (win.drawer === "event" && !eventEditor.readOnly) {
      win.cursorKey = key
      eventEditor.setSlot(key, minutes)
    } else newEvent(key, minutes)
  }

  function newEvent(key, minutes) {
    if (!store) return
    if (key) win.cursorKey = key
    win.drawer = "event"
    if (!eventEditor.openNew(win.cursorKey, minutes)) openCalendarEditor(null, "local")
  }

  // Drags from the views.
  property string notice: ""
  property bool noticeError: true
  function moveEvent(ev, changed) {
    if (!store) return
    if (ev.recurring) {
      if (Events.keyOf(Events.parseStamp(changed.start)) !== Events.keyOf(Events.parseStamp(ev.start)))
        changed.rrule = Recur.retarget(ev.rrule || "", ev.start.substr(0, 10), changed.start.substr(0, 10))
      win.drawer = "event"
      eventEditor.openMoved(ev, changed)
      return
    }
    store.moveEvent(ev, changed, function(err) {
      if (err) { win.notice = err; win.noticeError = true; noticeTimer.restart() }
    })
  }

  function newRange(key, startMin, endMin) {
    if (!store) return
    win.cursorKey = key
    win.drawer = "event"
    if (!eventEditor.openNew(key, startMin, endMin)) openCalendarEditor(null, "local")
  }

  Timer { id: noticeTimer; interval: win.noticeError ? 6000 : 2500; onTriggered: win.notice = "" }

  function editEvent(ev) {
    win.drawer = "event"
    eventEditor.openEdit(ev)
  }

  function openCalendarEditor(cal, kind) {
    win.drawer = "calendar"
    if (cal) calendarEditor.openEdit(cal)
    else calendarEditor.openNew(kind || "local")
  }

  function closeDrawer() {
    win.drawer = ""
    Qt.callLater(function() { focusRoot.takeFocus() })
  }

  Timer {
    interval: 60000
    running: win.visible
    repeat: true
    onTriggered: {
      var k = Events.keyOf(new Date())
      if (k !== win.todayKey) {
        var follow = win.cursorKey === win.todayKey
        win.todayKey = k
        if (follow) win.cursorKey = k
      }
    }
  }

  onVisibleChanged: if (visible && store) store.syncIfStale()

  FocusScope {
    id: focusRoot
    anchors.fill: parent
    focus: true

    // Take keyboard focus back from whatever has it inside the window (an
    // editor field, the search box). forceActiveFocus() alone is a no-op
    // here: the scope already counts as focused through that child, and a
    // field keeps focus even after its drawer is hidden, so every shortcut
    // would keep going to it.
    function takeFocus() {
      for (var i = 0; i < 10; i++) {
        var f = Window.activeFocusItem
        if (!f || f === focusRoot) break
        f.focus = false
      }
      focusRoot.forceActiveFocus()
    }

    // Shortcuts apply only while no editor is open, so typing in a form
    // never moves the calendar underneath it.
    Keys.onPressed: function(event) {
      if (win.drawer !== "") {
        if (event.key === Qt.Key_Escape) { win.closeDrawer(); event.accepted = true }
        return
      }
      var t = event.text
      var k = event.key
      if (t === "c" || t === "C") { win.setMode(win.contactsMode ? "calendar" : "contacts"); event.accepted = true; return }
      if (win.contactsMode) {
        if (k === Qt.Key_Down || t === "j") contactsView.move(1)
        else if (k === Qt.Key_Up || t === "k") contactsView.move(-1)
        else if (k === Qt.Key_PageDown) contactsView.move(10)
        else if (k === Qt.Key_PageUp) contactsView.move(-10)
        else if (t === "/" || (k === Qt.Key_F && (event.modifiers & Qt.ControlModifier))) { searchField.forceActiveFocus(); searchField.selectAll() }
        else if (t === "n" || t === "N") win.newContact()
        else if (t === "e" || k === Qt.Key_Return || k === Qt.Key_Enter) win.editContact(contactsView.current)
        else if (t === "r" && win.store) win.store.syncContacts()
        else if (k === Qt.Key_Escape && searchField.text !== "") searchField.text = ""
        else return
        event.accepted = true
        return
      }
      if (k === Qt.Key_Left || t === "h") win.cursorKey = Events.addDaysKey(win.cursorKey, -1)
      else if (k === Qt.Key_Right || t === "l") win.cursorKey = Events.addDaysKey(win.cursorKey, 1)
      else if (k === Qt.Key_Up || t === "k") win.cursorKey = Events.addDaysKey(win.cursorKey, -7)
      else if (k === Qt.Key_Down || t === "j") win.cursorKey = Events.addDaysKey(win.cursorKey, 7)
      else if (t === "[" || k === Qt.Key_PageUp) win.step(-1)
      else if (t === "]" || k === Qt.Key_PageDown) win.step(1)
      else if (t === "t" || t === "T") win.goToday()
      else if (t === "n" || t === "N" || k === Qt.Key_Return || k === Qt.Key_Enter) win.newEvent()
      else if (t === "m") win.setView("month")
      else if (t === "w") win.setView("week")
      else if (t === "d") win.setView("day")
      else if (t === "a") win.setView("agenda")
      else if (t === "y") win.setView("year")
      else if (t === "r" && win.store) win.store.syncAll()
      else return
      event.accepted = true
    }

    // ---------------------------------------------------------------- toolbar
    Item {
      id: toolbar
      x: Style.space(16)
      y: Style.space(10)
      width: parent.width - Style.space(32)
      height: Style.space(40)
      // Narrow tiles: one-letter view buttons and an icon-only New button.
      readonly property bool compact: width < Style.space(1000)

      Row {
        id: navRow
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(8)

        ButtonGroup {
          anchors.verticalCenter: parent.verticalCenter
          options: [
            { value: "calendar", label: "", icon: "󰃭", tooltip: "Calendar  (c)" },
            { value: "contacts", label: "", icon: "󰀉", tooltip: "Contacts  (c)" }
          ]
          value: win.mode
          focusable: false
          foreground: win.fg
          fontFamily: win.fontFamily
          onChanged: function(v) { win.setMode(v) }
        }

        Button {
          anchors.verticalCenter: parent.verticalCenter
          visible: !win.contactsMode
          text: "Today"
          bordered: true
          foreground: win.fg
          fontFamily: win.fontFamily
          onClicked: win.goToday()
        }
        PanelActionButton {
          anchors.verticalCenter: parent.verticalCenter
          visible: !win.contactsMode
          iconText: "󰅁"
          tooltipText: "Previous  ["
          foreground: win.fg
          fontFamily: win.fontFamily
          onClicked: win.step(-1)
        }
        PanelActionButton {
          anchors.verticalCenter: parent.verticalCenter
          visible: !win.contactsMode
          iconText: "󰅂"
          tooltipText: "Next  ]"
          foreground: win.fg
          fontFamily: win.fontFamily
          onClicked: win.step(1)
        }
      }

      Text {
        anchors.left: navRow.right
        anchors.leftMargin: Style.space(14)
        anchors.verticalCenter: parent.verticalCenter
        width: Math.max(0, actionRow.x - x - Style.space(12))
        elide: Text.ElideRight
        textFormat: Text.PlainText
        text: win.contactsMode ? (win.contactsBook && win.store && win.store.bookById(win.contactsBook) ? win.store.bookById(win.contactsBook).name : "Contacts")
          : Events.periodTitle(win.view, win.cursorKey, win.weekStart)
        color: win.fg
        font.family: win.fontFamily
        font.pixelSize: toolbar.compact ? Style.font.title : Style.font.display
        font.bold: true
      }

      Row {
        id: actionRow
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(10)

        TextField {
          id: searchField
          anchors.verticalCenter: parent.verticalCenter
          visible: win.contactsMode && win.store && win.store.addressBooks.length > 0
          width: toolbar.compact ? Style.space(180) : Style.space(280)
          placeholderText: "Search contacts  (/)"
          foreground: win.fg
          font.family: win.fontFamily
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) { text = ""; focusRoot.takeFocus(); event.accepted = true }
            else if (event.key === Qt.Key_Down || event.key === Qt.Key_Up) { contactsView.move(event.key === Qt.Key_Down ? 1 : -1); event.accepted = true }
            else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { focusRoot.takeFocus(); event.accepted = true }
          }
        }

        ButtonGroup {
          anchors.verticalCenter: parent.verticalCenter
          visible: !win.contactsMode
          options: [
            { value: "year", label: toolbar.compact ? "Y" : "Year", tooltip: "y" },
            { value: "month", label: toolbar.compact ? "M" : "Month", tooltip: "m" },
            { value: "week", label: toolbar.compact ? "W" : "Week", tooltip: "w" },
            { value: "day", label: toolbar.compact ? "D" : "Day", tooltip: "d" },
            { value: "agenda", label: toolbar.compact ? "A" : "Agenda", tooltip: "a" }
          ]
          value: win.view
          focusable: false
          foreground: win.fg
          fontFamily: win.fontFamily
          onChanged: function(v) { win.setView(v) }
        }
        PanelActionButton {
          anchors.verticalCenter: parent.verticalCenter
          readonly property bool busy: win.store && (win.contactsMode ? win.store.contactsSyncing : win.store.syncing)
          visible: win.store && (win.contactsMode ? win.store.addressBooks.length > 0 : win.store.hasRemote)
          iconText: "󰑐"
          tooltipText: busy ? "Syncing…" : "Sync now  (r)"
          foreground: busy ? Qt.darker(win.fg, 1.9) : win.fg
          fontFamily: win.fontFamily
          enabled: !busy
          onClicked: win.contactsMode ? win.store.syncContacts() : win.store.syncAll()
        }
        Button {
          anchors.verticalCenter: parent.verticalCenter
          readonly property string label: win.contactsMode ? "New contact" : "New event"
          text: toolbar.compact ? "" : label
          tooltipText: toolbar.compact ? label + "  (n)" : ""
          iconText: "󰐕"
          bordered: true
          selected: true
          foreground: win.fg
          fontFamily: win.fontFamily
          onClicked: win.contactsMode ? win.newContact() : win.newEvent()
        }
      }
    }

    // Errors from drags (e.g. the server refused the change).
    Rectangle {
      z: 11
      visible: win.notice !== ""
      width: Math.min(Style.space(460), mainView.width)
      height: noticeText.implicitHeight + Style.space(16)
      x: mainView.x + (mainView.width - width) / 2
      y: parent.height - height - Style.space(70)
      radius: Style.cornerRadius
      color: Qt.tint(Color.background, Util.alpha(win.noticeError ? Color.urgent : Color.accent, 0.3))
      Text {
        id: noticeText
        anchors.centerIn: parent
        width: parent.width - Style.space(20)
        wrapMode: Text.Wrap
        textFormat: Text.PlainText
        text: (win.noticeError ? "⚠ " : "") + win.notice
        color: win.fg
        font.family: win.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
      MouseArea { anchors.fill: parent; onClicked: win.notice = "" }
    }

    // Undo for the last hide, floating over the bottom of the main view.
    UndoBar {
      z: 10
      width: Math.min(Style.space(420), mainView.width)
      x: mainView.x + (mainView.width - width) / 2
      y: parent.height - height - Style.space(20)
      store: win.store
      fg: win.fg
      fontFamily: win.fontFamily
      color: Qt.tint(Color.background, Util.alpha(Color.accent, 0.25))
    }

    // ---------------------------------------------------------------- sidebar
    // A half-width tile cannot hold sidebar + view + editor; the sidebar
    // steps aside while an editor is open there.
    readonly property bool sidebarShown: !(win.drawer !== "" && win.width < Style.space(1300))

    Flickable {
      id: sidebar
      visible: focusRoot.sidebarShown
      x: Style.space(16)
      y: toolbar.y + toolbar.height + Style.space(12)
      width: visible ? Style.space(250) : 0
      height: parent.height - y - Style.space(12)
      contentWidth: width
      contentHeight: sideColumn.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds

      Column {
        id: sideColumn
        width: sidebar.width
        spacing: Style.space(14)

        AddressBookList {
          visible: win.contactsMode
          width: sideColumn.width
          store: win.store
          selectedBook: win.contactsBook
          fg: win.fg
          fontFamily: win.fontFamily
          onSelected: function(id) { win.contactsBook = id }
          onAddRequested: win.openBookEditor(null)
          onEditRequested: function(book) { win.openBookEditor(book) }
        }

        Text {
          visible: !win.contactsMode
          textFormat: Text.PlainText
          text: Qt.formatDate(Events.parseStamp(win.cursorKey) || new Date(), "MMMM yyyy").toUpperCase()
          color: Qt.darker(win.fg, 1.4)
          font.family: win.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.letterSpacing: 1
          font.bold: true
        }

        MonthGrid {
          visible: !win.contactsMode
          store: win.store
          year: (Events.parseStamp(win.cursorKey) || new Date()).getFullYear()
          month: (Events.parseStamp(win.cursorKey) || new Date()).getMonth()
          weekStart: win.weekStart
          selectedKey: win.cursorKey
          todayKey: win.todayKey
          showWeekNumbers: false
          cellWidth: (sideColumn.width - 6 * cellSpacing) / 7
          cellHeight: Style.space(28)
          dayFontSize: Style.font.bodySmall
          fg: win.fg
          fontFamily: win.fontFamily
          onPicked: function(key) { win.pick(key) }
          onActivated: function(key) { win.activate(key, -1) }
          onStepRequested: function(d) { win.cursorKey = Events.addMonthsKey(win.cursorKey, d) }
        }

        CalendarList {
          visible: !win.contactsMode
          width: sideColumn.width
          store: win.store
          fg: win.fg
          fontFamily: win.fontFamily
          onAddRequested: win.openCalendarEditor(null, "local")
          onEditRequested: function(cal) { win.openCalendarEditor(cal) }
          onHiddenRequested: { win.drawer = "hidden"; Qt.callLater(function() { hiddenList.forceActiveFocus() }) }
        }

        WorldClocks {
          visible: !win.contactsMode
          width: sideColumn.width
          store: win.store
          use24h: win.use24h
          fg: win.fg
          fontFamily: win.fontFamily
        }

        Text {
          width: sideColumn.width
          wrapMode: Text.Wrap
          textFormat: Text.PlainText
          text: win.contactsMode
            ? "Keys: ↑↓ / j k move · / search · n new · e edit · r sync · c calendar"
            : "Keys: ←→↑↓ move · [ ] previous/next · t today · n new · y m w d a views · r sync · c contacts"
          color: Qt.darker(win.fg, 1.9)
          font.family: win.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }

    Rectangle {
      visible: sidebar.visible
      x: sidebar.x + sidebar.width + Style.space(12)
      y: sidebar.y
      width: Style.spacing.hairline
      height: sidebar.height
      color: win.fg
      opacity: 0.1
    }

    // -------------------------------------------------------------- main view
    MainView {
      id: mainView
      x: sidebar.visible ? sidebar.x + sidebar.width + Style.space(24) : Style.space(16)
      y: sidebar.y
      width: (drawerPane.visible ? drawerPane.x - Style.space(16) : parent.width - Style.space(16)) - x
      height: sidebar.height
      visible: !win.contactsMode
      fill: true
      active: win.visible && !win.contactsMode
      store: win.store
      view: win.view
      cursorKey: win.cursorKey
      todayKey: win.todayKey
      weekStart: win.weekStart
      use24h: win.use24h
      hourHeight: Style.space(48)
      agendaDays: 90
      fg: win.fg
      fontFamily: win.fontFamily
      onPicked: function(key) { win.pick(key) }
      onActivated: function(key, minutes) { win.activate(key, minutes) }
      onEventPicked: function(ev) { win.editEvent(ev) }
      onStepRequested: function(d) { win.step(d) }
      onOpenRequested: function(key, v) { win.cursorKey = key; win.setView(v) }
      onEventMoved: function(ev, changed) { win.moveEvent(ev, changed) }
      onRangeSelected: function(key, a, b) { win.newRange(key, a, b) }
      onWeekStartToggleRequested: if (win.service) win.service.toggleWeekStart()
    }

    ContactsView {
      id: contactsView
      visible: win.contactsMode
      x: mainView.x
      y: mainView.y
      width: mainView.width
      height: mainView.height
      store: win.store
      bookId: win.contactsBook
      query: searchField.text
      selectedKey: win.contactKey
      fg: win.fg
      fontFamily: win.fontFamily
      onSelectRequested: function(key) { win.contactKey = key }
      onEditRequested: function(c) { win.editContact(c) }
      onNewRequested: win.newContact()
      onAddBookRequested: win.openBookEditor(null)
      onNotice: function(text) { win.flash(text) }
    }

    // ----------------------------------------------------------------- drawer
    Rectangle {
      id: drawerPane
      visible: win.drawer !== ""
      x: parent.width - width - Style.space(16)
      y: sidebar.y
      width: Style.space(360)
      height: sidebar.height
      radius: Style.cornerRadius
      color: Util.alpha(win.fg, 0.04)
      border.width: Style.spacing.hairline
      border.color: Util.alpha(win.fg, 0.1)

      Flickable {
        id: drawerScroll
        anchors.fill: parent
        anchors.margins: Style.space(14)
        contentWidth: width
        contentHeight: win.drawer === "event" ? eventEditor.implicitHeight
          : win.drawer === "hidden" ? hiddenList.implicitHeight
          : win.drawer === "contact" ? contactEditor.implicitHeight
          : win.drawer === "book" ? bookEditor.implicitHeight : calendarEditor.implicitHeight
        topMargin: Style.space(4)
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        EventEditor {
          id: eventEditor
          visible: win.drawer === "event"
          width: drawerScroll.width
          store: win.store
          use24h: win.use24h
          fg: win.fg
          fontFamily: win.fontFamily
          onFinished: function(key) {
            if (key) win.cursorKey = key
            win.closeDrawer()
          }
        }

        HiddenList {
          id: hiddenList
          visible: win.drawer === "hidden"
          width: drawerScroll.width
          store: win.store
          use24h: win.use24h
          fg: win.fg
          fontFamily: win.fontFamily
          onFinished: win.closeDrawer()
          onPicked: function(key) { win.cursorKey = key }
        }

        CalendarEditor {
          id: calendarEditor
          visible: win.drawer === "calendar"
          width: drawerScroll.width
          store: win.store
          fg: win.fg
          fontFamily: win.fontFamily
          onFinished: win.closeDrawer()
        }

        ContactEditor {
          id: contactEditor
          visible: win.drawer === "contact"
          width: drawerScroll.width
          store: win.store
          fg: win.fg
          fontFamily: win.fontFamily
          onFinished: function(key) {
            if (key) win.contactKey = key
            win.closeDrawer()
          }
        }

        AddressBookEditor {
          id: bookEditor
          visible: win.drawer === "book"
          width: drawerScroll.width
          store: win.store
          fg: win.fg
          fontFamily: win.fontFamily
          onAdded: function(id) { win.contactsBook = "" }
          onFinished: {
            if (win.contactsBook && win.store && !win.store.bookById(win.contactsBook)) win.contactsBook = ""
            win.closeDrawer()
          }
        }
      }
    }
  }
}
