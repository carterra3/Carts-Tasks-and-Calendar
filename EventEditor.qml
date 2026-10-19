import QtQuick
import qs.Commons
import qs.Ui
import "Events.js" as Events
import "Recur.js" as Recur
import "Tz.js" as Tz

// New / edit / view event form, shared by the popout and the window.
// Routing to local or CalDAV storage is the store's job (Store.saveEvent).
//
// openNew(key[, minutes]) / openEdit(ev) / setDay(key) drive it; it emits
// finished(key) when done ("" when cancelled) so the host can return to its
// normal view and select the day the event landed on.
Column {
  id: root

  property var store: null
  property bool use24h: true
  property color fg: Color.foreground
  property string fontFamily: Style.font.family

  signal finished(string key)

  property var editingEvent: null
  property string formCalendarId: ""
  property bool formAllDay: false
  property string formError: ""
  property bool confirmDelete: false
  property bool saving: false
  property bool readOnly: false
  property string readOnlyReason: ""
  // The zone the time fields are in ("" = this machine's). Records always
  // hold local times; the editor converts on the way in and out.
  property string formTz: ""
  property string _awaitTz: ""
  property var _awaitEvent: null
  readonly property var formTable: formTz && store ? store.zoneTable(formTz) : null
  // For an occurrence of a repeating event: "save" / "delete" while asking
  // which occurrences the change applies to.
  property string askScope: ""
  readonly property bool isOccurrence: editingEvent !== null && !!editingEvent.recurring
  readonly property string startKeyText: {
    var d = Events.parseDate(startDateField.text)
    return d ? Events.keyOf(d) : ""
  }

  readonly property var calendars: store ? store.calendars : []
  readonly property var writableCalendars: calendars.filter(function(c) { return root.store && root.store.calendarWritable(c.id) })
  readonly property color dimFg: Qt.darker(fg, 1.5)
  readonly property color faintFg: Qt.darker(fg, 1.9)

  spacing: Style.space(8)
  focus: readOnly
  Keys.onPressed: function(event) { root.handleKey(event) }

  function calColor(id) { return store ? store.calendarColor(id) : Color.accent }

  function firstWritableCalendarId() {
    for (var i = 0; i < calendars.length; i++)
      if (calendars[i].visible !== false && store.calendarWritable(calendars[i].id)) return calendars[i].id
    return writableCalendars.length ? writableCalendars[0].id : ""
  }

  function fill(form) {
    titleField.text = form.title
    root.formCalendarId = form.calendarId
    root.formAllDay = form.allDay
    startDateField.text = form.startDate
    endDateField.text = form.endDate
    startTimeField.text = form.startTime
    endTimeField.text = form.endTime
    locationField.text = form.location
    notesField.text = form.notes
    repeatEditor.load(form.rrule || "", form.startDate)
  }

  function reset() {
    root.formError = ""
    root.confirmDelete = false
    root.saving = false
    root.askScope = ""
  }

  // false when there is nowhere writable to put an event.
  // A drag moved a repeating event: show it at its new time and ask which
  // occurrences the move applies to.
  function openMoved(ev, changed) {
    openEdit(ev)
    if (root.readOnly) return
    var f = zoneForm(changed)
    f.rrule = changed.rrule !== undefined ? changed.rrule : (ev.rrule || "")
    fill(f)
    save()
  }

  // Editor fields for an event: its times in its own zone.
  function zoneForm(ev) {
    var shown = ev
    var table = !ev.allDay && ev.tz && store ? store.zoneTable(ev.tz) : null
    if (table) {
      shown = {}
      for (var k in ev) shown[k] = ev[k]
      shown.start = Tz.localToZone(ev.start, table)
      shown.end = Tz.localToZone(ev.end, table)
    }
    var f = Events.formFor(shown, root.use24h)
    if (ev.rrule !== undefined) f.rrule = ev.rrule
    return f
  }

  function openNew(key, minutes, endMinutes) {
    var cal = firstWritableCalendarId()
    if (cal === "") return false
    root.editingEvent = null
    root.readOnly = false
    root.readOnlyReason = ""
    root.formTz = ""
    if (store) store.loadZoneList()
    reset()
    var form = Events.newForm(key, cal, new Date(), root.use24h)
    if (minutes !== undefined && minutes !== null && minutes >= 0) {
      var h = Math.floor(minutes / 60), m = minutes % 60
      var endMin = endMinutes !== undefined && endMinutes > minutes ? Math.min(23 * 60 + 59, endMinutes) : Math.min(23 * 60 + 59, minutes + 60)
      form.startTime = Events.formatTime(h, m, root.use24h)
      form.endTime = Events.formatTime(Math.floor(endMin / 60), endMin % 60, root.use24h)
    }
    fill(form)
    Qt.callLater(function() { titleField.forceActiveFocus() })
    return true
  }

  function openEdit(ev) {
    root.editingEvent = ev
    root.readOnly = !store.eventEditable(ev)
    var t = store.sourceType(ev.calendarId)
    root.readOnlyReason = !root.readOnly ? ""
      : t === "ics" ? "From a subscribed link, so it can only be changed at the source."
      : "This calendar is read-only on the server."
    reset()
    root.formTz = ev.allDay ? "" : (ev.tz || "")
    store.loadZoneList()
    if (root.formTz && !store.zoneTable(root.formTz)) {
      // Not loaded yet: fill again once it is (see Connections below).
      root._awaitTz = root.formTz
      root._awaitEvent = ev
      store.ensureZones([root.formTz])
    }
    fill(zoneForm(ev))
    Qt.callLater(function() {
      if (root.readOnly) root.forceActiveFocus()
      else { titleField.forceActiveFocus(); titleField.selectAll() }
    })
  }

  // Picking a day elsewhere while editing moves the event there, keeping its length.
  function setDay(key) {
    if (root.readOnly) return
    var d = Events.parseStamp(key)
    if (!d) return
    var oldStart = Events.parseDate(startDateField.text)
    var oldEnd = Events.parseDate(endDateField.text)
    startDateField.text = key
    if (oldStart && oldEnd) endDateField.text = Events.keyOf(new Date(d.getTime() + (oldEnd.getTime() - oldStart.getTime())))
    else endDateField.text = key
  }

  // A clicked time slot while editing: move the event to that day and time,
  // keeping its length. minutes < 0 means a whole day (month view).
  function setSlot(key, minutes) {
    if (root.readOnly) return
    if (minutes === undefined || minutes === null || minutes < 0) { setDay(key); return }
    var oldStart = Events.parseDate(startDateField.text)
    var st = Events.parseTime(startTimeField.text)
    var et = Events.parseTime(endTimeField.text)
    var oldEnd = Events.parseDate(endDateField.text) || oldStart
    var length = 60
    if (!root.formAllDay && oldStart && st && et) {
      var a = new Date(oldStart.getFullYear(), oldStart.getMonth(), oldStart.getDate(), st.h, st.m)
      var b = new Date(oldEnd.getFullYear(), oldEnd.getMonth(), oldEnd.getDate(), et.h, et.m)
      if (b.getTime() > a.getTime()) length = Math.round((b.getTime() - a.getTime()) / 60000)
    }
    var day = Events.parseStamp(key)
    var s = new Date(day.getFullYear(), day.getMonth(), day.getDate(), Math.floor(minutes / 60), minutes % 60)
    var e = new Date(s.getTime() + length * 60000)
    // The grid is in local time; the fields are in the event's zone.
    var ss = Events.parseStamp(Tz.localToZone(Events.stampOf(s, false), root.formTable))
    var es = Events.parseStamp(Tz.localToZone(Events.stampOf(e, false), root.formTable))
    root.formAllDay = false
    startDateField.text = Events.keyOf(ss)
    startTimeField.text = Events.formatTime(ss.getHours(), ss.getMinutes(), root.use24h)
    endDateField.text = Events.keyOf(es)
    endTimeField.text = Events.formatTime(es.getHours(), es.getMinutes(), root.use24h)
  }

  // Synced events can be hidden here without touching the shared calendar.
  readonly property bool hideable: editingEvent !== null && store && store.canHide(editingEvent)

  function hide(series) {
    if (!root.hideable || root.saving) return
    var key = root.editingEvent.start.substr(0, 10)
    store.hideEvent(root.editingEvent, series)
    root.editingEvent = null
    reset()
    root.finished(key)
  }

  function cancel() {
    if (root.saving) return
    root.editingEvent = null
    reset()
    root.finished("")
  }

  function buildFromForm() {
    var rule = repeatEditor.ruleText()
    if (rule === null) return { error: "Repeat end date not understood (try 2026-12-31)" }
    var result = Events.buildEvent({
      title: titleField.text,
      calendarId: root.formCalendarId,
      allDay: root.formAllDay,
      startDate: startDateField.text,
      endDate: endDateField.text,
      startTime: startTimeField.text,
      endTime: endTimeField.text,
      location: locationField.text,
      notes: notesField.text
    }, root.editingEvent, new Date().toISOString())
    if (result.event) {
      if (rule) result.event.rrule = rule
      else delete result.event.rrule
      if (!result.event.allDay && root.formTz) {
        if (!root.formTable) return { error: "Time zone data is still loading; try again in a moment" }
        result.event.start = Tz.zoneToLocal(result.event.start, root.formTable)
        result.event.end = Tz.zoneToLocal(result.event.end, root.formTable)
        result.event.tz = root.formTz
      } else delete result.event.tz
    }
    return result
  }

  // "Your time: Tue 2:00 AM – 3:00 AM" under the times of an event in
  // another zone ("" when there is nothing to say).
  function localHint() {
    if (root.formAllDay || !root.formTz || !root.formTable) return ""
    var sd = Events.parseDate(startDateField.text), st = Events.parseTime(startTimeField.text)
    if (!sd || !st) return ""
    var ed = Events.parseDate(endDateField.text, sd.getFullYear()) || sd
    var et = Events.parseTime(endTimeField.text)
    var a = Events.parseStamp(Tz.zoneToLocal(Events.keyOf(sd) + "T" + Events.timeKey(st.h, st.m), root.formTable))
    var text = "Your time: " + Qt.formatDate(a, "ddd") + " " + Events.formatTime(a.getHours(), a.getMinutes(), root.use24h)
    if (et) {
      var b = Events.parseStamp(Tz.zoneToLocal(Events.keyOf(ed) + "T" + Events.timeKey(et.h, et.m), root.formTable))
      text += " – " + (Events.keyOf(b) !== Events.keyOf(a) ? Qt.formatDate(b, "ddd") + " " : "") + Events.formatTime(b.getHours(), b.getMinutes(), root.use24h)
    }
    return text
  }

  Connections {
    target: root.store
    function onZoneTablesChanged() {
      if (root._awaitTz && root.store.zoneTable(root._awaitTz) && root.editingEvent === root._awaitEvent) {
        root.fill(root.zoneForm(root._awaitEvent))
        root._awaitTz = ""
      }
    }
  }

  // Which scopes make sense for this change of an occurrence.
  readonly property bool scopeMoving: isOccurrence && root.formCalendarId !== editingEvent.calendarId
  property bool scopeRuleChanged: false

  function save(scope) {
    if (!store || root.saving) return
    if (root.readOnly) { cancel(); return }
    var result = buildFromForm()
    if (result.error) { root.formError = result.error; return }
    var ev = result.event
    root.formError = ""
    if (root.isOccurrence && !scope) {
      root.scopeRuleChanged = Recur.formatRule(Recur.parseRule(ev.rrule || "")) !== Recur.formatRule(Recur.parseRule(root.editingEvent.rrule || ""))
      root.askScope = "save"
      return
    }
    root.askScope = ""
    root.saving = store.isRemote(ev.calendarId) || (root.editingEvent && store.isRemote(root.editingEvent.calendarId))
    store.saveEvent(ev, root.editingEvent, function(err) {
      root.saving = false
      if (err) { root.formError = err; return }
      root.editingEvent = null
      root.finished(ev.start.substr(0, 10))
    }, scope)
  }

  function remove(scope) {
    if (!store || !root.editingEvent || root.saving) return
    if (root.isOccurrence && !scope) { root.scopeRuleChanged = false; root.askScope = "delete"; return }
    if (!root.isOccurrence && !root.confirmDelete) { root.confirmDelete = true; return }
    root.askScope = ""
    var key = root.editingEvent.start.substr(0, 10)
    root.saving = store.isRemote(root.editingEvent.calendarId)
    store.deleteEvent(root.editingEvent, function(err) {
      root.saving = false
      if (err) { root.formError = err; root.confirmDelete = false; return }
      root.editingEvent = null
      root.finished(key)
    }, scope)
  }

  function chooseScope(scope) {
    if (root.askScope === "save") save(scope)
    else if (root.askScope === "delete") remove(scope)
  }

  // Return is handled here, not with each field's onAccepted: TextField does
  // not consume it, so the same press would otherwise travel on to the host.
  function handleKey(event) {
    if (event.key === Qt.Key_Escape && root.askScope !== "") { root.askScope = ""; event.accepted = true }
    else if (event.key === Qt.Key_Escape) { cancel(); event.accepted = true }
    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { event.accepted = true; save() }
  }

  PanelSectionHeader {
    text: root.readOnly ? "EVENT" : root.editingEvent ? "EDIT EVENT" : "NEW EVENT"
    foreground: root.fg
    fontFamily: root.fontFamily
  }

  Text {
    visible: root.readOnly
    width: parent.width
    wrapMode: Text.Wrap
    textFormat: Text.PlainText
    text: "󰌾  " + root.readOnlyReason
    color: root.dimFg
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  TextField {
    id: titleField
    width: parent.width
    placeholderText: "Title"
    readOnly: root.readOnly
    foreground: root.fg
    font.family: root.fontFamily
  }

  // Read-only events show their own calendar; editable ones can move to any
  // calendar we can write to (local or CalDAV).
  Dropdown {
    width: parent.width
    showLabel: false
    enabled: !root.readOnly && !root.saving
    value: root.formCalendarId
    options: (root.readOnly ? root.calendars.filter(function(c) { return c.id === root.formCalendarId }) : root.writableCalendars)
      .map(function(c) { return { value: c.id, label: c.name } })
    foreground: root.fg
    fontFamily: root.fontFamily
    onChanged: function(v) { root.formCalendarId = v }

    Swatch {
      anchors.right: parent.right
      anchors.rightMargin: Style.space(30)
      anchors.verticalCenter: parent.verticalCenter
      swatch: root.calColor(root.formCalendarId)
    }
  }

  Text {
    visible: root.store && root.store.isRemote(root.formCalendarId)
    width: parent.width
    wrapMode: Text.Wrap
    textFormat: Text.PlainText
    text: root.store ? root.store.sourceLabel(root.formCalendarId) : ""
    color: root.faintFg
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Toggle {
    width: parent.width
    label: "All day"
    checked: root.formAllDay
    enabled: !root.readOnly
    foreground: root.fg
    fontFamily: root.fontFamily
    titleSize: Style.font.body
    onClicked: if (!root.readOnly) root.formAllDay = !root.formAllDay
  }

  Caption { foreground: root.fg; fontFamily: root.fontFamily; text: "STARTS" }
  Row {
    width: parent.width
    spacing: Style.space(8)
    TextField {
      id: startDateField
      width: root.formAllDay ? parent.width : (parent.width - parent.spacing) * 0.58
      placeholderText: "yyyy-mm-dd"
      readOnly: root.readOnly
      foreground: root.fg
      font.family: root.fontFamily
    }
    TextField {
      id: startTimeField
      visible: !root.formAllDay
      width: (parent.width - parent.spacing) * 0.42
      placeholderText: root.use24h ? "09:00" : "9:00 AM"
      readOnly: root.readOnly
      foreground: root.fg
      font.family: root.fontFamily
    }
  }

  Caption { foreground: root.fg; fontFamily: root.fontFamily; text: "ENDS" }
  Row {
    width: parent.width
    spacing: Style.space(8)
    TextField {
      id: endDateField
      width: root.formAllDay ? parent.width : (parent.width - parent.spacing) * 0.58
      placeholderText: "same day"
      readOnly: root.readOnly
      foreground: root.fg
      font.family: root.fontFamily
    }
    TextField {
      id: endTimeField
      visible: !root.formAllDay
      width: (parent.width - parent.spacing) * 0.42
      placeholderText: "+1 hour"
      readOnly: root.readOnly
      foreground: root.fg
      font.family: root.fontFamily
    }
  }

  SearchableDropdown {
    width: parent.width
    visible: !root.formAllDay && (!root.readOnly || root.formTz !== "")
    enabled: !root.readOnly
    showLabel: false
    value: root.formTz
    placeholderText: "Search time zones…"
    options: [{ value: "", label: "Your time zone" + (root.store && root.store.localZone ? " (" + root.store.localZone.replace(/_/g, " ") + ")" : "") }]
      .concat(root.store ? root.store.zoneOptions : [])
    foreground: root.fg
    fontFamily: root.fontFamily
    onChanged: function(v) {
      // The times stay as typed, now in the new zone ("9:00 in Paris").
      root.formTz = v
      if (v && root.store) root.store.ensureZones([v])
    }
  }

  Text {
    readonly property string hint: { startDateField.text; startTimeField.text; endDateField.text; endTimeField.text; return root.localHint() }
    visible: hint !== ""
    width: parent.width
    wrapMode: Text.Wrap
    textFormat: Text.PlainText
    text: hint
    color: root.faintFg
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  RepeatEditor {
    id: repeatEditor
    width: parent.width
    visible: !root.readOnly || preset !== "none"
    readOnly: root.readOnly
    startKey: root.startKeyText
    allDay: root.formAllDay
    fg: root.fg
    fontFamily: root.fontFamily
  }

  TextField {
    id: locationField
    width: parent.width
    placeholderText: root.readOnly ? "" : "Location"
    readOnly: root.readOnly
    visible: !root.readOnly || text !== ""
    foreground: root.fg
    font.family: root.fontFamily
  }

  TextField {
    id: notesField
    width: parent.width
    placeholderText: "Notes"
    readOnly: root.readOnly
    visible: !root.readOnly
    foreground: root.fg
    font.family: root.fontFamily
  }

  // Feeds often carry long descriptions (meeting links, agendas); read-only
  // events show them wrapped instead of in a one-line field.
  Text {
    visible: root.readOnly && notesField.text !== ""
    width: parent.width
    wrapMode: Text.Wrap
    textFormat: Text.PlainText
    maximumLineCount: 12
    elide: Text.ElideRight
    text: notesField.text
    color: root.dimFg
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  Text {
    visible: root.formError !== ""
    width: parent.width
    wrapMode: Text.Wrap
    textFormat: Text.PlainText
    text: root.formError
    color: Color.urgent
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  // ---- Which occurrences (repeating events)
  Column {
    visible: root.askScope !== ""
    width: parent.width
    spacing: Style.space(6)

    Text {
      width: parent.width
      wrapMode: Text.Wrap
      textFormat: Text.PlainText
      text: root.askScope === "delete" ? "Delete which events?"
        : root.scopeMoving ? "Moving to another calendar moves the whole series."
        : root.scopeRuleChanged ? "Change the repeat for which events?" : "Save changes to which events?"
      color: root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
    }
    Flow {
      width: parent.width
      spacing: Style.space(6)
      Button {
        visible: !root.scopeMoving && !root.scopeRuleChanged
        text: "This event"
        bordered: true
        selected: true
        foreground: root.askScope === "delete" ? Color.urgent : root.fg
        fontFamily: root.fontFamily
        onClicked: root.chooseScope("this")
      }
      Button {
        visible: !root.scopeMoving
        text: "This and following"
        bordered: true
        foreground: root.askScope === "delete" ? Color.urgent : root.fg
        fontFamily: root.fontFamily
        onClicked: root.chooseScope("following")
      }
      Button {
        text: "All events"
        bordered: true
        foreground: root.askScope === "delete" ? Color.urgent : root.fg
        fontFamily: root.fontFamily
        onClicked: root.chooseScope("all")
      }
      Button {
        text: "Back"
        bordered: true
        foreground: root.fg
        fontFamily: root.fontFamily
        onClicked: root.askScope = ""
      }
    }
  }

  Row {
    visible: root.askScope === ""
    spacing: Style.space(8)
    Button {
      visible: !root.readOnly
      text: root.saving ? "Saving…" : "Save"
      enabled: !root.saving
      bordered: true
      selected: true
      foreground: root.fg
      fontFamily: root.fontFamily
      onClicked: root.save()
    }
    Button {
      text: root.readOnly ? "Close" : "Cancel"
      enabled: !root.saving
      bordered: true
      foreground: root.fg
      fontFamily: root.fontFamily
      onClicked: root.cancel()
    }
    Button {
      visible: root.editingEvent !== null && !root.readOnly
      enabled: !root.saving
      text: root.confirmDelete
        ? (root.hideable ? "Really delete for everyone?" : "Really delete?")
        : (root.hideable ? "Delete for everyone" : "Delete")
      bordered: true
      foreground: root.confirmDelete ? Color.urgent : root.fg
      fontFamily: root.fontFamily
      onClicked: root.remove()
    }
  }

  // ---- Hide (synced calendars only)
  PanelSeparator { visible: root.hideable; width: parent.width; foreground: root.fg }

  Row {
    visible: root.hideable
    spacing: Style.space(8)
    Button {
      text: root.editingEvent && root.editingEvent.recurring ? "Hide this one" : "Hide"
      iconText: "\uf070"
      enabled: !root.saving
      bordered: true
      foreground: root.fg
      fontFamily: root.fontFamily
      onClicked: root.hide(false)
    }
    Button {
      visible: root.editingEvent !== null && !!root.editingEvent.recurring
      text: "Hide all repeats"
      enabled: !root.saving
      bordered: true
      foreground: root.fg
      fontFamily: root.fontFamily
      onClicked: root.hide(true)
    }
  }

  Text {
    visible: root.hideable
    width: parent.width
    wrapMode: Text.Wrap
    textFormat: Text.PlainText
    text: "Hiding only affects this computer. The shared calendar is unchanged, and it stays hidden after syncs. Unhide from \"Hidden events\" under Calendars."
    color: root.faintFg
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Text {
    visible: !root.readOnly
    width: parent.width
    wrapMode: Text.Wrap
    textFormat: Text.PlainText
    text: "Click a day or time to move the event. Enter saves, Esc cancels."
    color: root.faintFg
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
}
