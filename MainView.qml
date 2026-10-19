import QtQuick
import qs.Commons
import "Events.js" as Events

// The switchable main view: month grid, week or day time grid, or agenda.
// The popout gives it fixed sizes per preset (fill: false); the window lets
// it fill whatever space the tile has (fill: true).
Item {
  id: root

  property var store: null
  property string view: "month"         // year | month | week | day | agenda
  property string cursorKey: ""
  property string todayKey: ""
  property int weekStart: 1
  property bool use24h: true
  property color fg: Color.foreground
  property string fontFamily: Style.font.family

  property bool fill: false
  // Off while nobody can see it (e.g. the popup is closed): nothing is built,
  // so store changes cost nothing here.
  property bool active: true
  // Fixed-size presets (fill: false)
  property real monthCellWidth: Style.space(48)
  property real monthCellHeight: Style.space(40)
  property int maxChips: 0
  property bool showWeekNumbers: true
  property real timeGridWidth: Style.space(480)
  property real hourHeight: Style.space(34)
  property real visibleHours: 9
  property real agendaWidth: Style.space(420)
  property real agendaHeight: Style.space(380)
  property int agendaDays: 30

  signal picked(string key)
  signal activated(string key, int minutes)
  signal eventPicked(var ev)
  signal stepRequested(int delta)
  signal weekStartToggleRequested()
  // Year view: open a day (Day view) or a month (Month view).
  signal openRequested(string key, string view)
  // Drags: an event moved/resized, or a new time range picked.
  signal eventMoved(var ev, var changed)
  signal rangeSelected(string key, int startMinutes, int endMinutes)

  readonly property date cursorDate: Events.parseStamp(cursorKey) || new Date()
  readonly property bool isTime: view === "week" || view === "day"

  // Only the selected view exists (one Loader each). Hidden views used to stay
  // alive and redo their bindings over the whole event list on every change.

  implicitWidth: view === "year" ? timeGridWidth : view === "month" ? (monthLoader.item ? monthLoader.item.implicitWidth : 0)
    : view === "agenda" ? agendaWidth : timeGridWidth
  implicitHeight: view === "month" ? (monthLoader.item ? monthLoader.item.implicitHeight : 0)
    : view === "agenda" ? agendaHeight : (timeLoader.item ? timeLoader.item.implicitHeight : 0)

  Loader {
    id: monthLoader
    active: root.active && root.view === "month"
    sourceComponent: MonthGrid {
      store: root.store
      year: root.cursorDate.getFullYear()
      month: root.cursorDate.getMonth()
      weekStart: root.weekStart
      selectedKey: root.cursorKey
      todayKey: root.todayKey
      use24h: root.use24h
      showWeekNumbers: root.showWeekNumbers
      fg: root.fg
      fontFamily: root.fontFamily
      cellWidth: root.fill
        ? Math.max(Style.space(30), (root.width - weekColumnWidth - gutterWidth - 7 * cellSpacing) / 7)
        : root.monthCellWidth
      cellHeight: root.fill
        ? Math.max(Style.space(28), (root.height - headerHeight - 7 * Style.space(2)) / 6)
        : root.monthCellHeight
      maxChips: root.fill ? Math.max(0, Math.floor((cellHeight - Style.space(24)) / Style.space(17))) : root.maxChips
      dayFontSize: maxChips > 0 ? Style.font.bodySmall : Style.font.body
      onPicked: function(key) { root.picked(key) }
      onActivated: function(key) { root.activated(key, -1) }
      onEventPicked: function(ev) { root.eventPicked(ev) }
      onStepRequested: function(d) { root.stepRequested(d) }
      onWeekStartToggleRequested: root.weekStartToggleRequested()
      onEventMoved: function(ev, changed) { root.eventMoved(ev, changed) }
    }
  }

  Loader {
    id: timeLoader
    active: root.active && root.isTime
    sourceComponent: TimeGrid {
      width: root.fill ? root.width : root.timeGridWidth
      height: root.fill ? root.height : implicitHeight
      store: root.store
      days: root.view === "day" ? 1 : 7
      startKey: root.view === "day" ? root.cursorKey : Events.weekStartKey(root.cursorKey, root.weekStart)
      selectedKey: root.cursorKey
      todayKey: root.todayKey
      use24h: root.use24h
      // Filling a tall tile, show about 16 hours rather than a sliver of 24.
      hourHeight: root.fill ? Math.max(root.hourHeight, (root.height - Style.space(90)) / 16) : root.hourHeight
      visibleHours: root.visibleHours
      fg: root.fg
      fontFamily: root.fontFamily
      onPicked: function(key) { root.picked(key) }
      onEventPicked: function(ev) { root.eventPicked(ev) }
      onSlotActivated: function(key, minutes) { root.activated(key, minutes) }
      onEventMoved: function(ev, changed) { root.eventMoved(ev, changed) }
      onRangeSelected: function(key, a, b) { root.rangeSelected(key, a, b) }
    }
  }

  Loader {
    id: yearLoader
    active: root.active && root.view === "year"
    sourceComponent: YearView {
      width: root.fill ? root.width : root.timeGridWidth
      height: root.fill ? root.height : root.agendaHeight
      store: root.store
      cursorKey: root.cursorKey
      todayKey: root.todayKey
      weekStart: root.weekStart
      use24h: root.use24h
      fg: root.fg
      fontFamily: root.fontFamily
      onPicked: function(key) { root.picked(key) }
      onActivated: function(key) { root.openRequested(key, "day") }
      onMonthActivated: function(key) { root.openRequested(key, "month") }
      onStepRequested: function(d) { root.stepRequested(d) }
    }
  }

  Loader {
    id: agendaLoader
    active: root.active && root.view === "agenda"
    sourceComponent: Flickable {
      id: agendaScroll
      width: root.fill ? root.width : root.agendaWidth
      height: root.fill ? root.height : root.agendaHeight
      contentWidth: width
      contentHeight: agenda.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds

      AgendaList {
        id: agenda
        width: agendaScroll.width - Style.space(4)
        store: root.store
        fromKey: root.cursorKey
        days: root.agendaDays
        showHeaders: true
        todayKey: root.todayKey
        use24h: root.use24h
        fg: root.fg
        fontFamily: root.fontFamily
        onEventPicked: function(ev) { root.eventPicked(ev) }
        onPicked: function(key) { root.picked(key) }
      }
    }
  }
}
