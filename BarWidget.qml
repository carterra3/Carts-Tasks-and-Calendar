import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "Events.js" as Events

// Bar label + host for the calendar popup. A drop-in for omarchy.clock:
// left click opens the calendar, right click walks the same label formats
// the stock clock does (and persists the choice to shell.json), middle click
// opens the timezone picker.
BarWidget {
  id: root
  moduleName: "carterra3.carts"

  property date displayDate: clock.date

  readonly property string configuredFormat: vertical
    ? setting("verticalFormat", "HH\n—\nmm")
    : setting("format", "dddd HH:mm")
  readonly property string configuredAltFormat: vertical
    ? setting("verticalFormatAlt", "dd\nMMM\n'W'ww\n''yy")
    : setting("formatAlt", "d MMMM 'W'ww yyyy")

  readonly property var formatRing: Model.clockFormatRing(configuredFormat, configuredAltFormat, Model.clockFormats(vertical))
  readonly property string activeFormat: configuredFormat
  readonly property string displayText: formatted(displayDate)
  readonly property var verticalLines: displayText.split("\n")

  // The panel follows the bar label: a 12-hour label means 12-hour times in
  // the agenda and editor too.
  readonly property bool use24h: !/AP|ap/.test(configuredFormat)

  // Data, sync and the window live once in the plugin's service
  // (Service.qml); every bar widget instance shares it.
  readonly property var service: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor(moduleName) : null
  readonly property var store: service ? service.store : null

  onServiceChanged: registerWithService()
  Component.onCompleted: registerWithService()
  Component.onDestruction: if (service && service.popoutHost === root) service.popoutHost = null

  function registerWithService() {
    if (!service) return
    service.popoutHost = root
    service.barSettings = root.settings
    injectPanel()
  }

  // Ongoing/next event for the tooltip. Cheap: one day's worth of events.
  readonly property var todaysEvents: store && store.ready ? Events.eventsOn(store.dayIndex, Events.keyOf(displayDate)) : []

  function refresh() {
    displayDate = new Date()
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh()
  }

  function cycleFormat() {
    var current = String(configuredFormat)
    var next = Model.nextClockFormat(formatRing, current)
    if (next === "" || next === current) return

    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    entry[vertical ? "verticalFormat" : "format"] = next

    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function formatted(date) {
    return Qt.formatDateTime(date, activeFormat.replace(/ww/g, Model.isoWeekLiteral(date.getFullYear(), date.getMonth(), date.getDate())))
  }

  function tooltip() {
    var list = root.todaysEvents
    if (!list || list.length === 0) return ""
    var key = Events.keyOf(displayDate)
    var lines = []
    for (var i = 0; i < list.length && i < 6; i++)
      lines.push(Events.timeLabel(list[i], key, root.use24h) + "  " + list[i].title)
    if (list.length > 6) lines.push("+" + (list.length - 6) + " more")
    return lines.join("\n")
  }

  // ---- Popup shape contract (Bar.findPanelWidget wants open/close/opened).
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }
  function newEvent() { if (panelLoader.item) panelLoader.item.openNewEvent() }
  function newCalendarOfKind(kind) {
    if (!panelLoader.item) return
    if (!panelLoader.item.opened) panelLoader.item.open()
    panelLoader.item.openNewCalendar(kind)
  }
  function newCalendar() { newCalendarOfKind("local") }
  function subscribe() { newCalendarOfKind("link") }
  function connectAccount() { newCalendarOfKind("account") }
  function cycleView() { if (panelLoader.item) panelLoader.item.cycleView() }
  function cycleSize() { if (panelLoader.item) panelLoader.item.cycleSize() }
  function toggleWeekStart() { if (panelLoader.item) panelLoader.item.toggleWeekStart() }

  readonly property real openPanelIndicatorWidth: button.labelWidth
  readonly property real openPanelIndicatorHeight: Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55))
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("service" in target) target.service = root.service
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: {
    injectPanel()
    if (service && service.popoutHost === root) service.barSettings = root.settings
  }

  SystemClock {
    id: clock
    precision: SystemClock.Minutes
    onDateChanged: root.displayDate = date
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.vertical ? "" : root.displayText
    labelVisible: !root.vertical
    hasVisualContent: root.vertical ? root.verticalLines.length > 0 : text !== ""
    fixedHeight: root.vertical ? root.verticalLines.length * Style.bar.iconSlot : -1
    horizontalMargin: 8.75
    verticalPadding: 8.75
    tooltipText: root.opened ? "" : root.tooltip()

    onPressed: function(b) {
      if (b === Qt.RightButton) root.cycleFormat()
      else if (b === Qt.MiddleButton) { if (root.bar) root.bar.run("omarchy-menu-timezone") }
      else root.togglePanel()
    }

    Column {
      visible: root.vertical
      anchors.fill: parent

      Repeater {
        model: root.verticalLines

        OpticalGlyph {
          required property string modelData
          width: button.width
          height: Style.bar.iconSlot
          text: modelData
          fontFamily: button.fontFamily
          fontSize: modelData.length > 3 ? button.fontSize * 0.9 : button.fontSize
          color: button.foreground
        }
      }
    }
  }
}
