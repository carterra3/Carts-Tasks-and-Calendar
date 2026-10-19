import QtQuick
import qs.Commons
import qs.Ui
import "Events.js" as Events
import "Recur.js" as Recur

// The "Repeat" part of the event editor: presets that follow the event's
// start date (weekly on its weekday, monthly on its day or nth weekday,
// yearly on its date), an interval, weekdays for weekly, and how it ends.
// Rules it cannot represent (from other apps) are kept as they are.
//
// load(rule, startKey) fills it; ruleText() gives the rule ("" = no repeat).
Column {
  id: root

  property string startKey: ""          // yyyy-MM-dd of the event's start
  property bool allDay: false
  property bool readOnly: false
  property color fg: Color.foreground
  property string fontFamily: Style.font.family

  property string preset: "none"        // none daily weekly weekdays monthlyDay monthlyNth yearly custom
  property int interval: 1
  property var weekdays: []             // ["MO", "WE"]
  property string endMode: "never"      // never until count
  property int count: 10
  property string customRule: ""

  readonly property var codes: Recur.WEEKDAYS
  readonly property var shortNames: ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]
  readonly property var longNames: ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
  readonly property date startDate: Events.parseStamp(startKey) || new Date()
  readonly property int startWd: (startDate.getDay() + 6) % 7
  readonly property int dayOfMonth: startDate.getDate()
  readonly property bool lastWeek: dayOfMonth + 7 > new Date(startDate.getFullYear(), startDate.getMonth() + 1, 0).getDate()
  readonly property int nth: lastWeek && dayOfMonth > 28 ? -1 : Math.ceil(dayOfMonth / 7)
  readonly property var ordinalNames: ({ "1": "first", "2": "second", "3": "third", "4": "fourth", "5": "fifth", "-1": "last" })
  readonly property color dimFg: Qt.darker(fg, 1.5)

  spacing: Style.space(6)

  function weeklyDaysLabel() {
    var days = root.preset === "weekly" && root.weekdays.length ? root.weekdays : [root.codes[root.startWd]]
    var names = root.codes.filter(function(c) { return days.indexOf(c) !== -1 })
      .map(function(c) { return days.length > 2 ? root.shortNames[root.codes.indexOf(c)] : root.longNames[root.codes.indexOf(c)] })
    return names.length <= 1 ? names.join("") : names.slice(0, -1).join(", ") + " and " + names[names.length - 1]
  }

  function presetOptions() {
    var wd = longNames[startWd]
    var opts = [
      { value: "none", label: "Does not repeat" },
      { value: "daily", label: "Daily" },
      { value: "weekly", label: "Weekly on " + root.weeklyDaysLabel() },
      { value: "weekdays", label: "Every weekday (Mon–Fri)" },
      { value: "monthlyDay", label: "Monthly on day " + dayOfMonth },
      { value: "monthlyNth", label: "Monthly on the " + ordinalNames[String(nth)] + " " + wd },
      { value: "yearly", label: "Yearly on " + Qt.formatDate(startDate, "MMMM d") }
    ]
    if (root.preset === "custom") opts.push({ value: "custom", label: Recur.summary(root.customRule) || "Custom" })
    return opts
  }

  function load(rule, key) {
    root.startKey = key || root.startKey
    root.customRule = ""
    root.interval = 1
    root.weekdays = []
    root.endMode = "never"
    root.count = 10
    untilField.text = ""
    if (!rule) { root.preset = "none"; return }
    var r = Recur.parseRule(rule)
    var freq = String(r.FREQ || "").toUpperCase()
    var known = { FREQ: 1, INTERVAL: 1, COUNT: 1, UNTIL: 1, BYDAY: 1, BYMONTHDAY: 1, BYMONTH: 1, WKST: 1 }
    var simple = true
    for (var k in r) if (!known[k]) simple = false
    var byday = Recur.parseByday(r.BYDAY)
    var plain = byday.every(function(b) { return b.n === null })
    var md = r.BYMONTHDAY ? String(r.BYMONTHDAY).split(",") : []
    var p = "custom"
    if (simple) {
      if (freq === "DAILY" && !r.BYDAY && !r.BYMONTHDAY && !r.BYMONTH) p = "daily"
      else if (freq === "WEEKLY" && !r.BYMONTHDAY && !r.BYMONTH && plain) {
        var days = byday.map(function(b) { return root.codes[b.wd] })
        if (days.join() === "MO,TU,WE,TH,FR" && (r.INTERVAL || "1") === "1") p = "weekdays"
        else { p = "weekly"; root.weekdays = days }
      } else if (freq === "MONTHLY" && !r.BYMONTH && md.length === 1 && !r.BYDAY && +md[0] > 0) p = "monthlyDay"
      else if (freq === "MONTHLY" && !r.BYMONTH && !r.BYMONTHDAY && byday.length === 1 && byday[0].n !== null) p = "monthlyNth"
      else if (freq === "YEARLY" && !r.BYDAY && (!r.BYMONTH || String(r.BYMONTH).indexOf(",") === -1) && md.length <= 1) p = "yearly"
    }
    if (p === "custom") { root.customRule = rule; root.preset = "custom"; return }
    root.preset = p
    root.interval = Math.max(1, parseInt(r.INTERVAL || "1", 10) || 1)
    if (r.COUNT) { root.endMode = "count"; root.count = parseInt(r.COUNT, 10) || 1 }
    else if (r.UNTIL) {
      var u = Recur.parseUntil(r.UNTIL)
      if (u) {
        var ms = u.wall !== undefined ? u.wall : u.utc
        var d = u.wall !== undefined ? new Date(ms) : new Date(ms)
        root.endMode = "until"
        untilField.text = u.wall !== undefined
          ? Events.dateKey(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate())
          : Events.keyOf(d)
      }
    }
  }

  // "" = does not repeat; null = the end date could not be read.
  function ruleText() {
    if (root.preset === "none") return ""
    if (root.preset === "custom") return root.customRule
    var r = {}
    var wd = root.codes[root.startWd]
    if (root.preset === "daily") r.FREQ = "DAILY"
    else if (root.preset === "weekly") {
      r.FREQ = "WEEKLY"
      var days = root.weekdays.length ? root.weekdays : [wd]
      r.BYDAY = root.codes.filter(function(c) { return days.indexOf(c) !== -1 }).join(",")
    } else if (root.preset === "weekdays") { r.FREQ = "WEEKLY"; r.BYDAY = "MO,TU,WE,TH,FR" }
    else if (root.preset === "monthlyDay") { r.FREQ = "MONTHLY"; r.BYMONTHDAY = String(root.dayOfMonth) }
    else if (root.preset === "monthlyNth") { r.FREQ = "MONTHLY"; r.BYDAY = root.nth + wd }
    else if (root.preset === "yearly") { r.FREQ = "YEARLY"; r.BYMONTH = String(root.startDate.getMonth() + 1); r.BYMONTHDAY = String(root.dayOfMonth) }
    if (root.preset !== "weekdays" && root.interval > 1) r.INTERVAL = String(root.interval)
    if (root.endMode === "count") r.COUNT = String(Math.max(1, root.count))
    else if (root.endMode === "until") {
      var d = Events.parseDate(untilField.text, root.startDate.getFullYear())
      if (!d) return null
      // Through the end of that day, as UTC for timed events (RFC 5545).
      r.UNTIL = root.allDay ? Events.keyOf(d).replace(/-/g, "")
        : Events.occurrenceKeyUtc(new Date(d.getFullYear(), d.getMonth(), d.getDate(), 23, 59, 59).getTime()) + "Z"
    }
    return Recur.formatRule(r)
  }

  readonly property string unitName: ({ daily: "day", weekly: "week", monthlyDay: "month", monthlyNth: "month", yearly: "year" })[preset] || ""

  Caption { foreground: root.fg; fontFamily: root.fontFamily; text: "REPEAT" }

  Dropdown {
    width: parent.width
    showLabel: false
    enabled: !root.readOnly
    value: root.preset
    options: root.presetOptions()
    foreground: root.fg
    fontFamily: root.fontFamily
    onChanged: function(v) { root.preset = v; if (v === "weekly" && root.weekdays.length === 0) root.weekdays = [root.codes[root.startWd]] }
  }

  // Every N days/weeks/...
  Row {
    visible: root.unitName !== "" && !root.readOnly
    spacing: Style.space(8)
    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: "Every"
      color: root.dimFg
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
    NumberField {
      anchors.verticalCenter: parent.verticalCenter
      value: root.interval
      from: 1
      to: 99
      foreground: root.fg
      fontFamily: root.fontFamily
      onModified: function(v) { root.interval = Math.max(1, v) }
    }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: root.unitName + (root.interval === 1 ? "" : "s")
      color: root.dimFg
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }

  // Weekdays for weekly repeats.
  Row {
    visible: root.preset === "weekly" && !root.readOnly
    spacing: Style.space(3)
    Repeater {
      model: 7
      Button {
        required property int index
        readonly property string code: root.codes[index]
        text: root.shortNames[index]
        bordered: true
        selected: root.weekdays.indexOf(code) !== -1 || (root.weekdays.length === 0 && index === root.startWd)
        horizontalPadding: Style.space(6)
        fontSize: Style.font.caption
        foreground: root.fg
        fontFamily: root.fontFamily
        onClicked: {
          var days = root.weekdays.length ? root.weekdays.slice() : [root.codes[root.startWd]]
          var i = days.indexOf(code)
          if (i === -1) days.push(code)
          else if (days.length > 1) days.splice(i, 1)
          root.weekdays = days
        }
      }
    }
  }

  Row {
    visible: root.preset !== "none" && root.preset !== "custom" && !root.readOnly
    width: parent.width
    spacing: Style.space(8)
    Dropdown {
      width: (parent.width - parent.spacing) * 0.5
      showLabel: false
      value: root.endMode
      options: [{ value: "never", label: "Never ends" }, { value: "until", label: "Ends on" }, { value: "count", label: "Ends after" }]
      foreground: root.fg
      fontFamily: root.fontFamily
      onChanged: function(v) {
        root.endMode = v
        if (v === "until" && untilField.text === "") untilField.text = Events.addMonthsKey(root.startKey, 3)
      }
    }
    TextField {
      id: untilField
      visible: root.endMode === "until"
      width: (parent.width - parent.spacing) * 0.5
      placeholderText: "yyyy-mm-dd"
      foreground: root.fg
      font.family: root.fontFamily
    }
    Row {
      visible: root.endMode === "count"
      spacing: Style.space(6)
      NumberField {
        anchors.verticalCenter: parent.verticalCenter
        value: root.count
        from: 1
        to: 999
        foreground: root.fg
        fontFamily: root.fontFamily
        onModified: function(v) { root.count = Math.max(1, v) }
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "times"
        color: root.dimFg
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }
  }

  Text {
    visible: root.preset !== "none"
    width: parent.width
    wrapMode: Text.Wrap
    textFormat: Text.PlainText
    text: {
      var r = root.ruleText()
      return r === null ? "End date not understood" : Recur.summary(r)
    }
    color: Qt.darker(root.fg, 1.9)
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
}
